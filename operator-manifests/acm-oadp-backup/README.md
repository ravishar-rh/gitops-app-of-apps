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

## End-to-End Backup Guide

This section walks through the complete process from initial setup to having scheduled backups running to S3.

### Phase 1: AWS Infrastructure Setup

#### 1.1 Set environment variables

```bash
export CLUSTER_NAME=<YOUR_CLUSTER_NAME>
export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .id)
export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ROLE_NAME="${CLUSTER_NAME}-acm-backup-oadp"
export S3_BUCKET="${CLUSTER_NAME}-acm-backup"
```

#### 1.2 Create the S3 bucket

```bash
aws s3api create-bucket \
  --bucket ${S3_BUCKET} \
  --region ${REGION} \
  --create-bucket-configuration LocationConstraint=${REGION}

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${S3_BUCKET} \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": true}]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket ${S3_BUCKET} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Enable versioning (required for backup integrity)
aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --versioning-configuration Status=Enabled
```

#### 1.3 Create the IAM role and policy

```bash
# Update the trust policy with your cluster's values
sed -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<OIDC_ENDPOINT>|${OIDC_ENDPOINT}|g" \
    config/iam-trust-policy.json > /tmp/trust-policy.json

# Create the permissions policy
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_NAME}-policy" \
  --policy-document file://config/iam-permissions-policy.json \
  --query Policy.Arn --output text)

# Create the role with the trust policy
ROLE_ARN=$(aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --tags Key=rosa_cluster_id,Value=${ROSA_CLUSTER_ID} \
  --query Role.Arn --output text)

# Attach the policy to the role
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"

echo "Role ARN: ${ROLE_ARN}"
```

#### 1.4 Store the role ARN in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name oadp/acm-backup-credentials \
  --secret-string "{\"role_arn\": \"${ROLE_ARN}\"}"
```

### Phase 2: Deploy the Operator and Configure Backups

#### 2.1 Update manifest placeholders

Edit `config/dataprotectionapplication.yaml` and replace:

| Placeholder | Replace with |
|---|---|
| `<YOUR_S3_BUCKET>` | Your S3 bucket name (e.g., `mycluster-acm-backup`) |
| `<YOUR_AWS_REGION>` | Your AWS region (e.g., `us-east-1`) |

#### 2.2 Deploy via ArgoCD (GitOps)

Commit and push the updated manifests. ArgoCD will deploy the operator, credentials, DPA, and backup schedule automatically.

If deploying manually:

```bash
# Step 1: Install the OADP operator
oc apply -k acm-oadp-backup/operator/

# Step 2: Wait for the operator to be ready
oc wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=oadp-operator-controller-manager \
  -n open-cluster-management-backup --timeout=300s

# Step 3: Deploy credentials and DPA
oc apply -f config/credentials-secret.yaml
oc apply -f config/dataprotectionapplication.yaml

# Step 4: Wait for BackupStorageLocation to become Available
oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
  -n open-cluster-management-backup --timeout=120s

# Step 5: Create the backup schedule
oc apply -f config/backupschedule.yaml
```

#### 2.3 Enable cluster-backup on MultiClusterHub

This must be done separately (cannot be managed by ArgoCD due to MCH webhook validation):

```bash
oc patch multiclusterhub multiclusterhub -n open-cluster-management \
  --type merge \
  -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'
```

Verify it's enabled:

```bash
oc get multiclusterhub multiclusterhub -n open-cluster-management \
  -o jsonpath='{.status.components.cluster-backup.status}{"\n"}'
```

### Phase 3: Verify Backups Are Running

#### 3.1 Check the backup chain

```bash
# Verify DPA is reconciled
oc get dpa -n open-cluster-management-backup
# Expected: dpa-acm   1.4.x   True

# Verify BackupStorageLocation is Available
oc get backupstoragelocations -n open-cluster-management-backup
# Expected: dpa-acm-1   Available

# Verify BackupSchedule is enabled
oc get backupschedule -n open-cluster-management-backup
# Expected: schedule-acm   Enabled

