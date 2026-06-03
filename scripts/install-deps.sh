#!/usr/bin/env bash
# install-deps.sh — Install the local tools needed by the Supervisor
# Terraform module + preflight script. Idempotent: skips anything that's
# already present, only installs what's missing.
#
# Supports macOS (via Homebrew) and Debian/Ubuntu Linux (via apt).
# Refuses to run as root — it expects to invoke `sudo`/`brew` itself.
#
# Usage:
#   ./scripts/install-deps.sh
#
# Optional env:
#   ASSUME_YES=1   skip the confirmation prompt

set -euo pipefail

ok()    { printf "  \033[32m✓\033[0m %s\n" "$1"; }
miss()  { printf "  \033[33m·\033[0m %s — will install\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1" >&2; }
note()  { printf "    %s\n" "$1"; }
sect()  { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

[[ $EUID -eq 0 ]] && { fail "do not run as root; the script invokes sudo where needed"; exit 1; }

#───────────────────────────────────────────────────────────────────────
# Detect platform
#───────────────────────────────────────────────────────────────────────
UNAME=$(uname -s)
case "$UNAME" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      fail "unsupported platform: $UNAME"; exit 1 ;;
esac

if [[ $PLATFORM == mac ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew not installed. Get it from https://brew.sh first, then re-run."
    exit 1
  fi
fi

#───────────────────────────────────────────────────────────────────────
# Inventory what's needed and what's already there
#───────────────────────────────────────────────────────────────────────
sect "Checking current state"

declare -a TO_INSTALL

check_cli() {
  local cmd=$1 pkg_mac=$2 pkg_linux=$3 label=${4:-$1}
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$label ($(command -v "$cmd"))"
  else
    miss "$label"
    case "$PLATFORM" in
      mac)   TO_INSTALL+=("brew:$pkg_mac") ;;
      linux) TO_INSTALL+=("apt:$pkg_linux") ;;
    esac
  fi
}

check_cli  bash       bash                  bash
check_cli  curl       curl                  curl
check_cli  python3    python                python3
check_cli  ssh        openssh               openssh-client                    ssh
check_cli  jq         jq                    jq
check_cli  openssl    openssl               openssl
check_cli  pandoc     pandoc                pandoc
check_cli  weasyprint weasyprint            weasyprint
check_cli  xorriso    xorriso               xorriso
check_cli  govc       govc                  ""                                govc
# NOTE: hashicorp moved terraform out of brew core in 2023 (BSL license).
# Must tap hashicorp/tap. Handled specially below — DON'T add 'terraform'
# to BREW_PKGS via check_cli.
if command -v terraform >/dev/null 2>&1; then
  ok "terraform ($(command -v terraform))"
else
  miss "terraform"
  case "$PLATFORM" in
    mac)   TO_INSTALL+=("manual:terraform-mac") ;;
    linux) TO_INSTALL+=("manual:terraform-linux") ;;
  esac
fi
check_cli  sshpass    hudochenkov/sshpass/sshpass sshpass                     sshpass

# pyvmomi (Python module, not a CLI)
if python3 -c 'import pyVmomi' 2>/dev/null; then
  ok "pyvmomi (Python module)"
else
  miss "pyvmomi"
  TO_INSTALL+=("pip:pyvmomi")
fi

# expect (used by sv-cp-pwd, sv-wcp-restart, etc.)
check_cli  expect     expect                expect

# pip3 itself is part of python3 on most systems; ensure it works
if ! python3 -m pip --version >/dev/null 2>&1; then
  miss "pip"
  case "$PLATFORM" in
    mac)   TO_INSTALL+=("brew:python") ;;  # comes with brew python
    linux) TO_INSTALL+=("apt:python3-pip") ;;
  esac
fi

# Govc on Linux: install via go install or via curl-from-github
if [[ $PLATFORM == linux ]] && ! command -v govc >/dev/null 2>&1; then
  TO_INSTALL+=("manual:govc-linux")
fi

# Linux: also need build-essential family for some pip wheels
if [[ $PLATFORM == linux ]] && ! dpkg -s build-essential >/dev/null 2>&1; then
  miss "build-essential (compilers for pip wheels)"
  TO_INSTALL+=("apt:build-essential")
fi

