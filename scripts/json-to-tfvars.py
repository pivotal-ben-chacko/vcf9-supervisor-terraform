#!/usr/bin/env python3
"""
json-to-tfvars.py — Translate the human-friendly wcp-config-Skynet.json
into a Terraform config.auto.tfvars + a HAProxy CA cert file.

This is the "Option C" path: keep the JSON as the single source of
truth for human-edited config, regenerate the Terraform inputs from
it whenever you change a value.

Usage:
    ./json-to-tfvars.py  <input.json>  <out-tfvars-path>  <out-cert-path>

Example (driven by `make sync-config`):
    ./terraform/scripts/json-to-tfvars.py \\
        terraform/wcp-config-Skynet.json \\
        terraform/examples/lab/config.auto.tfvars \\
        haproxy-dpapi.crt

Anything not in the JSON (passwords, vCenter username, paths) stays in
secrets.auto.tfvars or the example's main.tf and is preserved untouched.
"""

import ipaddress
import json
import sys
from pathlib import Path


def parse_endpoint(ep: str):
    """'192.168.3.245:5556' → ('192.168.3.245', 5556)"""
    host, port = ep.split(":")
    return host.strip(), int(port.strip())


def parse_gateway_cidr(cidr: str):
    """'192.168.2.1/24' → ('192.168.2.1', '192.168.2.0/24', '255.255.255.0')"""
    iface = ipaddress.ip_interface(cidr)
    return str(iface.ip), str(iface.network), str(iface.netmask)


def parse_ip_range(s: str):
    """'192.168.3.249 - 192.168.3.254' → ('192.168.3.249', '192.168.3.254')
       '192.168.2.231' → ('192.168.2.231', '192.168.2.231')"""
    parts = [p.strip() for p in s.split("-")]
    if len(parts) == 1:
        return parts[0], parts[0]
    return parts[0], parts[1]


def enumerate_ips(start: str, end: str):
    s = int(ipaddress.IPv4Address(start))
    e = int(ipaddress.IPv4Address(end))
    return [str(ipaddress.IPv4Address(i)) for i in range(s, e + 1)]


def smallest_cidr_containing(ips):
    """Given a list of consecutive IPs, return the smallest /N CIDR that
    contains them with the same network number. Useful for vip_pool.
    E.g. .249..254 → 192.168.3.248/29 (which holds .249-.254 as usable)."""
    addrs = [ipaddress.IPv4Address(ip) for ip in ips]
    addrs.sort()
    candidate_supernet = list(
        ipaddress.summarize_address_range(addrs[0], addrs[-1])
    )
    # Often what we want is the next-wider /29 etc that holds the range.
    # If summarize gives exactly one network, use it; otherwise pick the
    # supernet of the first and last.
    if len(candidate_supernet) == 1:
        return str(candidate_supernet[0])
    # Else widen until both fit
    first = ipaddress.IPv4Network(f"{addrs[0]}/32")
    for prefix in range(31, 23, -1):  # try /31 down to /24
        net = first.supernet(new_prefix=prefix)
        if addrs[-1] in net:
            return str(net)
    return None


