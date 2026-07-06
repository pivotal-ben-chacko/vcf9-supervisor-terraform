terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
    null    = { source = "hashicorp/null" }
    local   = { source = "hashicorp/local" }
  }
}

variable "datacenter_id" {}
variable "cluster_id" {}
variable "cluster_name" {}
variable "datacenter" {}

variable "management_network" {}        # port group MoRef (sup-mgmt)
variable "management_starting_ip" {}
variable "management_subnet" {}
variable "management_gateway" {}
variable "management_dns" { type = list(string) }

variable "workload_network" {}          # port group MoRef (sup-workload)
variable "workload_ip_range" {}         # e.g. "192.168.3.201-192.168.3.230"
variable "workload_subnet" {}
variable "workload_gateway" {}
variable "workload_dns" { type = list(string) }

variable "k8s_service_cidr" {}
variable "k8s_pod_cidr" {}

variable "haproxy_endpoint" {}          # "192.168.3.245:5556"
variable "haproxy_user" {}
variable "haproxy_password" { sensitive = true }
variable "haproxy_cert_path" {}         # local path to dpapi.crt

variable "vip_pool" {}                  # CIDR "192.168.3.248/29"

variable "control_plane_size" {}        # TINY / SMALL / MEDIUM / LARGE
variable "control_plane_ha" { type = bool }

variable "vcenter_server" {}
variable "vcenter_username" {}
variable "vcenter_password" { sensitive = true }
variable "vcenter_insecure" { type = bool }
# Optional: pin vcenter_server's IP for curl in local-exec scripts. Useful when
# the operator's resolver hijacks the hostname to a public address (DoH, iCloud
# Private Relay, etc) and curl ends up hitting the wrong endpoint. When set,
# curl --resolve ${vcenter_server}:443:${vcenter_ip} forces the right path.
variable "vcenter_ip" {
  type    = string
  default = ""
}

variable "storage_policy_name" {
  description = "Name of the tag-based storage policy used by Supervisor for CP, ephemeral, and image storage. Matches wcp-config-Skynet.json:tkgsStoragePolicySpec.*."
  type        = string
  default     = "supervisor-storage"
}

variable "storage_tag_category_name" {
  description = "Name of the tag category the storage-policy tag belongs to. Pass the category resource's .name attribute so the policy depends on it existing."
  type        = string
  default     = "supervisor"
}

variable "storage_tag_name" {
  description = "Name of the tag that drives the storage policy. The tag itself is created in the root module and attached to nfs-shared natively by the nfs module."
  type        = string
  default     = "supervisor-storage"
}

###############################################################
# Tag-based storage policy targeting nfs-shared
# (Phase 8.0b in the runbook)
#
# The tag category + tag live in the root module, and the nfs module
# attaches the tag to the nfs-shared datastore via its `tags`
# attribute. This module only builds the policy from the names.
###############################################################

resource "vsphere_vm_storage_policy" "supervisor_storage" {
  name        = var.storage_policy_name
  description = "Tag-based policy that resolves to nfs-shared (for Supervisor CP/ephemeral/image storage)"

  tag_rules {
    tag_category                 = var.storage_tag_category_name
    tags                         = [var.storage_tag_name]
    include_datastores_with_tags = true
  }
}

###############################################################
# Read the dataplaneapi cert content for inclusion in the enable spec
###############################################################

data "local_file" "haproxy_cert" {
  filename = var.haproxy_cert_path
}

###############################################################
# Build the namespace.cluster.enable JSON spec
###############################################################

