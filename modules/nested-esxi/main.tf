terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
    null    = { source = "hashicorp/null" }
    local   = { source = "hashicorp/local" }
  }
}

###############################################################
# Nested ESXi VM module — option 2 from the discussion: build
# a per-host custom ESXi ISO with an embedded kickstart (ks.cfg),
# upload to a datastore, deploy 3 VMs from those ISOs, wait for
# unattended install to finish, detach the CD, and return the IPs.
#
# Replaces Phases 2-4 of the runbook (nested VM creation +
# interactive ESXi install + static IP setup) with declarative
# Terraform.
###############################################################

variable "datacenter" {
  description = "Datacenter name (used for govc paths)."
  type        = string
}

variable "datacenter_id" {}
variable "resource_pool_id" {
  description = "Resource pool / cluster ID where nested ESXi VMs will live (the *physical* cluster, NOT the Supervisor-Cluster — these ARE the VMs that join Supervisor-Cluster after install)."
}
variable "datastore_id" {
  description = "Datastore for the nested ESXi VMs' disks (typically the physical host's datastore1)."
}
variable "datastore_name" {
  description = "Same datastore as a string (govc datastore.upload takes a name, not an ID)."
  type        = string
}

variable "network_id" {
  description = "Outer port group for the nested ESXi VMs' vmnic0 (typically the outer VM Network)."
}
variable "network_dswitch_vm_id" {
  description = "Outer port group for the nested ESXi VMs' vmnic2 (the management-subnet bridge — typically dswitch-vm)."
}

variable "source_iso_path" {
  description = "Local path to the stock ESXi installer ISO (e.g. /Users/ben/Downloads/VMware-VMvisor-Installer-9.0.2-25148076.iso)."
  type        = string
}

variable "hosts" {
  description = "List of nested ESXi hosts to create. Each entry needs name, ip, and a hostname (defaults to name)."
  type = list(object({
    name     = string
    ip       = string
    hostname = optional(string)
  }))
}

variable "netmask" {
  type    = string
  default = "255.255.255.0"
}
variable "gateway" {
  type    = string
  default = "192.168.3.1"
}
variable "dns" {
  type    = string
  default = "192.168.3.1"
}
variable "root_password" {
  type      = string
  sensitive = true
}

variable "vm_num_cpus" {
  type    = number
  default = 8
}
variable "vm_memory" {
  description = "RAM in MB"
  type        = number
  default     = 32768
}
variable "vm_disk_size_gb" {
  type    = number
  default = 80
}

###############################################################
# Step 1 — Render a kickstart per host
###############################################################
locals {
  hosts_map = { for h in var.hosts : h.name => h }
}

resource "local_file" "ks_cfg" {
  for_each        = local.hosts_map
  filename        = "${path.module}/generated/${each.key}/ks.cfg"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/ks.cfg.tpl", {
    hostname      = coalesce(each.value.hostname, each.value.name)
    ip_addr       = each.value.ip
    gateway       = var.gateway
    netmask       = var.netmask
    dns           = var.dns
    root_password = var.root_password
  })
}

###############################################################
# Step 2 — Build per-host ISO with the kickstart baked in
###############################################################
resource "null_resource" "build_iso" {
  for_each = local.hosts_map

  # Rebuild when the ks.cfg content changes
  triggers = {
    ks_hash    = sha256(local_file.ks_cfg[each.key].content)
    source_iso = var.source_iso_path
    host_name  = each.key
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/build-iso.sh '${var.source_iso_path}' '${path.module}/generated/${each.key}/ks.cfg' '${path.module}/generated/${each.key}/esxi.iso'"
  }

  depends_on = [local_file.ks_cfg]
}

###############################################################
# Step 3 — Upload each ISO into the datastore at iso/<name>.iso
###############################################################
resource "null_resource" "upload_iso" {
  for_each = local.hosts_map

  triggers = {
    iso_hash       = null_resource.build_iso[each.key].id
    datastore_name = var.datastore_name
    host_name      = each.key
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      govc datastore.mkdir -ds="${var.datastore_name}" -dc="${var.datacenter}" -p iso/
      govc datastore.upload \
        -ds="${var.datastore_name}" \
        -dc="${var.datacenter}" \
        "${path.module}/generated/${each.key}/esxi.iso" \
        "iso/nested-esxi-${each.key}.iso"
    EOT
  }

  depends_on = [null_resource.build_iso]
}

