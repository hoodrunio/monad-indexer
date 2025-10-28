# Monad Indexer Helm Chart

Production-grade Helm chart for deploying Blockscout blockchain indexer for Monad network with high availability, auto-scaling, and GitOps support.

## Features

✅ **Production-Ready**: CloudNativePG for PostgreSQL HA, Redis Sentinel, auto-scaling
✅ **High-Throughput**: Optimized for 5000+ TPS blockchain indexing
✅ **GitOps**: Full ArgoCD integration with app-of-apps pattern
✅ **Security**: Pod Security Standards, NetworkPolicies, External Secrets Operator
✅ **Monitoring**: Prometheus ServiceMonitors, Grafana dashboards, comprehensive alerts
✅ **Scalable**: Seamless scaling from 1 node → multi-node without architecture changes

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                   │
│                                                          │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────┐│
│  │   Backend    │──▶│  PgBouncer   │──▶│ PostgreSQL  ││
│  │  (2-20 pods) │   │  (pooling)   │   │  Primary    ││
│  └──────────────┘   └──────────────┘   └─────────────┘│
│         │                                      │        │
│         ├──────────────────────────────────────┘        │
│         │                                               │
│  ┌──────▼───────┐                      ┌─────────────┐│
│  │ Microservices│                      │ PostgreSQL  ││
│  │  - Verifier  │                      │  Replicas   ││
│  │  - SigProvider│                      │  (2 pods)   ││
│  │  - Visualizer │                      └─────────────┘│
│  │  - Stats     │                                      │
│  └──────────────┘                                      │
│         │                                               │
│  ┌──────▼───────┐                                      │
│  │    Redis     │                                      │
│  │ Master+Replicas│                                     │
│  └──────────────┘                                      │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Kubernetes cluster 1.25+ (K3s, EKS, GKE, AKS)
- Helm 3.12+
- kubectl configured
- ArgoCD installed (optional, for GitOps)

### Installation (Standalone)

```bash
# Add dependencies
helm dependency update

# Install for development
helm install monad-indexer . \
  -f values.yaml \
  -f environments/values-dev.yaml \
  -n monad-indexer-dev \
  --create-namespace

# Install for production
helm install monad-indexer . \
  -f values.yaml \
  -f environments/values-production.yaml \
  -n monad-indexer-prod \
  --create-namespace
```

### Installation (GitOps with ArgoCD)

```bash
# Install root application (app-of-apps)
kubectl apply -f ../../argocd/bootstrap/root-app.yaml

# This will automatically deploy:
# - dev environment (auto-sync)
# - staging environment (auto-sync)
# - production environment (manual sync)
```

## Configuration

### Environment-Specific Values

| File | Environment | Use Case | Monthly Cost |
|------|-------------|----------|--------------|
| `values-dev.yaml` | Development | Single instance, minimal resources | $50-100 |
| `values-staging.yaml` | Staging | Production-like, smaller scale | $300-500 |
| `values-production.yaml` | Production | Full HA, auto-scaling | $600-1500 |

### Key Configuration Options

#### Backend (Indexer + API)

```yaml
backend:
  replicaCount: 2
  resources:
    requests:
      cpu: "2000m"
      memory: "4Gi"
    limits:
      memory: "8Gi"
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
  env:
    ETHEREUM_JSONRPC_HTTP_URL: "https://testnet-rpc.monad.xyz"
    CHAIN_ID: "10143"
```

#### PostgreSQL (CloudNativePG)

```yaml
postgresql:
  enabled: true
  replicaCount: 3  # 1 primary + 2 read replicas
  config:
    sharedBuffers: "8GB"
    maxConnections: 500
    synchronousCommit: "off"  # For performance
  primary:
    persistence:
      size: 500Gi
      storageClass: "fast-ssd"
  pooler:
    enabled: true  # PgBouncer connection pooling
```

#### Redis (Sentinel HA)

```yaml
redis:
  enabled: true
  architecture: replication
  sentinel:
    enabled: true
    quorum: 2
  replica:
    replicaCount: 3
```

## Scaling

### Vertical Scaling (Single Node → Bigger Node)

```yaml
# Update resources in values-production.yaml
postgresql:
  primary:
    resources:
      requests:
        cpu: "8000m"  # Increase from 4000m
        memory: "32Gi"  # Increase from 16Gi
```

### Horizontal Scaling (Add More Nodes)

```yaml
# Update replica counts
backend:
  replicaCount: 10  # Increase from 5

postgresql:
  replicaCount: 5  # Add more read replicas
```

### Auto-Scaling (HPA)

```yaml
backend:
  autoscaling:
    enabled: true
    minReplicas: 5
    maxReplicas: 20  # Increase max
    targetCPUUtilizationPercentage: 60  # Scale earlier
```

## Monitoring

### Prometheus Metrics

Automatically exposed via ServiceMonitors:

- **Backend**: `/metrics` on port 4000
- **PostgreSQL**: Port 9187 (CloudNativePG exporter)
- **PgBouncer**: Port 9127
- **Redis**: Port 9121

### Grafana Dashboards

Import dashboards from `../../monitoring/grafana-dashboards/`:

