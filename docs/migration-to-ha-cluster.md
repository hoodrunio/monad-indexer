# Migration to 2-Node HA Cluster - Production Runbook

## 🎯 Objective
Migrate from single-node K3s cluster to 2-node HA cluster with PostgreSQL replication and distributed backend pods.

## 📊 Expected Results
- **Architecture**: 1 primary + 1 replica PostgreSQL, 6 backend pods (3 per node)
- **Downtime**: 2-4 hours
- **TPS Improvement**: 5,000 → 15,000-20,000 TPS
- **HA**: System survives single node failure

## ⚠️ Prerequisites
1. **New server ready**: 64GB RAM, 6-8 cores, 1TB NVMe
2. **SSH access**: Root or sudo access to both servers
3. **Backup verified**: PostgreSQL backup completed and tested
4. **Maintenance window**: 2-4 hour downtime scheduled
5. **Rollback plan**: Ready to revert if needed

---

## 📋 Phase 1: Pre-Migration Checklist (30 minutes)

### 1.1 Verify Current State
```bash
# On existing server
cd /Users/errorist/Documents/new-projects/monad-indexer

# Check current cluster status
kubectl get nodes
kubectl get pods -n monad-indexer-production

# Get current block height (record for comparison)
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=100 | grep "Fetching"

# Check PostgreSQL data size
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- du -sh /var/lib/postgresql/data
```

### 1.2 Backup Current Configuration
```bash
# Backup current Helm values
cp charts/monad-indexer/environments/values-production.yaml \
   charts/monad-indexer/environments/values-production.yaml.backup.$(date +%Y%m%d-%H%M%S)

# Export current Helm release
helm get values monad-indexer-production -n monad-indexer-production > /tmp/current-values.yaml

# Backup Kubernetes resources
kubectl get all -n monad-indexer-production -o yaml > /tmp/k8s-backup.yaml
```

### 1.3 Trigger PostgreSQL Backup
```bash
# Force a backup before migration
kubectl annotate -n monad-indexer-production cluster/monad-indexer-production-postgresql \
  cnpg.io/reconcileNow="$(date +%s)"

# Wait for backup to complete (check status)
kubectl get backup -n monad-indexer-production -w
```

### 1.4 Record Metrics
```bash
# Save current metrics for comparison
kubectl top nodes > /tmp/metrics-before.txt
kubectl top pods -n monad-indexer-production >> /tmp/metrics-before.txt
```

---

## 📋 Phase 2: Setup New Node (45 minutes)

### 2.1 Update Ansible Inventory
```bash
cd ansible

# Edit inventory.ini with actual IPs
vi inventory.ini

# Example:
# [k3s_server]
# node1 ansible_host=95.217.XXX.XXX ansible_user=root
#
# [k3s_agents]
# node2 ansible_host=95.217.YYY.YYY ansible_user=root
```

### 2.2 Test SSH Connectivity
```bash
# Test connection to both servers
ansible -i inventory.ini all -m ping

# Expected output:
# node1 | SUCCESS => { "ping": "pong" }
# node2 | SUCCESS => { "ping": "pong" }
```

### 2.3 Run K3s Cluster Setup
```bash
# Run Ansible playbook (this will take ~30 minutes)
ansible-playbook -i inventory.ini k3s-cluster-setup.yml

# The playbook will:
# 1. Verify K3s server on node1 (or install if missing)
# 2. Get K3s token from server
# 3. Install K3s agent on node2
# 4. Apply system optimizations
# 5. Label nodes for workload placement
```

### 2.4 Verify Cluster Setup
```bash
# On your local machine (kubeconfig should be updated)
kubectl get nodes

# Expected output:
# NAME    STATUS   ROLES                  AGE   VERSION
# node1   Ready    control-plane,master   XXd   v1.28.5+k3s1
# node2   Ready    <none>                 XXm   v1.28.5+k3s1

# Verify node labels
kubectl get nodes --show-labels | grep postgres-role

# Expected:
# node1 ... postgres-role=primary ...
# node2 ... postgres-role=replica ...
```

---

## 📋 Phase 3: Stop Current Workload (15 minutes)

### 3.1 Scale Down Backend Pods
```bash
# Scale backend to 0 to prevent new writes
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=0

# Wait for pods to terminate
kubectl wait --for=delete pod -n monad-indexer-production \
  -l app.kubernetes.io/component=backend --timeout=300s

# Verify no backend pods running
kubectl get pods -n monad-indexer-production -l app.kubernetes.io/component=backend
```

### 3.2 Wait for PostgreSQL to Flush
```bash
# Wait for all transactions to complete
sleep 30

# Checkpoint database
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -c "CHECKPOINT;"

# Verify no active connections
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='blockscout';"
```

