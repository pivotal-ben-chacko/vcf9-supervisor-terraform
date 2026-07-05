###############################################################
# vCenter connection
###############################################################

variable "vcenter_server" {
  description = "vCenter hostname or IP (no scheme, no path)."
  type        = string
  default     = "vcenter.skynetsystems.io"
}

variable "vcenter_ip" {
  description = "Optional: pin vCenter's IP for local-exec curl calls (used as --resolve). Set when operator's resolver hijacks the hostname (DoH, iCloud Private Relay, etc) and curl ends up on the wrong server. Empty disables pinning."
  type        = string
  default     = ""
}

variable "vcenter_username" {
  description = "vSphere SSO username (e.g. administrator@vsphere.local). Not marked sensitive because usernames aren't secret and we reference this in plain-text outputs."
  type        = string
}

variable "vcenter_password" {
  description = "vSphere SSO password. Source from a secrets.auto.tfvars file, never commit."
  type        = string
  sensitive   = true
}

variable "vcenter_insecure" {
  description = "Skip TLS verification of vCenter cert."
  type        = bool
  default     = true
}

###############################################################
# Inventory references (must already exist)
###############################################################

variable "datacenter" {
  description = "vCenter Datacenter name where the cluster lives."
  type        = string
  default     = "Datacenter"
}

variable "supervisor_cluster" {
  description = "Name of the compute cluster that will host Supervisor (must already exist with nested ESXi hosts joined)."
  type        = string
  default     = "Supervisor-Cluster"
}

variable "physical_host_name" {
  description = "Name (typically IP) of the physical ESXi host."
  type        = string
  default     = "192.168.2.75"
}

variable "physical_host_cluster" {
  description = "Cluster containing the physical host."
  type        = string
  default     = "Cluster"
}

variable "nested_esxi_hosts" {
  description = "Names (typically IPs) of the nested ESXi hosts in the Supervisor cluster."
  type        = list(string)
  default     = ["192.168.3.241", "192.168.3.242", "192.168.3.243"]
}

variable "nested_host_mgmt_ips" {
  description = "Management-subnet vmkernel IP per nested host (keyed by host name). Gives spherelet a symmetric L2 path to the Supervisor CP floating IP — without it, strict rp_filter on the CP VMs drops host traffic and ESXi nodes never join (TROUBLESHOOTING.md, 'Supervisor ESXi nodes never join'). Set {} to disable."
  type        = map(string)
  default = {
    "192.168.3.241" = "192.168.2.241"
    "192.168.3.242" = "192.168.2.242"
    "192.168.3.243" = "192.168.2.243"
  }
}

variable "outer_vm_network_portgroup" {
  description = "Name of the outer (physical-host) port group used by nested ESXi vmnic1 for the workload subnet. Default = the lab's existing 'VM Network'. For fresh deploys via the physical-network module, use 'outer-workload-net'."
  type        = string
  default     = "VM Network"
}

variable "outer_dswitch_portgroup" {
  description = "Name of the outer (physical-host) DVS port group used by nested ESXi vmnic2 — bridges to the management subnet. Lab uses 'outer-mgmt-net' (was 'dswitch-vm' prior to 2026-05 rename). The physical-network module also creates this name."
  type        = string
  default     = "outer-mgmt-net"
}

###############################################################
# OPTIONAL — physical-network module
#
# Off by default (most users have these manually). Turn on for fresh
# vCenter deploys where the physical host has nothing but a default
# vSwitch0 with management vmk.
###############################################################

variable "create_outer_networking" {
  description = "If true, instantiate the physical-network module to create standard vSwitches on the physical host. Leave false to use existing port groups (data-source path)."
  type        = bool
  default     = false
}

variable "outer_mgmt_switch_name" {
  description = "Name of the management vSwitch created by physical-network (when create_outer_networking=true)."
  type        = string
  default     = "outer-mgmt-vsw"
}

variable "outer_workload_switch_name" {
  description = "Name of the workload vSwitch created by physical-network (when create_outer_networking=true)."
  type        = string
  default     = "outer-workload-vsw"
}

variable "outer_mgmt_pnic" {
  description = "Physical NIC on the physical host that backs the management vSwitch (when create_outer_networking=true)."
  type        = string
  default     = "vmnic4"
}

variable "outer_workload_pnic" {
  description = "Physical NIC on the physical host that backs the workload vSwitch (when create_outer_networking=true)."
  type        = string
  default     = "vmnic5"
}

# NOTE: when create_outer_networking=true, the physical-network module
# *names* the port groups it creates using `outer_vm_network_portgroup`
# (for the workload subnet) and `outer_dswitch_portgroup` (for the
# management subnet). Same vars do double duty: they're the names to
# create AND the names to look up downstream. Defaults match our
# existing lab; override for clean new deploys (e.g. "outer-workload-net"
# / "outer-mgmt-net").