def hcl(value):
    """JSON dump without trailing whitespace issues, suitable as HCL."""
    return json.dumps(value)


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    in_path = Path(sys.argv[1])
    tfvars_path = Path(sys.argv[2])
    cert_path = Path(sys.argv[3])

    cfg = json.loads(in_path.read_text())

    # ── Extract from JSON ───────────────────────────────────────────────
    env = cfg["envSpec"]["vcenterDetails"]
    tkg = cfg["tkgsComponentSpec"]
    hap = tkg["haProxyComponents"]
    mgmt = tkg["tkgsMgmtNetworkSpec"]
    work = tkg["tkgsPrimaryWorkloadNetwork"]
    stor = tkg["tkgsStoragePolicySpec"]

    # HAProxy
    ha_host, ha_port = parse_endpoint(hap["haProxyControllerEndpoint"][0])
    ha_user = hap["haProxyUsername"]
    vip_start, vip_end = parse_ip_range(hap["haProxyVirtualIpAddressRanges"][0])
    vips = enumerate_ips(vip_start, vip_end)
    # Compute the smallest CIDR that holds the VIPs (used by Supervisor
    # spec which wants a CIDR, not a list).
    vip_pool = smallest_cidr_containing(vips) or f"{vip_start}/29"

    # Management network
    mgmt_gw, mgmt_subnet, _ = parse_gateway_cidr(mgmt["tkgsMgmtNetworkGatewayCidr"])
    mgmt_start, _ = parse_ip_range(mgmt["tkgsMgmtNetworkStartingIp"])
    mgmt_dns = mgmt["tkgsMgmtNetworkDnsServers"]

    # Workload network
    work_gw, work_subnet, _ = parse_gateway_cidr(work["tkgsPrimaryWorkloadNetworkGatewayCidr"])
    work_start = work["tkgsPrimaryWorkloadNetworkStartRange"]
    work_end = work["tkgsPrimaryWorkloadNetworkEndRange"]
    work_dns = work["tkgsWorkloadDnsServers"]
    work_service_cidr = work["tkgsWorkloadServiceCidr"]

    # Storage policy — all 3 should match
    policies = {stor["masterStoragePolicy"], stor["ephemeralStoragePolicy"], stor["imageStoragePolicy"]}
    if len(policies) > 1:
        print(f"WARNING: multiple storage policies referenced: {policies}", file=sys.stderr)
    storage_policy = stor["masterStoragePolicy"]

    # Control plane
    cp_size = tkg.get("controlPlaneSize", "TINY")
    cp_count = tkg.get("cpvmCount", 1)
    ha_on = cp_count >= 3
    sup_name = cfg["supervisorSpec"]["supervisorName"]

    # vCenter
    vc_addr = env["vcenterAddress"]
    vc_cluster = env["vcenterCluster"]

    # HAProxy CA cert
    cert_chain = hap["haProxyCertAuthorityChain"]

    # ── Emit tfvars ─────────────────────────────────────────────────────
    lines = [
        f"# AUTO-GENERATED by terraform/scripts/json-to-tfvars.py",
        f"# Source: {in_path.relative_to(Path.cwd()) if in_path.is_absolute() and Path.cwd() in in_path.parents else in_path}",
        f"# Edit the source JSON and run `make sync-config` to regenerate.",
        f"# DO NOT EDIT THIS FILE — your changes will be overwritten.",
        f"",
        f"# ── vCenter ──",
        f"vcenter_server     = {hcl(vc_addr)}",
        f"supervisor_cluster = {hcl(vc_cluster)}",
        f"",
        f"# ── HAProxy ──",
        f"haproxy_ip                = {hcl(ha_host)}",
        f"haproxy_dataplaneapi_port = {ha_port}",
        f"haproxy_username          = {hcl(ha_user)}",
        f"vip_pool                  = {hcl(vip_pool)}",
        f"vip_pool_usable           = {hcl(vips)}",
        f"",
        f"# ── Management network (post-Phase-9 fix: separate from workload) ──",
        f"management_subnet         = {hcl(mgmt_subnet)}",
        f"management_gateway        = {hcl(mgmt_gw)}",
        f"management_cp_starting_ip = {hcl(mgmt_start)}",
        f"management_dns            = {hcl(mgmt_dns)}",
        f"",
        f"# ── Workload network ──",
        f"workload_subnet   = {hcl(work_subnet)}",
        f"workload_gateway  = {hcl(work_gw)}",
        f"workload_ip_range = {hcl(f'{work_start}-{work_end}')}",
        f"workload_dns      = {hcl(work_dns)}",
        f"k8s_service_cidr  = {hcl(work_service_cidr)}",
        f"",
        f"# ── Storage ──",
        f"# (Translator emits the policy name; supervisor module's vars consume it)",
        f"# storage_policy_name = {hcl(storage_policy)}    # currently passed inside the supervisor module",
        f"",
        f"# ── Control plane ──",
        f"control_plane_size = {hcl(cp_size)}",
        f"control_plane_ha   = {hcl(ha_on)}",
        "",
    ]

    tfvars_path.parent.mkdir(parents=True, exist_ok=True)
    tfvars_path.write_text("\n".join(lines))
    print(f"wrote {tfvars_path} ({tfvars_path.stat().st_size} bytes)")

    # ── Emit cert ───────────────────────────────────────────────────────
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    cert_path.write_text(cert_chain)
    print(f"wrote {cert_path} ({cert_path.stat().st_size} bytes)")

    # ── Summary ─────────────────────────────────────────────────────────
    print()
    print(f"  Supervisor:       {sup_name}")
    print(f"  vCenter:          {vc_addr} / {vc_cluster}")
    print(f"  HAProxy:          {ha_host}:{ha_port} (user={ha_user})")
    print(f"  VIP pool:         {vip_pool} ({len(vips)} usable IPs)")
    print(f"  Mgmt network:     {mgmt_subnet} (gw {mgmt_gw}), start {mgmt_start}")
    print(f"  Workload network: {work_subnet} (gw {work_gw}), {work_start}-{work_end}")
    print(f"  Storage policy:   {storage_policy}")
    print(f"  CP size / count:  {cp_size} × {cp_count}{' (HA on)' if ha_on else ' (HA off)'}")


if __name__ == "__main__":
    main()
