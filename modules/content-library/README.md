# `content-library` module (optional — TKG workload clusters)

Subscribes to VMware's public TKG content library. Required only if
you want to spawn **TKG / VKS workload clusters** on top of the
Supervisor (Path B from the runbook). For the basic Supervisor-only
deploy (Path A), this module is unused.

## Why it exists

The Supervisor's vSphere Kubernetes Service (VKS) needs OVA templates
of kubeadm-based K8s nodes to clone when provisioning workload
clusters. VMware publishes those templates as items in a *subscribed
content library*. Without an attached library, the VKS service will
fail signature verification (we saw this in Phase 8 — the
"8 of 9 conditions completed" wizard error mentioning
`tkg.vsphere.vmware.com signature verification not found`).

## How to wire it in

Add to your root `main.tf` (not enabled by default):

```hcl
module "tkg_library" {
  source = "./modules/content-library"

  datacenter_id = data.vsphere_datacenter.dc.id
  datastore_id  = data.vsphere_datastore.nfs_shared.id
  library_name  = "tkg-content"
  auto_sync     = false   # save disk; on-demand pull
}
```

After Terraform creates the subscribed library, you still need to:

1. **Activate the VKS service** on the Supervisor (vSphere UI →
   Workload Management → Services → Add → vSphere Kubernetes Service).
   Pick this library on activation.
2. **Attach the library + VM classes to each vSphere Namespace** that
   should host workload clusters.
3. `kubectl apply` a `Cluster` (Cluster API kind) resource — see the
   "Wizard Quick Reference" appendix in `SUPERVISOR-INSTALL.md` for
   the YAML schema.

The VKS service activation, namespace attachment, and Cluster apply
are deliberately out of scope for this module — they're per-namespace
operations that are easier to do once than to keep declarative across
many namespaces.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `datacenter_id` | string | — | |
| `datastore_id` | string | — | Datastore where library blobs cache. Use `nfs-shared`. |
| `library_name` | string | `tkg-content` | |
| `subscription_url` | string | `https://wp-content.vmware.com/v2/latest/lib.json` | VMware's public TKG catalog. Check VKS release notes for the current URL. |
| `auto_sync` | bool | `false` | If false, items are pulled on-demand (saves disk). |

## Outputs

| Name | Description |
|---|---|
| `library_id` | Content library ID — referenced when activating VKS service |
| `library_name` | Library name as shown in the vSphere UI |
