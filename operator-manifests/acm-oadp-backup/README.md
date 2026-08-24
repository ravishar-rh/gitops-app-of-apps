# ACM Hub Cluster Backup with OADP on ROSA HCP (STS)

Configures backup and disaster recovery for a Red Hat Advanced Cluster Management (RHACM) hub cluster running on **ROSA HCP with AWS STS authentication**, using the cluster-backup-operator and OADP with S3 storage.

## Why OADP for ACM Backup?

ACM does not have a standalone backup mechanism. Instead, ACM's **cluster-backup-operator** integrates with OADP/Velero to automatically back up all hub cluster resources to S3-compatible storage. The high-level flow is:

1. **Install OADP** in the `open-cluster-management-backup` namespace (not `openshift-adp`)
2. **Enable the cluster-backup controller** via the `MultiClusterHub` CR
3. **Configure a `DataProtectionApplication`** with your S3 storage backend
4. **Create a `BackupSchedule`** to schedule ACM backups

In a disaster recovery scenario, a new hub cluster can be stood up and restored from the latest backup, reconnecting to all managed clusters.

## ROSA HCP + STS: What's Different

ROSA HCP clusters use **AWS Security Token Service (STS)** with OIDC-based web identity federation instead of static IAM credentials. Key implications:

- **OADP is not auto-installed** -- on STS clusters, the cluster-backup-operator cannot configure the IAM role automatically, so OADP must be manually installed in `open-cluster-management-backup`
- **Credentials use `role_arn` + `web_identity_token_file`** (IRSA) instead of static access keys
- **Node agent (Kopia/Restic), Data Mover, cross-region restore, and backup images are not supported** on ROSA HCP with STS
- **OADP requires `OwnNamespace` install mode** -- `AllNamespaces` is not supported

## Directory Structure

```
acm-oadp-backup/
├── kustomization.yaml              # Root: includes operator/ and config/
├── operator/
│   ├── kustomization.yaml
│   ├── namespace.yaml               # open-cluster-management-backup namespace
│   ├── operatorgroup.yaml           # OwnNamespace OperatorGroup
│   └── subscription.yaml            # OADP operator subscription
└── config/
    ├── kustomization.yaml
    ├── multiclusterhub-patch.yaml    # Enables cluster-backup component
    ├── credentials-secret.yaml       # ExternalSecret for STS credentials
    ├── dataprotectionapplication.yaml # DPA with aws + openshift plugins
    ├── backupschedule.yaml           # Every 6h, 30-day retention
    ├── restore.yaml                  # DR restore (commented out in kustomization)
    ├── iam-trust-policy.json         # IAM trust policy template
    └── iam-permissions-policy.json   # IAM permissions policy template
```

## Prerequisites

### 1. Create the IAM Role for OADP

```bash
export CLUSTER_NAME=<YOUR_CLUSTER_NAME>
export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .id)
export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ROLE_NAME="${CLUSTER_NAME}-acm-backup-oadp"

# Replace placeholders in the trust policy
sed -i.bak \
  -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<OIDC_ENDPOINT>|${OIDC_ENDPOINT}|g" \
  config/iam-trust-policy.json

# Create the IAM permissions policy
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_NAME}-policy" \
  --policy-document file://config/iam-permissions-policy.json \
  --query Policy.Arn --output text)

# Create the IAM role with the trust policy
ROLE_ARN=$(aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://config/iam-trust-policy.json \
  --tags Key=rosa_cluster_id,Value=${ROSA_CLUSTER_ID} \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"
```

### 2. Store the Role ARN in AWS Secrets Manager

The credential secret is managed via an ExternalSecret that syncs from AWS Secrets Manager. No plaintext credentials are stored in Git.

```bash
aws secretsmanager create-secret \
  --name oadp/acm-backup-credentials \
  --secret-string "{\"role_arn\": \"${ROLE_ARN}\"}"
```

### 3. Create the S3 Bucket

```bash
aws s3api create-bucket \
  --bucket <YOUR_S3_BUCKET> \
  --region <YOUR_AWS_REGION> \
  --create-bucket-configuration LocationConstraint=<YOUR_AWS_REGION>

aws s3api put-bucket-encryption \
  --bucket <YOUR_S3_BUCKET> \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": true}]
  }'

aws s3api put-public-access-block \
  --bucket <YOUR_S3_BUCKET> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket <YOUR_S3_BUCKET> \
  --versioning-configuration Status=Enabled
```

### 4. Replace Placeholders

| Placeholder | File | Description |
|---|---|---|
| `<YOUR_S3_BUCKET>` | `config/dataprotectionapplication.yaml` | Target S3 bucket name |
| `<YOUR_AWS_REGION>` | `config/dataprotectionapplication.yaml` | AWS region (e.g. `us-east-1`) |
| `<AWS_ACCOUNT_ID>` | `config/iam-trust-policy.json` | Your 12-digit AWS account ID |
| `<OIDC_ENDPOINT>` | `config/iam-trust-policy.json` | Cluster OIDC endpoint (without `https://`) |

## Deployment

### Via Kustomize / ArgoCD

```bash
oc apply -k acm-oadp-backup/
```

When using ArgoCD, ensure sync waves or health checks enforce ordering. The BackupSchedule will remain `Pending` until the DPA's BackupStorageLocation is `Available`.

### Step-by-step

```bash
# 1. Create namespace, OperatorGroup, and Subscription
oc apply -k acm-oadp-backup/operator/

# 2. Enable cluster-backup on MultiClusterHub
oc apply -f config/multiclusterhub-patch.yaml

# 3. Wait for OADP operator to be ready
oc wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=oadp-operator-controller-manager \
  -n open-cluster-management-backup --timeout=300s

# 4. Create credentials and DPA
oc apply -f config/credentials-secret.yaml
oc apply -f config/dataprotectionapplication.yaml

# 5. Wait for BackupStorageLocation to be Available
oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
  -n open-cluster-management-backup --timeout=120s

# 6. Create the backup schedule
oc apply -f config/backupschedule.yaml
```

## Verifying

```bash
# Check cluster-backup is enabled
oc get multiclusterhub -o jsonpath='{.items[0].spec.overrides.components}' \
  -n open-cluster-management | jq

# Verify OADP is installed in backup namespace
oc get csv -n open-cluster-management-backup | grep oadp

# Check DPA and BackupStorageLocation
oc get dpa -n open-cluster-management-backup
oc get backupstoragelocations -n open-cluster-management-backup

# Check BackupSchedule and Velero schedules
oc get backupschedule -n open-cluster-management-backup
oc get schedules -n open-cluster-management-backup

# List recent backups
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp' | tail -10
```

## Disaster Recovery

The `restore.yaml` is commented out in the kustomization and should only be applied during actual DR. To restore:

1. Provision a new ROSA HCP cluster in the **same AWS region**
2. Install ACM and enable `cluster-backup: true`
3. Create the IAM role with the **new cluster's OIDC endpoint**
4. Install OADP and create the DPA pointing to the **same S3 bucket**
5. Apply the restore: `oc apply -f config/restore.yaml`

For a passive/standby hub, set `veleroManagedClustersBackupName: skip` in the restore to sync data without activating managed clusters.

## ROSA HCP + STS Limitations

- **No Kopia/Restic** -- node agent (file-level backup) is not supported
- **No Data Mover** -- the Data Mover feature is not supported
- **No cross-region restore** -- must restore in the same AWS region
- **No backup images** -- ROSA HCP does not expose the internal image registry
- **OwnNamespace only** -- OADP does not support AllNamespaces install mode
- **IAM role per cluster** -- each cluster needs its own IAM role with its unique OIDC endpoint
