# Rollback Procedure - HA Cluster Migration

## 🎯 Overview
This document provides step-by-step instructions for rolling back the 2-node HA cluster migration if issues are encountered during or after the migration.

## ⚠️ When to Rollback

**Immediate rollback if:**
- PostgreSQL cluster fails to start after 30 minutes
- Data corruption detected
- Replication completely fails
- System is unrecoverable

**Consider rollback if:**
- Performance degradation > 50% compared to pre-migration
- Persistent connection pool exhaustion after 1 hour
- Backend pods in CrashLoopBackOff for > 30 minutes
- Critical errors in PostgreSQL logs

**DO NOT rollback if:**
- Minor transient errors during migration
- Temporary pod restarts (< 5 restarts per pod)
- Indexing lag < 100 blocks
- Single backend pod issues (when others are healthy)

---

## 📋 Pre-Rollback Checklist

1. **Verify backup exists**
```bash
# Check latest backup
kubectl get backup -n monad-indexer-production -o wide

# Verify backup in S3
aws s3 ls s3://monad-testnet-archive/postgresql/base/
```

2. **Document current state**
```bash
# Save current state for post-mortem
kubectl get all -n monad-indexer-production -o yaml > /tmp/rollback-state-$(date +%Y%m%d-%H%M%S).yaml
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=500 > /tmp/backend-logs-$(date +%Y%m%d-%H%M%S).log
kubectl logs -n monad-indexer-production monad-indexer-production-postgresql-1 --tail=500 > /tmp/postgres-logs-$(date +%Y%m%d-%H%M%S).log
```

3. **Notify stakeholders**
- Announce rollback is starting
- Estimate downtime: 30-60 minutes
- Provide status updates channel

---

## 🔄 Rollback Scenarios

### Scenario A: Rollback During Migration (Before Helm Upgrade)
**If you haven't run `helm upgrade` yet**

```bash
# 1. Simply don't proceed with the upgrade
# 2. Scale backend back up
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=3

# 3. Wait for pods to be ready
kubectl wait --for=condition=ready pod -n monad-indexer-production \
  -l app.kubernetes.io/component=backend --timeout=300s

# 4. Verify indexing resumed
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f | grep "Fetching"

# Done - system back to pre-migration state
```

---

### Scenario B: Rollback After Helm Upgrade (PostgreSQL Issues)
**If Helm upgrade completed but PostgreSQL cluster is unhealthy**

#### Step 1: Stop All Workloads (5 minutes)
```bash
# Scale down backend to prevent writes
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=0

# Wait for pods to terminate
kubectl wait --for=delete pod -n monad-indexer-production \
  -l app.kubernetes.io/component=backend --timeout=300s
```

#### Step 2: Restore Values File (2 minutes)
```bash
cd /Users/errorist/Documents/new-projects/monad-indexer

# Find backup file
ls -lt charts/monad-indexer/environments/values-production.yaml.backup.*

# Restore from backup
BACKUP_FILE=$(ls -t charts/monad-indexer/environments/values-production.yaml.backup.* | head -1)
cp "$BACKUP_FILE" charts/monad-indexer/environments/values-production.yaml

# Verify restoration
git diff charts/monad-indexer/environments/values-production.yaml
```

#### Step 3: Rollback Helm Release (15 minutes)
```bash
# Check Helm history
helm history monad-indexer-production -n monad-indexer-production

# Rollback to previous version (adjust revision number)
helm rollback monad-indexer-production -n monad-indexer-production --wait --timeout=20m

# Alternative: Re-install with old values
# helm upgrade monad-indexer-production charts/monad-indexer \
#   --namespace monad-indexer-production \
#   --values charts/monad-indexer/environments/values-production.yaml \
#   --wait --timeout=20m
```

#### Step 4: Verify Single-Node PostgreSQL (10 minutes)
```bash
# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -n monad-indexer-production \
  -l cnpg.io/cluster=monad-indexer-production-postgresql --timeout=600s

# Check cluster status
kubectl get cluster -n monad-indexer-production monad-indexer-production-postgresql

# Verify single instance
kubectl get pods -n monad-indexer-production -l cnpg.io/cluster=monad-indexer-production-postgresql

# Expected: 1 pod running (not 2)
```

#### Step 5: Scale Backend Back Up (10 minutes)
```bash
# Scale backend to original replica count
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=3

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -n monad-indexer-production \
  -l app.kubernetes.io/component=backend --timeout=300s

# Verify backend connectivity
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend --tail=50
```

