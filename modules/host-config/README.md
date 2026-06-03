# `host-config` module

Configures the **physical ESXi host** for nested Supervisor: NTP, plus
security flags on the two outer port groups that nested ESXi VMs use
as their network uplinks.

Wraps three runbook phases:

- Phase 1 — Allow nested traffic on `VM Network` (vSwitch1 standard port group)
- Phase 8 / Root Cause #3 — NTP on the physical host (the most insidious failure mode in this whole project)
- Phase 10 / Root Cause #9 — Security flags on `dswitch-vm` (the DVS port group that backs vmnic2 for management traffic)

All three are implemented via `null_resource` + `local-exec` because
the vSphere provider doesn't expose these settings on *existing*
host port groups / DVS port groups. The NTP step uses govc; the
dswitch-vm security policy uses an embedded pyvmomi script.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `physical_host_id` | string | — | Inventory ID of the physical host (from `data.vsphere_host`) |
| `physical_host_name` | string | — | Name (typically IP) of the physical host |
| `physical_host_cluster` | string | — | Cluster name containing the physical host |
| `outer_vm_network_portgroup` | string | — | Name of the outer VM Network port group on vSwitch1 |
| `outer_dswitch_portgroup` | string | — | Name of the dswitch-vm DVS port group |
| `ntp_servers` | list(string) | — | NTP servers — use IPs to avoid DNS bootstrap problem |
| `vcenter_server` | string | — | vCenter hostname for govc |
| `vcenter_username` | string | — | vSphere SSO username |
| `vcenter_password` | string (sensitive) | — | vSphere SSO password |
| `vcenter_insecure` | bool | — | Skip TLS verification |
| `datacenter` | string | — | Datacenter name |

## Outputs

| Name | Description |
|---|---|
| `ntp_configured` | ID of the null_resource that configured NTP (use as a `depends_on` anchor) |
