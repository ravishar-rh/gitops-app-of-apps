# ACM Hub Backup Runbook

Operational guide for the `open-cluster-management-backup` namespace on **ROSA HCP**.

| Document | Purpose |
| --- | --- |
| [docs/ROSA-HCP.md](docs/ROSA-HCP.md) | IAM, S3, STS, and install prerequisites |
| [docs/RECOVERY-RUNBOOK.md](docs/RECOVERY-RUNBOOK.md) | Backup validation, restore, and disaster recovery |
| This runbook | Day-2 operations, install validation, detailed troubleshooting |

**Install order:** Phase 1 `overlays/rosa-hcp` (OADP) → Phase 2 MCH `cluster-backup: true` → Phase 3 `BackupSchedule`

```bash
export NS=open-cluster-management-backup
```

---

## 0. ROSA HCP prerequisites (before first sync)

Complete every item in [docs/ROSA-HCP.md](docs/ROSA-HCP.md). Summary:

| # | Task |
| --- | --- |
| 1 | S3 bucket in the **same region** as the ROSA cluster |
| 2 | IAM role + trust policy for `openshift-adp-controller-manager` and `velero` in `$NS` |
| 3 | IAM policy for S3 read/write on the bucket (`examples/rosa-oadp-s3-policy.json`) |
| 4 | Secrets Manager secret with `role_arn` + `region` (not access keys) |
| 5 | `ClusterSecretStore` `aws-secrets-manager` Ready (ESO IAM separate from OADP) |
| 6 | Worker → S3 connectivity (NAT or S3 VPC endpoint) |
| 7 | Placeholders set in `overlays/rosa-hcp` and `base/externalsecret.yaml` |

**Do not enable `cluster-backup` on MCH until phase 1 (`overlays/rosa-hcp`) is complete: OADP CSV `Succeeded` and BSL `Available`. Do not sync `overlays/schedule` until after phase 2.**

---

## 1. Post-sync validation (starting point)

**Assumed state:** App-of-apps synced this directory, MCH has `cluster-backup: true`, OADP CSV is `Succeeded` in `$NS`.

### 1.1 Confirm controllers are up

```bash
oc get mch multiclusterhub -n open-cluster-management \
  -o jsonpath='{range .spec.overrides.components[*]}{.name}{"="}{.enabled}{"\n"}{end}' \
  | grep cluster-backup

oc -n $NS get sub,csv
oc -n $NS get deploy openshift-adp-controller-manager cluster-backup-chart-clusterbackup
```

| Resource | Expected |
| --- | --- |
| `cluster-backup` on MCH | `true` |
| OADP CSV | `PHASE=Succeeded` |
| `openshift-adp-controller-manager` | `1/1` Ready |
| `cluster-backup-chart-clusterbackup` | `1/1` Ready |

### 1.2 ExternalSecret → `cloud-credentials`

```bash
oc -n $NS get externalsecret cloud-credentials
oc -n $NS get externalsecret cloud-credentials \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc -n $NS get secret cloud-credentials
```

ExternalSecret must be `Ready=True` before the DPA can use S3 credentials.

**ROSA HCP:** Secret must use STS format (`role_arn` + `web_identity_token_file`), not access keys:

```bash
oc -n $NS get secret cloud-credentials -o jsonpath='{.data.cloud}' | base64 -d | head -4
oc -n $NS get subscription redhat-oadp-operator-subscription -o yaml | grep -A2 ROLEARN
```

### 1.3 DataProtectionApplication and BackupStorageLocation

```bash
oc -n $NS get dpa dpa-acm
oc -n $NS get dpa dpa-acm \
  -o jsonpath='Reconciled={.status.conditions[?(@.type=="Reconciled")].status}{"\n"}'
oc -n $NS get deploy velero
oc -n $NS get backupstoragelocation
```

| Resource | Expected |
| --- | --- |
| DPA `dpa-acm` | `Reconciled=True` |
| `velero` deployment | `1/1` Ready |
| BSL `dpa-acm-1` | `PHASE=Available`, `DEFAULT=true` |

Do not proceed until BSL is `Available`. `BackupSchedule` stays `FailedValidation` until then.

### 1.4 BackupSchedule

