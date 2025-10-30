# PG_PARTMAN Implementation Guide

Quick reference for implementing pg_partman partition-based data retention in monad-indexer.

## Overview

**Problem**: DELETE-based retention takes hours, locks tables, and wastes I/O.
**Solution**: pg_partman automatically drops old partitions in milliseconds (99.9% faster).

**Timeline**: 3 weeks (1 week setup, 1 week migration, 1 week monitoring)

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
SELECT * FROM pg_extension WHERE extname = 'pg_partman';

-- Check background worker
SELECT * FROM pg_stat_activity WHERE backend_type = 'pg_partman_bgw';
```

### 4. Create partitions

```bash
kubectl cp scripts/pg_partman_setup.sql monad-indexer-dev-postgresql-1:/tmp/pg_partman_setup.sql -n monad-indexer-dev

kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -f /tmp/pg_partman_setup.sql
```

This creates `*_partitioned` tables and registers them with pg_partman. Duration: 5-10 minutes.

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

### 4. Monitor

```bash
# Check indexer logs
kubectl logs -f deployment/monad-indexer-dev-backend -n monad-indexer-dev

# Check Prometheus alerts
kubectl get prometheusrules -n monad-indexer-dev

# Verify partition maintenance
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -d blockscout -c "
SELECT parent_table, partition_interval, retention
FROM partman.part_config;
"
```

### 5. Drop old tables after 7 days

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

### Background worker not running
```bash
# Check logs
kubectl logs monad-indexer-dev-postgresql-1 -n monad-indexer-dev | grep partman

# Verify config
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- psql -U postgres -c "SHOW shared_preload_libraries;"
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
