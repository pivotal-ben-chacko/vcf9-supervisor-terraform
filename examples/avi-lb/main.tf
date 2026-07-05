###############################################################
# Avi (NSX Advanced Load Balancer) Controller — standalone deploy
#
# Stage 1 of the Avi path. Deploys + bootstraps the Controller so it is:
#   - powered on with a static management IP,
#   - admin password set (via the OVA `default-password` vApp property),
#   - DNS/NTP/backup-passphrase configured, license applied (optional),
#   - reachable over HTTPS for the cloud-config stage and for Supervisor.
#
# Then run ./cloud-config/ (the `avi` provider) to create the vCenter
# cloud, SE group, and VIP network. Finally repoint the supervisor module
# at this controller (see README "Wiring into Supervisor").
###############################################################

###############################################################
# Inventory lookups
###############################################################

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

# Controller lands on the physical host's cluster/pool + datastore, same
# as the haproxy/nfs modules — not on the nested Supervisor cluster.
data "vsphere_compute_cluster" "physical" {
  name          = var.physical_host_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.outer_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "mgmt" {
  name          = var.controller_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

###############################################################
# Deploy the Controller OVA
#
# Facts extracted from controller-31.2.2-9059.ova:
#   - single NIC on network labelled "Management"
#   - OVF transport = com.vmware.guestInfo (vApp props via guestinfo;
#     no ISO/CDROM needed, but we add a client CDROM defensively — the
#     vsphere provider has historically demanded one for vApp-property
#     delivery on refresh)
#   - userConfigurable props: mgmt-ip, mgmt-mask, default-gw,
#     default-password, sysadmin-public-key, hostname, mgmt-ip-v4-enable
#   - ships 6 vCPU / 32768 MB / 128 GB disk
###############################################################

resource "vsphere_virtual_machine" "controller" {
  name             = var.controller_vm_name
  datacenter_id    = data.vsphere_datacenter.dc.id
  resource_pool_id = data.vsphere_compute_cluster.physical.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = var.controller_cpus
  memory   = var.controller_memory_mb
  guest_id = "ubuntu64Guest" # Avi controller is Linux; overridden by OVF anyway
  # The OVA descriptor pins firmware=bios (vmw:key="firmware" value="bios").
  # Forcing EFI leaves the VM stuck at the EFI Boot Manager — it can't find
  # a bootloader on the BIOS-formatted disk and never boots the OS.
  firmware = "bios"

  # 0 = DISABLE the guest-network waits. (Non-zero means "wait N minutes
  # then FAIL"; the controller takes >5 min to get an IP on first boot, so
  # a non-zero value here fails the apply. The bootstrap null_resource does
  # the real readiness wait against the API instead.)
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0"
    size             = var.controller_disk_gb
    thin_provisioned = true
  }

  ovf_deploy {
    local_ovf_path    = var.avi_ova_path
    disk_provisioning = "thin"
    # Map the OVA's single network ("Management") onto our port group.
    ovf_network_map = {
      "Management" = data.vsphere_network.mgmt.id
    }
  }

  # Defensive: the provider has required a client CDROM to deliver vApp
  # properties on subsequent refreshes (seen in the haproxy module).
  cdrom {
    client_device = true
  }

  # OVA vApp properties — bare keys (no `.CONTROLLER` suffix in 31.x).
  vapp {
    properties = {
      "mgmt-ip-v4-enable" = "True"
      "mgmt-ip"           = var.controller_ip
      "mgmt-mask"         = var.controller_netmask
      "default-gw"        = var.controller_gateway
      "hostname"          = var.controller_hostname
      # Sets the admin password at first boot — avoids the fragile
      # API password-bootstrap dance.
      "default-password"    = var.avi_admin_password
      "sysadmin-public-key" = var.sysadmin_public_key
    }
  }

  lifecycle {
    # The controller rewrites/normalizes some vApp props after first boot;
    # don't fight it on every plan.
    ignore_changes = [vapp[0].properties]
  }
}

###############################################################
# Power-on safety net (mirrors the haproxy module): ovf_deploy with a
# datacenter usually auto-powers-on, but keep an idempotent govc nudge.
###############################################################

resource "null_resource" "power_on" {
  triggers = { vm_id = vsphere_virtual_machine.controller.id }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GOVC_URL      = var.vcenter_server
      GOVC_USERNAME = var.vcenter_username
      GOVC_PASSWORD = var.vcenter_password
      GOVC_INSECURE = var.vcenter_insecure ? "true" : "false"
    }
    command = "if govc vm.info ${var.controller_vm_name} 2>/dev/null | grep -q 'Power state:.*poweredOn'; then echo 'already on'; else govc vm.power -on=true ${var.controller_vm_name}; fi"
  }
}

###############################################################
# Bootstrap: wait for the API, verify admin login, set DNS/NTP +
# backup passphrase, apply license (optional). See scripts/.
###############################################################

resource "null_resource" "bootstrap" {
  triggers = {
    vm_id      = vsphere_virtual_machine.controller.id
    pw         = sha256(var.avi_admin_password)
    dns        = join(",", var.controller_dns_servers)
    ntp        = join(",", var.controller_ntp_servers)
    license    = var.avi_license_file
    script_sha = filesha256("${path.module}/scripts/bootstrap-controller.sh")
  }

  depends_on = [null_resource.power_on]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AVI_IP                = var.controller_ip
      AVI_USER              = var.avi_admin_username
      AVI_PASSWORD          = var.avi_admin_password
      AVI_VERSION           = var.avi_version
      AVI_DNS               = join(",", var.controller_dns_servers)
      AVI_NTP               = join(",", var.controller_ntp_servers)
      AVI_BACKUP_PASSPHRASE = var.avi_backup_passphrase
      AVI_LICENSE_FILE      = var.avi_license_file
    }
    command = "bash ${path.module}/scripts/bootstrap-controller.sh"
  }
}

###############################################################
# Fetch the controller's TLS cert for Supervisor's
# avi_config_create_spec.certificate_authority_chain.
###############################################################

resource "null_resource" "fetch_cert" {
  triggers   = { vm_id = vsphere_virtual_machine.controller.id }
  depends_on = [null_resource.bootstrap]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      mkdir -p ${path.module}/generated
      echo | openssl s_client -connect ${var.controller_ip}:443 -servername ${var.controller_ip} 2>/dev/null \
        | openssl x509 > ${path.module}/generated/avi-controller.crt
      echo "Saved controller cert to generated/avi-controller.crt"
    EOT
  }
}
