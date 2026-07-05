terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
  }
}

variable "datacenter_id" {}
variable "resource_pool_id" {}
variable "datastore_id" {}
variable "network_id" {}
variable "vm_name" {}
variable "ip_addr" {}
variable "gateway" {}
variable "dns_servers" { type = list(string) }
variable "share_size_gb" { type = number }
variable "share_path" {}
variable "ubuntu_ova_url" {}
variable "datastore_name" {
  description = "Name to register the NFS export as in vCenter (mounted on each nested ESXi host)."
  type        = string
  default     = "nfs-shared"
}
variable "nested_host_ids" {
  description = "ID list of nested ESXi hosts that should mount the NFS export as a datastore."
  type        = list(string)
}
variable "supervisor_tag_id" {
  description = "vSphere tag ID to attach to the datastore so the Supervisor tag-based storage policy resolves to it. Managed natively here (not via govc) so re-applies don't plan a tag detach."
  type        = string
}
# Credentials for the post-deploy power-on local-exec
variable "vcenter_server" {}
variable "vcenter_username" {}
variable "vcenter_password" { sensitive = true }
variable "vcenter_insecure" {
  type    = bool
  default = true
}

###############################################################
# NFS storage VM — Ubuntu 24.04 cloud image, single export at
# /srv/nfs/shared, sized per var.share_size_gb.
###############################################################

locals {
  cloud_init = templatefile("${path.module}/templates/user-data.yaml.tpl", {
    hostname    = var.vm_name
    ip_addr     = var.ip_addr
    gateway     = var.gateway
    dns_servers = join(",", var.dns_servers)
    share_path  = var.share_path
  })
}

resource "vsphere_virtual_machine" "nfs" {
  name                       = var.vm_name
  datacenter_id              = var.datacenter_id
  resource_pool_id           = var.resource_pool_id
  datastore_id               = var.datastore_id
  num_cpus                   = 2
  memory                     = 4096
  guest_id                   = "ubuntu64Guest"
  firmware                   = "efi"
  wait_for_guest_net_timeout = 5
  wait_for_guest_ip_timeout  = 5

  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0"
    size             = 40
    thin_provisioned = true
  }

  # Second disk for the NFS share itself
  disk {
    label            = "share"
    size             = var.share_size_gb
    thin_provisioned = true
    unit_number      = 1
  }

  ovf_deploy {
    remote_ovf_url    = var.ubuntu_ova_url
    disk_provisioning = "thin"
  }

  # Satisfy the vsphere provider's plan-time check that vApp properties
  # have a CDROM delivery channel (even though we deliver cloud-init via
  # extra_config/guestinfo, not vApp props). Without this, refreshing
  # the resource on subsequent applies fails with: "requires a client
  # CDROM device to deliver vApp properties".
  cdrom {
    client_device = true
  }

  extra_config = {
    "guestinfo.userdata"          = base64encode(local.cloud_init)
    "guestinfo.userdata.encoding" = "base64"
  }

  # vSphere reports io_reservation=1 / io_share_count=1000 on OVA-deployed
  # disks regardless of what's applied, so these two diff on every plan
  # (and via the supervisor module's depends_on, that noise cascades into
  # an enable-spec replacement). Pin them.
  lifecycle {
    ignore_changes = [
      disk[0].io_reservation,
      disk[0].io_share_count,
      disk[1].io_reservation,
      disk[1].io_share_count,
    ]
  }
}

# The vmware/vsphere provider's ovf_deploy path leaves the VM powered
# off after import — separate explicit step to power it on.
resource "null_resource" "nfs_power_on" {
  triggers = { vm_id = vsphere_virtual_machine.nfs.id }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GOVC_URL      = var.vcenter_server
      GOVC_USERNAME = var.vcenter_username
      GOVC_PASSWORD = var.vcenter_password
      GOVC_INSECURE = var.vcenter_insecure ? "true" : "false"
    }
    # Idempotent. ovf_deploy with datacenter_id set already auto-powers-on,
    # but keep this as a safety net for partial-apply recovery + future provider
    # quirks. Match against the text vm.info output (-json adds whitespace
    # around the colon which broke a prior pattern).
    command = "if govc vm.info ${var.vm_name} 2>/dev/null | grep -q 'Power state:.*poweredOn'; then echo 'already powered on'; else govc vm.power -on=true ${var.vm_name}; fi"
  }
}

###############################################################
# Mount the NFS export on each nested ESXi host as a datastore.
# The supervisor module's storage policy resolves to this datastore
# via tag; without this mount, supervisor_enable fails.
###############################################################

# Wait for cloud-init to finish + the NFS server to actually be listening
# before vCenter tries to mount it (otherwise mount fails with "no server").
resource "null_resource" "wait_for_nfs_export" {
  triggers = { vm_id = vsphere_virtual_machine.nfs.id }
  depends_on = [null_resource.nfs_power_on]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      echo "Waiting up to 6 min for nfs export ${var.ip_addr}:${var.share_path}..."
      for i in $(seq 1 72); do
        if showmount -e ${var.ip_addr} 2>/dev/null | grep -q "${var.share_path}"; then
          echo "  export visible"
          exit 0
        fi
        sleep 5
      done
      echo "ERROR: NFS export never appeared" >&2
      exit 1
    EOT
  }
}

resource "vsphere_nas_datastore" "nfs_shared" {
  name            = var.datastore_name
  host_system_ids = var.nested_host_ids
  type            = "NFS"
  remote_hosts    = [var.ip_addr]
  remote_path     = var.share_path

  # The supervisor module's tag-based storage policy resolves to this
  # datastore through this tag.
  tags = [var.supervisor_tag_id]

  depends_on = [null_resource.wait_for_nfs_export]
}

output "nfs_export" {
  value = "${var.ip_addr}:${var.share_path}"
}

output "nfs_ip" {
  value = var.ip_addr
}

output "nfs_datastore_id" {
  value = vsphere_nas_datastore.nfs_shared.id
}
