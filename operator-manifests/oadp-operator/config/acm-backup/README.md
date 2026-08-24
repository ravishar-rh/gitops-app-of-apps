# ACM Hub Cluster Backup with OADP on ROSA HCP (STS)

Configures backup and disaster recovery for a Red Hat Advanced Cluster Management (RHACM) hub cluster running on **ROSA HCP with AWS STS authentication**, using the cluster-backup-operator and OADP with S3 storage.

## What is ACM Backup?

Red Hat Advanced Cluster Management (ACM) manages a fleet of OpenShift clusters from a central **hub cluster**. The hub holds critical data: managed cluster registrations, policies, applications, placements, credentials, and governance configurations. Losing the hub without a backup means manually re-importing and reconfiguring every managed cluster.

ACM's **cluster-backup-operator** solves this by integrating with OADP/Velero to automatically back up all hub cluster resources to S3-compatible storage. In a disaster recovery scenario, a new hub cluster can be stood up and restored from the latest backup, reconnecting to all managed clusters.

## ROSA HCP + STS: What's Different

ROSA HCP clusters use **AWS Security Token Service (STS)** with OIDC-based web identity federation instead of static IAM credentials. This has significant implications for OADP:

| Aspect | Standard OCP | ROSA HCP (STS) |
|---|---|---|
| OADP installation by ACM | Auto-installed by cluster-backup-operator | **Not auto-installed** -- must be manually installed |
| Credential type | Static `aws_access_key_id` + `aws_secret_access_key` | `role_arn` + `web_identity_token_file` (IRSA) |
| IAM setup | Create IAM user with access keys | Create IAM role with OIDC trust policy |
| Node agent (Kopia/Restic) | Supported | **Not supported** |
| Data Mover | Supported | **Not supported** |
| Cross-region restore | Supported | **Not supported** |
| Volume backup method | CSI snapshots, native snapshots, Kopia | CSI snapshots and native snapshots **only** |
| Backup images | Supported | **Not supported** (no internal registry on ROSA HCP) |

### Why OADP Is Not Auto-Installed on STS

On non-STS clusters, enabling `cluster-backup: true` on the MultiClusterHub causes the cluster-backup-operator to automatically install OADP in `open-cluster-management-backup`. On STS clusters, the operator **cannot** configure the IAM role automatically, so it creates a ConfigMap (`acm-redhat-oadp-operator-subscription`) with the OADP channel and version details, and waits for OADP to become available. ACM requires the OADP operator to be installed **in** `open-cluster-management-backup`. OADP only supports OwnNamespace (AllNamespaces is not supported), so this directory includes its own OperatorGroup and Subscription. Use the same `stable` channel as `operator/` so CRD versions match.

### How STS Authentication Works

1. An IAM role is created with a **trust policy** that allows the cluster's OIDC provider to assume it
2. The trust policy restricts access to specific Kubernetes service accounts (`openshift-adp-controller-manager` and `velero` in the backup namespace)
3. The OADP credential secret contains the `role_arn` and a path to the projected service account token
4. Every hour, ROSA generates a new token. The AWS SDK reads the mounted secret, finds the token path and role ARN, and calls `sts:AssumeRoleWithWebIdentity` to get temporary credentials
5. No long-lived AWS credentials exist anywhere in the cluster

## Key Concepts

### Cluster Backup Operator

The **cluster-backup-operator** is an ACM component (not installed by default) that orchestrates hub cluster backups. When enabled, it:

1. Uses the `open-cluster-management-backup` namespace (created by our manifests or by ACM itself)
2. On STS clusters: creates a ConfigMap (`acm-redhat-oadp-operator-subscription`) with OADP channel and version details, but does **not** auto-install OADP -- this directory installs OADP in `open-cluster-management-backup` with an OwnNamespace OperatorGroup
3. Watches for `BackupSchedule` resources and translates them into Velero schedules
4. Manages backup collision detection across multiple hub clusters
5. Handles the restore lifecycle including managed cluster re-activation

The operator is enabled by setting `cluster-backup: true` on the `MultiClusterHub` resource.

### OADP Operator in the Backup Namespace

OADP only supports **OwnNamespace** (`AllNamespaces` is not supported in the CSV). ACM also checks that the OADP operator is installed **in** `open-cluster-management-backup`, so this directory deploys a second OADP OperatorGroup and Subscription there. Both subscriptions use the `stable` channel so CRD versions stay aligned.

The `DataProtectionApplication` for ACM backup is created in `open-cluster-management-backup`, keeping its Velero instance and backup data isolated from any general-purpose DPA in `openshift-adp`.

### BackupSchedule

