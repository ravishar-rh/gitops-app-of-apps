# ACM OADP Backup - Terraform Automation

Terraform automation for the AWS infrastructure required by ACM hub cluster backup on ROSA HCP with STS. Terraform manages the AWS side (S3, IAM, Secrets Manager), while ArgoCD deploys the Kubernetes resources (OADP operator, DPA, BackupSchedule) via the `operator-manifests/acm-oadp-backup/` manifests.

## What Terraform Manages

### AWS Resources

| Resource | Description |
|---|---|
| **S3 Bucket** | Encrypted, versioned bucket with public access blocked and lifecycle policies |
| **IAM Role** | OIDC-federated role for Velero/OADP service accounts |
| **IAM Policy** | S3 and EC2 permissions scoped to the backup bucket |
| **Secrets Manager Secret** | Stores the IAM role ARN for ExternalSecrets to sync |

### OpenShift (via `oc` CLI)

| Resource | Description |
|---|---|
| **MultiClusterHub patch** | Enables the cluster-backup component (optional) |
| **Restore** | Triggers an ACM restore during disaster recovery (optional) |

### What ArgoCD Manages (not Terraform)

The following are deployed by ArgoCD from the `operator-manifests/acm-oadp-backup/` directory:

- Namespace (`open-cluster-management-backup`)
- OperatorGroup and Subscription (OADP operator)
- ExternalSecret (syncs IAM role ARN from Secrets Manager)
- DataProtectionApplication (Velero config with S3 backend)
- BackupSchedule (every 6 hours, 30-day retention)

## Prerequisites

1. **AWS CLI** configured with credentials that can create IAM roles, S3 buckets, and Secrets Manager secrets
2. **oc CLI** logged in to the ROSA HCP cluster
3. **Terraform** >= 1.5.0
4. **ACM** already installed on the cluster (MultiClusterHub exists)
5. **ExternalSecrets Operator** installed with a `ClusterSecretStore` named `aws-secrets-manager`

## Quick Start - Backup Setup

### Step 1: Get your ROSA cluster name

```bash
rosa list clusters
```

Use the **NAME** column from the output. This is the name you specified when creating the cluster with `rosa create cluster`.

### Step 2: Get your cluster's OIDC endpoint

```bash
oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||'
```

### Step 3: Create your tfvars file

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

### Step 4: Apply

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Create the S3 bucket with encryption, versioning, and lifecycle policies
2. Create the IAM role and policy with OIDC trust for the cluster
3. Store the role ARN in Secrets Manager
4. Enable cluster-backup on the MultiClusterHub

ArgoCD will then automatically deploy the OADP operator and configure backups using the AWS resources Terraform created.

### Step 5: Verify

```bash
# Terraform prints verification commands in the output
terraform output verify_commands

# Or manually check
oc get dpa -n open-cluster-management-backup
oc get backupstoragelocations -n open-cluster-management-backup
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

# 2. Update terraform.tfvars with the new OIDC endpoint and enable restore
```

```hcl
oidc_endpoint   = "<new-oidc-endpoint>"
restore_enabled = true
restore_type    = "full"
```

```bash
# 3. Apply - creates AWS infra for new cluster and triggers restore
terraform init
terraform apply
```

Terraform creates the IAM role for the new cluster's OIDC endpoint, and ArgoCD deploys OADP pointing to the same S3 bucket. The restore reconnects managed clusters automatically.

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
| `acm_namespace` | No | `open-cluster-management` | ACM namespace |
| `enable_cluster_backup` | No | `true` | Enable cluster-backup on MCH |
| `tags` | No | `{}` | Additional AWS resource tags |
| `restore_enabled` | No | `false` | Trigger a restore |
| `restore_type` | No | `full` | `full` or `passive` restore |
| `restore_backup_name` | No | `latest` | Specific backup to restore |

## Teardown

To remove AWS resources (does **not** delete S3 bucket contents or OpenShift resources managed by ArgoCD):

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
