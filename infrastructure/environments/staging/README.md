# Staging Environment

This directory will contain staging environment configuration.

## Setup

1. Copy files from `dev/` directory:
   ```bash
   cp ../dev/*.yaml ./
   cp ../dev/config.env ./
   ```

2. Update configuration for staging:
   - `config.env`: Change IP, domains, namespace to staging
   - `lb-ippool.yaml`: Update IP pool CIDR for staging public IP
   - `gateway.yaml`: Update hostnames to staging domains
   - `certificates.yaml`: Update DNS names to staging domains
   - `httproutes.yaml`: Update hostnames and backend services

3. Deploy:
   ```bash
   ../../install-environment.sh staging
   ```

## Example Configuration

```env
# config.env
export ENVIRONMENT="staging"
export NAMESPACE="monad-indexer-staging"
export PUBLIC_IP="10.20.30.40"  # Your staging IP
export IP_POOL_CIDR="10.20.30.40/32"

export DOMAINS=(
  "argocd|cd-staging.hoodscan.io|argocd-server|argocd|443|argocd-tls"
  "monad-indexer|monad-staging.hoodscan.io|backend|monad-indexer-staging|4000|monad-indexer-tls"
)
```