---

## 📋 Phase 4: Upgrade Helm Release (60 minutes)

### 4.1 Update Helm Dependencies
```bash
cd /Users/errorist/Documents/new-projects/monad-indexer

# Update chart dependencies (if changed)
helm dependency update charts/monad-indexer
```

### 4.2 Dry Run Upgrade
```bash
# Perform dry run to validate changes
helm upgrade monad-indexer-production charts/monad-indexer \
  --namespace monad-indexer-production \
  --values charts/monad-indexer/environments/values-production.yaml \
  --dry-run --debug > /tmp/helm-dry-run.yaml

# Review the output
less /tmp/helm-dry-run.yaml
```

### 4.3 Execute Helm Upgrade
```bash
# Upgrade the release
helm upgrade monad-indexer-production charts/monad-indexer \
  --namespace monad-indexer-production \
  --values charts/monad-indexer/environments/values-production.yaml \
  --timeout 30m \
  --wait

# This will:
# 1. Update PostgreSQL cluster to 2 replicas (1 primary + 1 replica)
# 2. Scale backend to 6 replicas
# 3. Update pool sizes (100/50)
# 4. Configure pod affinity
# 5. Update PgBouncer configuration
```

### 4.4 Monitor PostgreSQL Cluster Creation
```bash
# Watch PostgreSQL pods come up
watch kubectl get pods -n monad-indexer-production -l cnpg.io/cluster=monad-indexer-production-postgresql

# Expected output (after ~10 minutes):
# NAME                                             READY   STATUS
# monad-indexer-production-postgresql-1            1/1     Running   # Primary
# monad-indexer-production-postgresql-2            1/1     Running   # Replica

# Check cluster status
kubectl get cluster -n monad-indexer-production monad-indexer-production-postgresql -o yaml
```

### 4.5 Verify Replication Status
```bash
# Check replication on primary
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Expected: 1 row showing replica connection

# Check replication lag on replica
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-2 -- \
  psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Lag should be minimal (< 1MB)
```

---

## 📋 Phase 5: Verify Services (30 minutes)

### 5.1 Check Pod Distribution
```bash
# Verify backend pods are distributed across nodes
kubectl get pods -n monad-indexer-production -l app.kubernetes.io/component=backend -o wide

# Expected: 3 pods on node1, 3 pods on node2

# Check PostgreSQL pod placement
kubectl get pods -n monad-indexer-production -l cnpg.io/cluster=monad-indexer-production-postgresql -o wide

# Expected:
# postgresql-1 on node1 (primary)
# postgresql-2 on node2 (replica)
```

### 5.2 Verify PgBouncer Pooler
```bash
# Check pooler pods
kubectl get pods -n monad-indexer-production -l cnpg.io/poolerName

# Expected: 3 pooler pods

# Check pooler configuration
kubectl exec -n monad-indexer-production \
  $(kubectl get pod -n monad-indexer-production -l cnpg.io/poolerName -o jsonpath='{.items[0].metadata.name}') \
  -- cat /etc/pgbouncer/pgbouncer.ini | grep -E "default_pool_size|max_client_conn|max_db_connections"

# Expected:
# default_pool_size = 500
# max_client_conn = 10000
# max_db_connections = 600
```

### 5.3 Check Backend Connectivity
```bash
# Check backend logs for database connections
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=50 | grep -i "database\|pool"

# Should see successful connections, no timeout errors
```

### 5.4 Verify Indexing Resumed
```bash
# Check if indexing is progressing
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f | grep "Fetching"

# Should see blocks being fetched and imported

# Get current block height (compare with pre-migration)
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=100 | grep "Fetching" | tail -1
```

---

## 📋 Phase 6: Performance Testing (30 minutes)

### 6.1 Check Resource Usage
```bash
# Check node resources
kubectl top nodes

# Expected:
# node1: ~50-60% CPU, ~40-50% memory
# node2: ~30-40% CPU, ~30-40% memory

# Check pod resources
kubectl top pods -n monad-indexer-production
```

### 6.2 Test API Endpoints
```bash
# Test backend API
curl -s https://monad-mainnet-indexer.hoodscan.io/api/v2/stats | jq

# Test block endpoint
curl -s https://monad-mainnet-indexer.hoodscan.io/api/v2/blocks?type=block | jq

# Test transaction endpoint
curl -s https://monad-mainnet-indexer.hoodscan.io/api/v2/transactions | jq
```

### 6.3 Run Verification Script
```bash
# Run automated verification
bash scripts/verify-cluster.sh

# This will check:
# - Node count and status
# - PostgreSQL replication status
# - Backend pod distribution
# - Connection pool usage
# - API health
```

