# Compliance Operator

Deploys the OpenShift Compliance Operator via OLM for **ROSA HCP** (hosted control plane), with Node-only scan settings for CIS and NIST Moderate benchmarks.

## Target platform: ROSA HCP

This configuration is tailored for **Red Hat OpenShift Service on AWS with hosted control planes (ROSA HCP)**:

- There are **no customer-managed control-plane / master nodes** — only worker nodes.
- The Compliance Operator loads **Node profiles only**. Platform profiles such as `ocp4-cis` and `ocp4-moderate` are **not created**, because the control plane is Red Hat managed and Platform scans are out of scope.
- The default `ScanSetting` targets the `worker` role only (no `master`).

Do **not** reference Platform profiles in ScanSettingBindings on ROSA HCP — bindings will stay `PENDING` with `NamedObjectReference … not found`.

## What is the Compliance Operator?

The Compliance Operator automates compliance scanning of an OpenShift cluster and its nodes against industry security standards. It uses **OpenSCAP**, a NIST-certified tool, under the hood to evaluate cluster configuration against published security benchmarks and produces actionable reports with remediation guidance.

The operator continuously watches for configuration drift and can automatically apply remediations to bring the cluster back into compliance.

## Key Concepts

### Profiles

A **Profile** is a predefined set of compliance rules mapped to a specific security standard. Profiles come bundled with the operator and are read-only. There are two types:

- **Platform profiles** (`ocp4-cis`, `ocp4-moderate`, …) -- scan the OpenShift API server, etcd, OAuth, and other cluster-level configuration. **Not available on ROSA HCP.**
- **Node profiles** (`ocp4-*-node`, `rhcos4-*`) -- scan individual RHCOS worker nodes for filesystem permissions, kernel parameters, services, and more. **Use these on ROSA HCP.**

#### Profiles used by this repo (ROSA HCP)

| Profile | Standard | Scope |
|---|---|---|
| `ocp4-cis-node` | CIS Benchmark | OpenShift config on each worker |
| `ocp4-moderate-node` | NIST 800-53 Moderate (Rev 4) | OpenShift config on each worker |
| `rhcos4-moderate` | NIST 800-53 Moderate (Rev 4) | RHCOS host config on each worker |

#### Other profiles (self-managed / full OCP only)

On a self-managed cluster you would typically also bind Platform variants (`ocp4-cis`, `ocp4-moderate`, `ocp4-pci-dss`, …). Those names will **not** exist on ROSA HCP.

List profiles on your cluster:

```bash
oc get profiles.compliance -n openshift-compliance
# Expect Node / RHCOS profiles only on ROSA HCP:
oc get profiles.compliance -n openshift-compliance | grep -E 'node|rhcos4'
```

### ScanSetting

A **ScanSetting** defines the operational parameters for how scans run:

- **`schedule`** -- cron expression for recurring scans (e.g., `0 1 * * *` for daily at 1 AM)
- **`roles`** -- which node roles to scan (`worker` only on ROSA HCP; do not add `master`)
- **`scanTolerations`** -- tolerations for scheduling scan pods on tainted nodes
- **`rawResultStorage`** -- PVC configuration for storing raw ARF (Asset Reporting Format) results

This repo ships a `default` ScanSetting with `roles: [worker]`.

### ScanSettingBinding

A **ScanSettingBinding** connects one or more Profiles (or TailoredProfiles) to a ScanSetting. When you create a ScanSettingBinding, the operator automatically generates a **ComplianceSuite** which in turn creates individual **ComplianceScan** resources.

This is the primary resource you use to start scanning.

### TailoredProfile

A **TailoredProfile** lets you customize an existing Profile without modifying it directly:

- **Disable rules** that don't apply to your environment (e.g., rules about features you don't use)
- **Enable additional rules** beyond the base profile
- **Set values** for parameterized rules (e.g., password length, SELinux mode)
- **Mark rules as manual** when automated checks aren't possible

