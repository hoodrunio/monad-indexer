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
  └─ monad-indexer/dev/backend
  └─ monad-indexer/dev/postgresql
  └─ monad-indexer/dev/stats-postgresql
          ↓
External Secrets Operator (Kubernetes)
          ↓
Kubernetes Secrets (auto-created)
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

### 2. Create AWS Secrets

For each environment, create 3 secrets in AWS Secrets Manager:

#### Backend Secret (SECRET_KEY_BASE)

```bash
# Generate a strong secret key
SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n')

# Create in AWS Secrets Manager (eu-north-1)
aws secretsmanager create-secret \
  --name "monad-indexer/dev/backend" \
  --description "Backend secret key for Monad Indexer dev environment" \
  --secret-string "{\"SECRET_KEY_BASE\":\"${SECRET_KEY}\"}" \
  --region eu-north-1
```

#### PostgreSQL Secret

```bash
# Generate password (alphanumeric only - Blockscout compatibility)
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# Create in AWS
aws secretsmanager create-secret \
  --name "monad-indexer/dev/postgresql" \
  --description "PostgreSQL credentials for Monad Indexer dev" \
  --secret-string "{
    \"username\": \"blockscout\",
    \"password\": \"${POSTGRES_PASSWORD}\",
    \"uri\": \"postgresql://blockscout:${POSTGRES_PASSWORD}@monad-indexer-dev-postgresql-rw:5432/blockscout?sslmode=disable\"
  }" \
  --region eu-north-1
```

#### Stats PostgreSQL Secret

```bash
# Generate password
STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# Create in AWS
aws secretsmanager create-secret \
  --name "monad-indexer/dev/stats-postgresql" \
  --description "Stats PostgreSQL credentials for Monad Indexer dev" \
  --secret-string "{
    \"username\": \"stats\",
    \"password\": \"${STATS_PASSWORD}\",
    \"uri\": \"postgresql://stats:${STATS_PASSWORD}@monad-indexer-dev-stats-postgresql-rw:5432/stats?sslmode=disable\"
  }" \
  --region eu-north-1
```

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
# 1. Generate new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# 2. Update secret in AWS
aws secretsmanager update-secret \
  --secret-id "monad-indexer/dev/postgresql" \
  --secret-string "{
    \"username\": \"blockscout\",
    \"password\": \"${NEW_PASSWORD}\",
    \"uri\": \"postgresql://blockscout:${NEW_PASSWORD}@monad-indexer-dev-postgresql-rw:5432/blockscout?sslmode=disable\"
  }" \
  --region eu-north-1

# 3. Force refresh (or wait up to 1 hour for automatic refresh)
kubectl annotate externalsecret monad-indexer-dev-postgresql \
  force-sync=$(date +%s) \
  -n monad-indexer-dev

# 4. Restart pods to use new secret
kubectl rollout restart deployment/monad-indexer-dev-backend -n monad-indexer-dev
kubectl rollout restart statefulset/monad-indexer-dev-postgresql -n monad-indexer-dev
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
  --secret-id "monad-indexer/dev/backend" \
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

### Staging

```bash
# Create secrets with staging prefix
aws secretsmanager create-secret \
  --name "monad-indexer/staging/backend" \
  --secret-string "{\"SECRET_KEY_BASE\":\"$(openssl rand -base64 64 | tr -d '\n')\"}" \
  --region eu-north-1

# Update values-staging.yaml:
# externalSecrets:
#   environment: "staging"
```

### Production

```bash
# Create secrets with production prefix
aws secretsmanager create-secret \
  --name "monad-indexer/production/backend" \
  --secret-string "{\"SECRET_KEY_BASE\":\"$(openssl rand -base64 64 | tr -d '\n')\"}" \
  --region eu-north-1

# Update values-production.yaml:
# externalSecrets:
#   environment: "production"
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

For 3 secrets per environment:
- Monthly: ~$1.20/environment
- Annual: ~$14.40/environment

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
