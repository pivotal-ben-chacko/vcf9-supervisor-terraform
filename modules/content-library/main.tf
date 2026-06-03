terraform {
  required_providers {
    vsphere = { source = "vmware/vsphere" }
  }
}

###############################################################
# Optional — subscribed content library for TKG workload clusters.
#
# This module is OFF by default; only instantiate it if you plan to
# spawn TKG workload clusters on top of the Supervisor (Path B from
# the runbook).
#
# Subscribes to VMware's public TKG content library, which publishes
# OVA templates of the kubeadm-based K8s nodes that Cluster API
# clones to provision workload clusters.
###############################################################

variable "datacenter_id" {}
variable "datastore_id" {
  description = "Datastore where the library's cached OVA blobs live. Use the nfs-shared datastore."
}
variable "library_name" {
  type    = string
  default = "tkg-content"
}
variable "subscription_url" {
  description = "TKG library subscription URL. Defaults to VMware's public catalog. Check vSphere release notes for current location."
  type        = string
  default     = "https://wp-content.vmware.com/v2/latest/lib.json"
}
variable "auto_sync" {
  description = "If true, library auto-syncs all items immediately. False saves disk space; on-demand pull when an item is referenced."
  type        = bool
  default     = false
}

resource "vsphere_content_library" "tkg" {
  name            = var.library_name
  description     = "Subscribed TKG content library for VKS workload clusters (managed by Terraform)"
  storage_backing = [var.datastore_id]

  subscription {
    subscription_url     = var.subscription_url
    authentication_method = "NONE"
    automatic_sync        = var.auto_sync
    on_demand             = !var.auto_sync
  }
}

output "library_id" {
  value = vsphere_content_library.tkg.id
}

output "library_name" {
  value = vsphere_content_library.tkg.name
}