### ComplianceSuite and ComplianceScan

These are generated automatically by the operator from ScanSettingBindings. A **ComplianceSuite** groups related scans together, and each **ComplianceScan** targets a specific profile on a specific set of nodes. You generally don't create these directly.

### ComplianceCheckResult

After a scan completes, the operator creates **ComplianceCheckResult** resources for each rule evaluated. Results include:

- **PASS** -- the rule is satisfied
- **FAIL** -- the rule is not satisfied (remediation may be available)
- **MANUAL** -- requires human review
- **NOT-APPLICABLE** -- the rule does not apply to this configuration
- **INCONSISTENT** -- different nodes report different results
- **ERROR** -- the check could not be evaluated

### ComplianceRemediation

For failed checks, the operator may generate **ComplianceRemediation** resources containing MachineConfig or Kubernetes object patches to fix the issue. Remediations can be applied automatically (if enabled) or reviewed and applied manually.

## Compatibility

| Component | Version / notes |
|---|---|
| Platform | ROSA HCP (hosted control plane, workers only) |
| OpenShift | 4.x on ROSA HCP |
| Compliance Operator | 1.10.x (stable channel); Node profiles only on ROSA HCP |
| Catalog Source | redhat-operators |

## Directory Structure

```
compliance-operator/
├── README.md
├── kustomization.yaml                      # references both subdirectories
├── operator/                                # OLM deployment manifests
│   ├── kustomization.yaml
│   ├── namespace.yaml                       # openshift-compliance namespace
│   ├── operatorgroup.yaml
│   └── subscription.yaml
└── config/                                  # scan configuration manifests
    ├── kustomization.yaml
    ├── scansetting.yaml                     # default scan schedule and settings
    ├── scansettingbinding-cis.yaml          # CIS benchmark binding
    ├── scansettingbinding-moderate.yaml      # NIST 800-53 Moderate binding
    ├── scansettingbinding-pci-dss.yaml      # PCI-DSS binding (commented out)
    └── tailoredprofile-cis-custom.yaml      # custom CIS profile example (commented out)
├── config/
│   ├── ...
│   ├── scansettingbinding-soc2.yaml        # SOC 2 composite binding (CIS + Moderate)
│   └── tailoredprofile-soc2.yaml           # SOC 2 tailored baseline
```

- **`operator/`** -- OLM resources to install the Compliance Operator. Deploy this first.
- **`config/`** -- Scan settings and profile bindings. Deploy after the operator is ready. Edit `config/kustomization.yaml` to uncomment additional profiles.

## Deployment

### Via Kustomize / ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: compliance-operator
  namespace: openshift-gitops
spec:
  source:
    path: compliance-operator
    repoURL: <YOUR_REPO_URL>
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
```

### Via CLI

```bash
# Step 1: Deploy the operator
oc apply -k compliance-operator/operator/

# Step 2: Wait for the operator to be ready
oc wait --for=condition=Available deployment/compliance-operator-controller-manager \
  -n openshift-compliance --timeout=300s

# Step 3: Deploy the scan configurations
oc apply -k compliance-operator/config/
```

### Via App of Apps

This directory is picked up automatically by the `operators` ApplicationSet (`operators-appset.yaml`). Argo CD creates an Application named `compliance-operator` that syncs both `operator/` and `config/` from a single kustomization.

**Important:** Installing the operator alone does **not** create PVCs or reports. Those appear only after ScanSettingBindings are applied **and** a ComplianceScan actually runs. The default ScanSetting schedule is `0 1 * * *` (daily at 1:00 AM), so a fresh install can look healthy with zero PVCs until the first scan completes.

On ROSA HCP, bindings that reference Platform profiles (`ocp4-cis`, `ocp4-moderate`, …) stay `PENDING` forever. This repo uses Node profiles only.

## Getting Reports After Install

Follow these steps after the App of Apps (or CLI) deploy to verify the pipeline and produce reports.

### Flow

```
App of Apps → compliance-operator app
  ├─ OLM Subscription          → operator pods
  ├─ ScanSetting (worker only) → schedule, PVC size
  └─ ScanSettingBinding        → Node Profiles → ComplianceSuite → ComplianceScan
                                      ↓ (on schedule or rescan)
                                 PVC (raw ARF) + ComplianceCheckResult (reports)
