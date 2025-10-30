# PG_PARTMAN Implementation Guide

Quick reference for implementing pg_partman partition-based data retention in monad-indexer.

## Overview

**Problem**: DELETE-based retention takes hours, locks tables, and wastes I/O.
**Solution**: pg_partman automatically drops old partitions in milliseconds (99.9% faster).

**Timeline**: 3 weeks (1 week setup, 1 week migration, 1 week monitoring)

---

## Fresh Deployment Workflow

For NEW deployments (fresh PostgreSQL cluster):

### What's Automatic:
✅ **Extension creation** - Happens automatically via `postInitSQL` on first cluster start
✅ **Maintenance CronJob** - Automatically enabled when `postgresql.partman.enabled: true`

### What's Manual:
📖 **Partition setup** - Run once after cluster is ready (see [Week 1: Extension Setup](#week-1-extension-setup) below)

### Quick Start for Fresh Deployment:

```bash
# 1. Deploy with pg_partman enabled
helm install monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml

# 2. Wait for cluster to be ready (~2-5 min)
kubectl wait --for=condition=Ready cluster/monad-indexer-dev-postgresql -n monad-indexer-dev --timeout=300s

# 3. Run partition setup (ONE TIME ONLY)
kubectl exec -i monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout < scripts/pg_partman_setup.sql

# 4. Done! Maintenance CronJob is already running
kubectl get cronjobs -n monad-indexer-dev | grep partman
```

**That's it!** The script is idempotent - safe to run multiple times.

**Important**: CloudNativePG does NOT support pg_partman background worker (`shared_preload_libraries` is fixed). Maintenance runs via Kubernetes CronJob instead.

---

## Week 1: Extension Setup

### 1. Enable pg_partman in values-dev.yaml

```yaml
postgresql:
  partman:
    enabled: true
    retentionDays: 90  # Conservative start
    premakeDays: 3
    bgwInterval: 1800  # 30 min in dev
```

### 2. Deploy to trigger rolling restart

```bash
helm upgrade monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

CloudNativePG automatically performs zero-downtime rolling restart to load `pg_partman_bgw`.

### 3. Verify extension

```bash
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout

-- Check extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_partman';
-- Expected: pg_partman | 5.3.1

-- Check available functions
SELECT proname FROM pg_proc
WHERE proname IN ('create_parent', 'partition_data_proc', 'run_maintenance_proc')
ORDER BY proname;
-- Expected: create_parent, partition_data_proc, run_maintenance_proc
```

**Note**: Background worker (`pg_partman_bgw`) is NOT available in CloudNativePG. Maintenance runs via CronJob.

### 4. Create partitions

```bash
# Run setup script via stdin (read-only filesystem)
kubectl exec -i monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout < scripts/pg_partman_setup.sql
```

This creates `*_partitioned` tables and registers them with pg_partman.

**What it does**:
- Sets timezone to UTC
- Creates partitioned versions of 5 tables
- Registers with pg_partman (90-day retention)
- Creates 7 days of future partitions
- Runs ANALYZE for constraint exclusion

Duration: 5-10 minutes.

---

## Week 2: Data Migration

### 1. Enable migration job

```yaml
postgresql:
  partman:
    migration:
      enabled: true
      batchSize: 50000
      batchInterval: 10  # 10s sleep between batches
```

### 2. Deploy migration job

```bash
helm upgrade monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

This creates a Kubernetes Job that uses `partman.partition_data_proc()` to migrate data in batches.

### 3. Monitor migration

```bash
# Watch job progress
kubectl logs -f job/monad-indexer-dev-pg-partman-migration -n monad-indexer-dev

# Check data counts
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT 'blocks' as table, COUNT(*) FROM blocks
UNION ALL SELECT 'blocks_partitioned', COUNT(*) FROM blocks_partitioned
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
UNION ALL SELECT 'transactions_partitioned', COUNT(*) FROM transactions_partitioned;
"
```

Duration: 12-48 hours depending on data volume (runs in background).

### 4. Test queries on partitioned tables

```sql
-- Test partition pruning
EXPLAIN ANALYZE
SELECT * FROM blocks_partitioned
WHERE inserted_at > NOW() - INTERVAL '7 days';
-- Should show "Partitions pruned: X"

-- Test write performance
INSERT INTO blocks_partitioned SELECT * FROM blocks WHERE number = 12345;
```

---

## Week 3: Cutover & Monitoring

### 1. Schedule maintenance window

Choose low-traffic period (e.g., Sunday 2 AM UTC).

### 2. Swap tables (atomic rename)

```sql
BEGIN;
-- Rename original tables
ALTER TABLE blocks RENAME TO blocks_old;
ALTER TABLE transactions RENAME TO transactions_old;
ALTER TABLE logs RENAME TO logs_old;
ALTER TABLE token_transfers RENAME TO token_transfers_old;
ALTER TABLE internal_transactions RENAME TO internal_transactions_old;

-- Rename partitioned tables to original names
ALTER TABLE blocks_partitioned RENAME TO blocks;
ALTER TABLE transactions_partitioned RENAME TO transactions;
ALTER TABLE logs_partitioned RENAME TO logs;
ALTER TABLE token_transfers_partitioned RENAME TO token_transfers;
ALTER TABLE internal_transactions_partitioned RENAME TO internal_transactions;
COMMIT;
```

Downtime: **0 seconds** (atomic renames).

### 3. Restart backend pods

```bash
kubectl rollout restart deployment/monad-indexer-dev-backend -n monad-indexer-dev
```

This clears Ecto's connection pool and schema cache.

### 4. Enable Maintenance CronJob

```yaml
# values-dev.yaml
postgresql:
  partman:
    maintenance:
      enabled: true  # Enable CronJob
      schedule: "0 * * * *"  # Hourly
```

```bash
# Deploy
helm upgrade monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

### 5. Monitor

```bash
# Check indexer logs
kubectl logs -f deployment/monad-indexer-dev-backend -n monad-indexer-dev

# Check maintenance CronJob
kubectl get cronjob monad-indexer-dev-pg-partman-maintenance -n monad-indexer-dev
kubectl get jobs -n monad-indexer-dev | grep partman-maintenance | head -5

# Check maintenance logs
kubectl logs -l app.kubernetes.io/component=pg-partman-maintenance -n monad-indexer-dev --tail=50

# Verify partition status
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT
  parent_table,
  partition_interval,
  retention,
  maintenance_last_run,
  (SELECT COUNT(*) FROM pg_inherits WHERE inhparent = pc.parent_table::regclass) as partition_count
FROM partman.part_config pc;
"

# Check default partitions (should be 0 or low)
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT parent_table, partman.check_default(parent_table) as default_rows
FROM partman.part_config;
"

# Check Prometheus alerts
kubectl get prometheusrules -n monad-indexer-dev | grep partman
```

### 6. Drop old tables after 7 days

```sql
-- After confirming everything works for a week
DROP TABLE blocks_old CASCADE;
DROP TABLE transactions_old CASCADE;
DROP TABLE logs_old CASCADE;
DROP TABLE token_transfers_old CASCADE;
DROP TABLE internal_transactions_old CASCADE;

VACUUM FULL;  -- Reclaim disk space
```

---

## Rollback Procedures

### Before Cutover (Week 1-2)

**If setup/migration fails:**

```bash
# Delete migration job
kubectl delete job monad-indexer-dev-pg-partman-migration -n monad-indexer-dev

# Drop partitioned tables
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
DROP TABLE IF EXISTS blocks_partitioned CASCADE;
DROP TABLE IF EXISTS transactions_partitioned CASCADE;
DROP TABLE IF EXISTS logs_partitioned CASCADE;
DROP TABLE IF EXISTS token_transfers_partitioned CASCADE;
DROP TABLE IF EXISTS internal_transactions_partitioned CASCADE;
"

# Disable pg_partman
helm upgrade monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml \
  --set postgresql.partman.enabled=false
```

Impact: **None** (original tables untouched).

### After Cutover (Week 3+)

**If issues discovered after table swap:**

```sql
BEGIN;
-- Swap back to old tables
ALTER TABLE blocks RENAME TO blocks_partitioned;
ALTER TABLE transactions RENAME TO transactions_partitioned;
ALTER TABLE logs RENAME TO logs_partitioned;
ALTER TABLE token_transfers RENAME TO token_transfers_partitioned;
ALTER TABLE internal_transactions RENAME TO internal_transactions_partitioned;

ALTER TABLE blocks_old RENAME TO blocks;
ALTER TABLE transactions_old RENAME TO transactions;
ALTER TABLE logs_old RENAME TO logs;
ALTER TABLE token_transfers_old RENAME TO token_transfers;
ALTER TABLE internal_transactions_old RENAME TO internal_transactions;
COMMIT;

-- Restart backend
kubectl rollout restart deployment/monad-indexer-dev-backend -n monad-indexer-dev
```

Downtime: **0 seconds** (atomic renames).

**Important**: Keep `*_old` tables for at least 7 days after cutover.

---

## Production Rollout

After successful dev testing:

1. **Staging**: Repeat Week 1-3 with production-like data volume
2. **Production**:
   - Use `retentionDays: 30` (not 90)
   - Use `bgwInterval: 3600` (1 hour)
   - Schedule cutover during maintenance window
   - Have rollback plan ready
   - Monitor for 7 days before dropping old tables

---

## Key Performance Metrics

| Metric | DELETE-based | pg_partman |
|--------|--------------|------------|
| Retention execution | 2-6 hours | 200ms |
| Table locks | Full table | None (only on partition) |
| I/O operations | Millions | Hundreds |
| Disk reclaim | Requires VACUUM FULL | Immediate |
| Query performance | Same | 2-10x faster (pruning) |

---

## Troubleshooting

### "No partition found for key"
```sql
-- Manually create missing partition
SELECT partman.create_partition('public.blocks_partitioned', p_parent_table := 'public.blocks_partitioned');

-- Or run maintenance manually
SELECT partman.run_maintenance_proc();
```

### Maintenance CronJob not running
```bash
# Check CronJob status
kubectl get cronjob monad-indexer-dev-pg-partman-maintenance -n monad-indexer-dev

# Check recent jobs
kubectl get jobs -n monad-indexer-dev | grep partman-maintenance | head -5

# Check job logs
kubectl logs -l app.kubernetes.io/component=pg-partman-maintenance -n monad-indexer-dev --tail=100

# Manual maintenance (if CronJob stuck)
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SET timezone = 'UTC';
CALL partman.run_maintenance_proc(p_wait := 1);
"
```

### Migration job stuck
```bash
# Check current batch progress
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT COUNT(*) FROM blocks WHERE inserted_at NOT IN (SELECT inserted_at FROM blocks_partitioned);
"

# Check for locks
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT * FROM pg_locks WHERE NOT granted;
"
```

---

## References

- **pg_partman setup script**: `scripts/pg_partman_setup.sql`
- **Migration job**: `charts/monad-indexer/templates/pg-partman-migration-job.yaml`
- **Monitoring**: `charts/monad-indexer/templates/retention-monitoring.yaml`
- **Configuration**: `charts/monad-indexer/values.yaml` (search for `partman:`)
- **CloudNativePG docs**: https://cloudnative-pg.io/
- **pg_partman docs**: https://github.com/pgpartman/pg_partman
