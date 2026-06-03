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

# NOTE: no `provider "vsphere"` configuration block here. When this directory
# is used as a child module (called from examples/lab/), the provider
# configuration must live in the ROOT module (examples/lab/main.tf), not
# here — Terraform forbids child modules from declaring provider configs.
