# Troubleshooting Guide - Monad Indexer

Comprehensive troubleshooting guide for common issues with your Monad blockchain indexer infrastructure.

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Pod Issues](#pod-issues)
3. [Database Issues](#database-issues)
4. [Network Issues](#network-issues)
5. [Performance Issues](#performance-issues)
6. [ArgoCD Issues](#argocd-issues)
7. [Monitoring Issues](#monitoring-issues)
8. [Storage Issues](#storage-issues)

## Quick Diagnostics

### Health Check Commands

```bash
# Check all pods
kubectl get pods -n monad-indexer-prod

# Check cluster status
kubectl get cluster -n monad-indexer-prod

# Check services
kubectl get svc -n monad-indexer-prod

# Check recent events
kubectl get events -n monad-indexer-prod --sort-by='.lastTimestamp'

# Check resource usage
kubectl top pods -n monad-indexer-prod
kubectl top nodes
```

### Common Diagnostic Tools

```bash
# Describe resource for detailed info
kubectl describe pod <pod-name> -n monad-indexer-prod

# View logs
kubectl logs <pod-name> -n monad-indexer-prod
kubectl logs <pod-name> -n monad-indexer-prod --previous  # Previous container

# Execute commands in pod
kubectl exec -it <pod-name> -n monad-indexer-prod -- bash

# Port forward for testing
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-prod
```

## Pod Issues

### Issue: Pods Stuck in Pending

**Symptoms**:
```
NAME                                      READY   STATUS    RESTARTS   AGE
monad-indexer-backend-xxx                 0/1     Pending   0          5m
```

**Diagnosis**:
```bash
kubectl describe pod monad-indexer-backend-xxx -n monad-indexer-prod
```

**Common Causes & Solutions**:

**1. Insufficient Resources**:
```
Events:
  Warning  FailedScheduling  pod didn't trigger scale-up: insufficient cpu
```

**Solution**: Scale up cluster or reduce resource requests
```yaml
# Reduce requests in values-production.yaml
backend:
  resources:
    requests:
      cpu: "1000m"  # Reduce from 2000m
      memory: "2Gi"  # Reduce from 4Gi
```

**2. PVC Not Bound**:
```
Events:
  Warning  FailedMount  Unable to attach or mount volumes
```

**Solution**: Check storage class and PVC status
```bash
kubectl get pvc -n monad-indexer-prod
kubectl get storageclass

# If storage class missing
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
EOF
```

**3. Node Affinity Not Satisfied**:
```
Events:
  Warning  FailedScheduling  0/3 nodes are available: pod affinity/anti-affinity not satisfied
```

**Solution**: Adjust affinity rules or add nodes
```yaml
# Relax anti-affinity to "preferred"
backend:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:  # Instead of required
        - weight: 100
          podAffinityTerm:
            # ...
```

### Issue: CrashLoopBackOff

**Symptoms**:
```
NAME                                      READY   STATUS             RESTARTS   AGE
monad-indexer-backend-xxx                 0/1     CrashLoopBackOff   5          10m
```

**Diagnosis**:
```bash
# Check logs
kubectl logs monad-indexer-backend-xxx -n monad-indexer-prod

# Check previous container logs
kubectl logs monad-indexer-backend-xxx -n monad-indexer-prod --previous
```

**Common Causes & Solutions**:

**1. Database Connection Failure**:
```
Error: could not connect to database
Connection refused: monad-indexer-pooler-rw:5432
```

**Solution**: Check database status
```bash
# Check PostgreSQL cluster
kubectl get cluster monad-indexer-postgresql -n monad-indexer-prod

# Check pooler
kubectl get pods -l cnpg.io/poolerName=monad-indexer-pooler -n monad-indexer-prod

# Test connection
kubectl exec -it monad-indexer-backend-xxx -n monad-indexer-prod -- \
  psql -h monad-indexer-pooler-rw -U blockscout -d blockscout -c "SELECT 1;"
```

**2. Out of Memory (OOM)**:
```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

**Solution**: Increase memory limits
```yaml
backend:
  resources:
    limits:
      memory: "16Gi"  # Increase from 8Gi
```

**3. Missing Environment Variable**:
```
Error: ETHEREUM_JSONRPC_HTTP_URL is required
```

**Solution**: Check ConfigMap and Secret
```bash
# Verify env vars
kubectl exec -it monad-indexer-backend-xxx -n monad-indexer-prod -- env | grep ETHEREUM

# Check secret exists
kubectl get secret monad-indexer-backend-secret -n monad-indexer-prod
```

### Issue: ImagePullBackOff

**Symptoms**:
```
NAME                                      READY   STATUS             RESTARTS   AGE
monad-indexer-backend-xxx                 0/1     ImagePullBackOff   0          2m
```

**Diagnosis**:
```bash
kubectl describe pod monad-indexer-backend-xxx -n monad-indexer-prod
```

**Common Causes & Solutions**:

**1. Invalid Image Name**:
```
Failed to pull image "ghcr.io/blockscout/blockscout:9.0.2": rpc error
```

**Solution**: Verify image exists
```bash
# Check image name in values
grep "image:" charts/monad-indexer/values.yaml

# Test pull locally
docker pull ghcr.io/blockscout/blockscout:9.0.2
```

**2. Private Registry Authentication**:
```
Failed to pull image: unauthorized
```

**Solution**: Create image pull secret
```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=your-username \
  --docker-password=your-token \
  -n monad-indexer-prod

# Add to values-production.yaml
backend:
  image:
    pullSecrets:
      - ghcr-secret
```

## Database Issues

### Issue: PostgreSQL Cluster Not Healthy

**Symptoms**:
```bash
kubectl get cluster -n monad-indexer-prod
NAME                       AGE    INSTANCES   READY   STATUS
monad-indexer-postgresql   10m    3           1       Cluster unhealthy
```

**Diagnosis**:
```bash
# Check cluster details
kubectl describe cluster monad-indexer-postgresql -n monad-indexer-prod

# Check pod logs
kubectl logs monad-indexer-postgresql-1 -n monad-indexer-prod

# Check replication status
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

**Common Causes & Solutions**:

**1. Primary Not Elected**:
```
Events:
  Warning  ClusterNotHealthy  Primary instance not found
```

**Solution**: Check operator logs and force failover
```bash
# Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager

# Force switchover to pod-2
kubectl cnpg promote monad-indexer-postgresql 2 -n monad-indexer-prod
```

**2. Replication Lag**:
```bash
# Check replication lag
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -c "SELECT client_addr, state, sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
    FROM pg_stat_replication;"
```

**Solution**: Check network and increase WAL retention
```yaml
postgresql:
  config:
    maxWalSize: "16GB"  # Increase from 8GB
    walKeepSize: "2GB"   # Increase from 1GB
```

**3. Disk Full**:
```
Error: could not extend file "base/16384/1259": No space left on device
```

**Solution**: Expand storage
```yaml
postgresql:
  primary:
    persistence:
      size: 2Ti  # Increase from 1Ti
```

### Issue: Connection Pool Exhaustion

**Symptoms**:
```
Error: remaining connection slots are reserved for non-replication superuser connections
```

**Diagnosis**:
```bash
# Check current connections
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Check connection limits
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -c "SHOW max_connections;"
```

**Solution**: Scale PgBouncer and increase limits
```yaml
postgresql:
  config:
    maxConnections: 1000  # Increase from 500

  pooler:
    replicaCount: 5           # Increase from 3
    maxClientConn: 10000      # Increase from 5000
    defaultPoolSize: 200      # Increase from 100
```

### Issue: Slow Queries

**Diagnosis**:
```bash
# Find slow queries
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "
    SELECT query, calls, total_exec_time, mean_exec_time
    FROM pg_stat_statements
    ORDER BY mean_exec_time DESC
    LIMIT 10;"
```

**Solution**: Add missing indexes
```bash
# Check missing indexes
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "
    SELECT schemaname, tablename, attname
    FROM pg_stats
    WHERE schemaname = 'public'
      AND n_distinct > 100
      AND correlation < 0.1
    LIMIT 20;"

# Create index
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "
    CREATE INDEX CONCURRENTLY idx_transactions_block_hash
    ON transactions(block_hash);"
```

## Network Issues

### Issue: Backend Cannot Connect to Database

**Diagnosis**:
```bash
# Test from backend pod
kubectl exec -it deployment/monad-indexer-backend -n monad-indexer-prod -- \
  nc -zv monad-indexer-pooler-rw 5432

# Check NetworkPolicy
kubectl get networkpolicy -n monad-indexer-prod

# Describe NetworkPolicy
kubectl describe networkpolicy monad-indexer-backend -n monad-indexer-prod
```

**Solution**: Fix NetworkPolicy
```yaml
# Ensure backend can reach database
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: monad-indexer-backend
spec:
  egress:
  - to:
    - podSelector:
        matchLabels:
          cnpg.io/poolerName: monad-indexer-pooler
    ports:
    - protocol: TCP
      port: 5432
```

### Issue: External RPC Timeout

**Symptoms**:
```
Error: request timeout connecting to https://testnet-rpc.monad.xyz
```

**Diagnosis**:
```bash
# Test from backend pod
kubectl exec -it deployment/monad-indexer-backend -n monad-indexer-prod -- \
  curl -v -m 10 https://testnet-rpc.monad.xyz

# Check DNS resolution
kubectl exec -it deployment/monad-indexer-backend -n monad-indexer-prod -- \
  nslookup testnet-rpc.monad.xyz
```

**Solution**: Update NetworkPolicy for external access
```yaml
backend:
  networkPolicies:
    egress:
    - to:
      - namespaceSelector: {}  # Allow all namespaces
      ports:
      - protocol: TCP
        port: 443
      - protocol: TCP
        port: 80
```

## Performance Issues

### Issue: Indexing Lag

**Symptoms**:
```
Indexer is 500 blocks behind chain head
```

**Diagnosis**:
```bash
# Check indexing metrics
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-prod
curl http://localhost:4000/api/v2/stats | jq '.latest_block, .indexed_block'

# Check resource usage
kubectl top pods -n monad-indexer-prod -l app.kubernetes.io/component=backend
```

**Common Causes & Solutions**:

**1. Backend CPU Throttling**:
```bash
# Check for throttling
kubectl get pods -n monad-indexer-prod -l app.kubernetes.io/component=backend \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits.cpu}{"\n"}{end}'
```

**Solution**: Remove CPU limits
```yaml
backend:
  resources:
    requests:
      cpu: "2000m"
    # NO CPU LIMIT to avoid throttling
```

**2. Database Slow**:
```bash
# Check cache hit ratio
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "
    SELECT
      sum(blks_hit) / (sum(blks_hit) + sum(blks_read)) AS cache_hit_ratio
    FROM pg_stat_database;"
```

**Solution**: Increase shared_buffers
```yaml
postgresql:
  config:
    sharedBuffers: "16GB"  # Increase from 8GB
    effectiveCacheSize: "48GB"  # Increase from 24GB
```

**3. RPC Rate Limiting**:
```
Error: 25/second request limit reached
```

**Solution**: Use your own RPC node or paid service
```yaml
backend:
  env:
    ETHEREUM_JSONRPC_HTTP_URL: "https://your-private-rpc"
```

### Issue: High Memory Usage

**Diagnosis**:
```bash
# Check memory usage
kubectl top pods -n monad-indexer-prod

# Check OOM kills
kubectl get pods -n monad-indexer-prod -o json | \
  jq '.items[] | select(.status.containerStatuses[].lastState.terminated.reason == "OOMKilled") | .metadata.name'
```

**Solution**: Increase memory limits or reduce batch sizes
```yaml
backend:
  resources:
    limits:
      memory: "16Gi"  # Increase

  env:
    INDEXER_MEMORY_LIMIT: "10"  # Reduce batch processing
```

## ArgoCD Issues

### Issue: Application Out of Sync

**Diagnosis**:
```bash
argocd app get monad-indexer-production

# Check diff
argocd app diff monad-indexer-production
```

**Solution**: Sync application
```bash
# Dry run first
argocd app sync monad-indexer-production --dry-run

# Actually sync
argocd app sync monad-indexer-production

# Force sync if needed (careful!)
argocd app sync monad-indexer-production --force
```

### Issue: Sync Failed

**Diagnosis**:
```bash
# Check sync status
argocd app get monad-indexer-production

# View detailed errors
kubectl logs -n argocd deployment/argocd-application-controller
```

**Common Causes & Solutions**:

**1. Invalid Manifest**:
```
Error: error validating data: ValidationError
```

**Solution**: Validate Helm chart locally
```bash
cd charts/monad-indexer

# Validate
helm lint .

# Dry-run
helm template monad-indexer . \
  -f values.yaml \
  -f environments/values-production.yaml \
  --debug
```

**2. Resource Conflicts**:
```
Error: resource already exists and is not managed by ArgoCD
```

**Solution**: Add owner labels or delete conflicting resource
```bash
# Option 1: Delete resource (if safe)
kubectl delete <resource-type> <resource-name> -n monad-indexer-prod

# Option 2: Add ArgoCD labels
kubectl label <resource-type> <resource-name> \
  app.kubernetes.io/instance=monad-indexer-production \
  -n monad-indexer-prod
```

## Monitoring Issues

### Issue: Metrics Not Available

**Diagnosis**:
```bash
# Check ServiceMonitors
kubectl get servicemonitor -n monad-indexer-prod

# Check Prometheus targets
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring
# Visit http://localhost:9090/targets
```

**Solution**: Verify ServiceMonitor selectors
```bash
# Check backend service labels
kubectl get svc monad-indexer-backend -n monad-indexer-prod --show-labels

# Ensure ServiceMonitor matches
kubectl get servicemonitor monad-indexer-backend -n monad-indexer-prod -o yaml
```

### Issue: Alerts Not Firing

**Diagnosis**:
```bash
# Check PrometheusRule
kubectl get prometheusrule -n monad-indexer-prod

# Check AlertManager
kubectl port-forward svc/alertmanager-operated 9093:9093 -n monitoring
# Visit http://localhost:9093
```

**Solution**: Verify alert configuration
```bash
# Test alert query in Prometheus
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring
# Visit http://localhost:9090 and run query
```

## Storage Issues

### Issue: PVC Not Expanding

**Diagnosis**:
```bash
# Check PVC status
kubectl get pvc -n monad-indexer-prod

# Check events
kubectl describe pvc postgres-monad-indexer-postgresql-1 -n monad-indexer-prod
```

**Solution**: Ensure StorageClass allows expansion
```bash
# Check StorageClass
kubectl get storageclass -o yaml | grep allowVolumeExpansion

# If not allowed, update
kubectl patch storageclass <storage-class-name> \
  -p '{"allowVolumeExpansion": true}'
```

### Issue: Disk Full

**Symptoms**:
```
Error: No space left on device
```

**Immediate Solution**: Free up space
```bash
# Connect to database
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- bash

# Check disk usage
df -h

# Vacuum large tables
psql -U postgres -d blockscout -c "VACUUM FULL blocks;"
```

**Long-term Solution**: Expand PVC
```yaml
postgresql:
  primary:
    persistence:
      size: 2Ti  # Increase size
```

## Getting Help

If you can't resolve the issue:

1. **Check Logs**:
```bash
kubectl logs <pod-name> -n monad-indexer-prod --tail=100
```

2. **Check Events**:
```bash
kubectl get events -n monad-indexer-prod --sort-by='.lastTimestamp'
```

3. **Gather Diagnostics**:
```bash
# Create diagnostic bundle
kubectl cluster-info dump -n monad-indexer-prod > diagnostics.txt
```

4. **Community Support**:
- GitHub Issues: https://github.com/hoodrunio/monad-indexer/issues
- Discord: [Monad Discord]
- Documentation: See other docs/ files

## Summary

This guide covers the most common issues you'll encounter. For each issue:

1. **Diagnose** using provided commands
2. **Identify** the root cause
3. **Apply** the appropriate solution
4. **Verify** the fix worked
5. **Document** for future reference

**Remember**: Always test fixes in staging before applying to production!
