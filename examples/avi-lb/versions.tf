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
  }
}

# This is a STANDALONE root configuration. Run it directly:
#   cd examples/avi-lb && terraform init && terraform apply
# Unlike the modules under ../../modules/, it declares its own provider
# block because it is not consumed as a child module.
provider "vsphere" {
  user                 = var.vcenter_username
  password             = var.vcenter_password
  vsphere_server       = var.vcenter_server
  allow_unverified_ssl = var.vcenter_insecure
}
