# Sealed Secrets Setup Guide

This guide explains how to set up and use Sealed Secrets for managing sensitive data in the Monad Indexer Helm deployment.

## What are Sealed Secrets?

Sealed Secrets allow you to encrypt Kubernetes Secrets so they can be safely stored in version control (Git). The sealed secrets can only be decrypted by the Sealed Secrets controller running in your Kubernetes cluster.

## Prerequisites

- Kubernetes cluster with kubectl access
- Helm 3.x installed
- `kubeseal` CLI tool installed

## Installation

### 1. Install Sealed Secrets Controller

Install the Sealed Secrets controller in your cluster:

```bash
# Add the Sealed Secrets Helm repository
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets

# Update repositories
helm repo update

# Verify repository was added
helm search repo sealed-secrets

# Install the controller
helm install sealed-secrets-controller sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --create-namespace

# Wait for controller to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n kube-system \
  --timeout=300s

# Verify installation
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

### 2. Install kubeseal CLI

**macOS:**
```bash
brew install kubeseal
```

**Linux:**
```bash
KUBESEAL_VERSION='0.26.0'
wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

## Creating Sealed Secrets for Monad Indexer

### Backend SECRET_KEY_BASE

The backend requires a `SECRET_KEY_BASE` for session encryption. Generate and seal it:

```bash
# 1. Generate a random secret key (using Elixir's mix tool if available)
SECRET_KEY=$(mix phx.gen.secret)

# OR generate using openssl
SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n')

# 2. Create a temporary Kubernetes Secret manifest
cat > /tmp/backend-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-backend-secret
  namespace: default
type: Opaque
stringData:
  secret-key-base: ${SECRET_KEY}
EOF

# 3. Seal the secret
kubeseal --format yaml \
  --cert https://CLUSTER_URL/v1/cert.pem \
  < /tmp/backend-secret.yaml \
  > charts/monad-indexer/templates/backend/sealed-secret.yaml

# 4. Clean up temporary file
rm /tmp/backend-secret.yaml
```

### PostgreSQL Passwords

For production, seal the PostgreSQL passwords:

```bash
# Generate strong password
POSTGRES_PASSWORD=$(openssl rand -base64 32)

# Create secret manifest
cat > /tmp/postgres-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-postgresql-app
  namespace: default
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: blockscout
  password: ${POSTGRES_PASSWORD}
EOF

# Seal it
kubeseal --format yaml \
  < /tmp/postgres-secret.yaml \
  > charts/monad-indexer/templates/postgresql/sealed-secret.yaml

rm /tmp/postgres-secret.yaml
```

### Stats PostgreSQL Password

```bash
# Generate password for stats DB
STATS_PASSWORD=$(openssl rand -base64 32)

cat > /tmp/stats-postgres-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-stats-postgresql-app
  namespace: default
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: stats
  password: ${STATS_PASSWORD}
EOF

kubeseal --format yaml \
  < /tmp/stats-postgres-secret.yaml \
  > charts/monad-indexer/templates/stats-postgresql/sealed-secret.yaml

rm /tmp/stats-postgres-secret.yaml
```

## Using Sealed Secrets with Helm

### Option 1: Replace Default Secrets (Recommended)

After creating sealed secrets, disable the default secret generation in `values.yaml`:

```yaml
backend:
  existingSecret: "monad-indexer-backend-secret"  # Use sealed secret
  secret:
    secretKeyBase: ""  # Leave empty when using sealed secret

postgresql:
  auth:
    existingSecret: "monad-indexer-postgresql-app"
    password: ""  # Leave empty

statsPostgresql:
  auth:
    existingSecret: "monad-indexer-stats-postgresql-app"
    password: ""  # Leave empty
```

### Option 2: Use Annotations for Auto-Sealing

Add annotations to trigger sealed secret creation:

```yaml
backend:
  secret:
    annotations:
      sealedsecrets.bitnami.com/managed: "true"
```

## Verifying Sealed Secrets

Check that sealed secrets are created:

```bash
# List sealed secrets
kubectl get sealedsecrets -n default

# Verify the sealed secret was decrypted to a regular secret
kubectl get secrets -n default | grep monad-indexer
```

## Rotating Secrets

To rotate a secret:

```bash
# 1. Generate new secret
NEW_SECRET=$(mix phx.gen.secret)

# 2. Create new sealed secret with the same name
# (follow the creation steps above)

# 3. Apply the new sealed secret
kubectl apply -f charts/monad-indexer/templates/backend/sealed-secret.yaml

# 4. Restart affected pods
kubectl rollout restart deployment/monad-indexer-backend -n default
```

## Best Practices

1. **Never commit plain secrets to Git** - Only commit sealed secrets
2. **Use namespace-scoped sealing** - Add `--scope namespace-wide` for more security
3. **Backup the sealing key** - Store the controller's private key securely:
   ```bash
   kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
   ```
4. **Rotate secrets regularly** - Set up a rotation schedule (e.g., every 90 days)
5. **Use different secrets per environment** - Create separate sealed secrets for dev/staging/prod

## Troubleshooting

### Secret not decrypting

Check controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=100
```

### Certificate issues

Fetch the public certificate:
```bash
kubeseal --fetch-cert --controller-namespace kube-system --controller-name sealed-secrets-controller
```

### Re-seal with correct certificate

```bash
kubeseal --fetch-cert \
  --controller-namespace=kube-system \
  --controller-name=sealed-secrets-controller \
  > pub-cert.pem

kubeseal --cert=pub-cert.pem --format=yaml < secret.yaml > sealed-secret.yaml
```

## Additional Resources

- [Sealed Secrets GitHub](https://github.com/bitnami-labs/sealed-secrets)
- [Sealed Secrets Documentation](https://sealed-secrets.netlify.app/)
- [CloudNativePG Secret Management](https://cloudnative-pg.io/documentation/current/bootstrap/)

## Example: Complete Setup Workflow

```bash
# 1. Add Sealed Secrets repository
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# 2. Install Sealed Secrets controller
helm install sealed-secrets-controller sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --create-namespace

# 3. Wait for controller to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n kube-system \
  --timeout=300s

# 4. Fetch the public certificate (needed for sealing)
kubeseal --fetch-cert \
  --controller-namespace=kube-system \
  --controller-name=sealed-secrets-controller \
  > pub-sealed-secrets-cert.pem

# 5. Generate all secrets
./scripts/generate-sealed-secrets.sh  # Create this script with above commands

# 6. Update values.yaml to use existing secrets
# 7. Deploy with Helm
helm upgrade --install monad-indexer ./charts/monad-indexer \
  --namespace monad-indexer \
  --create-namespace \
  -f values-production.yaml
```

## Security Considerations

- The sealed secret can only be decrypted in the cluster where it was sealed
- Moving sealed secrets between clusters requires re-sealing with the new cluster's certificate
- Sealed Secrets controller has access to decrypt all sealed secrets - protect the controller namespace
- Consider using external secret management (AWS Secrets Manager, HashiCorp Vault) for enterprise deployments
