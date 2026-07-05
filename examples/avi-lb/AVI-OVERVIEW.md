# Avi (NSX Advanced Load Balancer) — overview & architecture

This explains what Avi is, how its pieces fit together, and — importantly
— how its **control plane and data plane are separated**, which is the
fundamental difference from the single-VM HAProxy load balancer this lab
used before. Read this for the mental model; read [`README.md`](README.md)
for how to actually deploy and wire it into Supervisor.

---

## 1. What Avi is

Avi (now sold as **VMware NSX Advanced Load Balancer**, "NSX ALB") is a
**software-defined, scale-out application delivery controller** — a load
balancer whose brains and muscle are deliberately split into two tiers:

| Tier | Component | Runs as | Carries user traffic? |
|---|---|---|---|
| **Control plane** | **Avi Controller** | 1 VM (lab) or 3-VM cluster (prod) | **No** |
| **Data plane** | **Service Engines (SEs)** | Lightweight VMs the Controller deploys automatically | **Yes** |

Compare that to the HAProxy stack, where one Ubuntu VM ran *both* the
proxy (data plane) and a thin REST API (`dataplaneapi`, control plane).
Avi pulls those apart: the Controller is a separate appliance that never
touches a client packet, and the actual proxying happens on a fleet of
Service Engines it spins up and manages for you.

Why that split matters:
- **Elastic scale** — the Controller adds/removes SEs and scales a Virtual
  Service across multiple SEs under load. HAProxy was one fixed VM.
- **Resilience** — if the Controller is down, **SEs keep forwarding
  traffic**. Only config changes and analytics pause.
- **No manual VIP plumbing** — SEs place VIPs on their data NICs and answer
  ARP/GARP automatically. (This is exactly the HAProxy "Phase 11" pain —
  claiming `/32`s and gratuitous-ARP by hand — that disappears with Avi.)
- **Observability** — the Controller aggregates per-request analytics,
  health, and logs from all SEs.

---

## 2. The core objects

```
Cloud ─┬─ tells Avi HOW/WHERE to deploy SEs and discover networks
       │  (here: a vCenter cloud → SEs are vSphere VMs)
       │
       ├─ IPAM/DNS Profile ── allocates VIPs from a pool; optional DNS
       │
       └─ Service Engine Group ── SE sizing, HA mode, scale limits
                 │
                 ▼
        Service Engines (SEs)  ── the data-plane VMs
                 │  host ▼
        Virtual Service = VIP:port + Application Profile (L4/L7) + Pool
                                                              │
                                                     Pool = backend servers
                                                            + health monitor
                                                            + LB algorithm
```

