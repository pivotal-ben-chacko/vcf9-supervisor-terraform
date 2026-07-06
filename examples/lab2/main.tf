###############################################################
# Example: second lab — different location, different vCenter.
#
# IP plan (differs from examples/lab):
#   workload   = "VM Network"      = 192.168.1.0/24
#   management = "outer-mgmt-net"  = 192.168.2.0/24
#   nested ESXi hosts already running at 192.168.1.241-243
#
# Search for CHANGE-ME before running — vCenter FQDN, inventory
# names, and gateways/DNS must match the new site.
#
# Usage:
#   cd examples/lab2
#   cat > secrets.auto.tfvars <<EOF
#   vcenter_password = "..."
#   haproxy_password = "..."
#   vcenter_ip       = "..."   # the new vCSA's IP — pins curl against DNS hijacks
#   EOF
#   chmod 600 secrets.auto.tfvars
#   terraform init && terraform plan && terraform apply
#
# BEFORE apply: set a unique hostname on each nested host — ESXi
# defaults to "localhost", which makes every spherelet share the same
# certificate identity and blocks node registration (see
# TROUBLESHOOTING.md, "Supervisor ESXi nodes never join"):
#   esxcli system hostname set --host=nested-esxi-1 --domain=<site-domain>
###############################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = ">= 2.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3.0"
    }
  }
}

provider "vsphere" {
  user                 = var.vcenter_username
  password             = var.vcenter_password
  vsphere_server       = var.vcenter_server
  allow_unverified_ssl = true
}

module "supervisor_lab2" {
  source = "../../"

  # ── from secrets.auto.tfvars ──
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_ip       = var.vcenter_ip
  haproxy_password = var.haproxy_password

  # ── site config (see variables below for values) ──
  vcenter_server     = var.vcenter_server
  supervisor_cluster = var.supervisor_cluster

  management_subnet         = var.management_subnet
  management_gateway        = var.management_gateway
  management_dns            = var.management_dns
  management_cp_starting_ip = var.management_cp_starting_ip

  workload_subnet   = var.workload_subnet
  workload_gateway  = var.workload_gateway
  workload_dns      = var.workload_dns
  workload_ip_range = var.workload_ip_range
  k8s_service_cidr  = var.k8s_service_cidr

  vip_pool        = var.vip_pool
  vip_pool_usable = var.vip_pool_usable

  haproxy_ip                = var.haproxy_ip
  haproxy_username          = var.haproxy_username
  haproxy_dataplaneapi_port = var.haproxy_dataplaneapi_port

  control_plane_size = var.control_plane_size
  control_plane_ha   = var.control_plane_ha

  # ── site-specific inventory ──
  vcenter_insecure      = true
  datacenter            = var.datacenter
  physical_host_name    = var.physical_host_name
  physical_host_cluster = var.physical_host_cluster
  nested_esxi_hosts     = var.nested_esxi_hosts
  outer_datastore       = var.outer_datastore
  ntp_servers           = ["162.159.200.1"] # time.cloudflare.com anycast
  nfs_ip                = "192.168.1.244"

  # Management-subnet vmkernel NIC per host (spherelet path — see
  # TROUBLESHOOTING.md). Keys MUST match nested_esxi_hosts entries.
  nested_host_mgmt_ips = {
    "192.168.1.241" = "192.168.2.241"
    "192.168.1.242" = "192.168.2.242"
    "192.168.1.243" = "192.168.2.243"
  }

  # Port groups already exist at this site under the same names the
  # module defaults to ("VM Network" / "outer-mgmt-net").
  create_outer_networking = false
}

###############################################################
# Variables — site values. The lab1 example generates these from
# wcp-config-Skynet.json via `make sync-config`; for this site the
# values are maintained here directly (or wire up your own JSON with
# scripts/json-to-tfvars.py writing to this directory).
###############################################################

# ── From secrets.auto.tfvars ──
variable "vcenter_username" {
  type    = string
  default = "administrator@vsphere.local"
}
variable "vcenter_password" {
  type      = string
  sensitive = true
}
variable "vcenter_ip" {
  description = "The new vCSA's IP — pins local-exec curl calls against DNS interception."
  type        = string
  default     = ""
}
variable "haproxy_password" {
  type      = string
  sensitive = true
}

