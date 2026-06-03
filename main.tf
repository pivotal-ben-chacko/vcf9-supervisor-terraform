###############################################################
# Data sources — inventory references the module needs
###############################################################

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "supervisor" {
  name          = var.supervisor_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Outer/management VMs (HAProxy, NFS) deploy here, not on the Supervisor
# cluster. The nested ESXi hosts only see vsanDatastore (which isn't
# configured), so we use the physical host's datastore1 + its cluster's pool.
data "vsphere_compute_cluster" "physical" {
  name          = var.physical_host_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_host" "nested" {
  for_each      = toset(var.nested_esxi_hosts)
  name          = each.key
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_host" "physical" {
  name          = var.physical_host_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "outer_ds" {
  name          = var.outer_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

###############################################################
# OPTIONAL — create the outer physical-host networking (standard
# vSwitches + port groups). For existing environments that already
# have these (manually created as dswitch/VM Network), leave
# create_outer_networking = false (default) and the data sources
# below pick up the existing port groups by name.
###############################################################

module "physical_network" {
  count  = var.create_outer_networking ? 1 : 0
  source = "./modules/physical-network"

  physical_host_id        = data.vsphere_host.physical.id
  mgmt_switch_name        = var.outer_mgmt_switch_name
  mgmt_portgroup_name     = var.outer_dswitch_portgroup      # same name vars
  mgmt_pnic               = var.outer_mgmt_pnic
  workload_switch_name    = var.outer_workload_switch_name
  workload_portgroup_name = var.outer_vm_network_portgroup   # used both to create and to look up
  workload_pnic           = var.outer_workload_pnic
}

# Look up port group MoRefs by name. Works either way:
#   - if module.physical_network created them, the data source finds the new ones
#   - if not, the data source finds the pre-existing ones (data-source path)
# The depends_on forces resolution AFTER the module runs, so create-and-use in
# the same apply is safe.
data "vsphere_network" "outer_vm_network" {
  name          = var.outer_vm_network_portgroup
  datacenter_id = data.vsphere_datacenter.dc.id
  depends_on    = [module.physical_network]
}

data "vsphere_network" "outer_dswitch_vm" {
  name          = var.outer_dswitch_portgroup
  datacenter_id = data.vsphere_datacenter.dc.id
  depends_on    = [module.physical_network]
}

###############################################################
# Modules
###############################################################

# Phase 1, 8 (NTP), 11 (port group security flags on outer port groups)
module "host_config" {
  source = "./modules/host-config"

  physical_host_id           = data.vsphere_host.physical.id
  physical_host_name         = var.physical_host_name
  outer_vm_network_portgroup = var.outer_vm_network_portgroup
  outer_dswitch_portgroup    = var.outer_dswitch_portgroup
  ntp_servers                = var.ntp_servers

  # If physical-network module is creating the port groups with the right
  # flags already, skip the in-place security reconfigure.
  skip_outer_security_fixes = var.create_outer_networking

  vcenter_server   = var.vcenter_server
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_insecure = var.vcenter_insecure
  datacenter       = var.datacenter
  physical_host_cluster = var.physical_host_cluster

  depends_on = [module.physical_network]
}

# Phases 8.0a, 9 — supervisor-dvs, port groups, uplinks, teaming
module "network" {
  source = "./modules/network"

  datacenter_id      = data.vsphere_datacenter.dc.id
  cluster_id         = data.vsphere_compute_cluster.supervisor.id
  nested_hosts       = data.vsphere_host.nested

  outer_vm_network_id = data.vsphere_network.outer_vm_network.id
  outer_dswitch_vm_id = data.vsphere_network.outer_dswitch_vm.id

  vcenter_server   = var.vcenter_server
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_insecure = var.vcenter_insecure

  depends_on = [module.host_config]
}

# Phase 6 — NFS storage VM
module "nfs" {
  source = "./modules/nfs"

  datacenter_id    = data.vsphere_datacenter.dc.id
  resource_pool_id = data.vsphere_compute_cluster.physical.resource_pool_id
  datastore_id     = data.vsphere_datastore.outer_ds.id
  network_id       = data.vsphere_network.outer_vm_network.id
  vm_name          = var.nfs_vm_name
  ip_addr        = var.nfs_ip
  gateway        = var.workload_gateway
  dns_servers    = var.workload_dns
  share_size_gb  = var.nfs_share_size_gb
  share_path     = var.nfs_share_path

  ubuntu_ova_url = var.ubuntu_cloud_image_ova_url

  # Nested ESXi hosts that will mount the export as the "nfs-shared" datastore
  nested_host_ids = [for h in data.vsphere_host.nested : h.id]

  vcenter_server   = var.vcenter_server
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_insecure = var.vcenter_insecure

  depends_on = [module.host_config]
}

# Phase 7.B + 10 + 11 — HAProxy VM with the correct systemd flag and VIPs claimed
module "haproxy" {
  source = "./modules/haproxy"

  datacenter_id    = data.vsphere_datacenter.dc.id
  resource_pool_id = data.vsphere_compute_cluster.physical.resource_pool_id
  datastore_id     = data.vsphere_datastore.outer_ds.id
  network_id       = data.vsphere_network.outer_vm_network.id
  vm_name          = var.haproxy_vm_name
  ip_addr        = var.haproxy_ip
  gateway        = var.workload_gateway
  dns_servers    = var.workload_dns

  dataplaneapi_version = var.haproxy_dataplaneapi_version
  dataplaneapi_port    = var.haproxy_dataplaneapi_port
  dataplaneapi_user    = var.haproxy_username
  dataplaneapi_password = var.haproxy_password
  vip_addresses        = var.vip_pool_usable

  ubuntu_ova_url = var.ubuntu_cloud_image_ova_url

  vcenter_server   = var.vcenter_server
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_insecure = var.vcenter_insecure

  depends_on = [module.host_config]
}

# Phase 8.0b + 8.2 — storage policy + Supervisor enable
module "supervisor" {
  source = "./modules/supervisor"

  datacenter_id      = data.vsphere_datacenter.dc.id
  cluster_id         = data.vsphere_compute_cluster.supervisor.id
  cluster_name       = var.supervisor_cluster
  datacenter         = var.datacenter

  management_network        = module.network.sup_mgmt_portgroup_id
  management_starting_ip    = var.management_cp_starting_ip
  management_subnet         = var.management_subnet
  management_gateway        = var.management_gateway
  management_dns            = var.management_dns

  workload_network          = module.network.sup_workload_portgroup_id
  workload_ip_range         = var.workload_ip_range
  workload_gateway          = var.workload_gateway
  workload_subnet           = var.workload_subnet
  workload_dns              = var.workload_dns

  k8s_service_cidr = var.k8s_service_cidr
  k8s_pod_cidr     = var.k8s_pod_cidr

  haproxy_endpoint    = "${var.haproxy_ip}:${var.haproxy_dataplaneapi_port}"
  haproxy_user        = var.haproxy_username
  haproxy_password    = var.haproxy_password
  haproxy_cert_path   = module.haproxy.dataplaneapi_cert_path

  vip_pool = var.vip_pool

  control_plane_size = var.control_plane_size
  control_plane_ha   = var.control_plane_ha

  vcenter_server   = var.vcenter_server
  vcenter_username = var.vcenter_username
  vcenter_password = var.vcenter_password
  vcenter_insecure = var.vcenter_insecure
  vcenter_ip       = var.vcenter_ip

  depends_on = [module.network, module.haproxy, module.nfs]
}