```bash
oc -n $NS get backupschedule schedule-acm
oc -n $NS get backupschedule schedule-acm -o jsonpath='Status={.status.state}{"\n"}'
oc -n $NS get schedule.velero.io
```

| `BackupSchedule` status | Meaning |
| --- | --- |
| `Enabled` | Backups are running |
| `FailedValidation` | Fix BSL/DPA/credentials — read `status.message` |
| `Paused` | `spec.paused: true` |
| `BackupCollision` | Another hub writes to the same bucket/prefix |

The first backup runs immediately when `BackupSchedule` becomes valid, not at the next cron tick.

---

## 2. How to verify backups are running

Use these checks daily (or after any change to DPA, credentials, or the schedule).

### 2.1 Pipeline health (one command)

```bash
echo "=== ACM Hub Backup Health ==="
oc -n $NS get csv 2>/dev/null | grep oadp || true
oc -n $NS get externalsecret cloud-credentials \
  -o jsonpath='ExternalSecret Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null || echo "ExternalSecret missing"
oc -n $NS get dpa dpa-acm \
  -o jsonpath='DPA Reconciled={.status.conditions[?(@.type=="Reconciled")].status}{"\n"}' 2>/dev/null || echo "DPA missing"
oc -n $NS get bsl -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,DEFAULT:.spec.default 2>/dev/null || true
oc -n $NS get backupschedule schedule-acm \
  -o jsonpath='BackupSchedule={.status.state}{"\n"}' 2>/dev/null || echo "BackupSchedule missing"
echo -n "Velero schedules: "; oc -n $NS get schedule.velero.io --no-headers 2>/dev/null | wc -l | tr -d ' '
echo -n "Completed backups: "; oc -n $NS get backup.velero.io --field-selector status.phase=Completed --no-headers 2>/dev/null | wc -l | tr -d ' '
```

**Healthy hub:**

- ExternalSecret `Ready=True`
- BSL `Available` and `default=true`
- `BackupSchedule` `Enabled`
- At least 5 Velero schedules
- Growing count of `Completed` backups over time

### 2.2 Velero schedules exist

`BackupSchedule` creates these schedules (names are stable):

```bash
oc -n $NS get schedule.velero.io -o custom-columns=\
NAME:.metadata.name,\
SCHEDULE:.spec.schedule,\
LAST-BACKUP:.status.lastBackup
```

| Schedule | What it backs up |
| --- | --- |
| `acm-credentials-schedule` | Hive/ACM credentials (`Secret`, `ConfigMap` with backup labels) |
| `acm-resources-schedule` | ACM CRDs (Policies, Placements, Applications, etc.) |
| `acm-resources-generic-schedule` | Resources labeled `cluster.open-cluster-management.io/backup` |
| `acm-managed-clusters-schedule` | Managed cluster activation data (Hive, `ManagedCluster`, etc.) |
| `acm-validation-policy-schedule` | The `BackupSchedule` itself (heartbeat for policies) |

`LAST-BACKUP` should advance on each schedule’s cron (default: every 2 hours from `BackupSchedule`).

### 2.3 Velero backups completing

```bash
oc -n $NS get backup.velero.io --sort-by=.metadata.creationTimestamp
oc -n $NS get backup.velero.io -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
SCHEDULE:.metadata.labels.velero\\.io/schedule-name,\
STARTED:.status.startTimestamp,\
COMPLETED:.status.completionTimestamp
```

| Phase | Action |
| --- | --- |
| `Completed` | OK |
| `InProgress` | Wait |
| `Failed` | `oc -n $NS describe backup.velero.io <name>` |
| `PartiallyFailed` | Review `status.errors` — some items failed |

Recent backups per schedule:

```bash
for s in acm-credentials-schedule acm-resources-schedule acm-resources-generic-schedule \
         acm-managed-clusters-schedule acm-validation-policy-schedule; do
  echo "== $s =="
  oc -n $NS get backup.velero.io -l velero.io/schedule-name=$s \
    --sort-by=.metadata.creationTimestamp | tail -3
done
```

### 2.4 Backups present in S3

Confirm objects land under your DPA prefix (default `acm-hub/`):

```bash
# Replace bucket and prefix from your overlay
aws s3 ls s3://<bucket>/acm-hub/backups/ --recursive | tail -20
```

Velero layout: `s3://<bucket>/<prefix>/backups/<backup-name>/`.

