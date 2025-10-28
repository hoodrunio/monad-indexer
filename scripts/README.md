# Scripts

This directory contains utility scripts for managing the Monad Indexer deployment.

## seal-secrets.sh

Automatically generates and seals all required Kubernetes secrets for the Monad Indexer application.

### Prerequisites

- `kubeseal` CLI tool installed
- `kubectl` configured with access to your cluster
- Sealed Secrets controller running in the cluster

### Usage

Basic usage (uses `default` namespace):
```bash
./scripts/seal-secrets.sh
```

With custom namespace:
```bash
NAMESPACE=monad-indexer ./scripts/seal-secrets.sh
```

### What it does

1. **Checks prerequisites**: Verifies kubeseal and kubectl are installed
2. **Fetches sealing certificate**: Gets the public certificate from your cluster's Sealed Secrets controller
3. **Generates secrets**:
   - Backend `SECRET_KEY_BASE` (64-byte random key)
   - PostgreSQL password (32-byte random)
   - Stats PostgreSQL password (32-byte random)
4. **Seals secrets**: Encrypts them using the cluster's certificate
5. **Saves to chart templates**: Stores sealed secrets in appropriate locations:
   - `charts/monad-indexer/templates/backend/sealed-secret.yaml`
   - `charts/monad-indexer/templates/postgresql/sealed-secret.yaml`
   - `charts/monad-indexer/templates/stats-postgresql/sealed-secret.yaml`

### Safety

- Sealed secrets are **safe to commit to Git**
- They can only be decrypted by the Sealed Secrets controller in your cluster
- Original plain-text secrets are never written to disk
- Temporary files are cleaned up after sealing

### Example

```bash
$ ./scripts/seal-secrets.sh
===============================================
  Monad Indexer - Auto Seal Secrets
===============================================

[INFO] Checking prerequisites...
[INFO] Prerequisites OK
[INFO] Fetching sealing certificate from cluster...
[INFO] Certificate saved to pub-sealed-secrets-cert.pem
[WARN] This will generate NEW sealed secrets. Existing secrets will be overwritten.
Continue? (y/N) y
[INFO] Generating backend SECRET_KEY_BASE...
[INFO] Backend sealed secret created at charts/monad-indexer/templates/backend/sealed-secret.yaml
[INFO] Generating PostgreSQL password...
[INFO] PostgreSQL sealed secret created at charts/monad-indexer/templates/postgresql/sealed-secret.yaml
[INFO] Generating Stats PostgreSQL password...
[INFO] Stats PostgreSQL sealed secret created at charts/monad-indexer/templates/stats-postgresql/sealed-secret.yaml
[INFO] ✓ All secrets sealed successfully!

Next steps:
  1. Review the generated sealed secrets in charts/monad-indexer/templates/
  2. Commit them to Git (they are safe to commit)
  3. Update your values.yaml to use existingSecret
  4. Deploy with: helm upgrade --install monad-indexer ./charts/monad-indexer
```

## Using with Makefile

For convenience, you can use the Makefile commands:

```bash
# Setup everything
make dev-setup

# Or step by step:
make setup-sealed-secrets  # Install controller
make seal-secrets          # Generate and seal secrets
make deploy               # Deploy the application
```

## Troubleshooting

### Error: kubeseal is not installed

Install kubeseal:
```bash
# macOS
brew install kubeseal

# Linux
KUBESEAL_VERSION='0.26.0'
wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### Error: Sealed Secrets controller not found

Install the controller first:
```bash
make setup-sealed-secrets
```

Or manually:
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
```

### Secrets not decrypting in cluster

Check controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=100
```

Verify the sealed secret was created:
```bash
kubectl get sealedsecrets -n default
kubectl get secrets -n default | grep monad-indexer
```

## Security Notes

- **Never commit the sealing certificate** (`pub-sealed-secrets-cert.pem`) to Git - it's regenerated each time
- **Backup the controller's private key** if you need to restore:
  ```bash
  kubectl get secret -n kube-system sealed-secrets-key -o yaml > backup.yaml
  ```
- **Rotate secrets regularly** (recommended: every 90 days)
- Sealed secrets are **cluster-specific** - you need to re-seal for different clusters
