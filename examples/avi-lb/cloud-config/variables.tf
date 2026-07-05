###############################################################
# Connection to the controller (Stage 1 output)
###############################################################

variable "avi_controller_ip" {
  type    = string
  default = "192.168.2.240"
}

variable "avi_username" {
  type    = string
  default = "admin"
}

variable "avi_password" {
  type      = string
  sensitive = true
}

variable "avi_version" {
  type    = string
  default = "31.2.2"
}

###############################################################
# vCenter cloud — lets Avi auto-deploy Service Engines
###############################################################

variable "vcenter_server" {
  type    = string
  default = "vcenter.skynetsystems.io"
}

variable "vcenter_username" {
  type    = string
  default = "administrator@vsphere.local"
}

variable "vcenter_password" {
  type      = string
  sensitive = true
}

variable "datacenter" {
  type    = string
  default = "Datacenter"
}

variable "cloud_name" {
  description = "Avi cloud name. Reuse the built-in 'Default-Cloud' or create a new one."
  type        = string
  default     = "Default-Cloud"
}

variable "se_mgmt_portgroup" {
  description = "Port group name for Service Engine MANAGEMENT NICs (mgmt network)."
  type        = string
  default     = "outer-mgmt-net"
}

###############################################################
# VIP / data network — where Service Engines place the VIPs
###############################################################

variable "vip_portgroup" {
  description = "Port group name carrying the VIPs / SE data NICs (the workload network)."
  type        = string
  default     = "VM Network"
}

variable "vip_network_cidr" {
  description = "Subnet of the VIP network, e.g. 192.168.3.0/24."
  type        = string
  default     = "192.168.3.0/24"
}

variable "vip_pool_start" {
  description = "First VIP the Avi IPAM may hand out (matches the HAProxy pool)."
  type        = string
  default     = "192.168.3.249"
}

variable "vip_pool_end" {
  type    = string
  default = "192.168.3.254"
}

variable "se_group_name" {
  type    = string
  default = "Default-Group"
}
