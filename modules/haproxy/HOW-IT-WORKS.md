# How the HAProxy load balancer works

This document explains, end-to-end, how the `haproxy` module's load
balancer actually functions: what the two binaries are, how the vSphere
Supervisor control plane programs it over a REST API, and — in detail —
**how HAProxy applies configuration changes live without dropping
traffic.**

It consolidates the architecture, the wire-level reachability story, and
the two hard-won fixes (the systemd `-f` flag and the VIP/ARP claim) that
were previously scattered across the bring-up runbook
(`SUPERVISOR-INSTALL.md` Phases 7.B / 10 / 11). If you only read one
HAProxy doc, read this one; the README next door is the module reference
(inputs/outputs), and the runbook is the chronological post-mortem.

---

## 1. The two binaries

The VM runs **two separate processes**, both from HAProxy Technologies,
as **two separate systemd units**:

| Component | Origin | Role |
|---|---|---|
| `haproxy` | Ubuntu `apt` package (BSD-licensed) | The actual TCP/HTTP load balancer. Receives client traffic on the VIPs and forwards it to backend servers (the Supervisor control-plane VM and, later, pods). |
| `dataplaneapi` | Pre-built Go binary from `haproxytech/dataplaneapi` GitHub releases (Apache-2.0), pinned to **v2.9.25** | A REST API daemon that **edits HAProxy's config file and triggers reloads** so external systems can reprogram HAProxy without hand-editing files. |

Why two pieces? HAProxy Community Edition is *just the proxy* — no API.
HAProxy Enterprise bundles a Dataplane API, but the Dataplane API is
itself open source, so **Community HAProxy + Dataplane API** gives you an
Enterprise-style *programmable* load balancer for free. (The VMware
HAProxy OVA bundled both plus its own VIP allocator, but its firstboot
doesn't deploy on vCenter 9.0.2 — see runbook Phase 7.A — so we rebuilt
the stack on a plain Ubuntu cloud VM.)

The two processes communicate through exactly two channels:

- **`/etc/haproxy/haproxy.cfg`** — the on-disk config file. Dataplane API
  owns and rewrites it; HAProxy reads it on (re)start.
- **`/run/haproxy/admin.sock`** — HAProxy's runtime (stats) Unix socket.
  Dataplane API sends live, in-memory commands here ("set server weight",
  "disable server") that take effect *without* a reload.

That split — **config file for structural changes, runtime socket for
state changes** — is the key to understanding "live updates" (§6).

---

## 2. Why the Supervisor needs it

The Supervisor enablement wizard refuses to turn on unless it has a load
balancer that can (a) front the Kubernetes API server and (b) program a
new frontend/backend every time a user creates a
`Service{type: LoadBalancer}`. VMware supports two LB types: NSX Advanced
Load Balancer (Avi) or HAProxy. We use HAProxy because Avi needs its own
controller VM and licensing.

Once enabled, every `kubectl expose --type=LoadBalancer` requires the
platform to:

1. Allocate a VIP from the configured pool (`192.168.3.249–.254`),
2. Add an HAProxy **frontend** bound to that VIP,
3. Add an HAProxy **backend** with the pod endpoint IPs as servers,
4. Reload HAProxy so the change is live.

Doing that by hand-editing `haproxy.cfg` and running `systemctl reload`
per service would be unworkable — so the platform drives the Dataplane
API instead.

---

## 3. The control plane: who programs HAProxy, and how

There are two distinct control planes in play. Don't conflate them.

### 3a. Terraform (day-0, builds the box)

The `haproxy` module (`main.tf`) only *builds and validates* the LB VM.
It does **not** define any frontends/backends — those are created later by
the Supervisor. The module:

1. Generates a self-signed TLS cert for the Dataplane API
   (`generated/dpapi.{crt,key}`), SAN = the VM's IP. The Supervisor pins
   this cert.
2. Hashes the Dataplane API password (`openssl passwd -1`) for the YAML.
3. Renders `templates/user-data.yaml.tpl` and deploys the Ubuntu 24.04
   cloud OVA with that cloud-init via `guestinfo.userdata`.
4. cloud-init on first boot installs `haproxy`, downloads the pinned
   `dataplaneapi`, writes a minimal seed `haproxy.cfg`, the
   `dataplaneapi.yaml`, the systemd unit (with the correct `-f` flag),
   claims the VIPs on `ens192`, gratuitous-ARPs them, and starts both
   services.
