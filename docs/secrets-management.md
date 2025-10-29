# Secrets Management with AWS Secrets Manager

This guide explains how Monad Indexer manages secrets using **External Secrets Operator** and **AWS Secrets Manager**.

## Overview

**Why External Secrets?**
- ✅ Secrets stored in AWS Secrets Manager (centralized, audited)
- ✅ No secrets in Git (encrypted or plain)
- ✅ Automatic secret rotation supported
- ✅ IAM-based access control
- ✅ GitOps-friendly with ArgoCD

## Architecture

```
AWS Secrets Manager (eu-north-1)
  └─ blockscout (single secret containing all credentials)
     ├─ SECRET_KEY_BASE
     ├─ POSTGRES_PASSWORD
     └─ STATS_PASSWORD
          ↓
External Secrets Operator (Kubernetes)
          ↓
Kubernetes Secrets (auto-created)
  ├─ monad-indexer-dev-backend-secret
  ├─ monad-indexer-dev-postgresql-app
  └─ monad-indexer-dev-stats-postgresql-app
          ↓
Application Pods (consume secrets)
```

## Prerequisites

- AWS Account with Secrets Manager access
- AWS CLI installed and configured
- kubectl access to Kubernetes cluster
- Helm 3.x

## Installation

### 1. Install External Secrets Operator

```bash
./infrastructure/external-secrets-operator-install.sh
```

This script will:
- Add External Secrets Helm repository
- Install operator to `external-secrets-system` namespace
- Verify installation

### 2. Create AWS Secret

Create a single secret named `blockscout` containing all credentials:

```bash
# Generate strong credentials
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')
STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# Create single secret in AWS Secrets Manager (eu-north-1)
aws secretsmanager create-secret \
  --name "blockscout" \
  --description "All credentials for Blockscout/Monad Indexer" \
  --secret-string "{\"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\",\"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",\"STATS_PASSWORD\":\"${STATS_PASSWORD}\"}" \
  --region eu-north-1
```

**Secret Structure:**
```json
{
  "SECRET_KEY_BASE": "base64-encoded-key-for-phoenix-backend",
  "POSTGRES_PASSWORD": "base64-encoded-postgres-password",
  "STATS_PASSWORD": "base64-encoded-stats-db-password"
}
```

**Note:** Usernames are hardcoded in Helm templates (`blockscout` for main DB, `stats` for stats DB). Database URIs are auto-generated from passwords.

### 3. Create AWS Credentials Secret in Kubernetes

```bash
# Create Kubernetes Secret with your AWS credentials
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n monad-indexer-dev
```

### 4. Deploy Application

```bash
# Deploy via ArgoCD
kubectl apply -f argocd/applications/monad-indexer-dev.yaml

# Or sync existing app
argocd app sync monad-indexer-dev
```

## Verification

### Check ExternalSecrets

```bash
# List ExternalSecrets
kubectl get externalsecrets -n monad-indexer-dev

# Should show:
# NAME                                     STORE                           REFRESH INTERVAL   STATUS
# monad-indexer-dev-backend                monad-indexer-dev-aws-secrets   1h                 SecretSynced
# monad-indexer-dev-postgresql             monad-indexer-dev-aws-secrets   1h                 SecretSynced
# monad-indexer-dev-stats-postgresql       monad-indexer-dev-aws-secrets   1h                 SecretSynced
```

### Check Created Secrets

```bash
# List secrets
kubectl get secrets -n monad-indexer-dev | grep monad-indexer

# Should show:
# monad-indexer-dev-backend-secret
# monad-indexer-dev-postgresql-app
# monad-indexer-dev-stats-postgresql-app
```

### Check Application Pods

```bash
# Backend should be running
kubectl get pods -n monad-indexer-dev -l app.kubernetes.io/component=backend

# Check logs for any secret-related errors
kubectl logs -n monad-indexer-dev -l app.kubernetes.io/component=backend --tail=50
```

## Secret Rotation

To rotate credentials:

