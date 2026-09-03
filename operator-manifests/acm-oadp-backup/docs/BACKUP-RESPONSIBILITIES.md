# Backup Responsibilities — Red Hat, AWS, and Customer

This document defines **who is responsible for backing up, storing, and recovering** each component in a **ROSA HCP hub cluster with ACM**. It is the authoritative responsibility matrix for backup and disaster recovery planning.

| Related document | Purpose |
| --- | --- |
| [BACKUP-PLAN.md](BACKUP-PLAN.md) | Full backup scope, RPO/RTO, and component inventory |
| [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) | Operational restore procedures |
| [ROSA-HCP.md](ROSA-HCP.md) | STS/IAM prerequisites for OADP |

**Environment reference:** ROSA HCP hub (`ravi-rosa-hub-hcp`), ACM hub backup via OADP → S3 (`ravi-rosa-hub-hcp-acm-backup`, `us-east-2`).

---

## 1. Summary

| Party | Primary role in backup |
| --- | --- |
| **Red Hat** | Platform availability and DR for the **hosted control plane** (HyperShift); ACM/OADP software; ROSA operational support |
| **AWS** | **Infrastructure services** in the customer account — S3 durability, IAM, Secrets Manager, networking; physical/regional resilience |
| **Customer** | **Configuration, data, and operations** — install OADP, run backups, maintain GitOps/Terraform, label secrets, execute restore, spoke cluster DR |

> No single party backs up everything. A complete DR strategy requires all three: Red Hat for the platform layer, AWS for durable storage services, and the customer for ACM state, application config, and runbooks.

---

## 2. Responsibility model

```
                    ┌─────────────────────────────────────┐
                    │           CUSTOMER                  │
                    │  • Install & operate OADP/ACM backup│
                    │  • GitOps, Terraform, labeled secrets│
                    │  • Execute restore & DR drills       │
                    │  • Spoke cluster workload DR         │
                    └──────────────┬──────────────────────┘
                                   │ uses
                    ┌──────────────▼──────────────────────┐
                    │              AWS                     │
                    │  • S3 bucket (backup storage)        │
                    │  • IAM roles / OIDC / Secrets Manager│
                    │  • VPC, endpoints, regional SLA      │
                    │  • Account security & access control │
                    └──────────────┬──────────────────────┘
                                   │ hosts
                    ┌──────────────▼──────────────────────┐
                    │            RED HAT                   │
                    │  • ROSA HCP hosted control plane     │
                    │  • Worker node platform (OCP base)   │
                    │  • ACM / OADP operator software      │
                    │  • Platform upgrades & ROSA support  │
                    └─────────────────────────────────────┘
```

---

## 3. Master responsibility matrix

Legend: **R** = Responsible (owns backup/restore) · **O** = Operates (runs day-to-day) · **P** = Provides (platform/service) · **C** = Contributes (shared) · **—** = Not in scope

### 3.1 ROSA HCP platform

| Component | Red Hat | AWS | Customer |
| --- | --- | --- | --- |
| Hosted control plane (HyperShift / etcd) | **R/P** — platform DR | — | Monitor; rebuild cluster via ROSA if hub lost |
| API server / authentication (hosted) | **R/P** | — | — |
| Worker nodes (EC2) | **P** (via ROSA) | **P** (EC2 service) | **O** — sizing, node pools |
| Worker node OS / machine config | **R/P** | — | **C** — custom MCO if used |
| Core OpenShift operators (platform) | **R/P** | — | **O** — upgrade windows |
| ROSA cluster lifecycle (create/delete/upgrade) | **R/P** | **C** — account quotas | **O** — initiate via ROSA/OCM |
| ROSA SLA / support tickets | **R** | — | **O** — open cases |

### 3.2 ACM hub — multicluster management state

| Component | Red Hat | AWS | Customer |
| --- | --- | --- | --- |
| ACM / MCE operator software | **P** | — | **O** — install via GitOps |
| `cluster-backup` controller | **P** (shipped with ACM) | — | **O** — enable on MCH |
| OADP / Velero operator software | **P** | — | **O** — install in `open-cluster-management-backup` |
| `BackupSchedule` / Velero schedules | **P** (CRD/controller) | — | **R/O** — create & monitor |
| Velero backups (ACM policies, apps, clusters) | **P** (software) | **C** — S3 stores data | **R/O** — configure & validate |
| Hive credentials / labeled secrets | — | **C** — SM if ESO-backed | **R/O** — label + backup via OADP |
| Policies, placements, applications | — | — | **R/O** — backed up via OADP |
| Managed cluster registration metadata | — | — | **R/O** — backed up via OADP |
| Hub restore (`Restore` CR) | **P** (controller) | **C** — S3 read access | **R/O** — execute restore |
| `local-cluster` hub settings | — | — | **R** — manual reconfig on new hub |

