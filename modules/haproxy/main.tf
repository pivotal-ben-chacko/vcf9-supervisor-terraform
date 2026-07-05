terraform {
  required_providers {
    vsphere  = { source = "vmware/vsphere" }
    null     = { source = "hashicorp/null" }
    local    = { source = "hashicorp/local" }
    random   = { source = "hashicorp/random" }
    external = { source = "hashicorp/external" }
  }
}

variable "datacenter_id" {}
variable "resource_pool_id" {}
variable "datastore_id" {}
variable "network_id" {}
variable "vm_name" {}
variable "ip_addr" {}
variable "gateway" {}
variable "dns_servers" { type = list(string) }
variable "dataplaneapi_version" {}
variable "dataplaneapi_port" { type = number }
variable "dataplaneapi_user" {}
variable "dataplaneapi_password" { sensitive = true }
variable "vip_addresses" { type = list(string) }
variable "ubuntu_ova_url" {}
# Credentials for the post-deploy power-on local-exec
variable "vcenter_server" {}
variable "vcenter_username" {}
variable "vcenter_password" { sensitive = true }
variable "vcenter_insecure" {
  type    = bool
  default = true
}

###############################################################
# Generate the self-signed TLS cert for Dataplane API
# (the wizard pins this cert)
###############################################################

resource "null_resource" "generate_dpapi_cert" {
  triggers = { vm_name = var.vm_name, san_ip = var.ip_addr }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      mkdir -p ${path.module}/generated
      openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout ${path.module}/generated/dpapi.key \
        -out    ${path.module}/generated/dpapi.crt \
        -days 825 \
        -subj "/CN=haproxy/O=lab" \
        -addext "subjectAltName=IP:${var.ip_addr},DNS:haproxy" 2>/dev/null
      chmod 600 ${path.module}/generated/dpapi.key
    EOT
  }
}

data "local_file" "dpapi_cert" {
  filename   = "${path.module}/generated/dpapi.crt"
  depends_on = [null_resource.generate_dpapi_cert]
}

data "local_file" "dpapi_key" {
  filename   = "${path.module}/generated/dpapi.key"
  depends_on = [null_resource.generate_dpapi_cert]
}

###############################################################
# Hash the dataplaneapi password for the YAML config
###############################################################

resource "random_password" "salt" {
  length  = 8
  special = false
}

data "external" "pw_hash" {
  program = ["bash", "-c", "openssl passwd -1 -salt ${random_password.salt.result} '${var.dataplaneapi_password}' | jq -Rn 'inputs | {hash:.}'"]
}

###############################################################
# Build cloud-init user-data (writes haproxy.cfg, dataplaneapi.yaml,
# TLS cert, systemd unit using the CORRECT `-f` flag, and netplan
# entries that claim all VIPs on ens192).
###############################################################

locals {
  # 14 leading spaces aligns with the existing `              - $${ip_addr}/24`
  # entry inside `addresses:` in the netplan block (content: | block scalar
  # strips 6 spaces of base indent; 14 - 6 = 8 spaces in the rendered file).
  netplan_vip_addresses = join("\n", [
    for ip in var.vip_addresses : "              - ${ip}/32"
  ])

  cloud_init = templatefile("${path.module}/templates/user-data.yaml.tpl", {
    hostname             = var.vm_name
    ip_addr              = var.ip_addr
    gateway              = var.gateway
    dns_servers          = join(",", var.dns_servers)
    netplan_vip_addresses = local.netplan_vip_addresses
    dataplaneapi_user    = var.dataplaneapi_user
    dataplaneapi_password = var.dataplaneapi_password
    dataplaneapi_password_hash = data.external.pw_hash.result.hash
    dataplaneapi_port    = var.dataplaneapi_port
    dataplaneapi_version = var.dataplaneapi_version
    dpapi_cert_b64       = base64encode(data.local_file.dpapi_cert.content)
    dpapi_key_b64        = base64encode(data.local_file.dpapi_key.content)
    vip_list             = join(" ", var.vip_addresses)
  })
}

###############################################################
# Deploy the VM from the Ubuntu cloud OVA with cloud-init
###############################################################

resource "vsphere_virtual_machine" "haproxy" {
  name                       = var.vm_name
  datacenter_id              = var.datacenter_id
  resource_pool_id           = var.resource_pool_id
  datastore_id               = var.datastore_id
  num_cpus                   = 2
  memory                     = 2048
  guest_id                   = "ubuntu64Guest"
  firmware                   = "efi"
  wait_for_guest_net_timeout = 5
  wait_for_guest_ip_timeout  = 5

  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0"
    size             = 40
    thin_provisioned = true
  }

  ovf_deploy {
    remote_ovf_url    = var.ubuntu_ova_url
    disk_provisioning = "thin"
  }

  # Satisfy the vsphere provider's plan-time check that vApp properties
  # have a CDROM delivery channel (even though we deliver cloud-init via
  # extra_config/guestinfo, not vApp props). Without this, refreshing
  # the resource on subsequent applies fails with: "requires a client
  # CDROM device to deliver vApp properties".
  cdrom {
    client_device = true
  }

  extra_config = {
    "guestinfo.userdata"          = base64encode(local.cloud_init)
    "guestinfo.userdata.encoding" = "base64"
  }

  # vSphere reports io_reservation=1 / io_share_count=1000 on OVA-deployed
  # disks regardless of what's applied, so these two diff on every plan
  # (and via the supervisor module's depends_on, that noise cascades into
  # an enable-spec replacement). Pin them.
  lifecycle {
    ignore_changes = [
      disk[0].io_reservation,
      disk[0].io_share_count,
    ]
  }
}

