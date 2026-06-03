#cloud-config
# HAProxy + Dataplane API cloud-init.
# Bakes in the Phase 10 fix (systemd `-f` flag, not `--config-file=`) and
# the Phase 11 fix (VIPs claimed on ens192 as /32 secondaries).

hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: ${dataplaneapi_password}
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false

write_files:
  # ── Static IP + VIPs ────────────────────────────────────────────────
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
            addresses:
              - ${ip_addr}/24
${netplan_vip_addresses}
            routes:
              - to: default
                via: ${gateway}
            nameservers:
              addresses: [${dns_servers}]

  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}

  # ── Enable non-local bind + forwarding ──────────────────────────────
  - path: /etc/sysctl.d/99-haproxy.conf
    content: |
      net.ipv4.ip_nonlocal_bind = 1
      net.ipv4.ip_forward = 1

  # ── Dataplane API TLS cert + key ────────────────────────────────────
  - path: /etc/haproxy/certs/dpapi.crt
    permissions: '0600'
    encoding: b64
    content: ${dpapi_cert_b64}

  - path: /etc/haproxy/certs/dpapi.key
    permissions: '0600'
    encoding: b64
    content: ${dpapi_key_b64}

  # ── Minimal seed haproxy.cfg (dataplaneapi takes over from here) ────
  - path: /etc/haproxy/haproxy.cfg
    permissions: '0644'
    # NOTE: no `owner: root:haproxy` — write_files runs BEFORE packages install,
    # so the haproxy group doesn't exist yet. Setting it here aborts write_files
    # for all subsequent entries. Package install creates the group later; root
    # ownership + 0644 perms are fine for haproxy to read.
    content: |
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

  # ── Dataplane API config — properly indented YAML ───────────────────
  # The dataplaneapi v2.9.10 bug rewrote this file without indentation;
  # we pin a newer version below to avoid that. Even so, keep the YAML
  # tidy in case anyone diffs it.
  - path: /etc/haproxy/dataplaneapi.yaml
    permissions: '0600'
    content: |
      config_version: 2
      name: haproxy-lab
      mode: single

      dataplaneapi:
        host: 0.0.0.0
        port: ${dataplaneapi_port}
        scheme:
          - https
        tls:
          tls_host: 0.0.0.0
          tls_port: ${dataplaneapi_port}
          tls_certificate: /etc/haproxy/certs/dpapi.crt
          tls_key: /etc/haproxy/certs/dpapi.key
        user:
          - name: ${dataplaneapi_user}
            password: ${dataplaneapi_password_hash}
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

  # ── systemd unit — CRITICAL: uses `-f` flag (Phase 10 fix) ──────────
  - path: /etc/systemd/system/dataplaneapi.service
    permissions: '0644'
    content: |
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

package_update: true
packages:
  - haproxy
  - openssl
  - jq
  - curl
  - open-vm-tools
  - net-tools
  - ca-certificates
  - python3
  - iputils-arping   # for gratuitous-ARP announcement of VIPs at boot

runcmd:
  # Apply network config so the VM is reachable post-boot
  - rm -f /etc/netplan/50-cloud-init.yaml
  - chmod 600 /etc/netplan/60-static.yaml
  - netplan apply
  - sysctl --system

  # Download dataplaneapi binary at the pinned version
  - >
    curl -fsSL -o /tmp/dpapi.tar.gz
    "https://github.com/haproxytech/dataplaneapi/releases/download/v${dataplaneapi_version}/dataplaneapi_${dataplaneapi_version}_Linux_x86_64.tar.gz"
  - tar -xzf /tmp/dpapi.tar.gz -C /tmp/
  - install -m 0755 /tmp/dataplaneapi /usr/local/bin/dataplaneapi
  - rm -f /tmp/dpapi.tar.gz /tmp/dataplaneapi /tmp/dataplaneapi.yml.dist /tmp/CHANGELOG.md /tmp/LICENSE /tmp/README.md

  # Storage dirs
  - install -d -m 0755 /etc/haproxy/maps /etc/haproxy/ssl /tmp/haproxy

  # Announce VIPs via gratuitous ARP so upstream routers/switches cache them
  # immediately. Done BEFORE starting the dataplane API: the validator races
  # the API "ready" signal against the arping completion — if arping comes
  # after, the last VIPs in the list look DEAD until ARP catches up.
  # -c1 -w1 is enough to register; we run all 6 in ~1s total.
  - for ip in ${vip_list}; do arping -A -c1 -w1 -I ens192 "$ip" || true; done

  # Start services (do this AFTER arping so dataplaneapi-reachable is a strong
  # signal that all VIPs are externally pingable)
  - systemctl daemon-reload
  - systemctl enable open-vm-tools
  - systemctl enable --now haproxy
  - systemctl enable --now dataplaneapi

final_message: "HAProxy + Dataplane API ready on https://${ip_addr}:${dataplaneapi_port}"