### 3.3 Hub cluster — customer workloads and operators

| Component | Red Hat | AWS | Customer |
| --- | --- | --- | --- |
| GitOps repo (operators, workloads) | — | — | **R/O** — git is source of truth |
| Argo CD / OpenShift GitOps | **P** (operator) | — | **O** — config in git or cluster |
| Compliance Operator + scan configs | **P** (operator) | — | **R/O** — configs in git |
| Logging Operator + forwarding | **P** (operator) | **C** — CloudWatch/S3 if forwarded | **R/O** — log destination & retention |
| File Integrity Operator | **P** (operator) | — | **R/O** — configs in git |
| Application workloads on hub | — | — | **R/O** — git + optional OADP/CSI |
| Container images | **C** — integrated registry | **C** — ECR if used | **R** — mirror / pull secrets |

### 3.4 AWS infrastructure (customer account)

| Component | Red Hat | AWS | Customer |
| --- | --- | --- | --- |
| S3 backup bucket | — | **P** — durability, versioning API | **R/O** — create, lifecycle, access |
| S3 backup objects (Velero data) | — | **P** — storage durability | **R** — content produced by OADP |
| IAM roles (OADP Velero IRSA) | — | **P** — IAM service | **R/O** — create trust + policies |
| IAM policies (S3/EC2 for Velero) | — | **P** — IAM service | **R/O** — least-privilege design |
| Secrets Manager secrets | — | **P** — encryption, replication API | **R/O** — secret content & rotation |
| OIDC provider (IRSA) | — | **P** — IAM OIDC | **C** — cluster issuer from ROSA |
| VPC / subnets / security groups | — | **P** — networking | **R/O** — design & Terraform |
| VPC endpoints (S3, Secrets Manager) | — | **P** — endpoint service | **R/O** — enable for private ROSA |
| EC2 instances (workers) | **C** — ROSA provisions | **P** — EC2 | **O** — instance types, scaling |
| Terraform state backend | — | **P** — S3/DynamoDB | **R/O** — remote state config |

### 3.5 Managed (spoke) clusters

| Component | Red Hat | AWS | Customer |
| --- | --- | --- | --- |
| Spoke ROSA HCP / OCP control plane | **R/P** (if ROSA) | **C** | **O** — cluster lifecycle |
| Spoke cluster workloads / PVs | — | **C** — EBS/EFS if used | **R** — per-spoke backup plan |
| Spoke registration on ACM hub | — | — | **R/O** — backed up on **hub** via OADP |
| Hive-provisioned cluster infrastructure | — | **C** — AWS resources in account | **R/O** — Hive + cloud credentials |

---

## 4. Party-specific responsibilities

### 4.1 Red Hat

**Provides:**

- ROSA HCP hosted control plane availability and platform disaster recovery (HyperShift layer)
- OpenShift Container Platform base on worker nodes
- ACM, MCE, cluster-backup, and OADP operator software and documentation
- ROSA support for platform issues, upgrades, and outages

**Does not provide:**

- Backup of customer ACM policies, applications, or credentials
- Backup of customer application workloads on hub or spoke clusters
- Customer S3 bucket or IAM configuration
- Execution of Velero restore or hub failover on behalf of the customer

**Customer expectation:** Open ROSA/ACM support cases for platform defects; do not expect Red Hat to restore customer Velero backups from S3.

---

### 4.2 AWS

**Provides:**

- Durable object storage (S3) with regional SLA and optional versioning/replication
- IAM, STS, and Secrets Manager as services
- EC2, VPC, and networking infrastructure in the customer account
- Physical and regional resilience within the chosen region

**Does not provide:**

- Application-aware backup of ACM or OpenShift resources
- Automatic backup configuration — customer must create buckets, policies, and roles
- Cross-region restore orchestration for ACM (customer must design within ROSA STS limits)
- Guarantee that backup objects exist — only stores what the customer writes

**Customer expectation:** Enable S3 versioning and lifecycle policies; restrict bucket access; use same region as ROSA cluster for STS restore compatibility.

---

### 4.3 Customer

**Responsible for:**

| Area | Actions |
| --- | --- |
| **Backup implementation** | Install OADP, configure DPA, enable `cluster-backup`, deploy `BackupSchedule` |
| **Backup content** | Label secrets for ACM backup; maintain GitOps manifests |
| **AWS backup infra** | S3 bucket, IAM roles, Secrets Manager (e.g. `terraform-acm-backup/`) |
| **Validation** | Weekly BSL/backup checks; governance policy compliance |
| **Restore execution** | `Restore` CR, hub rebuild, passive/active failover |
| **DR planning** | RPO/RTO targets, runbooks, quarterly restore drills |
| **Spoke DR** | Separate plan for workload backup on each managed cluster |
| **Documentation** | Maintain [BACKUP-PLAN.md](BACKUP-PLAN.md) and this matrix |