# The vmware/vsphere provider's ovf_deploy path leaves the VM powered
# off after import — separate explicit step to power it on.
resource "null_resource" "haproxy_power_on" {
  triggers = { vm_id = vsphere_virtual_machine.haproxy.id }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GOVC_URL      = var.vcenter_server
      GOVC_USERNAME = var.vcenter_username
      GOVC_PASSWORD = var.vcenter_password
      GOVC_INSECURE = var.vcenter_insecure ? "true" : "false"
    }
    # Idempotent. ovf_deploy with datacenter_id set already auto-powers-on,
    # but keep this as a safety net for partial-apply recovery + future provider
    # quirks. Match against the text vm.info output (-json adds whitespace
    # around the colon which broke a prior pattern).
    command = "if govc vm.info ${var.vm_name} 2>/dev/null | grep -q 'Power state:.*poweredOn'; then echo 'already powered on'; else govc vm.power -on=true ${var.vm_name}; fi"
  }
}

###############################################################
# Post-deploy validation — wait for Dataplane API to respond and
# verify a transaction commit works (catches Phases 10/11 if they
# ever regress).
###############################################################

resource "null_resource" "validate_dataplane_api" {
  triggers = {
    vm_id = vsphere_virtual_machine.haproxy.id
    pw    = sha256(var.dataplaneapi_password)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      DPAPI_USER = var.dataplaneapi_user
      DPAPI_PASS = var.dataplaneapi_password
      DPAPI_HOST = var.ip_addr
      DPAPI_PORT = tostring(var.dataplaneapi_port)
    }
    command = <<-EOT
      set -euo pipefail
      H="https://$DPAPI_HOST:$DPAPI_PORT"
      U="$DPAPI_USER:$DPAPI_PASS"

      echo "Waiting up to 5 minutes for Dataplane API to come up..."
      for i in $(seq 1 60); do
        if curl -sk --max-time 4 -u "$U" "$H/v2/info" | grep -q '"version"'; then
          break
        fi
        sleep 5
      done

      echo "Verifying transaction commit (catches Phase 10 regression)..."
      VER=$(curl -sk -u "$U" "$H/v2/services/haproxy/configuration/version")
      TX=$(curl -sk -u "$U" -X POST "$H/v2/services/haproxy/transactions?version=$VER")
      TX_ID=$(echo "$TX" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")

      curl -sk -u "$U" -X POST -H 'Content-Type: application/json' \
        "$H/v2/services/haproxy/configuration/backends?transaction_id=$TX_ID" \
        -d '{"name":"tf_test","mode":"tcp","balance":{"algorithm":"roundrobin"}}' >/dev/null

      RESULT=$(curl -sk -u "$U" -X PUT "$H/v2/services/haproxy/transactions/$TX_ID")
      if echo "$RESULT" | grep -q '"status":"success"'; then
        echo "  transaction commit: OK"
        NEW_VER=$(curl -sk -u "$U" "$H/v2/services/haproxy/configuration/version")
        curl -sk -u "$U" -X DELETE "$H/v2/services/haproxy/configuration/backends/tf_test?version=$NEW_VER" >/dev/null
      else
        echo "  transaction commit FAILED: $RESULT" >&2
        exit 1
      fi

      echo "Verifying VIPs are reachable (catches Phase 11 regression)..."
      for ip in ${join(" ", var.vip_addresses)}; do
        # Retry up to 3 times: the gratuitous-ARP from cloud-init usually
        # primes upstream caches, but a slow router (or one that drops
        # unsolicited ARP) can leave the first ping/sec timing out. -W10
        # gives ARP-Who-Has time to complete on the cold path.
        ok=false
        for try in 1 2 3; do
          if ping -c2 -W10 "$ip" >/dev/null 2>&1; then
            ok=true; break
          fi
          sleep 2
        done
        if [ "$ok" = true ]; then
          echo "  $ip OK"
        else
          echo "  $ip DEAD (Phase 11 fix may not have run)" >&2
          exit 1
        fi
      done
    EOT
  }
}

output "dataplaneapi_endpoint" {
  value = "https://${var.ip_addr}:${var.dataplaneapi_port}"
}

output "dataplaneapi_cert_path" {
  value = data.local_file.dpapi_cert.filename
}
