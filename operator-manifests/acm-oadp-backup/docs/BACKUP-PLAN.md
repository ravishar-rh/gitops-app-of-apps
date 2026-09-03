# Backup Plan — Customer-Managed Components (ROSA HCP + ACM)

This document defines the **backup scope, responsibilities, and recovery objectives** for customer-managed components on a **ROSA with Hosted Control Planes (ROSA HCP)** cluster running **Red Hat Advanced Cluster Management (ACM)** as the hub.

It complements the operational guides in this repository:

| Document | Purpose |
| --- | --- |
| [ROSA-HCP.md](ROSA-HCP.md) | IAM, S3, STS prerequisites |
| [BACKUP-RESPONSIBILITIES.md](BACKUP-RESPONSIBILITIES.md) | Division of backup duties between Red Hat, AWS, and Customer |
| [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) | Backup validation and restore procedures |
| [../RUNBOOK.md](../RUNBOOK.md) | Day-2 operations and troubleshooting |

---

## 1. Purpose and scope

### 1.1 Objective

Ensure customer-managed configuration, ACM hub state, and supporting AWS/GitOps assets can be recovered after:

- Accidental deletion or misconfiguration
- Hub cluster loss or corruption
- Planned migration or disaster recovery failover

### 1.2 In scope

| Layer | Customer-managed items |
| --- | --- |
| **ACM hub** | Policies, placements, applications, managed cluster registrations, credentials, governance |
| **Hub cluster workloads** | GitOps-managed operators, compliance configs, logging, workloads |
| **AWS (customer account)** | S3 backup bucket, IAM roles/policies, Secrets Manager secrets, VPC endpoints |
| **Source control** | GitOps repositories, Terraform state, runbooks |
| **Managed (spoke) clusters** | Cluster lifecycle metadata on hub; spoke recovery is separate |

### 1.3 Out of scope (Red Hat–managed on ROSA HCP)

| Component | Owner | Customer action |
| --- | --- | --- |
| HyperShift control plane (hosted control plane) | Red Hat | None — not customer-backup-able |
| ROSA HCP etcd / API server | Red Hat | None |
| Worker node OS / platform operators (core OCP) | Red Hat / shared | Monitor only |
| ROSA infrastructure (VPC, subnets created by installer) | Customer AWS account, Red Hat operated | Document in DR plan; rebuild via ROSA if hub lost |
| Managed cluster worker/control planes (spoke ROSA/OCP) | Spoke cluster owner | Separate backup/DR per spoke |

> **Key distinction:** ACM hub backup (OADP + `cluster-backup`) preserves **multicluster management state** on the hub. It does **not** replace ROSA HCP control-plane disaster recovery or full spoke-cluster rebuild.

---

## 2. Shared responsibility model

See [BACKUP-RESPONSIBILITIES.md](BACKUP-RESPONSIBILITIES.md) for the full Red Hat / AWS / Customer matrix. Summary:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        CUSTOMER RESPONSIBILITY                          │
├─────────────────────────────────────────────────────────────────────────┤
│  Git repos (GitOps, Terraform)     AWS backup bucket, IAM, Secrets Mgr  │
│  ACM policies / apps / placements  OADP install + BackupSchedule      │
│  Operator configs (compliance,     External Secrets, labeled secrets   │
│   logging, FIO, workloads)         Hub rebuild / passive hub design   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────┴───────────────────────────────────┐
│                     RED HAT / PLATFORM (ROSA HCP)                       │
├─────────────────────────────────────────────────────────────────────────┤
│  Hosted control plane (HyperShift)   ROSA SLA / support for platform   │
│  Platform monitoring & upgrades      Worker node provisioning           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Recovery objectives

| Tier | Scope | RPO | RTO | Method |
| --- | --- | --- | --- | --- |
| **T1 — ACM hub state** | Policies, placements, apps, managed cluster activation, credentials | 6 hours | 4–8 hours | OADP `BackupSchedule` → S3 |
| **T2 — GitOps source of truth** | Operator installs, MCH, DPA, compliance, workloads | Near zero (git) | 1–2 hours | Git repository + Argo CD re-sync |
| **T3 — AWS backup infrastructure** | S3 bucket, IAM, Secrets Manager | N/A (config) | 1–2 hours | Terraform (`terraform-acm-backup/`) |
| **T4 — Hub cluster platform** | ROSA HCP cluster itself | N/A | 2–4 hours | New ROSA HCP cluster + restore ACM from backup |
| **T5 — Spoke clusters** | Workloads on managed clusters | Varies | Varies | Per-cluster DR (not covered by hub backup) |

