# ACM OADP Backup - Terraform Automation

Terraform automation for ACM hub cluster backup and restore on ROSA HCP with STS. ArgoCD manages operator installation (OADP + MCH cluster-backup), Terraform manages AWS infrastructure and backup configuration.

## Architecture

### ArgoCD manages (via `operator-manifests/`)

| App | Resources |
|---|---|
| **acm-hub** | MultiClusterHub with `cluster-backup: true` (creates namespace + OperatorGroup) |
| **oadp-operator** | OADP Subscription with `Manual` install plan approval |

### Terraform manages

| Resource | Description |
|---|---|
| **S3 Bucket** | Encrypted, versioned bucket with public access blocked and lifecycle policies |
| **IAM Role** | OIDC-federated role for Velero/OADP service accounts |
| **IAM Policy** | S3 and EC2 permissions scoped to the backup bucket |
| **Secrets Manager Secret** | Stores the IAM role ARN for ExternalSecrets to sync |
| **ExternalSecret** | Syncs IAM role ARN from Secrets Manager to a Kubernetes secret |
| **DataProtectionApplication** | Velero config with aws + openshift plugins, S3 backend |
| **BackupSchedule** | ACM backup every 6 hours, 30-day retention |
| **Restore** | Triggers an ACM restore during disaster recovery (optional) |

## Prerequisites

1. **AWS CLI** configured with credentials that can create IAM roles, S3 buckets, and Secrets Manager secrets
2. **oc CLI** installed and logged in to the ROSA HCP cluster
3. **Terraform** >= 1.5.0
4. **ACM** already installed on the cluster (MultiClusterHub exists)
5. **ExternalSecrets Operator** installed with a `ClusterSecretStore` named `aws-secrets-manager`
6. **OADP operator installed and running** (deployed by ArgoCD from `operator-manifests/oadp-operator/`)

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
cd terraform-acm-backup
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
cluster_name  = "my-rosa-cluster"
aws_region    = "us-east-1"
oidc_endpoint = "rh-oidc.s3.us-east-1.amazonaws.com/abc123xyz"
```

### Step 4: Deploy OADP operator via ArgoCD

Ensure the ArgoCD applications are synced:

1. **acm-hub** — syncs `multiclusterhub.yaml` with `cluster-backup: true`, which creates the `open-cluster-management-backup` namespace and OperatorGroup
2. **oadp-operator** — syncs the OADP Subscription with `Manual` approval

Approve the first OADP install plan:

```bash
# Find the install plan
oc get installplan -n open-cluster-management-backup

# Approve it
oc patch installplan <install-plan-name> -n open-cluster-management-backup \
  --type merge -p '{"spec":{"approved":true}}'

# Wait for the operator to be ready
oc get csv -n open-cluster-management-backup -w
```

### Step 5: Apply Terraform

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Verify you are logged in to the cluster (`oc whoami`)
2. Verify OADP operator is installed and ready
3. Create the S3 bucket with encryption, versioning, and lifecycle policies
4. Create the IAM role and policy with OIDC trust for the cluster
5. Store the role ARN in Secrets Manager
6. Create the ExternalSecret to sync credentials from Secrets Manager
7. Create the DataProtectionApplication with your S3 bucket and region
8. Wait for the BackupStorageLocation to become Available
9. Create the BackupSchedule

### Step 6: Verify

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
| `tags` | No | `{}` | Additional AWS resource tags |
| `restore_enabled` | No | `false` | Trigger a restore |
| `restore_type` | No | `full` | `full` or `passive` restore |
| `restore_backup_name` | No | `latest` | Specific backup to restore |

## Troubleshooting

### Not logged in to the cluster

Terraform checks `oc whoami` as its first step. If you see:

```
ERROR: Not logged in to an OpenShift cluster.
Run 'oc login' before running terraform apply.
```

Log in and re-run:

```bash
oc login --token=<token> --server=https://<api-server>:6443
terraform apply
```

### OADP CRD not found

If Terraform fails with `ERROR: OADP CRD not found`, the OADP operator hasn't been installed yet:

```bash
# Check the subscription exists
oc get subscription redhat-oadp-operator -n open-cluster-management-backup

# Check for pending install plans (Manual approval required)
oc get installplan -n open-cluster-management-backup

# Approve the install plan
oc patch installplan <name> -n open-cluster-management-backup \
  --type merge -p '{"spec":{"approved":true}}'
```

### Secrets Manager: secret already scheduled for deletion

If you previously ran `terraform destroy` and then re-run `terraform apply`, you may see:

```
InvalidRequestException: You can't create this secret because a secret
with this name is already scheduled for deletion.
```

Secrets Manager has a 7-day recovery window by default. To fix this, either force delete and re-apply, or restore and import:

**Option A: Force delete and re-create**

```bash
aws secretsmanager delete-secret \
  --secret-id oadp/acm-backup-credentials \
  --force-delete-without-recovery

terraform apply
```

**Option B: Restore and import into Terraform state**

```bash
aws secretsmanager restore-secret \
  --secret-id oadp/acm-backup-credentials

terraform import aws_secretsmanager_secret.oadp_credentials oadp/acm-backup-credentials
terraform apply
```

### S3 bucket already exists

If the S3 bucket was created outside of Terraform or from a previous run:

```bash
terraform import aws_s3_bucket.acm_backup <bucket-name>
terraform apply
```

### IAM role already exists

```bash
terraform import aws_iam_role.oadp <role-name>
terraform import aws_iam_policy.oadp <policy-arn>
terraform apply
```

### ExternalSecret not syncing

Verify the `ClusterSecretStore` named `aws-secrets-manager` exists and is healthy:

```bash
oc get clustersecretstore aws-secrets-manager
oc get externalsecret cloud-credentials -n open-cluster-management-backup
```

If the ExternalSecret shows `SecretSyncedError`, check that the Secrets Manager secret exists:

```bash
aws secretsmanager get-secret-value --secret-id oadp/acm-backup-credentials
```

## Teardown

To remove all resources (AWS + OpenShift):

```bash
terraform destroy
```

To also remove the S3 bucket contents:

```bash
aws s3 rm s3://$(terraform output -raw s3_bucket_name) --recursive
terraform destroy
```

**Note:** `terraform destroy` schedules the Secrets Manager secret for deletion with a 7-day recovery window. If you need to re-create it immediately, use the force delete command from the troubleshooting section above.

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