The `BackupSchedule` is an ACM-specific CRD (`cluster.open-cluster-management.io/v1beta1`) -- not a standard Velero Schedule. When you create a BackupSchedule, the cluster-backup-operator automatically generates **four Velero schedules**:

| Velero Schedule | What It Backs Up |
|---|---|
| `acm-credentials-schedule` | Hub credentials, cloud provider secrets, Git repo secrets, managed cluster access tokens |
| `acm-managed-clusters-schedule` | ManagedCluster resources, KlusterletAddonConfig, cluster pools, Hive ClusterDeployments |
| `acm-resources-schedule` | Applications, Subscriptions, Channels, Policies, PlacementRules, Placements, PolicySets |
| `acm-resources-generic-schedule` | ConfigMaps and other generic resources labeled for backup inclusion |

These are split into separate schedules so they can be restored independently during DR scenarios.

### BackupSchedule Properties

| Property | Required | Description |
|---|---|---|
| `veleroSchedule` | Yes | Cron expression for backup frequency (e.g., `0 */6 * * *` for every 6 hours) |
| `veleroTtl` | No | Backup retention period (default: `720h` / 30 days) |
| `useManagedServiceAccount` | No | When `true`, creates ManagedServiceAccount tokens for managed cluster authentication during restore |
| `managedServiceAccountTTL` | No | TTL for generated service account tokens (default matches `veleroTtl`). Use with caution -- short TTLs may cause tokens to expire before restore |
| `paused` | No | When `true`, pauses the backup schedule and deletes all Velero schedules created by it |

### Restore

The `Restore` resource (`cluster.open-cluster-management.io/v1beta1`) controls how backups are applied to a new hub cluster. It has three independently controllable backup streams:

| Property | Values | Purpose |
|---|---|---|
| `veleroCredentialsBackupName` | `latest`, `skip`, or specific backup name | Restore credentials and secrets |
| `veleroResourcesBackupName` | `latest`, `skip`, or specific backup name | Restore applications, policies, and configurations |
| `veleroManagedClustersBackupName` | `latest`, `skip`, or specific backup name | Restore and **activate** managed cluster connections |

Setting `veleroManagedClustersBackupName` to `latest` is a **one-way operation** -- it activates managed clusters on this hub, making it the primary. The original hub should stop its BackupSchedule to avoid backup collisions.

### Active vs Passive Hub

ACM supports two DR patterns:

- **Active-Passive** -- one hub actively manages clusters, the other syncs backup data passively. Set `veleroManagedClustersBackupName: skip` on the passive hub to keep it in standby. When the active hub fails, change to `latest` to promote the passive hub.

- **Backup-Only** -- a single hub runs scheduled backups. If it fails, a new hub is provisioned and restored from the latest backup. Simpler but has longer recovery time.

### Backup Collision Detection

If multiple hub clusters write backups to the same S3 location, the operator detects a **BackupCollision** state. This prevents a demoted hub from overwriting backups created by the new primary hub. Always ensure only one hub has an active (non-paused) BackupSchedule at any time.

### ManagedServiceAccount

When `useManagedServiceAccount: true`, the operator creates short-lived service account tokens for each managed cluster. These tokens allow the restored hub to authenticate with managed clusters without requiring the original hub's service account secrets. This is the recommended approach for production DR.

### What Gets Backed Up vs What Doesn't

**Backed up:**
- Managed cluster definitions and registration data
- Applications, Subscriptions, Channels, PlacementRules
- Policies, PolicySets, PlacementBindings
- Credentials (cloud providers, Git repos, image registries)
- Observability configuration
- Governance and compliance data
- Bare metal assets

**Not backed up (must be reinstalled on new hub):**
- ACM operator itself
- MultiClusterHub and MultiClusterEngine resources
- Other operators (Ansible Automation Platform, OpenShift GitOps, cert-manager, etc.)
- Cluster-scoped custom resources not labeled for backup

### Managed Cluster Reconnection

After restore, managed cluster behavior depends on how they were created:

| Creation Method | Behavior After Restore |
|---|---|
| **Hive API** (ClusterDeployment) | Automatically reconnects to new hub |
| **Manual import** | Enters `Pending Import` state -- must be manually re-imported |
| **ROSA / ARO / managed services** | Must be manually re-imported |

## Compatibility

| Component | Version |
|---|---|
| OpenShift | 4.22 (ROSA HCP) |
| RHACM | 2.17 |
| OADP | 1.6.x (stable-1.6 channel) |
| Authentication | AWS STS (OIDC + IRSA) |
| Cluster Backup Operator | Installed via MultiClusterHub |
| Namespace | `open-cluster-management-backup` |

