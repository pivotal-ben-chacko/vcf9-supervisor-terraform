terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
    null    = { source = "hashicorp/null" }
  }
}

variable "physical_host_id" {}
variable "physical_host_name" {}
variable "physical_host_cluster" {}
variable "outer_vm_network_portgroup" {}
variable "outer_dswitch_portgroup" {}
variable "ntp_servers" { type = list(string) }
variable "vcenter_server" {}
variable "vcenter_username" {}
variable "vcenter_password" { sensitive = true }
variable "vcenter_insecure" { type = bool }
variable "datacenter" {}

variable "skip_outer_security_fixes" {
  description = "If true, skip the in-place security-flag reconfigure on outer port groups. Set true when create_outer_networking=true at the root, because the physical-network module already creates port groups with Accept flags."
  type        = bool
  default     = false
}

###############################################################
# Phase 8 / Root Cause #3 — NTP on the physical ESXi host.
# Without this, the host clock drifts and TLS handshakes fail
# silently.
###############################################################

resource "null_resource" "physical_host_ntp" {
  triggers = {
    ntp_servers = join(",", var.ntp_servers)
    host_id     = var.physical_host_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GOVC_URL      = var.vcenter_server
      GOVC_USERNAME = var.vcenter_username
      GOVC_PASSWORD = var.vcenter_password
      GOVC_INSECURE = var.vcenter_insecure ? "true" : "false"
    }
    command = <<-EOT
      set -euo pipefail
      HOST="/${var.datacenter}/host/${var.physical_host_cluster}/${var.physical_host_name}"
      # host.date.change takes single -server. We use the first IP.
      govc host.date.change -host "$HOST" -server "${var.ntp_servers[0]}"
      # host.service does NOT respect -host; pass via GOVC_HOST env.
      GOVC_HOST="$HOST" govc host.service enable ntpd
      GOVC_HOST="$HOST" govc host.service start  ntpd
      # Verify
      govc host.date.info -host "$HOST" | grep -E 'NTP'
    EOT
  }
}

###############################################################
# Phase 1 — security flags on outer "VM Network" (standard vSwitch)
# Required so nested-ESXi vmnic1 → outer port group works for traffic
# whose source MAC is a nested VM's, not vmnic1's.
###############################################################

resource "null_resource" "vm_network_security" {
  count = var.skip_outer_security_fixes ? 0 : 1
  triggers = {
    host_id     = var.physical_host_id
    portgroup   = var.outer_vm_network_portgroup
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GOVC_URL      = var.vcenter_server
      GOVC_USERNAME = var.vcenter_username
      GOVC_PASSWORD = var.vcenter_password
      GOVC_INSECURE = var.vcenter_insecure ? "true" : "false"
    }
    command = <<-EOT
      set -euo pipefail
      HOST="/${var.datacenter}/host/${var.physical_host_cluster}/${var.physical_host_name}"
      govc host.portgroup.change \
        -host "$HOST" \
        -allow-promiscuous=true \
        -forged-transmits=true \
        -mac-changes=true \
        "${var.outer_vm_network_portgroup}"
    EOT
  }
}

###############################################################
# Phase 10 / Root Cause #9 — security flags on the outer DVS port
# group used for the management bridge (lab name: outer-mgmt-net,
# formerly dswitch-vm). Same reason as VM Network — frames from
# nested VMs need to leave via the outer DVS uplink.
###############################################################

resource "null_resource" "dswitch_vm_security" {
  count = var.skip_outer_security_fixes ? 0 : 1
  triggers = {
    portgroup = var.outer_dswitch_portgroup
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      VCENTER_SERVER   = var.vcenter_server
      VCENTER_USERNAME = var.vcenter_username
      VCENTER_PASSWORD = var.vcenter_password
      PG_NAME          = var.outer_dswitch_portgroup
    }
    command = <<-EOT
      set -euo pipefail
      python3 - <<'PY'
import os, ssl, time, sys
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
si = SmartConnect(host=os.environ['VCENTER_SERVER'],
                  user=os.environ['VCENTER_USERNAME'],
                  pwd=os.environ['VCENTER_PASSWORD'],
                  sslContext=ctx)

content = si.RetrieveContent()
pg_name = os.environ['PG_NAME']
pg = None
for dc in content.rootFolder.childEntity:
    if not hasattr(dc, 'networkFolder'): continue
    for n in dc.networkFolder.childEntity:
        if isinstance(n, vim.dvs.DistributedVirtualPortgroup) and n.name == pg_name:
            pg = n
            break

if pg is None:
    print(f"port group {pg_name} not found", file=sys.stderr)
    sys.exit(1)

sec = vim.dvs.VmwareDistributedVirtualSwitch.SecurityPolicy(
    inherited=False,
    allowPromiscuous=vim.BoolPolicy(inherited=False, value=True),
    forgedTransmits=vim.BoolPolicy(inherited=False, value=True),
    macChanges=vim.BoolPolicy(inherited=False, value=True),
)
cfg = vim.dvs.VmwareDistributedVirtualSwitch.VmwarePortConfigPolicy(securityPolicy=sec)
spec = vim.dvs.DistributedVirtualPortgroup.ConfigSpec(
    configVersion=pg.config.configVersion,
    defaultPortConfig=cfg,
)
task = pg.ReconfigureDVPortgroup_Task(spec=spec)
while task.info.state == vim.TaskInfo.State.running:
    time.sleep(1)
print(f"  {pg_name}: reconfigure {task.info.state}")
Disconnect(si)
PY
    EOT
  }
}

output "ntp_configured" {
  value = null_resource.physical_host_ntp.id
}