```bash
# 1. Get current secret
CURRENT=$(aws secretsmanager get-secret-value --secret-id blockscout --region eu-north-1 --query SecretString --output text)

# 2. Generate new password
NEW_POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# 3. Update secret in AWS (example: rotating POSTGRES_PASSWORD)
aws secretsmanager update-secret \
  --secret-id "blockscout" \
  --secret-string "{\"SECRET_KEY_BASE\":\"$(echo $CURRENT | jq -r .SECRET_KEY_BASE)\",\"POSTGRES_PASSWORD\":\"${NEW_POSTGRES_PASSWORD}\",\"STATS_PASSWORD\":\"$(echo $CURRENT | jq -r .STATS_PASSWORD)\"}" \
  --region eu-north-1

# 4. Force refresh (or wait up to 1 hour for automatic refresh)
kubectl annotate externalsecret monad-indexer-dev-postgresql \
  force-sync=$(date +%s) \
  -n monad-indexer-dev

# 5. CloudNativePG will automatically restart pods (cnpg.io/reload: "true" label)
```

## Troubleshooting

### ExternalSecret shows "SecretSyncedError"

```bash
# Check ExternalSecret status
kubectl describe externalsecret monad-indexer-dev-backend -n monad-indexer-dev

# Common issues:
# 1. AWS credentials invalid
kubectl get secret aws-credentials -n monad-indexer-dev -o yaml

# 2. Secret doesn't exist in AWS
aws secretsmanager describe-secret \
  --secret-id "blockscout" \
  --region eu-north-1

# 3. IAM permissions insufficient
# Ensure AWS user has: secretsmanager:GetSecretValue permission
```

### SecretStore not ready

```bash
# Check SecretStore
kubectl get secretstore -n monad-indexer-dev
kubectl describe secretstore monad-indexer-dev-aws-secrets -n monad-indexer-dev

# Verify AWS credentials secret exists
kubectl get secret aws-credentials -n monad-indexer-dev
```

### Pods failing to start

```bash
# Check if secrets were created
kubectl get secrets -n monad-indexer-dev

# Check pod events
kubectl describe pod <pod-name> -n monad-indexer-dev

# Common issue: Secret not found
# Solution: Verify ExternalSecret created the secret successfully
```

## Multi-Environment Setup

For multiple environments, use different AWS secret names:

### Staging

```bash
# Create separate secret for staging
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')
STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

aws secretsmanager create-secret \
  --name "blockscout-staging" \
  --description "Staging credentials for Blockscout/Monad Indexer" \
  --secret-string "{\"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\",\"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",\"STATS_PASSWORD\":\"${STATS_PASSWORD}\"}" \
  --region eu-north-1

# Update values-staging.yaml:
# externalSecrets:
#   aws:
#     secretName: "blockscout-staging"
```

### Production

```bash
# Create separate secret for production
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')
STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

aws secretsmanager create-secret \
  --name "blockscout-production" \
  --description "Production credentials for Blockscout/Monad Indexer" \
  --secret-string "{\"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\",\"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",\"STATS_PASSWORD\":\"${STATS_PASSWORD}\"}" \
  --region eu-north-1

# Update values-production.yaml:
# externalSecrets:
#   aws:
#     secretName: "blockscout-production"
```

## Security Best Practices

✅ **DO:**
- Use separate AWS IAM users per environment
- Enable AWS CloudTrail for secret access auditing
- Use least-privilege IAM policies
- Rotate secrets regularly (90 days recommended)
- Enable AWS Secrets Manager automatic rotation

❌ **DON'T:**
- Commit AWS credentials to Git
- Share AWS credentials between environments
- Use root AWS account credentials
- Store secrets in ConfigMaps or environment variables directly

## Cost Estimation

AWS Secrets Manager pricing (eu-north-1):
- $0.40 per secret per month
- $0.05 per 10,000 API calls

For 1 secret per environment:
- Monthly: ~$0.40/environment
- Annual: ~$4.80/environment

**Significant cost savings** compared to 3 separate secrets per environment!

## Migration from SealedSecrets

If migrating from SealedSecrets:

1. Deploy External Secrets Operator
2. Create AWS secrets (steps above)
3. Create AWS credentials secret in Kubernetes
4. Deploy updated Helm chart (will create ExternalSecrets)
5. Verify new secrets are created
6. Delete old SealedSecrets:
   ```bash
   kubectl delete sealedsecret -n monad-indexer-dev --all
   ```

## References

- [External Secrets Operator Docs](https://external-secrets.io)
- [AWS Secrets Manager Docs](https://docs.aws.amazon.com/secretsmanager/)
- [Helm Chart values.yaml](../charts/monad-indexer/values.yaml)