locals {
  # Address count = how many IPs the wizard reserves in the management
  # subnet starting at management_starting_ip. vSphere requires minimum
  # 5 even for HA-off (CP + floating + upgrade overhead). Bumping HA on
  # to a larger buffer would be future tuning.
  mgmt_address_count = 5

  # Parse workload IP range "x.x.x.A-x.x.x.B" into start + count.
  workload_range_parts = split("-", var.workload_ip_range)
  workload_range_start = local.workload_range_parts[0]
  workload_range_end   = local.workload_range_parts[1]
  workload_range_count = tonumber(split(".", local.workload_range_end)[3]) - tonumber(split(".", local.workload_range_start)[3]) + 1

  # Parse VIP pool CIDR — just need start + count of usable
  vip_pool_parts = split("/", var.vip_pool)
  vip_pool_net   = local.vip_pool_parts[0]
  vip_pool_prefix = tonumber(local.vip_pool_parts[1])
  vip_pool_count = pow(2, 32 - local.vip_pool_prefix) - 2

  enable_spec = jsonencode({
    spec = {
      size_hint        = var.control_plane_size
      network_provider = "VSPHERE_NETWORK"  # HAProxy + vDS path; NSXT_CONTAINER_PLUGIN is the alternative

      master_management_network = {
        network = var.management_network
        mode    = "STATICRANGE"
        address_range = {
          starting_address = var.management_starting_ip
          subnet_mask      = "255.255.255.0"
          address_count    = local.mgmt_address_count
          gateway          = var.management_gateway
        }
      }

      master_DNS         = var.management_dns
      master_NTP_servers = ["pool.ntp.org"]
      master_DNS_search_domains = []

      worker_DNS = var.workload_dns

      workload_networks_spec = {
        supervisor_primary_workload_network = {
          network = "primary-workload"
          network_provider = "VSPHERE_NETWORK"
          vsphere_network = {
            portgroup       = var.workload_network
            address_ranges  = [
              {
                address = local.workload_range_start
                count   = local.workload_range_count
              }
            ]
            gateway       = var.workload_gateway
            subnet_mask   = "255.255.255.0"
          }
        }
      }

      service_cidr = {
        address = split("/", var.k8s_service_cidr)[0]
        prefix  = tonumber(split("/", var.k8s_service_cidr)[1])
      }

      # Verified from vCenter's own metamodel:
      # com.vmware.vcenter.namespace_management.clusters.enable_spec.load_balancer_config_spec
      # is an OPTIONAL<com.vmware.vcenter.namespace_management.load_balancers.config_spec>
      # (single struct, not wrapped, not a list). Only valid when
      # network_provider = "VSPHERE_NETWORK".
      load_balancer_config_spec = {
        id       = "haproxy-lab"
        provider = "HA_PROXY"
        # First usable IP of the pool, derived from var.vip_pool. This was
        # previously hardcoded to lab 1's "192.168.3.249", which silently
        # poisoned any environment with a different VIP pool: the Supervisor
        # allocated its API endpoint (and Pinniped callback) from a range
        # HAProxy never claimed. cidrhost(pool, 1) yields the same string
        # for lab 1, so its enable-spec hash is unchanged.
        address_ranges = [
          { address = cidrhost(var.vip_pool, 1), count = local.vip_pool_count }
        ]
        ha_proxy_config_create_spec = {
          servers = [
            { host = split(":", var.haproxy_endpoint)[0], port = tonumber(split(":", var.haproxy_endpoint)[1]) }
          ]
          username                    = var.haproxy_user
          password                    = var.haproxy_password
          certificate_authority_chain = data.local_file.haproxy_cert.content
        }
      }

      ephemeral_storage_policy = vsphere_vm_storage_policy.supervisor_storage.id
      master_storage_policy    = vsphere_vm_storage_policy.supervisor_storage.id
      image_storage = {
        storage_policy = vsphere_vm_storage_policy.supervisor_storage.id
      }

      # default_kubernetes_service_content_library: omitted because vSphere 9
      # rejects an empty string as "Content Library UUID , error: not found".
      # When you want TKG workload clusters later, create a subscribed library
      # (e.g. via the content-library module) and set this to its UUID.
    }
  })
}

# path.cwd (the consuming example's directory) rather than path.module:
# each environment keeps its own spec + api-endpoint file. With
# path.module, two environments sharing this module would overwrite
# each other's generated files.
resource "local_file" "enable_spec" {
  filename = "${path.cwd}/generated/enable-spec.json"
  content  = local.enable_spec
  file_permission = "0600"
}