- **Cloud** — the infrastructure connector. A *vCenter cloud* lets the
  Controller log into vCenter, discover port groups, and auto-create SE
  VMs. (Other cloud types: NSX-T, AWS, GCP, OpenStack, bare-metal "No
  Orchestrator".)
- **IPAM/DNS Profile** — where VIPs come from. We use Avi's **internal
  IPAM** with a static pool on the VIP network. Avi hands out the next
  free VIP when a Virtual Service is created.
- **Service Engine Group** — a template/policy for SEs: vCPU/RAM per SE,
  HA mode (`HA_MODE_SHARED` = N+M elastic), and how far a VS may scale out.
- **Virtual Service (VS)** — the load balancer instance: a VIP + port, an
  application profile (TCP/UDP passthrough for L4, or HTTP/HTTPS for L7),
  and a pool. *In the Supervisor case, Supervisor creates these for you.*
- **Pool** — backend members (e.g. the Supervisor control-plane VM, or pod
  endpoints), a health monitor, and a load-balancing algorithm.

---

## 3. Control plane vs data plane — how they work together

```
            ┌──────────────────────────────────────────────────────┐
            │                  CONTROL PLANE                        │
            │                 Avi Controller VM                     │
            │  ┌────────────┬──────────────┬───────────────────┐    │
            │  │ REST API / │  Policy &    │  Analytics /       │    │
            │  │ UI         │  Config DB   │  Metrics store     │    │
            │  └────────────┴──────────────┴───────────────────┘    │
            │  • Source of truth for all config                     │
            │  • Talks to vCenter (the "cloud") to place SEs        │
            │  • Pushes VS/Pool config DOWN to SEs                  │
            │  • Collects health + per-request metrics UP from SEs  │
            │  • Does NOT see client traffic                        │
            └───────────────▲───────────────────────┬──────────────┘
                            │ secure mgmt channel    │ config push /
              metrics, logs,│ (TLS; SE↔Controller    │ SE lifecycle
              health  ▲     │  on the mgmt network)  ▼
            ┌─────────┴───────────────────────────────────────────┐
            │                   DATA PLANE                         │
            │        Service Engine VMs (auto-deployed)            │
            │  ┌───────────────────────────────────────────────┐  │
            │  │ SE-1                         SE-2  ...          │  │
            │  │  mgmt NIC  ── to Controller (mgmt network)     │  │
            │  │  data NIC  ── on the VIP network               │  │
            │  │  hosts Virtual Services (VIP:port)             │  │
            │  │  terminates/forwards, health-checks pools      │  │
            │  └───────────────────────────────────────────────┘  │
            │  • Receives ALL client traffic on the VIPs           │
            │  • Answers ARP/GARP for its VIPs automatically       │
            │  • Keeps forwarding even if the Controller is down   │
            └───────────────▲─────────────────────────┬───────────┘
                            │ client requests          │ load-balanced
                            │ to VIP                    ▼ to pool members
                     ┌──────┴──────┐            ┌───────────────────┐
                     │   Clients   │            │ Backend servers / │
                     │ (kubectl,…) │            │ pods / CP VM      │
                     └─────────────┘            └───────────────────┘
```

**Key behaviors**

1. **Provisioning** — You (or Supervisor) define a Virtual Service via the
   Controller API. The Controller picks/creates an SE in the SE Group,
   attaches a data NIC on the VIP network, allocates a VIP from IPAM, and
   programs the VS onto that SE.
2. **Steady state** — Clients hit the VIP; **the SE** (not the Controller)
   load-balances to the pool. The Controller only receives telemetry.
3. **Scale-out** — Under load (or for HA), the Controller places the same
   VS on additional SEs and uses native scale-out so multiple SEs share
   the VIP.
4. **Controller-down** — Existing VSes keep serving on the SEs. You just
   can't make config changes or see fresh analytics until it returns.

> "Control plane on the Controller" = the API, the config database, the
> orchestration logic, and the analytics pipeline. "Data plane on the SEs"
> = the actual packet path. The Controller is the only thing you or
> Supervisor talk to; it does the rest.

---

## 4. How Avi replaces the HAProxy stack here

| Concern | HAProxy stack (before) | Avi (now) |
|---|---|---|
| Control API endpoint | `dataplaneapi` :5556 on the HAProxy VM | Avi Controller REST :443 |
| Data plane | `haproxy` on the same VM | Service Engine VM(s), auto-deployed |
| VIP reachability | manual `/32` + gratuitous ARP (Phase 11) | SE answers ARP/GARP automatically |
| Config reload | rewrite `haproxy.cfg` + `systemctl reload` | Controller pushes config to SEs live |
| Scale / HA | single VM | elastic SE scale-out, N+M HA |
| Cost/footprint | ~2 GB VM, free | Controller (≈6 vCPU/32 GB) + SE VMs, licensed |

For vSphere Supervisor the integration shape is the same as HAProxy: a
controller exposes a REST API, Supervisor's load-balancer controller
(`lbapi`) calls it to create Virtual Services for the kube-apiserver VIP
and every `Service{type:LoadBalancer}`. The difference is what's behind
the API — a managed SE fleet instead of one hand-plumbed proxy.

See [`README.md`](README.md) §"How it all comes together" for the
end-to-end diagram with this lab's actual networks and IPs.
