# SealedSecrets Deployment Guide

## Problem

Hard-coded SealedSecrets in Helm templates cause conflicts:
- Secret already exists error
- Base64 parse warnings
- Ownership conflicts between manual secrets and SealedSecrets controller

## Solution

**Don't include SealedSecrets in Helm chart templates**. Instead:

1. **Store SealedSecrets separately** in `argocd/sealed-secrets/{env}/` directory
2. **Apply them manually before ArgoCD deployment**
3. **Let Helm chart reference existingSecret only**

## Directory Structure

```
argocd/sealed-secrets/
├── dev/
│   ├── backend-sealed-secret.yaml
│   ├── postgresql-sealed-secret.yaml
│   └── stats-postgresql-sealed-secret.yaml
├── staging/
│   ├── backend-sealed-secret.yaml
│   ├── postgresql-sealed-secret.yaml
│   └── stats-postgresql-sealed-secret.yaml
└── production/
    ├── backend-sealed-secret.yaml
    ├── postgresql-sealed-secret.yaml
    └── stats-postgresql-sealed-secret.yaml
```

## Fresh Deployment Workflow

### 1. Generate Sealed Secrets (One-Time Per Environment)

```bash
# For dev environment
NAMESPACE=monad-indexer-dev ./scripts/seal-secrets.sh

# For staging environment
NAMESPACE=monad-indexer-staging ./scripts/seal-secrets.sh

# For production environment
NAMESPACE=monad-indexer-prod ./scripts/seal-secrets.sh
```

This will create sealed secrets in `charts/monad-indexer/templates/*/sealed-secret.yaml`.

### 2. Move Sealed Secrets to ArgoCD Directory

```bash
# Move dev sealed secrets
mv charts/monad-indexer/templates/backend/sealed-secret.yaml \
   argocd/sealed-secrets/dev/backend-sealed-secret.yaml

mv charts/monad-indexer/templates/postgresql/sealed-secret.yaml \
   argocd/sealed-secrets/dev/postgresql-sealed-secret.yaml

mv charts/monad-indexer/templates/stats-postgresql/sealed-secret.yaml \
   argocd/sealed-secrets/dev/stats-postgresql-sealed-secret.yaml

# Repeat for staging and production
```

### 3. Apply Sealed Secrets to Cluster

**IMPORTANT**: Apply sealed secrets BEFORE deploying Helm chart with ArgoCD.

```bash
# For dev environment
kubectl apply -f argocd/sealed-secrets/dev/

# For staging environment
kubectl apply -f argocd/sealed-secrets/staging/

# For production environment
kubectl apply -f argocd/sealed-secrets/production/
```

### 4. Verify Secrets are Created

```bash
# Check SealedSecret status
kubectl get sealedsecret -n monad-indexer-dev
kubectl get sealedsecret monad-indexer-postgresql-app -n monad-indexer-dev -o yaml

# Verify actual Secret was created by controller
kubectl get secret -n monad-indexer-dev
kubectl get secret monad-indexer-postgresql-app -n monad-indexer-dev -o yaml

# Ensure status is "Synced: True" (not "Degraded")
kubectl get sealedsecret monad-indexer-postgresql-app -n monad-indexer-dev \
  -o jsonpath='{.status.conditions[0].status}'
# Should output: True
```

### 5. Deploy with ArgoCD

```bash
# Helm chart references existing secrets via values.yaml
kubectl apply -f argocd/applications/monad-indexer-dev.yaml

# Or sync existing application
argocd app sync monad-indexer-dev
```

## Values Configuration

Ensure `values.yaml` or `environments/values-{env}.yaml` references the existingSecret:

```yaml
backend:
  existingSecret: "monad-indexer-backend-secret"

postgresql:
  auth:
    existingSecret: "monad-indexer-postgresql-app"
```

## Why This Approach?

### ❌ Wrong Approach (What We Had)
- Hard-coded SealedSecrets in Helm templates
- Helm tries to manage resources that SealedSecrets controller should manage
- Conflicts arise: "Resource already exists and is not managed by SealedSecret"

### ✅ Correct Approach (Production-Ready)
- SealedSecrets deployed **before** Helm chart
- SealedSecrets controller creates Secrets
- Helm chart **only references** existing Secrets
- Clean ownership: SealedSecrets controller owns Secrets, Helm owns application resources

## Troubleshooting

### SealedSecret shows "Degraded" status

```bash
# Check error message
kubectl get sealedsecret <name> -n <namespace> \
  -o jsonpath='{.status.conditions[0].message}'

# Common issues:
# 1. "Resource already exists and is not managed by SealedSecret"
#    Solution: Delete the existing Secret first
kubectl delete secret <name> -n <namespace>

# 2. "illegal base64 data at input byte X"
#    Solution: Regenerate the sealed secret using stringData (not data)

# 3. Secret created manually before SealedSecret applied
#    Solution: Delete Secret, then delete and reapply SealedSecret
kubectl delete secret <name> -n <namespace>
kubectl delete sealedsecret <name> -n <namespace>
kubectl apply -f argocd/sealed-secrets/{env}/<file>.yaml
```

### Base64 Parse Warnings

Always use `stringData` when creating the source Secret (before sealing):

```yaml
# ✅ Correct
stringData:
  username: blockscout
  password: mypassword

# ❌ Wrong - can cause parse errors
data:
  username: YmxvY2tzY291dA==
  password: bXlwYXNzd29yZA==
```

## Updating Secrets

To update a secret (rotate credentials):

```bash
# 1. Create new secret manifest with new values
cat > /tmp/new-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-postgresql-app
  namespace: monad-indexer-dev
type: kubernetes.io/basic-auth
stringData:
  username: blockscout
  password: NEW_PASSWORD_HERE
  uri: postgresql://blockscout:NEW_PASSWORD_HERE@monad-indexer-dev-postgresql-rw:5432/blockscout
EOF

# 2. Seal it
kubeseal --format yaml \
  < /tmp/new-secret.yaml \
  > argocd/sealed-secrets/dev/postgresql-sealed-secret.yaml

# 3. Delete old resources
kubectl delete sealedsecret monad-indexer-postgresql-app -n monad-indexer-dev
kubectl delete secret monad-indexer-postgresql-app -n monad-indexer-dev

# 4. Apply new SealedSecret
kubectl apply -f argocd/sealed-secrets/dev/postgresql-sealed-secret.yaml

# 5. Verify
kubectl get sealedsecret monad-indexer-postgresql-app -n monad-indexer-dev
kubectl get secret monad-indexer-postgresql-app -n monad-indexer-dev

# 6. Commit to Git
git add argocd/sealed-secrets/dev/postgresql-sealed-secret.yaml
git commit -m "chore: rotate postgresql credentials for dev environment"
git push
```

## Security Notes

- ✅ SealedSecrets are safe to commit to Git (encrypted with cluster public key)
- ✅ Only the cluster with matching private key can decrypt them
- ❌ Never commit unencrypted Secrets (the `/tmp/new-secret.yaml` files)
- ✅ Always delete temporary secret files after sealing: `rm /tmp/*.yaml`
