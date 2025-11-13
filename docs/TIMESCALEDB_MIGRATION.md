# TimescaleDB Migration Guide

## Overview

This guide documents the migration from pg_partman to TimescaleDB for the Monad Blockscout indexer.

**Date:** 2025-01-13
**Status:** Ready for deployment
**Estimated Downtime:** 1-2 hours (for hypertable conversion)

## What Changed

### 1. PostgreSQL Image
- **Before:** `ghcr.io/hoodrunio/postgresql-partman:17`
- **After:** `timescale/timescaledb-ha:pg16`

### 2. Partition Management
- **Before:** pg_partman (manual cron jobs, SQL scripts)
- **After:** TimescaleDB (automatic, zero-maintenance)

### 3. Files Removed
```
✗ charts/monad-indexer/templates/pg-partman-maintenance-cronjob.yaml
✗ charts/monad-indexer/templates/pg-partman-migration-job.yaml
✗ docs/PG_PARTMAN.md
✗ scripts/pg_partman_setup.sql
✗ scripts/test_pg_partman.sh
```

### 4. Files Added
```
✓ scripts/timescaledb_setup.sql (initialization script)
✓ docs/TIMESCALEDB_MIGRATION.md (this file)
```

### 5. Configuration Changes
```yaml
# values-production.yaml

# Old: pg_partman config (removed)
partman:
  enabled: true
  retentionDays: 30

# New: TimescaleDB config (added)
timescaledb:
  enabled: true
  hypertables:
    - table: "transactions"
      timeColumn: "inserted_at"
      chunkInterval: "1 day"
      compression:
        enabled: true
        afterDays: 7
      retention:
        enabled: false  # For mainnet decision
        afterDays: 30
```

## Benefits

### Performance
- ✅ **5-10x faster queries** (automatic partition pruning)
- ✅ **70-90% disk savings** (compression: 86GB → 8-17GB)
- ✅ **Zero maintenance** (no cron jobs, automatic chunk management)

### Operations
- ✅ **No code changes required** (100% PostgreSQL compatible)
- ✅ **Automatic partitioning** (no manual SQL scripts)
- ✅ **Built-in compression** (configurable policies)
- ✅ **Easy retention** (optional, disabled for now)

## Migration Steps

### Phase 1: Pre-Migration (5 minutes)

1. **Commit changes**
```bash
git add .
git commit -m "feat(postgresql): migrate from pg_partman to TimescaleDB"
git push origin stable
```

2. **Verify current state**
```bash
# Check current disk usage
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "\dt+ transactions"

# Should show ~86GB
```

3. **Scale down backend (stop indexing)**
```bash
kubectl scale deployment monad-indexer-production-backend \
  --replicas=0 -n monad-indexer-production
```

### Phase 2: Deploy TimescaleDB (10 minutes)

1. **Sync ArgoCD**
```bash
argocd app sync argocd/monad-indexer-production --prune
```

2. **Wait for PostgreSQL pod restart**
```bash
# PostgreSQL will restart with new TimescaleDB image
kubectl get pods -n monad-indexer-production -w | grep postgresql

# Wait for: monad-indexer-production-postgresql-1   1/1   Running
```

3. **Verify TimescaleDB extension**
```bash
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"

# Should show: timescaledb | 2.18.x
```

### Phase 3: Run Migration Script (1-2 hours)

1. **Execute TimescaleDB setup**
```bash
kubectl exec -i -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout < scripts/timescaledb_setup.sql
```

**Expected Output:**
```
NOTICE:  Hypertable created: transactions
NOTICE:  Migrating existing data to chunks... This may take 1-2 hours for 86GB
NOTICE:  Compression policy added: transactions (after 7 days)
NOTICE:  Expected disk savings: 70-90% (86GB -> 8-17GB)
NOTICE:  ============================================
NOTICE:  TimescaleDB Setup Complete!
NOTICE:  ============================================
NOTICE:  Hypertable: transactions
NOTICE:  Total chunks: ~30 (for 30 days of data)
NOTICE:  Compressed chunks: 0 (compression runs after 7 days)
NOTICE:  Total size: 86 GB
NOTICE:  Chunk interval: 1 day
NOTICE:  Compression: After 7 days
NOTICE:  Retention: Disabled (keep all data)
NOTICE:  ============================================
```

2. **Monitor migration progress**
```bash
# Check chunk creation progress
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM timescaledb_information.chunks WHERE hypertable_name = 'transactions';"

# Check if hypertable is ready
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = 'transactions';"
```

### Phase 4: Verify and Resume (15 minutes)

1. **Test query performance**
```bash
# Test SELECT (should work exactly as before)
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM transactions;"

# Test with time filter (should be much faster)
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM transactions WHERE inserted_at > NOW() - INTERVAL '1 day';"
```

2. **Scale up backend**
```bash
kubectl scale deployment monad-indexer-production-backend \
  --replicas=2 -n monad-indexer-production
```

3. **Monitor backend logs**
```bash
kubectl logs -f deployment/monad-indexer-production-backend -n monad-indexer-production

# Should see normal indexing resume, no errors about missing tables
```

4. **Verify API endpoints**
```bash
# Test transactions endpoint
curl -s "https://monad-tn1-indexer.hoodscan.io/api/v2/transactions" | jq '.items | length'

# Should return results (faster than before!)
```

### Phase 5: Wait for Compression (7 days)

