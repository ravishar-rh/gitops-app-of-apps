# GitOps App of Apps

An ArgoCD (OpenShift GitOps) repository using the **App of Apps** pattern with an `ApplicationSet` to manage deployments declaratively. Deploy once, then add applications by simply dropping manifests into this repo — no ArgoCD Application YAMLs needed.

## Repository Structure

```
gitops-app-of-apps/
├── root-app.yaml              # ApplicationSet — deploy this once
└── manifests/                 # Drop your app manifests here
    └── sample-app/            # Each subdirectory becomes an ArgoCD Application
        ├── deployment.yaml
        └── service.yaml
```

## How It Works

The `ApplicationSet` uses a **Git directory generator** that watches `manifests/` for subdirectories. For every subdirectory it finds, ArgoCD automatically:

1. Creates an ArgoCD Application named after the directory (e.g. `manifests/my-app/` becomes Application `my-app`)
2. Deploys all Kubernetes/OpenShift resources found in that directory
3. Targets a namespace matching the directory name (e.g. `my-app`), creating it if it doesn't exist

No manual ArgoCD Application manifests are required. Just drop YAMLs into a directory and push.

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
