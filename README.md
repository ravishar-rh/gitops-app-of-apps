# GitOps App of Apps

An ArgoCD (OpenShift GitOps) repository using the **App of Apps** pattern to manage deployments declaratively. Deploy once, then add applications by dropping manifests into this repo.

## Repository Structure

```
gitops-app-of-apps/
├── root-app.yaml              # Root ArgoCD Application — deploy this once
├── apps/                      # ArgoCD Application manifests (one per app)
│   └── sample-app.yaml        # Example: points ArgoCD at manifests/sample-app/
└── manifests/                 # Workload manifests, organized by app
    └── sample-app/
        ├── deployment.yaml
        └── service.yaml
```

## How It Works

The App of Apps pattern creates a hierarchy of ArgoCD Applications:

1. **Root Application** (`root-app.yaml`) watches the `apps/` directory for ArgoCD `Application` manifests.
2. Each manifest in `apps/` defines a child Application that points to a subdirectory under `manifests/`.
3. ArgoCD syncs each child Application independently, deploying whatever Kubernetes/OpenShift resources it finds in the corresponding `manifests/<app-name>/` directory.

When the root app syncs, it picks up any new, modified, or deleted Application manifests in `apps/` automatically. This means adding or removing an app from the cluster is just a git commit.

## Getting Started

### 1. Update the repo URL

Replace the placeholder URL in `root-app.yaml` and every file under `apps/` with your actual repository URL:

```
repoURL: https://github.com/<your-org>/gitops-app-of-apps.git
```

### 2. Deploy the root application

Apply the root application once to your OpenShift cluster:

```bash
oc apply -f root-app.yaml
```

This creates the root ArgoCD Application in the `openshift-gitops` namespace. From this point on, everything is driven by git.

## Adding a New Application

### Step 1: Create a manifests directory

Create a new directory under `manifests/` for your application and drop your Kubernetes/OpenShift YAML files into it:

```bash
mkdir manifests/my-new-app
# Copy or create your manifests
cp deployment.yaml service.yaml route.yaml manifests/my-new-app/
```

You can put any valid Kubernetes or OpenShift resources here — Deployments, Services, Routes, ConfigMaps, Secrets, CronJobs, etc.

### Step 2: Create an ArgoCD Application manifest

Add a YAML file in `apps/` that tells ArgoCD about your new application. Use the sample as a template:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-new-app
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<your-org>/gitops-app-of-apps.git
    targetRevision: main
    path: manifests/my-new-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-new-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Key fields to change per app:
- `metadata.name` — unique name for the ArgoCD Application
- `spec.source.path` — path to the app's manifests directory
- `spec.destination.namespace` — target namespace on the cluster

### Step 3: Commit and push

```bash
git add apps/my-new-app.yaml manifests/my-new-app/
git commit -m "Add my-new-app"
git push
```

ArgoCD detects the change, creates the child Application, and syncs all the manifests to the cluster.

## Updating an Application

Edit or add YAML files in the app's `manifests/<app-name>/` directory, commit, and push. ArgoCD syncs the changes automatically.

## Removing an Application

Delete the Application manifest from `apps/` and optionally remove its `manifests/` subdirectory:

```bash
rm apps/my-new-app.yaml
rm -rf manifests/my-new-app/
git add -A
git commit -m "Remove my-new-app"
git push
```

The `resources-finalizer.argocd.argoproj.io` finalizer ensures ArgoCD cleans up all deployed resources from the cluster when the Application is deleted.

## Sync Policies

All applications are configured with:

| Policy | Description |
|--------|-------------|
| `automated` | ArgoCD syncs automatically when it detects a difference between git and the cluster |
| `prune: true` | Resources removed from git are deleted from the cluster |
| `selfHeal: true` | Manual changes made directly on the cluster are reverted to match git |
| `CreateNamespace=true` | Target namespace is created if it doesn't exist |

## Quick Reference

| Task | Action |
|------|--------|
| Add an app | Create `apps/<name>.yaml` + `manifests/<name>/` with your YAMLs |
| Update an app | Edit files in `manifests/<name>/` |
| Remove an app | Delete `apps/<name>.yaml` and `manifests/<name>/` |
| Change sync target | Edit `targetRevision` in the Application manifest (e.g., `main`, `staging`, a tag) |
| Deploy to a different namespace | Edit `spec.destination.namespace` in the Application manifest |