**Current implementation (this repo):**

- `BackupSchedule` cron: **every 6 hours** (`0 */6 * * *`)
- Velero TTL: **720 hours** (30 days)
- S3 bucket: `ravi-rosa-hub-hcp-acm-backup` (region `us-east-2`, prefix `acm-hub`)

---

## 4. Component inventory and backup method

### 4.1 ACM hub — backed up by OADP / cluster-backup (T1)

These are captured automatically when `cluster-backup: true` on MultiClusterHub and `BackupSchedule` is `Enabled`:

| Component | Velero schedule | Included resources (examples) |
| --- | --- | --- |
| **ACM governance** | `acm-resources-schedule` | Policies, PolicySets, PlacementBindings, PlacementRules, ManagedClusterSets |
| **ACM applications** | `acm-resources-schedule` | Applications, Subscriptions, Channels, HelmRepos |
| **Generic labeled resources** | `acm-resources-generic-schedule` | Any resource with `cluster.open-cluster-management.io/backup` label |
| **Credentials** | `acm-credentials-schedule` | Hive secrets, pull secrets, provider connections, TLS certs (when labeled) |
| **Managed clusters** | `acm-managed-clusters-schedule` | `ManagedCluster`, `KlusterletAddonConfig`, import/auto-import secrets |
| **Validation** | `acm-validation-policy-schedule` | BackupSchedule heartbeat for governance policies |

**Not included in ACM hub backup:**

| Item | Why | Mitigation |
| --- | --- | --- |
| `local-cluster` ManagedCluster settings | ACM limitation on new hubs | Reconfigure cluster set membership manually |
| Unlabeled GitOps-created Hive secrets | Never in backup scope | Add `cluster.open-cluster-management.io/backup: ""` label |
| Spoke cluster etcd / PV data | Hub backup is metadata, not workload data | Spoke-level backup (OADP on spoke, app backup, etc.) |
| Container images in registries | `backupImages: false` on DPA | Mirror registries / image pull secrets in credentials backup |

### 4.2 Hub cluster operators — GitOps + partial ACM backup (T1 + T2)

Operators deployed via `operator-manifests/` in the GitOps app-of-apps repo:

| Directory | Components | Primary backup | Secondary |
| --- | --- | --- | --- |
| `acm/` | ACM operator Subscription, OperatorGroup, RBAC | Git repo | ACM resources backup (operator CRs) |
| `acm-hub/` | MultiClusterHub (`cluster-backup: true`) | Git repo | ACM resources backup |
| `acm-oadp-backup/` | OADP, DPA, ExternalSecret, BackupSchedule | Git repo | Re-apply after hub rebuild |
| `logging/` | Cluster Logging operator | Git repo | Not in ACM backup — reinstall from git |
| `compliance-operator/` | Compliance Operator + scan profiles | Git repo | Scan CRs may need re-sync; profiles in git |
| `file-integrity-operator/` | FIO + AIDE configs | Git repo | FileIntegrity CRs in git |
| `web-terminal/` | Web Terminal operator | Git repo | Reinstall from git |

**Principle:** GitOps manifests are the **authoritative backup** for operator install and configuration. ACM OADP backup covers **runtime state** (policies, cluster registrations, secrets with backup labels).

### 4.3 Application workloads (T2)

Workloads under `workloads/` in the GitOps repo (e.g. demo apps, ESO-backed deployments):

| Backup type | Method |
| --- | --- |
| Deployment manifests | Git repository |
| Runtime secrets (ESO-synced) | AWS Secrets Manager (source) + optional ACM credentials backup if labeled |
| Persistent volumes | **Not covered** — use CSI snapshots, OADP on namespace, or app-specific backup |

### 4.4 AWS customer-managed infrastructure (T3)

Provisioned by `terraform-acm-backup/` (or equivalent):

| Resource | Purpose | Backup / recovery |
| --- | --- | --- |
| **S3 bucket** | Velero backup storage | Versioning enabled; lifecycle per Terraform; cross-region replication optional (not on ROSA STS restore path) |
| **IAM role** | OADP Velero IRSA | Terraform re-apply on new hub; trust policy uses cluster OIDC |
| **IAM policy** | S3/EC2 permissions for Velero | Terraform |
| **Secrets Manager secret** | `role_arn` + `region` for ExternalSecret | AWS SM replication or export; Terraform can recreate structure |
| **VPC endpoints** (optional) | S3, Secrets Manager for private ROSA | Terraform / IaC documentation |