### 2.5 ACM governance policies

The `cluster-backup` chart installs policies that assert backup health:

```bash
oc get policy -n open-cluster-management | grep backup
oc get policy backup-restore-enabled -n open-cluster-management \
  -o jsonpath='Compliant={.status.compliant}{"\n"}'
```

`Compliant=True` means templates such as `data-protection-application-available` and backup-in-bucket checks are passing.

### 2.6 What a failed backup looks like

```bash
BACKUP=<failed-backup-name>
oc -n $NS describe backup.velero.io $BACKUP
oc -n $NS logs deploy/velero --tail=100 | grep -i "$BACKUP"
```

Common causes: RBAC, CRD version skew, resources too large, or transient API errors. Re-run after fix:

```bash
velero backup create manual-$(date +%Y%m%d-%H%M) \
  --from-schedule acm-managed-clusters-schedule \
  -n $NS
```

### 2.7 Trigger a backup on demand (before maintenance)

```bash
velero backup create pre-maint-$(date +%Y%m%d-%H%M) \
  --from-schedule acm-managed-clusters-schedule \
  -n $NS

oc -n $NS get backup.velero.io pre-maint-$(date +%Y%m%d-%H%M) -w
```

Pick the schedule that matches what you need preserved (`acm-credentials-schedule`, `acm-resources-schedule`, etc.).

---

## 3. How to restore ACM from backup

Restore uses the `Restore.cluster.open-cluster-management.io` CR in `$NS`. It orchestrates Velero restores from the three backup categories:

| Backup category | Velero schedule prefix | Restore field |
| --- | --- | --- |
| Credentials | `acm-credentials-schedule` | `veleroCredentialsBackupName` |
| ACM resources | `acm-resources-schedule`, `acm-resources-generic-schedule` | `veleroResourcesBackupName` |
| Managed cluster activation | `acm-managed-clusters-schedule` | `veleroManagedClustersBackupName` |

Each field accepts:

- `latest` — most recent backup of that category in the bucket
- `skip` — do not restore this category
- `<backup-name>` — specific Velero backup name

### 3.1 Prerequisites (all restore scenarios)

1. **New or standby hub** with the same ACM version as the backup hub (equal or newer; never older).
2. **Same operator layout** as the source hub: ACM/MCE in the same namespaces, plus any other hub operators (GitOps, cert-manager, AAP, etc.) installed before restore.
3. **`cluster-backup: true`** on MCH; OADP installed in `$NS`.
4. **DPA** pointed at the **same bucket and prefix** as the backup hub.
5. **BSL `Available`** on the restore hub (can read the bucket).
6. **Shut down or pause backups on the old hub** before activating managed clusters, or you get `BackupCollision`.

**ROSA HCP / STS:** Restore hub must be in the **same AWS region** as the backup hub. Cross-region restore is **not supported** on ROSA STS.

List available backups in the bucket from the restore hub:

```bash
velero backup get -n $NS
# or
oc -n $NS get backup.velero.io
```

### 3.2 Scenario A — Full disaster recovery (single replacement hub)

Use when the original hub is gone or permanently offline. Restores credentials, ACM resources, and managed cluster activation in one step.

**Before restore:**

```bash
# On the OLD hub (if still reachable): pause backups
oc -n $NS patch backupschedule schedule-acm --type=merge -p '{"spec":{"paused":true}}'
# Or delete BackupSchedule on the old hub
```

**Apply restore** (see `examples/restore-full.yaml`):

```bash
oc apply -f examples/restore-full.yaml
```

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

**`cleanupBeforeRestore` options:**

| Value | Use when |
| --- | --- |
| `None` | Brand-new empty hub; nothing to clean |
| `CleanupRestored` | Hub had a previous restore; remove stale restored objects first |
| `CleanupAll` | Aggressive cleanup of labeled resources — use with care |

**Monitor:**

```bash
oc -n $NS get restore restore-acm -w
oc -n $NS get restore restore-acm -o yaml | grep -A20 '^status:'
oc -n $NS get restore.velero.io
```

**After restore:**

- Hive-provisioned managed clusters should reconnect automatically.
- Imported (non-Hive) clusters may show `Pending` until manually reattached.
- Create a new `BackupSchedule` on this hub if it is now the primary.
- Do **not** bring the old hub online with `BackupSchedule` still enabled.

