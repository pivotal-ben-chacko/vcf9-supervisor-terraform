# `nested-esxi` module

Creates 3 nested ESXi VMs from a stock ESXi installer ISO, fully
unattended via embedded kickstart (`ks.cfg`). Replaces runbook
Phases 2-4 (VM creation + interactive installer + static IP setup).

## How it works

```
For each of the 3 nested ESXi hosts:

  1. Render a per-host ks.cfg via templatefile() — sets hostname,
     static IP, gateway, DNS, root password.

  2. Run scripts/build-iso.sh, which:
     - extracts the stock ESXi ISO
     - drops the rendered ks.cfg in as /KS.CFG on the new ISO
     - patches boot.cfg (BIOS) and efi/boot/boot.cfg (UEFI) to add
       `ks=cdrom:/KS.CFG` to kernelopt — installer auto-loads it
     - re-bundles into a new ISO via xorriso

  3. Upload the customized ISO to the physical host's datastore.

  4. Create a vsphere_virtual_machine with the ISO mounted as CD-ROM.

  5. Wait for the static IP to come up (sign install + first-boot
     completed).

  6. Detach the CD so the next reboot boots from disk, not the
     installer.
```

End result: 3 nested ESXi hosts with static IPs `192.168.3.241/.242/.243`,
SSH enabled, root password set, ready to be joined to a vCenter cluster
by a downstream module.

## Prerequisites

- `xorriso` installed locally (`brew install xorriso` /
  `apt-get install xorriso`)
- A stock ESXi installer ISO on disk (e.g.
  `VMware-VMvisor-Installer-9.0.2-25148076.iso` from Broadcom support)
- `govc` configured (the upload-ISO step uses it)
- The outer port groups (`VM Network`, `dswitch-vm`) already exist —
  these are the same outer port groups the rest of the module uses

## Inputs (key ones)

| Name | Type | Default | Description |
|---|---|---|---|
| `source_iso_path` | string | — | Local path to the stock ESXi ISO |
| `hosts` | list(object) | — | List of `{ name, ip, hostname? }` per nested host |
| `gateway` | string | `192.168.3.1` | Default gateway for the management vmk |
| `dns` | string | `192.168.3.1` | DNS server |
| `netmask` | string | `255.255.255.0` | |
| `root_password` | string (sensitive) | — | ESXi root password |
| `vm_num_cpus` | number | `8` | per VM |
| `vm_memory` | number | `32768` | RAM in MB |
| `vm_disk_size_gb` | number | `80` | per VM |
| `network_id` | string | — | Outer VM Network port group ID (vmnic0 + vmnic1 land here) |
| `network_dswitch_vm_id` | string | — | Outer dswitch-vm port group ID (vmnic2 lands here) |
| `datastore_id` | string | — | datastore ID for the VM disks |
| `datastore_name` | string | — | datastore name (for govc upload) |
| `datacenter` | string | — | datacenter name (for govc paths) |
| `datacenter_id` | string | — | datacenter ID (for data sources) |
| `resource_pool_id` | string | — | resource pool / cluster where VMs land (the *physical* cluster) |

## Outputs

| Name | Description |
|---|---|
| `host_ips` | map host → IP |
| `host_ids` | map host → VM ID (use as `depends_on` anchor) |

## Generated artifacts (gitignored)

```
modules/nested-esxi/generated/
  nested-esxi-1/
    ks.cfg
    esxi.iso       ← ~700 MB per host
  nested-esxi-2/
    ks.cfg
    esxi.iso
  nested-esxi-3/
    ks.cfg
    esxi.iso
```

Each ISO is about the same size as the source (~700 MB). 3 × 700 MB =
~2.1 GB of generated artifacts. Add a `terraform clean` or `make clean`
target if disk space matters.

## Limitations

- **Per-host ISO** — we build 3 separate ISOs because the ks.cfg
  bakes in the IP/hostname. A more elaborate setup could use a
  single ISO + MAC-based identity, but it'd be more complex than the
  whole rest of this module.
- **No PXE option** — pure ISO. If you need PXE bootstrap, that's a
  separate module (DHCP + TFTP).
- **ESXi version pinned by source ISO** — to upgrade, point
  `source_iso_path` at a newer ISO and `terraform apply`. Will trigger
  a full rebuild.
- **First-boot customizations are minimal** — enables SSH and sets
  vSwitch0 security flags. Everything else is handled by downstream
  modules (host-config, network) once the hosts are joined to a
  cluster.

## How to wire it into the example

```hcl
# In examples/lab/main.tf, add:
module "nested_esxi" {
  source = "../../modules/nested-esxi"

  source_iso_path = "/Users/ben/Repos/greylog/VMware-VMvisor-Installer-9.0.2.0.25148076.x86_64.iso"

  datacenter       = "Datacenter"
  datacenter_id    = data.vsphere_datacenter.dc.id
  resource_pool_id = data.vsphere_compute_cluster.physical.resource_pool_id
  datastore_id     = data.vsphere_datastore.physical.id
  datastore_name   = "datastore1"

  network_id            = data.vsphere_network.outer_vm_network.id
  network_dswitch_vm_id = data.vsphere_network.outer_dswitch_vm.id

  root_password = var.nested_esxi_root_password
  hosts = [
    { name = "nested-esxi-1", ip = "192.168.3.241" },
    { name = "nested-esxi-2", ip = "192.168.3.242" },
    { name = "nested-esxi-3", ip = "192.168.3.243" },
  ]
}
```

Then add a downstream `cluster-bootstrap` module (TODO — separate
work) that takes these IPs and joins them to a vCenter cluster.