> Store Terraform state in a **remote backend** (S3 + DynamoDB lock). The state file is part of your DR assets.

### 4.5 GitOps and automation (T2)

| Asset | Location | Recovery |
| --- | --- | --- |
| App-of-apps manifests | `gitops-app-of-apps` GitHub repo | Clone + push; Argo CD re-sync |
| ApplicationSet definitions | `operators-appset.yaml`, `workloads-appset.yaml` | Git |
| Argo CD project config | Cluster or git | Document manual steps if not in git |
| Terraform code | `terraform-acm-backup/` | Git |
| This runbook / docs | `operator-manifests/acm-oadp-backup/docs/` | Git |

### 4.6 Managed (spoke) clusters (T5 — separate plan)

Hub backup preserves **how ACM knows about** spoke clusters. It does **not** back up spoke cluster workloads or nodes.

| Spoke type | Hub backup restores | Spoke recovery |
| --- | --- | --- |
| **Hive-provisioned** | ClusterDeployment metadata, secrets (if labeled) | Hive reprovisions or cluster reconnects after hub restore |
| **Import (detach/attach)** | Import secrets, ManagedCluster CR | Manual re-import if auto-reconnect fails |
| **ROSA/OCP spokes** | Registration + addons config | Spoke cluster DR is independent (ROSA support, OADP on spoke, etc.) |

---

## 5. Backup architecture (implemented)

```
┌──────────────────┐     Git push      ┌─────────────────────┐
│  GitOps repo     │ ────────────────► │  Argo CD / AppSets  │
│  (operators,     │                   │  (hub cluster)      │
│   workloads,     │                   └──────────┬──────────┘
│   acm-oadp)      │                              │
└──────────────────┘                              ▼
                                       ┌─────────────────────┐
                                       │  ACM Hub            │
                                       │  MCH cluster-backup │
                                       │  + OADP / Velero    │
                                       └──────────┬──────────┘
                                                  │ every 6h
                                                  ▼
┌──────────────────┐     IRSA (STS)     ┌─────────────────────┐
│ Secrets Manager  │ ◄── ExternalSecret │  S3 bucket          │
│ (role_arn,       │                    │  ravi-rosa-hub-hcp- │
│  region)         │                    │  acm-backup/acm-hub/ │
└──────────────────┘                    └─────────────────────┘
         ▲
         │ Terraform
┌────────┴─────────┐
│ terraform-acm-   │
│ backup/          │
└──────────────────┘
```

**Three-phase install order** (required before backups run):

1. **Phase 1** — OADP: `overlays/rosa-hcp` (Subscription, ExternalSecret, DPA)
2. **Phase 2** — MCH: `cluster-backup: true`
3. **Phase 3** — `BackupSchedule` (`backup/backupschedule.yaml`)

---

## 6. Customer action items

### 6.1 Required for complete ACM backup coverage

- [ ] Label Hive `ClusterDeployment` secrets: `cluster.open-cluster-management.io/backup: ""`
- [ ] Label any GitOps-managed secrets that must survive hub loss
- [ ] Confirm `BackupSchedule` status is `Enabled` (not `FailedValidation`)
- [ ] Verify BSL `Available` and backups completing in S3
- [ ] Keep GitOps repo as source of truth for all hub operators

### 6.2 Recommended enhancements

| Enhancement | Benefit |
| --- | --- |
| **Passive / standby hub** in same region | Faster failover ([RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) Section 4.2) |
| **S3 versioning + lifecycle** | Protect against accidental object deletion |
| **Terraform remote state** | Recover AWS infra after account/team changes |
| **Secrets Manager backup** | Export or replicate `oadp/acm-backup-credentials` |
| **Quarterly restore drill** | Validate RTO on non-production standby hub |
| **Spoke cluster backup policy** | Document per-cluster workload backup (OADP, RDS, etc.) |

### 6.3 Items explicitly not backed up by this plan

| Item | Recommended approach |
| --- | --- |
| ROSA HCP control plane | Red Hat SLA; rebuild hub cluster via ROSA |
| OpenShift internal registry images | Mirror to Quay/ECR; include pull secrets in labeled secrets |
| Compliance scan results (historical) | Compliance Operator reinstall; rescans produce new results |
| Cluster Logging stored logs | Forward to S3/CloudWatch via logging operator; separate retention |
| Argo CD deployment history | Git commit history is authoritative |
| etcd on hub (worker-hosted resources only) | Velero covers labeled K8s resources; not raw etcd |