5. **Post-apply validation** (`null_resource.validate_dataplane_api`):
   polls `/v2/info`, runs a real transaction (create + commit + delete a
   throwaway backend), and pings every VIP. A failure fails the apply —
   this catches a Phase 10 or Phase 11 regression *before* the Supervisor
   would silently hang on it.

Outputs `dataplaneapi_endpoint` (`https://<ip>:5556`) and
`dataplaneapi_cert_path` are handed to the `supervisor` module, which
passes them into the enablement spec (`load_balancer_config_spec` with the
host/port, basic-auth creds, and `certificate_authority_chain`).

### 3b. vSphere Supervisor / WCP (day-1+, programs the LB continuously)

After enablement, the component that actually talks to the Dataplane API
is the **`lbapi` controller** (`vmware-system-lbapi`) running inside the
Supervisor control-plane VM, coordinated by **WCP** in vCenter. Its loop:

```
 user: kubectl expose deploy/foo --type=LoadBalancer
        │
        ▼
 Supervisor (WCP / lbapi-controller-manager)  — reconciles Gateway/Service objects
        │   speaks REST over HTTPS, basic-auth admin:••••, TLS-pinned to dpapi.crt
        ▼
 Dataplane API  (:5556 on the HAProxy VM)
        │   edits /etc/haproxy/haproxy.cfg, then `systemctl reload haproxy`
        ▼
 haproxy        — new frontend/backend live; EXTERNAL-IP assigned from the VIP pool
```

You can watch this happen: `sudo journalctl -u dataplaneapi` on the LB VM
shows the POSTs arrive as the Supervisor finishes enabling — that's the
green flag that WCP programmed HAProxy successfully.

---

## 4. How the Supervisor uses the Dataplane API (the transaction model)

The Dataplane API is a REST wrapper over the HAProxy config. Endpoints the
Supervisor uses:

| Path | Purpose |
|---|---|
| `GET /v2/info` | Health/version check — `200` + `"version"` means it's alive |
| `GET /v2/services/haproxy/configuration/version` | Current config version (optimistic-concurrency token) |
| `POST /v2/services/haproxy/transactions?version=N` | Open a transaction against version `N` |
| `.../configuration/frontends?transaction_id=…` | Add/remove/list frontends |
| `.../configuration/backends?transaction_id=…` | Add/remove/list backends |
| `.../configuration/servers?transaction_id=…` | Add/remove/list backend members |
| `PUT /v2/services/haproxy/transactions/{id}` | **Commit** the transaction atomically |

The important property is that changes are **transactional and atomic**.
Rather than mutate `haproxy.cfg` line by line and hope each intermediate
state is valid, the controller:

1. Reads the current config **version** (a monotonically increasing
   integer the API stamps into the file). This is optimistic concurrency:
   if someone else committed in the meantime, your commit is rejected and
   you retry against the new version.
2. Opens a **transaction** bound to that version. The API copies the
   current config to a scratch file `/tmp/haproxy/haproxy.cfg.<tx-id>`.
3. Issues one or more change operations (add backend, add frontend, add
   servers) — these accumulate in the scratch file, *not* in the live
   config.
4. **Commits** with `PUT …/transactions/{id}`. Only now does the API:
   - run `haproxy -c -f /tmp/haproxy/haproxy.cfg.<tx-id>` to **validate**
     the candidate config,
   - if valid → atomically `rename()` the scratch file over
     `/etc/haproxy/haproxy.cfg` and run the configured reload command,
   - if invalid → return `400 Bad Request` and discard the scratch file;
     the live config is untouched.

So a bad change can never reach the running proxy: it's rejected at commit
with the live config still intact. This is exactly the flow the module's
post-deploy validator exercises end-to-end.

The relevant `dataplaneapi.yaml` keys that wire this up:

```yaml
haproxy:
  config_file: /etc/haproxy/haproxy.cfg     # the file the API rewrites
  haproxy_bin: /usr/sbin/haproxy            # used for `-c` validation
  reload:
    reload_cmd:  "systemctl reload haproxy" # how the API tells HAProxy to apply
    restart_cmd: "systemctl restart haproxy"
    status_cmd:  "systemctl is-active haproxy"
    reload_delay: 2
transaction:
  transaction_dir: /tmp/haproxy             # scratch dir for candidate configs
```

---

