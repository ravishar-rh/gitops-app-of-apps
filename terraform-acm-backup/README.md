# ACM OADP Backup & Restore

End-to-end ACM hub cluster backup and restore for ROSA HCP with STS. Uses a split architecture: ArgoCD manages operator lifecycle and backup configuration via GitOps, Terraform manages AWS infrastructure.

## Architecture

### ArgoCD manages (via `operator-manifests/`)

| App | Resource | Sync Wave | Description |
|---|---|---|---|
| **acm-hub** | MultiClusterHub | — | `cluster-backup: true` creates namespace + OperatorGroup |
| **oadp-operator** | Subscription | 0 | OADP operator with `Automatic` install plan approval |
| **oadp-operator** | ExternalSecret | 5 | Syncs IAM role ARN from Secrets Manager to cluster secret |
| **oadp-operator** | DataProtectionApplication | 10 | Velero with aws + openshift plugins, S3 backend |
| **oadp-operator** | BackupSchedule | 15 | ACM backup every 6 hours, 30-day retention |

### Terraform manages (via `terraform-acm-backup/`)

| Resource | Description |
|---|---|
| **S3 Bucket** | Encrypted, versioned bucket with public access blocked and lifecycle policies |
| **IAM Role** | OIDC-federated role for Velero/OADP service accounts |
| **IAM Policy** | S3 and EC2 permissions scoped to the backup bucket |
| **Secrets Manager Secret** | Stores the IAM role ARN for ExternalSecrets to sync |

### What gets backed up

The ACM BackupSchedule creates 5 Velero backups every 6 hours:

| Backup | Contents |
|---|---|
| **acm-resources-schedule** | Policies, PlacementRules, Applications, Subscriptions, Channels, governance |
| **acm-resources-generic-schedule** | Generic ACM resources and configuration |
| **acm-credentials-schedule** | Secrets, ConfigMaps, provider connections, pull secrets, certificates |
| **acm-managed-clusters-schedule** | ManagedCluster resources, KlusterletAddonConfigs, auto-import secrets |
| **acm-validation-policy-schedule** | Backup validation policies |

## Prerequisites

1. **AWS CLI** configured with credentials that can create IAM roles, S3 buckets, and Secrets Manager secrets
2. **oc CLI** installed and logged in to the ROSA HCP cluster
3. **Terraform** >= 1.5.0
4. **ACM** already installed on the cluster (MultiClusterHub exists)
5. **ExternalSecrets Operator** installed with a `ClusterSecretStore` named `aws-secrets-manager`

## New Cluster Setup

### Step 1: Run Terraform for AWS infrastructure

```bash
rosa list clusters                    # Get your cluster name
oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||'  # Get OIDC endpoint
```

```bash
cd terraform-acm-backup
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name  = "my-rosa-cluster"
aws_region    = "us-east-2"
oidc_endpoint = "oidc.op1.openshiftapps.com/abc123xyz"
```

```bash
terraform init
terraform apply
```

This creates the S3 bucket, IAM role with OIDC trust, and Secrets Manager secret.

### Step 2: Apply app-of-apps

Once ArgoCD syncs, everything deploys automatically in order:

1. **acm-hub** syncs → MCH enables `cluster-backup`, creates `open-cluster-management-backup` namespace and OperatorGroup
2. **oadp-operator** syncs in wave order:
   - Wave 0: OADP Subscription → operator installs automatically
   - Wave 5: ExternalSecret → syncs IAM role ARN from Secrets Manager
   - Wave 10: DPA → configures Velero with S3 backend
   - Wave 15: BackupSchedule → backups start every 6 hours

No manual intervention required — backups start automatically.

### Step 3: Verify

```bash
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
# 3. Apply - updates IAM trust for new cluster and triggers restore
terraform apply
```

Or restore manually via `oc`:

```bash
cat <<YAML | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm
  namespace: open-cluster-management-backup
spec:
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
  cleanupBeforeRestore: CleanupRestored
YAML
```

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

