###############################################################
# Stage 2 — configure the Avi Controller for vSphere Supervisor.
#
# Creates the minimum Avi needs to serve VIPs for Supervisor:
#   1. vCenter credentials object
#   2. a vCenter Cloud (so Avi can auto-deploy Service Engines)
#   3. an internal-IPAM profile bound to the VIP network
#   4. a static VIP pool on the VIP network
#   5. an SE Group (SE sizing/placement)
#
# Supervisor itself (via NCP/lbapi) creates the actual VirtualServices and
# Pools later — we only lay the foundation.
#
# ⚠ TWO-PASS / VERSION NOTES
#   - The `avi` provider's resource schemas are version-specific (this
#     targets 31.x). If `terraform plan` flags an unknown field, check the
#     provider docs for your version.
#   - A vCenter Cloud discovers port groups ASYNCHRONOUSLY after it is
#     created. `data.avi_network` lookups for the VIP/mgmt port groups only
#     resolve once discovery completes. If the first apply errors on a
#     network lookup, wait ~1–2 min and re-apply, or pre-create the cloud
#     in the UI. For a one-off lab the UI "Infrastructure > Clouds" wizard
#     is often faster; this file is the automation path.
###############################################################

# The vCenter cloud. Reusing "Default-Cloud" avoids having to set a
# per-object cloud_ref everywhere; Supervisor defaults to it too.
# Avi 31.x takes the vCenter creds INLINE in vcenter_configuration — there
# is no separate avi_cloudconnectoruser object in this schema.
resource "avi_cloud" "vcenter" {
  name         = var.cloud_name
  vtype        = "CLOUD_VCENTER"
  dhcp_enabled = false

  vcenter_configuration {
    vcenter_url        = var.vcenter_server
    username           = var.vcenter_username
    password           = var.vcenter_password
    privilege          = "WRITE_ACCESS"
    datacenter         = var.datacenter
    verify_certificate = false # lab vCenter self-signed cert
  }

  # The cloud rewrites several runtime fields after it connects; don't
  # churn the plan on them.
  lifecycle {
    ignore_changes = [vcenter_configuration]
  }
}

# Discovered VIP port group (resolves after the cloud finishes discovery).
data "avi_network" "vip" {
  name       = var.vip_portgroup
  cloud_ref  = avi_cloud.vcenter.id
  depends_on = [avi_cloud.vcenter]
}

# Configure a static VIP pool on the VIP network and turn off DHCP so Avi
# uses the pool for VIP allocation.
resource "avi_network" "vip" {
  name         = data.avi_network.vip.name
  uuid         = data.avi_network.vip.uuid
  cloud_ref    = avi_cloud.vcenter.id
  dhcp_enabled = false

  configured_subnets {
    prefix {
      ip_addr {
        addr = split("/", var.vip_network_cidr)[0]
        type = "V4"
      }
      mask = tonumber(split("/", var.vip_network_cidr)[1])
    }
    static_ip_ranges {
      type = "VIP"
      range {
        begin {
          addr = var.vip_pool_start
          type = "V4"
        }
        end {
          addr = var.vip_pool_end
          type = "V4"
        }
      }
    }
  }
}

# Avi's built-in IPAM, scoped to the VIP network above.
resource "avi_ipamdnsproviderprofile" "internal" {
  name = "avi-internal-ipam"
  type = "IPAMDNS_TYPE_INTERNAL"

  internal_profile {
    usable_network_refs = [avi_network.vip.id]
  }
}

# Bind the IPAM profile to the cloud so VIP allocation works.
#
# This is deliberately a curl PATCH, NOT a second avi_cloud resource:
# attaching the IPAM to the same cloud whose discovery produced the VIP
# network is a dependency CYCLE in Terraform (cloud → ipam → network →
# cloud_ref → cloud). Avi's own docs do it as a final step for the same
# reason. We break the cycle by patching the cloud after everything else
# exists. Idempotent: re-running just re-sets the same ref.
resource "null_resource" "attach_ipam" {
  triggers = {
    cloud = avi_cloud.vcenter.uuid
    ipam  = avi_ipamdnsproviderprofile.internal.uuid
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AVI_IP       = var.avi_controller_ip
      AVI_USER     = var.avi_username
      AVI_PASSWORD = var.avi_password
      AVI_VERSION  = var.avi_version
      CLOUD_UUID   = avi_cloud.vcenter.uuid
      IPAM_UUID    = avi_ipamdnsproviderprofile.internal.uuid
    }
    command = <<-EOT
      set -euo pipefail
      C="https://$AVI_IP"; J=$(mktemp); trap 'rm -f "$J"' EXIT
      curl -sk -c "$J" -X POST "$C/login" \
        --data-urlencode "username=$AVI_USER" --data-urlencode "password=$AVI_PASSWORD" >/dev/null
      CSRF=$(awk '/csrftoken/ {print $7}' "$J" | tail -1)
      curl -sk -b "$J" -H "X-CSRFToken: $CSRF" -H "Referer: $C" \
        -H "X-Avi-Version: $AVI_VERSION" -H "Content-Type: application/json" \
        -X PATCH "$C/api/cloud/$CLOUD_UUID" \
        -d "{\"replace\":{\"ipam_provider_ref\":\"$C/api/ipamdnsproviderprofile/$IPAM_UUID\"}}" >/dev/null
      echo "Attached IPAM $IPAM_UUID to cloud $CLOUD_UUID"
    EOT
  }
}

# Service Engine group — sizing/placement for the data-plane SE VMs Avi
# spins up. Defaults are fine for a lab; one small SE pair.
resource "avi_serviceenginegroup" "default" {
  name      = var.se_group_name
  cloud_ref = avi_cloud.vcenter.id

  ha_mode             = "HA_MODE_SHARED" # N+M, SEs shared across VServices
  min_scaleout_per_vs = 1
  max_scaleout_per_vs = 2
  vcpus_per_se        = 1
  memory_per_se       = 2048

  lifecycle { ignore_changes = all }
}
