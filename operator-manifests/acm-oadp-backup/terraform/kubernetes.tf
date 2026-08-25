resource "null_resource" "enable_cluster_backup" {
  count = var.enable_cluster_backup ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      oc patch multiclusterhub multiclusterhub -n ${var.acm_namespace} \
        --type merge \
        -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'
    EOT
  }
}

resource "null_resource" "verify_deployment" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "AWS infrastructure is ready."
      echo ""
      echo "S3 Bucket:       ${aws_s3_bucket.acm_backup.id}"
      echo "IAM Role ARN:    ${aws_iam_role.oadp.arn}"
      echo "Secrets Manager: ${var.secrets_manager_secret_name}"
      echo ""
      echo "ArgoCD will deploy the OADP operator and configure backups."
      echo "Verify with:"
      echo "  oc get dpa -n ${var.oadp_namespace}"
      echo "  oc get backupstoragelocations -n ${var.oadp_namespace}"
      echo "  oc get backupschedule -n ${var.oadp_namespace}"
    EOT
  }

  depends_on = [
    aws_s3_bucket.acm_backup,
    aws_iam_role_policy_attachment.oadp,
    aws_secretsmanager_secret_version.oadp_credentials,
  ]
}
