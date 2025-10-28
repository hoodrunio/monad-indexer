# Scaling Guide - Monad Indexer

Complete guide for scaling your Monad blockchain indexer infrastructure from single-node to multi-node production deployment.

## Table of Contents

1. [Overview](#overview)
2. [Vertical Scaling](#vertical-scaling)
3. [Horizontal Scaling](#horizontal-scaling)
4. [Auto-Scaling Configuration](#auto-scaling-configuration)
5. [Database Scaling](#database-scaling)
6. [Multi-Region Deployment](#multi-region-deployment)
7. [Performance Monitoring](#performance-monitoring)
8. [Cost Optimization](#cost-optimization)

## Overview

The Monad indexer infrastructure is designed to scale seamlessly without architecture changes. You can scale by simply updating `values.yaml` and redeploying.

### Scaling Triggers

Scale when you observe:
- ⚠️ Indexing lag > 100 blocks
- ⚠️ CPU utilization > 80% sustained
- ⚠️ Memory usage > 85%
- ⚠️ Database connection pool exhaustion
- ⚠️ API response time > 1s

## Vertical Scaling

Vertical scaling means increasing resources per pod.

### Backend Scaling

**Current Configuration** (values-production.yaml):
```yaml
backend:
  resources:
    requests:
      cpu: "2000m"
      memory: "4Gi"
    limits:
      memory: "8Gi"
```

**Scaled Configuration**:
```yaml
backend:
  resources:
    requests:
      cpu: "4000m"      # 2x CPU
      memory: "8Gi"     # 2x memory
    limits:
      memory: "16Gi"    # 2x memory limit
```

### PostgreSQL Scaling

**Current Configuration**:
```yaml
postgresql:
  primary:
    resources:
      requests:
        cpu: "4000m"
        memory: "16Gi"
      limits:
        memory: "32Gi"
```

**Scaled Configuration**:
```yaml
postgresql:
  primary:
    resources:
      requests:
        cpu: "8000m"      # 2x CPU
        memory: "32Gi"    # 2x memory
      limits:
        memory: "64Gi"    # 2x memory limit

  config:
    sharedBuffers: "16GB"           # Increase from 8GB
    effectiveCacheSize: "48GB"      # Increase from 24GB
    maxConnections: 1000             # Increase from 500
```

### Apply Vertical Scaling

```bash
# 1. Update values-production.yaml
vim charts/monad-indexer/environments/values-production.yaml

# 2. Commit changes
git add charts/monad-indexer/environments/values-production.yaml
git commit -m "Vertical scale: 2x resources"
git push

# 3. Sync via ArgoCD
argocd app sync monad-indexer-production

# 4. Watch rolling update
kubectl rollout status deployment/monad-indexer-backend -n monad-indexer-prod
```

## Horizontal Scaling

Horizontal scaling means adding more pod replicas.

### Backend Horizontal Scaling

**Benefits**:
- Better fault tolerance
- Higher throughput
- Load distribution

**Configuration**:
```yaml
backend:
  replicaCount: 10  # Increase from 5

  # Update HPA max replicas
  autoscaling:
    minReplicas: 10
    maxReplicas: 30
```

### Microservices Scaling

Scale microservices independently:

```yaml
microservices:
  smart-contract-verifier:
    replicaCount: 10  # Increase from 5
    autoscaling:
      minReplicas: 10
      maxReplicas: 20

  sig-provider:
    replicaCount: 5   # Increase from 3

  stats:
    replicaCount: 3   # Increase from 2
```

### PgBouncer Connection Pooler Scaling

When backend scales, scale PgBouncer:

```yaml
postgresql:
  pooler:
    replicaCount: 5        # Increase from 3
    maxClientConn: 10000   # Increase from 5000
    defaultPoolSize: 150   # Increase from 100
```

### Apply Horizontal Scaling

```bash
# 1. Update configuration
vim charts/monad-indexer/environments/values-production.yaml

# 2. Commit and push
git add .
git commit -m "Horizontal scale: 10 backend pods"
git push

# 3. Sync (automatic or manual)
argocd app sync monad-indexer-production

# 4. Verify new pods
kubectl get pods -n monad-indexer-prod -l app.kubernetes.io/component=backend
```

## Auto-Scaling Configuration

### HPA (Horizontal Pod Autoscaler)

**Basic Configuration**:
```yaml
backend:
  autoscaling:
    enabled: true
    minReplicas: 5
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
```

**Advanced Configuration with Behavior**:
```yaml
backend:
  autoscaling:
    enabled: true
    minReplicas: 5
    maxReplicas: 30
    targetCPUUtilizationPercentage: 60  # Scale earlier
    targetMemoryUtilizationPercentage: 70

    # Scaling behavior
    behavior:
      scaleUp:
        stabilizationWindowSeconds: 60
        policies:
        - type: Percent
          value: 100        # Double pods in one step
          periodSeconds: 60
        - type: Pods
          value: 5          # Or add 5 pods
          periodSeconds: 60
        selectPolicy: Max   # Use the policy that scales faster

      scaleDown:
        stabilizationWindowSeconds: 300  # Wait 5 min before scaling down
        policies:
        - type: Percent
          value: 50         # Remove max 50% of pods
          periodSeconds: 60
        selectPolicy: Min   # Use the policy that scales slower
```

**Custom Metrics (Advanced)**:
```yaml
backend:
  autoscaling:
    customMetrics:
    # Scale based on indexing lag
    - type: Pods
      pods:
        metric:
          name: indexing_lag_seconds
        target:
          type: AverageValue
          averageValue: "30"  # Scale when lag > 30s

    # Scale based on API request rate
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"  # Scale when > 1000 req/s per pod
```

### VPA (Vertical Pod Autoscaler)

Install VPA for automatic resource adjustment:

```bash
# Install VPA
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh
```

**VPA Configuration**:
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: monad-indexer-backend-vpa
  namespace: monad-indexer-prod
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: monad-indexer-backend
  updatePolicy:
    updateMode: "Auto"  # Auto, Recreate, Initial, or Off
  resourcePolicy:
    containerPolicies:
    - containerName: backend
      minAllowed:
        cpu: 1000m
        memory: 2Gi
      maxAllowed:
        cpu: 8000m
        memory: 16Gi
```

## Database Scaling

### PostgreSQL Read Replica Scaling

**Add More Read Replicas**:
```yaml
postgresql:
  replicaCount: 5  # 1 primary + 4 read replicas (from 3)
```

**Application Configuration** (use read replicas for read queries):
```yaml
backend:
  env:
    # Write to primary
    DATABASE_URL: "postgresql://blockscout:password@monad-indexer-pooler-rw:5432/blockscout"

    # Read from replicas (via pooler)
    DATABASE_READ_URL: "postgresql://blockscout:password@monad-indexer-pooler-ro:5432/blockscout"
```

### Storage Expansion

**Expand PostgreSQL Storage**:
```yaml
postgresql:
  primary:
    persistence:
      size: 2Ti  # Increase from 1Ti
```

**Apply Storage Expansion**:
```bash
# 1. Update values
# 2. Apply via ArgoCD
argocd app sync monad-indexer-production

# 3. CloudNativePG will automatically expand the volume
# 4. Verify expansion
kubectl get pvc -n monad-indexer-prod
```

### Database Connection Pool Tuning

**High-Load Configuration**:
```yaml
postgresql:
  config:
    maxConnections: 1000  # Increase from 500

  pooler:
    maxClientConn: 20000      # Increase from 10000
    defaultPoolSize: 200      # Increase from 100
    reservePoolSize: 50       # Increase from 25
    maxDbConnections: 300     # Increase from 100
```

### Database Sharding (Future)

For extreme scale (50k+ TPS), consider sharding:

```yaml
# Deploy multiple database clusters
postgresql-shard-1:
  # Blocks 0 - 10M

postgresql-shard-2:
  # Blocks 10M - 20M

# Application routes queries to appropriate shard
```

## Multi-Region Deployment

### Architecture

```
┌──────────────────┐         ┌──────────────────┐
│   US-EAST        │         │   US-WEST        │
│                  │         │                  │
│  ┌────────────┐  │         │  ┌────────────┐  │
│  │ Primary DB │──┼────────▶│  │ Replica DB │  │
│  └────────────┘  │  WAL    │  └────────────┘  │
│       │          │ Stream  │       │          │
│  ┌────▼────┐     │         │  ┌────▼────┐     │
│  │ Backend │     │         │  │ Backend │     │
│  └─────────┘     │         │  └─────────┘     │
└──────────────────┘         └──────────────────┘
```

### Primary Region Configuration

```yaml
# US-EAST (Primary)
postgresql:
  replicaCount: 3
  primary:
    persistence:
      size: 2Ti

  # Enable WAL archiving for cross-region replication
  config:
    walLevel: "logical"
    maxWalSenders: 10
```

### Secondary Region Configuration

```yaml
# US-WEST (Replica)
postgresql:
  replica:
    enabled: true
    source: "postgresql-primary.us-east.svc.cluster.local"

  replicaCount: 3
```

### Global Load Balancer

Use cloud load balancer for global traffic distribution:

```yaml
ingress:
  enabled: true
  annotations:
    external-dns.alpha.kubernetes.io/hostname: indexer.monad.global
    # AWS Global Accelerator, Cloudflare, or similar
```

## Performance Monitoring

### Key Metrics to Monitor

**Backend Performance**:
```bash
# Indexing rate (blocks/minute)
rate(blocks_indexed_total[5m]) * 60

# Indexing lag (seconds behind chain head)
indexing_lag_seconds

# API request rate
rate(http_requests_total[5m])

# API response time (p95)
histogram_quantile(0.95, http_request_duration_seconds_bucket)
```

**Database Performance**:
```bash
# TPS (transactions per second)
rate(pg_stat_database_xact_commit[1m])

# Connection pool usage
pg_stat_activity_count / pg_settings_max_connections

# Replication lag
pg_replication_lag_seconds

# Cache hit ratio
pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read)
```

### Grafana Dashboards

Import pre-built dashboards:

```bash
kubectl port-forward svc/grafana 3000:80 -n monitoring

# Visit http://localhost:3000
# Import dashboards from monitoring/grafana-dashboards/
```

### Performance Testing

**Load Test Script**:
```bash
#!/bin/bash
# Load test the indexer

# Simulate high query load
for i in {1..1000}; do
  curl -s http://indexer.monad.local/api/v2/blocks &
  curl -s http://indexer.monad.local/api/v2/transactions &
done

# Wait for all requests
wait

# Check metrics
kubectl top pods -n monad-indexer-prod
```

## Cost Optimization

### Resource Right-Sizing

**Step 1: Monitor Actual Usage**
```bash
# View actual resource usage
kubectl top pods -n monad-indexer-prod

# View HPA status
kubectl get hpa -n monad-indexer-prod
```

**Step 2: Adjust Requests**
```yaml
# If pods consistently use only 50% of requests
backend:
  resources:
    requests:
      cpu: "1000m"    # Reduce from 2000m
      memory: "2Gi"   # Reduce from 4Gi
```

### Spot Instances (Cloud)

**AWS Example**:
```yaml
backend:
  nodeSelector:
    node.kubernetes.io/instance-type: "spot"

  tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

**Cost Savings**: 60-90% vs on-demand

### Storage Cost Optimization

**Tiered Storage**:
```yaml
# Hot data (recent blocks)
postgresql:
  primary:
    persistence:
      storageClass: "fast-ssd"  # NVMe
      size: 500Gi

# Cold data (archive)
postgresql:
  archive:
    persistence:
      storageClass: "standard"  # HDD
      size: 5Ti
```

### Schedule-Based Scaling

**Scale Down During Low Traffic**:
```yaml
# CronJob to scale down at night
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-down-night
spec:
  schedule: "0 0 * * *"  # Midnight
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scaler
          containers:
          - name: kubectl
            image: bitnami/kubectl
            command:
            - kubectl
            - scale
            - deployment/monad-indexer-backend
            - --replicas=2
            - -n
            - monad-indexer-prod
          restartPolicy: OnFailure

---
# Scale up in the morning
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-up-morning
spec:
  schedule: "0 6 * * *"  # 6 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scaler
          containers:
          - name: kubectl
            image: bitnami/kubectl
            command:
            - kubectl
            - scale
            - deployment/monad-indexer-backend
            - --replicas=10
            - -n
            - monad-indexer-prod
          restartPolicy: OnFailure
```

## Scaling Checklist

### Before Scaling

- [ ] Monitor current resource usage for 24-48 hours
- [ ] Identify bottlenecks (CPU, memory, disk, network)
- [ ] Review error logs for resource-related issues
- [ ] Check database connection pool usage
- [ ] Verify current indexing lag

### During Scaling

- [ ] Update values-production.yaml with new configuration
- [ ] Commit and push changes to Git
- [ ] Sync ArgoCD application
- [ ] Monitor rolling update progress
- [ ] Watch for pod crashes or errors
- [ ] Check PodDisruptionBudget compliance

### After Scaling

- [ ] Verify all pods are Running
- [ ] Check indexing lag has decreased
- [ ] Monitor resource usage (should be < 80%)
- [ ] Test API endpoints
- [ ] Review database replication lag
- [ ] Update monitoring alert thresholds

## Troubleshooting Scaling Issues

### HPA Not Scaling

**Check HPA status**:
```bash
kubectl describe hpa monad-indexer-backend -n monad-indexer-prod
```

**Common issues**:
- Metrics server not installed
- Resource requests not set
- PodDisruptionBudget too restrictive

### Pods Stuck in Pending

**Check pod events**:
```bash
kubectl describe pod <pod-name> -n monad-indexer-prod
```

**Common causes**:
- Insufficient node resources
- Node affinity/anti-affinity conflicts
- Storage class not available

### Database Connection Exhaustion

**Increase connection limits**:
```yaml
postgresql:
  config:
    maxConnections: 1000

  pooler:
    maxClientConn: 20000
    defaultPoolSize: 200
```

## Summary

Scaling the Monad indexer is designed to be simple:

1. **Monitor** current usage and identify bottlenecks
2. **Update** values-production.yaml with new configuration
3. **Commit** and push to Git
4. **Sync** via ArgoCD
5. **Verify** deployment and performance

No architecture changes needed - the infrastructure scales seamlessly from 1 node to multi-region deployment.

**Next**: See [03-backup-restore.md](03-backup-restore.md) for disaster recovery procedures.
