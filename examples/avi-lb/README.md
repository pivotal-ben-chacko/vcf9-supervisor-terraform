# Avi (NSX ALB) load balancer for vSphere Supervisor

Standalone Terraform to deploy and configure the **Avi Controller** as an
alternative to the HAProxy load balancer, then point vSphere Supervisor at
it. This is a *separate* root config from the main stack — run it on its
own.

- New to Avi? Read [`AVI-OVERVIEW.md`](AVI-OVERVIEW.md) first (what it is,
  control plane vs data plane, architecture diagrams).
- Tracking the live rollout? See [`DEPLOYMENT-LOG.md`](DEPLOYMENT-LOG.md).

---

## Prerequisites

1. **Controller OVA** — `controller-31.2.2-9059.ova` (already in the repo
   root). Not public; download from the Broadcom/VMware portal. Ignored by
   git (it's ~5 GB).
2. **License** — optional for a lab; Avi runs on a built-in trial /
   Essentials grant. Supply `avi_license_file` to apply a real one.
3. **Host capacity** — the Controller wants **6 vCPU / 32 GB / 128 GB**,
   plus headroom for the Service Engine VMs Avi will auto-deploy (≈1 vCPU /
   2 GB each). This is much heavier than the 2 GB HAProxy VM — make sure
   the physical host has room.
4. `terraform`, `govc`, `openssl`, `curl`, `python3` on the workstation.

---

## Layout

```
examples/avi-lb/
├── README.md              ← you are here
├── AVI-OVERVIEW.md        ← concepts + architecture diagrams
├── DEPLOYMENT-LOG.md      ← running progress log
├── versions.tf variables.tf main.tf outputs.tf
├── terraform.tfvars.example
├── scripts/bootstrap-controller.sh
└── cloud-config/          ← Stage 2: vCenter cloud, SE group, VIP network
```

Two stages, because the second talks to the controller the first creates:

| Stage | Dir | Provider | What it does |
|---|---|---|---|
| 1 | `.` | `vsphere` | Deploy + bootstrap the Controller VM |
| 2 | `cloud-config/` | `avi` | vCenter cloud, IPAM, VIP pool, SE group |

---

## Networks — control plane vs data plane

Avi's two tiers map onto this lab's two networks exactly the way the rest
of the stack does (management `192.168.2.0/24`, workload `192.168.3.0/24`):

| Plane | Component | Network | Port group | Example IP |
|---|---|---|---|---|
| **Control** | Avi Controller (mgmt NIC) | management `192.168.2.0/24` | `outer-mgmt-net` | `192.168.2.240` |
| **Control** | SE management NICs | management `192.168.2.0/24` | `outer-mgmt-net` | DHCP/auto |
| **Data** | SE data NICs (carry VIPs) | workload `192.168.3.0/24` | `VM Network` | from VIP pool |
| **Data** | **VIPs** | workload `192.168.3.0/24` | `VM Network` | `192.168.3.249–.254` |
| (backend) | Supervisor CP VM | workload `192.168.3.0/24` | `VM Network` | `192.168.3.201` |

Rationale:
- **Controller on the management network** so it can reach vCenter
  (`192.168.2.80`) to orchestrate SEs, and so the Supervisor control plane
  (which has a mgmt NIC) can call its API.
- **VIPs on the workload network** (same `192.168.3.248/29` pool HAProxy
  used) so kubectl clients, the spherelets, and pods reach them exactly as
  before — no routing changes to the rest of the lab.
- **SEs are dual-homed**: a management NIC (to talk to the Controller) and
  a data NIC on the VIP network (to receive client traffic and host VIPs).
  Avi creates these NICs automatically when it places a Virtual Service.

---

## How VIPs are configured

Unlike HAProxy — where we hand-claimed each VIP as a `/32` on `ens192` and
fired gratuitous ARP (Phase 11) — **Avi owns VIP allocation and L2
reachability itself**:

1. **Pool definition** (`cloud-config/`): we register the workload subnet
   `192.168.3.0/24` as an Avi network and put a **static VIP range
   `192.168.3.249–.254`** on it, then bind it to an **internal IPAM
   profile**. That range is the menu Avi allocates from.
2. **Allocation**: when a Virtual Service is created (by us for a test, or
   by Supervisor for the kube-apiserver / a `LoadBalancer` Service), the
   IPAM hands out the next free IP from that range as the VS's VIP.
3. **Placement**: the Controller programs that VIP onto a Service Engine's
   data NIC on `VM Network`.
4. **Reachability**: the SE **answers ARP for the VIP and sends gratuitous
   ARP** when it places/moves it — so upstream routers/switches learn the
   IP→MAC binding with zero manual steps. On scale-out/failover the VIP
   moves to another SE and GARP re-points it.

Net effect: the same `192.168.3.249–.254` VIPs you used with HAProxy, but
allocated and kept reachable by Avi instead of by hand.

---

## How it all comes together

```
 CONTROL PLANE (management net 192.168.2.0/24)         DATA PLANE (workload net 192.168.3.0/24)
 ─────────────────────────────────────────────         ────────────────────────────────────────

  ┌─────────────────┐      orchestrates SEs      ┌──────────────────────────────────────────┐
  │ vCenter         │◀────────(vCenter cloud)────│ Avi Controller   192.168.2.240            │
  │ 192.168.2.80    │                            │  REST API :443 (control plane)            │
  └─────────────────┘                            └───────┬───────────────────────▲───────────┘
                                                         │ push VS/Pool config   │ metrics/health
  ┌───────────────────────────┐   REST :443             ▼                        │
  │ Supervisor control plane  │────(lbapi creates ──────┐                        │
  │  mgmt 192.168.2.231+       │     Virtual Services)   │                        │
  │  workload 192.168.3.201    │                         │                        │
  └───────────────────────────┘                ┌────────┴────────────────────────┴─────────┐
            ▲                                   │ Service Engine VM(s)  (data plane)         │
            │ backend pool member               │  mgmt NIC → 192.168.2.x (to Controller)    │
            │ (kube-apiserver :6443, etc.)      │  data NIC → 192.168.3.x (VM Network)       │
            └───────────────────────────────────┤  hosts VIPs 192.168.3.249–.254             │
                                                │  answers ARP/GARP, LB to pools             │
                                                └────────────────────▲───────────────────────┘
                                                                     │ client traffic to VIP
                                ┌────────────────────────────────────┴───────────────────┐
                                │ Clients: kubectl (Mac), ESXi spherelets, browsers        │
                                │  → https://192.168.3.251:6443  (kube-apiserver VIP), etc. │
                                └──────────────────────────────────────────────────────────┘
```

End-to-end sequence:

1. **Stage 1** deploys the Controller on `192.168.2.240`, sets its admin
   password (via the OVA `default-password` prop), DNS/NTP, and grabs its
   TLS cert.
2. **Stage 2** connects the Controller to vCenter as a cloud, defines the
   VIP pool `192.168.3.249–.254` + internal IPAM, and an SE Group.
3. **Supervisor enable** points at the Controller's API (provider `AVI`).
   Supervisor's `lbapi` creates a Virtual Service for the kube-apiserver
   VIP and one per `LoadBalancer` Service.
4. The Controller **auto-deploys Service Engine VM(s)**, places the VIPs on
   their data NICs on `VM Network`, and load-balances to the backends (the
   CP VM, then pods). SEs answer ARP for the VIPs — no Phase-11 plumbing.

---

## Controller bootstrap — what Stage 1 configures

After the OVA is imported and powered on, Stage 1 runs
`scripts/bootstrap-controller.sh` (as `null_resource.bootstrap`) to bring
the controller from "booted" to "ready for Stage 2 / Supervisor". It drives
the Avi REST API on `https://<controller-ip>` and does six things, in order:

| # | Step | API call | Fatal? | Notes |
|---|---|---|---|---|
| 1 | **Wait for the API** | `GET /api/initial-data`, every 10 s for up to **15 min** | ✅ yes | A fresh controller takes 5–10 min to start its services on first boot. This is the long phase of `apply`. |
| 2 | **Verify admin login** | `POST /login` (`admin` / your `avi_admin_password`), retried 12× | ✅ yes | Confirms the password the OVA's `default-password` prop set. No password is *created* here. The hard success gate. |
| 3 | **Capture CSRF token** | from the login cookie jar | — | Avi requires `X-CSRFToken` + matching `Referer` + `X-Avi-Version` on every authenticated write. |
| 4 | **Apply license** *(optional)* | `POST /api/license` | no (warn) | Only if `avi_license_file` is set; otherwise runs on the built-in trial/Essentials grant. |
| 5 | **Set DNS + NTP** | `GET`→merge→`PUT /api/systemconfiguration` | no (warn) | Writes `dns_configuration.server_list` and `ntp_configuration.ntp_servers` from `controller_dns_servers` / `controller_ntp_servers`. |
| 6 | **Set backup passphrase** | `GET /api/backupconfiguration` → `PATCH` | no (warn) | Enables config backup/restore, using `avi_backup_passphrase`. |

After the script succeeds, a separate `null_resource.fetch_cert` grabs the
controller's TLS cert via `openssl s_client` into
`generated/avi-controller.crt` — that file is the
`certificate_authority_chain` for the Supervisor enable spec.

Behavior notes:
- **Idempotent**: re-running re-applies the same settings; the block only
  re-triggers when the script hash, password, DNS, NTP, or license inputs
  change (see its `triggers`).
- **Fatal vs tolerant**: only steps 1–2 fail the apply. Steps 4–6
  warn-and-continue so a minor API-shape difference doesn't block the
  deploy.
- **Version-sensitive**: the REST shapes target Avi/NSX-ALB **31.x**. On a
  different major, verify the `systemconfiguration` / `backupconfiguration`
  payloads. The script is the definitive reference — it's heavily commented.

---

## Usage

```bash
cd examples/avi-lb

# Secrets (gitignored): vcenter_password, avi_admin_password, avi_backup_passphrase
cat > secrets.auto.tfvars <<'EOF'
vcenter_password      = "..."
avi_admin_password    = "..."        # >=8 chars, mixed case + digit + special
avi_backup_passphrase = "..."
EOF

cp terraform.tfvars.example terraform.tfvars   # adjust IPs/names if needed

# Stage 1 — deploy + bootstrap the Controller (~10–15 min on first boot)
terraform init
terraform apply

# Stage 2 — configure cloud / IPAM / VIP pool / SE group
cd cloud-config
cp terraform.tfvars.example terraform.tfvars
echo 'avi_password = "..."'     >> secrets.auto.tfvars   # = avi_admin_password
echo 'vcenter_password = "..."' >> secrets.auto.tfvars
terraform init
terraform apply        # if a network lookup errors, wait ~1–2 min, re-apply
```

> **Lab shortcut:** Stage 2's vCenter-cloud + network setup is also a
> 5-minute guided wizard in the Avi UI (**Infrastructure → Clouds**). The
> Terraform is the automation path; the UI is often faster for a one-off.

---

## Wiring into Supervisor

The Supervisor enable spec in `modules/supervisor/main.tf` currently uses
the HAProxy provider. To use Avi instead, swap the
`load_balancer_config_spec` block:

```hcl
# modules/supervisor/main.tf  (replace the HA_PROXY block)
load_balancer_config_spec = {
  id       = "avi-lab"
  provider = "AVI"
  # For Avi the VIP range is managed by Avi IPAM, but the API still wants
  # an address_ranges entry that matches the configured pool:
  address_ranges = [
    { address = "192.168.3.249", count = 6 }
  ]
  avi_config_create_spec = {
    server = {
      host = "192.168.2.240"   # Avi Controller mgmt IP
      port = 443
    }
    username                    = "admin"
    password                    = var.avi_admin_password
    certificate_authority_chain = file("${path.root}/../avi-lb/generated/avi-controller.crt")
  }
}
```

And set `network_provider = "VSPHERE_NETWORK"` (unchanged — Avi, like
HAProxy, is a vDS-mode L4 provider).

> Schema note: the exact field name is
> `com.vmware.vcenter.namespace_management.load_balancers.config_spec` with
> `provider ∈ {HA_PROXY, AVI}` and an `avi_config_create_spec`
> sub-struct. Confirm against your vCenter 9.0.2 metamodel the same way the
> HAProxy spec was verified.

**If Supervisor is already enabled on HAProxy**, switching the LB provider
is destructive — it requires disabling and re-enabling Supervisor. Plan a
maintenance window.

---

## Teardown

```bash
cd cloud-config && terraform destroy   # remove cloud/IPAM/SE-group config first
cd ..          && terraform destroy    # then the Controller VM
```

Service Engines auto-deployed by Avi are removed when the cloud config is
torn down; if any linger, delete them from vCenter or via the Avi UI.
