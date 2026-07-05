# Terraform Deployment in a Nutshell

A from-zero explanation of what this repo's Terraform does, how it does
it, why each step exists, and every network/naming assumption baked in.
Written for someone using Terraform for the first time.

---

## 1. What is Terraform?

Terraform is a tool that builds infrastructure from a **written
description** instead of clicks. You describe the *end state* you want
("a VM named `haproxy` with IP 192.168.3.245 exists"), and Terraform
figures out what to create, change, or delete to get there.

Three ideas carry the whole tool:

1. **Declarative config** — `.tf` files say *what* should exist, not
   *how* to make it. Terraform computes the "how".
2. **Providers** — plugins that know how to talk to a platform. We use
   the `vmware/vsphere` provider, which speaks the vCenter API. When
   the config can't be expressed as a provider resource, we shell out
   (see §4).
3. **State** — a file (`terraform.tfstate`) recording what Terraform
   built and every ID it got back. State is how Terraform knows the
   difference between "needs creating" and "already exists".

The workflow loop:

```
   .tf files          terraform plan               terraform apply
  (desired state) ──► compare desired vs ──► diff ──► make the changes ──► state file
        ▲             actual (refresh from            (create/update/       (records reality)
        │             vCenter + state file)            delete)                    │
        └──────────────────── you edit, re-plan, re-apply ────────────────────────┘
```

Key consequences for daily use:

- **`plan` is free** — it only reads. Run it any time to see drift
  (differences between config and the real environment).
- **`apply` is idempotent** — running it twice does nothing the second
  time if nothing changed. "No changes. Your infrastructure matches
  the configuration." is the healthy steady state.
- **`destroy` walks the graph backwards** — deletes everything in
  reverse dependency order (and here, first disables the Supervisor
  cleanly via a destroy-time hook).
- **State is precious and secret** — `terraform.tfstate` contains
  every password Terraform ever saw. It's gitignored; never commit it.

**Modules** are folders of `.tf` files used like functions: inputs
(variables) in, resources created, outputs returned. This repo is one
**root module** (repo root) composed of eight **child modules**
(`modules/*`), consumed by a tiny **example** (`examples/lab`) that
supplies the lab's real values.

```
examples/lab/main.tf                 ← the values (IPs, names, sizes)
   └── module "supervisor_lab"  →  repo root main.tf   ← the wiring
          ├── module "physical-network"   (optional)
          ├── module "host-config"
          ├── module "network"
          ├── module "nested-esxi"        (optional, via examples/lab)
          ├── module "nfs"
          ├── module "haproxy"
          ├── module "content-library"    (optional)
          └── module "supervisor"
```

---

## 2. What this Terraform builds (the big picture)

Goal: a vSphere **Supervisor** (Kubernetes embedded in vSphere) on a
single physical ESXi host, using three *nested* ESXi VMs as the
"cluster" Supervisor requires. Everything sits on two subnets routed
by an EdgeRouter:

```
                     192.168.1.0/24 (LAN1 — your Mac)
                              │
                        ┌─────┴──────┐
                        │ EdgeRouter │  gateways: .1.1 / .2.1 / .3.1
                        └──┬─────┬───┘
            ┌──────────────┘     └───────────────────┐
   192.168.2.0/24  MANAGEMENT            192.168.3.0/24  WORKLOAD
   │                                     │
   │  vCSA (vCenter)   .2.80             │  nested ESXi   .3.241/.242/.243
   │  physical ESXi    .2.75             │  nfs-storage   .3.244   ─┐
   │  Supervisor CP    .2.231–.235       │  haproxy       .3.245    ├─ built by
   │  host mgmt vmks   .2.241–.243       │  VIP pool      .3.249–254┘  Terraform
   └───────────────                      │  workload IPs  .3.201–.230
                                         └───────────────
```

What Terraform creates on that foundation, in dependency order:

```
 [look up existing inventory]                (data sources — read-only)
        │
        ▼
 [host-config]  NTP on physical host + security flags on outer port groups
        │
        ├─────────────► [network]   supervisor-dvs + port groups + teaming
        │                    │
        ├──► [nfs]      NFS VM + nfs-shared datastore on all 3 hosts (tagged)
        │                    │
        ├──► [haproxy]  HAProxy VM + Dataplane API + VIPs + self-test
        │                    │
        ▼                    ▼
 [supervisor]   storage policy → enable-spec JSON → REST "enable" → poll to RUNNING
```

