# Supervisor cluster — Terraform module

Terraform module that reproduces the Supervisor cluster bring-up
documented in [`../SUPERVISOR-INSTALL.md`](../SUPERVISOR-INSTALL.md).
Encodes every settled-on workaround (NTP on the physical host,
security flags on outer port groups, supervisor-dvs with two uplinks
per host and pinned teaming policy, HAProxy with the correct
systemd flag + VIPs claimed on `ens192`).

## What this manages

```
✓ Outer vSwitches + port groups (when create_outer_networking=true)  (physical-network)
✓ Nested ESXi VM build + install via custom ISO w/ kickstart         (nested-esxi)
✓ Physical host NTP                                                  (host-config)
✓ "VM Network" + "outer-mgmt-net" security flags = Accept            (host-config)
✓ supervisor-dvs DVS                                                 (network)
✓ sup-mgmt + sup-workload port groups w/ teaming policy              (network)
✓ Two uplinks (vmnic1+vmnic2) per nested host on DVS                 (network)
✓ HAProxy VM deploy + cloud-init + setup script + VIPs               (haproxy)
✓ NFS storage VM deploy + cloud-init + share                         (nfs)
✓ Tag-based storage policy targeting nfs-shared                      (supervisor)
✓ Supervisor enable via govc API call                                (supervisor)
✓ Clean disable via destroy provisioner                              (supervisor)
✗ vCenter / physical ESXi initial install                            (out of scope — one-shot)
✗ Nested ESXi → Supervisor-Cluster join                              (TODO — separate module)
✗ Subscribed content library for TKG workload clusters               (optional follow-up)
```

### Default mode (use existing infrastructure)

The default `terraform apply` assumes the outer port groups (`outer-mgmt-net`
on DSwitch, `VM Network` on vSwitch1) and the 3 nested ESXi hosts
(`192.168.3.241-243`) already exist. This matches our actual lab, where
those were created manually before Terraform.

### Vanilla mode (full bring-up)

For a fresh vCenter deploy with just the physical host added:

```hcl
# in terraform.tfvars
create_outer_networking      = true           # build outer vSwitches + port groups
outer_vm_network_portgroup   = "outer-workload-net"
outer_dswitch_portgroup      = "outer-mgmt-net"

build_nested_esxi            = true           # build + install 3 nested ESXi VMs
source_iso_path              = "/path/to/VMware-VMvisor-Installer-9.0.2.iso"
nested_esxi_root_password    = "..."          # in secrets.auto.tfvars
```

The still-missing piece is "join the nested hosts to a
Supervisor-Cluster" — currently you do that manually in vCenter
after the nested-esxi module finishes installing them.

## Layout

```
terraform/
├── README.md              ← this file
├── versions.tf            ← provider requirements (terraform-provider-vsphere)
├── variables.tf           ← all inputs
├── main.tf                ← composition (calls each module)
├── outputs.tf
├── scripts/
│   └── preflight-check.sh ← run BEFORE apply — catches issues that would fail apply silently
├── modules/
│   ├── physical-network/  ← OPTIONAL — outer vSwitches + port groups (for vanilla vCenter)
│   ├── nested-esxi/       ← OPTIONAL — build + deploy 3 nested ESXi VMs with embedded kickstart
│   ├── host-config/       ← Physical host NTP + outer port-group security  (Phases 1, 8, 10)
│   ├── network/           ← supervisor-dvs, sup-mgmt, sup-workload, uplinks, teaming  (Phases 8.0a, 9)
│   ├── haproxy/           ← HAProxy VM + Dataplane API + VIP claiming  (Phases 7.B, 10, 11)
│   ├── nfs/               ← NFS storage VM  (Phase 6)
│   ├── supervisor/        ← Storage policy + Supervisor enable + clean destroy  (Phases 8.0b, 8.2)
│   └── content-library/   ← OPTIONAL — subscribed TKG content library for workload clusters
└── examples/
    └── lab/
        ├── main.tf                  ← example consuming the modules
        └── terraform.tfvars.example ← copy to terraform.tfvars, fill in real values
```

Each module has its own `README.md` documenting inputs, outputs, and
which runbook phase it implements.

## Top-level Makefile

A `Makefile` at the repo root wraps the common operations:

```
make help          # show all targets
make preflight     # run preflight checks
make apply         # preflight + terraform apply
make destroy       # terraform destroy (disables Supervisor cleanly)
make state         # quick health snapshot via sv-state
make pdf           # rebuild the engineering-summary PDF
```

## Prerequisites

- Terraform ≥ 1.6
- govc on the local machine (used by the `supervisor` module for
  `namespace.cluster.enable`)
- `pyvmomi` (`pip3 install pyvmomi`) for the DVS uplink edits that
  govc can't do
- The nested ESXi hosts already in a cluster called `Supervisor-Cluster`
- A vCenter SSO account with cluster + network admin
- A network with WAN access for the HAProxy and NFS VMs to bootstrap
- An NTP server reachable from the physical ESXi host (e.g.
  `162.159.200.1` = `time.cloudflare.com`)

## Usage

```bash
cd terraform/examples/lab

# 1. Set credentials. Don't commit terraform.tfvars with secrets.
cat > secrets.auto.tfvars <<EOF
vcenter_username = "administrator@vsphere.local"
vcenter_password = "<SSO admin password>"
haproxy_password = "<password used for both ubuntu user and dataplaneapi admin>"
EOF
chmod 600 secrets.auto.tfvars

# 2. Initialize providers
terraform init

# 3. Preview
terraform plan

# 4. Apply (creates everything ~20-30 min including Supervisor enable)
terraform apply
```

## What still needs you to click

- **vSphere Namespace creation** — Supervisor only exposes namespaces
  to users with SSO group membership; modelling RBAC in Terraform is
  possible but tedious. After `terraform apply` finishes, go to
  Workload Management → Namespaces → New Namespace.
- **TKG content library subscription** — included as commented-out
  example in `modules/supervisor/library.tf` but not enabled by
  default (you may not need TKG workload clusters).
- **vSphere SSO user/group permissions** on the new Supervisor —
  inherit from the cluster's permissions in our lab; tighten for
  production.

## Re-running and idempotence

Terraform's state is per-environment. After the first `apply`, running
`terraform plan` again should show no changes if nothing drifted.
Common drift sources:

- HAProxy `dataplaneapi` rewrote `dataplaneapi.yaml` (Root Cause #10).
  The cloud-init writes the correct file; if the running dataplaneapi
  has already corrupted it, run `./scripts/fix-dataplaneapi.sh` or
  redeploy the VM (`terraform taint module.haproxy.vsphere_virtual_machine.haproxy`).
- Manual ARP-claim of additional VIPs (`ip addr add`) — Terraform
  doesn't manage live network state inside the VM. Always
  re-apply the netplan file if you've added more VIPs.

## When to use this vs the runbook

The runbook is for first-time, exploratory deploys where you want to
see *why* each step is needed. This module is for re-deploys or
templated multi-env rollouts. They're complementary: the module's
inline comments link to runbook phases (e.g. `# See Phase 11 in
SUPERVISOR-INSTALL.md`) so you can dive deeper if a phase ever fails.
