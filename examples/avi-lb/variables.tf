###############################################################
# vCenter connection
###############################################################

variable "vcenter_server" {
  description = "vCenter hostname/FQDN (no scheme)."
  type        = string
  default     = "vcenter.skynetsystems.io"
}

variable "vcenter_username" {
  type    = string
  default = "administrator@vsphere.local"
}

variable "vcenter_password" {
  type      = string
  sensitive = true
}

variable "vcenter_insecure" {
  description = "Skip TLS verification of vCenter (lab self-signed cert)."
  type        = bool
  default     = true
}

###############################################################
# vSphere placement — where the Avi Controller VM lands.
#
# Mirror the haproxy/nfs modules: the controller runs on the PHYSICAL
# host's cluster + datastore (NOT the nested Supervisor cluster), because
# the nested ESXi hosts only see vsanDatastore/nfs-shared, and the
# controller needs to talk to vCenter on the management network.
###############################################################

variable "datacenter" {
  type    = string
  default = "Datacenter"
}

variable "physical_host_cluster" {
  description = "Cluster whose resource pool hosts the controller VM (the physical host's cluster)."
  type        = string
  default     = "Cluster"
}

variable "outer_datastore" {
  description = "Datastore for the controller VM disk (the physical host's local datastore)."
  type        = string
  default     = "datastore1"
}

variable "controller_network" {
  description = <<-EOT
    Port group for the controller's single management NIC. The controller
    must reach vCenter and be reachable by the Supervisor control plane, so
    this is the MANAGEMENT network (192.168.2.x in the lab), not the
    workload/VIP network. The OVA exposes exactly one NIC labelled
    "Management".
  EOT
  type        = string
  default     = "outer-mgmt-net"
}

###############################################################
# Avi Controller OVA + sizing
###############################################################

variable "avi_ova_path" {
  description = <<-EOT
    Local path (or remote URL) to the Avi/NSX-ALB Controller OVA. The OVA
    is NOT public — download it from the Broadcom/VMware support portal.
    Default points at the copy already sitting in the repo root.
  EOT
  type        = string
  default     = "../../controller-31.2.2-9059.ova"
}

variable "controller_vm_name" {
  type    = string
  default = "avi-controller"
}

# OVA ships 6 vCPU / 32 GB / 128 GB. Avi supports going to 8 vCPU for
# production; do NOT go below these for anything but a throwaway lab.
variable "controller_cpus" {
  type    = number
  default = 6
}

variable "controller_memory_mb" {
  type    = number
  default = 32768
}

variable "controller_disk_gb" {
  description = "Must be >= the OVA's 128 GB disk; the provider can grow but not shrink it."
  type        = number
  default     = 128
}

###############################################################
# Controller management network identity (set via OVA vApp props)
###############################################################

variable "controller_ip" {
  description = "Management IPv4 for the controller (on controller_network)."
  type        = string
  default     = "192.168.2.240"
}

variable "controller_netmask" {
  type    = string
  default = "255.255.255.0"
}

variable "controller_gateway" {
  type    = string
  default = "192.168.2.1"
}

variable "controller_hostname" {
  type    = string
  default = "avi-controller"
}

variable "sysadmin_public_key" {
  description = "Optional SSH public key for the controller's admin shell. Empty = none."
  type        = string
  default     = ""
}

###############################################################
# Avi admin account + post-deploy bootstrap
###############################################################

variable "avi_admin_username" {
  description = "Avi admin username. The OVA hardcodes 'admin'; leave as-is."
  type        = string
  default     = "admin"
}

variable "avi_admin_password" {
  description = <<-EOT
    Initial admin password, injected at deploy time via the OVA's
    `default-password` vApp property. Avi enforces complexity (>= 8 chars,
    upper/lower/digit/special). Put this in secrets.auto.tfvars.
  EOT
  type        = string
  sensitive   = true
}

variable "avi_version" {
  description = "Avi API version, sent as the X-Avi-Version header. Match the OVA (31.2.2)."
  type        = string
  default     = "31.2.2"
}

variable "avi_backup_passphrase" {
  description = "Backup/restore passphrase for the controller. Put in secrets.auto.tfvars."
  type        = string
  sensitive   = true
  default     = ""
}

variable "avi_license_file" {
  description = "Optional path to an Avi license JSON to apply post-deploy. Empty = run on the default trial/Essentials grant."
  type        = string
  default     = ""
}

variable "controller_dns_servers" {
  type    = list(string)
  default = ["192.168.2.1", "8.8.8.8"]
}

variable "controller_ntp_servers" {
  type    = list(string)
  default = ["162.159.200.1"] # time.cloudflare.com anycast (matches the lab)
}
