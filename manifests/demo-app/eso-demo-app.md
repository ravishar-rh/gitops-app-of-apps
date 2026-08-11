# ESO Demo App

A demo application that verifies the External Secrets Operator (ESO) integration with AWS Secrets Manager through the GitOps App of Apps pattern.

## What This Demo Does

This app deploys a simple pod that loads database credentials from AWS Secrets Manager via a `ClusterSecretStore`. No secret values are stored in git — only an `ExternalSecret` CR that tells ESO where to find them.

## Architecture

```
AWS Secrets Manager                 OpenShift Cluster
┌─────────────────────┐            ┌──────────────────────────────────┐
│                     │            │  ClusterSecretStore              │
│  /demo-app/prod/db  │◄───────────│  (aws-secrets-manager)          │
│  ├── username       │            │         │                       │
│  ├── password       │            │         ▼                       │
│  ├── host           │            │  ExternalSecret                 │
│  ├── port           │            │  (demo-app-db-creds)            │
│  └── dbname         │            │         │                       │
│                     │            │         ▼                       │
│                     │            │  Secret (auto-created by ESO)   │
│                     │            │  (demo-app-db-creds)            │
│                     │            │         │                       │
│                     │            │         ▼                       │
│                     │            │  Deployment (demo-app)          │
│                     │            │  envFrom: secretRef             │
└─────────────────────┘            └──────────────────────────────────┘
```

## Manifests

| File | Purpose |
|------|---------|
| `external-secret.yaml` | Pulls credentials from AWS Secrets Manager and creates a Kubernetes Secret |
| `deployment.yaml` | Pod that consumes the secret as environment variables |
| `service.yaml` | ClusterIP service for the app |

## Prerequisites

- External Secrets Operator installed on the cluster
- A `ClusterSecretStore` named `aws-secrets-manager` configured and healthy
- AWS Secrets Manager accessible from the cluster (IAM role/credentials configured in the SecretStore)

Verify the ClusterSecretStore is ready:

```bash
oc get clustersecretstore aws-secrets-manager
```

## Setup

### Step 1: Create the secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name /demo-app/prod/db \
  --secret-string '{"username":"demo_user","password":"S3cur3P@ssw0rd!","host":"demo-db.abc123.us-east-1.rds.amazonaws.com","port":"5432","dbname":"demo"}'
```

### Step 2: Push and let ArgoCD sync

Once the manifests are pushed to this repo, ArgoCD automatically:

1. Creates the `demo-app` namespace
2. Applies the `ExternalSecret` — ESO reads from AWS Secrets Manager and creates a Kubernetes `Secret` named `demo-app-db-creds`
3. Deploys the pod, which loads all secret values as environment variables via `envFrom`

## Verification

### Check the ExternalSecret status

```bash
oc get externalsecret demo-app-db-creds -n demo-app
```

Expected output — `SecretSynced` with status `Ready`:

```
NAME                 STORE                  REFRESH INTERVAL   STATUS         READY
demo-app-db-creds    aws-secrets-manager    1h                 SecretSynced   True
```

### Check the Kubernetes Secret was created

```bash
oc get secret demo-app-db-creds -n demo-app
```

### Check the pod logs

```bash
oc logs -l app=demo-app -n demo-app
```

Expected output:

```
--- Demo App Started ---
DB_HOST=demo-db.abc123.us-east-1.rds.amazonaws.com
DB_PORT=5432
DB_NAME=demo
DB_USERNAME=demo_user
DB_PASSWORD is set: yes
--- Secrets loaded from AWS Secrets Manager via ESO ---
```

### Verify env vars inside the pod

```bash
oc exec deploy/demo-app -n demo-app -- env | grep DB_
```

## Updating the Secret

Update the secret value in AWS Secrets Manager:

```bash
aws secretsmanager update-secret \
  --secret-id /demo-app/prod/db \
  --secret-string '{"username":"new_user","password":"N3wP@ssw0rd!","host":"demo-db.abc123.us-east-1.rds.amazonaws.com","port":"5432","dbname":"demo"}'
```

ESO refreshes the Kubernetes Secret based on the `refreshInterval` (set to `1h` in this demo). To force an immediate refresh:

```bash
oc annotate externalsecret demo-app-db-creds -n demo-app force-sync=$(date +%s) --overwrite
```

Note: the pod needs a restart to pick up the updated env vars:

```bash
oc rollout restart deployment/demo-app -n demo-app
```

## Cleanup

Remove the demo from the cluster by deleting the directory and pushing:

```bash
rm -rf manifests/demo-app/
git add -A
git commit -m "Remove demo-app"
git push
```

Then clean up the AWS secret:

```bash
aws secretsmanager delete-secret --secret-id /demo-app/prod/db --force-delete-without-recovery
```

## Troubleshooting

### ExternalSecret shows `SecretSyncedError`

Check the ESO controller logs:

```bash
oc logs -l app.kubernetes.io/name=external-secrets -n external-secrets
```

Common causes:
- IAM permissions — the role used by the ClusterSecretStore doesn't have `secretsmanager:GetSecretValue` on the secret ARN
- Secret path mismatch — the `remoteRef.key` doesn't match the secret name in AWS
- Region mismatch — the ClusterSecretStore points to a different AWS region than where the secret was created

### Pod stuck in `CreateContainerConfigError`

The Kubernetes Secret hasn't been created yet. Check the ExternalSecret status:

```bash
oc describe externalsecret demo-app-db-creds -n demo-app
```
