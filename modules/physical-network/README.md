# `physical-network` module

Creates the outer L2 networking layout on the **physical** ESXi host
— what the rest of the module previously expected to find via data
sources.

For our existing lab (where this stuff was already created manually
as `dswitch` + `dswitch-vm` + `vSwitch1` + `VM Network`), you don't
need this module. For a **fresh vCenter install** where only the
physical host has been added, this module produces the prerequisites
that the other modules depend on.

## What it creates

Two **standard vSwitches** (not DVS — see "Why no DVS" below) with one
port group each:

| Switch (vSS) | pNIC | Port group | Carries |
|---|---|---|---|
| `outer-mgmt-vsw` | `vmnic4` | `outer-mgmt-net` | 192.168.2.x — management subnet |
| `outer-workload-vsw` | `vmnic5` | `outer-workload-net` | 192.168.3.x — workload subnet |

All names are variables — if you want different conventions or
different pNIC mappings, pass them in.

All port groups have **Promiscuous / Forged Transmits / MAC Changes =
Accept** because nested-ESXi VMs running on top will egress traffic
with their inner VMs' source MACs, not the outer vNIC's MAC.

## Why no DVS

A DVS (Distributed Virtual Switch) exists to keep port-group
configuration consistent across multiple hosts. The outer-physical
side of this lab has only **one** host, so DVS adds complexity (a
vCenter dependency, a more complex API, slower reconfiguration) with
no benefit. Standard vSwitches do everything we need here.

The inner side (the nested ESXi cluster's `supervisor-dvs`) does need
a DVS, because it spans 3 hosts and the Supervisor wizard requires
DVS port groups specifically.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `physical_host_id` | string | — | from `data.vsphere_host` |
| `mgmt_switch_name` | string | `outer-mgmt-vsw` | |
| `mgmt_portgroup_name` | string | `outer-mgmt-net` | |
| `mgmt_pnic` | string | `vmnic4` | physical NIC for mgmt traffic |
| `workload_switch_name` | string | `outer-workload-vsw` | |
| `workload_portgroup_name` | string | `outer-workload-net` | |
| `workload_pnic` | string | `vmnic5` | physical NIC for workload traffic |
| `mtu` | number | `1500` | Switch MTU; bump to 9000 for jumbo frames |

## Outputs

| Name | Description |
|---|---|
| `mgmt_portgroup_name` | Pass downstream as `outer_dswitch_portgroup` |
| `workload_portgroup_name` | Pass downstream as `outer_vm_network_portgroup` |

(Downstream modules look up the port group ID by name via
`data.vsphere_network`. The `vsphere_host_port_group` resource
returns a composite ID, not a MoRef, so we plumb the *name*
through, and the data source resolves it to the MoRef at apply
time.)

## When NOT to use this module

- **Your existing environment already has these port groups** (our
  lab's case). Use data sources to reference them instead. The root
  `main.tf` has `create_outer_networking = false` (default) for this
  path.
- **You're using NSX or some other network virtualization layer** on
  the physical host. Don't add standard vSwitches on top of NSX-T;
  that path is its own architecture.
- **You can't free up `vmnic4` / `vmnic5`** to be claimed by these
  switches. (If those pNICs are already serving traffic elsewhere,
  Terraform will refuse to claim them.) Override the `mgmt_pnic` /
  `workload_pnic` vars to point at unused pNICs instead.

## Migrating from the existing `dswitch` setup

If you already have `dswitch` / `dswitch-vm` working manually and want
to convert to Terraform-managed standard vSwitches:

1. **Don't try to terraform-import the existing DVS.** Resources are
   different kinds (DVS vs standard vSwitch). Trying to import a DVS
   into a `vsphere_host_virtual_switch` resource won't work.
2. The cheapest path is:
   - Bring up the new standard vSwitches (`terraform apply` with
     `create_outer_networking=true` and different pNICs than dswitch
     uses)
   - Migrate VMs onto the new port groups
   - Remove the dswitch manually after nothing is using it
3. The other option is to leave the existing dswitch in place and
   continue using `create_outer_networking=false` + data sources.
   This is what our actual lab does.

## Example

```hcl
data "vsphere_host" "physical" {
  name          = "192.168.2.75"
  datacenter_id = data.vsphere_datacenter.dc.id
}

module "physical_network" {
  source = "./modules/physical-network"

  physical_host_id = data.vsphere_host.physical.id

  # Defaults are fine; override if needed:
  # mgmt_pnic           = "vmnic2"
  # workload_pnic       = "vmnic3"
  # mgmt_portgroup_name = "lab-mgmt"
}
```
