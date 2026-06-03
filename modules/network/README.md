# `network` module

Creates the **supervisor-dvs** Distributed Virtual Switch and the two
port groups (`sup-mgmt`, `sup-workload`) that Supervisor needs.

Encodes the Phase 9 lesson: management and workload must be on
different physical paths. We use a single DVS with two uplinks per
host (`vmnic1` for workload, `vmnic2` for management), and pin each
port group to a specific uplink via teaming policy.

| Resource | Phase | Purpose |
|---|---|---|
| `vsphere_distributed_virtual_switch.supervisor_dvs` | 8.0a | DVS spanning the nested ESXi hosts, with vmnic1+vmnic2 from each as uplinks |
| `vsphere_distributed_port_group.sup_workload` | 8.0a, 9 | Port group for workload traffic, active uplink pinned to uplink1 (vmnic1) |
| `vsphere_distributed_port_group.sup_mgmt` | 9 | Port group for management traffic, active uplink pinned to uplink2 (vmnic2) |

## Prerequisites (must be true before applying this module)

- Each nested ESXi VM already has 3 vNICs (vmnic0 + vmnic1 + vmnic2).
  Adding the third vNIC is a one-shot setup task — see Phase 9 of the
  runbook for the `govc vm.network.add` + power-cycle commands.
- Outer port groups (`VM Network`, `dswitch-vm`) already exist and
  have all three security flags = Accept (handled by the `host-config`
  module).

## Inputs

| Name | Type | Description |
|---|---|---|
| `datacenter_id` | string | Datacenter inventory ID |
| `cluster_id` | string | Supervisor cluster inventory ID |
| `nested_hosts` | any (map of vsphere_host data sources) | The 3 nested ESXi hosts to add to the DVS |
| `outer_vm_network_id` | string | ID of the outer VM Network port group |
| `outer_dswitch_vm_id` | string | ID of the outer dswitch-vm port group |
| `vcenter_*` | various | passthrough for any provisioners needing govc |

## Outputs

| Name | Description |
|---|---|
| `sup_mgmt_portgroup_id` | Port group ID for sup-mgmt (used as wizard input by the `supervisor` module) |
| `sup_workload_portgroup_id` | Port group ID for sup-workload |
| `dvs_id` | DVS ID itself |
