output "s3_bucket_name" {
  description = "Name of the S3 bucket used for ACM backups"
  value       = aws_s3_bucket.acm_backup.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.acm_backup.arn
}

output "iam_role_arn" {
  description = "ARN of the IAM role used by OADP/Velero"
  value       = aws_iam_role.oadp.arn
}

output "iam_role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.oadp.name
}

output "iam_policy_arn" {
  description = "ARN of the IAM policy attached to the OADP role"
  value       = aws_iam_policy.oadp.arn
}

output "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the role ARN"
  value       = aws_secretsmanager_secret.oadp_credentials.arn
}

output "oadp_namespace" {
  description = "Namespace where OADP is installed"
  value       = var.oadp_namespace
}

output "backup_schedule" {
  description = "Backup schedule in cron format"
  value       = var.backup_schedule
}

output "backup_ttl" {
  description = "Backup retention period"
  value       = var.backup_ttl
}

output "verify_commands" {
  description = "Commands to verify the backup setup"
  value       = <<-EOT

    # Verify OADP operator
    oc get csv -n ${var.oadp_namespace} | grep oadp

    # Verify DPA and BackupStorageLocation
    oc get dpa -n ${var.oadp_namespace}
    oc get backupstoragelocations -n ${var.oadp_namespace}

    # Verify BackupSchedule
    oc get backupschedule -n ${var.oadp_namespace}
    oc get schedules -n ${var.oadp_namespace}

    # List recent backups
    oc get backups -n ${var.oadp_namespace} --sort-by='.metadata.creationTimestamp' | tail -10

    # Verify S3 objects
    aws s3 ls s3://${aws_s3_bucket.acm_backup.id}/${var.s3_bucket_prefix}/ --recursive | head -20

  EOT
}