## Manifests

| File | Resource | Description |
|---|---|---|
| `multiclusterhub-patch.yaml` | MultiClusterHub | Enables the `cluster-backup` component |
| `oadp-subscription.yaml` | Namespace | Creates `open-cluster-management-backup` namespace |
| `credentials-secret.yaml` | ExternalSecret | STS credentials (`role_arn` + `web_identity_token_file`) synced from AWS Secrets Manager |
| `dataprotectionapplication.yaml` | DataProtectionApplication | DPA with `openshift` + `aws` plugins, node agent and Data Mover disabled |
| `backupschedule.yaml` | BackupSchedule | Every 6 hours, 30-day retention, ManagedServiceAccount enabled |
| `restore.yaml` | Restore | Full restore from latest backup (for DR only, commented out) |
| `iam-trust-policy.json` | IAM Trust Policy template | OIDC federation trust policy for the OADP IAM role |
| `iam-permissions-policy.json` | IAM Permissions Policy template | S3 + EC2 permissions required by Velero |

## Prerequisites

### 1. Create the IAM Role for OADP

ROSA HCP uses STS, so OADP authenticates via an IAM role assumed through OIDC federation. You must create this role before deploying.

#### Get cluster details

```bash
export CLUSTER_NAME=<YOUR_CLUSTER_NAME>
export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .id)
export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ROLE_NAME="${CLUSTER_NAME}-acm-backup-oadp"
```

#### Create the IAM permissions policy

The policy grants S3 access for backup storage and EC2 access for volume snapshots. Use the template in `iam-permissions-policy.json`:

```bash
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_NAME}-policy" \
  --policy-document file://iam-permissions-policy.json \
  --query Policy.Arn --output text)
```

#### Create the trust policy

Replace placeholders in `iam-trust-policy.json` with your actual values:

```bash
sed -i.bak \
  -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<OIDC_ENDPOINT>|${OIDC_ENDPOINT}|g" \
  iam-trust-policy.json
```

#### Create the IAM role

```bash
ROLE_ARN=$(aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://iam-trust-policy.json \
  --tags Key=rosa_cluster_id,Value=${ROSA_CLUSTER_ID} Key=rosa_openshift_version,Value=4.22 Key=operator_namespace,Value=open-cluster-management-backup Key=operator_name,Value=openshift-oadp \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"

echo "Role ARN: ${ROLE_ARN}"
```

### 2. Store the Role ARN in AWS Secrets Manager

The credential secret is managed via an **ExternalSecret** that syncs from AWS Secrets Manager using the `aws-secrets-manager` ClusterSecretStore. No plaintext credentials are stored in Git.

Create the following secret in AWS Secrets Manager:

- **Secret name:** `oadp/acm-backup-credentials`
- **Secret value (JSON):**

```json
{
  "role_arn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/<CLUSTER_NAME>-acm-backup-oadp"
}
```

```bash
aws secretsmanager create-secret \
  --name oadp/acm-backup-credentials \
  --secret-string "{\"role_arn\": \"${ROLE_ARN}\"}"
```

The ExternalSecret templates this into the INI credential format that OADP/Velero expects:

```ini
[default]
role_arn = arn:aws:iam::123456789012:role/my-cluster-acm-backup-oadp
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
```

The `web_identity_token_file` points to the projected service account token that ROSA mounts into pods. This token is rotated automatically by ROSA every hour.

### 3. Create the S3 Bucket

```bash
aws s3api create-bucket \
  --bucket <YOUR_S3_BUCKET> \
  --region <YOUR_AWS_REGION> \
  --create-bucket-configuration LocationConstraint=<YOUR_AWS_REGION>

# Enable server-side encryption (strongly recommended -- backups contain cluster credentials)
aws s3api put-bucket-encryption \
  --bucket <YOUR_S3_BUCKET> \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": true}]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket <YOUR_S3_BUCKET> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Enable versioning (recommended for backup integrity)
aws s3api put-bucket-versioning \
  --bucket <YOUR_S3_BUCKET> \
  --versioning-configuration Status=Enabled
```

### 4. Replace Placeholders

| Placeholder | File | Description |
|---|---|---|
| `<YOUR_S3_BUCKET>` | `dataprotectionapplication.yaml` | Target S3 bucket name |
| `<YOUR_AWS_REGION>` | `dataprotectionapplication.yaml` | AWS region (e.g. `us-east-1`) |
| `<AWS_ACCOUNT_ID>` | `iam-trust-policy.json` | Your 12-digit AWS account ID |
| `<OIDC_ENDPOINT>` | `iam-trust-policy.json` | Cluster OIDC endpoint (without `https://`) |

