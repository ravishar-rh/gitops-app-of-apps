# File Integrity Operator

Deploys the OpenShift File Integrity Operator via OLM on OpenShift Container Platform 4.22, with pre-configured integrity monitoring for both worker and master nodes.

## What is the File Integrity Operator?

The File Integrity Operator continuously monitors the filesystems of RHCOS (Red Hat Enterprise Linux CoreOS) cluster nodes for unauthorized modifications. It deploys **AIDE** (Advanced Intrusion Detection Environment) as a privileged DaemonSet on targeted nodes, establishing a known-good baseline database on first run and then periodically scanning for deviations.

This is a critical component of a defense-in-depth security strategy -- if an attacker or misconfiguration alters system files, the operator will detect and report the change.

## Key Concepts

### AIDE (Advanced Intrusion Detection Environment)

**AIDE** is an open-source host-based intrusion detection system. It works by:

1. **Initialization** -- scanning the filesystem and building a database of file attributes (checksums, permissions, ownership, SELinux contexts, extended attributes)
2. **Checking** -- periodically comparing the current filesystem state against the stored database
3. **Reporting** -- logging any differences (added, removed, or changed files)

The File Integrity Operator manages the AIDE lifecycle automatically, handling database initialization, periodic checks, and result reporting through Kubernetes-native CRDs.

### FileIntegrity CR

The **FileIntegrity** custom resource is the primary object you create to enable monitoring. Each FileIntegrity CR deploys a DaemonSet targeting a specific set of nodes. Key fields:

- **`nodeSelector`** -- standard Kubernetes label selector to target specific nodes (e.g., workers, masters, or nodes with custom roles)
- **`tolerations`** -- allows scheduling on tainted nodes (e.g., master nodes with `NoSchedule`)
- **`config.gracePeriod`** -- seconds to wait between consecutive AIDE checks (default: 900 / 15 minutes). Increase for resource-constrained environments
- **`config.maxBackups`** -- maximum number of AIDE database and log backups to retain per node (default: 5). Older backups are automatically pruned
- **`config.initialDelay`** -- seconds to wait before the first AIDE check after pod startup (default: 0). Useful to avoid scanning during node bootstrap
- **`config.name/namespace/key`** -- reference to a ConfigMap containing a custom AIDE configuration (optional, uses a sensible CoreOS-optimized default if omitted)
- **`debug`** -- enable verbose logging in the DaemonSet pods

### FileIntegrity Status Phases

Each FileIntegrity CR reports its lifecycle phase:

| Phase | Description |
|---|---|
| **Pending** | CR created, DaemonSet not yet deployed |
| **Active** | DaemonSet is running and AIDE checks are executing on schedule |
| **Initializing** | AIDE database is being built or re-initialized |

### FileIntegrityNodeStatus

The operator creates a **FileIntegrityNodeStatus** resource for each node being monitored. These report the per-node integrity state:

| Status | Meaning |
|---|---|
| **Succeeded** | Last AIDE check passed -- no file changes detected |
| **Failed** | File changes detected -- review the AIDE log for details |
| **Errored** | AIDE could not run (permissions, resource issues, etc.) |

### Custom AIDE Configuration

The default AIDE configuration is optimized for RHCOS and monitors key system directories (`/boot`, `/root`, `/usr`, `/etc`, `/opt`) while excluding paths that change frequently (e.g., `/etc/kubernetes/aide.*`, `/etc/machine-config-daemon`).

You can provide a **custom AIDE configuration** via a ConfigMap to:

- Add directories to monitor (e.g., `/opt/myapp/bin`)
- Exclude additional paths that are expected to change
- Change the hash algorithm or attribute checks
- Monitor application-specific files

The operator automatically prefixes all paths with `/hostroot/` since AIDE runs in a container with the host filesystem mounted.

### Relationship to the Compliance Operator

The File Integrity Operator and Compliance Operator are complementary:

- **Compliance Operator** -- checks configuration *settings* against policy (are the right values set?)
- **File Integrity Operator** -- checks file *contents* for changes over time (has anything been modified?)

Both are typically deployed together as part of a comprehensive security posture on OpenShift.

## Compatibility

| Component | Version |
|---|---|
| OpenShift | 4.22 |
| File Integrity Operator | 1.3.x (stable channel) |
| Catalog Source | redhat-operators |

## Directory Structure

```
file-integrity-operator/
├── README.md
├── kustomization.yaml                    # references both subdirectories
├── operator/                              # OLM deployment manifests
│   ├── kustomization.yaml
│   ├── namespace.yaml                     # openshift-file-integrity namespace
│   ├── operatorgroup.yaml
│   └── subscription.yaml
└── config/                                # monitoring configuration manifests
    ├── kustomization.yaml
    ├── fileintegrity-worker.yaml          # default AIDE on worker nodes
    ├── fileintegrity-master.yaml          # default AIDE on master nodes
    ├── aide-config.yaml                   # custom AIDE config (commented out)
    └── fileintegrity-worker-custom.yaml   # worker config using custom AIDE (commented out)
```

- **`operator/`** -- OLM resources to install the File Integrity Operator. Deploy this first.
- **`config/`** -- FileIntegrity CRs that define what to monitor. Deploy after the operator is ready. Edit `config/kustomization.yaml` to uncomment custom AIDE configuration.

## Deployment

### Via Kustomize / ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: file-integrity-operator
  namespace: openshift-gitops
spec:
  source:
    path: file-integrity-operator
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
oc apply -k file-integrity-operator/operator/

# Step 2: Wait for the operator to be ready
oc wait --for=condition=Available deployment/file-integrity-operator-controller-manager \
  -n openshift-file-integrity --timeout=300s

