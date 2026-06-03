terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
  }
}

###############################################################
# physical-network module
#
# Creates the outer networking layout on the *physical* ESXi host —
# the part our existing modules previously referenced as `dswitch`,
# `dswitch-vm`, and `vSwitch1`/`VM Network`.
#
# Uses standard vSwitches (vSS), NOT a DVS — there's only one
# physical host, so a DVS adds complexity without a benefit. All
# port groups have promiscuous / forged-transmits / MAC-changes
# Accept so nested-ESXi VMs running on top can pass arbitrary
# source MACs.
#
# Resources created:
#   - vsphere_host_virtual_switch.outer_mgmt       (vSS on one pNIC)
#   - vsphere_host_virtual_switch.outer_workload   (vSS on another pNIC)
#   - vsphere_host_port_group.outer_mgmt           (PG on outer-mgmt-vsw)
#   - vsphere_host_port_group.outer_workload       (PG on outer-workload-vsw)
#
# Names are variables; defaults are listed in the table below.
###############################################################

variable "physical_host_id" {
  description = "Inventory ID of the physical ESXi host (use data.vsphere_host)."
  type        = string
}

variable "mgmt_switch_name" {
  description = "Name of the standard vSwitch that carries management-subnet traffic."
  type        = string
  default     = "outer-mgmt-vsw"
}

variable "mgmt_portgroup_name" {
  description = "Name of the port group for the management subnet."
  type        = string
  default     = "outer-mgmt-net"
}

variable "mgmt_pnic" {
  description = "Physical NIC backing the management vSwitch — typically the one cabled to the management LAN port on the EdgeRouter."
  type        = string
  default     = "vmnic4"
}

variable "workload_switch_name" {
  description = "Name of the standard vSwitch that carries workload-subnet traffic."
  type        = string
  default     = "outer-workload-vsw"
}

variable "workload_portgroup_name" {
  description = "Name of the port group for the workload subnet."
  type        = string
  default     = "outer-workload-net"
}

variable "workload_pnic" {
  description = "Physical NIC backing the workload vSwitch."
  type        = string
  default     = "vmnic5"
}

variable "mtu" {
  description = "MTU for both vSwitches (1500 is standard; 9000 if you're doing jumbo frames)."
  type        = number
  default     = 1500
}

###############################################################
# Standard vSwitch — management
###############################################################

resource "vsphere_host_virtual_switch" "outer_mgmt" {
  name             = var.mgmt_switch_name
  host_system_id   = var.physical_host_id
  network_adapters = [var.mgmt_pnic]
  active_nics      = [var.mgmt_pnic]
  standby_nics     = []
  mtu              = var.mtu

  # Security flags at the switch level. These propagate to port groups
  # by default but we set them explicitly on each port group below too,
  # for clarity.
  allow_promiscuous      = true
  allow_forged_transmits = true
  allow_mac_changes      = true
}

resource "vsphere_host_port_group" "outer_mgmt" {
  name                = var.mgmt_portgroup_name
  host_system_id      = var.physical_host_id
  virtual_switch_name = vsphere_host_virtual_switch.outer_mgmt.name
  vlan_id             = 0

  allow_promiscuous      = true
  allow_forged_transmits = true
  allow_mac_changes      = true
}

###############################################################
# Standard vSwitch — workload
###############################################################

resource "vsphere_host_virtual_switch" "outer_workload" {
  name             = var.workload_switch_name
  host_system_id   = var.physical_host_id
  network_adapters = [var.workload_pnic]
  active_nics      = [var.workload_pnic]
  standby_nics     = []
  mtu              = var.mtu

  allow_promiscuous      = true
  allow_forged_transmits = true
  allow_mac_changes      = true
}

resource "vsphere_host_port_group" "outer_workload" {
  name                = var.workload_portgroup_name
  host_system_id      = var.physical_host_id
  virtual_switch_name = vsphere_host_virtual_switch.outer_workload.name
  vlan_id             = 0

  allow_promiscuous      = true
  allow_forged_transmits = true
  allow_mac_changes      = true
}

###############################################################
# Outputs
###############################################################

output "mgmt_portgroup_name" {
  description = "Name of the management port group — pass to nested-esxi and supervisor modules as outer_dswitch_portgroup."
  value       = vsphere_host_port_group.outer_mgmt.name
}

output "workload_portgroup_name" {
  description = "Name of the workload port group — pass to other modules as outer_vm_network_portgroup."
  value       = vsphere_host_port_group.outer_workload.name
}

# The port groups become vsphere_network data sources (looked up by name)
# downstream. We don't have a direct .id available from the resource —
# the host_port_group resource returns a composite ID, not a MoRef. So
# downstream modules look it up by name.
output "mgmt_switch_name" {
  value = vsphere_host_virtual_switch.outer_mgmt.name
}

output "workload_switch_name" {
  value = vsphere_host_virtual_switch.outer_workload.name
}