## Deployment

### Step-by-step

```bash
# Step 1: Ensure the general-purpose OADP operator is installed (from operator/ directory)
oc apply -k oadp-operator/operator/

# Step 2: Create the backup namespace, OADP OwnNamespace install, and enable cluster-backup
oc apply -f oadp-subscription.yaml
oc apply -f operatorgroup.yaml
oc apply -f subscription.yaml
oc apply -f multiclusterhub-patch.yaml

# Step 3: Wait for the OADP operator to be ready in the backup namespace
oc wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=oadp-operator-controller-manager \
  -n open-cluster-management-backup --timeout=300s

# Step 4: Create ExternalSecret (syncs role_arn from AWS Secrets Manager)
oc apply -f credentials-secret.yaml

# Step 4a: Verify the secret synced from AWS Secrets Manager
oc wait --for=condition=SecretSynced externalsecret/cloud-credentials \
  -n open-cluster-management-backup --timeout=60s

# Step 5: Create the DataProtectionApplication
oc apply -f dataprotectionapplication.yaml

# Step 6: Wait for BackupStorageLocation to be Available
oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
  -n open-cluster-management-backup --timeout=120s

# Step 7: Create the backup schedule
oc apply -f backupschedule.yaml
```

### Via Kustomize

```bash
oc apply -k oadp-operator/config/acm-backup/
```

**Note:** When using Kustomize/ArgoCD, ensure sync waves or health checks enforce ordering. The BackupSchedule will remain `Pending` until the DPA's BackupStorageLocation is `Available`.

## Verifying ACM Backup

```bash
# Check cluster-backup component is enabled
oc get multiclusterhub -o jsonpath='{.items[0].spec.overrides.components}' \
  -n open-cluster-management | jq

# Verify OADP is installed in the backup namespace
oc get csv -n open-cluster-management-backup | grep oadp

# Check the ExternalSecret synced the credentials
oc get externalsecret cloud-credentials -n open-cluster-management-backup
oc get secret cloud-credentials -n open-cluster-management-backup -o jsonpath='{.data.credentials}' | base64 -d

# Verify DPA is reconciled
oc get dpa -n open-cluster-management-backup

# Check backup storage location is Available
oc get backupstoragelocations -n open-cluster-management-backup

# Check BackupSchedule status
oc get backupschedule -n open-cluster-management-backup

# Verify the 4 Velero schedules were created
oc get schedules -n open-cluster-management-backup

# List recent backups
oc get backups -n open-cluster-management-backup \
  --sort-by='.metadata.creationTimestamp' | tail -10

# Check for backup collisions
oc get backupschedule -n open-cluster-management-backup \
  -o jsonpath='{.items[0].status.phase}'
```

Expected `BackupSchedule` phase should be `Enabled` (not `BackupCollision` or `Failed`).

## Disaster Recovery: Restoring to a New Hub

The `restore.yaml` is **commented out** in the kustomization and should only be applied during actual DR.

### Full Restore (Activate Managed Clusters)

1. Provision a new ROSA HCP cluster in the **same AWS region** (cross-region restore is not supported on STS)
2. Install ACM operator in the same namespace as the original hub
3. Create the MultiClusterHub with `cluster-backup: true`
4. Create the IAM role for OADP with the **new cluster's OIDC endpoint** in the trust policy
5. Install any other operators that were on the original hub (GitOps, Ansible, cert-manager, etc.)
6. Manually install OADP and create the DPA pointing to the **same** S3 bucket
7. Apply the restore:

```bash
oc apply -f restore.yaml
```

### Passive Hub (Standby Without Activating Clusters)

For a standby hub that syncs data but doesn't take over managed clusters:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive
  namespace: open-cluster-management-backup
spec:
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
  syncRestoreWithNewBackups: true
```

The controller checks for new backups every 30 minutes when `syncRestoreWithNewBackups: true`. Customize with `restoreSyncInterval`.

To promote the passive hub to primary, change `veleroManagedClustersBackupName` to `latest` and ensure the old hub's BackupSchedule is paused or deleted.

## Troubleshooting

### BackupSchedule stuck in Pending

The backup component remains Pending until OADP is installed in `open-cluster-management-backup`. Verify the operator in that namespace:

```bash
# Verify the OADP operator is installed and running in the backup namespace
oc get csv -n open-cluster-management-backup | grep oadp

# Verify the OperatorGroup is OwnNamespace
oc get operatorgroup -n open-cluster-management-backup -o yaml

# Check if ACM created the subscription hint ConfigMap
oc get configmap acm-redhat-oadp-operator-subscription \
  -n open-cluster-management-backup -o yaml

