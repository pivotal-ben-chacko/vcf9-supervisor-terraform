output "avi_controller_url" {
  description = "Controller UI/API base URL."
  value       = "https://${var.controller_ip}"
}

output "avi_controller_ip" {
  value = var.controller_ip
}

output "avi_controller_cert_path" {
  description = "Local path to the fetched controller cert (feed to Supervisor's avi_config_create_spec.certificate_authority_chain)."
  value       = "${path.module}/generated/avi-controller.crt"
}

output "next_steps" {
  value = <<-EOT

    Avi Controller deployed at https://${var.controller_ip}

    1. Log in (admin / <avi_admin_password>) and confirm it is healthy.
    2. Configure the vCenter cloud + SE group + VIP network:
         cd cloud-config
         terraform init && terraform apply
    3. Wire Supervisor at the Avi controller — see README
       "Wiring into Supervisor" (provider = "AVI" in the enable spec).
  EOT
}