```

### 1. Confirm the operator is ready

```bash
oc get csv -n openshift-compliance
oc get pods -n openshift-compliance
oc wait --for=condition=Available deployment/compliance-operator \
  -n openshift-compliance --timeout=300s
```

### 2. Confirm ProfileBundles and Node Profiles are loaded

```bash
oc get profilebundle -n openshift-compliance
oc get profiles.compliance -n openshift-compliance | grep -E 'node|rhcos4'
```

On ROSA HCP you should see `ocp4-cis-node`, `ocp4-moderate-node`, and `rhcos4-moderate`. You will **not** see Platform profiles `ocp4-cis` or `ocp4-moderate`.

### 3. Confirm scan config synced from GitOps

Use the Argo CD API group explicitly — bare `oc get application` may resolve to `app.k8s.io` instead of Argo CD:

```bash
oc get applications.argoproj.io -n openshift-gitops
oc get applications.argoproj.io compliance-operator -n openshift-gitops

oc get scansetting -n openshift-compliance
oc get scansettingbinding -n openshift-compliance
```

Expected bindings:

- `cis-compliance` → `ocp4-cis-node`
- `nist-moderate-compliance` → `ocp4-moderate-node`, `rhcos4-moderate`
- `soc2-compliance-mapping` → `ocp4-cis-node`, `ocp4-moderate-node`

**`STATUS: PENDING`** usually means referenced Profiles are missing (for example an old binding still naming `ocp4-cis`) or ProfileBundles are still loading.

```bash
oc describe scansettingbinding cis-compliance -n openshift-compliance
oc get profiles.compliance ocp4-cis-node ocp4-moderate-node rhcos4-moderate \
  -n openshift-compliance
```

### 4. Confirm suites and scans were created

```bash
oc get scansettingbinding -n openshift-compliance
oc get compliancesuites -n openshift-compliance
oc get compliancescans -n openshift-compliance
```

Trigger an immediate rescan instead of waiting for 1:00 AM:

```bash
oc annotate compliancesuites --all \
  -n openshift-compliance \
  compliance.openshift.io/rescan= --overwrite
```

### 5. Wait for scans — PVCs and results appear

```bash
oc get compliancescans -n openshift-compliance -w
oc get pvc -n openshift-compliance
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/check-status=FAIL
```

### 6. Export raw or HTML reports (optional)

```bash
oc krew install compliance

oc compliance fetch-raw scansettingbindings cis-compliance \
  -n openshift-compliance -o ./raw-results/

oc compliance view-result scansettingbindings cis-compliance \
  -n openshift-compliance --output html > report.html