### 6.4 Monitor for Errors
```bash
# Watch for any errors in logs
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=200 | grep -i "error\|failed\|timeout"

# Check PostgreSQL logs
kubectl logs -n monad-indexer-production monad-indexer-production-postgresql-1 --tail=200 | grep -i "error\|fatal"

# Should see no critical errors
```

---

## 📋 Phase 7: Post-Migration Tasks (15 minutes)

### 7.1 Update Monitoring
```bash
# Verify Prometheus scraping new pods
kubectl get servicemonitor -n monad-indexer-production

# Check Grafana dashboards (if enabled)
# - Node resource usage
# - PostgreSQL replication lag
# - Backend pod distribution
```

### 7.2 Document Changes
```bash
# Record final state
kubectl get nodes -o wide > /tmp/nodes-after.txt
kubectl get pods -n monad-indexer-production -o wide > /tmp/pods-after.txt
kubectl top nodes > /tmp/metrics-after.txt
kubectl top pods -n monad-indexer-production >> /tmp/metrics-after.txt

# Git commit
git add charts/monad-indexer/environments/values-production.yaml
git add ansible/
git add docs/migration-to-ha-cluster.md
git commit -m "feat: migrate to 2-node HA cluster with PostgreSQL replication

- Scale PostgreSQL to 2 replicas (1 primary + 1 replica)
- Increase backend to 6 replicas with pod affinity
- Update connection pools: 100/50 (up from 60/30)
- Enable read replica routing
- Optimize PostgreSQL config for high TPS
- Add K3s multi-node cluster setup playbook

Expected TPS improvement: 5,000 → 15,000-20,000"

git push origin main
```

### 7.3 Update Documentation
```bash
# Update README with new architecture
# Update runbooks with multi-node procedures
# Document new node maintenance procedures
```

---

## ⚠️ Troubleshooting

### Issue 1: PostgreSQL Replica Not Starting
```bash
# Check replica logs
kubectl logs -n monad-indexer-production monad-indexer-production-postgresql-2

# Common issues:
# - Node selector mismatch (check node labels)
# - Insufficient storage
# - Network connectivity between nodes

# Fix node selector:
kubectl label nodes <node-name> postgres-role=replica --overwrite

# Check storage:
kubectl get pvc -n monad-indexer-production
```

### Issue 2: Backend Pods Connection Timeouts
```bash
# Check pooler status
kubectl exec -n monad-indexer-production <pooler-pod> -- pgbouncer -R

# Check pooler logs
kubectl logs -n monad-indexer-production -l cnpg.io/poolerName

# Restart pooler if needed
kubectl rollout restart deployment -n monad-indexer-production -l cnpg.io/poolerName
```

### Issue 3: Pods Not Distributing Across Nodes
```bash
# Check pod anti-affinity
kubectl get pod -n monad-indexer-production <backend-pod> -o yaml | grep -A 20 affinity

# Force rescheduling
kubectl delete pod -n monad-indexer-production -l app.kubernetes.io/component=backend
```

### Issue 4: High Replication Lag
```bash
# Check network latency between nodes
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  ping -c 5 <node2-ip>

# Check WAL archiving
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_archiver;"

# Increase wal_sender_timeout if needed
```

---

## 🔄 Rollback Procedure (See rollback-procedure.md)

If migration fails, follow rollback procedure:
1. Scale backend to 0
2. Restore Helm values from backup
3. Helm rollback
4. Verify single-node operation
5. Scale backend back up

---

## 📊 Success Criteria

✅ **Infrastructure**
- [ ] 2 nodes online and Ready
- [ ] PostgreSQL: 1 primary + 1 replica running
- [ ] Backend: 6 pods running (3 per node)
- [ ] PgBouncer: 3 pooler pods running

✅ **Database**
- [ ] Replication lag < 10MB
- [ ] Connection pool utilization < 80%
- [ ] Query latency p95 < 100ms

✅ **Application**
- [ ] Indexing progressing (blocks incrementing)
- [ ] API responding (< 200ms p95)
- [ ] No connection timeout errors
- [ ] Stats service operational

✅ **Performance**
- [ ] TPS capacity > 10,000
- [ ] CPU utilization < 70% per node
- [ ] Memory utilization < 70% per node

---

## 📞 Emergency Contacts

- **Primary Contact**: [Your name/email]
- **Backup Contact**: [Backup person]
- **Vendor Support**: CloudNativePG Slack, K3s GitHub

---

## 📝 Migration Log

**Date**: _______________
**Performed by**: _______________
**Start time**: _______________
**End time**: _______________
**Downtime**: _______________
**Issues encountered**: _______________
**Final status**: _______________

---

**End of Migration Runbook**
