#!/usr/bin/env bash
# preflight-check.sh — Verifies the environment is ready for `terraform apply`
# of the Supervisor module. Run this BEFORE apply.
#
# Catches: clock skew, missing depot, missing port groups, hosts not in cluster,
# HAProxy not ready, etc. — i.e., all the conditions that would make the
# `null_resource.supervisor_enable` apply fail after 20+ wasted minutes.
#
# Exits 0 if everything's ready, non-zero with a clear message otherwise.
#
# Usage:
#   ./scripts/preflight-check.sh
#
# Optional env overrides (sourced from sv-env or terraform.tfvars equivalents):
#   GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_INSECURE
#   HAPROXY_IP, DPAPI_PORT, DPAPI_USER, DPAPI_PASS
#   NESTED_HOSTS  (space-separated)

set -euo pipefail

#───────────────────────────────────────────────────────────────────────
# Defaults — override via env or sv-env
#───────────────────────────────────────────────────────────────────────
: "${GOVC_URL:=vcenter.skynetsystems.io}"
: "${GOVC_USERNAME:=administrator@vsphere.local}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD or source sv-env}"
: "${GOVC_INSECURE:=true}"

: "${PHYSICAL_HOST:=192.168.2.75}"
: "${PHYSICAL_HOST_CLUSTER:=Cluster}"
: "${SUPERVISOR_CLUSTER:=Supervisor-Cluster}"
: "${DATACENTER:=Datacenter}"
: "${NESTED_HOSTS:=192.168.3.241 192.168.3.242 192.168.3.243}"

: "${HAPROXY_IP:=192.168.3.245}"
: "${DPAPI_PORT:=5556}"
: "${DPAPI_USER:=admin}"
: "${DPAPI_PASS:?Set DPAPI_PASS (HAProxy dataplane basic-auth password)}"

: "${VIP_RANGE_START:=192.168.3.249}"
: "${VIP_RANGE_END:=192.168.3.254}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE

FAIL=0
WARN=0

ok()    { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; WARN=$((WARN+1)); }
note()  { printf "    %s\n" "$1"; }

section() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

#───────────────────────────────────────────────────────────────────────
section "Tools on this host"

# Detect platform once so we can suggest the right install command
case "$(uname -s)" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      PLATFORM=other ;;
esac

# Helper: check a CLI tool. If missing, print the platform-specific install hint.
check_tool() {
  local cmd=$1 mac_cmd=$2 linux_cmd=$3
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd installed"
  else
    case "$PLATFORM" in
      mac)    fail "$cmd missing — install with:   $mac_cmd" ;;
      linux)  fail "$cmd missing — install with:   $linux_cmd" ;;
      other)  fail "$cmd missing (see your platform's package manager)" ;;
    esac
  fi
}

check_tool govc       "brew install govc"                              "see https://github.com/vmware/govmomi/releases"
check_tool python3    "brew install python"                            "sudo apt-get install -y python3 python3-pip"
check_tool curl       "brew install curl"                              "sudo apt-get install -y curl"
check_tool ssh        "(already in macOS)"                             "sudo apt-get install -y openssh-client"
check_tool sshpass    "brew install hudochenkov/sshpass/sshpass"       "sudo apt-get install -y sshpass"
check_tool openssl    "brew install openssl"                           "sudo apt-get install -y openssl"
check_tool jq         "brew install jq"                                "sudo apt-get install -y jq"
check_tool expect     "brew install expect"                            "sudo apt-get install -y expect"
check_tool terraform  "brew tap hashicorp/tap && brew install hashicorp/tap/terraform"  "see https://developer.hashicorp.com/terraform/install"
check_tool xorriso    "brew install xorriso"                                            "sudo apt-get install -y xorriso"

if python3 -c 'import pyVmomi' 2>/dev/null; then
  ok "pyvmomi (Python module) importable"
else
  fail "pyvmomi missing — install with:   pip3 install pyvmomi --break-system-packages"
fi

# Catch-all hint if multiple tools are missing
if [ "$FAIL" -gt 0 ]; then
  note "Or just run:  ./terraform/scripts/install-deps.sh  to install everything at once."
fi

#───────────────────────────────────────────────────────────────────────
section "vCenter reachability"
if govc about >/dev/null 2>&1; then
  V=$(govc about | awk -F: '/^Version/{print $2}' | xargs)
  ok "vCenter reachable (version $V)"
else
  fail "vCenter unreachable — check GOVC_URL/credentials"
  exit 1
fi