# ── vCenter / inventory (CHANGE-ME: must match the new site) ──
variable "vcenter_server" {
  # The lab-2 vCSA's system name (PNID) — an FQDN or an IP, whichever
  # the vCSA was deployed with (check: the CN of the cert on :443).
  # If the PNID is an IP, use the IP here; that also removes the
  # DNS-hijack failure mode entirely (see TROUBLESHOOTING.md → DNS).
  type    = string
  default = "CHANGE-ME" # FQDN or IP of the lab-2 vCenter
}
variable "datacenter" {
  type    = string
  default = "Datacenter" # CHANGE-ME if the new vCenter names it differently
}
variable "physical_host_name" {
  type    = string
  default = "CHANGE-ME" # physical host's inventory name (typically its IP)
}
variable "physical_host_cluster" {
  type    = string
  default = "Cluster" # CHANGE-ME: cluster containing the physical host
}
variable "supervisor_cluster" {
  # NOT created by Terraform — this is a lookup. Create the cluster in
  # the lab-2 vCenter and join the three nested hosts to it BEFORE
  # running terraform; this name must match that cluster's inventory
  # name exactly (CHANGE-ME if you named it something else).
  type    = string
  default = "Supervisor-Cluster"
}
variable "nested_esxi_hosts" {
  # These are vCenter INVENTORY names — the exact string each host was
  # registered with when added to vCenter. README §2b adds hosts by IP,
  # so IPs are correct here; if you add them by FQDN instead, put the
  # FQDNs here. NOTE: this is independent of the esxcli hostname set in
  # step 0 (that drives spherelet's cert identity / K8s node name;
  # setting it does NOT rename the vCenter inventory object). The
  # nested_host_mgmt_ips map keys must match these values.
  type    = list(string)
  default = ["192.168.1.241", "192.168.1.242", "192.168.1.243"]
}
variable "outer_datastore" {
  type    = string
  default = "datastore1" # CHANGE-ME: datastore on the physical host for HAProxy/NFS VMs
}

# ── Supervisor CONTROL-PLANE management network ──
# (outer-mgmt-net = 192.168.2.0/24)
#
# "Management" here is the Supervisor wizard's term: this subnet is
# where the Supervisor control-plane VMs put eth0 (vCenter/DNS traffic)
# and where Terraform adds each host's vmk1 for spherelet. It is NOT
# the ESXi hosts' own "Management Network" (vmk0) — that stays on the
# workload subnet (192.168.1.24x) and these values never touch it.
variable "management_subnet" {
  type    = string
  default = "192.168.2.0/24"
}
variable "management_gateway" {
  type    = string
  default = "192.168.2.1" # CHANGE-ME if the site router differs
}
variable "management_dns" {
  type    = list(string)
  default = ["192.168.2.1", "8.8.8.8"] # CHANGE-ME: DNS reachable from the mgmt subnet
}
variable "management_cp_starting_ip" {
  description = "First of 5 consecutive free IPs reserved for Supervisor CP VMs."
  type        = string
  default     = "192.168.2.231"
}

# ── Workload network: VM Network = 192.168.1.0/24 ──
variable "workload_subnet" {
  type    = string
  default = "192.168.1.0/24"
}
variable "workload_gateway" {
  type    = string
  default = "192.168.1.1" # CHANGE-ME if the site router differs
}
variable "workload_dns" {
  type    = list(string)
  default = ["192.168.1.1", "8.8.8.8"] # CHANGE-ME: DNS reachable from the workload subnet
}
variable "workload_ip_range" {
  description = "CP eth1 + pod VM IPs. Keep outside DHCP and clear of .241-.245."
  type    = string
  default = "192.168.1.201-192.168.1.230"
}
variable "k8s_service_cidr" {
  type    = string
  default = "10.96.0.0/23"
}

variable "vip_pool" {
  type    = string
  default = "192.168.1.248/29"
}
variable "vip_pool_usable" {
  type    = list(string)
  default = ["192.168.1.249", "192.168.1.250", "192.168.1.251", "192.168.1.252", "192.168.1.253", "192.168.1.254"]
}

variable "haproxy_ip" {
  type    = string
  default = "192.168.1.245"
}
variable "haproxy_username" {
  type    = string
  default = "admin"
}
variable "haproxy_dataplaneapi_port" {
  type    = number
  default = 5556
}

variable "control_plane_size" {
  type    = string
  default = "TINY"
}
variable "control_plane_ha" {
  type    = bool
  default = false
}

###############################################################
# Pass-through outputs
###############################################################

output "supervisor_api_vip" {
  value = module.supervisor_lab2.supervisor_api_vip
}

output "haproxy_dataplane_api" {
  value = module.supervisor_lab2.haproxy_dataplane_api
}

output "next_steps" {
  value = module.supervisor_lab2.next_steps
}
