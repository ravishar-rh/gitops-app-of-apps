# GitOps App of Apps

An ArgoCD (OpenShift GitOps) repository using the **App of Apps** pattern with `ApplicationSets` to manage deployments declaratively. Deploy once, then add applications by simply dropping manifests into this repo — no ArgoCD Application YAMLs needed.

## Repository Structure

```
gitops-app-of-apps/
├── operators-appset.yaml          # ApplicationSet for operators — deploy this once
├── workloads-appset.yaml          # ApplicationSet for app workloads — deploy this once
├── operator-manifests/            # Operator installs (one subdirectory per operator)
│   ├── acm/                       # ACM operator (Namespace, OperatorGroup, Subscription, RBAC)
│   ├── acm-hub/                   # MultiClusterHub CR (separate — needs the CRD from acm first)
│   ├── logging/                   # Cluster Logging operator
│   ├── compliance-operator/       # Compliance Operator + CIS/NIST scan configs
│   ├── file-integrity-operator/   # File Integrity Operator + AIDE node monitoring
│   └── oadp-operator/             # OADP operator + ACM hub backup (ROSA HCP/STS)
└── workloads/                     # Application workloads (one subdirectory per app)
    └── demo-app/                  # ESO demo app (ExternalSecret + Deployment + Service)
```

## How It Works

Two `ApplicationSets` each use a **Git directory generator** to watch their respective directories:

| ApplicationSet | File | Watches | Purpose |
|----------------|------|---------|---------|
| `operators` | `operators-appset.yaml` | `operator-manifests/*` | Operator installs (ACM, ESO, etc.) |
| `workloads` | `workloads-appset.yaml` | `workloads/*` | Application workloads |

For every subdirectory found, ArgoCD automatically:

1. Creates an ArgoCD Application named after the directory
2. Deploys all Kubernetes/OpenShift resources found in that directory
3. Targets a namespace matching the directory name, creating it if it doesn't exist

No manual ArgoCD Application manifests are required. Just drop YAMLs into a directory and push.

## Prerequisites — ArgoCD Permissions

The ArgoCD application controller needs permissions to create resources across namespaces (operators, CRDs, namespaces, etc.). Choose one of the two approaches below.

### Option A: Cluster Admin (simple, broad access)

Grant the ArgoCD service account full cluster-admin privileges:

```bash
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

This is the simplest approach and works for all current and future apps without additional RBAC configuration. Use this if the cluster is dedicated to your team or in non-production environments.

### Option B: Scoped Permissions (least-privilege)

This repo includes scoped RBAC manifests in `operator-manifests/acm/` (`clusterrole.yaml` and `clusterrolebinding.yaml`) that grant only the permissions needed for ACM:

| API Group | Resources |
|-----------|-----------|
| `operator.open-cluster-management.io` | `multiclusterhubs` |
| `operators.coreos.com` | `operatorgroups`, `subscriptions`, `clusterserviceversions`, `installplans` |
| `""` (core) | `namespaces` |

Since ArgoCD needs these permissions before it can sync, apply them manually the first time:

```bash
oc apply -f operator-manifests/acm/clusterrole.yaml
oc apply -f operator-manifests/acm/clusterrolebinding.yaml
```

After the initial apply, ArgoCD manages these RBAC resources going forward via git.

When adding new apps that require access to additional API groups or cluster-scoped resources, you'll need to extend the `ClusterRole` or add new RBAC manifests for each app.

### Switching from Scoped to Cluster Admin

If you start with scoped permissions and later want to switch:

```bash
# Grant cluster-admin
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller

# Clean up the scoped RBAC from the cluster
oc delete clusterrolebinding argocd-acm-manager
oc delete clusterrole argocd-acm-manager
```

Then remove `clusterrole.yaml` and `clusterrolebinding.yaml` from `operator-manifests/acm/` in this repo, commit, and push.

## Getting Started

Apply both ApplicationSets once to your OpenShift cluster:

```bash
oc apply -f operators-appset.yaml
oc apply -f workloads-appset.yaml
```

This creates the ApplicationSets in the `openshift-gitops` namespace. From this point on, everything is driven by git.

## Adding a New Operator

### Step 1: Create a directory and drop your manifests

```bash
mkdir operator-manifests/my-operator
# Add Namespace, OperatorGroup, Subscription YAMLs
```

### Step 2: Commit and push

```bash
git add operator-manifests/my-operator/
git commit -m "Add my-operator"
git push
```

## Adding a New Application Workload

### Step 1: Create a directory and drop your manifests

```bash
mkdir workloads/my-new-app
cp deployment.yaml service.yaml route.yaml workloads/my-new-app/
```

You can put any valid Kubernetes or OpenShift resources here — Deployments, Services, Routes, ConfigMaps, Secrets, ExternalSecrets, CronJobs, etc.

### Step 2: Commit and push

```bash
git add workloads/my-new-app/
git commit -m "Add my-new-app"
git push
```

ArgoCD detects the new directory, creates an Application for it, and syncs all the manifests to the cluster.

## Updating an Application

Edit or add YAML files in the app's directory, commit, and push. ArgoCD syncs the changes automatically.

## Removing an Application

Delete the app's directory:

```bash
rm -rf workloads/my-new-app/
git add -A
git commit -m "Remove my-new-app"
git push
```

The `resources-finalizer.argocd.argoproj.io` finalizer ensures ArgoCD cleans up all deployed resources from the cluster when the Application is removed.

## Sync Policies

All applications are configured with:

| Policy | Description |
|--------|-------------|
| `automated` | ArgoCD syncs automatically when it detects a difference between git and the cluster |
| `prune: true` | Resources removed from git are deleted from the cluster |
| `selfHeal: true` | Manual changes made directly on the cluster are reverted to match git |
| `CreateNamespace=true` | Target namespace is created automatically if it doesn't exist |

## Conventions

| Convention | Detail |
|------------|--------|
| App name | Matches the directory name under `operator-manifests/` or `workloads/` |
| Target namespace | Matches the directory name |
| Branch | `main` (change `targetRevision` in the ApplicationSet to use a different branch) |

## Quick Reference

| Task | Action |
|------|--------|
| Add an operator | Create `operator-manifests/<name>/` and drop your YAMLs in it |
| Add a workload | Create `workloads/<name>/` and drop your YAMLs in it |
| Update an app | Edit files in its directory |
| Remove an app | Delete its directory |
