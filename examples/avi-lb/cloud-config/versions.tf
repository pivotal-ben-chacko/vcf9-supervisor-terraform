terraform {
  required_version = ">= 1.6.0"

  required_providers {
    avi = {
      source = "vmware/avi"
      # Track the controller's major (OVA is 31.2.2). The avi provider is
      # versioned in lock-step with Avi/NSX-ALB releases.
      version = ">= 31.1.0, < 32.0.0"
    }
  }
}

# Talks to the controller stood up by ../ (Stage 1). The controller must
# already be reachable and the admin password set before this applies.
provider "avi" {
  avi_controller = var.avi_controller_ip
  avi_username   = var.avi_username
  avi_password   = var.avi_password
  avi_tenant     = "admin"
  avi_version    = var.avi_version
}