## 5. Full architecture diagram

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ CONTROL PLANE (who changes the config)                                          │
│                                                                                  │
│   kubectl expose --type=LoadBalancer                                             │
│            │                                                                     │
│            ▼                                                                     │
│   ┌──────────────────────────┐        ┌──────────────────────────────────┐      │
│   │ vCenter / WCP            │  REST  │ lbapi-controller (on CP VM)        │      │
│   │ namespace_management     │◀──────▶│ vmware-system-lbapi                │      │
│   └──────────────────────────┘        └───────────────┬──────────────────┘      │
│                                                        │ HTTPS :5556              │
│                          basic-auth admin:••••  +  TLS-pinned to dpapi.crt        │
└────────────────────────────────────────────────────────┼─────────────────────────┘
                                                          │
                                                          ▼
┌────────────────────────────────────────────────────────────────────────────────┐
│ HAProxy VM  (Ubuntu 24.04, ens192 on the outer "VM Network", 192.168.3.245/24)  │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │ ens192 — kernel OWNS these IPs (`ip addr add`), so it answers ARP for them │  │
│  │   192.168.3.245/24   primary, default route via .3.1                      │  │
│  │   192.168.3.249/32   CSI controller VIP         ┐                          │  │
│  │   192.168.3.250/32   mgmt-image-proxy VIP       │  Phase 11 fix: each VIP  │  │
│  │   192.168.3.251/32   kube-apiserver LB VIP      │  is a /32 secondary so   │  │
│  │   192.168.3.252/32   ┐ reserved for             │  the kernel ARP-replies  │  │
│  │   192.168.3.253/32   ├─ user LoadBalancer       │  and delivers packets to │  │
│  │   192.168.3.254/32   ┘ Services                 ┘  the listening socket.   │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
│  ┌────────────────────────────────┐   reads/writes   ┌─────────────────────────┐│
│  │ dataplaneapi.service           │ ───────────────▶ │ /etc/haproxy/haproxy.cfg ││
│  │ ExecStart=dataplaneapi \       │                  └──────────┬──────────────┘│
│  │   -f /etc/haproxy/             │   `systemctl reload haproxy`│                │
│  │      dataplaneapi.yaml         │ ────────────────────────────┼──────────┐     │
│  │   (Phase 10 fix: -f, NOT       │                             │          │     │
│  │    --config-file=)             │   runtime cmds              ▼          │     │
│  │ Listens *:5556 HTTPS (admin)   │ ──────────▶ /run/haproxy/admin.sock    │     │
│  └────────────────────────────────┘            (live, no reload)          │     │
│                                                                            ▼     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │ haproxy.service  (master-worker, started with `-Ws`)                       │  │
│  │                                                                            │  │
│  │  frontend kube-apiserver-lb-svc   bind .251:6443, .251:443   mode tcp      │  │
│  │     backend → server cp1 192.168.3.201:6443 check                          │  │
│  │  frontend mgmt-image-proxy        bind .250:443                            │  │
│  │     backend → server cp1 192.168.3.201:443                                 │  │
│  │  frontend vsphere-csi-controller  bind .249:2112, .249:2113                │  │
│  │     backend → server cp1 192.168.3.201:2112 / :2113                        │  │
│  │  (user LB Services add more frontends, consuming .252/.253/.254)           │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                          │  plain TCP forward (no TLS termination)
                                          ▼
                        ┌────────────────────────────────────┐
                        │ Supervisor control-plane VM ("cp1") │
                        │   eth0 192.168.2.232 (mgmt)         │
                        │   eth1 192.168.3.201 (workload)     │
                        │   kube-apiserver :6443              │
                        │   nginx redirect :443              │
                        │   CSI controller :2112 / :2113     │
                        │   mgmt-image-proxy :443            │
                        └────────────────────────────────────┘