#───────────────────────────────────────────────────────────────────────
# Summarize and confirm
#───────────────────────────────────────────────────────────────────────
if [[ ${#TO_INSTALL[@]} -eq 0 ]]; then
  printf "\n\033[32mAll dependencies already installed.\033[0m\n\n"
  exit 0
fi

sect "Will install"
for item in "${TO_INSTALL[@]}"; do
  echo "  $item"
done

if [[ -z "${ASSUME_YES:-}" ]]; then
  echo
  read -r -p "Proceed? [y/N] " ans
  [[ ! "$ans" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 1; }
fi

#───────────────────────────────────────────────────────────────────────
# Install
#───────────────────────────────────────────────────────────────────────
sect "Installing"

BREW_PKGS=()
APT_PKGS=()
PIP_PKGS=()
declare -a MANUAL

for item in "${TO_INSTALL[@]}"; do
  case "$item" in
    brew:*)   BREW_PKGS+=("${item#brew:}") ;;
    apt:*)    APT_PKGS+=("${item#apt:}") ;;
    pip:*)    PIP_PKGS+=("${item#pip:}") ;;
    manual:*) MANUAL+=("${item#manual:}") ;;
  esac
done

if [[ ${#BREW_PKGS[@]} -gt 0 ]]; then
  echo "▶ brew install ${BREW_PKGS[*]}"
  brew install "${BREW_PKGS[@]}"
fi

if [[ ${#APT_PKGS[@]} -gt 0 ]]; then
  echo "▶ sudo apt-get install ${APT_PKGS[*]}"
  sudo apt-get update -y
  sudo apt-get install -y "${APT_PKGS[@]}"
fi

if [[ ${#PIP_PKGS[@]} -gt 0 ]]; then
  echo "▶ pip3 install --break-system-packages ${PIP_PKGS[*]}"
  python3 -m pip install --break-system-packages "${PIP_PKGS[@]}"
fi

for m in "${MANUAL[@]:-}"; do
  case "$m" in
    govc-linux)
      echo "▶ installing govc (latest release from GitHub)"
      VER=$(curl -sSL https://api.github.com/repos/vmware/govmomi/releases/latest \
             | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
      ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=x86_64 ;; aarch64) ARCH=arm64 ;; esac
      curl -fsSL -o /tmp/govc.tar.gz \
        "https://github.com/vmware/govmomi/releases/download/$VER/govc_Linux_$ARCH.tar.gz"
      tar -xzf /tmp/govc.tar.gz -C /tmp/
      sudo install -m 0755 /tmp/govc /usr/local/bin/govc
      rm /tmp/govc.tar.gz /tmp/govc
      ;;

    terraform-mac)
      # Hashicorp moved Terraform out of brew core in Aug 2023 when they
      # switched to the BSL license. Use the official hashicorp/tap.
      echo "▶ tapping hashicorp/tap and installing terraform"
      brew tap hashicorp/tap
      brew install hashicorp/tap/terraform
      ;;

    terraform-linux)
      # Hashicorp's apt repo
      echo "▶ adding HashiCorp apt repo and installing terraform"
      sudo apt-get update -y
      sudo apt-get install -y gnupg software-properties-common
      curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt-get update -y
      sudo apt-get install -y terraform
      ;;
  esac
done

#───────────────────────────────────────────────────────────────────────
# Re-verify
#───────────────────────────────────────────────────────────────────────
sect "Verifying"
ALL_OK=1
for cmd in govc python3 terraform curl ssh sshpass openssl pandoc weasyprint jq expect; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    fail "$cmd still missing"
    ALL_OK=0
  fi
done
if python3 -c 'import pyVmomi' 2>/dev/null; then
  ok "pyvmomi"
else
  fail "pyvmomi still missing"
  ALL_OK=0
fi

if [[ $ALL_OK -eq 1 ]]; then
  printf "\n\033[32mAll dependencies installed.\033[0m\n\n"
  printf "Next steps:\n"
  printf "  1. export GOVC_PASSWORD='...'\n"
  printf "  2. export DPAPI_PASS='...'  (if running preflight against an existing deploy)\n"
  printf "  3. make hard-check        # verifies vCenter + cluster + nested hosts exist\n"
  printf "  4. make apply             # deploys the cluster\n"
  printf "  5. make verify            # post-deploy preflight\n\n"
else
  printf "\n\033[31mSome dependencies failed to install. See errors above.\033[0m\n\n"
  exit 1
fi
