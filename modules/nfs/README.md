# `nfs` module

Deploys the **NFS storage VM** that all 3 nested ESXi hosts mount as
the `nfs-shared` datastore. Encodes Phase 6 of the runbook.

## What it does

1. Deploys the Ubuntu 24.04 cloud OVA with two disks (40 GB OS,
   `share_size_gb` for the share)
2. cloud-init on first boot:
   - configures static IP
   - formats `/dev/sdb` as XFS, mounts at `/srv/nfs/shared`
   - installs `nfs-kernel-server`
   - writes `/etc/exports` with the right options for ESXi (`rw,sync,no_root_squash,insecure`)
   - starts the NFS service

After Terraform apply, you'll need to **manually mount the export
on each nested ESXi host** as a datastore — Terraform doesn't have
a clean resource for this. From the vSphere UI: Host → Datastores →
New Datastore → NFS, or via govc:

```bash
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc datastore.create -type=nfs \
    -name=nfs-shared \
    -remote-host=192.168.3.244 \
    -remote-path=/srv/nfs/shared \
    "/Datacenter/host/Supervisor-Cluster/$h"
done
```

The host-mount step is a candidate for a future `null_resource` in
this module; for now it's left manual because the timing matters
(nfs-kernel-server must be ready before mount; otherwise the host
shows the datastore as inaccessible).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `datacenter_id` | string | — | |
| `cluster_id` | string | — | resource pool / cluster for the VM |
| `datastore_id` | string | — | datastore for the *VM's OS disk* (not the share!) |
| `network_id` | string | — | port group ID (outer VM Network) |
| `vm_name` | string | `nfs-storage` | |
| `ip_addr` | string | `192.168.3.244` | |
| `gateway` | string | — | |
| `dns_servers` | list(string) | — | |
| `share_size_gb` | number | `200` | size of the second disk that becomes the NFS share |
| `share_path` | string | `/srv/nfs/shared` | mount path inside the VM = NFS export path |
| `ubuntu_ova_url` | string | — | |

## Outputs

| Name | Description |
|---|---|
| `nfs_export` | `<ip>:<path>` — pass to ESXi when mounting |
| `nfs_ip` | the NFS server IP |