# Verify Velero schedules were created (ACM creates 3 sub-schedules)
oc get schedules -n open-cluster-management-backup
# Expected:
#   acm-credentials-schedule    ...
#   acm-managed-clusters-schedule  ...
#   acm-resources-schedule      ...
```

#### 3.2 Trigger a manual backup (optional)

To test without waiting for the schedule (every 6h), trigger a backup immediately:

```bash
# Create a one-time backup
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: manual-test-backup
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "*/2 * * * *"
  veleroTtl: 24h
  useManagedServiceAccount: true
EOF

# Wait 2-3 minutes for the backup to trigger, then check
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp'

# Clean up the manual schedule after verifying
oc delete backupschedule manual-test-backup -n open-cluster-management-backup
```

#### 3.3 Check backup status

```bash
# List all backups with status
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp' | tail -10

# Get details on a specific backup
oc describe backup <backup-name> -n open-cluster-management-backup

# Verify objects exist in S3
aws s3 ls s3://${S3_BUCKET}/acm-backup/ --recursive | head -20
```

#### 3.4 What gets backed up

ACM creates three Velero backups per schedule run:

| Backup | Contents |
|---|---|
| **acm-credentials-schedule** | Secrets, ConfigMaps used by managed clusters (credentials, pull secrets) |
| **acm-managed-clusters-schedule** | ManagedCluster, KlusterletAddonConfig, and related resources for each managed cluster |
| **acm-resources-schedule** | ACM hub resources: Policies, Placements, Applications, Channels, Subscriptions, Governance, Observability config |

All backups are stored under the `acm-backup/` prefix in your S3 bucket with a 30-day retention (`veleroTtl: 720h`).

## End-to-End Restore Guide

### Scenario: Disaster Recovery to a New Hub Cluster

Use this procedure when the original hub cluster is lost or you're migrating to a new hub. The restore reconnects all managed clusters to the new hub.

#### Step 1: Provision a new ROSA HCP cluster

```bash
rosa create cluster --cluster-name <NEW_CLUSTER_NAME> \
  --region ${REGION} --sts --mode auto
```

The new cluster **must** be in the **same AWS region** as the original (cross-region restore is not supported on ROSA HCP).

#### Step 2: Install ACM on the new hub

```bash
# Install the ACM operator (via your gitops manifests or manually)
oc apply -k acm-hub/operator/

# Wait for the operator
oc wait --for=condition=Available deployment \
  -l app=multiclusterhub-operator \
  -n open-cluster-management --timeout=600s

# Create the MultiClusterHub
oc apply -f acm-hub/multiclusterhub.yaml
```

#### Step 3: Create the IAM role for the new cluster

The new cluster has a **different OIDC endpoint**, so you need a new IAM role:

```bash
export NEW_CLUSTER_NAME=<NEW_CLUSTER_NAME>
export NEW_OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export NEW_ROLE_NAME="${NEW_CLUSTER_NAME}-acm-backup-oadp"

# Create trust policy with the new OIDC endpoint
sed -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<OIDC_ENDPOINT>|${NEW_OIDC_ENDPOINT}|g" \
    config/iam-trust-policy.json > /tmp/new-trust-policy.json