###############################################################
# Call govc namespace.cluster.enable with the generated spec.
#
# NOTE: the namespace.cluster.enable JSON schema is large and evolves
# between vSphere releases. The spec above is a best-effort match for
# vSphere 9.0.2. If govc rejects it with a 4xx, dump the result with
# `govc namespace.cluster.enable -h` and check the current schema.
###############################################################

resource "null_resource" "supervisor_enable" {
  triggers = {
    spec_hash     = sha256(local.enable_spec)
    cluster       = var.cluster_name
    cluster_id    = var.cluster_id
    vc_ip         = var.vcenter_ip
    # Captured for use in the destroy-time provisioner (self.triggers.*)
    # because var.* aren't available on destroy:
    vc_url        = var.vcenter_server
    vc_username   = var.vcenter_username
    vc_password   = var.vcenter_password
    vc_insecure   = var.vcenter_insecure ? "true" : "false"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      VC_URL      = var.vcenter_server
      VC_IP       = var.vcenter_ip
      VC_USERNAME = var.vcenter_username
      VC_PASSWORD = var.vcenter_password
      SPEC_FILE   = local_file.enable_spec.filename
      CLUSTER_ID  = var.cluster_id
      CLUSTER     = var.cluster_name
    }
    # Use the vCenter REST API directly. govc 0.54+'s namespace.cluster.enable
    # only supports NSX-T (-network-provider=NSXT_CONTAINER_PLUGIN); there's no
    # CLI flag for HAProxy. The REST API accepts the full spec including HAProxy
    # load_balancer_config_spec, so we hit it via curl.
    command = <<-EOT
      # -eo (not -euo): with -u, bash 3.2 (macOS default) treats an empty
      # array expansion as "unbound variable" and bails. We use such arrays
      # for the optional --resolve flag, so -u doesn't fit here.
      set -eo pipefail
      API="https://$VC_URL/api"
      AUTH="$VC_USERNAME:$VC_PASSWORD"
      # If vcenter_ip is set, pin DNS via --resolve so DoH/Private-Relay/etc
      # can't hijack the hostname. (Same pattern used by the destroy provisioner.)
      RESOLVE=()
      [ -n "$VC_IP" ] && RESOLVE=(--resolve "$VC_URL:443:$VC_IP")

      # Get session token (POST /api/session with basic auth → returns "<token>" string)
      SESSION=$(curl "$${RESOLVE[@]}" -sk -u "$AUTH" -X POST -H 'Content-Type: application/json' "$API/session" | tr -d '"')
      # A K8s 401 body (from a hijacked hostname → Supervisor) parses as a JSON
      # object starting with "{". A real session token is a hex string. Refuse to
      # proceed on non-hex token output.
      if ! [[ "$SESSION" =~ ^[a-f0-9]+$ ]]; then
        echo "Got non-token response from $API/session (likely DNS/proxy hijack):"
        echo "  $SESSION" | head -c 200
        echo ""
        echo "Set var.vcenter_ip to the actual vCenter IP to bypass."
        exit 1
      fi
      HDR="vmware-api-session-id: $SESSION"

      # Check current status (404 = not yet enabled)
      STATUS=$(curl "$${RESOLVE[@]}" -sk -H "$HDR" "$API/vcenter/namespace-management/clusters/$CLUSTER_ID" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('config_status','NONE'))" 2>/dev/null || echo "NONE")
      echo "Current status: $STATUS"

      if [[ "$STATUS" == "RUNNING" || "$STATUS" == "CONFIGURING" ]]; then
        echo "Supervisor already $STATUS; not re-enabling. (taint module.supervisor.null_resource.supervisor_enable to force.)"
        exit 0
      fi

      # The /api endpoint takes the spec object directly (no {"spec": ...} wrapper).
      python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['spec']))" < "$SPEC_FILE" > /tmp/enable-spec.json

      echo "Submitting supervisor enable for $CLUSTER ($CLUSTER_ID) via REST..."
      RESP=$(curl "$${RESOLVE[@]}" -sk -w "HTTP_CODE:%%{http_code}" -H "$HDR" -H 'Content-Type: application/json' -X POST \
        -d @/tmp/enable-spec.json \
        "$API/vcenter/namespace-management/clusters/$CLUSTER_ID?action=enable")
      CODE=$(echo "$RESP" | grep -oE 'HTTP_CODE:[0-9]+' | cut -d: -f2)
      BODY=$(echo "$RESP" | sed 's/HTTP_CODE:[0-9]*$//')
      echo "Response code: $CODE"
      [ -n "$BODY" ] && echo "Body: $BODY"
      if [[ "$CODE" != "204" && "$CODE" != "200" ]]; then
        echo "Enable submission failed"
        exit 1
      fi

      echo "Polling status (this takes 15-30 min for HA-off, longer for HA on)..."
      mkdir -p "${path.cwd}/generated"
      # Tolerate transient ERROR flickers: vSphere's reconcile loop can
      # briefly mark the cluster ERROR while replaying a content-library
      # update / API call retry, then recover to CONFIGURING and eventually
      # RUNNING. Only bail if we see CONSECUTIVE ERROR states for a while.
      ERROR_RUN=0
      for i in $(seq 1 90); do
        RESP=$(curl "$${RESOLVE[@]}" -sk -H "$HDR" "$API/vcenter/namespace-management/clusters/$CLUSTER_ID" 2>/dev/null)
        STATUS=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('config_status','NONE'))" 2>/dev/null || echo "NONE")
        printf "  [%s] %s\n" "$(date +%T)" "$STATUS"
        if [[ "$STATUS" == "RUNNING" ]]; then
          echo "Supervisor RUNNING - proceeding."
          # Capture the live API VIP (vSphere/HAProxy pick it from the pool;
          # it can differ across re-enables). Downstream outputs read this file.
          echo "$RESP" \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('api_server_cluster_endpoint',''))" \
            > "${path.cwd}/generated/api-endpoint.txt"
          exit 0
        fi
        if [[ "$STATUS" == "ERROR" ]]; then
          ERROR_RUN=$((ERROR_RUN + 1))
          if [ "$ERROR_RUN" -ge 5 ]; then
            echo "Supervisor stuck in ERROR for 5 consecutive checks (~2.5 min)."
            echo "  Check vSphere Client > Workload Management > Configuration > Status"
            echo "  Common causes: clock skew (Phase 8), security flags (Phase 10), VIPs not claimed (Phase 11)"
            exit 1
          fi
        else
          ERROR_RUN=0
        fi
        sleep 30
      done
      echo "Timed out waiting for Supervisor RUNNING."
      exit 1
    EOT
  }

  # On `terraform destroy`, disable Supervisor cleanly via REST API.
  # Without this, destroy would orphan a running Supervisor and the
  # subsequent storage_policy delete would fail with
  # "still associated with N entities" (the 3 Control Plane VMs).
  #
  # Earlier version used `govc namespace.cluster.ls/disable` but those
  # commands either don't exist or behave differently in govc 0.54
  # (namespace.cluster.enable is NSX-T only; the .ls JSON output is
  # absent/changed). REST is what we use for enable, and the same
  # cluster moref + session-token pattern works here.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      VC_URL      = self.triggers.vc_url
      VC_IP       = self.triggers.vc_ip
      VC_USERNAME = self.triggers.vc_username
      VC_PASSWORD = self.triggers.vc_password
      CLUSTER_ID  = self.triggers.cluster_id
      CLUSTER     = self.triggers.cluster
    }
    command = <<-EOT
      # -eo (not -euo): with -u, bash 3.2 (macOS default) treats an empty
      # array expansion as "unbound variable" and bails. We use such arrays
      # for the optional --resolve flag, so -u doesn't fit here.
      set -eo pipefail
      API="https://$VC_URL/api"
      AUTH="$VC_USERNAME:$VC_PASSWORD"
      # If vcenter_ip is pinned, use --resolve so DoH/Private-Relay-style
      # hostname hijacking can't redirect us to the Supervisor's K8s API.
      RESOLVE=()
      [ -n "$VC_IP" ] && RESOLVE=(--resolve "$VC_URL:443:$VC_IP")

      SESSION=$(curl "$${RESOLVE[@]}" -sk -u "$AUTH" -X POST -H 'Content-Type: application/json' "$API/session" | tr -d '"')
      # Refuse to continue if we got a non-token response (e.g. a K8s Status
      # JSON from a hostname hijack). vCenter session tokens are pure hex.
      if ! [[ "$SESSION" =~ ^[a-f0-9]+$ ]]; then
        echo "Got non-token response from $API/session — likely DNS hijack."
        echo "  Set var.vcenter_ip to the actual vCenter IP (e.g. 192.168.2.80)."
        echo "  Response head: $(echo "$SESSION" | head -c 200)"
        exit 1
      fi
      HDR="vmware-api-session-id: $SESSION"

      # Current status (404 / NONE means already disabled)
      STATUS=$(curl "$${RESOLVE[@]}" -sk -H "$HDR" "$API/vcenter/namespace-management/clusters/$CLUSTER_ID" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('config_status','NONE'))" 2>/dev/null || echo "NONE")
      echo "Current Supervisor status: $STATUS"

      if [[ "$STATUS" == "NONE" || "$STATUS" == "REMOVED" ]]; then
        echo "Supervisor already gone; nothing to disable."
        exit 0
      fi

      if [[ "$STATUS" != "REMOVING" ]]; then
        echo "Submitting disable for $CLUSTER ($CLUSTER_ID)..."
        RESP=$(curl "$${RESOLVE[@]}" -sk -w "HTTP_CODE:%%{http_code}" -H "$HDR" -X POST \
          "$API/vcenter/namespace-management/clusters/$CLUSTER_ID?action=disable")
        CODE=$(echo "$RESP" | grep -oE 'HTTP_CODE:[0-9]+' | cut -d: -f2)
        BODY=$(echo "$RESP" | sed 's/HTTP_CODE:[0-9]*$//')
        echo "Response code: $CODE"
        [ -n "$BODY" ] && echo "Body: $BODY"
        if [[ "$CODE" != "204" && "$CODE" != "200" ]]; then
          echo "Disable submission failed"
          exit 1
        fi
      fi

      echo "Polling for GONE (typically 10-15 min)..."
      for i in $(seq 1 60); do
        STATUS=$(curl "$${RESOLVE[@]}" -sk -H "$HDR" "$API/vcenter/namespace-management/clusters/$CLUSTER_ID" 2>/dev/null \
          | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('config_status','GONE'))" 2>/dev/null || echo "GONE")
        printf "  [%s] %s\n" "$(date +%T)" "$STATUS"
        [ "$STATUS" = "GONE" ] && exit 0
        sleep 30
      done
      echo "Disable timed out; may need manual cleanup via vSphere UI."
      exit 1
    EOT
  }
}

output "storage_policy_id" {
  value = vsphere_vm_storage_policy.supervisor_storage.id
}

output "enable_spec_path" {
  value = local_file.enable_spec.filename
}

# Live Supervisor API endpoint, written by the enable provisioner once
# config_status == RUNNING. May change across destroy/re-enable cycles
# (HAProxy picks an IP from the VIP pool).
data "local_file" "api_endpoint" {
  filename   = "${path.cwd}/generated/api-endpoint.txt"
  depends_on = [null_resource.supervisor_enable]
}

output "supervisor_api_endpoint" {
  description = "Live Supervisor cluster API endpoint (IP or hostname), populated post-enable."
  value       = trimspace(data.local_file.api_endpoint.content)
}