**Does not rely on Red Hat or AWS for:**

- ACM policy/application state recovery without OADP backups
- GitOps configuration recovery without version control
- Spoke workload recovery from hub backup alone

---

## 5. Backup data flow and ownership

| Step | Action | Owner |
| --- | --- | --- |
| 1 | ACM resources exist on hub cluster | **Customer** (config) · **Red Hat** (platform) |
| 2 | Velero captures labeled/ACM resources | **Red Hat** (OADP/Velero software) · **Customer** (config) |
| 3 | Backup written to S3 | **Customer** (OADP config) · **AWS** (storage) |
| 4 | S3 object durability | **AWS** |
| 5 | IAM authentication (IRSA) | **Customer** (roles) · **AWS** (STS) · **Red Hat** (OIDC issuer on ROSA) |
| 6 | Restore read from S3 | **Customer** (execute) · **AWS** (serve objects) |
| 7 | ACM state recreated on new hub | **Customer** (restore) · **Red Hat** (controllers) |

---

## 6. Common gaps and misconceptions

| Misconception | Reality | Owner to fix |
| --- | --- | --- |
| "ROSA backs up my ACM policies" | ROSA backs up the **hosted control plane**, not ACM app state | **Customer** — OADP |
| "S3 versioning means I'm fully protected" | Versioning protects objects AWS stores; customer must **write** backups first | **Customer** — validate Velero |
| "ACM cluster-backup installs OADP on STS" | On ROSA STS, customer must **GitOps OADP first** | **Customer** |
| "Hub backup restores spoke workloads" | Hub backup restores **registration/metadata** only | **Customer** — spoke DR plan |
| "Red Hat will restore from my S3 bucket" | Customer executes restore; Red Hat supports platform software | **Customer** |
| "Cross-region S3 = cross-region ACM restore" | ROSA STS restore requires **same region** as backup hub | **Customer** — architecture |
| "GitOps secrets are backed up automatically" | Only if labeled `cluster.open-cluster-management.io/backup` | **Customer** |

---

## 7. Escalation path

| Issue | First contact | Escalation |
| --- | --- | --- |
| BSL unavailable, Velero backup failures | **Customer** platform team | [RUNBOOK.md](../RUNBOOK.md), [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) |
| OADP/ACM controller bugs | **Red Hat** support (ROSA/ACM case) | Red Hat SRE |
| S3 access denied, IAM/OIDC errors | **Customer** cloud team | AWS support (customer account) |
| Secrets Manager / ESO sync failures | **Customer** platform + security | AWS support if service issue |
| Hub cluster / API unavailable (platform) | **Red Hat** ROSA support | Red Hat + **Customer** DR plan |
| Restore drill / failover execution | **Customer** DR owner | [RECOVERY-RUNBOOK.md](RECOVERY-RUNBOOK.md) |

---

## 8. Compliance and audit mapping

| Audit question | Answer |
| --- | --- |
| Who defines backup retention? | **Customer** (`veleroTtl`, S3 lifecycle) |
| Who can access backup data? | **Customer** (IAM policies on S3 bucket) |
| Where is backup data stored? | **AWS** S3 in customer account, customer-chosen region |
| Who validates backups run successfully? | **Customer** (monitoring, governance policies) |
| Who is accountable for restore RTO? | **Customer** (DR plan and execution) |
| What does Red Hat attest for ROSA? | Platform SLA — see ROSA subscription terms |
| What does AWS attest for S3? | Storage durability SLA — see AWS service terms |

---

## 9. Quick reference card

```
┌────────────────────────────────────────────────────────────────────────┐
│ RED HAT     → Platform & software (ROSA HCP control plane, ACM, OADP) │
│ AWS         → Storage & identity services (S3, IAM, SM, VPC, EC2)     │
│ CUSTOMER    → Backup config, data, restore, GitOps, spoke DR          │
├────────────────────────────────────────────────────────────────────────┤
│ ACM state on hub        → CUSTOMER (via OADP → AWS S3)                │
│ ROSA control plane      → RED HAT                                       │
│ S3 backup durability    → AWS                                           │
│ GitOps manifests        → CUSTOMER (git)                                │
│ Spoke workloads         → CUSTOMER (per-cluster)                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Document control

| Field | Value |
| --- | --- |
| Version | 1.0 |
| Applies to | ROSA HCP + ACM hub (`ravi-rosa-hub-hcp`) |
| Last updated | 2026-03-19 |