#───────────────────────────────────────────────────────────────────────
section "Clock alignment (critical — Phase 8 / Root Cause #3)"
LOCAL_UTC=$(date -u +%s)
HOST_UTC=$(govc host.date.info -host "/$DATACENTER/host/$PHYSICAL_HOST_CLUSTER/$PHYSICAL_HOST" 2>/dev/null \
  | awk '/Current date and time/{$1=$2=$3=$4=""; print $0}' | xargs -I{} date -u -j -f '%a %b %d %H:%M:%S UTC %Y' '{}' +%s 2>/dev/null || echo 0)
NTP_ENABLED=$(govc host.date.info -host "/$DATACENTER/host/$PHYSICAL_HOST_CLUSTER/$PHYSICAL_HOST" 2>/dev/null \
  | awk -F: '/NTP client status/{print $2}' | xargs)

if [ "$NTP_ENABLED" = "Enabled" ]; then
  ok "physical host NTP enabled"
else
  fail "physical host NTP NOT enabled — without NTP, vCSA clock drifts and TLS fails silently"
fi

if [ "$HOST_UTC" -ne 0 ]; then
  SKEW=$((LOCAL_UTC - HOST_UTC))
  ABS=${SKEW#-}
  if [ "$ABS" -le 30 ]; then
    ok "physical host clock within 30s of local UTC (skew=${SKEW}s)"
  elif [ "$ABS" -le 300 ]; then
    warn "physical host clock skew=${SKEW}s — within minutes, but check NTP is actually syncing"
  else
    fail "physical host clock skew=${SKEW}s — Supervisor enable will fail silently. Fix NTP first."
  fi
fi

#───────────────────────────────────────────────────────────────────────
section "Supervisor cluster + nested hosts"
if govc cluster.usage -dc "$DATACENTER" "$SUPERVISOR_CLUSTER" >/dev/null 2>&1 \
   || govc find "/$DATACENTER/host/$SUPERVISOR_CLUSTER" >/dev/null 2>&1; then
  ok "cluster $SUPERVISOR_CLUSTER exists"
else
  fail "cluster $SUPERVISOR_CLUSTER not found"
fi

for h in $NESTED_HOSTS; do
  cs=$(govc host.info -host "/$DATACENTER/host/$SUPERVISOR_CLUSTER/$h" -json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['hostSystems'][0]['runtime']['connectionState'])" 2>/dev/null || echo "missing")
  if [ "$cs" = "connected" ]; then
    ok "$h connected"
  else
    fail "$h connection state = $cs"
  fi

  # Verify vmnic2 present (Phase 9 prerequisite)
  pnics=$(govc host.info -host "/$DATACENTER/host/$SUPERVISOR_CLUSTER/$h" -json 2>/dev/null \
    | python3 -c "import json,sys; print(' '.join(n['device'] for n in json.load(sys.stdin)['hostSystems'][0]['config']['network']['pnic']))" 2>/dev/null || echo "")
  if echo "$pnics" | grep -q vmnic2; then
    ok "  $h has vmnic2 (Phase 9 setup done)"
  else
    fail "  $h missing vmnic2 — add via Phase 9 commands before applying"
  fi
done

#───────────────────────────────────────────────────────────────────────
section "Outer port-group security (Phases 1, 10)"
SEC=$(govc host.portgroup.info -host "/$DATACENTER/host/$PHYSICAL_HOST_CLUSTER/$PHYSICAL_HOST" 2>/dev/null \
  | awk '/^Name:.*VM Network$/{found=1; next} found && /Allow promiscuous mode/{print $NF; exit}')
if [ "$SEC" = "Yes" ]; then
  ok "VM Network (vSwitch1) promiscuous = Yes"
else
  fail "VM Network promiscuous=$SEC — should be Yes"
fi

# outer-mgmt-net (DVS port group on DSwitch — formerly named "dswitch-vm") via pyvmomi
python3 - <<PY
import os, ssl, sys
from pyVim.connect import SmartConnect
from pyVmomi import vim
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
si = SmartConnect(host=os.environ['GOVC_URL'], user=os.environ['GOVC_USERNAME'],
                  pwd=os.environ['GOVC_PASSWORD'], sslContext=ctx)
ok_all = True
for dc in si.RetrieveContent().rootFolder.childEntity:
    for n in dc.networkFolder.childEntity:
        if isinstance(n, vim.dvs.DistributedVirtualPortgroup) and n.name == 'outer-mgmt-net':
            s = n.config.defaultPortConfig.securityPolicy
            for flag, val in [('Promiscuous', s.allowPromiscuous.value),
                              ('Forged TX',   s.forgedTransmits.value),
                              ('MAC Changes', s.macChanges.value)]:
                marker = "\033[32m✓\033[0m" if val else "\033[31m✗\033[0m"
                print(f"  {marker} outer-mgmt-net {flag}: {val}")
                if not val: ok_all = False
            sys.exit(0 if ok_all else 1)
print("\033[31m✗\033[0m outer-mgmt-net port group not found", file=sys.stderr)
sys.exit(1)
PY
[ $? -ne 0 ] && fail "outer-mgmt-net security policy not fully Accept — fix per Phase 10"

#───────────────────────────────────────────────────────────────────────
section "HAProxy + Dataplane API"
if curl -sk --max-time 4 -u "$DPAPI_USER:$DPAPI_PASS" \
     "https://$HAPROXY_IP:$DPAPI_PORT/v2/info" 2>/dev/null | grep -q '"version"'; then
  V=$(curl -sk -u "$DPAPI_USER:$DPAPI_PASS" "https://$HAPROXY_IP:$DPAPI_PORT/v2/info" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['api']['version'])")
  ok "Dataplane API responding ($V)"

  # Try a manual transaction commit to catch Phase 10 regressions
  VER=$(curl -sk -u "$DPAPI_USER:$DPAPI_PASS" "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/configuration/version")
  TX=$(curl -sk -u "$DPAPI_USER:$DPAPI_PASS" -X POST "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/transactions?version=$VER")
  TX_ID=$(echo "$TX" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  if [ -n "$TX_ID" ]; then
    curl -sk -u "$DPAPI_USER:$DPAPI_PASS" -X POST -H 'Content-Type: application/json' \
      "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/configuration/backends?transaction_id=$TX_ID" \
      -d '{"name":"preflight_test","mode":"tcp","balance":{"algorithm":"roundrobin"}}' >/dev/null
    RES=$(curl -sk -u "$DPAPI_USER:$DPAPI_PASS" -X PUT \
      "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/transactions/$TX_ID")
    if echo "$RES" | grep -q '"status":"success"'; then
      ok "transaction commit works"
      NV=$(curl -sk -u "$DPAPI_USER:$DPAPI_PASS" "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/configuration/version")
      curl -sk -u "$DPAPI_USER:$DPAPI_PASS" -X DELETE \
        "https://$HAPROXY_IP:$DPAPI_PORT/v2/services/haproxy/configuration/backends/preflight_test?version=$NV" >/dev/null
    else
      fail "transaction commit failed — likely Phase 10 (systemd flag)"
      note "$RES"
    fi
  else
    fail "couldn't open a transaction (auth or schema issue)"
  fi
else
  fail "Dataplane API not responding at https://$HAPROXY_IP:$DPAPI_PORT — check the VM, network, and creds"
fi

#───────────────────────────────────────────────────────────────────────
section "VIP reachability (Phase 11)"
for ip in $(seq -f "$(echo $VIP_RANGE_START | sed 's/\.[0-9]*$/.%g/')" \
                $(echo $VIP_RANGE_START | awk -F. '{print $4}') \
                $(echo $VIP_RANGE_END   | awk -F. '{print $4}')); do
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    ok "$ip reachable"
  else
    fail "$ip unreachable — likely Phase 11 (ip addr add … /32 dev ens192)"
  fi
done

#───────────────────────────────────────────────────────────────────────
section "NFS storage"
if govc datastore.info -dc "$DATACENTER" nfs-shared >/dev/null 2>&1; then
  ok "datastore 'nfs-shared' visible from vCenter"
else
  fail "datastore 'nfs-shared' not visible — Phase 6 mount step not done?"
fi

#───────────────────────────────────────────────────────────────────────
section "vLCM depot + cluster image (Phases 1, 2)"
# This is harder to check via govc; just warn the user to verify in the UI.
warn "manually verify vSphere Client → $SUPERVISOR_CLUSTER → Updates → Image shows 'All hosts compliant' with a 9.x base image"

#───────────────────────────────────────────────────────────────────────
section "Summary"
if [ $FAIL -eq 0 ]; then
  printf "\033[32mAll preflight checks passed.\033[0m"
  [ $WARN -gt 0 ] && printf " (%d warnings — review above.)" "$WARN"
  printf "\n\nReady to:  cd terraform/examples/lab && terraform apply\n\n"
  exit 0
else
  printf "\n\033[31m%d preflight check(s) failed.\033[0m\n" "$FAIL"
  printf "Fix the issues above before running 'terraform apply'.\n"
  printf "See SUPERVISOR-INSTALL.md for phase-by-phase remediation.\n\n"
  exit 1
fi
