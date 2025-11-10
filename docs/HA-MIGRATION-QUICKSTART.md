# 2-Node HA Cluster Migration - Quick Start Guide

## 🎯 Overview
This guide helps you quickly migrate from single-node to 2-node HA cluster for high TPS performance.

**Current State**: 1 node, 1 PostgreSQL, ~5,000 TPS capacity
**Target State**: 2 nodes, 1 primary + 1 replica PostgreSQL, 15,000-20,000 TPS capacity
**Downtime**: 2-4 hours

---

## 📦 What's Included

### 1. Ansible Playbook (`ansible/k3s-cluster-setup.yml`)
- Automated K3s multi-node cluster setup
- System optimizations for PostgreSQL
- Node labeling for workload placement

### 2. Updated Helm Values (`values-production.yaml`)
**Changes:**
- PostgreSQL: `replicaCount: 1 → 2` (1 primary + 1 replica)
- Backend: `replicaCount: 1 → 6` (3 pods per node)
- Pool sizes: `60/30 → 100/50`
- PgBouncer: `defaultPoolSize: 300 → 500`
- PostgreSQL resources: `1.5/4Gi → 4/32Gi` (primary)
- Backend resources: `1/2Gi → 1.5/3Gi` per pod
- PostgreSQL config optimizations for high TPS

### 3. Migration Runbook (`docs/migration-to-ha-cluster.md`)
- 7 phases with detailed step-by-step commands
- Verification checkpoints
- Troubleshooting guide

### 4. Verification Script (`scripts/verify-cluster.sh`)
- Automated health checks
- Resource usage validation
- Replication status verification

### 5. Rollback Procedure (`docs/rollback-procedure.md`)
- 3 rollback scenarios
- Emergency recovery procedures
- Post-rollback verification

---

## 🚀 Quick Start (5 Steps)

### Step 1: Prepare (10 minutes)
```bash
cd /Users/errorist/Documents/new-projects/monad-indexer

# Update Ansible inventory with your server IPs
vi ansible/inventory.ini

# Test SSH connectivity
ansible -i ansible/inventory.ini all -m ping
```

### Step 2: Setup K3s Cluster (45 minutes)
```bash
# Run Ansible playbook
ansible-playbook -i ansible/inventory.ini ansible/k3s-cluster-setup.yml

# Verify cluster
kubectl get nodes
# Expected: 2 nodes
```

### Step 3: Migrate PostgreSQL & Backend (60 minutes)
```bash
# Scale down backend
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=0

# Upgrade Helm release
helm upgrade monad-indexer-production charts/monad-indexer \
  --namespace monad-indexer-production \
  --values charts/monad-indexer/environments/values-production.yaml \
  --timeout 30m --wait
```

### Step 4: Verify (30 minutes)
```bash
# Run verification script
bash scripts/verify-cluster.sh

# Check pod distribution
kubectl get pods -n monad-indexer-production -o wide
```

### Step 5: Monitor (ongoing)
```bash
# Watch logs
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f

# Check metrics
kubectl top nodes
kubectl top pods -n monad-indexer-production
```

---

## 📊 Expected Results

### Before Migration
```
Nodes:              1
PostgreSQL:         1 instance
Backend Pods:       1-3 (autoscaled)
TPS Capacity:       ~5,000
CPU Usage:          86%
Memory Usage:       80%
Connection Errors:  Frequent
```

### After Migration
```
Nodes:              2
PostgreSQL:         1 primary + 1 replica
Backend Pods:       6 (3 per node)
TPS Capacity:       15,000-20,000
CPU Usage:          50-60% per node
Memory Usage:       40-50% per node
Connection Errors:  None
```

---

## ⚠️ Prerequisites

- [ ] New server ready (64GB RAM, 6-8 cores, 1TB NVMe)
- [ ] SSH access to both servers (root or sudo)
- [ ] PostgreSQL backup verified
- [ ] Maintenance window scheduled (2-4 hours)
- [ ] Ansible installed on local machine

---

## 📚 Detailed Documentation

1. **Full Migration Steps**: `docs/migration-to-ha-cluster.md`
2. **Rollback Procedure**: `docs/rollback-procedure.md`
3. **Ansible Playbook**: `ansible/k3s-cluster-setup.yml`
4. **Verification Script**: `scripts/verify-cluster.sh`

---

## 🆘 Need Help?

**If something goes wrong:**
1. Check logs: `kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend`
2. Run diagnostics: `bash scripts/verify-cluster.sh`
3. Consult troubleshooting: `docs/migration-to-ha-cluster.md#troubleshooting`
4. Rollback if needed: `docs/rollback-procedure.md`

---

## 🎓 Key Configuration Changes

### PostgreSQL Optimizations
```yaml
sharedBuffers: 8GB          # Up from 2GB
effectiveCacheSize: 24GB    # Up from 4GB
maxConnections: 1000        # Up from 800
lock_timeout: 5s            # NEW - fail fast on contention
synchronous_commit: off     # Performance over durability
```

### Backend Scaling
```yaml
replicaCount: 6            # Up from 1
poolSize: 100              # Up from 60
poolSizeApi: 50            # Up from 30
INDEXER_MEMORY_LIMIT: 7    # Up from 5
```

### PgBouncer Tuning
```yaml
replicaCount: 3            # Up from 1
defaultPoolSize: 500       # Up from 300
maxClientConn: 10000       # Up from 5000
```

---

## 📈 Performance Improvements

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| TPS Capacity | 5,000 | 15,000 | 3x |
| PostgreSQL CPU | 4.4 cores (294%) | 2-3 cores (75%) | 66% reduction |
| Backend Pods | 1-3 | 6 | 2-6x |
| Connection Pool | 60/30 | 100/50 | 67% increase |
| Node CPU Usage | 86% | 50-60% | 30% reduction |
| HA | No | Yes | ✓ |

---

## ✅ Success Checklist

After migration, verify:
- [ ] 2 nodes online and Ready
- [ ] PostgreSQL: 1 primary + 1 replica running
- [ ] Replication lag < 10MB
- [ ] Backend: 6 pods running (3 per node)
- [ ] No connection timeout errors
- [ ] Indexing progressing normally
- [ ] API responding < 200ms
- [ ] Resource usage < 70%

---

## 🔄 Next Steps (Long-term)

After successful migration, consider:
1. **Month 2-3**: Monitor performance, tune parameters
2. **Month 4-6**: Evaluate Citus sharding for 40,000 TPS
3. **Month 7-12**: Consider event-driven architecture for 100,000+ TPS

See `docs/long-term-architecture-roadmap.md` for details.

---

**Ready to start? Open `docs/migration-to-ha-cluster.md` and follow Phase 1!**
