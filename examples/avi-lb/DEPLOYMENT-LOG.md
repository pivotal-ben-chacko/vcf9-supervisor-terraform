# Avi LB deployment — running log

A living record of the Avi (NSX ALB) rollout for this lab. Append a dated
entry as each step happens; keep the **Status** and **Checklist** current.

---

## Status

**Phase:** ✅ Stage 1 COMPLETE — controller up, healthy, admin login OK. Stage 2 next.

| Item | Value |
|---|---|
| Avi version | 31.2.2 (build 9059) |
| Controller OVA | `controller-31.2.2-9059.ova` (repo root, gitignored) |
| Controller mgmt IP | `192.168.2.240` (management net, `outer-mgmt-net`) — **pings, API up** |
| Admin login | `admin` / `Srosario1!` → HTTP 200 |
| Cluster state | `CLUSTER_UP_NO_HA` (single node, healthy) |
| Default license tier | `ENTERPRISE_WITH_CLOUD_SERVICES` |
| Controller cert | saved to `generated/avi-controller.crt` (valid to 2036) |
| VIP pool | `192.168.3.249–.254` (workload net, `VM Network`) |
| Controller size | 6 vCPU / 32 GB / 128 GB (OVA default) |
| Supervisor wired to Avi? | No — still on HAProxy |

---

## Checklist

- [x] Confirm OVA present & inspect OVF (props, NICs, sizing)
- [x] Author Stage 1 Terraform (controller deploy + bootstrap + cert fetch)
- [x] Author Stage 2 Terraform (vCenter cloud, IPAM, VIP pool, SE group)
- [x] `terraform validate` Stage 1 (passes)
- [x] Author docs (overview, README, this log)
- [x] Set secrets (`secrets.auto.tfvars`: vcenter/admin/backup) — all `Srosario1!`
- [x] `terraform apply` Stage 1 → Controller up & reachable (`192.168.2.240`)
- [x] Verify admin login + controller health (`CLUSTER_UP_NO_HA`)
- [ ] `terraform apply` Stage 2 → cloud connected, IPAM/VIP pool, SE group
- [ ] Confirm an SE deploys & a test Virtual Service gets a VIP
- [ ] Repoint `modules/supervisor` to `provider = "AVI"`
- [ ] (If Supervisor already enabled on HAProxy) plan disable/re-enable window
- [ ] Enable/verify Supervisor on Avi; kube-apiserver VIP reachable
- [ ] Decommission HAProxy VM (optional)

---

## Decisions

- **Standalone config under `examples/avi-lb/`**, separate from the main
  stack, so Avi can be brought up/torn down independently of HAProxy.
- **Two stages** (`vsphere` then `avi` provider) because Stage 2 must talk
  to the controller Stage 1 builds.
- **Admin password via the OVA `default-password` vApp property** instead
  of an API password-bootstrap — this OVA (31.x) exposes it, which is far
  more robust.
- **Controller on management net, VIPs on workload net**, reusing the
  HAProxy VIP pool `192.168.3.249–.254` so nothing else in the lab reroutes.
- **IPAM attach via curl PATCH** (not a 2nd `avi_cloud` resource) to avoid
  the cloud→ipam→network→cloud Terraform dependency cycle.

---

## Open questions / risks

- **License**: running on the built-in trial/Essentials grant for now.
  Supply `avi_license_file` if a real license is required.
- **Host capacity**: Controller (32 GB) + SE VMs is a big bump over the
  2 GB HAProxy VM. Watch the physical host's memory.
- **`avi` provider schema**: Stage 2 targets the 31.x schema and could not
  be `validate`d offline (provider not yet downloaded). Run `terraform
  plan` and adjust any field the provider rejects. UI wizard is the
  fallback.
- **Switch is destructive if Supervisor is already enabled** on HAProxy.

---

## Log

### 2026-06-08 — scaffolding & validation
- Located `controller-31.2.2-9059.ova` in `vcf9-supervisor-terraform/`
  (~5 GB). Extracted the OVF descriptor:
  - single NIC on network **"Management"**; transport
    `com.vmware.guestInfo`.
  - userConfigurable props: `mgmt-ip`, `mgmt-mask`, `default-gw`,
    `default-password`, `sysadmin-public-key`, `hostname`,
    `mgmt-ip-v4-enable`.
  - ships **6 vCPU / 32768 MB / 128 GB**.
- Wrote Stage 1 (`main.tf` etc.): OVA deploy via `ovf_deploy` + vApp props,
  power-on safety net, `bootstrap-controller.sh` (wait→login→DNS/NTP→backup
  passphrase→optional license), and controller-cert fetch.
- Wrote Stage 2 (`cloud-config/`): vCenter cloud, internal IPAM, VIP pool
  `192.168.3.249–.254`, SE group; IPAM attached via curl PATCH.
- `.gitignore`: added `examples/avi-lb/generated/` and `*.ova`.
- `terraform validate` (Stage 1): **passed**. `terraform fmt`: clean.
- Wrote `AVI-OVERVIEW.md` (concepts + control/data-plane diagrams) and
  `README.md` (networks, VIP config, overall-picture diagram, Supervisor
  wiring).

### 2026-06-09/10 — applied Stage 1 (with two fixes)
- **DNS hijack bit the provider.** First `plan` failed: the `vsphere`
  provider (Go → macOS system resolver + Private Relay) resolved
  `vcenter.skynetsystems.io` to a stale `192.168.2.12` ("network is
  unreachable"). The lab DNS (`192.168.2.1`) has the correct `.80`, but the
  Mac queries its own gateway `192.168.1.1`. **Fix:** pinned
  `vcenter_server = "192.168.2.80"` (IP) in `terraform.tfvars`.
- **First apply errored:** `timeout waiting for an available IP address`.
  Two mistakes in `main.tf`:
  1. `wait_for_guest_ip_timeout = 5` / `wait_for_guest_net_timeout = 5` —
     non-zero means "wait 5 min then FAIL", not "skip". → set both to `0`.
  2. **`firmware = "efi"`** (copied from the Ubuntu/haproxy pattern). The
     Avi OVA descriptor pins **`firmware = "bios"`**; EFI left the VM stuck
     at the EFI Boot Manager (confirmed via console screenshot) — OS never
     booted, hence no tools/IP and a misleading empty `guestinfo.ovfEnv`.
     → set `firmware = "bios"`.
- Recovery without re-uploading the 5 GB OVA: `terraform untaint` the VM,
  then a targeted in-place apply flipped firmware → BIOS (power-cycle only).
  VM then booted, VMware Tools came up, got `192.168.2.240` (pings), API
  came up, `admin`/`Srosario1!` → HTTP 200.
- Full `apply`: bootstrap ran (DNS/NTP/backup passphrase), cert fetched to
  `generated/avi-controller.crt`. `Apply complete! 3 added, 1 changed.`
- **Lesson (analogous to the HAProxy Phase-10/11 gotchas):** match
  `firmware` to the OVA descriptor; for Avi 31.x it's **BIOS**.

### (next) — Stage 2 (cloud-config)
- _pending_: `cd cloud-config && terraform init && terraform apply` to
  create the vCenter cloud, IPAM, VIP pool, SE group.