```

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `oc get application` → `applications.app.k8s.io` NotFound | Wrong CRD; use `oc get applications.argoproj.io -n openshift-gitops` |
| `ocp4-cis` / `ocp4-moderate` not found; bindings `PENDING` | Platform profiles are not loaded on ROSA HCP — use Node profiles |
| Operator OK, no ScanSettingBinding | Config sync raced CRDs; re-sync the Argo CD app |
| Suites exist, no PVC | Scan not run yet (`0 1 * * *`); annotate for rescan |
| Scans targeting `master` fail / N/A | No master MCP on ROSA HCP — keep `roles: [worker]` only |
| Scans stuck or Error | StorageClass / PVC provisioning, or profile name mismatch |

## Included Configurations

All bindings below use **Node / RHCOS profiles only**, suitable for ROSA HCP.

### CIS Benchmark (`scansettingbinding-cis.yaml`)

Binds `ocp4-cis-node` to the default scan setting. Scans run daily at 1:00 AM on **worker** nodes.

### NIST 800-53 Moderate (`scansettingbinding-moderate.yaml`)

Binds `ocp4-moderate-node` and `rhcos4-moderate`. Covers OpenShift node config and RHCOS host hardening for FedRAMP Moderate–style baselines on the data plane.

### PCI-DSS (`scansettingbinding-pci-dss.yaml`)

Commented out by default. Uncomment in `config/kustomization.yaml` if you process payment card data. Uses `ocp4-pci-dss-node` only (Platform `ocp4-pci-dss` is not available on ROSA HCP).

### SOC 2 Compliance Mapping (`scansettingbinding-soc2.yaml`)

Combines `ocp4-cis-node` and `ocp4-moderate-node` under a single binding with a `internal-control-id: SOC2-CC6-LOGICAL-ACCESS` label. This label enables downstream GRC tools to ingest and map scan results to SOC 2 Common Criteria controls.

### SOC 2 Tailored Baseline (`tailoredprofile-soc2.yaml`)

A Node TailoredProfile extending `ocp4-cis-node` with SOC 2-specific adjustments. Rules handled by the cloud provider's IAM layer are disabled, and rules requiring manual auditor verification are flagged as `manualRules`. Customize the `disableRules` and `manualRules` lists to match your organization's control mapping.

### Custom CIS Profile (`tailoredprofile-cis-custom.yaml`)

Commented out by default. Example Node TailoredProfile extending `ocp4-cis-node` with rule exceptions. Customize this to disable rules that conflict with your environment.

## Working with Results

### Where Reports Are Generated

Compliance scan results are stored as Kubernetes custom resources in the `openshift-compliance` namespace. The operator creates the following resources after each scan:

| Resource | Description |
|---|---|
| **ComplianceSuite** | Top-level grouping for all scans triggered by a ScanSettingBinding |
| **ComplianceScan** | Individual scan targeting a specific profile on a specific set of nodes |
| **ComplianceCheckResult** | Per-rule result (PASS, FAIL, MANUAL, NOT-APPLICABLE, INCONSISTENT, ERROR) |
| **ComplianceRemediation** | Auto-generated fix (MachineConfig or K8s patch) for failed checks |

Raw scan results in ARF (Asset Reporting Format) and XCCDF XML format are persisted to PVCs in the `openshift-compliance` namespace, controlled by the `rawResultStorage` settings in your ScanSetting (default: 1Gi, 3 rotations).

### Viewing Results via CLI

```bash
# Check scan suite status (DONE, RUNNING, ERROR)
oc get compliancesuites -n openshift-compliance

# List individual scans and their phase
oc get compliancescans -n openshift-compliance

# View all check results
oc get compliancecheckresults -n openshift-compliance

# View only failures
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/check-status=FAIL

# View failures for a specific suite (e.g., SOC 2)
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/suite=soc2-compliance-mapping,compliance.openshift.io/check-status=FAIL

# Get details on a specific check result
oc describe compliancecheckresult <result-name> -n openshift-compliance

# View available remediations
oc get complianceremediations -n openshift-compliance
```

### Viewing Results via OpenShift Console

Navigate to **Installed Operators > Compliance Operator** in the OpenShift web console. From there you can browse:

- **ComplianceSuites** -- overview of all scan suites and their status
- **ComplianceCheckResults** -- drill into individual rule results with descriptions and remediation guidance
- **ComplianceRemediations** -- review and apply fixes directly from the console

### Extracting Raw Reports

Raw ARF/XCCDF reports can be extracted for offline analysis or import into external tools:

```bash
# List raw result PVCs
oc get pvc -n openshift-compliance

# Extract results from a specific scan (creates XML files locally)
SCAN_NAME="cis-compliance-ocp4-cis-node"
POD=$(oc get pods -n openshift-compliance -l compliancescan=$SCAN_NAME \
  -o jsonpath='{.items[0].metadata.name}')