#### Step 6: Verify System Recovery (10 minutes)
```bash
# Check indexing resumed
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f | grep "Fetching"

# Test API
curl -s https://monad-mainnet-indexer.hoodscan.io/api/v2/stats | jq

# Check resource usage
kubectl top nodes
kubectl top pods -n monad-indexer-production
```

---

### Scenario C: Rollback After Full Migration (System Running but Degraded)
**If migration completed but performance is poor or errors persist**

#### Step 1: Capture Diagnostic Data (10 minutes)
```bash
# Run full diagnostics
bash scripts/verify-cluster.sh > /tmp/diagnostics-$(date +%Y%m%d-%H%M%S).log 2>&1

# Export Prometheus metrics (if enabled)
# kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
# curl -s http://localhost:9090/api/v1/query?query=up > /tmp/metrics.json

# Get detailed pod status
kubectl describe pods -n monad-indexer-production > /tmp/pod-details.txt
```

#### Step 2: Attempt Targeted Fixes First (Before Full Rollback)
```bash
# Option 1: Restart only backend pods
kubectl rollout restart deployment -n monad-indexer-production \
  monad-indexer-production-backend

# Option 2: Restart only pooler
kubectl rollout restart deployment -n monad-indexer-production \
  -l cnpg.io/poolerName

# Option 3: Force PostgreSQL replica resync
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-2 -- \
  psql -U postgres -c "SELECT pg_wal_replay_resume();"

# Wait 15 minutes to see if issues resolve
```

#### Step 3: If Issues Persist - Full Rollback (45 minutes)
```bash
# Follow Scenario B steps (same process)
# 1. Scale backend to 0
# 2. Restore values file
# 3. Helm rollback
# 4. Verify single PostgreSQL
# 5. Scale backend up
# 6. Verify recovery
```

---

## 🔴 Emergency Rollback (Data Loss Scenario)

**⚠️ ONLY if PostgreSQL data is corrupted or unrecoverable**

### Step 1: Delete Broken Cluster (5 minutes)
```bash
# Delete PostgreSQL cluster (WARNING: This deletes data!)
kubectl delete cluster -n monad-indexer-production monad-indexer-production-postgresql

# Delete PVCs
kubectl delete pvc -n monad-indexer-production -l cnpg.io/cluster=monad-indexer-production-postgresql

# Verify deletion
kubectl get pvc -n monad-indexer-production
```

### Step 2: Restore from Backup (30 minutes - 2 hours depending on data size)
```bash
# Restore values file to single-node config
cp charts/monad-indexer/environments/values-production.yaml.backup.* \
   charts/monad-indexer/environments/values-production.yaml

# Deploy fresh PostgreSQL cluster
helm upgrade monad-indexer-production charts/monad-indexer \
  --namespace monad-indexer-production \
  --values charts/monad-indexer/environments/values-production.yaml \
  --wait --timeout=30m

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -n monad-indexer-production \
  -l cnpg.io/cluster=monad-indexer-production-postgresql --timeout=600s
```

### Step 3: Restore Data from S3 Backup
```bash
# Get primary pod name
PRIMARY_POD=$(kubectl get pods -n monad-indexer-production \
  -l cnpg.io/cluster=monad-indexer-production-postgresql,cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

# Trigger restore from backup (CloudNativePG handles this automatically on first boot)
# Check restore progress
kubectl logs -n monad-indexer-production "$PRIMARY_POD" -f

# Or manually restore specific backup:
# kubectl cnpg restore monad-indexer-production-postgresql \
#   --backup-name=<backup-name> \
#   --namespace=monad-indexer-production
```

### Step 4: Verify Data Integrity
```bash
# Connect to PostgreSQL
kubectl exec -n monad-indexer-production "$PRIMARY_POD" -it -- \
  psql -U postgres -d blockscout

# Check row counts
SELECT COUNT(*) FROM blocks;
SELECT COUNT(*) FROM transactions;
SELECT MAX(number) as latest_block FROM blocks;

# Exit psql
\q
```

### Step 5: Resume Indexing
```bash
# Scale backend back up
kubectl scale deployment -n monad-indexer-production \
  monad-indexer-production-backend --replicas=3

# Monitor logs
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f
```

---

## 🧪 Post-Rollback Verification

