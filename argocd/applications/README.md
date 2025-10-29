# ArgoCD Applications

This directory contains ArgoCD Application definitions for managing infrastructure and application deployments.

## Structure

### Infrastructure Applications

1. **infrastructure-gateway.yaml**
   - `gateway-api-infrastructure`: Cluster-wide GatewayClass
   - `gateway-dev`: Dev environment Gateway, IP pools, certificates, HTTPRoutes
   - `gateway-staging`: Staging environment (optional)
   - `gateway-production`: Production environment (optional)

2. **infrastructure-monitoring.yaml**
   - Prometheus, Grafana, Alertmanager stack

### Application Deployments

1. **monad-indexer-dev.yaml**
   - Dev environment application deployment

2. **monad-indexer-staging.yaml**
   - Staging environment application deployment

3. **monad-indexer-production.yaml**
   - Production environment application deployment

## Sync Waves

Applications are deployed in order using sync waves:

```
-5: Cilium (installed by k3s-install.sh, not managed by ArgoCD)
-4: External Secrets Operator (manual install)
-3: GatewayClass (cluster-wide)
-2: Environment-specific Gateways, IP pools, certificates
-1: Monitoring infrastructure
 0: Application deployments (default)
```

## Notes

- **Cilium**: Not managed by ArgoCD. Installed by `k3s-install.sh` for bootstrap reliability.
- **Cert-Manager**: Installed manually, not managed by ArgoCD.
- **External Secrets**: Installed manually, not managed by ArgoCD.
- **Gateways**: Each environment has its own Gateway Application pointing to `infrastructure/environments/{env}/`

## Adding New Environment

To add a new environment:

1. Create `infrastructure/environments/new-env/` with required YAML files
2. Add a new Application in `infrastructure-gateway.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-new-env
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/hoodrunio/monad-indexer.git
    path: infrastructure/environments/new-env
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

3. Apply the updated `infrastructure-gateway.yaml`