### 3.3 Scenario B — Active / passive (standby hub follows backups)

**Phase 1 — Passive sync:** Restore credentials and resources only; keep following new backups from the active hub.

```bash
oc apply -f examples/restore-passive-sync.yaml
```

```yaml
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip      # do NOT activate clusters yet
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

Managed clusters stay on the active hub. The passive hub stays current with passive data.

**Phase 2 — Failover / activate:** When you cut over, pause `BackupSchedule` on the **active** hub first, then activate managed clusters on the passive hub.

```bash
oc apply -f examples/restore-activate.yaml
```

```yaml
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest    # activates managed clusters HERE
  veleroCredentialsBackupName: skip
  veleroResourcesBackupName: skip
```

After activation, the passive hub becomes primary. Create `BackupSchedule` on it and keep the old hub offline or with backups paused.

### 3.4 Scenario C — Staged restore (verify each category)

Restore one category at a time using `skip` / `latest`:

```bash
# Step 1: credentials only
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-credentials
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: None
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: skip
  veleroManagedClustersBackupName: skip
EOF

# Step 2: resources (after verifying step 1)
# Step 3: managed clusters (after verifying step 2)
```

Delete or finish each `Restore` CR before starting the next if the controller requires a clean state (check `status.phase`).

### 3.5 Restore status and troubleshooting

```bash
oc -n $NS get restore
oc -n $NS describe restore <name>
oc -n $NS get restore.velero.io
oc -n $NS logs deploy/cluster-backup-chart-clusterbackup --tail=100
oc -n $NS logs deploy/velero --tail=100
```

| Restore phase / issue | Likely cause |
| --- | --- |
| Stuck `InProgress` | Large backup; check Velero logs |
| `Failed` | Wrong backup name, BSL unavailable, version mismatch |
| Managed clusters not connecting | Activation backup not restored; old hub still online |
| Duplicate / wrong cluster state | Old hub still running and reimporting |
| `BackupCollision` on primary | Two hubs writing to same bucket — pause one `BackupSchedule` |

### 3.6 Post-restore checklist

- [ ] `Restore` CR `phase` is `Finished` (or equivalent success state)
- [ ] ACM console shows expected managed clusters, policies, and applications
- [ ] `oc get managedcluster` — expected clusters and states
- [ ] Re-import any non-Hive clusters that remain `Pending`
- [ ] `BackupSchedule` enabled only on the **one** primary hub
- [ ] `backup-restore-enabled` policy `Compliant` on the new primary
- [ ] Old hub powered off or `BackupSchedule` paused/deleted

### 3.7 Important limitations

- `local-cluster` managed cluster settings (e.g. cluster set ownership) are **not** restored on new hubs.
- GitOps-deployed Hive secrets need `cluster.open-cluster-management.io/backup` label on the **source** hub or they were never in the backup.
- Restore hub ACM version must be **≥** backup hub version.
- Only one OADP/Velero install per cluster (CRDs are cluster-scoped).

---

## 4. Quick reference — dependency order

```
MCH cluster-backup=true
  → cluster-backup-chart controller
  → OADP operator (in open-cluster-management-backup)
Phase 1 (overlays/rosa-hcp)
  → ExternalSecret (wave 5) → Secret cloud-credentials
  → DPA (wave 10) → Velero + BackupStorageLocation
Phase 2 — MCH cluster-backup: true → cluster-backup-chart controller
Phase 3 (overlays/schedule)
  → BackupSchedule → Velero Schedules → Backups → S3
Restore (standby/replacement hub only)
  → Restore CR → Velero Restore → ACM resources on hub
```

## 5. Common blockers

| Symptom | Where to look |
| --- | --- |
| MCH backup `Pending` | OADP not in `$NS` |
| `BackupSchedule` `FailedValidation` | BSL not `Available` |
| BSL `Unavailable` | ExternalSecret, bucket IAM, region, missing bucket |
| Backups `Failed` | `describe backup`, Velero logs |
| `BackupCollision` | Two hubs, same bucket/prefix |
| Restore missing data | Wrong prefix/bucket; resource never labeled for backup |
| Policy noncompliant on OADP channel | Subscription `stable` vs `stable-1.4` for your OCP version |
