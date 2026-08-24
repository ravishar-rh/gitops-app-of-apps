# OADP Operator

Deploys the OpenShift API for Data Protection (OADP) Operator via OLM on a ROSA HCP (OpenShift 4.22) cluster with AWS STS authentication, configured with S3 backup storage.

## What is OADP?

OADP (OpenShift API for Data Protection) is Red Hat's supported solution for backing up and restoring applications running on OpenShift. It installs and manages **Velero**, an open-source Kubernetes backup tool, along with plugins for OpenShift-specific resources and storage integrations.

OADP protects:
- Kubernetes resources (Deployments, Services, ConfigMaps, Secrets, etc.)
- Persistent volume data (via CSI snapshots or file-level backup)
- OpenShift Virtualization virtual machines (via the kubevirt plugin)
- Internal container images

OADP does **not** provide disaster recovery for etcd or OpenShift Operators themselves -- those are handled by the platform's built-in etcd backup mechanism.

## Key Concepts

### Velero

**Velero** is the upstream open-source project that OADP is built on. It provides the core backup, restore, and schedule controllers. OADP packages Velero with Red Hat-supported plugins and integrates it with the OpenShift ecosystem. You don't interact with Velero directly -- OADP manages it through the DataProtectionApplication CR.

### DataProtectionApplication (DPA)

The **DataProtectionApplication** is the central CR that configures the entire backup infrastructure:

- **Velero plugins** -- which integrations to load:
  - `openshift` -- required, handles OpenShift-specific resources (Routes, DeploymentConfigs, ImageStreams)
  - `aws` -- S3-compatible object storage for backup data
  - `csi` -- CSI VolumeSnapshot integration for storage-native snapshots
  - `kubevirt` -- OpenShift Virtualization VM backup with freeze/unfreeze hooks
- **Backup locations** -- where backup data is stored (S3 bucket, region, credentials)
- **Snapshot locations** -- where volume snapshots are stored (cloud provider, region)
- **Node agent** -- runs as a DaemonSet on every node to handle file-level backup/restore via Kopia

### Backup Storage Location (BSL)

A **Backup Storage Location** defines the S3 bucket (or S3-compatible endpoint) where Velero stores:
- Kubernetes resource manifests (as JSON/tarball)
- Kopia file-level backup data (if node agent is used instead of CSI snapshots)
- Backup metadata and logs

The BSL references a Kubernetes Secret containing the storage credentials.

### Volume Snapshot Location (VSL)

A **Volume Snapshot Location** tells Velero where to store cloud-provider volume snapshots. For AWS, this is the region where EBS snapshots are created. When using CSI snapshots, a VSL is optional since the CSI driver manages snapshot storage natively.

### Kopia vs Restic

The **node agent** handles file-level backup of persistent volumes. It supports two upload engines:

- **Kopia** (current, recommended) -- modern deduplicating backup tool with encryption, compression, and efficient incremental backups
- **Restic** (removed in OADP 1.6) -- legacy uploader, no longer supported for new backups

If you have existing restic-based backups, restores from those backups are still supported for at least two more Velero versions.

### Backup

A **Backup** CR triggers a point-in-time backup. You control what gets backed up through:

- **`includedNamespaces`** -- which namespaces to include
- **`includedResources`** / **`excludedResources`** -- resource type filtering
- **`labelSelector`** -- back up only resources matching specific labels
- **`hooks`** -- pre/post-backup commands to run inside containers (e.g., database quiesce, VM filesystem freeze)
- **`ttl`** -- how long to retain the backup before automatic deletion
- **`storageLocation`** -- which BSL to use

### Schedule

A **Schedule** CR creates Backups automatically on a cron schedule. The `template` field contains the same spec as a Backup CR. Each trigger creates a new Backup resource with a timestamped name.

### Restore

A **Restore** CR recovers resources from a specific Backup. You can restore everything or use filters to selectively restore specific namespaces, resources, or labels. Restores are non-destructive by default -- existing resources are not overwritten unless you configure conflict resolution.

## Compatibility

| Component | Version |
|---|---|
| OpenShift | 4.22 (ROSA HCP) |
| OADP | 1.6.x (stable channel) |
| Velero | 1.18 |
| Authentication | AWS STS (OIDC + IRSA) |
| OperatorGroup | OwnNamespace |
| Catalog Source | redhat-operators |