oc cp openshift-compliance/$POD:/results ./compliance-reports/
```

### Applying Remediations

```bash
# Apply a specific remediation
oc patch complianceremediations/<remediation-name> \
  -n openshift-compliance --type merge \
  -p '{"spec":{"apply":true}}'

# Re-scan after applying remediations to verify fixes
oc annotate compliancesuites/<suite-name> \
  -n openshift-compliance compliance.openshift.io/rescan= --overwrite
```

## Integrating with External Systems

### Exporting Results to GRC / SIEM Tools

The Compliance Operator stores results as Kubernetes resources with structured labels, making them straightforward to export to external governance, risk, and compliance (GRC) or SIEM platforms.

#### Using the OpenShift API

Query ComplianceCheckResults directly from any tool that speaks the Kubernetes API:

```bash
# Export all FAIL results as JSON
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/check-status=FAIL \
  -o json > compliance-failures.json

# Export results for a specific control mapping
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/suite=soc2-compliance-mapping \
  -o json > soc2-results.json
```

#### Using the `oc-compliance` Plugin

The `oc-compliance` plugin provides purpose-built commands for extracting and converting compliance data:

```bash
# Install the plugin
oc krew install compliance

# Fetch raw results for a scan
oc compliance fetch-raw scansettingbindings soc2-compliance-mapping \
  -o ./raw-results/

# Generate an HTML report
oc compliance view-result scansettingbindings soc2-compliance-mapping \
  --output html > report.html
```

#### Label-Based Filtering for GRC Ingestion

The SOC 2 ScanSettingBinding includes metadata labels (e.g., `internal-control-id: SOC2-CC6-LOGICAL-ACCESS`) that downstream GRC tools can use to automatically map findings to your control framework. When building integrations:

1. Query by label: `compliance.openshift.io/suite=soc2-compliance-mapping`
2. Map the `internal-control-id` label to your GRC tool's control taxonomy
3. Use the `compliance.openshift.io/check-status` label to filter by result severity

#### Splunk / Elasticsearch Integration

Forward compliance events using a cluster log forwarder or event router:

1. **OpenShift Logging** -- configure a `ClusterLogForwarder` to send audit logs (which include compliance events) to Splunk or Elasticsearch
2. **Event Router** -- deploy the OpenShift Event Router to forward Kubernetes events (including compliance scan lifecycle events) to your log aggregator
3. **CronJob Export** -- schedule a periodic job that queries ComplianceCheckResults and pushes them to your SIEM:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: compliance-exporter
  namespace: openshift-compliance
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: exporter
              image: registry.redhat.io/openshift4/ose-cli:latest
              command:
                - /bin/sh
                - -c
                - |
                  oc get compliancecheckresults -n openshift-compliance \
                    -o json | curl -X POST -H "Content-Type: application/json" \
                    -d @- https://your-siem-endpoint/api/compliance
          restartPolicy: OnFailure
          serviceAccountName: compliance-exporter
```

#### Red Hat Advanced Cluster Security (ACS / StackRox)

If you run ACS, it natively integrates with the Compliance Operator. ACS pulls ComplianceCheckResults and displays them in its compliance dashboard alongside vulnerability and runtime data. No additional export configuration is needed -- ACS discovers the operator automatically.

## References

- [Compliance Operator Documentation (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/compliance-operator)
- [Supported Compliance Profiles](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/security_and_compliance/compliance-operator)
- [Compliance Operator release notes (ROSA HCP Node-only profiles)](https://docs.okd.io/4.22/security/compliance_operator/compliance-operator-release-notes.html)
- [Tailoring the Compliance Operator](https://docs.openshift.com/container-platform/4.15/security/compliance_operator/co-scans/compliance-operator-tailor.html)
- [Compliance Operator CRDs Reference](https://github.com/openshift/compliance-operator/blob/master/doc/crds.md)
- [GitHub - ComplianceAsCode/compliance-operator](https://github.com/ComplianceAsCode/compliance-operator)
