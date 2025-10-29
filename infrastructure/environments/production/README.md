# Production Environment

This directory will contain production environment configuration.

## Setup

1. Copy files from `dev/` directory:
   ```bash
   cp ../dev/*.yaml ./
   cp ../dev/config.env ./
   ```

2. Update configuration for production:
   - `config.env`: Change IP, domains, namespace to production
   - `lb-ippool.yaml`: Update IP pool CIDR for production public IP
   - `gateway.yaml`: Update hostnames to production domains
   - `certificates.yaml`: Update DNS names to production domains
   - `httproutes.yaml`: Update hostnames and backend services

3. **IMPORTANT**: Use `letsencrypt-prod` issuer for production certificates

4. Deploy:
   ```bash
   ../../install-environment.sh production
   ```

## Example Configuration

```env
# config.env
export ENVIRONMENT="production"
export NAMESPACE="monad-indexer-production"
export PUBLIC_IP="88.99.11.22"  # Your production IP
export IP_POOL_CIDR="88.99.11.22/32"

export DOMAINS=(
  "monad-indexer|monad-indexer.hoodscan.io|backend|monad-indexer-production|4000|monad-indexer-tls"
)

export LETSENCRYPT_ISSUER="letsencrypt-prod"  # IMPORTANT: Use production issuer
```

## Production Checklist

- [ ] DNS records configured and propagated
- [ ] Public IP allocated and routed correctly
- [ ] Let's Encrypt production issuer configured
- [ ] TLS certificates issued and valid
- [ ] Gateway programmed and LoadBalancer IP assigned
- [ ] HTTPRoutes created and routing correctly
- [ ] Backend services healthy
- [ ] Monitoring and alerting configured
- [ ] Backup and disaster recovery plan in place