variable "outer_datastore" {
  description = "Datastore on the physical host where HAProxy/NFS VMs are deployed."
  type        = string
  default     = "datastore1"
}

###############################################################
# IP plan
###############################################################

variable "management_subnet" {
  description = "Management subnet (CP VM eth0 lives here). CIDR."
  type        = string
  default     = "192.168.2.0/24"
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
  description = "Starting IP for Supervisor control-plane VM(s) in the management subnet. Wizard reserves 1 (HA off) or 5 (HA on) consecutive IPs from here."
  type        = string
  default     = "192.168.2.231"
}

variable "workload_subnet" {
  description = "Workload subnet (CP VM eth1, pods, LB backends). CIDR."
  type        = string
  default     = "192.168.3.0/24"
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
  description = "IP range used for the Supervisor workload network — e.g. CP VM eth1 + pod IPs requested via Service{type:LB}."
  type        = string
  default     = "192.168.3.201-192.168.3.230"
}

variable "vip_pool" {
  description = "VIP pool CIDR for HAProxy frontends. Must be a /29 or wider; usable IPs are claimed on HAProxy's ens192 as /32 secondaries."
  type        = string
  default     = "192.168.3.248/29"
}

variable "vip_pool_usable" {
  description = "List of usable VIPs from the pool (network + broadcast excluded)."
  type        = list(string)
  default = [
    "192.168.3.249",
    "192.168.3.250",
    "192.168.3.251",
    "192.168.3.252",
    "192.168.3.253",
    "192.168.3.254",
  ]
}

variable "k8s_service_cidr" {
  description = "Cluster-internal Service CIDR (defaults work for most setups)."
  type        = string
  default     = "10.96.0.0/24"
}

variable "k8s_pod_cidr" {
  description = "Cluster-internal Pod CIDR."
  type        = string
  default     = "10.244.0.0/20"
}

###############################################################
# NTP — critical (see Phase 8 root cause #3 in SUPERVISOR-INSTALL.md)
###############################################################

variable "ntp_servers" {
  description = "NTP servers for the physical ESXi host. Use IPs to avoid DNS bootstrap problem."
  type        = list(string)
  default     = ["162.159.200.1"] # time.cloudflare.com anycast
}

###############################################################
# HAProxy
###############################################################

variable "haproxy_vm_name" {
  type    = string
  default = "haproxy"
}

variable "haproxy_ip" {
  description = "HAProxy primary IP (workload subnet). Also where the Dataplane API listens."
  type        = string
  default     = "192.168.3.245"
}

variable "haproxy_username" {
  description = "Username for Dataplane API basic auth and the ubuntu user on the VM."
  type        = string
  default     = "admin"
}

variable "haproxy_password" {
  description = "Password for Dataplane API basic auth. Provide via secrets.auto.tfvars."
  type        = string
  sensitive   = true
}

variable "haproxy_dataplaneapi_port" {
  type    = number
  default = 5556
}

variable "haproxy_dataplaneapi_version" {
  description = "Version of HAProxy Dataplane API to install. v2.9.10 has the YAML-rewrite bug — use ≥v2.9.25."
  type        = string
  default     = "2.9.25"
}

###############################################################
# NFS storage VM
###############################################################

variable "nfs_vm_name" {
  type    = string
  default = "nfs-storage"
}

variable "nfs_ip" {
  type    = string
  default = "192.168.3.244"
}

variable "nfs_share_size_gb" {
  type    = number
  default = 200
}

variable "nfs_share_path" {
  type    = string
  default = "/srv/nfs/shared"
}

###############################################################
# Supervisor storage
###############################################################

variable "storage_tag_name" {
  description = "Name of the vSphere tag (in the 'supervisor' category) attached to the nfs-shared datastore to drive the Supervisor storage policy."
  type        = string
  default     = "supervisor-storage"
}

###############################################################
# Supervisor control plane
###############################################################

variable "control_plane_size" {
  description = "Tiny / Small / Medium / Large. Tiny suffices for a lab."
  type        = string
  default     = "TINY"
  validation {
    condition     = contains(["TINY", "SMALL", "MEDIUM", "LARGE"], var.control_plane_size)
    error_message = "control_plane_size must be TINY / SMALL / MEDIUM / LARGE"
  }
}

variable "control_plane_ha" {
  description = "Enable HA (3 CP VMs + floating IP). OFF for lab to save ~16 GiB RAM."
  type        = bool
  default     = false
}

###############################################################
# Ubuntu cloud image
###############################################################

variable "ubuntu_cloud_image_ova_url" {
  description = "URL or path to the Ubuntu cloud OVA used as the base for HAProxy and NFS VMs."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.ova"
}
