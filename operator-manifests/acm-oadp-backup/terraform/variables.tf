variable "cluster_name" {
  description = "Name of the ROSA HCP cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region where the cluster and S3 bucket reside"
  type        = string
}

variable "oidc_endpoint" {
  description = "OIDC endpoint of the ROSA HCP cluster (without https://). Get it with: oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||'"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for ACM backups. Defaults to <cluster_name>-acm-backup"
  type        = string
  default     = ""
}

variable "s3_bucket_prefix" {
  description = "Prefix (folder) inside the S3 bucket for backup objects"
  type        = string
  default     = "acm-backup"
}

variable "backup_schedule" {
  description = "Cron schedule for ACM backups (Velero format)"
  type        = string
  default     = "0 */6 * * *"
}

variable "backup_ttl" {
  description = "Retention period for backups (Go duration format)"
  type        = string
  default     = "720h"
}

variable "secrets_manager_secret_name" {
  description = "Name of the AWS Secrets Manager secret for OADP credentials"
  type        = string
  default     = "oadp/acm-backup-credentials"
}

variable "oadp_namespace" {
  description = "Namespace where OADP is installed for ACM backup"
  type        = string
  default     = "open-cluster-management-backup"
}

variable "oadp_channel" {
  description = "OLM channel for the OADP operator subscription"
  type        = string
  default     = "stable-1.4"
}

variable "acm_namespace" {
  description = "Namespace where ACM is installed"
  type        = string
  default     = "open-cluster-management"
}

variable "enable_cluster_backup" {
  description = "Whether to enable the cluster-backup component on MultiClusterHub"
  type        = bool
  default     = true
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file. If empty, uses the default KUBECONFIG env var or ~/.kube/config"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}