```

### IP-to-port reference

| IP | Port | Direction | Purpose |
|---|---|---|---|
| `192.168.3.245` | `22` | inbound (admin) | SSH to the `ubuntu` user |
| `192.168.3.245` | `5556` | inbound (vCenter/lbapi) | **Dataplane API (HTTPS)** — basic auth, TLS pinned via `dpapi.crt` |
| `192.168.3.249` | `2112/2113` | inbound | vSphere CSI controller/syncer LB → CP `.201` |
| `192.168.3.250` | `443` | inbound | Supervisor mgmt-image-proxy LB → CP `.201:443` |
| `192.168.3.251` | `6443` | inbound (kubectl) | **K8s API LB** → CP `.201:6443` |
| `192.168.3.251` | `443` | inbound (browsers) | nginx redirect / plugin download → CP `.201:443` |
| `192.168.3.252–.254` | dynamic | inbound | reserved for user `Service{type:LoadBalancer}` VIPs |
| `192.168.3.245` | outbound | from HAProxy | default route `.3.1`, DNS, TKG content library if subscribed |

---

## 6. How HAProxy applies the change live (the part people get wrong)

"Live update" actually covers **two different mechanisms** inside HAProxy.
The Dataplane API uses both, depending on what changed.

### 6a. Runtime state changes — truly live, no reload

Changes to *existing* objects — marking a server up/down, changing a
server's weight, draining a server, even adding/removing a server in a
backend that has spare `server` slots — are sent as text commands over
**`/run/haproxy/admin.sock`** (HAProxy's "Runtime API"). The running
worker applies them **in memory, instantly, with zero connection
impact**. Nothing is re-parsed, nothing forks, no socket is touched.

This is why health-check-driven changes (a backend pod going unhealthy)
don't churn the config file at all.

### 6b. Structural changes — require a reload (new worker generation)

Adding a **new frontend or backend** (which is what a new
`Service{type:LoadBalancer}` needs) changes the *structure* of the
config — new listening sockets, new sections. HAProxy cannot splice those
into a running worker's memory, so the Dataplane API writes the new
`haproxy.cfg` and runs `systemctl reload haproxy`. Here is exactly what
that reload does, and why in-flight traffic survives it:

```
 1. systemd ExecReload first runs:  haproxy -Ws -f haproxy.cfg -c -q
        → validates the new config. If it fails, the reload aborts and the
          old workers keep running untouched. (Belt-and-suspenders: the
          Dataplane API already validated at commit time in §4.)

 2. systemd sends SIGUSR2 to the HAProxy *master* process (PID 1 of the
    haproxy unit; it runs in master-worker mode because of `-Ws`).

 3. The master re-execs itself and re-reads haproxy.cfg, then FORKS A NEW
    GENERATION OF WORKERS bound to the new config.

 4. The listening sockets (the binds on :6443, :443, the VIPs, …) are held
    by the MASTER and inherited by every worker generation. Because the
    master never closes them, there is no window where the VIP stops
    accepting connections — new connections are handed straight to the new
    workers. This is the "seamless / hitless reload" property of
    master-worker mode (HAProxy passes the listening file descriptors
    across the reload rather than close/reopen them).

 5. The OLD workers are told to "soft-stop" (internally, `-sf <old-pids>`):
        - they STOP accepting new connections,
        - they keep serving their existing in-flight connections until
          those finish (or until `hard-stop-after`, if configured),
        - then they exit.

 6. Result: established TCP sessions on the old workers drain gracefully
    while brand-new sessions land on the new workers. No accept() gap, no
    RST storm. From a kubectl client's perspective the API VIP never blips.
```

So the mental model is:

- **State of an existing server** → runtime socket → live, in place.
- **Shape of the config (new/removed sections)** → file rewrite + reload →
  new worker generation, old one drains, listeners preserved by the
  master. Atomic at the file level (`rename()`), validated before it can
  ever go live, and seamless on the connection path.

`reload_delay: 2` in `dataplaneapi.yaml` simply coalesces a burst of
commits (e.g. the Supervisor creating several Services at once) so they
ride a single reload instead of one reload per change.

---

## 7. Reachability: why the VIPs need `/32` + ARP (Phase 11)

A subtle failure: HAProxy can *listen* on a VIP it doesn't own (thanks to
`net.ipv4.ip_nonlocal_bind = 1`), but `bind()` permission is **not** the
same as the kernel owning the address. `ip_nonlocal_bind` only affects the
`bind()` syscall — it does **not** make the kernel:

- add the IP to an interface,
- **answer ARP** for the IP,
- reply to ICMP for the IP.

So with only the sysctl set, HAProxy shows `LISTEN` on `.251:6443`, but a
packet addressed to `.251` never arrives: when the upstream router
(EdgeRouter on `192.168.3.0/24`) needs to deliver it, it broadcasts an ARP
"who has 192.168.3.251?" — and **nobody answers**, because no interface
owns that IP. The router retries a few times, then drops the packet. The
symptom was the spherelet on each ESXi host stuck for 75+ minutes with
"context deadline exceeded" trying to reach the kube-apiserver VIP.

**Fix:** claim every pool VIP as a `/32` secondary address on `ens192`
(done in cloud-init via netplan). Now the kernel owns the address at layer
2 — it ARP-replies, accepts the frame, and delivers it to HAProxy's
listening socket. cloud-init also fires a gratuitous ARP (`arping -A`) per
VIP at boot so upstream switches/routers cache the IP→MAC binding
immediately instead of waiting for the first cold ARP.

```
EdgeRouter ──"ARP: who has .251?"──▶ broadcast on LAN3
HAProxy VM kernel (owns .251/32)  ──"ARP: .251 is at <my MAC>"──▶ reply
EdgeRouter caches IP→MAC, forwards the packet ──▶ HAProxy accepts on :6443
```

The module's post-deploy validator pings every VIP and fails the apply if
any is unreachable, so a Phase 11 regression is caught at `terraform
apply` time, not three wizard steps later.

---

## 8. The systemd `-f` flag (Phase 10)

The Dataplane API's CLI flags are dangerously easy to swap:

```
-f=                  Path to the DATAPLANE config file   (dataplaneapi.yaml)
-c, --config-file=   Path to the HAPROXY config file     (haproxy.cfg)
```

`--config-file=` *sounds* like the daemon's own config but means
`haproxy.cfg`. An early setup script used
`dataplaneapi --config-file=/etc/haproxy/dataplaneapi.yaml`, which told the
Dataplane API "your HAProxy config is this YAML file." It then "managed"
that YAML (stamped a `# Dataplaneapi managed File` header, rewrote it
**without indentation**), and on every commit copied it to
`/tmp/haproxy/dataplaneapi.yaml.<txid>` and ran `haproxy -c -f` on it —
which fails, because YAML isn't HAProxy syntax. Every commit returned
`400`, lbapi never progressed, and Supervisor enablement hung forever at
the LoadBalancer-service step with `EXTERNAL-IP: <pending>`.

