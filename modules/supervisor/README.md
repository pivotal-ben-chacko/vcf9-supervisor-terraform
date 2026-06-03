# `supervisor` module

Creates the **tag-based storage policy** that points at `nfs-shared`,
then submits the **Supervisor enable** spec to vCenter via govc.

Wraps Phases 8.0b (storage policy) and 8.2 (the wizard "Finish" step).

## What it does

1. Creates `vsphere_tag_category` ("supervisor") + `vsphere_tag`
   ("supervisor-nfs") + `vsphere_tag_assignment` (attaches the tag to
   the `nfs-shared` datastore)
2. Creates a `vsphere_vm_storage_policy` whose rule says "datastores
   tagged supervisor-nfs"
3. Renders the namespace.cluster.enable JSON spec via `jsonencode()`
4. Submits it via `govc namespace.cluster.enable -cluster <name> -spec @file.json`
5. Polls every 30s for up to 45 min for `config_status` to reach `RUNNING`
6. On `terraform destroy`: calls `govc namespace.cluster.disable`, then
   bounces wcp (which is usually required to actually move state), then
   polls until `GONE`

## Important caveats

- **The enable spec schema drifts between vSphere versions.** The
  layout in `main.tf` targets vSphere 9.0.2. If you get a 4xx
  ("invalid spec"), check the current shape with:
  ```
  govc namespace.cluster.enable -h
  ```
  or refer to VMware's REST API docs under
  *Namespace Management Clusters Enable*.
- **The enable is idempotent.** If Supervisor is already `RUNNING` or
  `CONFIGURING`, the apply skips re-enabling. To force a re-enable,
  `terraform taint` the `null_resource.supervisor_enable` and apply
  again (after manually `sv-disable`'ing first).
- **The destroy provisioner uses `expect` to bounce wcp** because
  `service-control --restart wcp` is sometimes a soft no-op (see Root
  Cause #4). It's a best-effort step; if it fails, the disable may
  hang and need manual cleanup via `sv-wcp-restart`.

## Inputs

A lot — see `main.tf`. The key ones:

| Name | Description |
|---|---|
| `cluster_id` / `cluster_name` | the Supervisor cluster |
| `management_network` / `management_starting_ip` / `management_gateway` / `management_dns` | management network spec |
| `workload_network` / `workload_ip_range` / `workload_gateway` / `workload_dns` | workload network spec |
| `haproxy_endpoint` / `haproxy_user` / `haproxy_password` / `haproxy_cert_path` | Load balancer spec |
| `vip_pool` | VIP pool CIDR |
| `control_plane_size` / `control_plane_ha` | sizing |
| `k8s_service_cidr` / `k8s_pod_cidr` | cluster-internal CIDRs |

## Outputs

| Name | Description |
|---|---|
| `storage_policy_id` | ID of the storage policy created |
| `enable_spec_path` | Filesystem path of the generated enable spec JSON (useful for debugging) |
