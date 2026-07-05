output "cloud_name" {
  value = avi_cloud.vcenter.name
}

output "vip_network" {
  value = avi_network.vip.name
}

output "vip_pool" {
  value = "${var.vip_pool_start} - ${var.vip_pool_end}"
}

output "se_group" {
  value = avi_serviceenginegroup.default.name
}
