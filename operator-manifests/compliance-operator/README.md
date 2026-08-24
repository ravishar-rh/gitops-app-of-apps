# Compliance Operator

Deploys the OpenShift Compliance Operator via OLM on OpenShift Container Platform 4.22, with pre-configured scan settings for CIS and NIST Moderate benchmarks.

## What is the Compliance Operator?

The Compliance Operator automates compliance scanning of an OpenShift cluster and its nodes against industry security standards. It uses **OpenSCAP**, a NIST-certified tool, under the hood to evaluate cluster configuration against published security benchmarks and produces actionable reports with remediation guidance.

The operator continuously watches for configuration drift and can automatically apply remediations to bring the cluster back into compliance.

## Key Concepts

### Profiles

A **Profile** is a predefined set of compliance rules mapped to a specific security standard. Profiles come bundled with the operator and are read-only. There are two types:

- **Platform profiles** (`ocp4-*`) -- scan the OpenShift API server, etcd, OAuth, and other cluster-level configuration
- **Node profiles** (`ocp4-*-node`, `rhcos4-*`) -- scan individual RHCOS nodes for filesystem permissions, kernel parameters, services, and more

You typically bind both the platform and node variant together to get full coverage.

#### Available Profiles on OCP 4.22

| Profile | Standard | Description |
|---|---|---|
| `ocp4-cis` / `ocp4-cis-node` | CIS Benchmark v1.7.0 | Center for Internet Security best practices for Kubernetes |
| `ocp4-moderate` / `ocp4-moderate-node` | NIST 800-53 Moderate (Rev 4) | Federal risk management framework (FedRAMP baseline) |
| `ocp4-high` / `ocp4-high-node` | NIST 800-53 High (Rev 4) | Highest NIST impact level for critical systems |
| `ocp4-pci-dss` / `ocp4-pci-dss-node` | PCI-DSS v3.2.1 / v4.0 | Payment Card Industry Data Security Standard |
| `ocp4-nerc-cip` / `ocp4-nerc-cip-node` | NERC-CIP | North American Electric Reliability Corporation |
| `ocp4-stig` / `ocp4-stig-node` | DISA STIG V2R2 | Defense Information Systems Agency Security Technical Implementation Guide |
| `ocp4-e8` / `rhcos4-e8` | Essential Eight | Australian Cyber Security Centre mitigation strategies |
| `ocp4-bsi` / `ocp4-bsi-node` / `rhcos4-bsi` | BSI IT-Grundschutz | German Federal Office for Information Security |

List profiles on your cluster:

```bash
oc get profiles.compliance -n openshift-compliance
```

### ScanSetting

A **ScanSetting** defines the operational parameters for how scans run:

- **`schedule`** -- cron expression for recurring scans (e.g., `0 1 * * *` for daily at 1 AM)
- **`roles`** -- which node roles to scan (`worker`, `master`)
- **`scanTolerations`** -- tolerations for scheduling scan pods on tainted nodes
- **`rawResultStorage`** -- PVC configuration for storing raw ARF (Asset Reporting Format) results

The operator ships with a `default` ScanSetting. You can create additional ScanSettings for different scan frequencies or node targeting.

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

| Component | Version |
|---|---|
| OpenShift | 4.22 |
| Compliance Operator | 1.9.x (stable channel) |
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

## Included Configurations

### CIS Benchmark (`scansettingbinding-cis.yaml`)

Binds `ocp4-cis` (platform) and `ocp4-cis-node` (node) profiles to the default scan setting. Scans run daily at 1:00 AM on both master and worker nodes.

### NIST 800-53 Moderate (`scansettingbinding-moderate.yaml`)

Binds `ocp4-moderate` (platform) and `ocp4-moderate-node` (node) profiles. Required for FedRAMP Moderate authorization.

### PCI-DSS (`scansettingbinding-pci-dss.yaml`)

Commented out by default. Uncomment in `config/kustomization.yaml` if you process payment card data. Supports both v3.2.1 and v4.0 profiles.

### Custom CIS Profile (`tailoredprofile-cis-custom.yaml`)

Commented out by default. Example TailoredProfile extending `ocp4-cis` with rule exceptions. Customize this to disable rules that conflict with your environment.

## Working with Results

### View scan status

```bash
oc get compliancesuites -n openshift-compliance
```

### View all check results

```bash
oc get compliancecheckresults -n openshift-compliance
```

### View only failures

```bash
oc get compliancecheckresults -n openshift-compliance \
  -l compliance.openshift.io/check-status=FAIL
```

### View available remediations

```bash
oc get complianceremediations -n openshift-compliance
```

### Apply a specific remediation

```bash
oc patch complianceremediations/<remediation-name> \
  -n openshift-compliance --type merge \
  -p '{"spec":{"apply":true}}'
```

## References

- [Compliance Operator Documentation (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/compliance-operator)
- [Supported Compliance Profiles](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/security_and_compliance/compliance-operator)
- [Tailoring the Compliance Operator](https://docs.openshift.com/container-platform/4.15/security/compliance_operator/co-scans/compliance-operator-tailor.html)
- [Compliance Operator CRDs Reference](https://github.com/openshift/compliance-operator/blob/master/doc/crds.md)
- [GitHub - ComplianceAsCode/compliance-operator](https://github.com/ComplianceAsCode/compliance-operator)