# Step 3: Deploy the monitoring configurations
oc apply -k file-integrity-operator/config/
```

## Included Configurations

### Worker Node Monitoring (`fileintegrity-worker.yaml`)

Monitors all worker nodes with the default AIDE configuration:
- Grace period: 900s (15 minutes between checks)
- Max backups: 5 per node
- Initial delay: 60s (waits 1 minute before first check)

### Master Node Monitoring (`fileintegrity-master.yaml`)

Monitors all master/control-plane nodes with a toleration for the `NoSchedule` taint. Same timing settings as workers.

### Custom AIDE Configuration (`aide-config.yaml` + `fileintegrity-worker-custom.yaml`)

Commented out by default. Uncomment in `config/kustomization.yaml` to deploy workers with a customized AIDE config that:
- Extends the grace period to 1800s (30 minutes)
- Retains 7 backups
- Uses a 120s initial delay
- References a custom AIDE ConfigMap for directory inclusions/exclusions

To customize, edit the `aide-config.yaml` ConfigMap to add or exclude paths for your environment.

## Working with Results

### Check overall status

```bash
oc get fileintegrities -n openshift-file-integrity
```

### Check per-node integrity status

```bash
oc get fileintegritynodestatuses -n openshift-file-integrity
```

### View details for a failed node

```bash
oc get fileintegritynodestatuses -n openshift-file-integrity \
  -o jsonpath='{.items[?(@.results[0].condition=="Failed")].nodeName}'
```

### View the AIDE log from a specific node's pod

```bash
# Find the daemon pod on the node
oc get pods -n openshift-file-integrity -o wide | grep <node-name>

# Check the AIDE log
oc logs <pod-name> -n openshift-file-integrity
```

### Re-initialize the AIDE database

After expected changes (e.g., OS updates, MachineConfig changes), reinitialize the database by annotating the FileIntegrity CR:

```bash
oc annotate fileintegrities/worker-fileintegrity \
  -n openshift-file-integrity \
  file-integrity.openshift.io/re-init=
```

## Verifying the Operator Is Working

### Step 1: Check the Operator Is Running

```bash
# Operator pod should be Running
oc get pods -n openshift-file-integrity

# CSV should show Succeeded
oc get csv -n openshift-file-integrity
```

### Step 2: Check FileIntegrity CR Status

```bash
# Both CRs should show phase: Active
oc get fileintegrities -n openshift-file-integrity
```

Expected output:

```
NAME                    AGE   PHASE
worker-fileintegrity    10m   Active
master-fileintegrity    10m   Active
```

If the phase is still `Initializing`, AIDE is building its initial database -- wait a few minutes.

### Step 3: Check the DaemonSet Pods

```bash
# One pod per targeted node should be Running
oc get pods -n openshift-file-integrity -o wide

# Pod count should match your node count
oc get daemonsets -n openshift-file-integrity
```

### Step 4: Check Per-Node Integrity Status

```bash
oc get fileintegritynodestatuses -n openshift-file-integrity
```

Expected output:

```
NAME                                            NODE          STATUS
worker-fileintegrity-ip-10-0-1-100.ec2.local    ip-10-0-...  Succeeded
worker-fileintegrity-ip-10-0-1-101.ec2.local    ip-10-0-...  Succeeded
```

### Step 5: Simulate a Change (Validation Test)

To confirm the operator actually detects changes, trigger a controlled modification on a node:

```bash
# Open a debug shell on a worker node
oc debug node/<node-name>

# Inside the debug pod
chroot /host
touch /etc/test-integrity-check
exit
exit
```

Wait for the next scan cycle (default `gracePeriod` is 900s / 15 minutes), then check:

```bash
# This node should now show Failed
oc get fileintegritynodestatuses -n openshift-file-integrity
```

### Step 6: View the AIDE Log Details

When a node reports `Failed`, get the details:

```bash
# Find the configmap with the AIDE log for the failed node
oc get configmaps -n openshift-file-integrity -l file-integrity.openshift.io/log=

# Read the log
oc get configmap <configmap-name> -n openshift-file-integrity -o jsonpath='{.data.integritylog}'
```

The log will show exactly which files were added, removed, or changed.

### Step 7: Clean Up and Re-initialize

After verifying detection works, clean up and reinitialize the database:

```bash
# Remove the test file
oc debug node/<node-name> -- chroot /host rm /etc/test-integrity-check

# Re-initialize the AIDE database to accept current state as the new baseline
oc annotate fileintegrities/worker-fileintegrity \
  -n openshift-file-integrity \
  file-integrity.openshift.io/re-init=
```

Wait for the phase to go from `Initializing` back to `Active`, then verify the node returns to `Succeeded`.

### Quick Health Check (All-in-One)

```bash
echo "=== Operator ===" && \
oc get csv -n openshift-file-integrity && \
echo "=== FileIntegrity CRs ===" && \
oc get fileintegrities -n openshift-file-integrity && \
echo "=== DaemonSets ===" && \
oc get daemonsets -n openshift-file-integrity && \
echo "=== Node Statuses ===" && \
oc get fileintegritynodestatuses -n openshift-file-integrity && \
echo "=== Events ===" && \
oc get events -n openshift-file-integrity --sort-by='.lastTimestamp' | tail -10
```

Everything is healthy when: the CSV shows `Succeeded`, FileIntegrity CRs are `Active`, DaemonSet desired/ready counts match, and all node statuses show `Succeeded`.

## References

- [File Integrity Operator Documentation (OCP 4.18)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/file-integrity-operator)
- [Configuring the File Integrity Operator (OCP 4.14)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html/security_and_compliance/file-integrity-operator)
- [GitHub - openshift/file-integrity-operator](https://github.com/openshift/file-integrity-operator)