### Run Full Verification
```bash
# Use verification script
bash scripts/verify-cluster.sh

# Expected output:
# - 1 node (if agent was removed) OR 2 nodes (if agent kept running)
# - 1 PostgreSQL pod
# - 1-3 backend pods
# - All checks passing
```

### Verify Data Consistency
```bash
# Check latest indexed block
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT MAX(number) as latest_block FROM blocks;"

# Compare with chain tip
curl -s https://monad-rpc.hoodscan.io \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  | jq -r '.result' | xargs printf "%d\n"

# Lag should be < 100 blocks
```

### Monitor for Stability (1 hour)
```bash
# Watch pod status
watch kubectl get pods -n monad-indexer-production

# Monitor logs for errors
kubectl logs -n monad-indexer-production -l app.kubernetes.io/component=backend -f --since=10m

# Check metrics
kubectl top nodes
kubectl top pods -n monad-indexer-production
```

---

## 🔧 Cleanup After Rollback

### If Keeping 2-Node Cluster (Agent Still Running)
```bash
# Just keep the agent node running
# It will be used for future retry

# Cordon the agent node to prevent scheduling
kubectl cordon <agent-node-name>

# Or drain if you want to remove workloads
kubectl drain <agent-node-name> --ignore-daemonsets --delete-emptydir-data
```

### If Removing Agent Node Completely
```bash
# Drain the node
kubectl drain <agent-node-name> --ignore-daemonsets --delete-emptydir-data --force

# Delete the node
kubectl delete node <agent-node-name>

# On the agent server, stop K3s
ssh root@<agent-ip> '/usr/local/bin/k3s-agent-uninstall.sh'

# Verify single-node cluster
kubectl get nodes
```

---

## 📊 Rollback Success Criteria

✅ **Infrastructure**
- [ ] Single PostgreSQL pod running
- [ ] Backend pods running (1-3 replicas)
- [ ] No CrashLoopBackOff pods
- [ ] PgBouncer pooler operational

✅ **Database**
- [ ] PostgreSQL accepting connections
- [ ] Connection pool usage < 80%
- [ ] Query latency < 200ms

✅ **Application**
- [ ] Indexing progressing
- [ ] API responding (< 300ms)
- [ ] No connection timeout errors
- [ ] Block lag < 50 blocks

✅ **Performance**
- [ ] TPS back to pre-migration levels
- [ ] CPU utilization stable
- [ ] Memory utilization stable
- [ ] No resource exhaustion

---

## 📝 Post-Rollback Actions

### 1. Document What Went Wrong
```bash
# Create incident report
cat > /tmp/migration-incident-$(date +%Y%m%d).md <<EOF
# Migration Incident Report

**Date**: $(date)
**Duration**: XX minutes
**Rollback Reason**: [FILL IN]

## What Happened
[Describe the issue]

## Root Cause
[Identified cause]

## Actions Taken
[Rollback steps]

## Prevention
[How to avoid in future]

## Next Steps
[Plan for retry]
EOF

# Save for review
```

### 2. Analyze Logs
```bash
# Review saved logs
ls -lh /tmp/*-logs-*.log
ls -lh /tmp/diagnostics-*.log

# Look for patterns
grep -i "error\|failed\|timeout" /tmp/backend-logs-*.log
grep -i "fatal\|panic" /tmp/postgres-logs-*.log
```

### 3. Plan Retry
- Review what went wrong
- Identify missing prerequisites
- Consider staging environment test
- Schedule new migration window
- Update runbook with lessons learned

### 4. Communicate Status
- Notify stakeholders of rollback completion
- Share timeline for retry
- Document lessons learned
- Update team on next steps

---

## 🆘 Emergency Contacts

If you need help during rollback:

- **CloudNativePG Support**: https://cloudnative-pg.io/support/
- **K3s GitHub Issues**: https://github.com/k3s-io/k3s/issues
- **Blockscout Discord**: https://discord.gg/blockscout
- **Internal Team**: [Add your team contacts]

---

## 📚 References

- Migration Runbook: `docs/migration-to-ha-cluster.md`
- Verification Script: `scripts/verify-cluster.sh`
- CloudNativePG Recovery: https://cloudnative-pg.io/documentation/current/recovery/
- Helm Rollback Docs: https://helm.sh/docs/helm/helm_rollback/

---

**Remember**: Rollback is not a failure, it's a safety mechanism. Better to roll back and retry than push forward with a broken system.

**End of Rollback Procedure**
