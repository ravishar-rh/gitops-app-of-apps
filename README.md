# GitOps App of Apps

An ArgoCD (OpenShift GitOps) repository using the **App of Apps** pattern with an `ApplicationSet` to manage deployments declaratively. Deploy once, then add applications by simply dropping manifests into this repo — no ArgoCD Application YAMLs needed.

## Repository Structure

```
gitops-app-of-apps/
├── root-app.yaml              # ApplicationSet — deploy this once
└── manifests/                 # Drop your app manifests here
    ├── acm/                   # ACM operator install (Namespace, OperatorGroup, Subscription, RBAC)
    └── acm-hub/               # MultiClusterHub CR (separate app — needs the CRD from acm first)
```

## How It Works

The `ApplicationSet` uses a **Git directory generator** that watches `manifests/` for subdirectories. For every subdirectory it finds, ArgoCD automatically:

1. Creates an ArgoCD Application named after the directory (e.g. `manifests/my-app/` becomes Application `my-app`)
2. Deploys all Kubernetes/OpenShift resources found in that directory
3. Targets a namespace matching the directory name (e.g. `my-app`), creating it if it doesn't exist

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

This repo includes scoped RBAC manifests in `manifests/acm/` (`clusterrole.yaml` and `clusterrolebinding.yaml`) that grant only the permissions needed for ACM:

| API Group | Resources |
|-----------|-----------|
| `operator.open-cluster-management.io` | `multiclusterhubs` |
| `operators.coreos.com` | `operatorgroups`, `subscriptions`, `clusterserviceversions`, `installplans` |
| `""` (core) | `namespaces` |

Since ArgoCD needs these permissions before it can sync, apply them manually the first time:

```bash
oc apply -f manifests/acm/clusterrole.yaml
oc apply -f manifests/acm/clusterrolebinding.yaml
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

Then remove `clusterrole.yaml` and `clusterrolebinding.yaml` from `manifests/acm/` in this repo, commit, and push.

## Getting Started

Apply the ApplicationSet once to your OpenShift cluster:

```bash
oc apply -f root-app.yaml
```

This creates the ApplicationSet in the `openshift-gitops` namespace. From this point on, everything is driven by git.

## Adding a New Application

### Step 1: Create a directory and drop your manifests

```bash
mkdir manifests/my-new-app
cp deployment.yaml service.yaml route.yaml manifests/my-new-app/
```

You can put any valid Kubernetes or OpenShift resources here — Deployments, Services, Routes, ConfigMaps, Secrets, CronJobs, etc.

### Step 2: Commit and push

```bash
git add manifests/my-new-app/
git commit -m "Add my-new-app"
git push
```

ArgoCD detects the new directory, creates an Application for it, and syncs all the manifests to the cluster in the `my-new-app` namespace.

## Updating an Application

Edit or add YAML files in `manifests/<app-name>/`, commit, and push. ArgoCD syncs the changes automatically.

## Removing an Application

Delete the app's directory:

```bash
rm -rf manifests/my-new-app/
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
| App name | Matches the directory name under `manifests/` |
| Target namespace | Matches the directory name under `manifests/` |
| Branch | `main` (change `targetRevision` in `root-app.yaml` to use a different branch) |

## Quick Reference

| Task | Action |
|------|--------|
| Add an app | Create `manifests/<name>/` and drop your YAMLs in it |
| Update an app | Edit files in `manifests/<name>/` |
| Remove an app | Delete `manifests/<name>/` |
