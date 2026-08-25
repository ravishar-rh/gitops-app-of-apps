# ACM OADP Backup - Terraform Automation

Terraform automation for end-to-end ACM hub cluster backup and restore on ROSA HCP with STS. A single `terraform apply` creates all AWS infrastructure, installs the OADP operator, configures backups to S3, and enables the ACM cluster-backup component.

## What Terraform Creates

### AWS Resources

| Resource | Description |
|---|---|
| **S3 Bucket** | Encrypted, versioned bucket with public access blocked and lifecycle policies |
| **IAM Role** | OIDC-federated role for Velero/OADP service accounts |
| **IAM Policy** | S3 and EC2 permissions scoped to the backup bucket |
| **Secrets Manager Secret** | Stores the IAM role ARN for ExternalSecrets to sync |

### OpenShift Resources

| Resource | Description |
|---|---|
| **Namespace** | `open-cluster-management-backup` |
| **OperatorGroup** | OwnNamespace install mode |
| **Subscription** | OADP operator from redhat-operators catalog |
| **ExternalSecret** | Syncs IAM role ARN from Secrets Manager to a Kubernetes secret |
| **DataProtectionApplication** | Velero config with aws + openshift plugins, S3 backend |
| **BackupSchedule** | ACM backup every 6 hours, 30-day retention |
| **MultiClusterHub patch** | Enables the cluster-backup component |

## Prerequisites

1. **AWS CLI** configured with credentials that can create IAM roles, S3 buckets, and Secrets Manager secrets
2. **oc CLI** logged in to the ROSA HCP cluster
3. **Terraform** >= 1.5.0
4. **ACM** already installed on the cluster (MultiClusterHub exists)
5. **ExternalSecrets Operator** installed with a `ClusterSecretStore` named `aws-secrets-manager`

## Quick Start - Backup Setup

### Step 1: Get your cluster's OIDC endpoint

```bash
oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||'
```

### Step 2: Create your tfvars file

```bash
cd acm-oadp-backup/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
cluster_name  = "my-rosa-cluster"
aws_region    = "us-east-1"
oidc_endpoint = "rh-oidc.s3.us-east-1.amazonaws.com/abc123xyz"
```

### Step 3: Apply

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Create the S3 bucket with encryption, versioning, and lifecycle policies
2. Create the IAM role and policy with OIDC trust for the cluster
3. Store the role ARN in Secrets Manager
4. Create the OADP namespace, OperatorGroup, and Subscription
5. Wait for the OADP operator to become ready
6. Create the ExternalSecret and DataProtectionApplication
7. Wait for the BackupStorageLocation to become Available
8. Create the BackupSchedule
9. Enable cluster-backup on the MultiClusterHub

### Step 4: Verify

```bash
# Terraform prints verification commands in the output
terraform output verify_commands

# Or manually check
oc get backupschedule -n open-cluster-management-backup
oc get backups -n open-cluster-management-backup
```

## Disaster Recovery - Restore

### Full Restore (all managed clusters reconnect)

On the **new** hub cluster:

```bash
# 1. Get the new cluster's OIDC endpoint
NEW_OIDC=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')

# 2. Update terraform.tfvars
cat >> terraform.tfvars <<EOF
oidc_endpoint   = "${NEW_OIDC}"
restore_enabled = true
restore_type    = "full"
EOF

# 3. Apply - this installs OADP, points to the same S3 bucket, and triggers restore
terraform init
terraform apply
```

Terraform will install OADP on the new cluster, connect to the existing S3 bucket, discover the backups, and apply the restore. Managed clusters will reconnect automatically.

### Passive Standby (sync config only, no managed cluster activation)

```hcl
restore_enabled = true
restore_type    = "passive"
```

This restores all ACM configuration (policies, apps, governance) but skips managed cluster connections. To fail over later, change `restore_type` to `full` and re-apply.

### Restore a Specific Backup

```hcl
restore_enabled     = true
restore_type        = "full"
restore_backup_name = "acm-managed-clusters-schedule-20260825060000"
```

List available backups:

```bash
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp'
```

## Monitoring Restore Progress

```bash
# Watch restore status
oc get restore -n open-cluster-management-backup -w

# Check Velero restores
oc get restores.velero.io -n open-cluster-management-backup

# Watch managed clusters reconnect
oc get managedclusters -w
```

## Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `cluster_name` | Yes | - | ROSA HCP cluster name |
| `aws_region` | Yes | - | AWS region |
| `oidc_endpoint` | Yes | - | Cluster OIDC endpoint (without `https://`) |
| `s3_bucket_name` | No | `<cluster_name>-acm-backup` | S3 bucket name |
| `s3_bucket_prefix` | No | `acm-backup` | S3 key prefix for backups |
| `backup_schedule` | No | `0 */6 * * *` | Backup cron schedule |
| `backup_ttl` | No | `720h` | Backup retention (30 days) |
| `secrets_manager_secret_name` | No | `oadp/acm-backup-credentials` | Secrets Manager secret name |
| `oadp_namespace` | No | `open-cluster-management-backup` | OADP namespace |
| `oadp_channel` | No | `stable-1.4` | OLM subscription channel |
| `acm_namespace` | No | `open-cluster-management` | ACM namespace |
| `enable_cluster_backup` | No | `true` | Enable cluster-backup on MCH |
| `kubeconfig_path` | No | `""` (uses default) | Path to kubeconfig |
| `tags` | No | `{}` | Additional AWS resource tags |
| `restore_enabled` | No | `false` | Trigger a restore |
| `restore_type` | No | `full` | `full` or `passive` restore |
| `restore_backup_name` | No | `latest` | Specific backup to restore |

## Teardown

To remove all resources (does **not** delete the S3 bucket contents):

```bash
terraform destroy
```

To also remove the S3 bucket contents:

```bash
aws s3 rm s3://$(terraform output -raw s3_bucket_name) --recursive
terraform destroy
```

## State Management

For production use, configure a remote backend for Terraform state:

```hcl
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "acm-oadp-backup/terraform.tfstate"
    region = "us-east-1"
  }
}
```

Add this to a `backend.tf` file before running `terraform init`.