# Verify Velero pods are running in the backup namespace
oc get pods -n open-cluster-management-backup
```

### BackupStorageLocation shows FailedValidation

Common on STS when the IAM role is misconfigured:

```bash
# Check the BSL status
oc get backupstoragelocations -n open-cluster-management-backup -o yaml

# Check Velero logs for STS errors
oc logs deployment/velero -n open-cluster-management-backup | grep -i "error\|sts\|assume"
```

Common causes:
- IAM trust policy OIDC endpoint doesn't match the cluster's OIDC provider
- Trust policy doesn't include the correct service account names
- IAM permissions policy is missing required S3 or EC2 actions
- S3 bucket doesn't exist or is in a different region

### STS AssumeRoleWithWebIdentity Errors

```bash
# Verify the OIDC endpoint
oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}'

# Verify the credential secret has the correct format
oc get secret cloud-credentials -n open-cluster-management-backup \
  -o jsonpath='{.data.credentials}' | base64 -d

# Check the IAM role trust policy
aws iam get-role --role-name <ROLE_NAME> --query Role.AssumeRolePolicyDocument
```

The trust policy's `Federated` principal must match: `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC_ENDPOINT>`

The `Condition` must list the service accounts in the `open-cluster-management-backup` namespace:
- `system:serviceaccount:open-cluster-management-backup:openshift-adp-controller-manager`
- `system:serviceaccount:open-cluster-management-backup:velero`

### BackupCollision state

Another hub is writing backups to the same storage location. Ensure only one hub has an active BackupSchedule:

```bash
# Pause the backup on the old hub
oc patch backupschedule schedule-acm \
  -n open-cluster-management-backup --type merge \
  -p '{"spec":{"paused":true}}'
```

### ExternalSecret not syncing

```bash
# Check ExternalSecret status
oc describe externalsecret cloud-credentials -n open-cluster-management-backup

# Verify the ClusterSecretStore is healthy
oc get clustersecretstore aws-secrets-manager

# Check if the AWS Secrets Manager secret exists
aws secretsmanager get-secret-value --secret-id oadp/acm-backup-credentials
```

## ROSA HCP + STS Limitations

- **No Kopia/Restic:** Node agent (file-level backup) is not supported on ROSA STS. Only CSI snapshots and native EBS snapshots are supported for volume backup
- **No Data Mover:** The Data Mover feature is not supported on ROSA clusters
- **No cross-region restore:** Restoring backed-up data to a different AWS region is not supported on STS clusters
- **No backup images:** `backupImages` is set to `false` because ROSA HCP does not expose the internal image registry
- **OwnNamespace only:** OADP does not support AllNamespaces. Install matching-channel OADP operators in `openshift-adp` (general workloads) and `open-cluster-management-backup` (ACM backup). Do not mix channels/versions -- CRDs are cluster-scoped.
- **IAM role per cluster:** Each ROSA HCP cluster needs its own IAM role with a trust policy referencing its unique OIDC endpoint. The same role cannot be shared across clusters

## References

### Official Red Hat Documentation

- [OADP on ROSA with STS Tutorial](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/tutorials/cloud-experts-deploy-api-data-protection)
- [ROSA Backing Up and Restoring Applications](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html-single/backing_up_and_restoring_applications/index)
- [AWS STS and ROSA HCP Explained](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/about/cloud-experts-rosa-hcp-sts-explained)
- [ROSA IAM Roles for Service Accounts](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/authentication_and_authorization/assuming-an-aws-iam-role-for-a-service-account)
- [RHACM 2.17 Business Continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/pdf/business_continuity/Red_Hat_Advanced_Cluster_Management_for_Kubernetes-2.17-Business_continuity-en-US.pdf)
- [RHACM 2.16 Business Continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/business_continuity/index)
- [OADP Documentation (OCP 4.20)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/oadp-application-backup-and-restore)
- [ROSA STS IAM Resources Reference](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)

### GitHub Repositories

- [stolostron/cluster-backup-operator](https://github.com/stolostron/cluster-backup-operator) -- source code for the cluster backup operator, includes sample YAML files under `config/samples/`
- [openshift/oadp-operator](https://github.com/openshift/oadp-operator) -- OADP operator source and documentation
- [velero-plugin-for-aws](https://github.com/vmware-tanzu/velero-plugin-for-aws) -- Velero AWS plugin with IAM policy reference

### Related Documentation

- [RHACM 2.13 Business Continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.13/html-single/business_continuity/index)
- [Velero Documentation](https://velero.io/docs/) -- upstream Velero project documentation