NEW_ROLE_ARN=$(aws iam create-role \
  --role-name "${NEW_ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/new-trust-policy.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${NEW_ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"

# Update Secrets Manager with the new role ARN
aws secretsmanager update-secret \
  --secret-id oadp/acm-backup-credentials \
  --secret-string "{\"role_arn\": \"${NEW_ROLE_ARN}\"}"
```

#### Step 4: Install OADP and point to the same S3 bucket

```bash
# Deploy the OADP operator
oc apply -k acm-oadp-backup/operator/

# Wait for operator
oc wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=oadp-operator-controller-manager \
  -n open-cluster-management-backup --timeout=300s

# Deploy credentials and DPA (same S3 bucket as the original hub)
oc apply -f config/credentials-secret.yaml
oc apply -f config/dataprotectionapplication.yaml

# Wait for BackupStorageLocation to discover existing backups
oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
  -n open-cluster-management-backup --timeout=120s
```

#### Step 5: Enable cluster-backup on the new hub

```bash
oc patch multiclusterhub multiclusterhub -n open-cluster-management \
  --type merge \
  -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'
```

#### Step 6: Verify existing backups are visible

```bash
# The new hub should see all backups from the S3 bucket
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp'

# Confirm there are backups for all 3 categories
oc get backups -n open-cluster-management-backup | grep -c credentials
oc get backups -n open-cluster-management-backup | grep -c managed-clusters
oc get backups -n open-cluster-management-backup | grep -c resources
```

#### Step 7: Apply the restore

```bash
# Restore from the latest backup
oc apply -f config/restore.yaml
```

This applies the [restore.yaml](config/restore.yaml) which restores the latest of all three backup types:

```yaml
spec:
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

#### Step 8: Monitor the restore

```bash
# Watch the restore status
oc get restore -n open-cluster-management-backup -w

# Check Velero restores created by the ACM restore controller
oc get restores.velero.io -n open-cluster-management-backup

# Watch for managed clusters to reconnect
oc get managedclusters -w
```

The restore typically completes in 5-15 minutes depending on the number of managed clusters and policies. Managed clusters will automatically reconnect to the new hub using the restored credentials.

#### Step 9: Verify the restore

```bash
# All managed clusters should show Available/Joined
oc get managedclusters
# Expected: each cluster shows True under HUBACCEPTED and AVAILABLE

# Verify policies are restored
oc get policies -A

# Verify applications
oc get applications.argoproj.io -A

# Verify governance
oc get placementrules -A
oc get placementbindings -A

# Re-enable the backup schedule on the new hub
oc apply -f config/backupschedule.yaml
```

### Scenario: Passive Standby Hub

For an active-passive hub configuration where you want to keep a standby hub in sync without activating managed clusters:

```bash
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-passive
  namespace: open-cluster-management-backup
spec:
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
EOF
```

Setting `veleroManagedClustersBackupName: skip` restores all ACM configuration (policies, apps, governance) but does **not** activate managed cluster connections. When you're ready to fail over, delete this restore and apply the full restore with `latest` for all three.

### Scenario: Restoring a Specific Backup (Not Latest)

```bash
# List available backups to find the one you want
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp'

# Apply a restore referencing specific backup names
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-specific
  namespace: open-cluster-management-backup
spec:
  veleroManagedClustersBackupName: acm-managed-clusters-schedule-20260825060000
  veleroCredentialsBackupName: acm-credentials-schedule-20260825060000
  veleroResourcesBackupName: acm-resources-schedule-20260825060000
EOF
```

## Troubleshooting

### BackupStorageLocation stuck in Unavailable

```bash
# Check the BSL status
oc describe backupstoragelocations -n open-cluster-management-backup

# Common causes:
# - IAM role ARN is wrong -> check the cloud-credentials secret
oc get secret cloud-credentials -n open-cluster-management-backup -o jsonpath='{.data.credentials}' | base64 -d

# - S3 bucket doesn't exist or wrong region -> verify
aws s3api head-bucket --bucket ${S3_BUCKET}

# - OIDC trust not configured for the correct service accounts -> check IAM role trust policy
aws iam get-role --role-name ${ROLE_NAME} --query Role.AssumeRolePolicyDocument
```

### Backups stuck in InProgress or FailedValidation

```bash
# Check Velero pod logs
oc logs -l app.kubernetes.io/name=velero -n open-cluster-management-backup --tail=50

# Check backup details
oc describe backup <backup-name> -n open-cluster-management-backup
```

### Managed clusters not reconnecting after restore

```bash
# Check klusterlet status on a managed cluster
oc get klusterlet -o yaml

# Verify the managed cluster credentials were restored
oc get secrets -n <managed-cluster-namespace> | grep -i credential

# Force re-import if needed
oc patch managedcluster <cluster-name> --type merge \
  -p '{"spec":{"hubAcceptsClient":true}}'
```

## ROSA HCP + STS Limitations

- **No Kopia/Restic** -- node agent (file-level backup) is not supported
- **No Data Mover** -- the Data Mover feature is not supported
- **No cross-region restore** -- must restore in the same AWS region
- **No backup images** -- ROSA HCP does not expose the internal image registry
- **OwnNamespace only** -- OADP does not support AllNamespaces install mode
- **IAM role per cluster** -- each cluster needs its own IAM role with its unique OIDC endpoint