###############################################################
# Step 4 — Deploy 3 VMs with the per-host ISO mounted as CD-ROM
###############################################################
data "vsphere_datastore" "iso_store" {
  name          = var.datastore_name
  datacenter_id = var.datacenter_id
}

resource "vsphere_virtual_machine" "nested" {
  for_each = local.hosts_map

  name             = each.key
  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id

  num_cpus         = var.vm_num_cpus
  memory           = var.vm_memory
  guest_id         = "vmkernel8Guest"   # ESXi 8.x/9.x guest OS hint
  firmware         = "efi"
  nested_hv_enabled = true              # required so VMs running ON this ESXi work
  cpu_hot_add_enabled = true
  memory_hot_add_enabled = true

  # vmnic0 → outer VM Network (workload subnet)
  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }
  # vmnic1 → outer VM Network (supervisor-dvs uplink1 later)
  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }
  # vmnic2 → outer dswitch-vm (supervisor-dvs uplink2 later — bridges to mgmt subnet)
  network_interface {
    network_id   = var.network_dswitch_vm_id
    adapter_type = "vmxnet3"
  }

  # ESXi installer can't see LSI Logic SAS disks; use PVSCSI (matches our
  # manual Phase 3 setup).
  scsi_type = "pvscsi"
  disk {
    label            = "disk0"
    size             = var.vm_disk_size_gb
    thin_provisioned = true
    eagerly_scrub    = false
  }

  cdrom {
    datastore_id = data.vsphere_datastore.iso_store.id
    path         = "iso/nested-esxi-${each.key}.iso"
  }

  # Wait short — ESXi doesn't have VMware Tools at install time so the
  # provider's default wait-for-IP times out. We do the wait in step 5.
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  lifecycle {
    ignore_changes = [
      # ESXi rewrites these during install; let it
      annotation,
      vapp,
    ]
  }

  depends_on = [null_resource.upload_iso]
}

###############################################################
# Step 5 — Wait for each VM's static IP to come up (sign the install
# completed + ESXi booted from disk) and then detach the CD-ROM so
# future reboots don't re-run the installer.
###############################################################
resource "null_resource" "post_install" {
  for_each = local.hosts_map

  triggers = {
    vm_id   = vsphere_virtual_machine.nested[each.key].id
    host_ip = each.value.ip
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "Waiting for ${each.value.ip} to come up (ESXi install can take 5-10 min)..."
      for i in $(seq 1 60); do
        if ping -c1 -W2 ${each.value.ip} >/dev/null 2>&1; then
          echo "  reachable after $((i*30))s"
          break
        fi
        sleep 30
      done

      echo "Detaching CD-ROM from /${var.datacenter}/vm/${each.key} ..."
      # Find the cdrom device by name and detach. govc names CD-ROMs
      # like "cdrom-3000"; fetch dynamically.
      CD=$(govc device.ls -vm "/${var.datacenter}/vm/${each.key}" \
            | awk '/^cdrom-/{print $1; exit}')
      if [ -n "$CD" ]; then
        govc device.cdrom.eject -vm "/${var.datacenter}/vm/${each.key}" -device "$CD" || true
        govc device.disconnect  -vm "/${var.datacenter}/vm/${each.key}" "$CD" || true
      fi
    EOT
  }

  depends_on = [vsphere_virtual_machine.nested]
}

###############################################################
# Outputs
###############################################################
output "host_ips" {
  description = "Map of host name → IP, in the order they were declared."
  value       = { for name, h in local.hosts_map : name => h.ip }
}

output "host_ids" {
  description = "Map of host name → VM ID (for use by other modules as `depends_on`)."
  value       = { for name, vm in vsphere_virtual_machine.nested : name => vm.id }
}