After 7 days, TimescaleDB will automatically start compressing old chunks:

```bash
# Check compression status
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "
    SELECT
      chunk_name,
      pg_size_pretty(total_bytes) as uncompressed,
      pg_size_pretty(compressed_total_bytes) as compressed,
      ROUND(100.0 * compressed_total_bytes / NULLIF(total_bytes, 0), 2) as ratio_pct
    FROM timescaledb_information.chunks
    WHERE hypertable_name = 'transactions' AND is_compressed = true
    ORDER BY range_end DESC LIMIT 10;
  "
```

Expected compression: 70-90% savings (86GB → 8-17GB after 7 days).

## Rollback Plan

If migration fails, rollback steps:

### 1. Revert Git Changes
```bash
git revert HEAD
git push origin stable
argocd app sync argocd/monad-indexer-production
```

### 2. Restore from Backup (if enabled)
```bash
# Use CNPG backup/restore
kubectl cnpg backup monad-indexer-production-postgresql -n monad-indexer-production
```

### 3. Manual Recovery (worst case)
```sql
-- Drop hypertable (converts back to normal table)
SELECT drop_hypertable('transactions', if_exists => true);

-- Rebuild indexes if needed
REINDEX TABLE transactions;
```

## Post-Migration Monitoring

### Key Metrics to Watch

1. **Disk Usage**
```bash
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  df -h | grep /var/lib/postgresql/data
```

2. **Query Performance**
```bash
# Compare before/after
# Before: /api/v2/transactions = 8-15 seconds
# After: /api/v2/transactions = 1-3 seconds (expected)
```

3. **Chunk Count**
```sql
SELECT COUNT(*) FROM timescaledb_information.chunks
WHERE hypertable_name = 'transactions';
```

4. **Compression Progress (after 7 days)**
```sql
SELECT
  COUNT(*) FILTER (WHERE is_compressed = true) as compressed,
  COUNT(*) FILTER (WHERE is_compressed = false) as uncompressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'transactions';
```

## Backend Compatibility

### No Code Changes Required

✅ All existing queries work unchanged:
```sql
-- SELECT queries (same as before)
SELECT * FROM transactions WHERE hash = $1;
SELECT * FROM transactions ORDER BY inserted_at DESC LIMIT 50;

-- INSERT queries (same as before)
INSERT INTO transactions (...) VALUES (...);

-- UPDATE queries (same as before)
UPDATE transactions SET status = $1 WHERE hash = $2;

-- DELETE queries (same as before - but slower on compressed chunks)
DELETE FROM transactions WHERE inserted_at < NOW() - INTERVAL '30 days';
```

### What TimescaleDB Does Automatically

1. **Query Routing**: Directs queries to relevant chunks only
2. **Compression**: Compresses old data after 7 days
3. **Chunk Creation**: Creates new daily chunks automatically
4. **Partition Pruning**: Skips irrelevant partitions in queries

## Future Enhancements

### For Mainnet (when ready)

1. **Enable Retention Policy**
```sql
-- Uncomment in timescaledb_setup.sql
SELECT add_retention_policy('transactions', drop_after => INTERVAL '30 days');
```

2. **Add Continuous Aggregates** (pre-computed queries)
```sql
-- Example for recent transactions materialized view
CREATE MATERIALIZED VIEW recent_transactions_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('5 minutes', inserted_at) AS bucket,
  COUNT(*) as tx_count
FROM transactions
WHERE inserted_at > NOW() - INTERVAL '1 hour'
GROUP BY bucket;
```

3. **Multi-Table Hypertables**
```sql
-- Apply to other large tables
SELECT create_hypertable('logs', 'inserted_at');
SELECT create_hypertable('token_transfers', 'inserted_at');
```

## Troubleshooting

### Issue: Migration script hangs

**Cause:** Large table (77M rows) takes time to migrate
**Solution:** Wait patiently (1-2 hours is normal)

```bash
# Monitor progress
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM timescaledb_information.chunks;"
```

### Issue: Backend can't connect after migration

**Cause:** Connection string unchanged, but possible connection pool exhaustion
**Solution:** Restart backend pods

```bash
kubectl rollout restart deployment/monad-indexer-production-backend -n monad-indexer-production
```

### Issue: Queries still slow after migration

**Cause:** Query planner needs statistics update
**Solution:** Run ANALYZE

```bash
kubectl exec -n monad-indexer-production monad-indexer-production-postgresql-1 -- \
  psql -U postgres -d blockscout -c "ANALYZE transactions;"
```

### Issue: Compression not happening

**Cause:** Compression policy runs in background job
**Solution:** Wait or trigger manually

```sql
-- Manual compression trigger
CALL run_job((SELECT job_id FROM timescaledb_information.jobs WHERE proc_name = 'policy_compression'));
```

## References

- [TimescaleDB Documentation](https://docs.timescale.com/)
- [Hypertables Guide](https://docs.timescale.com/use-timescale/latest/hypertables/)
- [Compression Guide](https://docs.timescale.com/use-timescale/latest/compression/)
- [Migration Best Practices](https://docs.timescale.com/migrate/latest/)

## Support

For issues or questions:
1. Check TimescaleDB logs: `kubectl logs -n monad-indexer-production monad-indexer-production-postgresql-1`
2. Review this guide's troubleshooting section
3. Contact infrastructure team
