variable "restore_enabled" {
  description = "Set to true to trigger a restore from backup. Only use during disaster recovery."
  type        = bool
  default     = false
}

variable "restore_type" {
  description = "Type of restore: 'full' restores everything including managed clusters, 'passive' restores config only (no managed cluster activation)"
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "passive"], var.restore_type)
    error_message = "restore_type must be 'full' or 'passive'"
  }
}

variable "restore_backup_name" {
  description = "Specific backup name to restore from. Use 'latest' for the most recent backup."
  type        = string
  default     = "latest"
}

resource "kubernetes_manifest" "restore" {
  count = var.restore_enabled ? 1 : 0

  manifest = {
    apiVersion = "cluster.open-cluster-management.io/v1beta1"
    kind       = "Restore"
    metadata = {
      name      = "restore-acm"
      namespace = var.oadp_namespace
    }
    spec = {
      veleroManagedClustersBackupName = var.restore_type == "full" ? var.restore_backup_name : "skip"
      veleroCredentialsBackupName     = var.restore_backup_name
      veleroResourcesBackupName       = var.restore_backup_name
    }
  }

  depends_on = [null_resource.wait_for_bsl]
}

resource "null_resource" "wait_for_restore" {
  count = var.restore_enabled ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for restore to complete..."
      until oc get restore restore-acm -n ${var.oadp_namespace} \
        -o jsonpath='{.status.phase}' 2>/dev/null | grep -qE "Completed|FinishedWithErrors"; do
        sleep 15
        echo "  Restore status: $(oc get restore restore-acm -n ${var.oadp_namespace} -o jsonpath='{.status.phase}' 2>/dev/null || echo 'waiting')"
      done
      echo "Restore finished: $(oc get restore restore-acm -n ${var.oadp_namespace} -o jsonpath='{.status.phase}')"
    EOT
  }

  depends_on = [kubernetes_manifest.restore]
}
