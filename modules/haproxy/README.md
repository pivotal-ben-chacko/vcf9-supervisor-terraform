# `haproxy` module

Deploys the **HAProxy + Dataplane API** VM that Supervisor uses as its
load balancer. Encodes every Phase 7.B / 10 / 11 lesson:

- Phase 7.B — vanilla HAProxy on Ubuntu (skips the broken VMware HAProxy OVA)
- Phase 10 — systemd unit uses `-f` (dataplaneapi config) NOT `--config-file=` (HAProxy config)
- Phase 11 — VIPs `.249–.254` claimed on `ens192` as `/32` secondaries (so the kernel actually answers ARP)

## What it does

1. Generates a self-signed TLS cert for the Dataplane API
   (`modules/haproxy/generated/dpapi.{crt,key}`)
2. Renders `templates/user-data.yaml.tpl` with the lab-specific values
3. Deploys the Ubuntu 24.04 cloud OVA with that cloud-init via
   `extra_config.guestinfo.userdata`
4. cloud-init on first boot installs HAProxy + Dataplane API v2.9.25,
   writes a properly-indented dataplaneapi.yaml, writes a systemd unit
   with the correct `-f` flag, claims all VIPs via netplan, and starts
   the services
5. Post-apply validation: pings each VIP and tries a manual transaction
   commit against the Dataplane API. Failure = fail the apply. This
   catches Phase 10/11 regressions before Supervisor enable would
   silently hang on them.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `datacenter_id` | string | — | |
| `cluster_id` | string | — | resource pool / cluster for the VM |
| `datastore_id` | string | — | datastore for the VM disk |
| `network_id` | string | — | port group ID (the outer VM Network) |
| `vm_name` | string | `haproxy` | name of the VM |
| `ip_addr` | string | — | primary IP on ens192 |
| `gateway` | string | — | default gateway |
| `dns_servers` | list(string) | — | resolvers for /etc/resolv.conf |
| `dataplaneapi_version` | string | `2.9.25` | pinned version (avoids v2.9.10 YAML-rewrite bug) |
| `dataplaneapi_port` | number | `5556` | listen port |
| `dataplaneapi_user` | string | `admin` | basic-auth username |
| `dataplaneapi_password` | string (sensitive) | — | basic-auth password |
| `vip_addresses` | list(string) | — | VIPs to claim on ens192 as /32 |
| `ubuntu_ova_url` | string | — | OVA URL (or local path) |

## Outputs

| Name | Description |
|---|---|
| `dataplaneapi_endpoint` | `https://<ip>:5556` — pass to the supervisor module |
| `dataplaneapi_cert_path` | filesystem path to dpapi.crt (used by supervisor module for Server CA Certificate) |

## Files generated under the module

```
modules/haproxy/generated/
  dpapi.crt   ← self-signed cert (mode 0644)
  dpapi.key   ← key (mode 0600)
```

Both are in `.gitignore` — don't commit.
