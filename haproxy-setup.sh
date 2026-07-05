#!/usr/bin/env bash
# Run on the haproxy VM (192.168.3.245) after the cloud-init base install.
# Installs HAProxy Dataplane API, generates a self-signed cert, wires up
# systemd, and exposes the API on https://192.168.3.245:5556 with basic
# auth `admin:Srosario1!`.
#
# Usage:
#   scp haproxy-setup.sh ubuntu@192.168.3.245:/tmp/
#   ssh ubuntu@192.168.3.245 'sudo bash /tmp/haproxy-setup.sh'

set -euo pipefail

DPAPI_USER='admin'
DPAPI_PASS='Srosario1!'
DPAPI_PORT='5556'
DPAPI_VER='2.9.10'
VIP_RANGE='192.168.3.248/29'
SAN_IP='192.168.3.245'

# ---- 1. Install Dataplane API binary ----
if ! command -v dataplaneapi >/dev/null 2>&1; then
  echo "[*] downloading dataplaneapi ${DPAPI_VER}..."
  curl -fsSL -o /tmp/dpapi.tar.gz \
    "https://github.com/haproxytech/dataplaneapi/releases/download/v${DPAPI_VER}/dataplaneapi_${DPAPI_VER}_Linux_x86_64.tar.gz"
  tar -xzf /tmp/dpapi.tar.gz -C /tmp/
  # tar is flat — binary lands directly at /tmp/dataplaneapi
  install -m 0755 /tmp/dataplaneapi /usr/local/bin/dataplaneapi
  rm -f /tmp/dpapi.tar.gz /tmp/dataplaneapi /tmp/dataplaneapi.yml.dist /tmp/CHANGELOG.md /tmp/LICENSE /tmp/README.md
fi
echo "[*] dataplaneapi $(dataplaneapi --version 2>&1 | head -1)"

# ---- 2. Generate self-signed TLS cert for the API ----
install -d -m 0750 -o root -g root /etc/haproxy/certs
if [ ! -f /etc/haproxy/certs/dpapi.crt ]; then
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout /etc/haproxy/certs/dpapi.key \
    -out    /etc/haproxy/certs/dpapi.crt \
    -days 825 \
    -subj "/CN=haproxy/O=lab" \
    -addext "subjectAltName=IP:${SAN_IP},DNS:haproxy" 2>/dev/null
  chmod 600 /etc/haproxy/certs/*
fi
echo "[*] dpapi cert SAN: $(openssl x509 -in /etc/haproxy/certs/dpapi.crt -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | xargs)"

# ---- 3. Minimal seed haproxy.cfg (Dataplane API will manage it from here) ----
cat > /etc/haproxy/haproxy.cfg <<'CFG'
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
CFG
chown root:haproxy /etc/haproxy/haproxy.cfg
chmod 644 /etc/haproxy/haproxy.cfg

# ---- 4. Dataplane API config ----
DPAPI_PASS_HASH=$(openssl passwd -1 "${DPAPI_PASS}")
cat > /etc/haproxy/dataplaneapi.yaml <<CFG
config_version: 2
name: haproxy-lab
mode: single

dataplaneapi:
  host: 0.0.0.0
  port: ${DPAPI_PORT}
  scheme:
    - https
  tls:
    tls_host: 0.0.0.0
    tls_port: ${DPAPI_PORT}
    tls_certificate: /etc/haproxy/certs/dpapi.crt
    tls_key: /etc/haproxy/certs/dpapi.key
  user:
    - name: ${DPAPI_USER}
      password: ${DPAPI_PASS_HASH}
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
CFG
chmod 600 /etc/haproxy/dataplaneapi.yaml

install -d -m 0755 /etc/haproxy/maps /etc/haproxy/ssl /tmp/haproxy

# ---- 5. systemd unit for dataplaneapi ----
cat > /etc/systemd/system/dataplaneapi.service <<'UNIT'
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

systemctl daemon-reload
systemctl enable --now haproxy
systemctl enable --now dataplaneapi
sleep 3

# ---- 6. Verify ----
echo
echo "=== systemd status ==="
systemctl is-active haproxy dataplaneapi
echo
echo "=== dataplane API /v3/info ==="
curl -sk -u "${DPAPI_USER}:${DPAPI_PASS}" --max-time 5 \
  "https://localhost:${DPAPI_PORT}/v3/info" | head -10
echo
echo "=== cert fingerprint (Supervisor will pin this) ==="
openssl x509 -in /etc/haproxy/certs/dpapi.crt -noout -fingerprint -sha256
echo
echo "[done] haproxy + dataplane API ready."
echo "[done] VIP pool ${VIP_RANGE} will be allocated by Supervisor at Phase 8 enable."
