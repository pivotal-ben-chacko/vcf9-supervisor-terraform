<div style="text-align: center; font-size: 13pt; font-weight: bold; color: #FF6600; margin-bottom: 6px;">Fiserv 2026</div>

# vSphere Supervisor on a Single Physical Host — Installation Runbook

Step-by-step install guide for running vSphere Supervisor (Kubernetes) on
a single physical ESXi host using nested ESXi. Each phase has GUI clicks
*and* CLI commands so you can follow either path. Updates as the install
progresses; tagged `[done]`, `[in progress]`, or `[todo]` at each phase.

## Why this exists

vSphere Supervisor officially requires a cluster with at least 3 ESXi
hosts. If you only have one physical host (lab, home, single-server) you
can build a 3-host cluster of *nested* ESXi VMs on the one physical host
and run Supervisor there. Unsupported by VMware, but well-trodden.

```
Physical host (192.168.2.75)
└── Cluster (existing — managed by vCenter, stays as-is)
    ├── nested-esxi-1   (a VM running ESXi)   ┐
    ├── nested-esxi-2   (a VM running ESXi)   ├── new cluster ─ Supervisor enabled here
    └── nested-esxi-3   (a VM running ESXi)   ┘
```

## Final architecture target

```
EdgeRouter (192.168.1.1) ── eth3 → physical pNIC vmnic5 → vSwitch1 → VM Network (192.168.3.0/24)
                                                                          │
                                          ┌───────────────┬───────────────┴───────────────┐
                                          ▼               ▼                               ▼
                                   nested-esxi-1   nested-esxi-2   nested-esxi-3   NFS VM   HAProxy VM
                                   .241            .242            .243            .244     .245
                                          └─────── new Supervisor cluster ────────┘
                                                          │
                                                  Supervisor control plane (3 VMs)
                                                  on 192.168.3.250-.254
```

### Final network topology (after the management/workload split)

The Supervisor wizard requires **management** and **workload** networks to
be on **different subnets**. To get both networks reachable from the
nested ESXi cluster, each nested ESXi VM has a *second* vNIC bridged to
a port group on the physical host's existing `dswitch` DVS (which is on
the 192.168.2.x management LAN). The supervisor-dvs DVS then has *two*
uplinks per host, and port-group **teaming policy** decides which uplink
each port group sends traffic out of:

```
                                       192.168.1.0/24 (LAN1)              ┌──────────────┐
                                       Mac (.160), DHCP clients ─────────▶│  EdgeRouter  │
                                                                          │  .1.1 .2.1   │
                          ┌─────────────────────────────────────────────  │  .3.1        │
                          │                                               └──────┬───────┘
                          │     192.168.2.0/24 (LAN2 — management)               │
                          │     ┌───────────┐   ┌─────────┐                      │
                          │     │  vCSA     │   │ ESXi    │                      │
                          │     │  .80      │   │ .75     │                      │
                          │     └─────┬─────┘   └────┬────┘  Physical host        │
                          │           └──────────────┤      (192.168.2.75)        │
                          │                          │                            │
                          │                  ┌───────┴─────────────────────────┐  │
                          │                  │  vSwitch1   port group:         │  │
                          │                  │  "VM Network" (192.168.3.x)     │──┼─eth3
                          │                  │  pNIC: vmnic5                   │  │
                          │                  └────┬──────┬──────┬──────────────┘  │
                          │                       │      │      │                 │
                          │                  ┌────▼─┐ ┌──▼──┐ ┌─▼────┐            │
                          │                  │nESXi1│ │nESXi│ │nESXi3│            │
                          │                  │.241  │ │.242 │ │.243  │            │
                          │                  │      │ │     │ │      │            │
                          │              vmnic0 (mgmt vmk on 192.168.3.x via vSw0) │
                          │              vmnic1 (supervisor-dvs uplink1)           │
                          │              vmnic2 (supervisor-dvs uplink2 NEW) ──────┼──┐
                          │                  └──┬───┘ └──┬──┘ └──┬───┘            │  │
                          │                     │        │       │                │  │
                          │             ┌───────▼────────▼───────▼──────────────┐ │  │
                          │             │  supervisor-dvs (cluster-wide DVS)    │ │  │
                          │             │    uplink1: vmnic1 (each host)        │ │  │
                          │             │    uplink2: vmnic2 (each host)        │ │  │
                          │             │                                       │ │  │
                          │             │  ┌─ port group: sup-workload          │ │  │
                          │             │  │   teaming: active=[uplink1]        │ │  │
                          │             │  │   → traffic exits vmnic1 → outer   │ │  │
                          │             │  │     VM Network → 192.168.3.x       │ │  │
                          │             │  │                                    │ │  │
                          │             │  └─ port group: sup-mgmt              │ │  │
                          │             │      teaming: active=[uplink2]        │ │  │
                          │             │      → traffic exits vmnic2 → outer   │ │  │
                          │             │        dswitch-vm → 192.168.2.x       │ │  │
                          │             └──────────────┬────────────────────────┘ │  │
                          │                            │                          │  │
                          │           ┌──── CP VM ─────┴──┐                       │  │
                          │           │ eth0(mgmt) on sup-mgmt → 192.168.2.231    │  │
                          │           │ eth1(workload) on sup-workload → .3.x     │  │
                          │           └─────────────────────────────────────────  │  │
                          │                                                          │
                          │                  ┌───────────────────────────────────┐   │
                          │                  │ Physical host's dswitch (DVS)     │   │
                          │                  │ port group "dswitch-vm" (LAN2)    │◀──┘
                          │                  │ pNIC: (physical NICs on LAN2)     │
                          │                  └───────────────────────────────────┘
                          │
                          └────────────── 192.168.3.0/24 (LAN3 — workload) ────────────────
                                  HAProxy mgmt (.245), VIP pool (.248/29),
                                  NFS (.244), nested ESXi vmk (.241-.243),
                                  Supervisor workload IPs
```

**Reading the diagram:**

- **Outer VM Network on vSwitch1** is the "main" lab L2 segment on the
  physical host. It carries all 192.168.3.x traffic out to the
  EdgeRouter's LAN3 via the physical NIC vmnic5.
- **dswitch-vm on dswitch** is the management L2 segment that bridges
  to LAN2 (192.168.2.x) via the physical host's dswitch uplinks.
- **Each nested ESXi VM has two functional uplinks:** vmnic1 (to the
  workload network) and vmnic2 (to the management network). At the
  physical layer these are vNICs on the nested ESXi VM, connected to
  different outer port groups.
- **supervisor-dvs is the DVS that lives inside the cluster of nested
  ESXi hosts.** It has both uplinks per host. Its port groups choose
  which uplink to use via teaming policy — sup-workload → uplink1,
  sup-mgmt → uplink2.
- **The CP VM** has eth0 on sup-mgmt (→ 192.168.2.x) and eth1 on
  sup-workload (→ 192.168.3.x). Two interfaces, two distinct subnets,
  no kernel-routing ambiguity.

### What "teaming" means in this context

NIC teaming is when a vSwitch or DVS has multiple physical uplinks
attached and decides per-frame which one to use. vSphere teaming serves
three purposes:

1. **Redundancy** — if uplink1 dies, traffic fails over to uplink2.
2. **Bandwidth aggregation** — load-balance traffic across uplinks.
3. **Traffic steering** — pin specific port groups to specific uplinks.

We use the third here. Each DVS port group has an "uplink teaming
policy" that names:

- **Active uplinks** — carry traffic for this port group normally.
- **Standby uplinks** — take over only if no active uplink is alive.
- **Unused uplinks** — never carry traffic for this port group.

By setting `sup-mgmt`'s active uplink to *only* uplink2 and
`sup-workload`'s active uplink to *only* uplink1, we force each port
group to a specific physical NIC even though they share the same DVS.
That's how a single DVS can bridge two different physical networks.

The vSphere GUI exposes this at:
DVS → port group → Edit → Teaming and failover → Failover order

Or via govc:

```bash
# Make sup-mgmt traffic egress through uplink2 only
govc dvs.portgroup.change -active=uplink2 -standby= -unused=uplink1 sup-mgmt

# Make sup-workload traffic egress through uplink1 only
govc dvs.portgroup.change -active=uplink1 -standby= -unused=uplink2 sup-workload
```

### Glossary — outer, inner, pNIC, vNIC

These terms get used throughout. Worth pinning down up front.

| Term | Meaning |
|---|---|
| **pNIC** | **Physical Network Interface Card.** The actual silicon on the motherboard or a PCIe card, with real RJ45 / SFP+ ports on the back of the server. ESXi names each one `vmnicN`. |
| **vNIC** | **Virtual Network Interface Card.** A software NIC inside a VM, connected to a port group. Shows up as `ethN` in a Linux guest, or as `vmnicN` if the guest itself is ESXi. |
| **outer** | The *physical host's* networking layer — port groups, vSwitches, DVS, and pNICs that exist directly on the bare-metal ESXi at 192.168.2.75. |
| **inner** | The *nested ESXi cluster's* networking layer — port groups, DVS, and "vmnics" that exist inside the nested ESXi VMs. From the nested ESXi's perspective vmnicN looks physical, but it's really a vmxnet3 vNIC the outer host provided. |
| **uplink** | A slot on a vSwitch/DVS that a vmnic (pNIC) plugs into. Outer-layer uplinks consume real pNICs; inner-layer uplinks consume the nested ESXi's "pNICs" (which are really vNICs). |
| **port group** | A named L2 segment on a vSwitch/DVS. VMs attach to port groups, not to switches directly. |

The two-layer structure looks like this:

```
═════════════════════════════════════════════════════════════════════
  OUTER — physical host (192.168.2.75)
═════════════════════════════════════════════════════════════════════

   Real pNICs:  vmnic0, vmnic1, ..., vmnic7   (real cables on real ports)

   Standard vSwitches + port groups defined on this layer:
   - outer-mgmt-net (or 'dswitch-vm' in our existing lab)
       carries 192.168.2.x management traffic; backed by pNIC vmnic4
   - outer-workload-net (or 'VM Network' in our existing lab)
       carries 192.168.3.x workload traffic; backed by pNIC vmnic5

   These are the "OUTER" port groups.
                            │
   VMs running on this host attach to these port groups via vNICs:
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  - nested-esxi-1  (a VM whose guest OS IS ESXi)              │
   │  - nested-esxi-2                                             │
   │  - nested-esxi-3                                             │
   │  - vCSA (vCenter Server Appliance, .2.80)                    │
   │  - HAProxy VM (.3.245), NFS VM (.3.244)                      │
   └──────────────────────────────────────────────────────────────┘
                            │
        (each nested-esxi VM has 3 vNICs that attach to outer port
         groups; from the VM's guest OS those vNICs appear as
         vmnic0/vmnic1/vmnic2 "physical" interfaces)
                            │
                            ▼

═════════════════════════════════════════════════════════════════════
  INNER — nested ESXi cluster (3 ESXi instances, each a VM)
═════════════════════════════════════════════════════════════════════

   "pNICs" from the nested ESXi's view:  vmnic0, vmnic1, vmnic2
                                         (actually vNICs the outer
                                          host gave each VM)

   DVS + port groups defined on this layer:
   - supervisor-dvs (cluster-wide DVS spanning all 3 nested hosts)
     ├── sup-mgmt      → uplink2 (= inner vmnic2) → outer-mgmt-net
     └── sup-workload  → uplink1 (= inner vmnic1) → outer-workload-net

   These are the "INNER" port groups.
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  VMs running on the nested cluster:                          │
   │   - SupervisorControlPlaneVM (CP VM)                         │
   │     - eth0 → sup-mgmt (192.168.2.232/24)                     │
   │     - eth1 → sup-workload (192.168.3.201/24)                 │
   │   - Pod VMs (created by Supervisor)                          │
   │   - Future TKG workload VMs                                  │
   └──────────────────────────────────────────────────────────────┘
```

**Same network, two names.** `outer-mgmt-net` and `sup-mgmt` are *both*
on subnet `192.168.2.0/24` — same broadcast domain at the wire level
— but each is configured separately because they live at different
layers of the stack. Likewise `outer-workload-net` (a.k.a. `VM
Network` in our existing lab) and `sup-workload` share
`192.168.3.0/24`.