---

## 7. Backup schedule and retention

| Parameter | Value | Config location |
| --- | --- | --- |
| Backup frequency | Every 6 hours | `backup/backupschedule.yaml` → `veleroSchedule: "0 */6 * * *"` |
| Retention (Velero TTL) | 30 days (720h) | `backup/backupschedule.yaml` → `veleroTtl: 720h` |
| S3 prefix | `acm-hub/` | `base/dpa.yaml` |
| Backup bucket | `ravi-rosa-hub-hcp-acm-backup` | `overlays/rosa-hcp/kustomization.yaml` |
| AWS region | `us-east-2` (must match cluster) | DPA + Secrets Manager |

**RPO:** Up to 6 hours (worst case if backup fails just after a successful run).

**Retention alignment:** Ensure S3 bucket lifecycle policies do not delete objects before Velero TTL expires. Terraform lifecycle rules should be ≥ 30 days.

---

## 8. Disaster recovery scenarios

| Scenario | Primary recovery path | Documents |
| --- | --- | --- |
| ACM policy/app deleted | Restore from latest Velero backup or Git | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §4.3 |
| Hub cluster lost | New ROSA HCP + GitOps + ACM restore from S3 | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §4.1 |
| Planned hub migration | Passive sync → failover | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §4.2 |
| S3 bucket corrupted | S3 versioning restore; Velero backup from prior version | AWS console / CLI |
| Git repo lost | Restore from GitHub; cluster state from S3 if needed | Git host backup |
| AWS IAM/OIDC drift | Re-run Terraform with new cluster OIDC endpoint | [ROSA-HCP.md](ROSA-HCP.md) |
| Spoke cluster lost | Hub may still show cluster; reprovision via Hive or re-import | Spoke DR plan (separate) |

**ROSA STS constraint:** Restore hub must be in the **same AWS region** as the backup hub. Cross-region ACM restore is not supported.

---

## 9. Validation and review cadence

| Activity | Frequency | Owner | Reference |
| --- | --- | --- | --- |
| Backup health check (BSL, schedules, S3) | Weekly | Platform / SRE | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §2 |
| `backup-restore-enabled` policy compliance | Weekly | Governance | `oc get policy backup-restore-enabled` |
| Review labeled secrets coverage | Monthly | Platform + app teams | Section 6.1 |
| Pre-change on-demand backup | Per change window | Change owner | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §2.6 |
| Restore drill (standby hub) | Quarterly | Platform / DR team | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) §4 |
| Backup plan review | Annually | Architecture / security | This document |

---

## 10. Roles and responsibilities

| Role | Responsibilities |
| --- | --- |
| **Platform team** | OADP/DPA, BackupSchedule, S3/IAM Terraform, hub rebuild, restore execution |
| **GitOps / DevOps** | Maintain `gitops-app-of-apps` repo, Argo CD, operator manifests |
| **ACM / governance** | Policies, placements, applications; ensure backup labels on secrets |
| **Application teams** | Label resources for generic backup; spoke workload DR |
| **Security / compliance** | Compliance Operator configs, audit of backup retention and access |
| **Red Hat (ROSA)** | Hosted control plane availability, platform upgrades, ROSA support |

---

## 11. Related repositories and paths

| Path | Contents |
| --- | --- |
| `operator-manifests/acm-oadp-backup/` | OADP, DPA, BackupSchedule, recovery docs |
| `operator-manifests/acm-hub/` | MultiClusterHub with `cluster-backup: true` |
| `operator-manifests/acm/` | ACM operator install |
| `terraform-acm-backup/` | S3, IAM, Secrets Manager |
| `operators-appset.yaml` | Argo CD ApplicationSet for operators |

---

## 12. References

- [ACM Business continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview)
- [OADP on ROSA STS](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/backup_and_restore/oadp-rosa-backing-up-applications)
- [ROSA HCP overview](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/rosa-architecture/rosa-archit-overview)
- [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) — operational restore procedures
- [ROSA-HCP.md](ROSA-HCP.md) — STS prerequisites

---

## Document control

| Field | Value |
| --- | --- |
| Version | 1.0 |
| Cluster | `ravi-rosa-hub-hcp` (ROSA HCP) |
| Hub namespace | `open-cluster-management-backup` |
| Last updated | 2026-03-19 |