**Fix:** the systemd unit must use `-f`:

```ini
ExecStart=/usr/local/bin/dataplaneapi -f /etc/haproxy/dataplaneapi.yaml
```

This is baked into `templates/user-data.yaml.tpl`, and the post-deploy
validator's transaction-commit test exists specifically to catch a
regression here (a broken `-f`/`--config-file=` swap makes the commit
return `400`, failing the apply).

> Related pin: `dataplaneapi_version` defaults to **2.9.25**. v2.9.10 had a
> bug that rewrote `dataplaneapi.yaml` without indentation; pinning a newer
> build avoids it even if the `-f` flag is correct.

---

## 9. Boot sequence (what cloud-init does, in order)

1. Write static IP + all VIPs to netplan, disable cloud-init networking,
   set `ip_nonlocal_bind` / `ip_forward`, drop the TLS cert/key, the seed
   `haproxy.cfg`, the `dataplaneapi.yaml`, and the systemd unit.
   *(Note: the seed `haproxy.cfg` is written `root:root 0644` with no
   `owner: root:haproxy` — `write_files` runs before package install, so
   the `haproxy` group doesn't exist yet; setting it would abort the rest
   of `write_files`.)*
2. Install `haproxy` + tools; download and install the pinned
   `dataplaneapi` binary.
3. `netplan apply` (VIPs now owned by the kernel), `sysctl --system`.
4. Gratuitous-ARP every VIP **before** starting services, so by the time
   the Dataplane API reports "ready" the VIPs are already externally
   pingable (avoids a race where the last VIPs look DEAD until ARP catches
   up).
5. `systemctl enable --now haproxy` then `dataplaneapi`.

From here the box is idle until the Supervisor's `lbapi` controller starts
POSTing frontends/backends — at which point §4 and §6 take over.

---

## 10. Operational quick-reference

```bash
# Is the Dataplane API alive?
curl -sk -u admin:'<pw>' https://192.168.3.245:5556/v2/info | jq .version

# What does HAProxy currently have configured? (expect ~5 backends once K8s is up)
curl -sk -u admin:'<pw>' https://192.168.3.245:5556/v2/services/haproxy/configuration/backends | jq '.data[].name'

# Watch the Supervisor program the LB in real time
sudo journalctl -u dataplaneapi -f

# Live worker/server state (runtime API, no reload)
echo "show servers state" | sudo socat - /run/haproxy/admin.sock

# Are all VIPs reachable from a client? (Phase 11 check)
for ip in 192.168.3.249 250 251 252 253 254; do ping -c1 -W2 192.168.3.$ip >/dev/null \
  && echo "$ip OK" || echo "$ip DEAD"; done
```

**See also:** module `README.md` (inputs/outputs), `SUPERVISOR-INSTALL.md`
Phases 7.B (build), 10 (the `-f` flag), and 11 (VIP/ARP) for the original
chronological diagnosis.