- `postgres.json` - PostgreSQL metrics
- `blockscout-indexer.json` - Indexer performance
- `kubernetes.json` - Cluster health

### Alerts

PrometheusRule includes alerts for:

- Indexing lag > 100 blocks
- Backend pods down
- PostgreSQL replication lag
- High CPU/memory usage
- Database connection limits
- Disk space warnings

## Backup & Restore

### Automated Backups (pgBackRest)

```yaml
postgresql:
  backup:
    enabled: true
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: "s3://your-bucket/backups"
```

### Manual Backup

```bash
# Trigger backup
kubectl cnpg backup monad-indexer-postgresql

# List backups
kubectl cnpg backup list monad-indexer-postgresql
```

### Restore

```bash
# Create cluster from backup
kubectl cnpg restore monad-indexer-postgresql \
  --backup backup-20241028-120000
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n monad-indexer-prod
```

### View Logs

```bash
# Backend logs
kubectl logs -f deployment/monad-indexer-backend -n monad-indexer-prod

# PostgreSQL logs
kubectl logs -f monad-indexer-postgresql-1 -n monad-indexer-prod
```

### Check Database Connection

```bash
# Connect to PostgreSQL
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- psql -U postgres

# Check replication status
SELECT * FROM pg_stat_replication;
```

### Check Indexing Progress

```bash
# API call
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-prod
curl http://localhost:4000/api/v2/stats | jq
```

## Upgrade

### Helm Upgrade

```bash
helm upgrade monad-indexer . \
  -f values.yaml \
  -f environments/values-production.yaml \
  -n monad-indexer-prod
```

### GitOps Upgrade

```bash
# Update values in Git
git commit -am "Update backend image to v9.0.3"
git push

# ArgoCD automatically syncs (or manual sync for production)
argocd app sync monad-indexer-production
```

## Security

### Pod Security Standards

All pods run with:
- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities: drop: [ALL]`

### Network Policies

Strict network policies enabled by default:
- Backend → PostgreSQL, Redis, Microservices, External RPC
- PostgreSQL → Only from Backend
- Redis → Only from Backend

### Secrets Management

Use External Secrets Operator:

```yaml
# Create ExternalSecret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
spec:
  secretStoreRef:
    name: aws-secrets-manager
  data:
    - secretKey: password
      remoteRef:
        key: monad-indexer/postgresql
        property: password
```

## Performance Tuning

### PostgreSQL (5k TPS Optimizations)

```yaml
postgresql:
  config:
    synchronousCommit: "off"  # 1.5x performance boost
    sharedBuffers: "8GB"
    effectiveCacheSize: "24GB"
    walBuffers: "64MB"
    maxWalSize: "8GB"
    randomPageCost: "1.1"  # For NVMe SSD
```

### Backend (Indexer Tuning)

```yaml
backend:
  env:
    POOL_SIZE: "80"  # Database connection pool
    INDEXER_MEMORY_LIMIT: "5"
    INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER: "false"
```

## Cost Optimization

### Development (~$50-100/month)

- 1 node
- 1 PostgreSQL instance
- No replicas
- Minimal resources

### Staging (~$300-500/month)

- 1-2 nodes
- PostgreSQL HA (3 instances)
- Redis HA (3 instances)
- Moderate resources

### Production (~$600-1500/month)

- 3+ nodes
- Full HA for all services
- Auto-scaling enabled
- High-performance storage

### Self-Hosted (Break-even: 10 months)

- Bare metal: ~$125/month ongoing cost
- Initial investment: ~$6800
- Best long-term cost efficiency

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `backend.replicaCount` | Number of backend pods | `2` |
| `backend.resources.requests.cpu` | Backend CPU request | `2000m` |
| `backend.resources.requests.memory` | Backend memory request | `4Gi` |
| `backend.autoscaling.enabled` | Enable HPA | `true` |
| `backend.autoscaling.maxReplicas` | Max replicas | `10` |
| `postgresql.replicaCount` | PostgreSQL instances (1 primary + N replicas) | `3` |
| `postgresql.config.maxConnections` | Max database connections | `500` |
| `postgresql.pooler.enabled` | Enable PgBouncer pooling | `true` |
| `redis.replica.replicaCount` | Redis replicas | `2` |
| `monitoring.enabled` | Enable Prometheus monitoring | `true` |
| `networkPolicies.enabled` | Enable network policies | `true` |

See [values.yaml](values.yaml) for full configuration options.

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## Support

- **Documentation**: See `docs/` directory
- **Issues**: https://github.com/hoodrunio/monad-indexer/issues
- **Discussions**: https://github.com/hoodrunio/monad-indexer/discussions

## License

MIT License - see LICENSE file for details

## Sealed Secrets for Production

For production deployments, use Sealed Secrets to encrypt sensitive data:

```bash
# 1. Add Sealed Secrets Helm repository
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# 2. Install Sealed Secrets controller
helm install sealed-secrets-controller sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --create-namespace

# 3. Follow the detailed guide
cat ../../docs/sealed-secrets-setup.md
```

See [Sealed Secrets Setup Guide](../../docs/sealed-secrets-setup.md) for complete instructions.