## Directory Structure

```
oadp-operator/
├── README.md
├── kustomization.yaml                    # references both subdirectories
├── operator/                              # OLM deployment manifests
│   ├── kustomization.yaml
│   ├── namespace.yaml                     # openshift-adp namespace
│   ├── operatorgroup.yaml                # OwnNamespace in openshift-adp
│   └── subscription.yaml
└── config/                                # backup configuration
    ├── kustomization.yaml
    └── acm-backup/                        # ACM hub cluster backup (ROSA HCP / STS)
        ├── README.md                       # ACM backup concepts, STS setup guide
        ├── kustomization.yaml
        ├── oadp-subscription.yaml          # Namespace for backup
        ├── operatorgroup.yaml              # OwnNamespace in backup namespace
        ├── subscription.yaml               # OADP Subscription in backup namespace
        ├── multiclusterhub-patch.yaml
        ├── credentials-secret.yaml         # ExternalSecret with role_arn (STS)
        ├── dataprotectionapplication.yaml
        ├── backupschedule.yaml
        ├── restore.yaml
        ├── iam-trust-policy.json           # IAM OIDC trust policy template
        └── iam-permissions-policy.json     # IAM S3+EC2 permissions template
```

- **`operator/`** -- OLM resources to install the OADP operator in `openshift-adp` (Namespace, OperatorGroup, Subscription). OADP only supports **OwnNamespace**, so this instance watches `openshift-adp` only. Deploy this first.
- **`config/acm-backup/`** -- ACM hub cluster backup for ROSA HCP with STS: backup namespace, OwnNamespace OADP install, STS credentials via ExternalSecret, DPA, and BackupSchedule. See [acm-backup/README.md](config/acm-backup/README.md) for IAM role setup and deployment steps.

## Deployment

### Via Kustomize / ArgoCD

Deploy the full stack (operator + config):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oadp-operator
  namespace: openshift-gitops
spec:
  source:
    path: oadp-operator
    repoURL: <YOUR_REPO_URL>
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Or deploy each subdirectory independently with separate ArgoCD Applications using sync waves to ensure ordering.

### Via CLI

```bash
# Step 1: Deploy the operator
oc apply -k oadp-operator/operator/

# Step 2: Wait for the operator to be ready
oc wait --for=condition=Available deployment/openshift-adp-controller-manager \
  -n openshift-adp --timeout=300s

# Step 3: Deploy the configuration
oc apply -k oadp-operator/config/
```

## ROSA HCP + STS Notes

- OADP only supports **OwnNamespace**. The operator in `openshift-adp` watches that namespace; ACM backup installs a second same-channel OADP operator in `open-cluster-management-backup`
- OADP on ROSA STS uses `role_arn` + `web_identity_token_file` instead of static AWS credentials -- see [acm-backup/README.md](config/acm-backup/README.md) for IAM role setup
- **Node agent (Kopia/Restic) is not supported** on ROSA STS -- only CSI snapshots and native EBS snapshots
- **Data Mover is not supported** on ROSA clusters
- **Cross-region restore is not supported** on STS clusters

## Monitoring

```bash
# Check DPA status (general workloads)
oc get dpa -n openshift-adp

# Check DPA status (ACM backup)
oc get dpa -n open-cluster-management-backup

# Check backup storage locations (both namespaces)
oc get backupstoragelocations -n openshift-adp
oc get backupstoragelocations -n open-cluster-management-backup

# Check ACM backup schedule and backups
oc get backupschedule -n open-cluster-management-backup
oc get backups -n open-cluster-management-backup --sort-by='.metadata.creationTimestamp' | tail -10

# Verify Velero pods are running
oc get pods -n openshift-adp
oc get pods -n open-cluster-management-backup
```

## References

- [OADP on ROSA with STS Tutorial](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/tutorials/cloud-experts-deploy-api-data-protection)
- [ROSA Backing Up and Restoring Applications](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html-single/backing_up_and_restoring_applications/index)
- [AWS STS and ROSA HCP Explained](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/about/cloud-experts-rosa-hcp-sts-explained)
- [OADP Documentation (OCP 4.20)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/oadp-application-backup-and-restore)
- [OADP GitHub Repository](https://github.com/openshift/oadp-operator)
- [Velero AWS Plugin IAM Policy](https://github.com/vmware-tanzu/velero-plugin-for-aws)
