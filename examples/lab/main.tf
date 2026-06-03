###############################################################
# Example: deploy the Supervisor cluster as in the lab.
#
# Usage:
#   cd terraform/examples/lab
#   cp ../../terraform.tfvars.example terraform.tfvars   # or write your own
#   # Set the two secret vars in secrets.auto.tfvars (NEVER commit this):
#   #   vcenter_password = "..."
#   #   haproxy_password = "..."
#   terraform init
#   terraform plan
#   terraform apply
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

# Provider configuration MUST live in the root module. Child modules
# (like ../../) can declare `required_providers` but not the actual
# provider config with credentials.
provider "vsphere" {
  user                 = var.vcenter_username
  password             = var.vcenter_password
  vsphere_server       = var.vcenter_server
  allow_unverified_ssl = true
}

###############################################################
# Most values for this module come from config.auto.tfvars, which
# is auto-generated from terraform/wcp-config-Skynet.json by
# `make sync-config`. Edit the JSON, regenerate, and these var.*
# references pick up the new values automatically.
#
# Values that DON'T come from the JSON (passwords, lab-specific
# inventory like physical_host_name, paths) are kept here.
###############################################################

module "supervisor_lab" {
  source = "../../"

  # ── from secrets.auto.tfvars ──
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_ip       = var.vcenter_ip
  haproxy_password = var.haproxy_password

  # ── from config.auto.tfvars (generated from wcp-config-Skynet.json) ──
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

  # ── lab-specific, not in the JSON ──
  vcenter_insecure      = true
  datacenter            = "Datacenter"
  physical_host_name    = "192.168.2.75"
  physical_host_cluster = "Cluster"
  nested_esxi_hosts     = ["192.168.3.241", "192.168.3.242", "192.168.3.243"]
  outer_datastore       = "datastore1"
  ntp_servers           = ["162.159.200.1"] # time.cloudflare.com anycast
  nfs_ip                = "192.168.3.244"

  # Outer networking — false for our lab (DSwitch + outer-mgmt-net + vSwitch1 + VM Network already exist).
  # Set true for vanilla vCenter deploys (physical-network module will create the equivalents).
  create_outer_networking = false
}

###############################################################
# Variables that this example expects from secrets.auto.tfvars
###############################################################

###############################################################
# Variables sourced from secrets.auto.tfvars (passwords) and
# config.auto.tfvars (everything from wcp-config-Skynet.json).
# Defaults match the lab's settled values so `terraform plan` works
# even if config.auto.tfvars hasn't been regenerated yet.
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
  description = "Optional: pin vCenter's IP for curl --resolve, defeats DNS hijack by DoH/Private-Relay/etc. Set to vCenter's internal IP (e.g. 192.168.2.80) when system DNS returns the public IP."
  type        = string
  default     = ""
}
variable "haproxy_password" {
  type      = string
  sensitive = true
}

# ── From config.auto.tfvars (generated from wcp-config-Skynet.json) ──
variable "vcenter_server" {
  type    = string
  default = "vcenter.skynetsystems.io"
}
variable "supervisor_cluster" {
  type    = string
  default = "Supervisor-Cluster"
}

variable "management_subnet" {
  type    = string
  default = "192.168.2.0/24"
}
variable "management_gateway" {
  type    = string
  default = "192.168.2.1"
}
variable "management_dns" {
  type    = list(string)
  default = ["192.168.2.1", "8.8.8.8"]
}
variable "management_cp_starting_ip" {
  type    = string
  default = "192.168.2.231"
}

variable "workload_subnet" {
  type    = string
  default = "192.168.3.0/24"
}
variable "workload_gateway" {
  type    = string
  default = "192.168.3.1"
}
variable "workload_dns" {
  type    = list(string)
  default = ["192.168.3.1", "8.8.8.8"]
}
variable "workload_ip_range" {
  type    = string
  default = "192.168.3.201-192.168.3.230"
}
variable "k8s_service_cidr" {
  type    = string
  default = "10.96.0.0/24"
}

variable "vip_pool" {
  type    = string
  default = "192.168.3.248/29"
}
variable "vip_pool_usable" {
  type    = list(string)
  default = ["192.168.3.249", "192.168.3.250", "192.168.3.251", "192.168.3.252", "192.168.3.253", "192.168.3.254"]
}

variable "haproxy_ip" {
  type    = string
  default = "192.168.3.245"
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
# OPTIONAL — nested ESXi VM creation
#
# Enable by setting build_nested_esxi = true in terraform.tfvars and
# providing source_iso_path + nested_esxi_root_password. Disabled by
# default because our lab already has the nested hosts running; new
# environments should turn this on.
###############################################################

variable "build_nested_esxi" {
  description = "If true, create the 3 nested ESXi VMs via the nested-esxi module. Off by default (assumes hosts already exist)."
  type        = bool
  default     = false
}

variable "source_iso_path" {
  description = "Local path to the ESXi installer ISO — only used when build_nested_esxi=true."
  type        = string
  default     = ""
}

variable "nested_esxi_root_password" {
  description = "Root password for the nested ESXi hosts. Set in secrets.auto.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

module "nested_esxi" {
  count  = var.build_nested_esxi ? 1 : 0
  source = "../../modules/nested-esxi"

  source_iso_path = var.source_iso_path

  datacenter       = "Datacenter"
  # The example's `module "supervisor_lab"` block constructs these
  # internally; for the optional case we re-resolve them here.
  datacenter_id    = data.vsphere_datacenter.dc.id
  resource_pool_id = data.vsphere_compute_cluster.physical.resource_pool_id
  datastore_id     = data.vsphere_datastore.physical.id
  datastore_name   = "datastore1"

  network_id            = data.vsphere_network.outer_vm_network.id
  network_dswitch_vm_id = data.vsphere_network.outer_dswitch_vm.id

  root_password = var.nested_esxi_root_password
  hosts = [
    { name = "nested-esxi-1", ip = "192.168.3.241" },
    { name = "nested-esxi-2", ip = "192.168.3.242" },
    { name = "nested-esxi-3", ip = "192.168.3.243" },
  ]
}

# Data sources used only when build_nested_esxi=true.
data "vsphere_datacenter" "dc" {
  name = "Datacenter"
}

data "vsphere_compute_cluster" "physical" {
  name          = "Cluster"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "physical" {
  name          = "datastore1"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "outer_vm_network" {
  name          = "VM Network"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "outer_dswitch_vm" {
  name          = "outer-mgmt-net"
  datacenter_id = data.vsphere_datacenter.dc.id
}

###############################################################
# Pass-through outputs
###############################################################

output "supervisor_api_vip" {
  value = module.supervisor_lab.supervisor_api_vip
}

output "haproxy_dataplane_api" {
  value = module.supervisor_lab.haproxy_dataplane_api
}

output "next_steps" {
  value = module.supervisor_lab.next_steps
}
