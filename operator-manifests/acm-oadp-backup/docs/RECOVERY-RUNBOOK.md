# ACM Hub Backup — Recovery Runbook

Operational procedures for **validating backups**, **restoring ACM hub state**, and **recovering from hub failure** on ROSA HCP.

| Document | Purpose |
| --- | --- |
| [ROSA-HCP.md](ROSA-HCP.md) | IAM, S3, STS, and install prerequisites |
| [../RUNBOOK.md](../RUNBOOK.md) | Day-2 operations, install validation, detailed troubleshooting |
| This runbook | Backup validation, restore, and disaster recovery |

```bash
export NS=open-cluster-management-backup
export BUCKET=ravi-rosa-hub-hcp-acm-backup   # from overlays/rosa-hcp
export PREFIX=acm-hub                          # DPA objectStorage prefix
export REGION=us-east-2
```

---

## 1. When to use this runbook

| Situation | Start at |
| --- | --- |
| Routine backup health check | [Section 2](#2-backup-validation) |
| Planned maintenance / pre-change snapshot | [Section 2.6](#26-pre-change-backup) |
| Hub cluster lost or unrecoverable | [Section 4.1](#41-full-disaster-recovery) |
| Standby hub failover (active/passive) | [Section 4.2](#42-activepassive-failover) |
| Partial data loss (policies, credentials, clusters) | [Section 4.3](#43-staged-restore) |
| Restore attempted but failed | [Section 5](#5-troubleshooting) |

**ROSA HCP constraints (non-negotiable):**

- Restore hub must be in the **same AWS region** as the backup hub.
- Use the **same S3 bucket and prefix** as the source hub DPA.
- Only **one** hub may write backups to a bucket/prefix at a time (`BackupCollision`).
- Restore hub ACM version must be **equal to or newer than** the backup hub.

---

## 2. Backup validation

Run these checks regularly and **before any restore attempt**.

### 2.1 Health snapshot (one command)

```bash
echo "=== ACM Hub Backup Health ==="
oc -n $NS get csv 2>/dev/null | grep oadp || echo "OADP CSV missing"
oc -n $NS get externalsecret cloud-credentials \
  -o jsonpath='ExternalSecret Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null
oc -n $NS get dpa dpa-acm \
  -o jsonpath='DPA Reconciled={.status.conditions[?(@.type=="Reconciled")].status}{"\n"}' 2>/dev/null
oc -n $NS get bsl -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,DEFAULT:.spec.default 2>/dev/null
oc -n $NS get backupschedule schedule-acm \
  -o jsonpath='BackupSchedule={.status.state} Message={.status.message}{"\n"}' 2>/dev/null
echo -n "Velero schedules: "; oc -n $NS get schedule.velero.io --no-headers 2>/dev/null | wc -l | tr -d ' '
echo -n "Completed backups: "; oc -n $NS get backup.velero.io --field-selector status.phase=Completed --no-headers 2>/dev/null | wc -l | tr -d ' '
```

**Healthy hub checklist:**

| Check | Expected |
| --- | --- |
| OADP CSV | `PHASE=Succeeded` |
| ExternalSecret `cloud-credentials` | `Ready=True` |
| DPA `dpa-acm` | `Reconciled=True` |
| BackupStorageLocation | `PHASE=Available`, `default=true` |
| BackupSchedule `schedule-acm` | `Enabled` (not `FailedValidation`) |
| Velero schedules | 5 schedules present |
| Completed backups | Count increases over time |

Current schedule (from `backup/backupschedule.yaml`): every **6 hours**, retention **720h** (30 days).

### 2.2 Validate BackupStorageLocation

BSL must be `Available` before backups or restores succeed.

```bash
oc -n $NS get backupstoragelocation -o wide
oc -n $NS describe backupstoragelocation
oc -n $NS logs deploy/velero --tail=50 | grep -iE 'bsl|storage|error|credential'
```

If BSL is `Unavailable`, fix credentials and DPA before proceeding. See [Section 5.1](#51-backupstoragelocation-unavailable).

### 2.3 Validate Velero schedules and backups

`BackupSchedule` creates five Velero schedules:

| Schedule | Contents |
| --- | --- |
| `acm-credentials-schedule` | Hive/ACM credentials (`Secret`, labeled `ConfigMap`) |
| `acm-resources-schedule` | ACM CRDs (Policies, Placements, Applications, etc.) |
| `acm-resources-generic-schedule` | Resources labeled `cluster.open-cluster-management.io/backup` |
| `acm-managed-clusters-schedule` | Managed cluster activation data |
| `acm-validation-policy-schedule` | BackupSchedule heartbeat for governance policies |

```bash
oc -n $NS get schedule.velero.io -o custom-columns=\
NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST-BACKUP:.status.lastBackup

oc -n $NS get backup.velero.io --sort-by=.metadata.creationTimestamp | tail -10

for s in acm-credentials-schedule acm-resources-schedule acm-resources-generic-schedule \
         acm-managed-clusters-schedule acm-validation-policy-schedule; do
  echo "== $s =="
  oc -n $NS get backup.velero.io -l velero.io/schedule-name=$s \
    --sort-by=.metadata.creationTimestamp | tail -3
done
```

| Backup phase | Action |
| --- | --- |
| `Completed` | OK |
| `InProgress` | Wait |
| `Failed` | `oc -n $NS describe backup.velero.io <name>` |
| `PartiallyFailed` | Review `status.errors`; may still be usable |

### 2.4 Validate S3 objects

Confirm backups exist in the bucket under the DPA prefix:

```bash
aws s3 ls s3://${BUCKET}/${PREFIX}/backups/ --recursive | tail -20
aws s3 ls s3://${BUCKET}/${PREFIX}/backups/ | wc -l
```

Velero layout: `s3://${BUCKET}/${PREFIX}/backups/<backup-name>/`.

### 2.5 Validate ACM governance policies

```bash
oc get policy -n open-cluster-management | grep backup
oc get policy backup-restore-enabled -n open-cluster-management \
  -o jsonpath='Compliant={.status.compliant}{"\n"}'
```

`Compliant=True` indicates backup health templates (DPA available, backups in bucket) are passing.

### 2.6 Pre-change backup

Before hub upgrades, IAM changes, or maintenance:

```bash
# Pause scheduled backups (optional — prevents collision during manual backup)
oc -n $NS patch backupschedule schedule-acm --type=merge -p '{"spec":{"paused":true}}'

# Trigger on-demand backup of all managed cluster state
velero backup create pre-change-$(date +%Y%m%d-%H%M) \
  --from-schedule acm-managed-clusters-schedule \
  -n $NS

oc -n $NS wait --for=jsonpath='{.status.phase}'=Completed \
  backup.velero.io/pre-change-$(date +%Y%m%d-%H%M) --timeout=30m

# Resume schedule
oc -n $NS patch backupschedule schedule-acm --type=merge -p '{"spec":{"paused":false}}'
```

Record the backup name — use it for a targeted restore if needed.

---

## 3. Pre-restore checklist

Complete **all** items before applying a `Restore` CR on a replacement or standby hub.

### 3.1 Restore hub prerequisites

| # | Requirement | Verify |
| --- | --- | --- |
| 1 | ACM/MCE installed, same or newer version than backup hub | `oc get mch -n open-cluster-management` |
| 2 | `cluster-backup: true` on MCH | See [examples/mch-cluster-backup.yaml](../examples/mch-cluster-backup.yaml) |
| 3 | OADP installed in `$NS` (phase 1 synced) | `oc -n $NS get csv \| grep oadp` |
| 4 | DPA points at **same bucket + prefix** | `oc -n $NS get dpa dpa-acm -o yaml \| grep -E 'bucket\|prefix'` |
| 5 | BSL `Available` on restore hub | `oc -n $NS get bsl` |
| 6 | Same AWS **region** as backup hub (ROSA STS) | `echo $REGION` |
| 7 | Other hub operators installed (GitOps, cert-manager, etc.) | Match source hub layout |

### 3.2 Source hub — prevent collision

Before activating managed clusters on a new hub, **stop backups on the old hub**:

```bash
# On the OLD / failing hub (if reachable)
oc -n $NS patch backupschedule schedule-acm --type=merge -p '{"spec":{"paused":true}}'
# Or delete BackupSchedule entirely on the old hub
```

Skipping this step causes `BackupCollision` or duplicate cluster imports.

### 3.3 Identify restore point

```bash
# List backups visible from the restore hub
velero backup get -n $NS
oc -n $NS get backup.velero.io --sort-by=.metadata.creationTimestamp

# Get latest backup per category
oc -n $NS get backup.velero.io -l velero.io/schedule-name=acm-credentials-schedule \
  --sort-by=.metadata.creationTimestamp -o name | tail -1
oc -n $NS get backup.velero.io -l velero.io/schedule-name=acm-resources-schedule \
  --sort-by=.metadata.creationTimestamp -o name | tail -1
oc -n $NS get backup.velero.io -l velero.io/schedule-name=acm-managed-clusters-schedule \
  --sort-by=.metadata.creationTimestamp -o name | tail -1
```

Restore fields accept `latest`, `skip`, or a specific Velero backup name.

---

## 4. Recovery procedures

### 4.1 Full disaster recovery

**Use when:** The original hub is permanently offline. One replacement hub takes over credentials, ACM resources, and managed clusters.

**Steps:**

1. Complete [Section 3](#3-pre-restore-checklist).
2. Pause/delete `BackupSchedule` on the old hub.
3. Apply full restore:

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

4. Monitor until finished:

```bash
oc -n $NS get restore restore-acm -w
oc -n $NS get restore restore-acm -o jsonpath='Phase={.status.phase}{"\n"}'
oc -n $NS get restore.velero.io
```

5. Complete [Section 6](#6-post-recovery-validation).
6. Enable `BackupSchedule` on the **new** primary hub only.

| `cleanupBeforeRestore` | When to use |
| --- | --- |
| `None` | Brand-new empty hub |
| `CleanupRestored` | Hub had a previous restore attempt |
| `CleanupAll` | Aggressive cleanup — use with caution |

### 4.2 Active/passive failover

**Use when:** A standby hub follows backups from the active hub and takes over during planned or unplanned failover.

#### Phase 1 — Passive sync (standby hub)

Restores credentials and ACM resources; managed clusters stay on the active hub.

```bash
oc apply -f examples/restore-passive-sync.yaml
```

```yaml
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

Monitor passive sync:

```bash
oc -n $NS get restore restore-acm-passive-sync -w
```

#### Phase 2 — Failover (activate managed clusters)

1. Pause `BackupSchedule` on the **active** hub.
2. Apply activation restore on the standby hub:

```bash
oc apply -f examples/restore-activate.yaml
```

```yaml
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: skip
  veleroResourcesBackupName: skip
```

3. Complete [Section 6](#6-post-recovery-validation).
4. Enable `BackupSchedule` on the new primary; keep old hub offline or paused.

### 4.3 Staged restore

**Use when:** You need to restore one category at a time for verification.

```bash
# Step 1 — credentials only
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

oc -n $NS wait --for=jsonpath='{.status.phase}'=Finished restore/restore-acm-credentials --timeout=60m

# Step 2 — ACM resources (after verifying credentials)
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-resources
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroCredentialsBackupName: skip
  veleroResourcesBackupName: latest
  veleroManagedClustersBackupName: skip
EOF

# Step 3 — managed clusters (after verifying resources; pause old hub first)
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-clusters
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroCredentialsBackupName: skip
  veleroResourcesBackupName: skip
  veleroManagedClustersBackupName: latest
EOF
```

Wait for each `Restore` CR to reach `Finished` before proceeding to the next step.

### 4.4 Targeted restore (specific backup name)

When `latest` is not safe (e.g. a known-bad backup ran after a good one):

```bash
BACKUP_NAME=<velero-backup-name>   # from velero backup get

cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-point-in-time
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroCredentialsBackupName: ${BACKUP_NAME}
  veleroResourcesBackupName: ${BACKUP_NAME}
  veleroManagedClustersBackupName: ${BACKUP_NAME}
EOF
```

Use category-specific backup names when restoring staged categories from different points in time.

---

## 5. Troubleshooting

### 5.1 BackupStorageLocation Unavailable

```bash
oc -n $NS describe backupstoragelocation
oc -n $NS get secret cloud-credentials -o jsonpath='{.data.cloud}' | base64 -d; echo
oc -n $NS get subscription redhat-oadp-operator-subscription -o yaml | grep -A2 ROLEARN
oc -n $NS get externalsecret cloud-credentials
oc -n $NS logs deploy/velero --tail=100
```

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `FailedValidation` on BackupSchedule | BSL not Available | Fix BSL first |
| BSL `Unavailable` | Bad credentials | Verify ExternalSecret, IAM role, Secrets Manager JSON |
| BSL `Unavailable` | Wrong bucket/region | Check DPA `backupLocations` and overlay values |
| BSL `Unavailable` | Network | Workers need S3 access (NAT or VPC endpoint) |
| `REPLACE_ME_*` in DPA | Overlay not patched | Sync latest GitOps manifests |

### 5.2 Backup failures

```bash
BACKUP=<failed-backup-name>
oc -n $NS describe backup.velero.io $BACKUP
oc -n $NS logs deploy/velero --tail=100 | grep -i "$BACKUP"
```

| Phase | Action |
| --- | --- |
| `Failed` | Check RBAC, CRD version skew, API timeouts in `status.errors` |
| `PartiallyFailed` | Review failed items; may still be restorable |

Re-run manually after fix:

```bash
velero backup create manual-$(date +%Y%m%d-%H%M) \
  --from-schedule acm-managed-clusters-schedule -n $NS
```

### 5.3 Restore failures

```bash
oc -n $NS get restore
oc -n $NS describe restore <name>
oc -n $NS get restore.velero.io
oc -n $NS logs deploy/cluster-backup-chart-clusterbackup --tail=100
oc -n $NS logs deploy/velero --tail=100
```

| Issue | Likely cause | Fix |
| --- | --- | --- |
| Stuck `InProgress` | Large backup | Wait; check Velero logs |
| `Failed` | BSL unavailable | Fix BSL on restore hub |
| `Failed` | Version mismatch | Upgrade restore hub ACM to match or exceed source |
| Managed clusters not connecting | Activation backup missing | Restore `acm-managed-clusters-schedule` backup |
| Duplicate/wrong cluster state | Old hub still online | Pause old hub BackupSchedule |
| `BackupCollision` | Two hubs writing | Pause BackupSchedule on one hub |

### 5.4 Missing data after restore

| Missing item | Check |
| --- | --- |
| Hive cluster secrets | Were they labeled `cluster.open-cluster-management.io/backup` on source hub? |
| GitOps-deployed secrets | Add backup label on source before next backup |
| `local-cluster` settings | Not restored on new hubs — reconfigure manually |
| Policies / placements | Verify `acm-resources-schedule` backup completed before restore point |

---

## 6. Post-recovery validation

Run after any restore completes (`Restore` CR phase `Finished`).

```bash
echo "=== Post-Recovery Validation ==="

# Restore CR
oc -n $NS get restore -o wide

# ACM hub health
oc get mch multiclusterhub -n open-cluster-management -o jsonpath='Status={.status.phase}{"\n"}'
oc get managedcluster
oc get policy -n open-cluster-management --no-headers | wc -l

# Expected clusters reconnecting
oc get managedcluster -o custom-columns=\
NAME:.metadata.name,HUB:.metadata.labels.open-cluster-management\.io/clusterset,\
AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status

# Backup pipeline on new primary
oc -n $NS get backupschedule schedule-acm
oc -n $NS get bsl
oc get policy backup-restore-enabled -n open-cluster-management \
  -o jsonpath='Compliant={.status.compliant}{"\n"}'
```

**Post-recovery checklist:**

- [ ] `Restore` CR `phase=Finished`
- [ ] ACM console shows expected policies, placements, and applications
- [ ] `oc get managedcluster` — expected clusters present
- [ ] Hive clusters reconnect automatically
- [ ] Non-Hive (imported) clusters re-imported if still `Pending`
- [ ] `BackupSchedule` enabled on **one** primary hub only
- [ ] Old hub offline or `BackupSchedule` paused/deleted
- [ ] `backup-restore-enabled` policy `Compliant=True`
- [ ] On-demand backup completes successfully on new primary

---

## 7. Failback procedure

When returning to the original hub after temporary failover:

1. Ensure the original hub is rebuilt with the same ACM version and operator layout.
2. Sync OADP phase 1 and enable `cluster-backup` on MCH.
3. Point DPA at the same bucket/prefix (or a new bucket if you migrated backups).
4. Pause `BackupSchedule` on the **current** primary hub.
5. Run a full restore ([Section 4.1](#41-full-disaster-recovery)) on the original hub.
6. Complete [Section 6](#6-post-recovery-validation).
7. Re-enable `BackupSchedule` on the original hub; keep failover hub paused.

---

## 8. Quick reference

### Backup categories → restore fields

| Category | Velero schedule | Restore field |
| --- | --- | --- |
| Credentials | `acm-credentials-schedule` | `veleroCredentialsBackupName` |
| ACM resources | `acm-resources-schedule`, `acm-resources-generic-schedule` | `veleroResourcesBackupName` |
| Managed clusters | `acm-managed-clusters-schedule` | `veleroManagedClustersBackupName` |

### Recovery decision flow

```
Hub failure?
├── Yes, hub gone → Full DR (Section 4.1)
├── Yes, standby exists → Passive sync → Failover (Section 4.2)
└── No, backup unhealthy → Backup validation (Section 2) → Troubleshooting (Section 5)

Restore complete?
└── Post-recovery validation (Section 6) → Enable BackupSchedule on new primary
```

### Example manifests

| Scenario | File |
| --- | --- |
| Full disaster recovery | [examples/restore-full.yaml](../examples/restore-full.yaml) |
| Passive standby sync | [examples/restore-passive-sync.yaml](../examples/restore-passive-sync.yaml) |
| Failover activation | [examples/restore-activate.yaml](../examples/restore-activate.yaml) |

### External references

- [ACM Business continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview)
- [OADP on ROSA STS](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/backup_and_restore/oadp-rosa-backing-up-applications)
