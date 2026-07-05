#!/usr/bin/env bash
###############################################################
# Avi Controller post-deploy bootstrap.
#
# The OVA's `default-password` vApp property already set the admin
# password at first boot, so unlike HAProxy's Dataplane API there is no
# password-creation dance here — we just wait for the API, confirm login,
# and apply baseline system config.
#
# Targets Avi / NSX-ALB 31.x. The REST shapes below are stable across
# recent releases but verify against your version if a step warns.
#
# Required env (set by main.tf's null_resource.bootstrap):
#   AVI_IP, AVI_USER, AVI_PASSWORD, AVI_VERSION
# Optional env:
#   AVI_DNS (csv), AVI_NTP (csv), AVI_BACKUP_PASSPHRASE, AVI_LICENSE_FILE
###############################################################
set -euo pipefail

CTRL="https://${AVI_IP}"
COOKIES="$(mktemp)"
trap 'rm -f "$COOKIES"' EXIT

say() { printf '  %s\n' "$*"; }

###############################################################
# 1. Wait for the API to come up. A fresh controller takes 5–10 min to
#    initialize its services after power-on; poll for up to ~15 min.
###############################################################
say "Waiting for Avi Controller API at ${CTRL} (up to 15 min)..."
up=false
for i in $(seq 1 90); do
  # /api/initial-data is served once the web tier is ready, before login.
  if curl -sk --max-time 5 "${CTRL}/api/initial-data" >/dev/null 2>&1; then
    up=true; break
  fi
  sleep 10
done
if [ "$up" != true ]; then
  echo "ERROR: controller API never responded at ${CTRL}" >&2
  exit 1
fi

###############################################################
# 2. Log in with the admin password the OVA set. This is the hard
#    success criterion — if it fails, the deploy failed.
###############################################################
login() {
  curl -sk -c "$COOKIES" -X POST "${CTRL}/login" \
    --data-urlencode "username=${AVI_USER}" \
    --data-urlencode "password=${AVI_PASSWORD}"
}

say "Authenticating as ${AVI_USER}..."
ok=false
for i in $(seq 1 12); do
  if login | grep -q '"name"'; then ok=true; break; fi
  sleep 10
done
if [ "$ok" != true ]; then
  echo "ERROR: admin login failed — check avi_admin_password / OVA default-password" >&2
  exit 1
fi
say "login OK"

CSRF=$(awk '/csrftoken/ {print $7}' "$COOKIES" | tail -1)

# Authenticated request helper. Avi requires the CSRF token + a Referer
# matching the controller and the X-Avi-Version header.
api() {
  local method="$1" path="$2"; shift 2
  curl -sk -b "$COOKIES" \
    -H "X-CSRFToken: ${CSRF}" \
    -H "Referer: ${CTRL}" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    -H "Content-Type: application/json" \
    -X "$method" "${CTRL}${path}" "$@"
}

###############################################################
# 3. Apply license (optional). Without one the controller runs on its
#    built-in trial / Essentials grant, which is fine for a lab.
###############################################################
if [ -n "${AVI_LICENSE_FILE:-}" ] && [ -f "${AVI_LICENSE_FILE}" ]; then
  say "Applying license from ${AVI_LICENSE_FILE}..."
  if api POST /api/license --data-binary "@${AVI_LICENSE_FILE}" | grep -qiE 'error|invalid'; then
    echo "WARNING: license apply returned an error — continuing on trial grant" >&2
  else
    say "license applied"
  fi
else
  say "no license file provided — running on built-in trial/Essentials grant"
fi

###############################################################
# 4. Baseline system config: DNS + NTP. GET the singleton
#    SystemConfiguration, patch the two sub-objects, PUT it back.
###############################################################
build_json_list() { # csv -> ["a","b"]
  local IFS=','; read -ra parts <<< "$1"
  local out="" p
  for p in "${parts[@]}"; do
    [ -z "$p" ] && continue
    out="${out:+$out,}\"$p\""
  done
  printf '[%s]' "$out"
}

if [ -n "${AVI_DNS:-}" ] || [ -n "${AVI_NTP:-}" ]; then
  say "Configuring DNS/NTP..."
  DNS_JSON=$(build_json_list "${AVI_DNS:-}")
  # DNS servers go in dns_configuration.server_list as addr objects.
  DNS_SERVERS=$(python3 - "$AVI_DNS" <<'PY'
import json,sys
csv=sys.argv[1] if len(sys.argv)>1 else ""
servers=[{"type":"V4","addr":a} for a in csv.split(",") if a]
print(json.dumps(servers))
PY
)
  NTP_SERVERS=$(python3 - "$AVI_NTP" <<'PY'
import json,sys
csv=sys.argv[1] if len(sys.argv)>1 else ""
out=[{"server":{"type":"DNS","addr":a}} for a in csv.split(",") if a]
print(json.dumps(out))
PY
)
  # Merge into the live systemconfiguration object.
  CUR=$(api GET /api/systemconfiguration)
  NEW=$(python3 - <<PY
import json
cur=json.loads('''$CUR''')
cur.setdefault("dns_configuration",{})["server_list"]=json.loads('''$DNS_SERVERS''')
cur.setdefault("ntp_configuration",{})["ntp_servers"]=json.loads('''$NTP_SERVERS''')
print(json.dumps(cur))
PY
)
  if echo "$NEW" | api PUT /api/systemconfiguration --data-binary @- | grep -qiE '"error"'; then
    echo "WARNING: systemconfiguration PUT returned an error" >&2
  else
    say "DNS/NTP set"
  fi
fi

###############################################################
# 5. Backup passphrase (optional but recommended). Patch the default
#    BackupConfiguration singleton.
###############################################################
if [ -n "${AVI_BACKUP_PASSPHRASE:-}" ]; then
  say "Setting backup passphrase..."
  BC=$(api GET /api/backupconfiguration | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["results"][0]["url"] if d.get("results") else "")' 2>/dev/null || true)
  if [ -n "$BC" ]; then
    PAYLOAD=$(python3 - "$AVI_BACKUP_PASSPHRASE" <<'PY'
import json,sys
print(json.dumps({"backup_passphrase": sys.argv[1]}))
PY
)
    # PATCH merges into the existing object.
    if echo "{\"replace\": $(echo "$PAYLOAD")}" | api PATCH "/api/backupconfiguration/$(basename "$BC")" --data-binary @- | grep -qiE '"error"'; then
      echo "WARNING: backup passphrase PATCH returned an error" >&2
    else
      say "backup passphrase set"
    fi
  fi
fi

say "Controller bootstrap complete."