### Monitoring Restore Progress

```bash
oc get restore -n open-cluster-management-backup -w
oc get restores.velero.io -n open-cluster-management-backup
oc get managedclusters -w
```

### cleanupBeforeRestore options

| Value | Behavior |
|---|---|
| `CleanupRestored` | Deletes only previously restored resources (recommended) |
| `CleanupAll` | Deletes all ACM resources before restoring |
| `None` | No cleanup, overlay restore on existing resources |

## Terraform Variables

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

## GitOps Configuration

The backup configuration lives in `operator-manifests/oadp-operator/`:

```
oadp-operator/
  subscription.yaml       # Wave 0  - OADP operator (Automatic approval)
  externalsecret.yaml      # Wave 5  - Syncs IAM credentials from Secrets Manager
  dpa.yaml                 # Wave 10 - DataProtectionApplication (S3 bucket, region)
  backupschedule.yaml      # Wave 15 - Backup schedule and retention
```

To customize for a different cluster, update `dpa.yaml` with your S3 bucket and region, and `externalsecret.yaml` with your Secrets Manager secret name.

## Troubleshooting

### Not logged in to the cluster

Terraform checks `oc whoami` as its first step. If you see:

```
ERROR: Not logged in to an OpenShift cluster.
```

Log in and re-run:

```bash
oc login --token=<token> --server=https://<api-server>:6443
terraform apply
```

### OADP CRD not found

If Terraform fails with `ERROR: OADP CRD not found`, the OADP operator hasn't installed yet. Check the subscription and CSV:

```bash
oc get subscription redhat-oadp-operator -n open-cluster-management-backup
oc get csv -n open-cluster-management-backup
```

### BackupStorageLocation Unavailable

If BSL shows `Unavailable`, check the Velero logs:

```bash
oc logs deployment/velero -n open-cluster-management-backup | tail -20
```

Common causes:
- **STS AssumeRoleWithWebIdentity AccessDenied**: The OIDC endpoint in `terraform.tfvars` doesn't match the cluster. Update `oidc_endpoint` and run `terraform apply`.
- **S3 bucket not found**: Run `terraform apply` to create the bucket.
- **Credentials not synced**: Check `oc get externalsecret cloud-credentials -n open-cluster-management-backup`.

### Multiple OperatorGroups error

If you see `csv created in namespace with multiple operatorgroups`:

```bash
oc get operatorgroup -n open-cluster-management-backup
```

Delete any extra OperatorGroup — MCH's `cluster-backup` creates one, and there should only be one per namespace:

```bash
oc delete operatorgroup <extra-name> -n open-cluster-management-backup
```

### Secrets Manager: secret already scheduled for deletion

After `terraform destroy`, Secrets Manager schedules a 7-day deletion window. To re-create immediately:

```bash
aws secretsmanager delete-secret \
  --secret-id oadp/acm-backup-credentials \
  --force-delete-without-recovery

terraform apply
```

Or restore and import:

```bash
aws secretsmanager restore-secret \
  --secret-id oadp/acm-backup-credentials

terraform import aws_secretsmanager_secret.oadp_credentials oadp/acm-backup-credentials
terraform apply
```

### ExternalSecret not syncing

```bash
oc get clustersecretstore aws-secrets-manager
oc get externalsecret cloud-credentials -n open-cluster-management-backup
aws secretsmanager get-secret-value --secret-id oadp/acm-backup-credentials
```

## Teardown

Remove Terraform-managed AWS resources:

```bash
terraform destroy
```

To also remove S3 bucket contents:

```bash
aws s3 rm s3://$(terraform output -raw s3_bucket_name) --recursive
terraform destroy
```

Remove ArgoCD-managed resources by deleting the manifests from git or removing the `oadp-operator` directory.

## State Management

For production, configure a remote backend:

```hcl
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "acm-oadp-backup/terraform.tfstate"
    region = "us-east-2"
  }
}
```

Add this to a `backend.tf` file before running `terraform init`.