**Why both layers need security-flag fixes.** Phase 1 enabled the
three "Accept" security flags on the *outer* `VM Network`. Phase 10
did the same on the outer `dswitch-vm` (which was missed initially —
this is what manifested as the DNS resolution timeout in attempt
#8). The *inner* port groups have their own security flags that we
also set to Accept. Skipping any layer drops nested-VM traffic
silently.

**Why "outer" port groups can be standard vSwitches.** The outer
layer has only one host (the physical ESXi). A DVS exists to keep
configuration consistent across multiple hosts; with one host that's
unnecessary. The Terraform `physical-network` module uses two
standard vSwitches. The inner layer needs a DVS because it spans 3
nested hosts and the Supervisor wizard requires DVS port groups.

### What "bridge for nested management network" means

The phrase `dswitch-vm` "bridges to the management subnet" (used
throughout this doc and the architecture diagram above) deserves
unpacking, because it's the most subtle piece of the architecture.

"Bridge" here is the networking term — a connection that joins two
L2 (Ethernet) segments so they behave as one broadcast domain.
`dswitch-vm` is the bridge that gets traffic from *inside* a nested
ESXi VM out to the physical `192.168.2.x` management network.

The CP VM doesn't run on the physical host — it runs *inside* a
nested ESXi, which is itself a VM on the physical host. So a packet
from `CP VM eth0` to `192.168.2.1` has to traverse multiple layers:

```
CP VM eth0 (.2.232)
  │
  ▼
supervisor-dvs port group "sup-mgmt"
  │  teaming says: egress only via uplink2
  ▼
uplink2 of each nested ESXi = its vmnic2
  │
  ▼
─────────── INSIDE → OUTSIDE the nested ESXi VM ───────────
  │
  ▼
Physical host's "dswitch-vm" port group
  │  (vmnic2 of nested-esxi-N is one of its ports)
  │  Security must Accept Forged Transmits, MAC Changes,
  │  Promiscuous — because the source MAC is the CP VM's,
  │  not vmnic2's own MAC.
  ▼
dswitch (DVS on the physical host)
  │
  ▼
pNIC vmnic4 → physical Ethernet → EdgeRouter LAN2 port
  │
  ▼
192.168.2.1
```

From the **nested ESXi's** perspective, `vmnic2` is "a NIC plugged
into the 192.168.2.x network." From the **physical host's**
perspective, the same vmnic2 is just another port on `dswitch-vm`.
The bridge is `dswitch-vm` stitching those two views together so
they behave as one broadcast domain.

**Why we needed it:** without `vmnic2`/`dswitch-vm`, the only NICs
on each nested ESXi were `vmnic0` and `vmnic1`, both attached to
the outer `VM Network` port group on the 192.168.3.x lab subnet.
There was no path from inside the nested cluster to the 192.168.2.x
management network. Since the Supervisor wizard requires management
and workload networks to be on *different* subnets, we extended
each nested ESXi with a third vNIC bridged to `dswitch-vm` — giving
the nested CP VM a way to put its management interface on 192.168.2.x.

**Why "bridge" and not "route":** routing means L3 forwarding between
subnets; the two networks involved have different IP prefixes and a
router decides which interface to send a packet out. A bridge is L2 —
two segments merged into one broadcast domain with no L3 hop in
between. Both `sup-mgmt` (inside the nested DVS) and `dswitch-vm`
(on the physical host) are L2 segments on the *same* `192.168.2.0/24`
network. The nested ESXi's `vmnic2` just lets frames pass between
them transparently.

**The reverse view:** an inbound packet from `192.168.2.1` to
`CP VM eth0` follows the same path in reverse — EdgeRouter ARPs for
the CP VM's MAC out LAN2, the request reaches `dswitch-vm` on the
physical host, the physical dswitch forwards it to vmnic2's port
(which is one of nested-esxi-N's vNICs), the nested ESXi forwards it
into `supervisor-dvs`, and the DVS delivers it to the CP VM's eth0.
Each step is L2 frame forwarding; no IP routing happens between
nested-inside and outside.

## HAProxy — what it is, why we need it, and how it must be set up

The Supervisor wizard requires a load balancer that fronts the K8s
API server *and* programs frontends for every `Service{type:
LoadBalancer}` users create. Without it, the wizard refuses to enable
Supervisor. VMware supports two LB types: **NSX Advanced Load
Balancer** (Avi) or **HAProxy**. We picked HAProxy because Avi
requires a separate controller VM and licensing.

### What HAProxy does in this architecture

| Function | Frontend (VIP) | Backend |
|---|---|---|
| K8s API for kubectl clients | `192.168.3.251:6443` | CP VM workload IP `192.168.3.201:6443` |
| Plugin download / API HTTPS | `192.168.3.251:443` | CP VM `192.168.3.201:443` |
| Supervisor mgmt-image-proxy | `192.168.3.250:443` | CP VM `192.168.3.201:443` |
| vSphere CSI controller | `192.168.3.249:2112`/`2113` | CP VM `192.168.3.201:2112`/`2113` |
| User-created LoadBalancer Services | VIP from `.249–.254` pool | pod endpoint IPs |

### Visual reference — HAProxy VM with IPs, ports, and listeners

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Clients of the HAProxy VM                                               │
│  ─────────────────────────                                               │
│  Mac (192.168.1.160) ─── kubectl / curl ─────────────────────┐           │
│  ESXi spherelet on .241/.242/.243 ─── node register ─────────┤           │
│  vCenter (192.168.2.80) — WCP / lbapi controller ─── DPAPI ──┤           │
│                                                              │           │
│  (Mac traffic routed via EdgeRouter LAN1→LAN3; spherelet     │           │
│   talks directly on .3.x subnet; vCenter routes LAN2→LAN3)   │           │
└──────────────────────────────────────────────────────────────┼───────────┘
                                                               │
                                                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  HAProxy VM   (Ubuntu 24.04 cloud image, ens192 on outer "VM Network")   │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  ens192 interface — Linux kernel claims these IPs via `ip addr add`│  │
│  │                                                                    │  │
│  │  192.168.3.245/24  ← primary IP, default route via .3.1            │  │
│  │                                                                    │  │
│  │  VIPs (Phase 11 fix — without these, packets sent to a VIP get    │  │
│  │  silently dropped because the kernel won't ARP-reply for them):    │  │
│  │    192.168.3.249/32   ← CSI controller VIP                         │  │
│  │    192.168.3.250/32   ← mgmt-image-proxy VIP                       │  │
│  │    192.168.3.251/32   ← kube-apiserver LB VIP (the big one)        │  │
│  │    192.168.3.252/32   ┐                                            │  │
│  │    192.168.3.253/32   ├── reserved for user-defined LB Services    │  │
│  │    192.168.3.254/32   ┘                                            │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  dataplaneapi  (HAProxy Dataplane REST API, ≥ v2.9.25)             │  │
│  │  systemd unit  /etc/systemd/system/dataplaneapi.service            │  │
│  │     ExecStart=/usr/local/bin/dataplaneapi \                        │  │
│  │       -f /etc/haproxy/dataplaneapi.yaml                            │  │
│  │     (Phase 10 fix — `-f` is the dataplaneapi's OWN config flag;    │  │
│  │      `--config-file=` is the HAProxy config file flag.)            │  │
│  │                                                                    │  │
│  │  Listens on:   *:5556  HTTPS, basic-auth admin / Srosario1!        │  │
│  │  TLS cert:     /etc/haproxy/certs/dpapi.crt (SAN includes .245)    │  │
│  │  Manages:      /etc/haproxy/haproxy.cfg                            │  │
│  │  Reload cmd:   systemctl reload haproxy                            │  │
│  │  On every commit:                                                  │  │
│  │    1. write tmp snapshot to /tmp/haproxy/haproxy.cfg.<tx-id>       │  │
│  │    2. run `haproxy -c -f <tmp>` to validate                        │  │
│  │    3. if valid: rename tmp → haproxy.cfg, reload                   │  │
│  │    4. if invalid: 400 Bad Request, rollback                        │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  haproxy  (systemd-managed)                                        │  │
│  │  config:  /etc/haproxy/haproxy.cfg (managed by dataplaneapi)       │  │
│  │                                                                    │  │
│  │  frontend kube-apiserver-lb-svc                                    │  │
│  │     bind 192.168.3.251:6443                                        │  │
│  │     bind 192.168.3.251:443       (nginx-style HTTPS redirect)      │  │
│  │     mode tcp                                                       │  │
│  │     default_backend  …                                             │  │
│  │  backend kube-apiserver-lb-svc                                     │  │
│  │     mode tcp                                                       │  │
│  │     server cp1 192.168.3.201:6443 check                            │  │
│  │                                                                    │  │
│  │  frontend mgmt-image-proxy                                         │  │
│  │     bind 192.168.3.250:443                                         │  │
│  │  backend mgmt-image-proxy                                          │  │
│  │     server cp1 192.168.3.201:443                                   │  │
│  │                                                                    │  │
│  │  frontend vsphere-csi-controller                                   │  │
│  │     bind 192.168.3.249:2112                                        │  │
│  │     bind 192.168.3.249:2113                                        │  │
│  │  backend vsphere-csi-controller (one per port)                     │  │
│  │     server cp1 192.168.3.201:2112 (resp. 2113)                     │  │
│  │                                                                    │  │
│  │  user LB Services dynamically add more frontends as needed,        │  │
│  │  consuming VIPs .252/.253/.254 (and beyond, if the wizard's        │  │
│  │  configured pool was larger).                                      │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │  TCP forward (no SNI/TLS termination)
                                   ▼
                  ┌────────────────────────────────┐
                  │  CP VM                         │
                  │  eth0  192.168.2.232 (mgmt)    │
                  │  eth1  192.168.3.201 (workload)│
                  │                                │
                  │  kube-apiserver  :6443         │
                  │  nginx-redirect  :443          │
                  │  CSI controller  :2112/:2113   │
                  │  mgmt-image-proxy :443         │
                  └────────────────────────────────┘
```

### IP-to-port reference for the HAProxy VM

| IP | Port | Direction | Purpose |
|---|---|---|---|
| `192.168.3.245` | `22` | inbound from admin Mac | SSH to ubuntu user (password Srosario1!) |
| `192.168.3.245` | `5556` | inbound from vCenter | **Dataplane API (HTTPS)** — wizard uses this; basic auth `admin:Srosario1!`; TLS pinned via `haproxy-dpapi.crt` |
| `192.168.3.249` | `2112` | inbound | vSphere CSI controller LB → CP VM `.201:2112` |
| `192.168.3.249` | `2113` | inbound | vSphere CSI syncer LB → CP VM `.201:2113` |
| `192.168.3.250` | `443` | inbound | Supervisor mgmt-image-proxy LB → CP VM `.201:443` |
| `192.168.3.251` | `6443` | inbound from kubectl | **K8s API LB** → CP VM `.201:6443` |
| `192.168.3.251` | `443` | inbound from browsers | nginx HTTPS redirect / plugin download → CP VM `.201:443` |
| `192.168.3.252-.254` | dynamic | inbound | reserved for user `Service{type:LoadBalancer}` VIPs |
| `192.168.3.245` | outbound | from HAProxy | `192.168.3.1` (default route) + DNS lookups + `wp-content.vmware.com` if TKG library subscribed |

### Outbound calls from HAProxy

| To | Port | Why |
|---|---|---|
| `192.168.3.1` (LAN3 gateway) | various | default route for off-subnet replies (e.g. returning packets to Mac at `192.168.1.x`) |
| `192.168.3.201` (CP VM) | `6443`/`443`/`2112`/`2113` | backend-side forwarding |
| (none for admin plane) | | dataplaneapi has no outbound dependency once it's running |

The frontends/backends/binds are programmed dynamically by the
Supervisor's `vmware-system-lbapi` controller via the HAProxy
**Dataplane REST API** — `haproxy.cfg` is managed entirely by that
API; we do *not* hand-edit it once HAProxy is running.

```
Supervisor (CP VM)
  └── vmware-system-lbapi controller-manager
        │
        │  watches Service{type: LoadBalancer} objects in K8s
        │
        ▼
        HTTPS POST/PUT/DELETE to https://<haproxy-vm>:5556/v2/...
        │
        ▼
  HAProxy VM
  ├── /usr/local/bin/dataplaneapi  (REST API, port 5556)
  │     │
  │     │  writes /etc/haproxy/haproxy.cfg
  │     │  then runs `systemctl reload haproxy`
  │     ▼
  └── HAProxy (frontends/backends per /etc/haproxy/haproxy.cfg)
        ├── listens on VIPs (.249-.254)
        └── forwards to backend pod/CP endpoints
```

### Requirements

1. **Standalone Ubuntu/Photon VM** dedicated to HAProxy. We used the
   Ubuntu 24.04 cloud OVA (we pivoted to this in Phase 7.B after the
   VMware HAProxy OVA refused to import).
2. **One or two network interfaces** — VMware's reference deployment
   uses three (mgmt + workload + frontend) for full isolation; for a
   lab a single `ens192` on the workload network plus VIPs as `/32`
   secondaries works fine. vCenter routes cross-subnet to reach the
   Dataplane API.
3. **HAProxy + HAProxy Dataplane API ≥ v2.9.25** installed (older 2.9.x
   versions have a config-rewrite bug that breaks transactions — see
   Phase 10).
4. **A TLS certificate** for the Dataplane API endpoint. Self-signed
   is fine — the Supervisor wizard pins it. Stored at
   `haproxy-dpapi.crt` in this repo for re-pasting into the wizard.
5. **Outer port group security flags all = Accept** (we did this for
   `VM Network` on `vSwitch1` back in Phase 1). HAProxy itself doesn't
   require this, but nested-VM → HAProxy traffic in our topology does.
6. **VIPs claimed on an interface.** `net.ipv4.ip_nonlocal_bind=1` —
   which the cloud-init sets — only allows the `bind(2)` syscall to
   succeed on a non-local IP. It does **not** make the kernel respond
   to ARP for that IP. Each VIP needs an explicit
   `ip addr add <vip>/32 dev ens192`. See Phase 11 and the ARP
   explanation in that phase for why.
7. **The systemd unit must use the right flag**: the dataplaneapi
   binary uses `-f` to specify its *own* config file. The
   `--config-file=` flag is for the **HAProxy** config file. Mixing
   these up corrupts dataplaneapi's YAML and breaks every transaction
   commit. See Phase 10.

### Setup — minimum viable

Files used:

- `haproxy-userdata.yaml` — cloud-init for the base Ubuntu VM. Sets
  static IP `192.168.3.245/24`, enables `ip_nonlocal_bind=1` and
  `ip_forward=1`, installs HAProxy + open-vm-tools.
- `haproxy-setup.sh` — one-shot installer. Downloads Dataplane API,
  generates a self-signed TLS cert, writes config files, installs the
  systemd unit *with the correct `-f` flag*, starts services.

Walk-through:

```bash
# 1. Build the base VM (cloud-init from haproxy-userdata.yaml).
#    See Phase 7.B.2 for the import.spec generation.

# 2. Run the installer (one-shot, idempotent).
scp haproxy-setup.sh ubuntu@192.168.3.245:/tmp/
ssh ubuntu@192.168.3.245 'sudo bash /tmp/haproxy-setup.sh'

# 3. Post-install — claim VIPs on ens192. Without this, HAProxy is
#    listening on the VIPs but no one can reach them (Phase 11).
ssh ubuntu@192.168.3.245 'sudo bash -s' <<'EOF'
for ip in 192.168.3.249 192.168.3.250 192.168.3.251 \
         192.168.3.252 192.168.3.253 192.168.3.254; do
  ip addr add $ip/32 dev ens192 2>&1 | grep -v 'File exists' || true
done
# Persistent across reboot:
cat > /etc/netplan/61-vips.yaml <<'NET'
network:
  version: 2
  ethernets:
    ens192:
      addresses:
        - 192.168.3.245/24
        - 192.168.3.249/32
        - 192.168.3.250/32
        - 192.168.3.251/32
        - 192.168.3.252/32
        - 192.168.3.253/32
        - 192.168.3.254/32
NET
chmod 600 /etc/netplan/61-vips.yaml
EOF

# 4. Verify Dataplane API is alive and accepts transactions
curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/info \
  | python3 -m json.tool
# Expect:  "api": {"version": "v2.9.25 ..."}

# Manual transaction test — proves end-to-end commit path works
VER=$(curl -sk -u admin:'Srosario1!' \
  https://192.168.3.245:5556/v2/services/haproxy/configuration/version)
TX=$(curl -sk -u admin:'Srosario1!' -X POST \
  "https://192.168.3.245:5556/v2/services/haproxy/transactions?version=$VER")
TX_ID=$(echo "$TX" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

curl -sk -u admin:'Srosario1!' -X POST -H 'Content-Type: application/json' \
  "https://192.168.3.245:5556/v2/services/haproxy/configuration/backends?transaction_id=$TX_ID" \
  -d '{"name":"test","mode":"tcp","balance":{"algorithm":"roundrobin"}}'

curl -sk -u admin:'Srosario1!' -X PUT \
  "https://192.168.3.245:5556/v2/services/haproxy/transactions/$TX_ID"
# Expect: {"_version":N,"id":"...","status":"success"}

# Clean up the test backend
NEW_VER=$(curl -sk -u admin:'Srosario1!' \
  https://192.168.3.245:5556/v2/services/haproxy/configuration/version)
curl -sk -u admin:'Srosario1!' -X DELETE \
  "https://192.168.3.245:5556/v2/services/haproxy/configuration/backends/test?version=$NEW_VER"
```

### Wizard inputs targeting HAProxy

The wizard's **Load Balancer** page (Page 4) takes:

| Field | Value (our lab) |
|---|---|
| Type | HAProxy |
| Name | `haproxy-lab` |
| Data Plane API Addresses | `192.168.3.245:5556` |
| User / Password | `admin` / `Srosario1!` |
| Virtual IP Address Ranges | `192.168.3.249-192.168.3.254` |
| Server Certificate Authority | paste **entire content** of `haproxy-dpapi.crt` (the `-----BEGIN CERTIFICATE-----` through `-----END CERTIFICATE-----` block) |

### Common HAProxy failure modes (forward references to phases)

| Symptom | Most likely cause | Where to look |
|---|---|---|
| `lbapi` logs show `failed to commit transaction: 400 Bad Request` | systemd unit uses `--config-file=` instead of `-f` | Phase 10 |
| `dataplaneapi.yaml` re-emerges without indentation, all keys at top level | dataplaneapi v2.9.10 misinterpreted its own YAML as `haproxy.cfg` | Phase 10 |
| `EXTERNAL-IP <pending>` forever on LB Services | VIPs not claimed on `ens192` (`ip_nonlocal_bind` alone is insufficient) | Phase 11 |
| Ping VIP from inside-subnet works, from outside-subnet fails | outer port group security policy blocks forged transmits | Phase 10 (dswitch-vm) or Phase 1 (VM Network) |
| `dataplaneapi` service won't start | TLS cert/key permissions wrong, or `transaction_dir` not writable | `journalctl -u dataplaneapi -e` |
| Wizard "Connection failed" on Load Balancer page | wrong endpoint, wrong basic-auth creds, or cert mismatch | redownload `haproxy-dpapi.crt`, double-check user/password in `/etc/haproxy/dataplaneapi.yaml` |

### Why we couldn't use the VMware HAProxy OVA

VMware ships a pre-built HAProxy OVA designed for vSphere with Tanzu.
We tried it first (Phase 7.A) but vCenter 9.0.2 rejected the OVF
environment vApp options at import time — same OVA, multiple paths
attempted (vSphere UI, govc, ovftool, pyvmomi, manually-injected
`ovfenv.xml`), all failed with the same `Host did not have any
virtual nic associated with vApp dvport groups` error. We pivoted to
vanilla HAProxy on Ubuntu (Phase 7.B). That works, but we hit issues
the OVA would have handled for us (systemd flag, VIP claiming),
which we now document explicitly.

## Environment

| Item | Value |
|---|---|
| vCenter | `vcenter.skynetsystems.io` (vCenter 9.0.2) |
| Physical host | `192.168.2.75` (Cluster) — 40 cores, 256 GB RAM, 572 GB free on `datastore1` |
| EdgeRouter | `192.168.1.1` — DHCP serves 192.168.3.4–.240 on LAN3 (eth3) |
| Existing port group | `VM Network` on `vSwitch1`, uplink `vmnic5` → eth3 |
| ESXi ISO | `VMware-VMvisor-Installer-9.0.2.0.25148076.x86_64.iso` (664 MB) |
| Tooling | `govc 0.54.0`, `expect`, `pandoc + weasyprint` (for PDFs) |
| Substitute throughout | the IPs/names below match this lab; change for yours |

## IP plan

Note: the plan was revised at Phase 7 once we knew the HAProxy
`service_ip_range` had to be a network-aligned CIDR. The Supervisor
control-plane block moved down and the EdgeRouter DHCP pool was
shrunk to stop at .200 to free up middle-range statics.

| Range | Use |
|---|---|
| 192.168.3.4–200 | EdgeRouter DHCP (shrunk from .240) |
| .201–.230 | free for future statics |
| **.231–.235** | Supervisor control plane (5 consecutive) |
| .236–.240 | buffer |
| .241 | nested-esxi-1 |
| .242 | nested-esxi-2 |
| .243 | nested-esxi-3 |
| .244 | nfs-storage VM |
| **.245** | HAProxy management |
| **.246** | HAProxy workload (data plane) |
| .247 | buffer |
| **.248/29 (.249–.254)** | HAProxy VIP pool — Supervisor service VIPs |

---

## Phase 1 — Physical host preparation [done]

### 1.1 Allow nested traffic on the parent port group

Nested ESXi works only if the *outer* port group (the one the nested-ESXi
VMs attach to) lets frames pass for MACs other than the VM's own. That
requires three security flags flipped to **Accept**:

- Promiscuous mode
- Forged transmits
- MAC address changes

**GUI:** vSphere Client → host `192.168.2.75` → Configure → Virtual
Switches → `vSwitch1` → Edit Port Group `VM Network` → Security →
set all three to **Accept** → OK.

**CLI:**

```bash
govc host.portgroup.change \
  -host /Datacenter/host/Cluster/192.168.2.75 \
  -allow-promiscuous=true \
  -forged-transmits=true \
  -mac-changes=true \
  'VM Network'

# Verify:
govc host.portgroup.info -host /Datacenter/host/Cluster/192.168.2.75
# Allow promiscuous mode:  Yes
# Allow forged transmits:  Yes
# Allow MAC changes:       Yes
```

> **Note**: govc's flag naming is inconsistent — `-allow-promiscuous` has
> the `allow-` prefix, the other two don't.

### 1.2 Upload the ESXi installer ISO to the datastore

You need the installer ISO accessible to the ESXi host. Easiest path is
to put it on `datastore1`. Download the ISO from Broadcom Customer
Connect first if you don't have it.

```bash
# Create iso/ directory on the datastore
govc datastore.mkdir -ds=datastore1 -p iso

# Upload (664 MB; on slow uplink expect 20+ minutes)
govc datastore.upload \
  -ds=datastore1 \
  ./VMware-VMvisor-Installer-9.0.2.0.25148076.x86_64.iso \
  iso/VMware-VMvisor-Installer-9.0.2.0.25148076.x86_64.iso

# Verify
govc datastore.ls -l -ds=datastore1 iso
```

**GUI alternative:** Storage → datastore1 → Files → New Folder `iso` →
Upload Files → select the ISO.

> **Pitfall:** the upload can fail mid-stream over a slow/flaky link.
> If it does, just rerun the same command — it overwrites the target.

---

## Phase 2 — Create the nested ESXi VMs [done]

### 2.1 Spec

For each of the 3 nested hosts:

| Setting | Value | Why |
|---|---|---|
| CPUs | 8 vCPUs | Supervisor control plane VMs need real CPU |
| Memory | 32 GB | Supervisor control plane is ~16 GB per host |
| Boot disk | 80 GB thin | ESXi 9 installer + room for local logs |
| Firmware | EFI | required by ESXi 9 |
| Guest OS | VMware ESXi 8.0 (`vmkernel8Guest`) | closest match in the VM API |
| Storage controller | **VMware Paravirtual SCSI (PVSCSI)** | LSI Logic SAS does NOT work — installer can't see the disk |
| NIC adapter | VMXNET3 | standard for nested ESXi |
| NIC port group | `VM Network` (192.168.3.0/24) | reuses LAN3, EdgeRouter routes it |
| Nested HV | enabled | required so this ESXi can run nested VMs |
| Hardware version | latest (vmx-22 on vCenter 9) | govc picks this automatically |

> **Pitfall (controller choice):** ESXi 9 has tightened storage driver
> support. If you create the VM with the LSI Logic SAS controller (govc's
> default), the ESXi installer will boot but show "Remote (none) /
> Local (none)" with **no disks visible**. Use PVSCSI from the start.

### 2.2 CLI: create the VMs

```bash
for VM in nested-esxi-1 nested-esxi-2 nested-esxi-3; do
  # Create VM without a disk so we can attach PVSCSI manually
  govc vm.create \
    -on=false \
    -m=32768 -c=8 -g=vmkernel8Guest \
    -ds=datastore1 -net='VM Network' -net.adapter=vmxnet3 \
    -firmware=efi -folder=/Datacenter/vm \
    "$VM"

  # Add a PVSCSI controller, then a disk on it
  CTRL=$(govc device.scsi.add -vm "/Datacenter/vm/$VM" -type=pvscsi)
  govc vm.disk.create \
    -vm "/Datacenter/vm/$VM" -ds=datastore1 \
    -controller="$CTRL" -name="$VM/disk1" -size=80G

  # Attach the ESXi installer ISO + set boot order CD first
  govc device.cdrom.add -vm "/Datacenter/vm/$VM"
  govc device.cdrom.insert -vm "/Datacenter/vm/$VM" -device cdrom-3000 \
    '[datastore1] iso/VMware-VMvisor-Installer-9.0.2.0.25148076.x86_64.iso'
  govc device.boot -vm "/Datacenter/vm/$VM" -order=cdrom,disk

  # Enable nested hardware virtualization
  govc vm.change -vm "/Datacenter/vm/$VM" \
    -nested-hv-enabled=true \
    -e="vhv.enable=TRUE" \
    -e="hypervisor.cpuid.v0=FALSE"
done
```

`vhv.enable=TRUE` is the legacy syntax; `nested-hv-enabled=true` is the
modern attribute. Setting both is belt-and-braces — modern vCenter only
needs `nested-hv-enabled`.

`hypervisor.cpuid.v0=FALSE` hides the outer hypervisor from inner
workloads — useful if you ever run Windows VMs inside the nested ESXi
(some Windows installers refuse to install when they detect they're
already nested).

### 2.3 GUI alternative

vSphere Client → right-click `Cluster` → New Virtual Machine → Create:
- Type: Create a new virtual machine
- Name: `nested-esxi-1`, location: Datacenter
- Compute: Cluster, datastore: datastore1
- Compatibility: latest (ESXi 9.0 and later)
- Guest OS family: Other → Guest OS version: **VMware ESXi 8.0 or later**
- Customize hardware:
  - CPU: **8**, expand → **Expose hardware-assisted virtualization to the guest OS**
  - Memory: **32 GB**
  - Remove the default hard disk; click **Add New Device → SCSI Controller → VMware Paravirtual**
  - Click **Add New Device → Hard Disk** → 80 GB, controller = the PVSCSI one
  - Network: **VM Network**, adapter type **VMXNET3**
  - Click **Add New Device → CD/DVD Drive** → Datastore ISO File → browse to the ESXi ISO
  - **VM Options → Boot Options → Firmware = EFI**

---

## Phase 3 — Install ESXi via the installer [done]

The ESXi installer is interactive. Two ways to drive it:

1. **GUI**: vSphere Web Console (browser-based) or VMware Remote Console
   (standalone app). VMRC handles function keys reliably; browser console
   often loses F11 to the OS or browser.
2. **CLI via `govc vm.keystrokes`**: bypasses the console entirely —
   injects USB-HID keystrokes directly into the VM. We used this because
   the browser console eats F11 on macOS (Mission Control intercept).

### 3.1 Power on and walk through the installer (CLI)

```bash
VM=/Datacenter/vm/nested-esxi-1
govc vm.power -on "$VM"

# Wait for ESXi installer to load (~45–60 s after power-on)
sleep 50

# Welcome screen → Enter
govc vm.keystrokes -vm "$VM" -c KEY_ENTER ;  sleep 3

# EULA → F11 to accept
govc vm.keystrokes -vm "$VM" -c KEY_F11 ;    sleep 5

# Disk selection (PVSCSI disk listed) → Enter
govc vm.keystrokes -vm "$VM" -c KEY_ENTER ;  sleep 3

# Keyboard layout (US default) → Enter
govc vm.keystrokes -vm "$VM" -c KEY_ENTER ;  sleep 3

# Root password — type, Tab, type, Enter
govc vm.keystrokes -vm "$VM" -s 'Srosario1!'
govc vm.keystrokes -vm "$VM" -c KEY_TAB
govc vm.keystrokes -vm "$VM" -s 'Srosario1!'
govc vm.keystrokes -vm "$VM" -c KEY_ENTER ;  sleep 5

# Confirm install → F11
govc vm.keystrokes -vm "$VM" -c KEY_F11
```

The install runs ~2–4 minutes copying files to disk.

### 3.2 GUI alternative

Open the VM's Web Console (or Remote Console), then:

1. Press **Enter** on the welcome screen
2. **F11** to accept the EULA
3. **Enter** to select the local disk
4. **Enter** to accept the US keyboard
5. Type the root password, **Tab**, type it again, **Enter**
6. **F11** on the "Confirm Install" screen

> **Pitfall (F11 not reaching console):** On macOS, F11 triggers Show
> Desktop and is grabbed before the browser sees it. Fixes (in order):
> – use `govc vm.keystrokes -c KEY_F11` (recommended)
> – use VMware Remote Console standalone app
> – uncheck the F11 Mission Control binding in System Settings → Keyboard

### 3.3 Reboot and eject

After the install completes the installer shows
**"Remove the installation media before rebooting"**.

```bash
# Eject the ISO so the next boot uses the 80 GB disk
govc device.cdrom.eject -vm "$VM" -device cdrom-3000

# Send Enter to reboot
govc vm.keystrokes -vm "$VM" -c KEY_ENTER
```

> **Pitfall (eject during install):** if you try to eject *during* the
> install, you'll get `Connection control operation failed for disk
> 'ide0:0'` — the installer holds the CD lock. Either eject right after
> "Installation Complete" appears, or skip the eject and let the post-
> install boot's chain-load detect the on-disk install and skip the ISO.
> In our case the chain-load worked even with the ISO still attached.

### 3.4 Verification

After ~60 s the VM boots from disk into ESXi proper. Check from outside
that it acquired an IP:

```bash
govc vm.info -json /Datacenter/vm/nested-esxi-1 | python3 -c "
import json,sys
g=json.load(sys.stdin)['virtualMachines'][0].get('guest',{})
print('ip:', g.get('ipAddress'), 'tools:', g.get('toolsRunningStatus'))
"
# ip: 192.168.3.10  tools: guestToolsRunning
```

A DHCP-acquired IP from the LAN3 pool means ESXi is up. We'll switch
to static below.

### 3.5 Repeat for the other two hosts

The installer flow is identical. You can do them in parallel — they
share no per-VM state. Sample script:

```bash
prep_vm() {
  local VM="/Datacenter/vm/$1"
  govc vm.power -off -force "$VM" 2>/dev/null
  govc device.remove -vm "$VM" -keep=false disk-1000-0
  govc device.remove -vm "$VM" lsilogic-sas-1000
  local CTRL=$(govc device.scsi.add -vm "$VM" -type=pvscsi)
  govc vm.disk.create -vm "$VM" -ds=datastore1 \
    -controller="$CTRL" -name="$1/disk1" -size=80G
  govc device.boot -vm "$VM" -order=cdrom,disk
  govc vm.power -on "$VM"
}

drive_install() {
  local VM="/Datacenter/vm/$1"
  sleep 50
  govc vm.keystrokes -vm "$VM" -c KEY_ENTER ; sleep 3
  govc vm.keystrokes -vm "$VM" -c KEY_F11   ; sleep 5
  govc vm.keystrokes -vm "$VM" -c KEY_ENTER ; sleep 3
  govc vm.keystrokes -vm "$VM" -c KEY_ENTER ; sleep 3
  govc vm.keystrokes -vm "$VM" -s 'Srosario1!'
  govc vm.keystrokes -vm "$VM" -c KEY_TAB
  govc vm.keystrokes -vm "$VM" -s 'Srosario1!'
  govc vm.keystrokes -vm "$VM" -c KEY_ENTER ; sleep 5
  govc vm.keystrokes -vm "$VM" -c KEY_F11
}

( prep_vm nested-esxi-2 && drive_install nested-esxi-2 ) &
( prep_vm nested-esxi-3 && drive_install nested-esxi-3 ) &
wait
```

---

## Phase 4 — Set static management IP on each host [done]

Each nested ESXi needs a stable management IP. The IP plan has them at
.241–.243.

### 4.1 Via DCUI (interactive at the console)

Open the VM's console (vSphere Web Console or VMRC).

1. **F2** → root login (Username `root`, password `Srosario1!`)
2. Arrow keys to **Configure Management Network** → Enter
3. **IPv4 Configuration** → Enter
4. Arrow to **Set static IPv4 address and network configuration** → Space
   to mark
5. Tab to **IPv4 Address** → type the IP (e.g. `192.168.3.241`)
6. Tab to **Subnet Mask** → `255.255.255.0`
7. Tab to **Default Gateway** → `192.168.3.1`
8. **Enter** to save
9. From the menu, **DNS Configuration** → set Primary DNS = `192.168.3.1`,
   Hostname = `nested-esxi-1`
10. **Enter** → **Esc** to leave Configure Management Network →
    **Y** when asked "Apply changes and restart management network?"

### 4.2 Programmatic alternative (after the host is added to vCenter)

If you'd rather configure statics from outside, add the host first with
its DHCP IP, then change the vmk0 address via PowerCLI / API. See
Phase 5 for the host-add step.

### 4.3 Status

- **nested-esxi-1**: `192.168.3.241` ✓
- **nested-esxi-2**: `192.168.3.242` ✓
- **nested-esxi-3**: `192.168.3.243` ✓

All three were configured by hand at the DCUI. Verification from outside
the hosts:

```bash
for ip in 192.168.3.241 192.168.3.242 192.168.3.243; do
  curl -sk --max-time 3 -o /dev/null -w "  https://$ip   HTTP %{http_code}\n" "https://$ip"
done
# https://192.168.3.241   HTTP 200
# https://192.168.3.242   HTTP 200
# https://192.168.3.243   HTTP 200
```

A 200 from `https://<ip>` means the ESXi host's embedded host UI is up
and the management network is configured correctly.

---

## Phase 5 — Add hosts to a new cluster, enable HA + DRS [done]

Supervisor needs the nested hosts in *their own* cluster (distinct from
the physical host's `Cluster`). HA must be enabled (vSphere Supervisor
requires it) and DRS is strongly recommended.

### 5.1 Create the cluster

```bash
govc cluster.create -dc=Datacenter Supervisor-Cluster
```

**GUI alternative:** vSphere Client → Datacenter → right-click → New
Cluster → Name `Supervisor-Cluster`, leave vSAN off (we'll use NFS),
Next → Finish.

### 5.2 Enable HA + DRS

```bash
govc cluster.change \
  -ha-enabled=true \
  -drs-enabled=true \
  -drs-mode=fullyAutomated \
  /Datacenter/host/Supervisor-Cluster
```

**GUI alternative:** click the new cluster → Configure → Services →
vSphere DRS → Edit → enable, automation level **Fully Automated**, then
vSphere Availability → Edit → enable HA.

### 5.3 Add each host

```bash
for ip in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc cluster.add \
    -cluster=/Datacenter/host/Supervisor-Cluster \
    -hostname="$ip" \
    -username=root \
    -password='<esxi-root-password>' \
    -noverify=true \
    -force=true
done
```

`-noverify=true` skips host SSL cert verification (the nested hosts use
self-signed certs by default). `-force=true` bypasses the "already in
inventory" check, useful if you're rebuilding.

**GUI alternative:** right-click cluster → Add Hosts → enter all three
IPs, root username, password → accept certs → Finish.

### 5.4 Verification

```bash
govc find /Datacenter/host/Supervisor-Cluster
# /Datacenter/host/Supervisor-Cluster
# /Datacenter/host/Supervisor-Cluster/Resources
# /Datacenter/host/Supervisor-Cluster/192.168.3.241
# /Datacenter/host/Supervisor-Cluster/192.168.3.242
# /Datacenter/host/Supervisor-Cluster/192.168.3.243

govc collect /Datacenter/host/Supervisor-Cluster \
  configuration.dasConfig.enabled \
  configuration.drsConfig.enabled \
  configuration.drsConfig.defaultVmBehavior \
  summary.numHosts
# dasConfig.enabled              true
# drsConfig.enabled              true
# drsConfig.defaultVmBehavior    fullyAutomated
# numHosts                       3
```

Within ~60 s of cluster create, vSphere auto-deploys two **vCLS**
(vSphere Cluster Services) VMs on the new cluster. They're tiny, sip
resources, and back DRS. You'll see them appear in the VM inventory
automatically — that's normal.

## Phase 6 — Deploy the NFS storage VM [done]

Supervisor's HA placement needs **shared storage** visible to every host
in the cluster. We're standing up a small dedicated Ubuntu VM on the
**physical Cluster** (not on a nested host — avoids a dependency loop
where the nested host's datastore relies on a VM running on that same
nested host) and exporting an NFS share to all 3 nested ESXi hosts.

### 6.1 Sizing and placement

| Spec | Value | Why |
|---|---|---|
| OS | Ubuntu 24.04 server (cloud image) | smallest, scriptable via cloud-init |
| CPU | 1 vCPU | NFS server is mostly I/O bound |
| Memory | 4 GB | comfortable for a 200 GB export |
| Disk | 200 GB thin | datastore for nested-host VMs |
| Placement | physical `Cluster` / `datastore1` | NOT inside nested hosts |
| Network | `VM Network` (192.168.3.0/24) | same L2 as the nested hosts |
| Static IP | `192.168.3.244` | outside EdgeRouter DHCP range |

### 6.2 Use the Ubuntu cloud OVA, not a server ISO

The Ubuntu server ISO requires interactive install (or a heavy
preseed/autoinstall config). The cloud OVA is purpose-built for
unattended deployment via cloud-init and is ~10× faster to deploy.

```bash
curl -fsSL -o /tmp/ubuntu-24.04-server-cloudimg-amd64.ova \
  https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.ova
```

About 500 MB. The OVA contains an OVF descriptor, manifest, and a single
VMDK.

### 6.3 Cloud-init user-data

The OVA exposes vApp properties that cloud-init reads at first boot —
including `user-data`, which accepts a base64-encoded
`#cloud-config` YAML. We use it to configure hostname, network, packages,
NFS exports, and a default `ubuntu` user.

`/tmp/nfs-userdata.yaml`:

```yaml
#cloud-config
hostname: nfs-storage
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: <password>
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false

write_files:
  - path: /etc/netplan/60-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: en*
            dhcp4: false
            addresses: [192.168.3.244/24]
            routes:
              - to: default
                via: 192.168.3.1
            nameservers:
              addresses: [192.168.3.1, 8.8.8.8]
  - path: /etc/exports
    content: |
      /srv/nfs/datastore 192.168.3.241(rw,sync,no_subtree_check,no_root_squash) 192.168.3.242(rw,sync,no_subtree_check,no_root_squash) 192.168.3.243(rw,sync,no_subtree_check,no_root_squash)
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}

package_update: true
packages:
  - nfs-kernel-server
  - open-vm-tools

runcmd:
  - netplan apply
  - mkdir -p /srv/nfs/datastore
  - chown nobody:nogroup /srv/nfs/datastore
  - chmod 0777 /srv/nfs/datastore
  - exportfs -ra
  - systemctl enable --now nfs-kernel-server
  - systemctl enable --now open-vm-tools
```

> **Note**: `no_root_squash` makes the root user on ESXi the root user on
> the NFS server. Required for ESXi NFS datastores (ESXi writes VMDKs as
> root). Don't combine this with untrusted clients.

### 6.4 Generate the OVF import spec and inject vApp values

```bash
govc import.spec /tmp/ubuntu-24.04-server-cloudimg-amd64.ova > /tmp/nfs-spec.json
```

The default spec exposes these vApp properties:

| Property | Purpose |
|---|---|
| `instance-id` | cloud-init's idempotency key — set anything unique |
| `hostname` | initial hostname (cloud-init overrides this with user-data hostname) |
| `seedfrom` | URL for an external cloud-init seed (we don't use this) |
| `public-keys` | SSH key for default user |
| `user-data` | **base64-encoded** user-data YAML — primary way to configure |
| `password` | default password for the ubuntu user |

Edit the spec — base64 the user-data and inject:

```bash
USERDATA_B64=$(base64 < /tmp/nfs-userdata.yaml | tr -d '\n')

python3 <<'EOF'
import json
spec = json.load(open('/tmp/nfs-spec.json'))
spec['Name'] = 'nfs-storage'
spec['PowerOn'] = True
spec['InjectOvfEnv'] = True
spec['DiskProvisioning'] = 'thin'
props = {
    'instance-id': 'iid-nfs-storage-001',
    'hostname': 'nfs-storage',
    'user-data': open('/tmp/userdata.b64').read().strip(),
    'password': '<password>',
}
for p in spec['PropertyMapping']:
    if p['Key'] in props:
        p['Value'] = props[p['Key']]
for n in spec['NetworkMapping']:
    n['Network'] = 'VM Network'
open('/tmp/nfs-spec.json', 'w').write(json.dumps(spec, indent=2))
EOF
```

`InjectOvfEnv: True` is critical — that's what makes cloud-init see the
vApp properties at boot (otherwise they're set in vCenter but invisible
to the guest).

### 6.5 Import the OVA

```bash
govc import.ova \
  -options=/tmp/nfs-spec.json \
  -dc=Datacenter \
  -ds=datastore1 \
  -pool=/Datacenter/host/Cluster/Resources \
  -folder=/Datacenter/vm \
  /tmp/ubuntu-24.04-server-cloudimg-amd64.ova
```

`-pool=/Datacenter/host/Cluster/Resources` places the VM on the
**physical** Cluster, not the new Supervisor-Cluster.

Upload time depends on link speed to vCenter. With a ~400 KB/s
connection a 500 MB OVA takes ~20 minutes. Run with `&` or in the
background.

### 6.6 First-boot gotchas

Two issues that bit us on first boot, with workarounds:

**(a) Cloud-init's default netplan beat ours.** Cloud-init writes
`/etc/netplan/50-cloud-init.yaml` with the DHCP config during the
network module — **before** `runcmd` runs. Our `60-static.yaml` did
exist, but the cloud-init file had a more specific match (`macaddress:
00:50:56:...`) which overrode our `name: en*` match. Fix:

```bash
sudo rm /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

To prevent this on a fresh deploy, the user-data already writes
`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` with
`network: {config: disabled}`. That takes effect on *subsequent* boots
but not the first — so on first boot you still need to delete the
cloud-init netplan manually.

**(b) `apt install nfs-kernel-server` failed with
`Temporary failure resolving 'archive.ubuntu.com'`.** The EdgeRouter's
DNS forwarder (`dnsmasq`) only listens on `eth1` and `eth2` out of the
box, not `eth3` — so VMs on the LAN3 segment can't use `192.168.3.1`
for DNS even though it's the gateway.

We **fixed it at the source** on the EdgeRouter:

```
configure
set service dns forwarding listen-on eth3
commit
save
exit
```

Verify from any LAN3 host:

```bash
dig @192.168.3.1 +short example.com
# 104.20.23.154
# 172.66.147.243
```

If for some reason you can't change the router right now, the
short-term workaround on the VM is to point `/etc/resolv.conf` at
`8.8.8.8` directly:

```bash
sudo bash -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'
```

### 6.7 Install NFS server

After the workarounds:

```bash
ssh ubuntu@192.168.3.244 \
  'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server'

ssh ubuntu@192.168.3.244 \
  'sudo systemctl enable --now nfs-kernel-server && sudo exportfs -ra && sudo exportfs -v'
# /srv/nfs/datastore
#   192.168.3.241(sync,wdelay,...,rw,...,no_root_squash,...)
#   192.168.3.242(sync,wdelay,...,rw,...,no_root_squash,...)
#   192.168.3.243(sync,wdelay,...,rw,...,no_root_squash,...)
```

### 6.8 Grow the NFS server's disk

The Ubuntu cloud OVA ships with a ~10 GB virtual disk by default —
nowhere near enough for Supervisor's control-plane VMs and pod images.
Grow it online to 200 GB.

```bash
# 1. Resize the virtual disk in vCenter
govc vm.disk.change -vm /Datacenter/vm/nfs-storage \
  -disk.label 'Hard disk 1' -size 200G

# 2. Tell the Linux kernel to rescan the device for the new size
ssh ubuntu@192.168.3.244 \
  'echo 1 | sudo tee /sys/class/block/sda/device/rescan && lsblk | head -3'
#   sda  8:0   0  200G  0 disk

# 3. Grow the root partition and the filesystem on it
ssh ubuntu@192.168.3.244 \
  'sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1 && df -h /'
#   /dev/sda1  193G  2.0G  191G  1% /
```

> **Pitfall:** PVSCSI controllers don't auto-rescan when a virtual disk
> grows. Without the `echo 1 > /sys/class/block/sda/device/rescan` step,
> `lsblk` keeps reporting the old size and `growpart` says
> "NOCHANGE: partition 1 is size N. it cannot be grown".

### 6.9 Mount the NFS share as a vSphere datastore on each nested host

```bash
govc datastore.create \
  -type=nfs \
  -name=nfs-shared \
  -remote-host=192.168.3.244 \
  -remote-path=/srv/nfs/datastore \
  -mode=readWrite \
  /Datacenter/host/Supervisor-Cluster/192.168.3.241 \
  /Datacenter/host/Supervisor-Cluster/192.168.3.242 \
  /Datacenter/host/Supervisor-Cluster/192.168.3.243
```

Passing the three hosts as positional args mounts the same datastore on
each. **Critical:** every host must mount with the **same datastore
name** (`nfs-shared`) and **same remote path** or vCenter won't
recognize it as truly shared and Supervisor will refuse to deploy.

### 6.10 Verification

```bash
govc datastore.info nfs-shared
# Type:      NFS
# URL:       ds:///vmfs/volumes/<uuid>/
# Capacity:  192.7 GB
# Free:      190.8 GB
# Remote:    192.168.3.244:/srv/nfs/datastore

# Confirm same moref on all 3 hosts
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc collect "/Datacenter/host/Supervisor-Cluster/$h" datastore | grep nfs-shared
done
# (all 3 should show the same Datastore moref, e.g. Datastore:datastore-138)
```

Same moref across hosts is the proof that vSphere considers it shared
storage. HA and DRS can use it.

## Phase 7 — Load balancer for Supervisor [pivoted to vanilla HAProxy]

Supervisor in vDS networking mode (not NSX) needs an external L4 load
balancer to allocate VIPs to Kubernetes services of type LoadBalancer.

> **Heads up:** VMware's HAProxy OVA (`haproxy-v0.2.0.ova`) is the
> canonical option, but as of vCenter 9.0.2 the OVA's firstboot scripts
> never run — vCenter doesn't deliver the OVF environment XML to this
> OVA regardless of deployment method. We tried every deploy path and
> every workaround (catalogued below in **7.A**) before pivoting to a
> vanilla HAProxy Ubuntu VM (**7.B**). If you're starting fresh on
> vCenter 9.0.2 or later, jump straight to 7.B.

## Phase 7.A — HAProxy OVA (failed on vCenter 9.0.2)

### 7.1 Prerequisite — shrink the EdgeRouter DHCP pool on LAN3

HAProxy's `service_ip_range` must be a network-aligned CIDR (`/29`,
`/28`, etc.). The only aligned block that fits cleanly outside our
other statics is `192.168.3.248/29` (.248–.255), and we also need
~5 more consecutive IPs for the Supervisor control plane. To free
those up, shrink the EdgeRouter's LAN3 DHCP pool:

```
ssh admin@192.168.1.1
configure
set service dhcp-server shared-network-name LAN3 subnet 192.168.3.0/24 start 192.168.3.4 stop 192.168.3.200
commit
save
exit
```

Existing leases in `.4–.240` keep working until their renewal; new
leases only come from `.4–.200`. No service interruption.

### 7.2 Inspect the OVA's vApp properties

```bash
govc import.spec /path/to/haproxy-v0.2.0.ova > /tmp/hap-spec.json
```

The default spec exposes 3 network slots (Management / Workload /
Frontend) and these vApp properties:

| Property | Purpose |
|---|---|
| `appliance.root_pwd` | Linux root password |
| `appliance.permit_root_login` | enable SSH login as root |
| `appliance.ca_cert` / `_key` | optional CA cert/key (we use self-signed) |
| `network.hostname` | guest hostname |
| `network.nameservers` | comma-separated DNS resolvers |
| `network.management_ip` | CIDR for management interface (e.g. `192.168.3.245/24`) |
| `network.management_gateway` | gateway for management network |
| `network.workload_ip` | CIDR for workload interface |
| `network.workload_gateway` | gateway for workload network |
| `network.frontend_ip` / `_gateway` | only used in 3-NIC deployment |
| `loadbalance.service_ip_range` | CIDR pool that HAProxy allocates as VIPs |
| `loadbalance.dataplane_port` | HAProxy Dataplane API port (`5556` default) |
| `loadbalance.haproxy_user` / `_pwd` | credentials for the dataplane API |

### 7.3 Edit the spec for this lab

```python
import json
spec = json.load(open('/tmp/hap-spec.json'))
spec.update({
    'Name': 'haproxy',
    'PowerOn': True,
    'InjectOvfEnv': True,
    'DiskProvisioning': 'thin',
    'Deployment': 'default',
})
props = {
    'network.hostname':             'haproxy',
    'network.nameservers':          '192.168.3.1, 8.8.8.8',
    'network.management_ip':        '192.168.3.245/24',
    'network.management_gateway':   '192.168.3.1',
    'network.workload_ip':          '192.168.3.246/24',
    'network.workload_gateway':     '192.168.3.1',
    'appliance.root_pwd':           '<root password>',
    'appliance.permit_root_login':  'True',
    'loadbalance.service_ip_range': '192.168.3.248/29',
    'loadbalance.dataplane_port':   '5556',
    'loadbalance.haproxy_user':     'admin',
    'loadbalance.haproxy_pwd':      '<dataplane password>',
}
for p in spec['PropertyMapping']:
    if p['Key'] in props: p['Value'] = props[p['Key']]
for n in spec['NetworkMapping']:
    n['Network'] = 'VM Network'   # all 3 NICs to the same PG
open('/tmp/hap-spec.json','w').write(json.dumps(spec, indent=2))
```

### 7.4 Import [in progress]

Place the VM on the **physical** Cluster (avoid the nested cluster so
HAProxy isn't dependent on the same NFS datastore it'll later steer
traffic for):

```bash
govc import.ova \
  -options=/tmp/hap-spec.json \
  -dc=Datacenter \
  -ds=datastore1 \
  -pool=/Datacenter/host/Cluster/Resources \
  -folder=/Datacenter/vm \
  /path/to/haproxy-v0.2.0.ova
```

The OVA is ~660 MB. With OVF cached upload paths it tends to go
considerably faster than ISO uploads (we saw 40+ MB/s on the Ubuntu
import vs 400 KB/s on the early ESXi ISO).

### 7.5 What broke — failure modes catalog

After ovftool/govc/UI deploy, the VM came up but:
- Hostname stuck at `localhost` (not `haproxy`)
- IP fell back to DHCP (`.13`, `.14`, `.15`, `.16` on successive retries) instead of static `.245`
- Ports 22/443/5556 all refused connections — firstboot never started
  HAProxy, sshd, or the Dataplane API

Diagnostics that pinpointed the cause:

```bash
# extraConfig view: vApp props were stored, but...
govc vm.info -e /Datacenter/vm/haproxy | grep guestinfo.ovfEnv
#     guestinfo.ovfEnv:               (empty)
```

**`guestinfo.ovfEnv` is empty.** vCenter 9.0.2 doesn't render the OVF
environment XML for this OVA (transport: `com.vmware.guestInfo`). The
appliance's firstboot reads `vmware-rpctool "info-get guestinfo.ovfEnv"`,
gets nothing, bails out before configuring network/SSH/HAProxy.

#### Every fix we tried (all failed)

| Approach | Result |
|---|---|
| `govc import.ova -options=spec.json` with full PropertyMapping | Non-password props landed in vAppConfig; `guestinfo.ovfEnv` empty in guest |
| ovftool 4.6.3 with explicit `--prop:...=...` flags | Same |
| vSphere Client UI Deploy OVF Template (interactive) | Same |
| `govc vm.change -e "guestinfo.ovfEnv=<XML>"` after deploy | Silently dropped, key never written |
| pyvmomi `ReconfigVM_Task` with full XML body | API returned success, but key not persisted — vCenter filters this key |
| Set `vAppConfig.installBootRequired=True` + power-cycle | `guestinfo.ovfEnv` still empty |

`guestinfo.ovfEnv` is reserved by vCenter; external writes are silently
ignored. There's no path to force the appliance to firstboot correctly
on vCenter 9.0.2.

> **What would have worked:** vCenter 7.x reportedly delivered OVF env
> for this OVA. The HAProxy OVA project (`haproxytech/vmware-haproxy`)
> is also effectively abandoned — last meaningful update was 2022. So
> any future-proof path needs to assume the OVA won't be the
> load-balancer answer.

## Phase 7.B — Vanilla HAProxy on Ubuntu (working pivot) [done]

Build the load balancer from scratch on a small Ubuntu cloud VM instead
of relying on the (broken-on-9.0.2) HAProxy OVA. Same end state for
Supervisor — HAProxy on the workload network, Dataplane API on
`:5556` with TLS + basic auth, VIP pool `192.168.3.248/29`.

### 7.B.0 What HAProxy + Dataplane API actually are

Two separate binaries, same vendor (HAProxy Technologies):

| Component | Source on this VM | Role |
|---|---|---|
| `haproxy` | Ubuntu `apt` package, BSD-licensed | The actual TCP/HTTP load balancer — receives client traffic, forwards to backend pods |
| `dataplaneapi` | Pre-built Go binary from `haproxytech/dataplaneapi` GitHub releases | A REST API daemon that **edits HAProxy's config and triggers reloads** so external systems can program HAProxy without writing files by hand |

They run as **two separate systemd units** on this VM. They communicate
through:

- **`/etc/haproxy/haproxy.cfg`** — Dataplane API reads/writes this file
- **`/run/haproxy/admin.sock`** — Dataplane API sends runtime commands to a
  running HAProxy through this Unix socket (e.g. "reload your config",
  "set the weight of server X to 0")

#### Why Supervisor needs the Dataplane API

Every time someone runs `kubectl expose --type=LoadBalancer`, Supervisor
needs to allocate one of the VIPs from the configured pool
(`192.168.3.249-.254`) and:

1. Add a **frontend** on HAProxy bound to that VIP
2. Add a **backend** with the right pod IPs as servers
3. Reload HAProxy so the change is live

Doing this by editing `haproxy.cfg` and running `systemctl reload`
manually for every K8s service would be unworkable. Dataplane API
exposes those operations as JSON over HTTPS, e.g.:

```
POST /v2/services/haproxy/configuration/backends
{"name":"k8s-svc-nginx-abc123","mode":"tcp","balance":{"algorithm":"roundrobin"}}
```

Supervisor's WCP service issues those calls from inside vCenter,
authenticated with the basic-auth credentials we passed in the wizard
and TLS-pinned to the cert we generated.

#### Why they're packaged separately (vs the OVA path)

- **HAProxy Community Edition** (open-source, BSD) is *just the proxy*.
  No API.
- **HAProxy Enterprise** (commercial) bundles `dataplaneapi` plus a few
  other operational tools.
- The Dataplane API itself is **open source** (Apache 2.0) — so
  Community HAProxy + Dataplane API together gives you an
  Enterprise-style programmable LB without buying anything.

The VMware HAProxy OVA bundled both (`haproxy` + `dataplaneapi` +
their own VIP allocator called `anyiplb`) preconfigured. We rebuilt
the same stack on a plain Ubuntu cloud VM because that OVA's firstboot
doesn't work on vCenter 9.0.2 (see **7.A** for the post-mortem).

#### Endpoints Supervisor uses

| Path | Purpose |
|---|---|
| `/v2/info` | Health/version check — `200 OK` means the API is alive |
| `/v2/services/haproxy/configuration/frontends` | Add/remove/list frontends |
| `/v2/services/haproxy/configuration/backends` | Add/remove/list backends |
| `/v2/services/haproxy/configuration/servers` | Add/remove/list backend members |
| `/v2/services/haproxy/transactions` | Group several changes and commit atomically |

When Supervisor finishes enabling, you'll see those POSTs appear in
`sudo journalctl -u dataplaneapi` on the haproxy VM — that's the
green flag that WCP successfully programmed HAProxy.

### 7.B.1 Spec

| Item | Value |
|---|---|
| OS | Ubuntu 24.04 server cloud image (reuse the OVA from Phase 6) |
| CPU / RAM | 1 vCPU / 2 GB (LB is lightweight) |
| Disk | 10 GB thin (default cloudimg size is fine) |
| Placement | physical `Cluster` / `datastore1` |
| Network | `VM Network` port group, static `192.168.3.245/24` |
| Packages | `haproxy`, `openssl`, `curl`, `jq`, `open-vm-tools` |
| Extra | Dataplane API binary from haproxytech (Debian package not in Ubuntu repos) |
| Kernel sysctl | `net.ipv4.ip_nonlocal_bind=1` so HAProxy can bind to VIP addresses it doesn't own |

### 7.B.2 Cloud-init user-data

Stored in the repo at `haproxy-userdata.yaml`. Mirror of the
`nfs-storage` cloud-init pattern (same DNS workaround story, same
`50-cloud-init.yaml` removal trick) but with HAProxy-specific sysctl and
no NFS export config:

```yaml
#cloud-config
hostname: haproxy
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: <password>
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false
write_files:
  - path: /etc/netplan/60-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: en*
            dhcp4: false
            addresses: [192.168.3.245/24]
            routes: [{to: default, via: 192.168.3.1}]
            nameservers: {addresses: [192.168.3.1, 8.8.8.8]}
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}
  - path: /etc/sysctl.d/99-haproxy.conf
    content: |
      net.ipv4.ip_nonlocal_bind = 1
      net.ipv4.ip_forward = 1
package_update: true
packages: [haproxy, openssl, jq, curl, open-vm-tools, net-tools, ca-certificates]
runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml
  - chmod 600 /etc/netplan/60-static.yaml
  - netplan apply
  - sysctl --system
  - systemctl enable open-vm-tools
```

### 7.B.3 Import as `haproxy` VM

```bash
# Build spec from Ubuntu OVA, inject base64-encoded user-data
USERDATA_B64=$(base64 < haproxy-userdata.yaml | tr -d '\n')
govc import.spec ubuntu-24.04-server-cloudimg-amd64.ova > /tmp/hapvm-spec.json

python3 <<EOF
import json
spec = json.load(open('/tmp/hapvm-spec.json'))
spec.update({'Name':'haproxy','PowerOn':True,'InjectOvfEnv':True,'DiskProvisioning':'thin'})
props = {
  'instance-id': 'iid-haproxy-001',
  'hostname':    'haproxy',
  'user-data':   '$USERDATA_B64',
  'password':    '<password>',
}
for p in spec['PropertyMapping']:
    if p['Key'] in props: p['Value'] = props[p['Key']]
for n in spec['NetworkMapping']:
    n['Network'] = 'VM Network'
open('/tmp/hapvm-spec.json','w').write(json.dumps(spec, indent=2))
EOF

govc import.ova \
  -options=/tmp/hapvm-spec.json \
  -dc=Datacenter \
  -ds=datastore1 \
  -pool=/Datacenter/host/Cluster/Resources \
  -folder=/Datacenter/vm \
  ubuntu-24.04-server-cloudimg-amd64.ova
```

> **Note:** if the import fails with `dial tcp 192.168.2.75:443: connect:
> connection refused`, the ESXi host's NFC endpoint is unreachable —
> check that you have network routing to the lab network (VPN, WiFi
> bridge, etc). vCenter itself reaches the host over the lab side too,
> but the OVA upload happens directly from the client to the host.

After import + cloud-init runs the same one-time DNS/netplan workaround
we used for `nfs-storage` (the cloud-init defaults race against our
static config). Once `192.168.3.245` is up and reachable:

```bash
ssh ubuntu@192.168.3.245
# fix the netplan if cloud-init's 50-cloud-init.yaml is still winning:
sudo rm /etc/netplan/50-cloud-init.yaml && sudo netplan apply
```

### 7.B.4 Install HAProxy Dataplane API [todo]

The Dataplane API binary isn't in the Ubuntu repos. Download from
[haproxytech/dataplaneapi releases](https://github.com/haproxytech/dataplaneapi/releases),
e.g. v2.9.x. Plan to run as systemd unit on port `5556` with HTTPS +
basic-auth (`admin` / `<password>`).

```bash
DPAPI_VER=2.9.10
curl -L -o /tmp/dpapi.deb \
  "https://github.com/haproxytech/dataplaneapi/releases/download/v${DPAPI_VER}/dataplaneapi_${DPAPI_VER}_linux_amd64.deb"
sudo dpkg -i /tmp/dpapi.deb
```

(or use the tar.gz release if no .deb is available, and place the
binary at `/usr/local/bin/dataplaneapi`.)

### 7.B.5 Generate TLS cert + config [todo]

Self-signed cert for `192.168.3.245:5556`. We'll need the public cert
later for Phase 8 (Supervisor pins it).

```bash
sudo mkdir -p /etc/haproxy/certs
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/haproxy/certs/dpapi.key \
  -out    /etc/haproxy/certs/dpapi.crt \
  -days 825 \
  -subj "/CN=haproxy/O=lab" \
  -addext "subjectAltName=IP:192.168.3.245,DNS:haproxy"
sudo chmod 600 /etc/haproxy/certs/*
```

### 7.B.6 HAProxy + Dataplane API config [todo]

Minimal seed `/etc/haproxy/haproxy.cfg` that Dataplane API can mutate
later (it manages backends/frontends dynamically as Supervisor allocates
VIPs).

`/etc/haproxy/dataplaneapi.yaml` ties the API to the haproxy config and
defines the basic-auth user.

### 7.B.7 Verify

Two probes — auth and reachability — plus exporting the cert that
Supervisor will pin during Phase 8.

```bash
# From a host that can route to 192.168.3.245:
curl -sk --max-time 5 -o /dev/null -w "no-auth → %{http_code}\n" \
  https://192.168.3.245:5556/v2/info
# no-auth → 401

curl -sk -u admin:<password> --max-time 5 \
  https://192.168.3.245:5556/v2/info
# {"api":{"build_date":"2025-02-25T...","version":"v2.9.10 cada277a"},"system":{}}
```

> **API path note:** Dataplane API v2.x lives under `/v2/...`. The
> Supervisor wizard talks to that path (NOT `/v3`). If `/v2/info`
> returns 401 without creds and 200 with, you're set.

Export the cert for the Supervisor wizard's "Server Certificate
Authority" field — it pins this cert and refuses to talk to anyone
else presenting a different one.

```bash
echo | openssl s_client -connect 192.168.3.245:5556 -servername haproxy 2>/dev/null \
  | openssl x509 -outform PEM > haproxy-dpapi.crt

openssl x509 -in haproxy-dpapi.crt -noout -fingerprint -sha256 -subject -dates
# sha256 Fingerprint=3E:06:C5:B7:BA:59:C7:E3:98:6D:B3:F0:A0:1F:52:75:CA:62:37:0A:E6:DE:C2:14:A1:BC:A4:F8:70:95:7A:93
# subject=CN=haproxy, O=lab
# notBefore=...   notAfter=... (≈2 years)
```

The cert is also saved to `haproxy-dpapi.crt` in this repo for
reference.

---

## Phase 8 — Enable Supervisor on the nested cluster [in progress]

### Critical pre-requisite: NTP must be configured on the physical host

This is the single most insidious failure mode in this whole runbook.
Symptom: Supervisor enable runs for ~15 minutes, gets to `CONFIGURING`,
WCP creates the control-plane VMs, K8s comes up on them, but then
**nothing ever progresses**. HAProxy stays at zero backends, taints
never get removed, and pods stay stuck in `Pending` or `CrashLoopBackOff`.

Root cause: the physical ESXi host has **NTP disabled** by default, so
its clock drifts. The vCSA (a VM on that host) syncs its clock from the
host via VMware Tools, so it inherits the drift. The nested ESXi hosts
also drifted initially but have NTP active and converge to real time.
The control-plane VMs running on those nested hosts likewise have NTP
active and have correct time.

End result: **CP VMs are minutes-to-hours AHEAD of the vCSA's clock**.
When the CP VMs generate kube-apiserver TLS certificates, those certs'
`notBefore` is the CP's current time — which is in the *future* from the
vCSA's perspective. WCP's envoy sidecar (`localhost:1080`) tries to TLS
to the apiserver, openssl says "certificate is not yet valid", the
handshake silently fails, and WCP gets `Err <nil>` from the proxy on
every call. WCP eventually gives up trying to push the
`VSphereDistributedNetwork`, `HAProxyLoadBalancerConfig`, and
`GatewayClass` resources, and the deploy is dead.

In our lab the drift was **58 minutes**:

```
Mac (real time):                    Fri May 22 02:25:16 UTC 2026
CP1 (nested VM, NTP active):        Fri May 22 02:25:16 UTC 2026  ✓
vCSA (synced from host via Tools):  Fri May 22 01:27:32 UTC 2026  ✗ 58m slow
Physical ESXi host:                 Fri May 22 01:27:39 UTC 2026  ✗ 58m slow
                                    NTP client: Disabled
                                    NTP servers: None
```

The fix (do this BEFORE running the Supervisor wizard):

**Option A — automated** (recommended; idempotent, also handles Step 2 below):

```bash
./scripts/sv-fix-ntp                            # uses sv-env defaults
NTP_SERVER=162.159.200.1 ./scripts/sv-fix-ntp   # override the NTP server
```

This wraps the three manual steps below into one script and does
nothing if everything's already correct.

**Option B — manual commands:**

```bash
HOST=/Datacenter/host/Cluster/<your-host>

# Set NTP server — use IP, ESXi may not have DNS configured yet
# 162.159.200.1 = time.cloudflare.com (anycast)
govc host.date.change -host "$HOST" -server 162.159.200.1

# Enable + start ntpd. NB: host.service does NOT honor -host on its
# own; must set GOVC_HOST env var to disambiguate.
GOVC_HOST=$HOST govc host.service enable ntpd
GOVC_HOST=$HOST govc host.service start  ntpd

# Verify
govc host.date.info -host "$HOST"
#   NTP client status:  Enabled
#   NTP service status: Running
#   NTP servers:        162.159.200.1
```

After the host clock is correct, force the vCSA's running kernel to
catch up. The host's RTC value will propagate to the vCSA VM's RTC,
but the vCSA's *running clock* won't move until either VMware Tools
periodically syncs it OR you force it:

```bash
ssh root@<vcsa-mgmt-ip>
> shell
hwclock --hctosys --utc    # copy hardware (RTC) clock to system clock
date -u                    # verify it jumped to current real time
```

After the system clock is correct, WCP starts succeeding on its next
retry cycle (within ~30s). You should see all the missing resources
appear within 2–3 minutes:

```bash
# On a CP VM (password: /usr/lib/vmware-wcp/decryptK8Pwd.py on vCSA)
kubectl --kubeconfig=/etc/kubernetes/admin.conf get \
  vspheredistributednetworks,haproxyloadbalancerconfigs,gatewayclasses -A
# All three should now have entries
```

#### How to detect this proactively

If you suspect clock skew is the issue, this one-liner from the vCSA
confirms it:

```bash
echo | openssl s_client -connect <vip>:6443 -servername kubernetes 2>&1 \
  | grep -E 'notBefore|not yet valid'
```

If you see `certificate is not yet valid` and a `notBefore` value that's
in the future relative to `date -u`, that's the clock-skew bug.

#### Why the soft `service-control --restart wcp` doesn't help

If the wcp daemon is genuinely wedged, `service-control --restart wcp`
will print `Successfully restarted` but the PID won't actually change.
Confirm by capturing the PID before and after:

```bash
ps -ef | grep wcpsvc | grep -v grep
# wcp  173925  ...  /usr/lib/vmware-wcp/wcpsvc
service-control --restart wcp
ps -ef | grep wcpsvc | grep -v grep
# wcp  173925  ...  <-- same PID, restart was a no-op
```

If the PID didn't change you need a hard restart:

```bash
service-control --stop wcp
sleep 5
pkill -9 -f wcpsvc 2>/dev/null   # only if straggler still around
service-control --start wcp
ps -ef | grep wcpsvc | grep -v grep   # PID should now be different
```

The live wcp log is at `/storage/log/vmware/wcp/wcpsvc.log` (NOT
`/var/log/vmware/wcp/wcpsvc.log` — that one stops being written after
a restart). Tail the storage path if your restart looks like it took
but you're not seeing new log entries.

### The cluster image, not just the depot, has to match the host version

This is the subtle part. Uploading the right depot to vCenter is
necessary but **not sufficient**. The cluster has its own *declared
image* in vLCM, separate from the depot store. Even if the right base
image is sitting in the depot, the cluster's declared image can still
point at the wrong version, and that's what vLCM remediates against.

When we first switched the cluster to vLCM image mode, vCenter
auto-generated an image spec (`autogen-software-spec`) using whatever
depot was available — which was the original 8.0 U3 depot. That spec
stuck around. Even after we uploaded a fresh 9.0.2 depot, the cluster
image was still `8.0 U3e - 24674464`. Compliance still showed "3 hosts
incompatible" (running 9.0.2, declared 8.0 U3e).

**Fix:** explicitly edit the cluster image to point at the new 9.0.2
base build:

```
vSphere Client → Cluster → Updates → Image → EDIT
  → ESXi Version dropdown → 9.0.2.0 - <build>
  → VALIDATE  (warning about software compatibility metadata being
              from 2025-01 is harmless — image is still valid)
  → SAVE
```

vCenter renames the spec (`autogen-software-spec-2` etc.) and
re-evaluates compliance. The "incompatible" badge should flip to
"All hosts in this cluster are compliant".

**Side effect we noticed:** the moment we committed the corrected image,
the stuck `disable` workflow that had been sitting at `REMOVING` for
hours started progressing again. `RemoveSolutionTask` succeeded, all
three CP VMs were shut down and destroyed within 2 minutes, and config
status went to `GONE`. EAM had been blocked because it couldn't reconcile
against an unsatisfiable image; once the image was satisfiable, it
finished cleaning up the old state.

So: **always validate cluster image first** before troubleshooting
WCP/EAM hangs.

### Critical pre-requisite: vLCM depot must match the ESXi version on the nested hosts

Before any other Phase-8 work, **the offline depot uploaded to vCenter
Lifecycle Manager must be the same major+minor ESXi version as the hosts
in the cluster**. Supervisor enables vLCM image-managed mode on the
cluster, then pushes its `spherelet` and supporting VIBs onto the hosts
*from that depot*. If the depot is the wrong version vLCM tries to also
"correct" the host's base image to whatever's in the depot, EAM's
`Apply Solution` task fails with:

```
A general system error occurred: Cannot download VIB
  '/tmp/offlineBundleXxxxxx/vib20/<module>/<VIB_NAME>.vib'
```

The VIB name encodes the version it came from. For us the failing VIB
was `spidev-esxio_0.1-1vmw.803.0.0.24022510.vib` — `803` = ESXi 8.0.3
(U3), build `24022510`. Our nested hosts were ESXi 9.0.2 build 25148076
— a major-version mismatch.

**Fix:** download the offline depot matching the running hosts from
Broadcom support, upload it via the vSphere UI:

```
vSphere Client → Lifecycle Manager → Import → Bundle (.zip) → Upload
```

Then in Cluster → Updates → Image, build/reconcile the image with the
new depot before retrying Supervisor enable.

How to confirm depot vs host versions match:

```bash
# Host version reported by vCenter
govc host.info -host /Datacenter/host/<cluster>/<host> -json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
              p=d['hostSystems'][0]['summary']['config']['product']; \
              print(p['fullName'])"

# What's currently in the patch store on the vCSA
ssh root@<vcsa-mgmt-ip>
> shell
ls /storage/updatemgr/patch-store/hostupdate/vmw/vib20/ | head
# VIB names beginning with 'spidev', 'esx-base', etc. will encode the
# build (e.g. '.803.0.0.24022510.' vs '.902.0.0.25148076.')
```

### Recovery: SSH to the vCenter Server Appliance (vCSA)

**You will need this** if a Supervisor enable/disable gets stuck (we hit
this multiple times). The `wcp` service inside vCenter is what manages
Supervisor lifecycle; when it deadlocks, none of the external APIs
(`govc namespace.cluster.disable`, REST `?action=disable`, vSphere UI
"Remove Supervisor") can recover it. Only restarting `wcp` from inside
the appliance can.

#### Connecting

The vCenter Server Appliance has SSH enabled by default for `root`, but
only on the **management LAN-side IP**, not on the public DNS name. In
this lab the vCSA's LAN2 IP is `192.168.2.80`:

```bash
ssh root@192.168.2.80
# Password: same as the vSphere SSO administrator password (Srosario1!)
```

(If your vCenter's public DNS hostname rejects SSH but the internal IP
accepts it, the firewall on the WAN side is dropping port 22. Use the
internal IP.)

You land in the appliance shell:

```
Command>
```

This is **not bash** — it's VMware's appliance management shell. To get
a real shell:

```
Command> shell
Shell access is granted to root
root@vcenter [ ~ ]#
```

You're now in Photon OS running as root. From here you have full access
to all the vCenter service daemons.

#### Inspecting `wcp` state

```bash
# Service status
service-control --status wcp

# Live logs (where to look when things stall)
tail -f /var/log/vmware/wcp/wcpsvc.log

# Errors only, recent
grep -iE 'error|fail|panic' /var/log/vmware/wcp/wcpsvc.log | tail -50

# Other WCP-related logs
ls /var/log/vmware/wcp/
```

#### Restarting `wcp` (the canonical stuck-state fix)

```bash
service-control --stop wcp
sleep 5
service-control --start wcp

# Confirm running
service-control --status wcp
```

Total downtime: ~30 seconds. Other vCenter services aren't affected; only
Supervisor management goes quiet briefly. After the restart, vCenter
re-evaluates Supervisor cluster state from scratch and can usually
continue stuck disable/enable workflows that had deadlocked.

#### Last-resort: reboot the whole vCSA

If `wcp` restart doesn't help, you can reboot the entire appliance from
inside:

```bash
shutdown -r now
# OR from VAMI web UI: https://vcenter.skynetsystems.io:5480
```

All vSphere services bounce. ~10 min downtime for vCenter itself —
running VMs and workloads aren't affected (ESXi keeps running). Useful
nuclear option when only `wcp` restart isn't enough.

#### Pitfalls

- **Public DNS SSH may be blocked.** We hit `Permission denied` from
  `ssh root@vcenter.skynetsystems.io` even with the right password.
  Internal IP (`192.168.2.80`) worked. Check both.
- **`shell` is required.** Out of the box you're in the Appliance Shell,
  which doesn't understand standard Linux commands. Type `shell` to
  drop to bash.
- **`Srosario1!` worked for both.** In this lab the vSphere SSO admin
  password and the appliance root password are the same. They were set
  independently at vCSA install time and could in principle be different
  — check both if one fails.

### Right-sizing the vCSA itself

After six failed Supervisor enable attempts we discovered the vCSA
appliance was deployed at the **Tiny** size (2 vCPU, 14 GiB RAM). WCP's
workflow holds a lot of state in memory — cluster reconciliation, EAM
solution tracking, K8s API proxying, VIB transfer staging — and Tiny
runs out of headroom. Symptom inside the appliance was 6+ GiB swap-in-use
and reconciliation tasks deadlocking before completing.

**Sizing baseline** (from VMware's official table):

| Size   | vCPU | RAM    | Notes                              |
|--------|------|--------|------------------------------------|
| Tiny   | 2    | 14 GiB | up to ~10 hosts — **too small for Supervisor** |
| Small  | 4    | 21 GiB | up to ~100 hosts                   |
| Medium | 8    | 29 GiB | up to ~400 hosts — what we ended up at |
| Large  | 16   | 37 GiB | up to ~1000 hosts                  |

Even though our lab has 3 nested hosts (well under Tiny's 10-host limit),
**Supervisor workflows themselves push WCP past Tiny's memory budget**.
Medium-equivalent (8 vCPU / 32 GiB) was enough.

**Method 1 — Online hot-add (preferred).** The vCSA OVA enables CPU and
memory hot-add by default. Confirm and resize without downtime:

```bash
VM='/Datacenter/vm/vCLS/vCenter-9-0'   # or wherever the vCSA VM lives

# Verify hot-add flags
govc vm.info -e=true "$VM" | grep -iE 'cpuHotAdd|memoryHotAdd'
#   cpuHotAddEnabled: true
#   memoryHotAddEnabled: true

# Resize CPU + RAM (megabytes for RAM)
govc vm.change -vm "$VM" -c=8 -m=32768

# Confirm hardware now reports the new size
govc vm.info "$VM" | grep -iE 'cpu|memory'

# Confirm the *guest* sees it
ssh root@192.168.2.80
> shell
nproc
free -h
```

On Photon OS (the vCSA guest), hot-added memory blocks come online
automatically; no `chcpu` / `echo online > /sys/devices/.../memory*/state`
ritual was needed. `nproc` jumped from 2 → 8 and `free -h` showed total
RAM going from 13 GiB → 31 GiB immediately.

**Method 2 — Offline resize.** If hot-add is disabled or if you also need
to change disk/reservation, power off the vCSA (which interrupts vCenter
for ~5–10 min), make the change, power back on. Same `govc vm.change`
syntax; just shut down first via `shutdown -h now` inside the VAMI or the
appliance shell.

#### Flushing swap after a resize

After hot-adding RAM, the guest sees the new memory but pages that were
previously swapped out are **still on the swap device**. Linux only pages
them back in lazily, on the next access — so WCP's working set stays
slow until something touches each cold page. Force them all back into
RAM now:

```bash
# As root on the vCSA (shell, not the appliance shell)
free -h
# before:  Mem  11Gi used / 18Gi free
#          Swap  6 GiB used

swapoff -a   # kernel walks the swap map, pages every block back into RAM
swapon -a    # re-enable swap (now empty) for future use

free -h
# after:   Mem  15Gi used / 13Gi free
#          Swap  0 B used
```

`swapoff -a` only succeeds when `free + available > used_swap`; otherwise
it blocks waiting for RAM, or fails with ENOMEM. In our case 20 GiB
available comfortably covered 6 GiB swap.

After the swap flush, WCP service has no cold-page penalty on its next
reconcile cycle.

### After cleanup: re-run the wizard

> **Gotchas we hit (now baked into the steps below)**:
> 1. The wizard error "Hosts not in DVS" — fix: created `supervisor-dvs` and
>    added all 3 nested hosts to it via a 2nd vNIC (`vmnic1`). Hot-adding a
>    pNIC requires the host to reboot to detect new PCI devices. See **8.0**.
> 2. The wizard exposes two deployment modes: **vSphere Zone** (needs
>    pre-created zones) and **Cluster Deployment** (point at a single
>    cluster). Use Cluster Deployment for a lab single-cluster setup.
> 3. **Control Plane HA** is a wizard toggle. **HA ON** deploys 3 CP VMs
>    with a floating IP (`wcp-fip`) and is appropriate for production. **HA
>    OFF** deploys a single CP VM whose own IP serves as the API endpoint
>    — appropriate for a lab and saves ~16 GiB RAM. *Earlier this runbook
>    incorrectly blamed HA-off for a stuck deploy; the actual cause was
>    the clock-skew bug above. Either setting works once the clock is
>    right.*
> 4. The "Server Certificate Authority" cert paste on the LB step is
>    the public cert from `haproxy-dpapi.crt`, not the wizard's tooltip
>    example. WCP pins it and refuses connections that don't match.

### 8.0 Pre-requisite — nested hosts must be members of a DVS

The Supervisor enable wizard requires the cluster's hosts to be members
of a vSphere Distributed Switch. By default a fresh ESXi installation
uses only standard vSwitches, so a new DVS has to be created with the
nested hosts as members. The nested hosts only have one vNIC (vmnic0)
on the outer VM Network; that NIC also carries the management vmk,
so claiming it for a DVS uplink would disconnect the host. Workaround:
**add a second vNIC** to each nested ESXi VM, dedicated to the DVS.

```bash
# 1. Hot-add a second VMXNET3 vNIC to each nested-esxi VM
for vm in nested-esxi-1 nested-esxi-2 nested-esxi-3; do
  govc vm.network.add -vm "/Datacenter/vm/$vm" \
    -net='VM Network' -net.adapter=vmxnet3
done

# 2. ESXi only detects new PCI devices at boot — reboot each host
#    sequentially (maintenance mode first so vCLS VMs migrate)
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc host.maintenance.enter "/Datacenter/host/Supervisor-Cluster/$h"
  govc host.shutdown -r=true   "/Datacenter/host/Supervisor-Cluster/$h"
  # Wait until vCenter reports connected AND esxcli responds
  until govc collect "/Datacenter/host/Supervisor-Cluster/$h" runtime.connectionState 2>/dev/null | grep -q connected && \
        govc host.esxcli -host "/Datacenter/host/Supervisor-Cluster/$h" -- system hostname get >/dev/null 2>&1; do
    sleep 8
  done
  govc host.maintenance.exit "/Datacenter/host/Supervisor-Cluster/$h"
done
```

> **Pitfall (don't use `nc -z` as the wait condition):** during reboot,
> the host's old TCP session may still be in TIME_WAIT and nc-z returns
> success against a partially-down host. The `host.maintenance.exit`
> call then fires too early and errors with "communicating with the
> remote host". Use the vCenter-side `runtime.connectionState`
> property instead — it only flips to `connected` once HOSTd is back
> and managing the host.

### 8.0a Create the DVS and port groups

```bash
# Create DVS at the datacenter level
govc dvs.create -dc=Datacenter supervisor-dvs

# Add the 3 nested hosts as members, mapping vmnic1 as the uplink
govc dvs.add -dvs=supervisor-dvs -pnic=vmnic1 \
  /Datacenter/host/Supervisor-Cluster/192.168.3.241 \
  /Datacenter/host/Supervisor-Cluster/192.168.3.242 \
  /Datacenter/host/Supervisor-Cluster/192.168.3.243

# Two port groups for the Supervisor wizard
govc dvs.portgroup.add -dvs=supervisor-dvs -type=earlyBinding -nports=32 sup-mgmt
govc dvs.portgroup.add -dvs=supervisor-dvs -type=earlyBinding -nports=32 sup-workload
```

Verify:

```bash
govc find / -type n -name 'sup-*'
# /Datacenter/network/sup-mgmt
# /Datacenter/network/sup-workload
```

### 8.0b Create a tag-based storage policy targeting nfs-shared

The wizard's Storage step asks for a Storage Policy. Default policies
(`Management Storage Policy - Single Node`, etc.) target vSAN — won't
match `nfs-shared`. Create a tag-based policy that explicitly does:

```bash
# Tag category + tag + attach to nfs-shared
govc tags.category.create -m=false -t Datastore storage-class
govc tags.create -c=storage-class supervisor-nfs
govc tags.attach -c=storage-class supervisor-nfs /Datacenter/datastore/nfs-shared

# Verify
govc tags.attached.ls -r /Datacenter/datastore/nfs-shared
# supervisor-nfs

# Policy with a rule that requires that tag
govc storage.policy.create \
  -category=storage-class \
  -tag=supervisor-nfs \
  -d='Tag-based policy targeting nfs-shared for Supervisor' \
  supervisor-storage
```

### 8.1 Run the Workload Management wizard

Workload Management is the wizard that turns a vSphere cluster into a
Supervisor cluster. We'll point it at `Supervisor-Cluster` with HAProxy
as the load balancer and the NFS datastore as shared storage.

### 8.1 Prerequisites (verify before starting)

```bash
# Cluster has HA + DRS, 3 hosts, all connected
govc collect /Datacenter/host/Supervisor-Cluster \
  configuration.dasConfig.enabled \
  configuration.drsConfig.enabled \
  summary.numHosts
# all 3 should be true / 3

# All 3 nested hosts have nfs-shared mounted as the same datastore
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc collect "/Datacenter/host/Supervisor-Cluster/$h" datastore | grep nfs-shared
done

# HAProxy Dataplane API responds
curl -sk -u admin:<password> https://192.168.3.245:5556/v2/info
```

### 8.2 Run the Workload Management wizard

vSphere Client → **Menu → Workload Management → Get Started**.

> **Note:** The values below are the *post-fix* values — i.e., what
> works after the discoveries in Phases 9 (management/workload subnet
> split), 11 (VIPs claimed on `ens192`), etc. Earlier drafts of this
> table used a single-subnet plan that failed. For a consolidated
> wizard-page-by-page cheat sheet with every field, see the
> **Wizard Quick Reference** appendix at the end of this document.

| Wizard step | Value |
|---|---|
| 1. vCenter & Network | vCenter: `vcenter.skynetsystems.io`; Network stack: **vSphere Distributed Switch** (HAProxy mode) |
| 2. Cluster | `Datacenter / Supervisor-Cluster` |
| 3. Storage | Tag-based storage policy targeting `nfs-shared` |
| 4. Load Balancer | Type: **HAProxy**; Name: `haproxy-lab`; Data plane API: `192.168.3.245:5556`; User: `admin`; Password: `Srosario1!`; VIP range: `192.168.3.249-192.168.3.254`; Server CA Certificate: paste contents of `haproxy-dpapi.crt` |
| 5. Management Network | Network: **`sup-mgmt`** (on supervisor-dvs); Starting IP: `192.168.2.231`; Subnet mask: `255.255.255.0`; Gateway: `192.168.2.1`; DNS: `192.168.2.1, 8.8.8.8`; NTP: `pool.ntp.org` |
| 6. Workload Network | Workload network: **`sup-workload`** (on supervisor-dvs); Gateway: `192.168.3.1`; Subnet: `255.255.255.0`; IP ranges: `192.168.3.201-192.168.3.230` (DHCP-free band freed in Phase 7); DNS: `192.168.3.1, 8.8.8.8`; Services CIDR: `10.96.0.0/24` (default); Pods CIDR: `10.244.0.0/20` (default) |
| 7. Advanced (Control plane) | **Size: Tiny**, **Control Plane HA: OFF** (lab) or **ON** (production) |
| 8. TKG / Content library | Optional — skip if not deploying TKG workload clusters |
| 9. Review and Confirm | **Finish** |

The deploy takes **~15–30 minutes** with HA off (1 CP VM), or 30–45 min
with HA on (3 CP VMs). The CP VM(s) spin up on the nested cluster
with `eth0` on the management subnet (`192.168.2.x`) and `eth1` on
the workload subnet (`192.168.3.x`). HAProxy gets configured with
frontend/backend pairs, and spherelet runs on each nested ESXi host.

### 8.3 Watch the deploy

```bash
# poll Supervisor status
govc namespace.cluster.ls
govc namespace.cluster.info /Datacenter/host/Supervisor-Cluster

# also visible at vSphere Client → Workload Management → Supervisors
```

### 8.4 Verify with `kubectl`

Once status is **Running**, the Supervisor API server is reachable at
the VIP HAProxy allocated (one of `192.168.3.249–.254`). Find it via
the Workload Management UI or:

```bash
govc namespace.cluster.info /Datacenter/host/Supervisor-Cluster | grep -i 'control plane'
```

Install the vSphere kubectl plugin
(https://<api-vip>/wcp/plugin/MacOS/vsphere-plugin.zip), then:

```bash
kubectl vsphere login --server=<api-vip> --insecure-skip-tls-verify \
  --vsphere-username administrator@vsphere.local
kubectl get nodes
# 3 nodes, all Ready
```

### 8.5 Create the first vSphere Namespace

```bash
# from the UI (recommended for first time): Workload Management → Namespaces → New
# or via govc:
govc namespace.create -cluster=Supervisor-Cluster sandbox
```

Deploy a test workload to confirm HAProxy VIP allocation:

```bash
kubectl create deployment nginx --image=nginx -n sandbox
kubectl expose deployment nginx --port=80 --type=LoadBalancer -n sandbox
kubectl get svc -n sandbox
# nginx   LoadBalancer  10.96.x.x   192.168.3.250   80:30xxx/TCP
```

If `EXTERNAL-IP` lands in the `.249–.254` range, the entire stack —
nested ESXi, NFS, HAProxy, Supervisor — is working end-to-end.

---

## Phase 9 — Split management and workload networks onto different subnets [done]

This phase was added mid-deploy after we discovered that having both
management and workload networks on the same `192.168.3.0/24` subnet
caused the CP VM to have two interfaces with the same network. Linux
kernel had two equal-cost routes for `192.168.3.0/24` and would
non-deterministically pick the wrong one, sending DNS queries (to
`192.168.2.1` and `8.8.8.8`) out via the workload interface — reply path
was broken, DNS timed out, wizard failed with
`ManagementNetworkDNSServerConnectionFailed`.

### 9.1 The diagnosis

```bash
# On the CP VM (via SSH-jump through HAProxy since direct SSH was timing
# out — see "Recovery" section for how to get the password):
ip -br a | grep -v 'lo '
#   eth0  UP  192.168.3.232/24  192.168.3.231/32  (management)
#   eth1  UP  192.168.3.201/24                     (workload)
ip r
#   default via 192.168.3.1 dev eth0
#   192.168.3.0/24 dev eth0 src 192.168.3.232    ← duplicate
#   192.168.3.0/24 dev eth1 src 192.168.3.201    ← duplicate
```

Two `192.168.3.0/24` routes is the bug — Linux can't decide reliably
which interface to use, so DNS traffic randomly takes the wrong one.

### 9.2 The fix — use a different subnet for management

The physical host had an existing DVS `dswitch` with a port group
`dswitch-vm` that bridges to the management LAN (`192.168.2.0/24`).
We extended supervisor-dvs to have a *second uplink* on each nested
ESXi host that bridges to `dswitch-vm`, then used port-group teaming
policy to force `sup-mgmt` traffic out the new uplink (→ 192.168.2.x)
while `sup-workload` continues to use the old uplink (→ 192.168.3.x).

End result: CP VM gets eth0 on 192.168.2.x and eth1 on 192.168.3.x.
Two different subnets, no kernel route ambiguity, DNS works.

### 9.3 Step-by-step commands

**Step 1 — Disable the current Supervisor** (mandatory; you cannot
change CP-VM networks while Supervisor is running):

```bash
export GOVC_URL='vcenter.skynetsystems.io' \
       GOVC_USERNAME='administrator@vsphere.local' \
       GOVC_PASSWORD='Srosario1!' \
       GOVC_INSECURE=true

govc namespace.cluster.disable -cluster Supervisor-Cluster

# If disable hangs at REMOVING for >5 min, bounce wcp (this is required
# any time WCP is wedged — soft `service-control --restart wcp` is
# *not* enough because it returns success without actually killing the
# process; you need the hard sequence below):
ssh root@192.168.2.80
> shell
service-control --stop wcp
sleep 3
pkill -9 -f wcpsvc 2>/dev/null
service-control --start wcp

# Wait until status=GONE and cp_vms=0:
govc namespace.cluster.ls -json   # config_status should disappear
```

**Step 2 — Hot-add a third vNIC to each nested ESXi VM, attached to
`dswitch-vm`:**

```bash
for vm in nested-esxi-1 nested-esxi-2 nested-esxi-3; do
  govc vm.network.add -vm "/Datacenter/vm/$vm" \
    -net dswitch-vm -net.adapter=vmxnet3
done

# Verify each VM now has 3 ethernet devices:
govc device.info -vm /Datacenter/vm/nested-esxi-1 | grep '^Name: *ethernet'
#   Name:  ethernet-0
#   Name:  ethernet-1
#   Name:  ethernet-2
```

The vNIC hot-add succeeds at the VM-virtual-hardware layer, but the
**nested ESXi guest doesn't pick up the new PCI device** until power
cycle. A `vm.power -r=true` (soft Tools-mediated reboot) is *not
enough* — you must fully power off and power on.

**Step 3 — Power-cycle each nested ESXi to make ESXi detect vmnic2:**

```bash
for vm in nested-esxi-1 nested-esxi-2 nested-esxi-3; do
  govc vm.power -off=true -force=true "/Datacenter/vm/$vm"
done
sleep 10
for vm in nested-esxi-1 nested-esxi-2 nested-esxi-3; do
  govc vm.power -on=true "/Datacenter/vm/$vm"
done

# Wait for hosts to come back (3–5 min):
until [ "$(for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc host.info -host /Datacenter/host/Supervisor-Cluster/$h -json | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['hostSystems'][0]['runtime']['connectionState'])"
done | grep -c connected)" = "3" ]; do sleep 20; done

# Confirm vmnic2 now visible:
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  govc host.info -host /Datacenter/host/Supervisor-Cluster/$h -json | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(n['device'] for n in d['hostSystems'][0]['config']['network']['pnic']))"
done
# Should show: vmnic0 vmnic1 vmnic2 for each
```

**Step 4 — Add vmnic2 as a second uplink to supervisor-dvs.** govc
doesn't support modifying existing DVS host members, so we use
pyvmomi:

```bash
pip3 install pyvmomi --break-system-packages
```

```python
# /tmp/add-uplink.py
import ssl, time
from pyVim.connect import SmartConnect
from pyVmomi import vim

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
si = SmartConnect(host='vcenter.skynetsystems.io',
                  user='administrator@vsphere.local',
                  pwd='Srosario1!', sslContext=ctx)
content = si.RetrieveContent()

# Find supervisor-dvs and the 3 nested hosts
dvs = next(n for dc in content.rootFolder.childEntity
           for n in dc.networkFolder.childEntity
           if isinstance(n, vim.DistributedVirtualSwitch) and n.name=='supervisor-dvs')

hosts = {}
for dc in content.rootFolder.childEntity:
    for cluster in dc.hostFolder.childEntity:
        if hasattr(cluster,'host'):
            for h in cluster.host:
                if h.name in ('192.168.3.241','192.168.3.242','192.168.3.243'):
                    hosts[h.name] = h

host_specs = []
for ip, host in hosts.items():
    host_specs.append(vim.dvs.HostMember.ConfigSpec(
        operation='edit', host=host,
        backing=vim.dvs.HostMember.PnicBacking(pnicSpec=[
            vim.dvs.HostMember.PnicSpec(pnicDevice='vmnic1'),
            vim.dvs.HostMember.PnicSpec(pnicDevice='vmnic2'),
        ]),
    ))
task = dvs.ReconfigureDvs_Task(spec=vim.DistributedVirtualSwitch.ConfigSpec(
    configVersion=dvs.config.configVersion, host=host_specs))
while task.info.state == vim.TaskInfo.State.running:
    time.sleep(2)
print(task.info.state)
```

Run it:

```bash
python3 /tmp/add-uplink.py
# success

# Verify each host now has both pnics as uplinks:
python3 -c "
import ssl
from pyVim.connect import SmartConnect
from pyVmomi import vim
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
si = SmartConnect(host='vcenter.skynetsystems.io', user='administrator@vsphere.local', pwd='Srosario1!', sslContext=ctx)
dvs = next(n for dc in si.RetrieveContent().rootFolder.childEntity
           for n in dc.networkFolder.childEntity
           if isinstance(n, vim.DistributedVirtualSwitch) and n.name=='supervisor-dvs')
for hm in dvs.config.host:
    print(f'  {hm.config.host.name}: {[ps.pnicDevice for ps in hm.config.backing.pnicSpec]}')
"
# Expected:
#   192.168.3.241: ['vmnic1', 'vmnic2']
#   192.168.3.242: ['vmnic1', 'vmnic2']
#   192.168.3.243: ['vmnic1', 'vmnic2']
```

**Step 5 — Configure port-group teaming policy** so each port group
egresses out a specific uplink. The DVS internally names its uplinks
`uplink1`, `uplink2`, `uplink3`, `uplink4` (note: lowercase, no spaces
— "Uplink 1" with a space is *invalid*).

```python
# /tmp/teaming.py
import ssl, time
from pyVim.connect import SmartConnect
from pyVmomi import vim

ctx = ssl.create_default_context()
ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
si = SmartConnect(host='vcenter.skynetsystems.io',
                  user='administrator@vsphere.local',
                  pwd='Srosario1!', sslContext=ctx)
content = si.RetrieveContent()

def get_pg(name):
    for dc in content.rootFolder.childEntity:
        for n in dc.networkFolder.childEntity:
            if isinstance(n, vim.dvs.DistributedVirtualPortgroup) and n.name == name:
                return n

def set_teaming(pg, active):
    upo = vim.dvs.VmwareDistributedVirtualSwitch.UplinkPortOrderPolicy(
        inherited=False, activeUplinkPort=active, standbyUplinkPort=[])
    teaming = vim.dvs.VmwareDistributedVirtualSwitch.UplinkPortTeamingPolicy(
        inherited=False, uplinkPortOrder=upo)
    cfg = vim.dvs.VmwareDistributedVirtualSwitch.VmwarePortConfigPolicy(
        uplinkTeamingPolicy=teaming)
    spec = vim.dvs.DistributedVirtualPortgroup.ConfigSpec(
        configVersion=pg.config.configVersion, defaultPortConfig=cfg)
    task = pg.ReconfigureDVPortgroup_Task(spec=spec)
    while task.info.state == vim.TaskInfo.State.running: time.sleep(2)
    return task.info.state

# sup-mgmt → vmnic2 (uplink2) → dswitch-vm → 192.168.2.x
print(set_teaming(get_pg('sup-mgmt'), ['uplink2']))
# sup-workload → vmnic1 (uplink1) → outer VM Network → 192.168.3.x
print(set_teaming(get_pg('sup-workload'), ['uplink1']))
```

```bash
python3 /tmp/teaming.py
#   success
#   success
```

**Step 5b — Open dswitch-vm's security policy.** Easy to miss: the
outer port group that vmnic2 attaches to (here, `dswitch-vm`) must
permit promiscuous mode, forged transmits, and MAC changes — same
reason we needed it on `VM Network` back in Phase 1. The CP VM sends
frames with its own MAC out via the nested ESXi's vmnic2; from
`dswitch-vm`'s perspective, that's a *foreign* source MAC, and with
the default "Reject" policy the frames are silently dropped. Symptom
is the same DNS-server-unreachable wizard error as before, even though
the routing/teaming is now correct.

Check the current policy:

```python
# /tmp/check-sec.py
import ssl
from pyVim.connect import SmartConnect
from pyVmomi import vim
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
si = SmartConnect(host='vcenter.skynetsystems.io',
                  user='administrator@vsphere.local',
                  pwd='Srosario1!', sslContext=ctx)
for dc in si.RetrieveContent().rootFolder.childEntity:
    for n in dc.networkFolder.childEntity:
        if isinstance(n, vim.dvs.DistributedVirtualPortgroup) and n.name == 'dswitch-vm':
            sec = n.config.defaultPortConfig.securityPolicy
            print(f'  Promiscuous: {sec.allowPromiscuous.value}')
            print(f'  Forged TX:   {sec.forgedTransmits.value}')
            print(f'  MAC Changes: {sec.macChanges.value}')
```

Flip all three to True:

```python
# /tmp/fix-sec.py
import ssl, time
from pyVim.connect import SmartConnect
from pyVmomi import vim
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
si = SmartConnect(host='vcenter.skynetsystems.io',
                  user='administrator@vsphere.local',
                  pwd='Srosario1!', sslContext=ctx)
for dc in si.RetrieveContent().rootFolder.childEntity:
    for n in dc.networkFolder.childEntity:
        if isinstance(n, vim.dvs.DistributedVirtualPortgroup) and n.name == 'dswitch-vm':
            pg = n; break

sec = vim.dvs.VmwareDistributedVirtualSwitch.SecurityPolicy(
    inherited=False,
    allowPromiscuous=vim.BoolPolicy(inherited=False, value=True),
    forgedTransmits=vim.BoolPolicy(inherited=False, value=True),
    macChanges=vim.BoolPolicy(inherited=False, value=True),
)
cfg = vim.dvs.VmwareDistributedVirtualSwitch.VmwarePortConfigPolicy(securityPolicy=sec)
spec = vim.dvs.DistributedVirtualPortgroup.ConfigSpec(
    configVersion=pg.config.configVersion, defaultPortConfig=cfg)
task = pg.ReconfigureDVPortgroup_Task(spec=spec)
while task.info.state == vim.TaskInfo.State.running: time.sleep(1)
print(task.info.state)
```

**vSphere UI equivalent:** vSphere Client → Networking → dswitch →
right-click `dswitch-vm` → **Edit Settings** → **Security** → set
all three to **Accept** → OK.

After this, `ping 192.168.2.232` from the Mac should work, and the
CP VM should be able to resolve `vcenter.skynetsystems.io` via the
configured DNS servers. WCP will then complete its workflow on the
next retry (or after a `service-control --stop/start wcp` hard
restart).

#### Why this is the same fix as Phase 1, but on a different port group

Phase 1 enabled promiscuous/forged-transmits/MAC-changes on the *outer*
`VM Network` port group on `vSwitch1`, because that's where the nested
ESXi VMs lived (and their vmnic0/vmnic1 needed to forward frames for
nested VMs). When we added a third vNIC to each nested ESXi that
attaches to a *different* outer port group (`dswitch-vm` on the
physical host's dswitch DVS), that new port group needed the same
security relaxation. Easy to miss because it's not the same physical
switch object as VM Network — it's on a different DVS entirely.

**General rule for nested ESXi:** any outer port group that backs an
inner ESXi vmnic must have `Allow Promiscuous`, `Allow Forged Transmits`,
and `Allow MAC Changes` all set to **Accept**. Forgetting this on even
*one* port group silently drops traffic in a way that's very hard to
diagnose from the inside.

**Step 6 — Re-run the Workload Management wizard** with corrected
inputs. Same as before *except*:

| Wizard field | Old (broken) | New |
|---|---|---|
| Management Network | sup-mgmt | sup-mgmt (no change, port group is reused) |
| Mgmt Starting IP | `192.168.3.231` | **`192.168.2.231`** |
| Mgmt Gateway | `192.168.3.1` | **`192.168.2.1`** |
| Mgmt DNS | `192.168.2.1, 8.8.8.8` | `192.168.2.1, 8.8.8.8` (no change) |
| Workload Network | sup-workload | sup-workload (no change) |
| Workload IP range | `192.168.3.x` | `192.168.3.x` (no change) |
| HAProxy mgmt endpoint | `192.168.3.245:5556` | `192.168.3.245:5556` (no change) |
| VIP pool | `192.168.3.248/29` | `192.168.3.248/29` (no change) |

The CP VM will now boot with `eth0` on `192.168.2.231` and `eth1` on
the workload subnet — two distinct subnets, no kernel route conflict.

---

## Phase 10 — Fix the HAProxy Dataplane API systemd flag [done]

This phase was added late after attempt #9. Symptom: Supervisor enable
got *almost* all the way through. K8s came up, the management network
worked, operators were running, GatewayClass and Gateway objects all
appeared. But **Service objects of type LoadBalancer stayed forever at
`EXTERNAL-IP: <pending>`** and the HAProxy backends count stayed at zero.

The vSphere wizard reported `Timed out waiting for LB service update.
This operation is part of the cluster enablement and will be retried.`

### Diagnosis

On the CP VM (SSH-jumped through HAProxy because direct SSH was
unreachable from the workload subnet at first):

```bash
kubectl logs -n vmware-system-lbapi \
  deploy/vmware-system-lbapi-lbapi-controller-manager --tail=20 -c manager \
  | grep -iE 'error|fail|gateway'

# Repeated error:
#   failed to commit transaction: 400 Bad Request
```

So lbapi could *create* Gateways but couldn't `PUT` (commit) the
transaction against HAProxy Dataplane API. From the HAProxy VM side
we sent a manual transaction to see the specific error:

```bash
VER=$(curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/services/haproxy/configuration/version)
TX=$(curl -sk -u admin:'Srosario1!' -X POST https://192.168.3.245:5556/v2/services/haproxy/transactions?version=$VER)
TX_ID=$(echo "$TX" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

curl -sk -u admin:'Srosario1!' -X POST -H 'Content-Type: application/json' \
  "https://192.168.3.245:5556/v2/services/haproxy/configuration/backends?transaction_id=$TX_ID" \
  -d '{"name":"test_be","mode":"tcp","balance":{"algorithm":"roundrobin"}}'

curl -sk -u admin:'Srosario1!' -X PUT "https://192.168.3.245:5556/v2/services/haproxy/transactions/$TX_ID"
# 400: "config parsing [/tmp/haproxy/dataplaneapi.yaml.<txid>:5]: unknown
#  keyword 'config_version:' out of section"
```

The transaction snapshot file path was wrong — `/tmp/haproxy/dataplaneapi.yaml.<txid>`
instead of `/tmp/haproxy/haproxy.cfg.<txid>`. `haproxy -c -f` was being
run on a YAML file rather than the HAProxy config file.

Also, inspecting the *current* dataplaneapi.yaml on disk with `cat -A`:

```
# _md5hash=02799a591b12e754f1be4d6927597d53$
# _version=2$
# Dataplaneapi managed File$
config_version: 2$
name: haproxy-lab$
mode: single$
status: ""$
dataplaneapi:$
host: 0.0.0.0$         # ← NOT INDENTED, should be under dataplaneapi:
port: 5556$            # ← NOT INDENTED
advertised:$           # ← NOT INDENTED
```

The YAML had **lost all its indentation**. dataplaneapi had been
rewriting it. The `# Dataplaneapi managed File` header is the give-away
— that header is what dataplaneapi adds to *the HAProxy config file
it manages*. dataplaneapi was treating its own YAML config as if it
were `haproxy.cfg`.

### Root cause

`dataplaneapi --help` shows:

```
-f=                       Path to the dataplane configuration file
                          (default: /etc/haproxy/dataplaneapi.yaml)
-c, --config-file=        Path to the haproxy configuration file
                          (default: /etc/haproxy/haproxy.cfg)
```

**The flag names are confusingly named.** `--config-file=` sounds like
it should be the daemon's own config, but it's actually for HAProxy.
The original `haproxy-setup.sh` used:

```
ExecStart=/usr/local/bin/dataplaneapi --config-file=/etc/haproxy/dataplaneapi.yaml
```

So dataplaneapi was started with `dataplaneapi.yaml` as the HAProxy
config file. It then "managed" it (added headers, rewrote without
indentation), and for every transaction copied that file to
`/tmp/haproxy/dataplaneapi.yaml.<txid>` and ran `haproxy -c -f` on it.
Of course that fails because YAML is not HAProxy syntax → 400 on every
commit → lbapi never makes progress → Supervisor enable stuck at LB
service step.

### The fix

```bash
# On the HAProxy VM
sudo systemctl stop dataplaneapi

# Fix the systemd unit
sudo tee /etc/systemd/system/dataplaneapi.service >/dev/null <<'UNIT'
[Unit]
Description=HAProxy Dataplane API
After=network-online.target haproxy.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dataplaneapi -f /etc/haproxy/dataplaneapi.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNIT

# Restore clean dataplaneapi.yaml (the previous one was corrupted)
sudo tee /etc/haproxy/dataplaneapi.yaml >/dev/null <<'YAML'
config_version: 2
name: haproxy-lab
mode: single

dataplaneapi:
  host: 0.0.0.0
  port: 5556
  scheme:
    - https
  tls:
    tls_host: 0.0.0.0
    tls_port: 5556
    tls_certificate: /etc/haproxy/certs/dpapi.crt
    tls_key: /etc/haproxy/certs/dpapi.key
  user:
    - name: admin
      password: $1$s2q30d/g$3G.M.xOTUC2QcYjHNQ6l2.   # md5 hash of Srosario1!
      insecure: false
  transaction:
    transaction_dir: /tmp/haproxy
  resources:
    maps_dir: /etc/haproxy/maps
    ssl_certs_dir: /etc/haproxy/ssl

haproxy:
  config_file: /etc/haproxy/haproxy.cfg
  haproxy_bin: /usr/sbin/haproxy
  reload:
    reload_delay: 2
    reload_cmd: "systemctl reload haproxy"
    restart_cmd: "systemctl restart haproxy"
    status_cmd: "systemctl is-active haproxy"
YAML
sudo chmod 600 /etc/haproxy/dataplaneapi.yaml

# Restore a clean haproxy.cfg (in case it was also corrupted)
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'HCFG'
global
  log /dev/log local0
  log /dev/log local1 notice
  chroot /var/lib/haproxy
  stats socket /run/haproxy/admin.sock mode 660 level admin
  stats timeout 30s
  user haproxy
  group haproxy
  daemon

defaults
  log     global
  mode    tcp
  option  tcplog
  option  dontlognull
  timeout connect 5s
  timeout client  50s
  timeout server  50s
HCFG
sudo chown root:haproxy /etc/haproxy/haproxy.cfg
sudo chmod 644 /etc/haproxy/haproxy.cfg

# Clean leftover failed transaction state
sudo rm -rf /tmp/haproxy/failed/* /tmp/haproxy/*.*
sudo mkdir -p /tmp/haproxy

# Restart services
sudo systemctl daemon-reload
sudo systemctl restart haproxy
sudo systemctl start dataplaneapi
```

Verify a transaction commit succeeds:

```bash
VER=$(curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/services/haproxy/configuration/version)
TX=$(curl -sk -u admin:'Srosario1!' -X POST "https://192.168.3.245:5556/v2/services/haproxy/transactions?version=$VER")
TX_ID=$(echo "$TX" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

curl -sk -u admin:'Srosario1!' -X POST -H 'Content-Type: application/json' \
  "https://192.168.3.245:5556/v2/services/haproxy/configuration/backends?transaction_id=$TX_ID" \
  -d '{"name":"test_be","mode":"tcp","balance":{"algorithm":"roundrobin"}}'

curl -sk -u admin:'Srosario1!' -X PUT "https://192.168.3.245:5556/v2/services/haproxy/transactions/$TX_ID"
# Expect: {"_version":1,"id":"...","status":"success"}

# Clean up the test
NEW_VER=$(curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/services/haproxy/configuration/version)
curl -sk -u admin:'Srosario1!' -X DELETE "https://192.168.3.245:5556/v2/services/haproxy/configuration/backends/test_be?version=$NEW_VER"
```

Once the commit succeeds, lbapi will pick up on its next reconcile
round (within ~30s) and HAProxy backends will appear:

```bash
curl -sk -u admin:'Srosario1!' \
  https://192.168.3.245:5556/v2/services/haproxy/configuration/backends \
  | python3 -m json.tool

# Expect ~5 backends, one per LoadBalancer Service:
#   domain-c130:<uuid>-vmware-system-csi-vsphere-csi-controller-syncer
#   domain-c130:<uuid>-kube-system-kube-apiserver-lb-svc-kube-apiserver
#   domain-c130:<uuid>-kube-system-kube-apiserver-lb-svc-nginx
#   domain-c130:<uuid>-kube-system-mgmt-image-proxy-default
#   domain-c130:<uuid>-vmware-system-csi-vsphere-csi-controller-ctlr
```

### How lbapi (vmware-system-lbapi-controller-manager) works

End-to-end mapping from a Kubernetes `Service{type: LoadBalancer}` to
an HAProxy backend:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   Kubernetes (Supervisor) side                                               │
│   ─────────────────────────                                                  │
│                                                                              │
│   HAProxyLoadBalancerConfig                                                  │
│     (created by WCP from wizard inputs:                                      │
│      dataplane URL, credentials, cert, VIP pool)                             │
│           │                                                                  │
│           │ watched by netop                                                 │
│           ▼                                                                  │
│   GatewayClass: haproxy                                                      │
│     (advertises HAProxy as a LoadBalancer impl)                              │
│                                                                              │
│                                                                              │
│   Service { type: LoadBalancer, ports: [...] }                               │
│           │                                                                  │
│           │ watched by lbapi controller                                      │
│           ▼                                                                  │
│   Gateway (kind=Gateway, gatewayClassName=haproxy)                           │
│     (per-service: namespace/<service-name>)                                  │
│                                                                              │
│                                                                              │
│   lbapi reconcile loop, for each Gateway:                                    │
│      1. Resolve Service → backend pods → endpoint IPs                        │
│      2. Allocate a VIP from the configured pool                              │
│      3. Open a transaction on HAProxy Dataplane API                          │
│      4. Define a backend with backend pods as servers                        │
│      5. Define a frontend listening on the VIP for the Service's ports       │
│      6. Commit the transaction (Dataplane API runs `haproxy -c` first,       │
│         then `systemctl reload haproxy`)                                     │
│      7. Once HAProxy is reloaded, write EXTERNAL-IP on the Service           │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼  POST / PUT over HTTPS
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   HAProxy Dataplane API                                                      │
│   ─────────────────────                                                      │
│                                                                              │
│   /v2/services/haproxy/transactions      open/commit transactions            │
│   /v2/services/haproxy/configuration/    CRUD on backends, frontends,        │
│        ├── backends                       servers, binds, ACLs, etc.         │
│        ├── frontends                                                         │
│        ├── servers                                                           │
│        └── binds                                                             │
│                                                                              │
│   Internally:                                                                │
│   - parses /etc/haproxy/haproxy.cfg via go-haproxy-config-parser             │
│   - applies pending changes in a per-transaction temp file                   │
│   - on commit: `haproxy -c -f <tmp>` validates → success or 400              │
│   - if valid: atomically renames temp → /etc/haproxy/haproxy.cfg             │
│   - then runs reload_cmd (`systemctl reload haproxy`)                        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│   HAProxy proper                                                             │
│   ─────────────                                                              │
│                                                                              │
│   frontend kube-apiserver-fe                                                 │
│     bind 192.168.3.249:6443                                                  │
│     default_backend kube-apiserver-be                                        │
│                                                                              │
│   backend kube-apiserver-be                                                  │
│     server cp1 192.168.2.232:6443 check                                      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

So a single `Service{type: LoadBalancer}` request from Supervisor flows
through netop (LB-class discovery) → lbapi (transaction orchestration)
→ Dataplane API (transaction tracking + `haproxy -c` validation +
reload) → HAProxy (actual traffic forwarding). When *any* step fails
silently (like our 400-Bad-Request bug), the Service's `EXTERNAL-IP`
stays `<pending>` indefinitely and the wizard never finishes.

---

## Phase 11 — Make HAProxy VIPs actually reachable [done]

This was the final blocker. Symptoms:

- `config_status: RUNNING` ✓
- HAProxy frontends defined with VIPs (`.249/.250/.251`) ✓
- HAProxy's `ss -ltn` showed it listening on those VIPs ✓
- But ping/connect to the VIPs from anywhere failed
- Host Nodes wizard step stuck at 3/12 conditions for 75+ minutes,
  showing "context deadline exceeded" — spherelet on each ESXi can't
  reach the kube-apiserver LB to join as a worker.

### Root cause

The original cloud-init for the HAProxy VM
(`haproxy-userdata.yaml`) sets:

```
net.ipv4.ip_nonlocal_bind = 1
```

This sysctl only affects the **bind()** syscall — it allows a process
to bind to a socket on an IP that isn't configured on any interface.
That lets HAProxy *listen* on the VIPs without owning them. But the
kernel still doesn't:

- Add the IP to any interface
- Respond to ARP for the IP
- Reply to ICMP/ping for the IP

So even though HAProxy is "listening on .251", an incoming packet
addressed to .251 never makes it to HAProxy because nothing on the
network claims the address at layer 2. The packet just gets dropped
by the router that can't ARP-resolve it.

The VMware HAProxy OVA (which we couldn't get to deploy in Phase 7.A)
handles this automatically — its setup script claims the VIPs as
floating IPs on the workload-network interface. When we pivoted to
vanilla HAProxy in Phase 7.B we configured the sysctl but didn't
add the equivalent of that IP-claiming step.

### Fix

On the HAProxy VM, add each VIP from the configured pool as a `/32`
secondary address on the primary interface. The kernel will then
own them at layer 2 (answer ARP, deliver packets to the listening
socket, respond to ICMP):

```bash
# Live (immediate, lost on reboot):
for ip in 192.168.3.249 192.168.3.250 192.168.3.251 \
         192.168.3.252 192.168.3.253 192.168.3.254; do
  sudo ip addr add $ip/32 dev ens192
done

# Persistent (survives reboot) via netplan:
sudo tee /etc/netplan/61-vips.yaml >/dev/null <<'NET'
network:
  version: 2
  ethernets:
    ens192:
      addresses:
        - 192.168.3.245/24
        - 192.168.3.249/32
        - 192.168.3.250/32
        - 192.168.3.251/32
        - 192.168.3.252/32
        - 192.168.3.253/32
        - 192.168.3.254/32
NET
sudo chmod 600 /etc/netplan/61-vips.yaml
```

The new netplan file does NOT need `netplan apply` if you already
added the IPs live — it just makes them stick across reboots. Calling
`netplan apply` would temporarily flap the interface, which is
unnecessary mid-deploy.

### Verify

From the Mac (or any client):

```bash
for ip in 192.168.3.249 192.168.3.250 192.168.3.251 \
         192.168.3.252 192.168.3.253 192.168.3.254; do
  ping -c1 -W2 $ip >/dev/null && echo "  $ip OK" || echo "  $ip DEAD"
done
# Should be: all OK
```

From a nested ESXi (via govc, since you may not have direct SSH):

```bash
for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  GOVC_HOST=/Datacenter/host/Supervisor-Cluster/$h \
    govc host.esxcli -- network diag ping \
      --host=192.168.3.251 --count=2 --wait=1
done
# Expect "Received: 2" from each
```

Once VIPs are reachable, spherelet's retry loop on each ESXi host
will succeed at joining the kube-apiserver. The remaining Host Nodes
wizard conditions complete within a few minutes and `kubernetes_status`
transitions from `WARNING` to `RUNNING`.

### Background — how ARP actually works, and why `ip_nonlocal_bind` isn't enough

The "kernel won't respond to ARP for that IP" remark above is the
crux of the bug. This subsection explains the mechanism in detail so
the fix isn't cargo-culted.

#### What ARP is

ARP (Address Resolution Protocol) translates **IP addresses** (layer 3)
to **MAC addresses** (layer 2). Ethernet frames travel based on MAC;
IP routing knows nothing about MACs. Any host wanting to send a packet
to an IP on its local subnet (or to its default gateway) must first
ask "who has this IP, and what's your MAC?"

#### The wire-level exchange (Mac → VIP `.251`)

When the Mac wants to ping `192.168.3.251`:

```
Step 1: Mac sees 192.168.3.251 is off-subnet (its own subnet is .1.x),
        so it sends to its default gateway (192.168.1.1 = EdgeRouter).
        Mac ARPs for .1.1, gets EdgeRouter's MAC, sends the IP packet.

Step 2: EdgeRouter receives the packet. Sees destination is .3.251.
        EdgeRouter has an interface on 192.168.3.0/24 (LAN3, eth3).
        It needs to deliver the packet on LAN3 — but to do that it
        needs the destination's MAC. So it ARPs:

        EdgeRouter sends a BROADCAST ARP request out eth3:
        ┌────────────────────────────────────────────────────┐
        │ Ethernet header                                    │
        │   src MAC = EdgeRouter LAN3 MAC                    │
        │   dst MAC = ff:ff:ff:ff:ff:ff   (broadcast)        │
        │ Type      = ARP                                    │
        │ ARP payload:                                       │
        │   Operation: REQUEST                               │
        │   Sender IP/MAC = 192.168.3.1 / EdgeRouter MAC     │
        │   Target IP     = 192.168.3.251                    │
        │   Target MAC    = 00:00:00:00:00:00 (unknown)      │
        └────────────────────────────────────────────────────┘

Step 3: Every host on LAN3 sees this broadcast.
        Each host's kernel checks "Do I own 192.168.3.251?"
        If yes, it replies. If no, it silently ignores.

Step 4: The host that owns .251 unicasts an ARP REPLY:
        ┌────────────────────────────────────────────────────┐
        │   src MAC = (this host's MAC)                      │
        │   dst MAC = EdgeRouter LAN3 MAC                    │
        │ ARP payload:                                       │
        │   Operation: REPLY                                 │
        │   Sender IP/MAC = 192.168.3.251 / (this host's MAC)│
        └────────────────────────────────────────────────────┘

Step 5: EdgeRouter caches the binding (IP→MAC) in its ARP table, then
        forwards the original packet using the learned MAC. Future
        packets to .251 skip steps 2–4 until the cache expires.
```

If **step 4 never happens**, the EdgeRouter has nowhere to send the
packet. It typically retries 3–5 times, then drops the packet and the
original ping fails with "Request timeout" — exactly what we saw.

#### How the kernel decides "do I own this IP?"

The Linux kernel's ARP responder logic — in `net/ipv4/arp.c` — asks:

```
For each incoming ARP request on interface IFACE asking about target IP TARGET:
    Look up TARGET in the kernel's local IP table (essentially `ip addr show`).
    If TARGET is configured on an interface that's UP, respond.
    Otherwise, drop silently.
```

The "local IP table" is populated when you do:

```bash
sudo ip addr add 192.168.3.249/32 dev ens192
```

That's it. No daemon, no daemon config. The kernel just adds the IP
to its in-memory list of "IPs I own," and from that moment on it will:

- Answer ARP requests for that IP (responds with `ens192`'s MAC)
- Deliver inbound packets addressed to that IP to whichever socket is bound
- Reply to ICMP/ping for that IP

There's a tunable (`arp_ignore`) that can restrict this — e.g., "only
answer when the request comes in on the *same* interface that owns the
IP" — but the default (`arp_ignore=0`) is "answer for any local IP,
regardless of which interface the request arrives on."

#### Why `ip_nonlocal_bind=1` is **not** enough

This sysctl is a small kernel patch to the `bind(2)` syscall:

```
Default behavior of bind() with a non-zero IP address:
    if IP is not assigned to a local interface → return EADDRNOTAVAIL

With ip_nonlocal_bind=1:
    skip that check, allow the bind anyway
```

That's the entire effect. It only relaxes the bind() syscall's safety
check. It does *not*:

- Touch the kernel's local IP table
- Touch the ARP responder
- Cause the kernel to deliver inbound packets to the socket

So with `ip_nonlocal_bind=1` and HAProxy bound to `192.168.3.249:6443`:

```
HAProxy: socket(); bind(0.0.0.0/192.168.3.249:6443); listen()
Kernel:  ✓ socket created, listening
         (but the kernel has no idea .249 is meaningful — it's not
          in any interface's IP list)

Inbound:
  EdgeRouter sends ARP request for .249
  → reaches the kernel's ARP responder
  → "Do I own .249?"  Kernel scans local IP list → no.
  → silent drop, no reply
  → EdgeRouter never learns a MAC for .249
  → original packet never reaches the HAProxy VM at all
```

The whole "HAProxy is listening" thing is moot if no packets ever
make it to the host.

#### What `ip addr add X/32 dev IFACE` actually does

The fix command:

```bash
sudo ip addr add 192.168.3.249/32 dev ens192
```

Step by step:

1. **Adds `.249` to the kernel's local IP table** on interface `ens192`.
2. The kernel's ARP responder now answers requests for `.249` (using
   `ens192`'s MAC).
3. The kernel's IP layer now delivers inbound packets addressed to
   `.249` to whichever local socket is bound there (HAProxy).
4. The kernel also responds to ICMP echo for `.249` (so `ping` works).

That's why the moment we ran the loop adding `.249–.254` as `/32`
secondaries on `ens192`, pings immediately returned and the K8s API
became reachable — nothing else changed.

#### Why `/32` specifically (not `/24`)

The `/32` prefix means "this IP, exactly, not a subnet." HAProxy's
primary IP is `192.168.3.245/24` (a normal 24-bit subnet, meaning
"I own .245 *and* I'm on subnet 192.168.3.0/24"). For the VIPs we want:

- The IP claimed for ARP/delivery (yes, the `/32` gives us this)
- **No** "I'm on this subnet" implication that would add a duplicate
  route to `192.168.3.0/24`

A `/24` secondary would have added a *second* route to `192.168.3.0/24`
via `ens192` — confusing the kernel just like the dual-NIC problem
in Phase 9. The `/32` is precisely "the IP, nothing else."

#### Reference table

| Mechanism | What it does | Answers ARP? |
|---|---|---|
| `bind()` on a socket | Tells the socket which IP/port to accept connections on | No |
| `ip_nonlocal_bind=1` sysctl | Lets `bind()` succeed on IPs not on any interface | No |
| `ip addr add X dev IFACE` | Adds X to the kernel's local IP table | **Yes** ← the key |
| `keepalived` / VRRP | Coordinates `ip addr add`/`del` across nodes for failover; also sends gratuitous ARP to refresh neighbor caches faster | Yes (transitively) |

### Why this matters more broadly

This is a general lesson for vanilla HAProxy in any production-ish
setup where you want VIPs separate from the host's primary IP: you
need *something* to claim the VIPs at L2. Options ranked by complexity:

1. **Static `/32` on the interface** (what we did) — simplest, no extra
   software, but if you have multiple HAProxy nodes in HA, only one can
   own each VIP at a time and there's no automatic failover.
2. **keepalived / VRRP** — claims VIPs via gratuitous ARP, failover
   between HAProxy peers. Standard for multi-node HAProxy setups.
3. **HAProxy `bind` with `tfo`/`spread-checks`** — doesn't solve the
   ARP problem; this is purely about socket-level behavior.
4. **Anycast routing** — for very large setups. Overkill for a lab.

For a single-HAProxy lab, the static `/32` approach is fine. For
production with multiple HAProxy nodes, use keepalived.

---

## Critical command reference

### Set port group security on a host

```bash
govc host.portgroup.change \
  -host /Datacenter/host/Cluster/<host> \
  -allow-promiscuous=true \
  -forged-transmits=true \
  -mac-changes=true \
  '<port-group-name>'
```

### Add a PVSCSI controller and disk to an existing VM

```bash
CTRL=$(govc device.scsi.add -vm /Datacenter/vm/<vm> -type=pvscsi)
govc vm.disk.create -vm /Datacenter/vm/<vm> -ds=<datastore> \
  -controller="$CTRL" -name=<vm>/disk1 -size=80G
```

### Drive an ESXi install via injected keystrokes

```bash
VM=/Datacenter/vm/<vm>
govc vm.keystrokes -vm "$VM" -c KEY_ENTER       # send Enter
govc vm.keystrokes -vm "$VM" -c KEY_F11         # send F11
govc vm.keystrokes -vm "$VM" -c KEY_TAB         # send Tab
govc vm.keystrokes -vm "$VM" -s 'plaintext'     # type a string
```

USB HID aliases are case-insensitive; `KEY_F11`, `KEY_ENTER`, `KEY_TAB`,
`KEY_ESC`, `KEY_LEFT/RIGHT/UP/DOWN` all work.

### Eject an ISO from a running VM

```bash
govc device.cdrom.eject -vm /Datacenter/vm/<vm> -device cdrom-3000
```

Will fail with `Connection control operation failed for disk 'ide0:0'`
if the guest is actively using the CD (e.g., during installer run).
Retry once the install completes.

### Resize a running VM (CPU / RAM hot-add)

```bash
# Verify the VM has hot-add enabled
govc vm.info -e=true /Datacenter/vm/<vm> | grep -iE 'cpuHotAdd|memoryHotAdd'

# Resize without powering off (RAM in MB)
govc vm.change -vm /Datacenter/vm/<vm> -c=<vcpu> -m=<MB>

# Example: bump vCSA to 8 vCPU / 32 GiB
govc vm.change -vm /Datacenter/vm/vCLS/vCenter-9-0 -c=8 -m=32768
```

Linux guests with `udev` rules for memory hotplug auto-online new
blocks; if not, run inside the guest:

```bash
for m in /sys/devices/system/memory/memory*/state; do
  [ "$(cat $m)" = offline ] && echo online > "$m"
done
```

After a RAM hot-add, force previously-swapped pages back into RAM:

```bash
swapoff -a && swapon -a
```

Only works while `free + available > used_swap`.

### Restart the WCP (Workload Control Plane) service on the vCSA

```bash
ssh root@<vcsa-mgmt-ip>
> shell
service-control --stop wcp
service-control --start wcp
service-control --status wcp
```

Run this whenever `govc namespace.cluster.disable/enable` submits but
no task appears in `govc tasks` — WCP has deadlocked internally and only
a service restart clears it. Total downtime ~30s; other vCenter
services aren't affected.

### Inspect a VM's storage, network, guest IP

```bash
govc device.ls -vm /Datacenter/vm/<vm>
govc device.info -vm /Datacenter/vm/<vm> <device-name>
govc vm.info -json /Datacenter/vm/<vm> | python3 -c "
import json,sys
g=json.load(sys.stdin)['virtualMachines'][0].get('guest',{})
print('ip:', g.get('ipAddress'),
      'tools:', g.get('toolsRunningStatus'),
      'state:', g.get('guestState'))
for n in g.get('net',[]) or []:
    print('  nic:', n.get('macAddress'), 'ips:', n.get('ipAddress'))
"
```

---

## Port mappings reference

A consolidated map of every port we touch, in order of how they appear
on the network path from client to Supervisor workload:

### Outside-in flow

| From | To | Port | Protocol | Purpose |
|---|---|---|---|---|
| Mac / admin | EdgeRouter LAN1 | — | IP | default gateway |
| EdgeRouter LAN2 (`192.168.2.1`) | vCSA (`.80`) | `443` | HTTPS | vSphere Client + REST API |
| EdgeRouter LAN2 (`192.168.2.1`) | vCSA (`.80`) | `22`  | SSH   | appliance shell |
| EdgeRouter LAN2 (`192.168.2.1`) | vCSA (`.80`) | `5480` | HTTPS | VAMI (vCenter Server Appliance Management Interface) |
| EdgeRouter LAN3 (`192.168.3.1`) | physical ESXi (`192.168.2.75`) | `443` | HTTPS | direct ESXi host UI / API |
| EdgeRouter LAN3 (`192.168.3.1`) | nested ESXi (`.241/.242/.243`) | `22` | SSH | host shell (when enabled) |
| EdgeRouter LAN3 (`192.168.3.1`) | nested ESXi (`.241/.242/.243`) | `443` | HTTPS | direct ESXi API |
| EdgeRouter LAN3 (`192.168.3.1`) | nfs-storage (`.244`) | `2049` | NFS-over-TCP | NFS export from nfs-storage |
| EdgeRouter LAN3 (`192.168.3.1`) | HAProxy mgmt (`.245`) | `22` | SSH | HAProxy shell |
| EdgeRouter LAN3 (`192.168.3.1`) | HAProxy mgmt (`.245`) | `5556` | HTTPS | **Dataplane API** (consumed by WCP / lbapi to program HAProxy) |

### Kubernetes API plane (VIPs claimed on HAProxy `ens192`)

| Service | VIP | Port | Backend |
|---|---|---|---|
| kube-apiserver (LB) | `192.168.3.251` | `6443` | CP VM workload IP `.3.201` |
| kube-apiserver TLS nginx redirector | `192.168.3.251` | `443` | CP VM `.3.201` |
| Supervisor mgmt-image-proxy | `192.168.3.250` | `443` | CP VM `.3.201` |
| vSphere CSI controller | `192.168.3.249` | `2112` (ctlr) / `2113` (syncer) | CP VM `.3.201` |

The full pool reserved in the wizard is `192.168.3.248/29` =
`.249–.254`. With one CP VM and three system LoadBalancer services
we use 3 VIPs initially; the rest are reserved for user-deployed
LoadBalancer services in vSphere Namespaces.

### Plane-internal ports on the CP VM

The single CP VM (192.168.2.232 mgmt / 192.168.3.201 workload) runs
the K8s control plane as static pods. Internal listeners:

| Component | Bind | Reason |
|---|---|---|
| kube-apiserver | `:6443`, `:443` (alt) | K8s API |
| etcd            | `127.0.0.1:2379`/`2380` | KV store (peer & client TLS) |
| kube-scheduler  | `:10259` | leader election |
| kube-controller-manager | `:10257` | leader election |
| coredns         | `:53` UDP/TCP + `:8080` (metrics) | cluster DNS |
| docker-registry | `:5000` (localhost) | image cache for Supervisor services |
| wcp-fip         | (managed `.231/32` floating IP — only when HA on) | API floating IP |
| spherelet on each ESXi | `:10250` (kubelet API) | from kube-apiserver to ESXi nodes |
| cluster CNI     | `:8081`/`:8085`/etc. | depending on plugin |

### Time and DNS sync ports (often forgotten)

| From | To | Port | Why |
|---|---|---|---|
| Physical ESXi → cloudflare/Google NTP | UDP `123` | clock sync — without this, **TLS fails** (Phase 8 root cause) |
| vCSA → physical host (via VMware Tools) | (in-VM channel) | clock follow-from-host |
| CP VM → DNS server (LAN2 `.1`, `8.8.8.8`) | UDP/TCP `53` | resolve `vcenter.skynetsystems.io` during enable |

---

## Port group rationale

This is the architectural summary of every port group we touched and
why each setting matters.

### `VM Network` on vSwitch1 (physical host)

- **Purpose:** the outer L2 segment for the lab workload subnet
  (`192.168.3.0/24`), reached by the EdgeRouter's LAN3 via `vmnic5`.
- **All security flags set to Accept:** required so the nested ESXi VMs
  (each running an internal vSwitch/DVS) can forward frames whose
  source MAC is from a nested VM, not the outer vNIC's MAC. Without
  forged transmits the nested traffic is silently dropped.
- **VLAN ID:** 0 (untagged).

### `dswitch-vm` on dswitch (physical host)

- **Purpose:** outer L2 segment for the *management* subnet
  (`192.168.2.0/24`), reached by the EdgeRouter's LAN2 via the
  physical host's `vmnic4` (dswitch uplink).
- **All security flags set to Accept** (we had to flip these mid-deploy,
  Phase 11 fix): exactly the same reason as VM Network — we attached a
  third vNIC of each nested ESXi to dswitch-vm to extend management
  reach into the nested DVS. Forged transmits / promiscuous / MAC
  changes must all be permitted.
- **VLAN ID:** 0.

### `supervisor-dvs` (DVS spanning the 3 nested ESXi hosts)

A cluster-wide Distributed Virtual Switch we created specifically for
Supervisor. The wizard refuses any port group that isn't on a DVS.

| Port group | Active uplink | Outer dest |
|---|---|---|
| `sup-workload` | uplink1 (vmnic1) | VM Network → 192.168.3.x |
| `sup-mgmt`     | uplink2 (vmnic2) | dswitch-vm → 192.168.2.x |

- **Why two uplinks per host:** each nested ESXi has vmnic1 (lab
  workload) and vmnic2 (mgmt bridge). The DVS lets a single switch
  carry both networks; teaming policy decides which uplink each port
  group uses.
- **Why teaming-pinned rather than failover:** with HA off there's a
  single CP VM, but in any case we *don't* want sup-mgmt traffic to
  fail over to vmnic1 (it would route into the workload subnet and
  CP VM eth0 would silently use the wrong path).
- **Why two distinct port groups for two networks rather than one:**
  Supervisor *requires* management and workload to be on different
  subnets (Phase 9 fix). The CP VM's Linux kernel can't disambiguate
  routes when both eth0 and eth1 are on the same `/24`.

### Standard vSwitches we *didn't* touch

- `vSwitch0` on the physical host has the management vmk for the host
  itself (`192.168.2.75`). Untouched.
- Each nested ESXi has its own `vSwitch0` (auto-created on install)
  with vmk0 at `192.168.3.241–.243`. The nested host's *own*
  management traffic uses vmnic0 → outer VM Network; we left this alone.

---

## Helper scripts

These reusable scripts wrap the most common one-liners we used. Drop
them in `~/bin/` or anywhere on your `PATH`.

### `~/bin/sv-env` — set govc environment

```bash
#!/usr/bin/env bash
# Source this before running govc/pyvmomi:  . sv-env
export GOVC_URL='vcenter.skynetsystems.io'
export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='Srosario1!'   # use a password manager in real life
export GOVC_INSECURE=true
```

Usage: `. sv-env  &&  govc ls`

### `~/bin/sv-state` — quick Supervisor + HAProxy status

```bash
#!/usr/bin/env bash
. sv-env

state=$(govc namespace.cluster.ls -json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0])" 2>/dev/null)
echo "Supervisor: $state"

cpvms=$(govc find /Datacenter/vm -type m -name 'SupervisorControlPlaneVM*' 2>/dev/null | wc -l | xargs)
echo "CP VMs:     $cpvms"

hb=$(curl -sk -u admin:'Srosario1!' --max-time 4 \
  https://192.168.3.245:5556/v2/services/haproxy/configuration/backends 2>/dev/null \
  | python3 -c "import json,sys;d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
echo "HAProxy:    ${hb:-?} backends"

for h in 192.168.3.241 192.168.3.242 192.168.3.243; do
  cs=$(govc host.info -host "/Datacenter/host/Supervisor-Cluster/$h" -json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['hostSystems'][0]['runtime']['connectionState'])" 2>/dev/null)
  printf "Host %s: %s\n" "$h" "$cs"
done
```

### `~/bin/sv-cp-pwd` — fetch current CP VM root password

```bash
#!/usr/bin/env bash
# Uses expect since /usr/lib/vmware-wcp/decryptK8Pwd.py is only reachable
# through the appliance shell.
expect <<'EOF'
set timeout 30
log_user 0
spawn ssh root@192.168.2.80
expect "assword:"; send "Srosario1!\r"
expect "Command>"; send "shell\r"
sleep 2
log_user 1
send "/usr/lib/vmware-wcp/decryptK8Pwd.py | grep -E '^(IP|PWD):'\r"
expect -re {PWD: .*}
sleep 1
send "exit\r"; expect "Command>"; send "exit\r"; expect eof
EOF
```

### `~/bin/sv-wcp-restart` — hard restart wcp service

```bash
#!/usr/bin/env bash
expect <<'EOF'
set timeout 90
spawn ssh root@192.168.2.80
expect "assword:"; send "Srosario1!\r"
expect "Command>"; send "shell\r"
sleep 2
send "service-control --stop wcp; sleep 3; pkill -9 -f wcpsvc 2>/dev/null; service-control --start wcp\r"
expect "Successfully started"
sleep 2
send "exit\r"; expect "Command>"; send "exit\r"; expect eof
EOF
echo "wcp restarted."
```

### `~/bin/sv-disable` — disable Supervisor cleanly

```bash
#!/usr/bin/env bash
. sv-env
govc namespace.cluster.disable -cluster Supervisor-Cluster
sv-wcp-restart   # often required before disable actually progresses
echo "Watch with: sv-state"
```

### `~/bin/sv-clocks` — verify all clocks are in sync

```bash
#!/usr/bin/env bash
. sv-env
echo "Reference (Mac/UTC):  $(date -u +%FT%TZ)"
echo "Physical ESXi:        $(govc host.date.info -host /Datacenter/host/Cluster/192.168.2.75 | awk '/Current date/{print $5,$6,$7,$8,$9}')"
# vCSA via ssh
expect <<'EOF' 2>/dev/null | grep -E 'Local time|RTC'
spawn ssh root@192.168.2.80
expect "assword:"; send "Srosario1!\r"
expect "Command>"; send "shell\r"; sleep 1
send "timedatectl | head -3\r"; sleep 2
send "exit\r"; expect "Command>"; send "exit\r"; expect eof
EOF
```

### `~/bin/sv-haproxy-config` — dump current HAProxy state

```bash
#!/usr/bin/env bash
H='https://192.168.3.245:5556'
USER='admin:Srosario1!'

echo "=== backends ==="
curl -sk -u "$USER" --max-time 4 "$H/v2/services/haproxy/configuration/backends" \
  | python3 -c "import json,sys;[print('  '+b['name']) for b in json.load(sys.stdin)['data']]"

echo "=== frontends ==="
curl -sk -u "$USER" --max-time 4 "$H/v2/services/haproxy/configuration/frontends" \
  | python3 -c "import json,sys;[print('  '+b['name']) for b in json.load(sys.stdin)['data']]"

echo "=== binds ==="
for fe in $(curl -sk -u "$USER" --max-time 4 "$H/v2/services/haproxy/configuration/frontends" \
              | python3 -c "import json,sys;[print(b['name']) for b in json.load(sys.stdin)['data']]"); do
  curl -sk -u "$USER" --max-time 4 "$H/v2/services/haproxy/configuration/binds?frontend=$fe" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin).get('data',[])
for b in d:
    print(f'  {b[\"address\"]}:{b[\"port\"]}  ({b[\"name\"]})')"
done
```

### `~/bin/sv-add-uplink` — add a 2nd uplink to supervisor-dvs (pyvmomi)

Same script used in Phase 9. Wrap the contents from that section as a
file at `~/bin/sv-add-uplink.py`.

### Make them executable

```bash
chmod +x ~/bin/sv-*
ls ~/bin/sv-*
```

---

## Phase 12 — Logging into the Supervisor cluster [done]

Two ways to talk to the K8s API on a Supervisor cluster:

1. **`kubectl vsphere` plugin** — the normal user path; authenticates
   against vSphere SSO, gets a kubeconfig for each vSphere Namespace
   the user has access to.
2. **`admin.conf` from a CP VM** — bypasses SSO entirely, gives
   cluster-admin. Useful for breakglass / lab debugging. *Not* what
   end-users should use.

### Option 1 — Install the kubectl-vsphere plugin

The plugin is served by HAProxy on port `443` of the API VIP. From a
client (Mac, Linux, Windows):

```bash
# Substitute your OS path: darwin-amd64, linux-amd64, or windows-amd64
curl -kLo /tmp/vsphere-plugin.zip \
  https://192.168.3.251/wcp/plugin/darwin-amd64/vsphere-plugin.zip

unzip -d /tmp/vsphere-plugin /tmp/vsphere-plugin.zip
sudo install -m 0755 /tmp/vsphere-plugin/bin/kubectl           /usr/local/bin/
sudo install -m 0755 /tmp/vsphere-plugin/bin/kubectl-vsphere   /usr/local/bin/

kubectl version --client
kubectl vsphere --help
```

### Option 1 — Log in

```bash
kubectl vsphere login \
  --server=192.168.3.251 \
  --insecure-skip-tls-verify \
  --vsphere-username=administrator@vsphere.local
# Password: <SSO password>
```

The plugin writes one context per accessible vSphere Namespace into
`~/.kube/config` plus a top-level Supervisor context. Switch with:

```bash
kubectl config get-contexts
kubectl config use-context 192.168.3.251           # Supervisor itself
kubectl config use-context <namespace>             # a specific namespace
```

### Option 1 — Verify access

```bash
kubectl get ns
kubectl get nodes
kubectl get pods -A | head -20
```

End-users will only see namespaces they have permission to via
vSphere SSO group membership.

### Option 2 — Use `admin.conf` from a CP VM (breakglass)

```bash
# Get the CP VM root password
sv-cp-pwd   # → PWD: <17-char password>

# Copy admin.conf to your Mac (CP mgmt IP is 192.168.2.232 in our lab)
SSHPASS='<that password>' sshpass -e \
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@192.168.2.232:/etc/kubernetes/admin.conf ~/sup-admin.conf

# The server field in the kubeconfig may be "localhost" or a CP-internal
# IP; edit it to the LB VIP so it works from your client
sed -i.bak 's|server: https://.*|server: https://192.168.3.251:6443|' ~/sup-admin.conf

# Use it
export KUBECONFIG=~/sup-admin.conf
kubectl get nodes
kubectl get pods -A
```

This kubeconfig embeds the cluster-admin client cert — guard it like a
root password and don't commit it anywhere.

### First workload — verify end-to-end LB works

```bash
# Create a vSphere Namespace via the UI:
#   vSphere Client → Workload Management → Namespaces → New Namespace
#   Name: sandbox    Cluster: Supervisor-Cluster
# (Or with admin.conf:  kubectl create namespace sandbox)

kubectl -n sandbox create deployment nginx --image=nginx
kubectl -n sandbox expose deployment nginx --port=80 --type=LoadBalancer
kubectl -n sandbox get svc nginx

# Should show EXTERNAL-IP in 192.168.3.249–.254 range:
# nginx  LoadBalancer  10.96.x.x  192.168.3.252  80:30xxx/TCP

curl http://192.168.3.252/   # should return the nginx welcome page
```

If `EXTERNAL-IP` is in the VIP pool and `curl` returns nginx HTML, the
full stack — nested ESXi → DVS → CP VM → HAProxy LB → HAProxy listening
on VIPs → routing back to client — is working end-to-end.

### Logout / context cleanup

```bash
kubectl vsphere logout
# Removes the auth tokens; namespace contexts remain in ~/.kube/config.
```

---

## Phase 13 — Running workloads on the Supervisor [partially done]

There are **two paths** to running Kubernetes workloads on this
Supervisor. Pick based on what kind of workload you're deploying.

### Path A — Pods *directly* on the Supervisor (the simple path, works today)

The Supervisor *is* a Kubernetes cluster. You can deploy pods,
deployments, services, etc. directly into a **vSphere Namespace**
without setting up any additional cluster. Each pod runs as a small
"Pod VM" (a CRX-based micro-VM on the nested ESXi hosts) rather than
as a container inside a worker node — Supervisor enforces strong
isolation between pods.

#### 13.A.1 Create a vSphere Namespace

A vSphere Namespace is a resource-bounded K8s namespace tied to a
vSphere storage policy, VM class, and user RBAC. Create one via:

**vSphere UI:**
- Workload Management → Namespaces → **New Namespace**
- Cluster: `Supervisor-Cluster`
- Name: e.g. `sandbox`
- Storage Policy: the tag-based policy targeting `nfs-shared`
- VM Class: `best-effort-small` (and add others later if needed)
- Permissions: add yourself (or whichever vSphere SSO user) as an
  Owner / Edit role

**Or via govc (handy for scripted setup):**

```bash
govc namespace.create -cluster=Supervisor-Cluster -storage="<policy-name>" sandbox
```

(`-storage=` is required; without it pods can't get persistent storage.)

#### 13.A.2 Log in to your namespace

```bash
kubectl vsphere login \
  --server=192.168.3.251 \
  --insecure-skip-tls-verify \
  --vsphere-username=administrator@vsphere.local

# A context per accessible namespace is now in ~/.kube/config:
kubectl config get-contexts
kubectl config use-context sandbox
```

#### 13.A.3 Deploy a test workload

```bash
kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: sandbox
spec:
  replicas: 2
  selector:
    matchLabels: { app: nginx }
  template:
    metadata:
      labels: { app: nginx }
    spec:
      containers:
        - name: nginx
          image: nginx
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: sandbox
spec:
  type: LoadBalancer
  selector: { app: nginx }
  ports:
    - port: 80
      targetPort: 80
YAML

kubectl -n sandbox get pods,svc
# Wait for EXTERNAL-IP in the .249-.254 range:
#   nginx LoadBalancer 10.96.x.x 192.168.3.252 80:30xxx/TCP

curl http://192.168.3.252/   # should return the nginx welcome HTML
```

If the EXTERNAL-IP lands in the VIP pool and `curl` returns nginx
HTML, the full stack (Supervisor → lbapi → HAProxy → VIP → pod) is
working end-to-end.

#### 13.A.4 Limitations of Path A

- **No `nodes`** (or rather, only the CP node + spherelet-managed ESXi
  hosts as nodes). You can't see "worker nodes" in the traditional
  sense — pods are Pod VMs scheduled directly on ESXi via spherelet.
- **No DaemonSets that target worker nodes.** With no workers (HA
  off), DaemonSets only run on the CP node, which is tainted.
- **Many Helm charts assume a regular cluster.** Charts that expect
  worker nodes, root-level kernel modules, host-network access, or
  containerd/dockershim semantics often won't work or need significant
  rework.
- **Limited operator support.** Operators that talk to Kubernetes
  internals (CSI drivers, certain controllers) may not run as Pod VMs.
- **The Pod VM API is narrower than full kubelet** — some things like
  `kubectl exec` may behave differently or require additional
  permissions.

Path A is great for stateless web apps, simple TCP/HTTP services,
demos, and Service-of-type-LoadBalancer testing. It's the cheapest
path to "I have something running on this Supervisor."

---

### Path B — TKG / VKS Workload Cluster (full K8s on top, not done yet)

If you need a *real* Kubernetes cluster — for Helm charts, complex
operators, custom CNI, GPU workloads, anything that assumes worker
nodes — the Supervisor can provision standalone K8s clusters on
demand via the **vSphere Kubernetes Service** (VKS, formerly Tanzu
Kubernetes Grid / TKG service). Each workload cluster is its own
kubeadm-based K8s with its own control-plane and worker VMs.

> **Status in our lab:** **NOT YET WORKING.** Phase 8/9 hit signature-
> verification errors for `tkg.vsphere.vmware.com` and `velero.vsphere
> .vmware.com` (see Phase 8 screenshot "8 of 9 conditions completed"
> — those two services were the unresolved condition). The VKS
> service hasn't successfully installed because we never attached a
> compatible content library. This section sketches what needs to
> happen; it isn't fully validated.

#### 13.B.1 Subscribe to (or upload) a TKG/VKS content library

VMware publishes a public content library of Photon-based K8s OVA
templates at:

```
https://wp-content.vmware.com/v2/latest/lib.json
```

(URL may rotate; check the VKS release notes for current location.)

**vSphere UI:**
- Menu → Content Libraries → **+ Create**
- Type: **Subscribed Content Library**
- Subscription URL: the above
- Download content immediately on demand (not all at once, lab disk
  space is finite)

**Or via govc:**

```bash
govc library.create -sub https://wp-content.vmware.com/v2/latest/lib.json \
  -sub-autosync=false -on-demand=true tkg-content
```

The library starts empty; OVAs get pulled on first reference.

#### 13.B.2 Activate the VKS service on the Supervisor

If VKS wasn't installed cleanly during enable (because of the
signature-verification errors), activate it now:

- vSphere UI → Workload Management → Services → **Add**
- Type: **vSphere Kubernetes Service** (or "Tanzu Kubernetes Grid")
- Content library: select the one from step 13.B.1
- Storage policy: same one used for the Supervisor namespace storage
- Wait until status flips to **Active**

If activation fails with signature errors again, check that:
- The content library is fully reachable from the CP VM (it makes
  HTTPS calls to `wp-content.vmware.com`)
- The CP VM's outbound 443 path works (route via workload gateway →
  EdgeRouter LAN3 → WAN — verify with `curl -kI https://wp-content...`
  from inside the CP VM)
- The Supervisor's certificate trust store includes whatever signing
  roots are used by the VMware content library OVAs

#### 13.B.3 Attach the library and VM classes to a namespace

Each vSphere Namespace that will host workload clusters needs the
content library + VM classes attached:

- Workload Management → Namespaces → `sandbox` → **Configure**
- Add the TKG content library
- Add VM classes (`guaranteed-small`, `best-effort-medium`, etc.) so
  the namespace knows what shapes of VM are allowed

#### 13.B.4 Create the workload cluster — Cluster YAML schema

The CRD has evolved over Supervisor versions:

- Older: `TanzuKubernetesCluster` (in `run.tanzu.vmware.com/v1alpha2`)
- Newer (vSphere 8+): full **Cluster API** — `Cluster` in
  `cluster.x-k8s.io/v1beta1`, with the *templates* (control-plane and
  worker VM specs) defined by a **`ClusterClass`** object that VMware
  pre-installs as part of the VKS service.

For vSphere 9.0.2 we're on, prefer the Cluster API form. The
**ClusterClass** approach lets you declare *what* you want in a few
lines instead of having to define every Machine, KubeadmConfig,
MachineDeployment, and so on yourself — the ClusterClass expands
those for you.

##### Full example with comments

```yaml
# /tmp/workload-cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: my-cluster              # ─── REQUIRED: name of the workload cluster
  namespace: sandbox            # ─── REQUIRED: must be an existing vSphere Namespace
                                #     (you can't put workload clusters in 'default')
spec:
  # ─────────────────────────────────────────────────────────────────────
  # clusterNetwork: CIDRs and DNS domain for INSIDE the workload cluster
  # These are isolated from the Supervisor's own CIDRs. Defaults work
  # for most cases; pick non-overlapping ranges if you have multiple
  # workload clusters that need pod-to-pod across them.
  # ─────────────────────────────────────────────────────────────────────
  clusterNetwork:
    services:
      cidrBlocks: [10.96.0.0/12]      # Service ClusterIPs inside this cluster
    pods:
      cidrBlocks: [192.168.0.0/16]    # Pod IPs (CNI hands out from here)
    serviceDomain: cluster.local      # DNS suffix for ClusterIP names

  # ─────────────────────────────────────────────────────────────────────
  # topology: the declarative shape of the cluster. This block is what
  # makes Cluster API "ClusterClass-based" — the class field references
  # a template that VMware has pre-baked. The Supervisor's ClusterClass
  # controller expands this into the dozens of underlying CAPI objects.
  # ─────────────────────────────────────────────────────────────────────
  topology:

    # The name of the pre-installed ClusterClass. For VKS this is
    # typically "tanzukubernetescluster" or the per-version variant
    # like "tkg-vsphere-default-v1.0.0". List available classes with:
    #   kubectl get clusterclass -A
    class: tanzukubernetescluster

    # Which Kubernetes version to deploy. Must match an entry in the
    # VKS catalog. List with:
    #   kubectl get tanzukubernetesreleases -A
    # Format: vMAJOR.MINOR.PATCH---vmware.N-fips.N-tkg.N
    version: v1.31.4---vmware.1-fips.1-tkg.1

    controlPlane:
      replicas: 1                # 1 for lab/single-CP, 3 for HA in production
      # Optional advanced knobs (most users don't set these):
      # metadata:
      #   labels: {"role": "control"}
      # nodeDrainTimeout: 60s

    workers:
      machineDeployments:        # list of worker pools; can have multiple
        - class: node-pool       # ── REQUIRED: ClusterClass-defined machine type
          name: workers          # ── REQUIRED: name of this pool
          replicas: 3            # ── REQUIRED: how many worker VMs in this pool
          # Optional:
          # metadata:
          #   labels: {"workload": "general"}
          # failureDomain: zone-1
          # nodeDeletionTimeout: 10s

    # variables: knobs the ClusterClass exposes. VMware's
    # tanzukubernetescluster ClusterClass typically requires/accepts:
    #
    #   vmClass         — the VM shape for both CP and worker VMs
    #                     (best-effort-small, best-effort-medium,
    #                      guaranteed-small, ...). List with:
    #                        kubectl get virtualmachineclass -n <ns>
    #   storageClass    — name of a StorageClass that backs PV
    #                     provisioning inside the workload cluster
    #   defaultStorageClass — set if storageClass should also be the
    #                     cluster-wide default
    #   nodePoolVolumes — additional disks for worker pools
    #   ntp             — NTP servers for the nodes (defaults work)
    #   proxy           — http_proxy/https_proxy for air-gapped labs
    #   trust           — additional CA bundles
    #
    # Use `kubectl describe clusterclass tanzukubernetescluster -n vmware-system-tkg`
    # to see the full variable schema for your VKS install.
    variables:
      - name: vmClass
        value: best-effort-small
      - name: storageClass
        value: <your-storage-class>
      - name: defaultStorageClass
        value: <your-storage-class>
```

##### Required vs optional fields

| Field | Required? | Notes |
|---|---|---|
| `metadata.name` | yes | DNS-1035 (lowercase, hyphen, no dots) |
| `metadata.namespace` | yes | must be an existing vSphere Namespace |
| `spec.clusterNetwork.services.cidrBlocks` | yes | one or more CIDRs |
| `spec.clusterNetwork.pods.cidrBlocks` | yes | one or more CIDRs |
| `spec.clusterNetwork.serviceDomain` | optional | defaults to `cluster.local` |
| `spec.topology.class` | yes | name of an installed ClusterClass |
| `spec.topology.version` | yes | must be an available `TanzuKubernetesRelease` |
| `spec.topology.controlPlane.replicas` | yes | 1, 3, or 5 typically |
| `spec.topology.workers.machineDeployments[]` | yes (≥1) | at least one worker pool |
| `spec.topology.variables[]` | depends on ClusterClass | usually at least `vmClass` and `storageClass` |

##### Minimum viable Cluster

If you want to start with the smallest valid Cluster (everything else
defaulted), this works:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: tiny
  namespace: sandbox
spec:
  clusterNetwork:
    services: { cidrBlocks: [10.96.0.0/12] }
    pods:     { cidrBlocks: [192.168.0.0/16] }
  topology:
    class: tanzukubernetescluster
    version: v1.31.4---vmware.1-fips.1-tkg.1
    controlPlane: { replicas: 1 }
    workers:
      machineDeployments:
        - { class: node-pool, name: w, replicas: 1 }
    variables:
      - { name: vmClass,      value: best-effort-small }
      - { name: storageClass, value: <your-storage-class> }
```

This produces a 2-VM cluster (1 CP + 1 worker).

##### How the YAML expands into real objects

The Cluster object alone is just a *declaration*. Behind the scenes
the ClusterClass controller creates ~15 CAPI objects:

```
Cluster                                          (your YAML)
├── KubeadmControlPlane                          (the CP machineSet's spec)
│   └── KubeadmControlPlaneTemplate              (from ClusterClass)
├── VSphereCluster                               (vSphere-specific infra)
│   └── VSphereClusterIdentity                   (auth to vSphere)
├── for each machineDeployments[]:
│   ├── MachineDeployment                        (the deployment object)
│   ├── KubeadmConfigTemplate                    (cloud-init for workers)
│   ├── VSphereMachineTemplate                   (VM hardware spec)
│   └── eventually N × Machine                   (one per replica)
│       └── one VSphereVM                        (the actual VM)
│           └── one VirtualMachine               (Supervisor's CRD for "VM")
└── ClusterResourceSet                           (addons like CNI, CSI)
```

You typically only edit the `Cluster` object. Scaling workers up?
Change `replicas`. Upgrading K8s? Change `version`. The controllers
reconcile everything underneath.

##### Apply and watch

```bash
kubectl config use-context sandbox       # vSphere Namespace context

# (Dry-run validate before applying)
kubectl apply -f /tmp/workload-cluster.yaml --dry-run=server

# Apply for real
kubectl apply -f /tmp/workload-cluster.yaml

# Top-level state
kubectl -n sandbox get cluster
# NAME         PHASE          AGE   VERSION
# my-cluster   Provisioning   12s   v1.31.4-...

# Watch the underlying machines come up
kubectl -n sandbox get machine -w

# If something is stuck, drill in:
kubectl -n sandbox describe cluster my-cluster
kubectl -n sandbox get machine,vspheremachine,virtualmachine
kubectl -n sandbox logs deploy/capi-controller-manager       # CAPI core
kubectl -n sandbox logs deploy/capv-controller-manager       # vSphere CAPI
```

Provisioning takes ~10-20 min: the Cluster API controllers running on
the Supervisor pull the matching K8s OVA from the content library,
clone a control-plane VM, run kubeadm, then clone worker VMs that
join. Each VM gets an IP from the *vSphere Namespace's* configured
workload network (the same one we set up for the Supervisor, or a
separate one if you provisioned multiple).

##### Useful operations after the cluster is up

```bash
# Scale workers
kubectl -n sandbox patch cluster my-cluster --type merge -p '
spec:
  topology:
    workers:
      machineDeployments:
        - { class: node-pool, name: workers, replicas: 5 }'

# Upgrade K8s version (must be a valid next-step TanzuKubernetesRelease)
kubectl -n sandbox patch cluster my-cluster --type merge -p '
spec: { topology: { version: v1.32.1---vmware.1-fips.1-tkg.1 } }'

# Delete the cluster (deletes all underlying VMs and Machines)
kubectl -n sandbox delete cluster my-cluster
```

#### 13.B.5 Log in to the workload cluster

Once `Cluster` shows `Phase: Provisioned`, switch context:

```bash
kubectl vsphere login \
  --server=192.168.3.251 \
  --insecure-skip-tls-verify \
  --tanzu-kubernetes-cluster-namespace=sandbox \
  --tanzu-kubernetes-cluster-name=my-cluster \
  --vsphere-username=administrator@vsphere.local

kubectl config use-context my-cluster
kubectl get nodes        # should show CP + 3 workers
```

The workload cluster is a regular K8s cluster from kubectl's
perspective — Helm, DaemonSets, custom CNI, etc. all work normally.

#### 13.B.6 Things to validate when Path B is attempted

If/when we come back to finish Path B, validate in order:

1. CP VM can reach `wp-content.vmware.com` over HTTPS (workload net
   has WAN access via EdgeRouter)
2. Content library is fully indexed (no "syncing" state)
3. VKS service in Workload Management → Services shows **Active**, not
   "signature verification" errors
4. `kubectl get tanzukubernetesreleases` on the Supervisor lists
   available K8s versions
5. `kubectl get clusterclass -A` shows a `tanzukubernetescluster` class
6. `kubectl apply` of a Cluster resource doesn't 4xx
7. Machines proceed past `Provisioning` into `Running`

The most likely failure points are 1 (no WAN egress from workload
network) and 3 (signature verification), both of which we already hit.

---

## Phase 14 — Automation via Terraform [done]

A working Terraform module that reproduces the entire bring-up
declaratively lives at `terraform/` in the repo. Every Phase 1–11
workaround is encoded: NTP on the physical host, security flags on
outer port groups, supervisor-dvs with two uplinks per host and
pinned teaming policy, HAProxy with the correct systemd flag and VIPs
claimed on `ens192` via netplan.

### Layout

```
terraform/
├── README.md
├── versions.tf, variables.tf, main.tf, outputs.tf
├── modules/
│   ├── host-config/       ← Phase 1, 8 (NTP), 10 (dswitch-vm security)
│   ├── network/           ← Phase 8.0a, 9 (DVS + port groups + teaming)
│   ├── haproxy/           ← Phase 7.B + 10 + 11 (HAProxy + dataplaneapi + VIPs)
│   ├── nfs/               ← Phase 6 (NFS storage VM)
│   └── supervisor/        ← Phase 8.0b + 8.2 (storage policy + cluster.enable)
├── examples/
│   └── lab/
│       ├── main.tf
│       └── terraform.tfvars.example
└── .gitignore             ← excludes *.tfvars, state, generated certs
```

### What it does (and doesn't) cover

```
✓ Physical host NTP                                       host-config/
✓ "VM Network" + "dswitch-vm" security flags = Accept     host-config/
✓ supervisor-dvs DVS spanning the 3 nested ESXi hosts     network/
✓ sup-mgmt + sup-workload port groups + teaming policy    network/
✓ Two uplinks (vmnic1 + vmnic2) per nested host           network/
✓ HAProxy VM with cloud-init                              haproxy/
✓ Dataplane API ≥ v2.9.25 (avoids YAML-rewrite bug)       haproxy/
✓ Correct `-f` systemd flag (avoids Phase 10 trap)        haproxy/
✓ VIPs .249-.254 as /32 in netplan (Phase 11 fix)         haproxy/
✓ Post-deploy validation (manual transaction commit)      haproxy/
✓ NFS storage VM with NFS export                          nfs/
✓ Tag-based storage policy targeting nfs-shared           supervisor/
✓ Supervisor enable via govc with JSON spec               supervisor/

✗ Nested ESXi VM creation + OS install                    (Packer)
✗ vCenter / physical ESXi initial install                 (separate)
✗ TKG content library subscription                        (optional)
✗ vSphere SSO RBAC for namespace access                   (manual)
```

### Prerequisites

| Tool | Version | Why |
|---|---|---|
| Terraform | ≥ 1.6.0 | required by the providers |
| govc | any recent | called from `null_resource` for namespace.cluster.enable, host.service start ntpd, etc. |
| pyvmomi | any | called from `null_resource` for the dswitch-vm security policy fix (govc can't update DVPG security flags) |
| openssl | system | generates the Dataplane API self-signed TLS cert |
| jq | system | small JSON manipulations in null_resource scripts |

```bash
pip3 install pyvmomi --break-system-packages
# govc + jq + openssl: brew install govc jq (openssl is system)
```

### Walking through the modules

#### `terraform/modules/host-config/`

Three resources, all `null_resource` because the vsphere provider
doesn't expose these settings directly:

1. **`physical_host_ntp`** — wraps `govc host.date.change -server …`
   and `govc host.service enable/start ntpd`. Pass NTP server IPs
   (not hostnames) — the host may not have DNS configured yet.
2. **`vm_network_security`** — wraps `govc host.portgroup.change`
   to flip all three security flags on the outer `VM Network`
   standard port group.
3. **`dswitch_vm_security`** — runs an embedded pyvmomi script that
   calls `ReconfigureDVPortgroup_Task` on `dswitch-vm` (a distributed
   port group). The vsphere provider's `vsphere_distributed_port_group`
   resource doesn't manage *existing* DVPGs in-place, so we use the
   API directly.

#### `terraform/modules/network/`

Uses the native vSphere provider resources:

- `vsphere_distributed_virtual_switch` (`supervisor-dvs`) with two
  uplinks defined per host.
- Two `vsphere_distributed_port_group`s (`sup-workload`, `sup-mgmt`)
  with active_uplinks pinned to a single uplink each (per Phase 9).
- Both port groups have all three security flags = Accept by default.

#### `terraform/modules/haproxy/`

The most complex module. Steps:

1. **`null_resource.generate_dpapi_cert`** — runs `openssl req` to
   create a self-signed TLS cert in `modules/haproxy/generated/`.
   This cert is later read by the supervisor module and pasted into
   the namespace.cluster.enable spec as `certificate_authority_chain`.
2. **`data.external.pw_hash`** — runs `openssl passwd -1` to MD5-hash
   the dataplaneapi admin password (the YAML config wants a hashed
   password, not plaintext).
3. **`templatefile`** — renders `templates/user-data.yaml.tpl` with
   all the lab-specific values: static IP, VIP list, dataplaneapi
   version, cert/key b64-encoded, the correct systemd `-f` flag.
4. **`vsphere_virtual_machine.haproxy`** — deploys the Ubuntu 24.04
   cloud OVA with `extra_config.guestinfo.userdata` set to the
   rendered cloud-init. cloud-init does the rest on first boot.
5. **`null_resource.validate_dataplane_api`** — waits for the
   Dataplane API to come up, then manually runs a transaction commit
   (POST a transient backend, PUT the transaction, expect
   `status:success`) to catch a Phase 10 regression early. Then
   pings each VIP to catch Phase 11 regressions.

The post-deploy validation is the part that turns a manual mistake
into a Terraform apply failure: if dataplaneapi is misconfigured,
the apply *fails* rather than letting a broken HAProxy back through
unnoticed.

#### `terraform/modules/nfs/`

Straightforward. Two-disk VM (40 GB OS + N GB share), cloud-init
formats the second disk as XFS, mounts it at `/srv/nfs/shared`,
writes `/etc/exports`, and starts `nfs-kernel-server`.

#### `terraform/modules/supervisor/`

Two phases:

1. **Storage policy** — uses the native vSphere provider:
   - `vsphere_tag_category` ("supervisor")
   - `vsphere_tag` ("supervisor-nfs")
   - `vsphere_tag_assignment` (tags the `nfs-shared` datastore)
   - `vsphere_vm_storage_policy` (tag-based policy resolving to that datastore)
2. **Supervisor enable** — generates a JSON spec via
   `templatefile`/`jsonencode` and feeds it to
   `govc namespace.cluster.enable -cluster <name> -spec @file`.
   Then polls every 30s for up to 45 minutes for `config_status`
   to reach `RUNNING`.

The JSON spec is the trickiest part because the schema can drift
between vSphere versions. The version here targets vSphere 9.0.2;
if you hit a 4xx, dump `govc namespace.cluster.enable -h` and check
the current expected shape. The schema for vSphere REST is documented
under "Namespace Management Clusters Enable" in the vSphere API docs.

### Usage

```bash
cd terraform/examples/lab

# Secrets go in a separate file that's .gitignore'd
cat > secrets.auto.tfvars <<EOF
vcenter_password = "<sso admin password>"
haproxy_password = "<dataplane api basic-auth password>"
EOF
chmod 600 secrets.auto.tfvars

terraform init
terraform plan         # review what's about to happen
terraform apply        # ~20-30 min unattended
```

Outputs once the apply succeeds:

```
supervisor_api_vip    = "https://192.168.3.251:6443"
haproxy_dataplane_api = "https://192.168.3.245:5556"
next_steps            = (instructions for logging into the cluster)
```

### Drift and re-runs

After the first `apply`, running `terraform plan` should show no
changes if nothing drifted. Known drift sources:

- **`dataplaneapi.yaml` corruption** — if dataplaneapi got into a
  bad state on the VM, the post-deploy validation will fail on
  re-apply. Fix: `terraform taint module.supervisor_lab.module.haproxy.vsphere_virtual_machine.haproxy && terraform apply`.
- **Manual VIP changes** — if you `ip addr add` more VIPs by hand,
  Terraform doesn't know. Either re-add them to `vip_pool_usable`
  and apply, or accept the drift.
- **NTP server change on the host** — the `null_resource` re-runs
  whenever the trigger value (the NTP server list) changes.

### Migrating from manually-deployed to Terraform-managed

If you already have everything stood up (as in our lab), you can
`terraform import` the resources Terraform knows about:

```bash
# Provider-native resources support import
terraform import 'module.supervisor_lab.module.network.vsphere_distributed_virtual_switch.supervisor_dvs' /Datacenter/network/supervisor-dvs
terraform import 'module.supervisor_lab.module.network.vsphere_distributed_port_group.sup_mgmt' /Datacenter/network/sup-mgmt
terraform import 'module.supervisor_lab.module.network.vsphere_distributed_port_group.sup_workload' /Datacenter/network/sup-workload
terraform import 'module.supervisor_lab.module.haproxy.vsphere_virtual_machine.haproxy' /Datacenter/vm/haproxy
terraform import 'module.supervisor_lab.module.nfs.vsphere_virtual_machine.nfs' /Datacenter/vm/nfs-storage
# ... (storage policy, tags, etc.)
```

`null_resource`s don't import — they're considered "always do" actions
in Terraform's model. Their trigger values will cause them to re-run
on first apply, which is usually fine for idempotent operations
(NTP-enable, security-flag-set, supervisor-enable — the supervisor-enable
specifically checks if it's already RUNNING and skips).

### When to use this vs the runbook

The runbook (this document) is for first-time exploratory deploys
where you want to understand *why* each step is needed. The Terraform
module is for re-deploys or templated multi-env rollouts. They're
complementary — the Terraform comments reference the runbook phases
inline (e.g. `# Phase 10/11 fix`), so when something fails on apply
you can quickly find the diagnostic chapter.

---

## Wizard Quick Reference — every value, every screen

Keep this open in a second pane while clicking through the
**Workload Management → Get Started** wizard. Every field's value
for *our* lab is filled in; substitute the equivalents for your
environment from the IP plan and SSO setup.

### Pre-flight checklist (run BEFORE opening the wizard)

| Check | Verify with | Expected |
|---|---|---|
| vCenter clock matches real time | `date -u` on Mac vs `govc host.date.info -host /Datacenter/host/Cluster/192.168.2.75` and `timedatectl` on vCSA | All within 1 second of UTC |
| Physical host NTP enabled | `govc host.date.info -host /Datacenter/host/Cluster/192.168.2.75` | `NTP service status: Running` |
| Cluster image matches host ESXi build | Cluster → Updates → Image | `9.0.2.0 - 25148076`, "All hosts compliant" |
| 9.x offline depot uploaded | vSphere Client → Lifecycle Manager → Imported ISOs/Depots | `VMware-ESXi-9.0.2-25148076-depot.zip` present |
| supervisor-dvs exists with both port groups | `govc find / -type n` | `sup-mgmt`, `sup-workload`, `supervisor-dvs-DVUplinks-*` present |
| Each nested host has vmnic0/1/2 | `for h in 192.168.3.241 192.168.3.242 192.168.3.243; do govc host.info -host "/Datacenter/host/Supervisor-Cluster/$h" -json \| python3 -c "import json,sys; print([n['device'] for n in json.load(sys.stdin)['hostSystems'][0]['config']['network']['pnic']])"; done` | `['vmnic0', 'vmnic1', 'vmnic2']` per host |
| supervisor-dvs has both uplinks per host | pyvmomi check from Phase 9.3 Step 4 | Each host shows `['vmnic1', 'vmnic2']` |
| sup-mgmt teaming → uplink2 only | pyvmomi check from Phase 9.3 Step 5 | Active uplink = `['uplink2']` |
| sup-workload teaming → uplink1 only | same | Active uplink = `['uplink1']` |
| `dswitch-vm` security all Accept | pyvmomi `/tmp/check-sec.py` from Phase 10 | All three flags = True |
| `VM Network` (vSwitch1) security all Accept | `govc host.portgroup.info -host /Datacenter/host/Cluster/192.168.2.75` | Promiscuous/Forged/MAC all Yes |
| HAProxy + dataplaneapi running | `curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/info` | JSON with `"version":"v2.9.25..."` |
| HAProxy dataplaneapi commit works | manual transaction test from Phase 10 | `{"status":"success"}` |
| HAProxy VIPs claimed on ens192 | `ssh ubuntu@192.168.3.245 'ip -br a show ens192'` | Lists `.245/24` + `.249/32` through `.254/32` |
| VIPs pingable from Mac | `for ip in 192.168.3.249..254; do ping -c1 -W1 $ip; done` | All reply |
| NFS datastore mounted on all 3 nested hosts | `govc datastore.info` on each | `nfs-shared` shows up, accessible |
| EdgeRouter DHCP shrunk to leave static band | EdgeRouter UI / config | Pool `.4–.200`, leaves `.201–.254` for statics |

### IP plan (final, post-fixes)

| Purpose | Subnet/IP | Notes |
|---|---|---|
| Mac (admin client) | `192.168.1.x` (LAN1) | gateway `192.168.1.1` |
| vCSA | `192.168.2.80` (LAN2 mgmt) | hostname `vcenter.skynetsystems.io` |
| Physical ESXi | `192.168.2.75` | host vmk0 on vSwitch0 |
| EdgeRouter LAN2 gateway | `192.168.2.1` | DNS forwarder; reachable from CP VM mgmt iface |
| **Supervisor CP mgmt IPs** | `192.168.2.231-235` | starting `.231`; 1 IP if HA off, 5 if HA on |
| EdgeRouter LAN3 gateway | `192.168.3.1` | DNS forwarder; reachable from workload subnet |
| EdgeRouter LAN3 DHCP pool | `192.168.3.4-200` | shrunk from `.4-240` in Phase 7 |
| Free for statics | `192.168.3.201-230` | workload network IP range |
| nested-esxi-1/2/3 | `192.168.3.241/.242/.243` | management vmk0 |
| nfs-storage VM | `192.168.3.244` | NFS export |
| HAProxy management | `192.168.3.245` | primary IP on ens192 |
| HAProxy data plane port | `192.168.3.245:5556` | wizard "Load Balancer" endpoint |
| **HAProxy VIP pool** | `192.168.3.248/29` (`.249-.254`) | claimed on ens192 as `/32` secondaries |

### Page 1 — vCenter Server and Network

| Field | Value |
|---|---|
| vCenter Server | `vcenter.skynetsystems.io` |
| Supervisor Network Stack | **vSphere Distributed Switch** (NOT NSX) |
| Workload Management Activation Mode | **Cluster Deployment** (NOT vSphere Zone) |

### Page 2 — Select a Cluster

| Field | Value |
|---|---|
| Compute Cluster | `Datacenter / Supervisor-Cluster` |
| Notes shown by wizard | Should say "Compatible" — if not, fix host vLCM compliance first |

### Page 3 — Storage

| Field | Value |
|---|---|
| Control Plane Storage Policy | Tag-based policy targeting `nfs-shared` (or create one named e.g. `supervisor-nfs`) |
| Ephemeral Disks Storage Policy | Same as above (or any policy that resolves to `nfs-shared`) |
| Image Cache Storage Policy | Same as above |

### Page 4 — Load Balancer

| Field | Value |
|---|---|
| Name | `haproxy-lab` |
| Type | **HAProxy** |
| Data Plane API Addresses | `192.168.3.245:5556` |
| User | `admin` |
| Password | `Srosario1!` (or whatever you set; must match dataplaneapi.yaml hash) |
| IP Address Ranges for Virtual Servers | `192.168.3.249-192.168.3.254` (the `.248/29` block, excluding network/broadcast) |
| Server Certificate Authority | Paste the **entire content** of `haproxy-dpapi.crt` (the `-----BEGIN CERTIFICATE-----` through `-----END CERTIFICATE-----` block) |

### Page 5 — Management Network

This is the *control plane* network where vCenter talks to the CP VM(s).

| Field | Value |
|---|---|
| Network Mode | **Static** |
| Network | **`sup-mgmt`** (port group on supervisor-dvs) |
| Starting IP Address | `192.168.2.231` |
| Subnet Mask | `255.255.255.0` |
| Gateway | `192.168.2.1` |
| DNS Servers | `192.168.2.1, 8.8.8.8` |
| DNS Search Domains | (leave blank or use your domain) |
| NTP Server | `pool.ntp.org` (or `162.159.200.1` for cloudflare anycast) |

**With HA off:** wizard reserves only 1 IP starting at `.231` (so just `.231`).
**With HA on:** reserves 5 consecutive IPs `.231-.235` (3 CP VMs + 1 floating + 1 buffer).

### Page 6 — Workload Network

This is the network for the K8s data plane (pod-to-pod, kubelet, etc).

| Field | Value |
|---|---|
| Internal Network for Kubernetes Services | `10.96.0.0/24` (default — cluster-internal Service CIDR) |
| Pod CIDRs | `10.244.0.0/20` (default — cluster-internal Pod CIDR) |
| DNS Servers (for workload network) | `192.168.3.1, 8.8.8.8` |
| Workload Network → Edit → Name | `network-1` (auto-generated; can rename) |
| Port group | **`sup-workload`** (port group on supervisor-dvs) |
| Gateway | `192.168.3.1` |
| Subnet | `255.255.255.0` |
| IP Address Ranges | `192.168.3.201-192.168.3.230` (30 IPs in the DHCP-free band) |

### Page 7 — Review Settings / Advanced

| Field | Value |
|---|---|
| Control Plane Size | **Tiny** (2 vCPU / 4 GB RAM per CP VM — sufficient for lab) |
| Control Plane HA | **OFF** for lab (1 CP VM), **ON** for production (3 CP VMs + floating IP) |
| API Server DNS Names | (leave blank, or add a FQDN you've added to local DNS) |
| Export Settings | optional — saves a JSON of these inputs for future re-use |

### Page 8 — TKG Service / Tanzu Mission Control

| Field | Value |
|---|---|
| Content Library | Optional. Skip if you're not deploying TKG (Tanzu Kubernetes Grid) workload clusters. Can be attached later via **Workload Management → Services**. |

### Page 9 — Review and Confirm

Click **Finish**. The deploy starts immediately.

### What the deploy does (in order)

1. Creates an internal `Skynet` namespace folder + `Namespaces`
   resource pool in vCenter inventory.
2. Syncs the "Kubernetes Service Content Library" (Supervisor's
   internal image store).
3. Pushes spherelet VIBs to each nested ESXi via vLCM remediation
   (~3-4 min).
4. Imports the CP VM OVF templates from the content library
   (~4 min per CP VM).
5. Powers on CP VM(s); they run kubeadm and bring up etcd, apiserver,
   etc.
6. Pushes `VSphereDistributedNetwork`, `HAProxyLoadBalancerConfig`,
   `GatewayClass`, etc. as Kubernetes CRDs (this is where clock skew
   bites).
7. lbapi controller creates Gateway objects for each system service
   (mgmt-image-proxy, csi-controller, kube-apiserver-lb-svc).
8. lbapi calls HAProxy Dataplane API to define frontends/backends/binds.
9. WCP configures spherelet on each ESXi host (CSRs, kubeconfig).
10. ESXi hosts join the K8s cluster as worker nodes.
11. Optional Supervisor Services (Velero, TKG, etc.) install from
    the content library.

### Monitoring the deploy

```bash
# top-level status
. ~/bin/sv-env  &&  sv-state

# detailed condition list (this is what the wizard "Configuring Skynet" dialog shows)
govc namespace.cluster.ls -json | python3 -m json.tool

# CP VM bootstrap status
govc vm.info -e=true "/Datacenter/vm/Namespaces/Skynet/SupervisorControlPlaneVM (1)" \
  | grep -A1 'configureStatus' | head -3

# WCP live log
ssh root@192.168.2.80
> shell
tail -f /storage/log/vmware/wcp/wcpsvc.log

# HAProxy: backends should appear within ~5 min of K8s coming up
watch -n5 'curl -sk -u admin:Srosario1! \
  https://192.168.3.245:5556/v2/services/haproxy/configuration/backends \
  | python3 -c "import json,sys;d=json.load(sys.stdin); print(len(d.get(\"data\",[])))"'
```

### Post-deploy verification

| Check | Command | Expected |
|---|---|---|
| Supervisor RUNNING | `govc namespace.cluster.ls -json` | `config_status=RUNNING`, `kubernetes_status=RUNNING` (or `WARNING` if workers haven't joined yet) |
| CP VM up | `govc vm.info '/Datacenter/vm/Namespaces/Skynet/SupervisorControlPlaneVM (1)'` | `Power state: poweredOn`, `IP: 192.168.2.232` |
| K8s API reachable on VIP | `curl -sk https://192.168.3.251:6443/version` | JSON Status response (401 is fine — proves reachability) |
| HAProxy backends populated | `curl -sk -u admin:'Srosario1!' https://192.168.3.245:5556/v2/services/haproxy/configuration/backends` | At least 5 backends listed |
| Plugin downloadable | `curl -kI https://192.168.3.251/wcp/plugin/darwin-amd64/vsphere-plugin.zip` | `HTTP/1.1 200 OK`, content-type `application/zip` |
| `kubectl vsphere login` works | command from Phase 12 | "Logged in successfully", context written |
| Test LoadBalancer service gets a VIP | `kubectl -n sandbox expose deployment nginx --port=80 --type=LoadBalancer; kubectl -n sandbox get svc nginx` | `EXTERNAL-IP` in `192.168.3.249-.254` range |
| Test LB serves traffic | `curl http://<EXTERNAL-IP>/` | nginx welcome page |

### Wizard failure modes and where to look

| Wizard error | Most likely cause | Phase covering the fix |
|---|---|---|
| "Cannot download VIB ..." | depot version mismatch | Phase 8 — vLCM depot |
| "3 hosts incompatible" | cluster image declared wrong base | Phase 8 — cluster image |
| Deploy hangs at "Configured Supervisor Control plane VM's Management Network" | clock skew between vCSA and CP VMs | Phase 8 — NTP |
| `ManagementNetworkDNSServerConnectionFailed` | CP VM can't reach DNS — either two NICs on same subnet (Phase 9) or `dswitch-vm` security policy (Phase 10) |
| `Resource Type VSphereDistributedNetwork sup-workload is not found` | WCP couldn't push CRs — usually clock skew | Phase 8 — NTP |
| `failed to commit transaction: 400 Bad Request` (lbapi logs) | dataplaneapi systemd flag wrong | Phase 10 — dataplaneapi flag |
| `EXTERNAL-IP <pending>` forever | HAProxy frontends defined but VIPs unreachable | Phase 11 — VIPs on ens192 |
| Worker nodes stuck "Configured as Worker Node — context deadline exceeded" | API VIP unreachable from ESXi (Phase 11) or spherelet on long backoff (reboot the nested ESXi) |
| `Signature verification result not found` for Velero/TKG | optional services — non-blocking; retries automatically when content library catches up |