---

## 3. Exactly what each module does (and why)

### Data sources (root `main.tf`) — read, never create

Terraform looks up existing objects **by name** and fails fast if any
is missing: datacenter `Datacenter`, clusters `Cluster` (physical) and
`Supervisor-Cluster` (nested), host `192.168.2.75`, the three nested
hosts, datastore `datastore1`, and port groups `VM Network` +
`outer-mgmt-net`. *Why:* HAProxy/NFS VMs land on the physical host's
resources; the Supervisor lands on the nested cluster.

### `physical-network` (optional — `create_outer_networking = true`)

Creates two standard vSwitches (`outer-mgmt-vsw` on vmnic4,
`outer-workload-vsw` on vmnic5) and their port groups, with all
security flags Accept. *Why:* only for a virgin vCenter. Our lab
already had `VM Network`/`DSwitch` built by hand, so this is **off**
and the data sources above find the existing ones instead.

### `host-config` — fixes encoded from painful debugging

1. **NTP on the physical host** (govc): sets server `162.159.200.1`,
   enables + starts `ntpd`. *Why:* the host shipped with NTP off, the
   clock drifted ~58 min, vCSA inherited the drift, and every TLS
   handshake to the Supervisor failed *silently* (runbook Root Cause
   #3 — the single most insidious failure).
2. **Security flags → Accept** on `VM Network` (govc) and
   `outer-mgmt-net` (pyvmomi). *Why:* nested ESXi forwards frames
   whose source MAC belongs to an inner VM, not to the host's own
   vNIC. With Forged Transmits = Reject, the outer switch silently
   drops them (Root Causes #1/#9). pyvmomi is used for the DVS port
   group because govc has no command for DVS port-group security.

### `network` — the inner (nested-cluster) networking

Creates on the nested cluster:

- **`supervisor-dvs`** — a Distributed Virtual Switch spanning all 3
  nested hosts, with each host contributing `vmnic1` + `vmnic2`.
- **`sup-workload`** port group — teaming pinned to **uplink1**
  (vmnic1 → outer `VM Network` → 192.168.3.x).
- **`sup-mgmt`** port group — pinned to **uplink2** (vmnic2 → outer
  `outer-mgmt-net` → 192.168.2.x).
- **`sup-host-mgmt`** port group + one **vmkernel NIC per host**
  (192.168.2.241–243). *Why:*
  spherelet (the ESXi kubelet) must reach the Supervisor control
  plane's floating management IP; without a management-subnet vmk the
  path is asymmetric and strict rp_filter on the CP VMs drops it (see
  TROUBLESHOOTING.md, "Supervisor ESXi nodes never join").

*Why the pinning:* the Supervisor wizard demands management and
workload on **different subnets** (two NICs on one subnet made the CP
VM route DNS replies out the wrong interface — Root Cause #6). The
teaming pins guarantee sup-mgmt traffic can only exit toward
192.168.2.x and sup-workload toward 192.168.3.x.

### `nested-esxi` (optional — `build_nested_esxi = true`)

Builds the three nested ESXi VMs from the installer ISO: renders a
per-host kickstart (static IP, **unique hostname** — critical, see
TROUBLESHOOTING.md cert issue), repacks a boot ISO per host, uploads
it, creates the VMs, and lets the unattended install run. *Why
optional:* the lab's hosts were hand-built before this existed; a
fresh environment can turn it on.

### root `main.tf` — the storage tag

Creates tag category `supervisor` + tag `supervisor-storage`. *Why at
the root:* the nfs module attaches the tag (needs its ID) and the
supervisor module builds a policy from its name — putting it in either
module would create a dependency cycle.

### `nfs` — shared storage (Supervisor requires it on every host)

1. Deploys VM **`nfs-storage`** from the Ubuntu 24.04 cloud OVA with
   cloud-init: static IP 192.168.3.244, formats the second 200 GB disk
   as XFS at `/srv/nfs/shared`, installs `nfs-kernel-server`, exports
   `*(rw,sync,no_subtree_check,no_root_squash,insecure)`
   (`no_root_squash` because ESXi mounts as root; `insecure` because
   ESXi uses high source ports).
2. Waits until `showmount` sees the export (cloud-init takes minutes;
   mounting too early fails).
3. Mounts it on all three nested hosts as datastore **`nfs-shared`**
   and attaches the `supervisor-storage` tag.

*Why a separate VM:* local datastores differ per host; Supervisor
wants the *same* datastore everywhere for CP VMs and image cache, and
putting the share on a nested host creates a boot dependency loop.

### `haproxy` — the load balancer the Supervisor requires

1. Generates a **self-signed TLS cert** locally (openssl, SAN =
   192.168.3.245) — the Supervisor pins this cert.
2. Deploys VM **`haproxy`** from the Ubuntu OVA. Cloud-init writes
   everything: netplan with the primary IP **and all six VIPs as /32
   addresses on `ens192`**, `haproxy.cfg`, `dataplaneapi.yaml`,
   downloads Dataplane API **v2.9.25**, and installs a systemd unit
   using the **`-f` flag**.
3. Validates end-to-end: polls `https://.245:5556/v2/info`, performs a
   real test transaction commit, then pings every VIP.

*Why so specific:* three of the runbook's root causes live here.
`--config-file=` instead of `-f` makes dataplaneapi eat its own config
(RC #10); VIPs that are only *bound* but not *claimed* on the
interface never answer ARP, so traffic blackholes (RC #11); v2.9.10
had a YAML-rewriting bug (hence ≥ 2.9.25). The validation step exists
so a regression fails the apply instead of surfacing days later as
`EXTERNAL-IP: <pending>`.

### `supervisor` — turning it all on

1. **Storage policy** `supervisor-storage`: tag-based, resolves to
   whatever datastore carries the tag (= `nfs-shared`). *Why:* the
   Supervisor API takes policies, not datastore names.
2. **Renders `enable-spec.json`** — the exact JSON the vSphere
   "Workload Management" wizard would submit: cluster size TINY,
   networks (sup-mgmt / sup-workload port-group IDs), IP ranges,
   service CIDR, the HAProxy endpoint + user + password + pinned cert,
   VIP range, and the storage policy ID everywhere.
3. **Calls the vCenter REST API** (`POST /api/vcenter/namespace-management/clusters/{id}?action=enable`)
   and polls status up to 45 min until `RUNNING`. *Why REST and not
   the provider or govc:* the provider has no Supervisor resource, and
   govc 0.54's enable only supports NSX-T, not HAProxy.
4. **Destroy hook:** on `terraform destroy`, first submits
   `?action=disable` and waits for the Supervisor to be fully gone.
   *Why:* otherwise destroy would rip the storage policy out from
   under running control-plane VMs and fail.

### `content-library` (optional)

Subscribes a `tkg-content` library to VMware's public catalog — only
needed later for TKG/VKS workload clusters.

---

## 4. How Terraform acts: two mechanisms, one graph

**Native resources** (preferred): `vsphere_virtual_machine`,
`vsphere_distributed_virtual_switch`, `vsphere_nas_datastore`,
`vsphere_tag`, `vsphere_vm_storage_policy`, `vsphere_vnic`… The
provider creates them, tracks their IDs in state, detects drift, and
can delete them.

**Escape hatches** (`null_resource` + `local-exec`): shell scripts run
*on your machine* during apply, used only where the provider has no
resource type — govc for NTP/service control/power-on, pyvmomi for DVS
port-group security, curl for the Supervisor REST enable/disable, and
openssl for the cert. *Why it matters to you:* these run through
*your* shell, so the machine running `terraform apply` needs govc,
python3+pyvmomi, curl, jq, and openssl installed (that's what
`make install-deps` sets up), and they only re-run when their
`triggers` change — not on every apply.

Everything, native or scripted, hangs off one **dependency graph**
(`depends_on` + variable references), which is why order is
guaranteed: host-config → network/nfs/haproxy → supervisor.

---

## 5. Prerequisites

**On your workstation** (macOS or Linux — `make install-deps` installs
the tools):

| Tool | Used for |
|---|---|
| Terraform ≥ 1.6 | everything |
| govc | NTP, power-on, port-group flags, service control |
| python3 + pyvmomi | DVS security flags (govc gap) |
| curl + jq | Supervisor REST enable, Dataplane API validation |
| openssl | Dataplane API TLS cert + password hash |
| showmount | waiting for the NFS export |

**Already existing in vSphere** (Terraform looks these up, it does not
create them — default mode):

- vCenter (`vcenter.skynetsystems.io`) reachable on 443 with an SSO
  admin account
- Datacenter `Datacenter`; cluster `Cluster` containing physical host
  `192.168.2.75`; cluster `Supervisor-Cluster` containing the three
  nested hosts (joined, connected)
- Datastore `datastore1` on the physical host
- Outer port groups `VM Network` (vSwitch1/vmnic5) and
  `outer-mgmt-net` (DSwitch/vmnic4)
- Each nested ESXi has **three vNICs** (vmnic0/1/2 — vmnic2 is the
  management bridge)

**Network/environment:**

- EdgeRouter routes between LAN1/LAN2/LAN3 and serves DNS (192.168.1.1)
- WAN egress from the workload subnet (Ubuntu OVA + Dataplane API
  binary are downloaded at deploy time)
- Clocks sane everywhere (`make clocks` / `scripts/sv-fix-ntp`)
- `vcenter.skynetsystems.io` must resolve to **192.168.2.80** from
  your machine. Gotcha: the *public* DNS zone CNAMEs this name to the
  apex domain, which poisons macOS resolution via the AAAA path — we
  pin it in `/etc/hosts` (see TROUBLESHOOTING.md, DNS section)
- `examples/lab/secrets.auto.tfvars` (gitignored, chmod 600) with
  `vcenter_username`, `vcenter_password`, `vcenter_ip`,
  `haproxy_password`

**Run it:**

```bash
make sync-config   # only after editing wcp-config-Skynet.json
make hard-check    # verify the static prereqs above
make init plan     # review
make apply         # ~25 min unattended, including Supervisor enable
make verify        # post-apply health checks
```

---

## 6. Every assumption in one place

### Subnets & CIDR ranges

| What | Value | Where defined |
|---|---|---|
| Management subnet | `192.168.2.0/24`, gw `192.168.2.1` | JSON → `config.auto.tfvars` |
| Workload subnet | `192.168.3.0/24`, gw `192.168.3.1` | JSON → `config.auto.tfvars` |
| Supervisor CP IPs (mgmt) | `192.168.2.231` + next 4 (floating `.231`) | `management_cp_starting_ip` |
| Workload IP range | `192.168.3.201–230` (CP eth1, pod VMs) | `workload_ip_range` |
| VIP pool | `192.168.3.248/29` → usable `.249–.254` | `vip_pool`, `vip_pool_usable` |
| K8s Services CIDR | `10.96.0.0/23` (internal only) | `k8s_service_cidr` |
| K8s Pods CIDR | `10.244.0.0/20` (internal only) | `k8s_pod_cidr` default |
| EdgeRouter DHCP (LAN3) | `.4–.200` — everything above must stay outside it | router config |

### Fixed IPs

| Host | IP | Notes |
|---|---|---|
| vCenter (vCSA) | `192.168.2.80` | FQDN `vcenter.skynetsystems.io` |
| Physical ESXi | `192.168.2.75` | inventory name = this IP |
| Nested ESXi | `192.168.3.241/.242/.243` | inventory names = these IPs |
| Host mgmt vmks | `192.168.2.241/.242/.243` | `nested_host_mgmt_ips` |
| nfs-storage VM | `192.168.3.244` | `nfs_ip` |
| haproxy VM | `192.168.3.245` | `haproxy_ip` |
| DNS (both subnets) | `192.168.1.1` | `management_dns` / `workload_dns` |
| NTP | `162.159.200.1` (time.cloudflare.com) | `ntp_servers` |

### Ports

| Port | Between | Purpose |
|---|---|---|
| 443/tcp | workstation → vCenter | provider API + REST enable |
| 443/tcp | clients → VIPs `.250/.251` | plugin download, HTTPS redirect |
| 6443/tcp | kubectl/spherelet → API VIP; vCenter → CP `.2.231` | Kubernetes API |
| 5556/tcp | vCenter → haproxy `.245` | Dataplane API (basic auth + pinned TLS) |
| 2112/2113/tcp | → VIP | vSphere CSI controller/syncer |
| 2049, 111 tcp+udp; 20048/tcp | nested hosts → `.244` | NFS v3 + rpcbind + mountd |
| 22/tcp | workstation → VMs/vCSA | SSH (diagnostics) |
| 123/udp | hosts/vCSA → NTP | clock sync — silently fatal if broken |
| 53/udp | CP VM → `192.168.1.1` | wizard's DNS validation |

### Names Terraform assumes or creates

| Name | Kind | Created by Terraform? |
|---|---|---|
| `Datacenter`, `Cluster`, `Supervisor-Cluster` | inventory | no — must exist |
| `datastore1` | datastore | no — must exist |
| `VM Network`, `outer-mgmt-net`, `DSwitch` | outer networking | no (unless `create_outer_networking`) |
| `supervisor-dvs`, `sup-mgmt`, `sup-workload`, `sup-host-mgmt` | inner networking | **yes** |
| `nfs-storage`, `haproxy` VMs; `nfs-shared` datastore | compute/storage | **yes** |
| `supervisor` category, `supervisor-storage` tag + policy | storage policy | **yes** |
| `haproxy-lab` | LB id inside Supervisor | **yes** (enable spec) |
| `nested-esxi-1/2/3.skynetsystems.io` | ESXi hostnames | yes if `build_nested_esxi`; else set manually — **must be unique**, never `localhost` |

---

## 7. When the foundation changes — what to edit

**Rule 1: `wcp-config-Skynet.json` is the source of truth** for
subnets, gateways, DNS, IP ranges, VIP pool, HAProxy endpoint, service
CIDR, cluster name, and vCenter host. After editing it:

```bash
make sync-config    # regenerates examples/lab/config.auto.tfvars + haproxy-dpapi.crt
make plan           # review what re-converges
make apply
```

Never edit `config.auto.tfvars` directly — it's overwritten.

**Rule 2: lab facts not in the JSON** live in `examples/lab/main.tf`
(physical host name/cluster, nested host list, `outer_datastore`,
`ntp_servers`, `nfs_ip`, `create_outer_networking`, nested-esxi
`hosts` list) and root `variables.tf` defaults (VM names, NFS share
size/path, Dataplane API version, Ubuntu OVA URL,
`nested_host_mgmt_ips`).

**Rule 3: secrets** only ever go in `examples/lab/secrets.auto.tfvars`.

Common scenarios:

| Change | Touch |
|---|---|
| **Workload subnet moves** (e.g. → 192.168.30.0/24) | JSON (subnet, gw, DNS, `workload_ip_range`, VIP pool, HAProxy IP) → `make sync-config`; `nfs_ip` in examples/lab; EdgeRouter DHCP + routing; **nested host inventory names are their IPs** — hosts re-IP'd means updating `nested_esxi_hosts` and re-joining vCenter |
| **Management subnet moves** | JSON (mgmt subnet/gw/DNS, `management_cp_starting_ip`) → sync-config; `nested_host_mgmt_ips`; vCSA + physical host have their own IPs outside Terraform |
| **vCenter IP/name changes** | JSON `vcenter_server`; `vcenter_ip` in secrets; `/etc/hosts` pin; `scripts/sv-env` |
| **Different physical host / datastore** | `physical_host_name`, `physical_host_cluster`, `outer_datastore` in examples/lab |
| **DNS server changes** | JSON `management_dns` / `workload_dns` → sync-config |
| **VIP pool grows** | JSON `vip_pool` + usable list → sync-config → apply (haproxy cloud-init changes → VM is **replaced**; netplan claims the new /32s) |
| **HAProxy/DPAPI password rotate** | `secrets.auto.tfvars` → apply (spec re-submits; VM cloud-init replacement) |

Two behaviors to expect after foundation changes:

1. Anything that alters a VM's **cloud-init** (IPs, passwords, VIPs)
   **replaces that VM** — cloud-init only runs at first boot. Terraform
   will show `must be replaced`; that's correct, not an error.
2. Anything that alters the **enable spec** re-runs the Supervisor
   enable step. It exits early ("already RUNNING") without touching a
   healthy cluster, but a changed spec on a *live* Supervisor is not
   re-applied by vSphere — some settings (subnets, CIDRs) can only
   change via disable/re-enable (`make destroy` → `make apply`).

---

## 8. What Terraform deliberately does NOT manage

- vCenter and the physical ESXi install (one-shot, out of scope)
- Joining nested hosts to `Supervisor-Cluster` (manual today)
- EdgeRouter (routing, DHCP ranges, DNS records)
- vSphere Namespaces + SSO RBAC (click in Workload Management)
- Live guest-OS state: the CP VMs' `rp_filter` workaround (volatile —
  see TROUBLESHOOTING.md) and any manually added VIP claims
- Rotation of the CP VM root password (vSphere rotates it on
  enable/disable cycles; fetch with `scripts/sv-cp-pwd`)
