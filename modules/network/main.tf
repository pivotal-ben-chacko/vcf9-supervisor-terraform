terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
    null    = { source = "hashicorp/null" }
  }
}

variable "datacenter_id" {}
variable "cluster_id" {}
variable "nested_hosts" {
  description = "Map of vsphere_host data sources, keyed by host name. Pass `data.vsphere_host.nested` from the root module."
  type        = any
}
variable "outer_vm_network_id" {}
variable "outer_dswitch_vm_id" {}
variable "vcenter_server" {}
variable "vcenter_username" {}
variable "vcenter_password" { sensitive = true }
variable "vcenter_insecure" { type = bool }

###############################################################
# supervisor-dvs — Distributed Virtual Switch spanning the
# nested ESXi cluster.
#
# Two uplinks per host:
#   uplink1 = vmnic1 → outer VM Network (workload subnet)
#   uplink2 = vmnic2 → outer dswitch-vm (management subnet)
#
# (vmnic2 is added by the runbook in Phase 9 — Terraform assumes
# the nested ESXi VMs already have it. If they don't, run Phase 9's
# `govc vm.network.add` + power-cycle commands first.)
###############################################################

resource "vsphere_distributed_virtual_switch" "supervisor_dvs" {
  name          = "supervisor-dvs"
  datacenter_id = var.datacenter_id
  uplinks       = ["uplink1", "uplink2", "uplink3", "uplink4"]
  active_uplinks  = ["uplink1", "uplink2"]
  standby_uplinks = []

  dynamic "host" {
    for_each = var.nested_hosts
    content {
      host_system_id = host.value.id
      devices        = ["vmnic1", "vmnic2"]
    }
  }
}

###############################################################
# sup-workload port group — pinned to uplink1 (vmnic1 → workload)
###############################################################

resource "vsphere_distributed_port_group" "sup_workload" {
  name                            = "sup-workload"
  distributed_virtual_switch_uuid = vsphere_distributed_virtual_switch.supervisor_dvs.id
  vlan_id                         = 0

  active_uplinks  = ["uplink1"]
  standby_uplinks = []

  allow_promiscuous = true
  allow_forged_transmits = true
  allow_mac_changes = true
}

###############################################################
# sup-mgmt port group — pinned to uplink2 (vmnic2 → management)
###############################################################

resource "vsphere_distributed_port_group" "sup_mgmt" {
  name                            = "sup-mgmt"
  distributed_virtual_switch_uuid = vsphere_distributed_virtual_switch.supervisor_dvs.id
  vlan_id                         = 0

  active_uplinks  = ["uplink2"]
  standby_uplinks = []

  allow_promiscuous = true
  allow_forged_transmits = true
  allow_mac_changes = true
}

###############################################################
# Outputs
###############################################################

output "sup_mgmt_portgroup_id" {
  value = vsphere_distributed_port_group.sup_mgmt.id
}

output "sup_workload_portgroup_id" {
  value = vsphere_distributed_port_group.sup_workload.id
}

output "dvs_id" {
  value = vsphere_distributed_virtual_switch.supervisor_dvs.id
}
