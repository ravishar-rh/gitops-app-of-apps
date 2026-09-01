# ROSA HCP prerequisites for ACM hub backup

ACM on **ROSA with Hosted Control Planes (ROSA HCP)** uses **AWS STS / IRSA**. Static IAM user keys are not supported for OADP. This automation targets that model.

## What is different on ROSA HCP

| Topic | ROSA HCP requirement |
| --- | --- |
| OADP install | **Manual / GitOps** — MCH does **not** auto-install OADP when STS is enabled |
| Credentials | **IAM role + IRSA** (`role_arn` + `web_identity_token_file`), not access keys |
| OADP namespace | **`open-cluster-management-backup`** only (cluster-backup controller watches here) |
| OADP Subscription | Must set **`ROLEARN`** env var (see overlay patch) |
| `cloud-credentials` | STS INI format, synced from AWS Secrets Manager via ExternalSecret |
| DPA | `enableSharedConfig: "true"` on the backup location (ROSA STS) |
| S3 bucket | Pre-create in the **same AWS region** as the cluster |
| Cross-region restore | **Not supported** on ROSA STS — passive hub must use same region |
| Second OADP | **Forbidden** — Velero CRDs are cluster-scoped (`openshift-adp` conflicts) |

Hub backup captures **ACM Kubernetes objects** (policies, placements, managed clusters, credentials). It does **not** replace ROSA HCP control-plane DR (etcd/HyperShift); that is a separate concern.

---

## Prerequisites checklist (complete before Argo CD sync)

### AWS — IAM role for OADP (Velero S3 access)

1. Create an S3 bucket for ACM hub backups (Velero does not create it).
2. Create an IAM policy from `examples/rosa-oadp-s3-policy.json` (scope to your bucket).
3. Create an IAM role with trust policy from `examples/rosa-oadp-trust-policy.json`.

**Trust policy service accounts** (namespace is `open-cluster-management-backup`, not `openshift-adp`):

- `system:serviceaccount:open-cluster-management-backup:openshift-adp-controller-manager`
- `system:serviceaccount:open-cluster-management-backup:velero`

**Discover OIDC endpoint for trust policy:**

```bash
export CLUSTER_NAME=<rosa-cluster-name>
export REGION=$(rosa describe cluster -c "${CLUSTER_NAME}" -o json | jq -r .region.id)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')

echo "OIDC: ${OIDC_ENDPOINT}"
echo "Region: ${REGION}"
echo "Account: ${AWS_ACCOUNT_ID}"
```

4. Attach the S3 policy to the role. Record **`ROLE_ARN`**.

**If the bucket uses SSE-KMS**, add `kms:Decrypt` / `kms:GenerateDataKey` on the CMK to the IAM policy and set `kmsKeyId` on the DPA backup location config.

### AWS — Secrets Manager (ExternalSecret source)

Store a JSON secret (referenced by `REPLACE_ME_AWS_SECRET_NAME` in `base/externalsecret.yaml`):

```json
{
  "role_arn": "arn:aws:iam::123456789012:role/<cluster>-acm-oadp",
  "region": "us-east-1"
}
```

`role_arn` must match `REPLACE_ME_OADP_IAM_ROLE_ARN` in `overlays/rosa-hcp/kustomization.yaml`.

### Cluster — External Secrets Operator

- `ClusterSecretStore` **`aws-secrets-manager`** must exist and be `Ready`.
- Its IAM role must allow `secretsmanager:GetSecretValue` on the secret above.
- This is **separate** from the OADP Velero IAM role.

### Cluster — Network (ROSA HCP workers → S3)

Worker nodes must reach S3 (internet via NAT gateway or **S3 VPC gateway endpoint**). Private clusters without endpoints will see BSL `Unavailable` / Velero timeouts.

Optional but recommended for private ROSA:

- `com.amazonaws.<region>.s3` VPC gateway endpoint
- `com.amazonaws.<region>.secretsmanager` interface endpoint (for ESO)

