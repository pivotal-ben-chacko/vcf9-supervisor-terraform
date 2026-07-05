# Makefile for the Supervisor Terraform module.
#
# Run from the repo root:
#   make help
#
# (Or from anywhere with `make -C /path/to/repo <target>`)
#
# Paths in this Makefile are relative to the repo root:
#   examples/lab/        — the lab consumer example (where terraform runs)
#   scripts/             — install-deps.sh, preflight-check.sh, json-to-tfvars.py,
#                          and the operational helpers (sv-state, sv-clocks, ...)
#   modules/             — the modules themselves
#   SUPERVISOR-*.md      — docs

TF_DIR      := examples/lab
SCRIPTS_DIR := scripts
SV_DIR      := scripts
REPO_ROOT   := .
MD          := $(REPO_ROOT)/SUPERVISOR-SUMMARY.md
PDF         := $(REPO_ROOT)/SUPERVISOR-SUMMARY.pdf

# Default target — show what's available
.DEFAULT_GOAL := help

help:
	@printf "Usage (run from the repo root):  make <target>\n\n"
	@printf "Config sync (run after editing wcp-config-Skynet.json):\n"
	@printf "  sync-config   regenerate examples/lab/config.auto.tfvars + haproxy-dpapi.crt\n\n"
	@printf "Workflow (first-time deploy):\n"
	@printf "  install-deps  install local CLI tools (govc, terraform, pyvmomi, …) — idempotent\n"
	@printf "  hard-check    verify the static prereqs (vCenter up, cluster + hosts exist)\n"
	@printf "  init          terraform init\n"
	@printf "  validate      terraform validate (catches HCL syntax errors)\n"
	@printf "  fmt           terraform fmt -recursive\n"
	@printf "  plan          terraform plan\n"
	@printf "  apply         terraform apply  (no preflight — Terraform creates things preflight expects)\n"
	@printf "  verify        run preflight checks AFTER apply to confirm the cluster is healthy\n\n"
	@printf "Workflow (re-apply / drift check on existing deploy):\n"
	@printf "  preflight     verify the running environment still passes all checks\n"
	@printf "  plan          see drift\n"
	@printf "  apply         reconcile\n\n"
	@printf "Teardown:\n"
	@printf "  destroy       terraform destroy (disables Supervisor cleanly via destroy provisioners)\n\n"
	@printf "Ops (calls scripts/sv-*):\n"
	@printf "  state         sv-state — quick health snapshot\n"
	@printf "  clocks        sv-clocks — verify clock alignment (read-only diagnostic)\n"
	@printf "  fix-ntp       sv-fix-ntp — *fix* clock skew (enable host NTP + sync vCSA)\n"
	@printf "  haproxy-cfg   sv-haproxy-config — dump HAProxy backends/frontends\n"
	@printf "  cp-pwd        sv-cp-pwd — fetch current CP VM root password\n"
	@printf "  wcp-restart   sv-wcp-restart — hard restart wcp\n\n"
	@printf "Docs (in repo root):\n"
	@printf "  pdf           rebuild SUPERVISOR-SUMMARY.pdf\n\n"

# Translate wcp-config-Skynet.json into Terraform inputs + HAProxy cert.
# Run after every edit to the source JSON.
sync-config:
	@python3 $(SCRIPTS_DIR)/json-to-tfvars.py \
		wcp-config-Skynet.json \
		$(TF_DIR)/config.auto.tfvars \
		haproxy-dpapi.crt

# Install local CLI tools (idempotent). Detects macOS vs Linux and uses
# brew or apt accordingly. Set ASSUME_YES=1 to skip the prompt.
install-deps:
	@bash $(SCRIPTS_DIR)/install-deps.sh

# Static (hard) prereq check — verifies things that must exist BEFORE
# terraform apply. Does NOT check HAProxy/NFS/etc. because Terraform
# is about to create those.
hard-check:
	@bash -c ' \
		set -e; \
		: "$${GOVC_PASSWORD:?Set GOVC_PASSWORD (vSphere SSO password) before running}"; \
		export GOVC_URL=$${GOVC_URL:-vcenter.skynetsystems.io}; \
		export GOVC_USERNAME=$${GOVC_USERNAME:-administrator@vsphere.local}; \
		export GOVC_INSECURE=$${GOVC_INSECURE:-true}; \
		echo "Checking tools..."; \
		for t in govc python3 terraform curl; do command -v $$t >/dev/null && echo "  ✓ $$t" || { echo "  ✗ $$t missing"; exit 1; }; done; \
		python3 -c "import pyVmomi" 2>/dev/null && echo "  ✓ pyvmomi" || { echo "  ✗ pyvmomi missing (pip3 install pyvmomi --break-system-packages)"; exit 1; }; \
		echo "Checking vCenter..."; \
		govc about >/dev/null && echo "  ✓ vCenter reachable" || { echo "  ✗ vCenter unreachable — check GOVC_URL/credentials"; exit 1; }; \
		echo "Checking inventory..."; \
		govc find /Datacenter/host/Cluster/192.168.2.75 >/dev/null 2>&1 && echo "  ✓ physical host 192.168.2.75" || echo "  ✗ physical host missing"; \
		govc find /Datacenter/host/Supervisor-Cluster >/dev/null 2>&1 && echo "  ✓ Supervisor-Cluster exists" || echo "  ✗ Supervisor-Cluster missing"; \
		for h in 192.168.3.241 192.168.3.242 192.168.3.243; do \
		  govc find /Datacenter/host/Supervisor-Cluster/$$h >/dev/null 2>&1 && echo "  ✓ nested host $$h joined" || echo "  ✗ nested host $$h not joined"; \
		done; \
		echo "Hard prereqs OK. You can now: make apply"; \
	'

# Full preflight (assumes infrastructure already deployed) — call AFTER
# terraform apply, or before a re-apply to detect drift.
preflight verify:
	@bash $(SCRIPTS_DIR)/preflight-check.sh

init:
	@cd $(TF_DIR) && terraform init

fmt:
	@terraform fmt -recursive .

validate:
	@cd $(TF_DIR) && terraform init -backend=false && terraform validate

plan:
	@cd $(TF_DIR) && terraform plan

apply:
	@cd $(TF_DIR) && terraform apply

destroy:
	@cd $(TF_DIR) && terraform destroy

state:
	@bash $(SV_DIR)/sv-state

clocks:
	@bash $(SV_DIR)/sv-clocks

fix-ntp:
	@bash $(SV_DIR)/sv-fix-ntp

haproxy-cfg:
	@bash $(SV_DIR)/sv-haproxy-config

cp-pwd:
	@bash $(SV_DIR)/sv-cp-pwd

wcp-restart:
	@bash $(SV_DIR)/sv-wcp-restart

pdf:
	@bash $(REPO_ROOT)/build-pdf.sh $(MD) $(PDF)

.PHONY: help sync-config install-deps hard-check preflight verify init fmt validate plan apply destroy state clocks fix-ntp haproxy-cfg cp-pwd wcp-restart pdf
