output "supervisor_api_vip" {
  description = "Public K8s API endpoint, served by HAProxy. Read live from vCenter after enable — may differ across re-enables because HAProxy allocates from the VIP pool."
  value       = "https://${module.supervisor.supervisor_api_endpoint}"
}

output "haproxy_dataplane_api" {
  description = "Dataplane API endpoint (private — only used by vCenter/Supervisor)."
  value       = "https://${var.haproxy_ip}:${var.haproxy_dataplaneapi_port}"
}

output "nested_esxi_hosts" {
  value = var.nested_esxi_hosts
}

output "sup_mgmt_portgroup_id" {
  value = module.network.sup_mgmt_portgroup_id
}

output "sup_workload_portgroup_id" {
  value = module.network.sup_workload_portgroup_id
}

output "next_steps" {
  value = <<-EOT
    Supervisor cluster is up. To use it:

    1. Download the kubectl plugin:
       curl -kLo /tmp/plugin.zip https://${module.supervisor.supervisor_api_endpoint}/wcp/plugin/darwin-amd64/vsphere-plugin.zip

    2. Log in:
       kubectl vsphere login --server=${module.supervisor.supervisor_api_endpoint} \
         --insecure-skip-tls-verify --vsphere-username=${var.vcenter_username}

    3. Create a vSphere Namespace via vSphere UI → Workload Management → Namespaces.

    4. Switch to it: kubectl config use-context <namespace>

    Helper scripts: see ../../scripts/sv-*
  EOT
}