### Cluster — ACM

- ACM/MCE installed and `MultiClusterHub` `Running`.
- **`cluster-backup` not enabled yet** until OADP is installed in `open-cluster-management-backup` (STS requirement).

### Git — fill placeholders in `overlays/rosa-hcp`

| Placeholder | Set to |
| --- | --- |
| `REPLACE_ME_BUCKET` | S3 bucket name |
| `REPLACE_ME_REGION` | AWS region (same as cluster) |
| `REPLACE_ME_OADP_IAM_ROLE_ARN` | OADP IAM role ARN |
| `REPLACE_ME_AWS_SECRET_NAME` | Secrets Manager secret name/path |

Point your app-of-apps `Application` at **`overlays/rosa-hcp`** (relative path once this directory is in your GitOps repo). See [README.md](../README.md#app-of-apps-integration) for recommended `syncOptions` and `ignoreDifferences`.

---

## Install order (ROSA HCP / STS)

On STS clusters, **OADP must be installed via GitOps and healthy before `cluster-backup: true`**. `BackupSchedule` is a third phase — never include it in the OADP sync.

```
Phase 1 — GitOps: overlays/rosa-hcp
  → Namespace, OperatorGroup, Subscription (ROLEARN), ExternalSecret, DPA
  → Wait: OADP CSV Succeeded, ExternalSecret Ready, BSL Available

Phase 2 — MCH: cluster-backup: true (examples/mch-cluster-backup.yaml)
  → Only after phase 1 is green
  → cluster-backup-chart controller installs

Phase 3 — GitOps: overlays/schedule
  → BackupSchedule
  → Verify: BackupSchedule Enabled, Velero backups Completed
```

If you enable `cluster-backup` before phase 1 completes, MCH backup stays **Pending** and the chart only creates ConfigMap `acm-redhat-oadp-operator-subscription` (hints for manual install).

---

## ROSA-specific validation

```bash
export NS=open-cluster-management-backup

# Subscription carries ROLEARN for CCO/OLM STS workflow
oc -n $NS get subscription redhat-oadp-operator-subscription -o yaml | grep -A2 ROLEARN

# Secret uses STS format (not access keys)
oc -n $NS get secret cloud-credentials -o jsonpath='{.data.cloud}' | base64 -d | head -4

# DPA has enableSharedConfig
oc -n $NS get dpa dpa-acm -o yaml | grep enableSharedConfig

# BSL and backups
oc -n $NS get bsl,backupschedule,backup.velero.io
```

Expected `cloud-credentials` content:

```ini
[default]
role_arn = arn:aws:iam::...
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
region = us-east-1
```

---

## CCO vs ExternalSecret on `cloud-credentials`

On OCP/ROSA 4.15+, setting `ROLEARN` on the OADP Subscription may cause **CCO** to auto-create `cloud-credentials`. This repo uses **ExternalSecret** as the source of truth from Secrets Manager.

If both fight over the same Secret:

1. Check owners: `oc -n $NS get secret cloud-credentials -o yaml | grep -E 'ownerReferences|managed-by'`
2. Prefer ExternalSecret; ensure ESO syncs before DPA reconciles (sync-wave 5 vs 10).
3. If CCO recreates the Secret, confirm `role_arn` in the Secret matches SM; patch Subscription `ROLEARN` if the operator pod fails.

---

## Restore on ROSA HCP

- Use the same **region and bucket/prefix** on the restore hub.
- **Cross-region restore is not supported** on ROSA STS.
- Follow [RUNBOOK.md](../RUNBOOK.md) Section 3; pause `BackupSchedule` on the old hub before activating managed clusters.

---

## References

- [ACM Business continuity — STS manual OADP install](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview)
- [OADP on ROSA STS](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/backup_and_restore/oadp-rosa-backing-up-applications)
- [ROSA backing up applications](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws_classic_architecture/4/html/backing_up_and_restoring_applications/rosa-backing-up-applications)
