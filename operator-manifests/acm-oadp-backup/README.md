# ACM hub backup (OADP) for Argo CD on ROSA HCP

GitOps manifests for Red Hat Advanced Cluster Management hub backup on **ROSA with Hosted Control Planes**. Everything the cluster-backup controller uses lives in `open-cluster-management-backup`.

**Start here:** [docs/ROSA-HCP.md](docs/ROSA-HCP.md) — AWS IAM, S3, Secrets Manager, STS prerequisites.

## Three-phase install order (required)

OADP must be installed and healthy via GitOps **before** `cluster-backup: true` on MultiClusterHub. `BackupSchedule` is a **separate** GitOps phase after that.

| Phase | What | App-of-apps path |
| --- | --- | --- |
| **1. OADP** | Namespace, OperatorGroup, Subscription, ExternalSecret, DPA | `overlays/rosa-hcp` |
| **2. MCH** | Enable `cluster-backup` on MultiClusterHub | `examples/mch-cluster-backup.yaml` (not kustomize) |
| **3. Schedule** | `BackupSchedule` | `overlays/schedule` |

```bash
# Phase 1 — wait until all green
oc -n open-cluster-management-backup get csv,externalsecret,dpa,bsl

# Phase 2 — after BSL is Available
oc patch mch multiclusterhub -n open-cluster-management --type=merge \
  -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'

# Phase 3 — sync overlays/schedule, then verify
oc -n open-cluster-management-backup get backupschedule,schedule.velero.io
```

**Do not** enable `cluster-backup` before phase 1 completes. On ROSA STS, MCH will not install OADP for you — the backup component stays `Pending`.

## What owns what

| Phase 1 GitOps | Controller creates | Do not GitOps |
| --- | --- | --- |
| Namespace, OperatorGroup, OADP Subscription (`ROLEARN`) | OADP CSV, Velero deployment | `BackupStorageLocation` (DPA owns it) |
| `ExternalSecret` → STS `cloud-credentials` | BSL from `DPA.spec.backupLocations` | `Schedule.velero.io`, `Backup.velero.io` |
| `DataProtectionApplication` | | A second OADP in `openshift-adp` |
| Phase 3: `BackupSchedule` | Five Velero schedules | `Restore` on the active hub |

## OpenShift GitOps testing (`argocd/`)

For cluster testing with OpenShift GitOps, apply the Argo CD `Application` CRs in `openshift-gitops`:

```bash
# Phase 1 — OADP (auto-sync enabled)
oc apply -f argocd/application.yaml

# Wait for BSL Available, enable cluster-backup on MCH, then:
oc apply -f argocd/application-schedule.yaml
argocd app sync acm-hub-backup-schedule -n openshift-gitops
```

Or apply both definitions: `oc apply -k argocd/` (sync the schedule app manually from the Argo CD UI/CLI after phase 2).

Update `spec.source.repoURL` if you fork the repository.

## App-of-apps integration

For production app-of-apps, use the overlay paths below (no `Application` CRs in that repo). For OpenShift GitOps testing, see [`argocd/`](argocd/).

```yaml
# Application 1 — OADP (sync first)
spec:
  source:
    path: <path-to-this-dir>/overlays/rosa-hcp
  destination:
    namespace: open-cluster-management-backup
  syncPolicy:
    automated: { prune: false, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
  ignoreDifferences:
    - group: operators.coreos.com
      kind: Subscription
      jsonPointers: [/status, /spec/startingCSV]
    - group: oadp.openshift.io
      kind: DataProtectionApplication
      jsonPointers: [/status]
    - group: external-secrets.io
      kind: ExternalSecret
      jsonPointers: [/status]

# Application 2 — BackupSchedule (sync after MCH cluster-backup: true)
# Use manual sync or an App-of-Apps sync-wave higher than Application 1.
spec:
  source:
    path: <path-to-this-dir>/overlays/schedule
  destination:
    namespace: open-cluster-management-backup
  syncPolicy:
    automated: { prune: false, selfHeal: true }
  ignoreDifferences:
    - group: cluster.open-cluster-management.io
      kind: BackupSchedule
      jsonPointers: [/status]
```

Sync waves on phase 1 manifests (`-1` → `10`) order OADP resources within that app.

See [RUNBOOK.md](RUNBOOK.md) for validation, backup verification, and restore.

## Overlays

| Overlay | Phase | Use case |
| --- | --- | --- |
| `overlays/rosa-hcp` | 1 | **ROSA HCP / STS** — OADP install |
| `overlays/schedule` | 3 | `BackupSchedule` (all platforms) |
| `overlays/aws-s3` | 1 | Non-STS AWS OADP (legacy static keys) |
| `overlays/s3-compatible` | 1 | MinIO / NooBaa / RGW |

## GitOps resources that must be labeled

Hive `ClusterDeployment` secrets created by GitOps are not auto-labeled. Add `cluster.open-cluster-management.io/backup: ""` or they are absent from the credentials backup.

## Restore

See [RUNBOOK.md](RUNBOOK.md). On ROSA STS, restore hub must use the **same AWS region** as the backup hub.
