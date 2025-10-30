# Data Retention Testing Guide

This guide provides step-by-step instructions for testing the data retention CronJob in your Monad Indexer deployment.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Testing in Dev Environment](#testing-in-dev-environment)
4. [Manual Job Trigger](#manual-job-trigger)
5. [Validation Queries](#validation-queries)
6. [Monitoring](#monitoring)
7. [Troubleshooting](#troubleshooting)
8. [Rollback Procedures](#rollback-procedures)

---

## Overview

The data retention system automatically deletes blockchain data older than a configured retention period (default: 90 days, target: 30 days). It uses:

- **Kubernetes CronJob**: Scheduled daily execution
- **PostgreSQL**: Direct deletion via SQL
- **Prometheus**: Monitoring and alerting

### Safety Features

- **Dry Run Mode**: Test without actual deletion
- **Batch Processing**: Delete in small batches to avoid locks
- **Foreign Key Ordering**: Deletes in correct order to avoid FK violations
- **VACUUM**: Reclaims disk space after deletion

---

## Prerequisites

1. **Access to Kubernetes cluster**:
   ```bash
   kubectl config current-context
   ```

2. **Verify deployment namespace**:
   ```bash
   kubectl get namespaces | grep monad-indexer
   ```

3. **Check if retention is enabled**:
   ```bash
   helm get values monad-indexer -n monad-indexer-dev | grep -A 10 "retention:"
   ```

4. **Required tools**:
   - `kubectl`
   - `helm` (optional, for value checks)
   - `psql` (optional, for manual queries)

---

## Testing in Dev Environment

### Step 1: Enable Retention in Dev (Already Configured)

The dev environment (`values-dev.yaml`) has retention enabled with safe defaults:

```yaml
retention:
  enabled: true
  schedule: "0 3 * * *"  # Daily at 3 AM
  retentionDays: 90      # Conservative start
  dryRun: true           # DRY RUN - no actual deletion
```

### Step 2: Deploy/Update Helm Chart

```bash
# Navigate to chart directory
cd /Users/errorist/Documents/new-projects/monad-indexer

# Dry run to preview changes
helm upgrade --install monad-indexer ./charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml \
  --dry-run --debug

# Apply changes
helm upgrade --install monad-indexer ./charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

### Step 3: Verify CronJob Creation

```bash
# Check if CronJob was created
kubectl get cronjob -n monad-indexer-dev

# Expected output:
# NAME                             SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# monad-indexer-retention          0 3 * * *     False     0        <none>          1m

# Describe CronJob for details
kubectl describe cronjob monad-indexer-retention -n monad-indexer-dev
```

---

## Manual Job Trigger

Instead of waiting for the scheduled run, trigger the job manually for testing.

### Trigger Job from CronJob

```bash
# Create a one-time Job from the CronJob
kubectl create job --from=cronjob/monad-indexer-retention \
  manual-retention-test-$(date +%s) \
  -n monad-indexer-dev
```

### Monitor Job Progress

```bash
# Watch job status
kubectl get jobs -n monad-indexer-dev -w

# Get job details
kubectl describe job manual-retention-test-<timestamp> -n monad-indexer-dev

# View job logs (real-time)
kubectl logs -f job/manual-retention-test-<timestamp> -n monad-indexer-dev
```

### Expected Output (Dry Run Mode)

```
==================================================
Monad Indexer Data Retention Job
==================================================
Started at: 2025-10-30 03:00:00 UTC
Retention period: 90 days
Batch size: 10000
Dry run: true
==================================================

[INFO] Testing database connection...
[SUCCESS] Database connection successful

==================================================
Current Data Statistics
==================================================
[INFO] Getting oldest block timestamp...
[SUCCESS] Getting oldest block timestamp completed in 0s
Result: 2025-10-29 12:00:00

[INFO] Getting total block count...
[SUCCESS] Getting total block count completed in 0s
Result: 4562

==================================================
Data to be deleted (older than 90 days)
==================================================
Blocks: 0
Transactions: 0
Logs: 0
Token transfers: 0

[INFO] No data to delete. All data is within retention period.
Job completed successfully at: 2025-10-30 03:00:01 UTC
```

---

## Validation Queries

### Connect to PostgreSQL

```bash
# Get PostgreSQL password
PGPASSWORD=$(kubectl get secret monad-indexer-dev-postgresql-app \
  -n monad-indexer-dev \
  -o jsonpath='{.data.password}' | base64 -d)

# Connect via port-forward
kubectl port-forward svc/monad-indexer-dev-postgresql-rw 5432:5432 -n monad-indexer-dev &

# Connect with psql
PGPASSWORD=$PGPASSWORD psql -h localhost -U blockscout -d blockscout
```

### Query: Check Data Age

```sql
-- Oldest block
SELECT
  MIN(inserted_at) as oldest_block,
  MAX(inserted_at) as newest_block,
  EXTRACT(EPOCH FROM (NOW() - MIN(inserted_at))) / 86400 as age_days,
  COUNT(*) as total_blocks
FROM blocks;

-- Oldest transaction
SELECT
  MIN(inserted_at) as oldest_transaction,
  MAX(inserted_at) as newest_transaction,
  EXTRACT(EPOCH FROM (NOW() - MIN(inserted_at))) / 86400 as age_days,
  COUNT(*) as total_transactions
FROM transactions;

-- Oldest log
SELECT
  MIN(inserted_at) as oldest_log,
  MAX(inserted_at) as newest_log,
  EXTRACT(EPOCH FROM (NOW() - MIN(inserted_at))) / 86400 as age_days,
  COUNT(*) as total_logs
FROM logs;
```

### Query: Table Sizes

```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) as indexes_size,
  n_live_tup as live_rows,
  n_dead_tup as dead_rows
FROM pg_tables
LEFT JOIN pg_stat_user_tables USING (schemaname, tablename)
WHERE schemaname = 'public'
  AND tablename IN ('blocks', 'transactions', 'logs', 'token_transfers', 'internal_transactions')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Query: Count Old Data

```sql
-- Count blocks older than retention period
SELECT COUNT(*) as old_blocks
FROM blocks
WHERE inserted_at < NOW() - INTERVAL '90 days';

-- Count transactions older than retention period
SELECT COUNT(*) as old_transactions
FROM transactions
WHERE inserted_at < NOW() - INTERVAL '90 days';

-- Count logs older than retention period
SELECT COUNT(*) as old_logs
FROM logs
WHERE inserted_at < NOW() - INTERVAL '90 days';
```

### Query: Storage Usage

```sql
-- Database size
SELECT pg_size_pretty(pg_database_size(current_database())) as database_size;

-- Table sizes with percentages
SELECT
  tablename,
  pg_size_pretty(pg_total_relation_size(tablename::regclass)) as size,
  pg_total_relation_size(tablename::regclass) * 100.0 /
    (SELECT SUM(pg_total_relation_size(tablename::regclass))
     FROM pg_tables
     WHERE schemaname = 'public') as percentage
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(tablename::regclass) DESC
LIMIT 10;
```

---

## Monitoring

### Check Prometheus Alerts

```bash
# Port-forward to Prometheus (if running)
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &

# Open browser to: http://localhost:9090/alerts
```

### Available Alerts

1. **DataRetentionJobFailed**: Job execution failed
2. **DataRetentionJobMissing**: Job hasn't run in 48 hours
3. **DataRetentionJobSlow**: Job running for >6 hours
4. **OldDataAccumulating**: Data older than retention period exists
5. **DatabaseGrowthRateHigh**: Database growing >100GB/day
6. **DatabaseStorageHigh**: Storage >80% full
7. **DatabaseVacuumDelayed**: VACUUM hasn't run in 24 hours

### Check Metrics

```bash
# Query Prometheus metrics
curl -s http://localhost:9090/api/v1/query?query=kube_job_status_succeeded | jq

# Check custom metrics (if CloudNativePG monitoring enabled)
curl -s http://localhost:9090/api/v1/query?query=data_age_oldest_block_age_seconds | jq
```

---

## Troubleshooting

### Issue: Job Fails to Start

**Symptoms:**
- Job status: `Failed` or `Error`
- Pods not created

**Diagnosis:**
```bash
# Check job status
kubectl describe job manual-retention-test-<timestamp> -n monad-indexer-dev

# Check CronJob configuration
kubectl get cronjob monad-indexer-retention -n monad-indexer-dev -o yaml
```

**Common Causes:**
1. Missing PostgreSQL secret
2. ServiceAccount permissions
3. Image pull errors
4. Resource quota exceeded

**Fix:**
```bash
# Verify secret exists
kubectl get secret monad-indexer-dev-postgresql-app -n monad-indexer-dev

# Check ServiceAccount
kubectl get serviceaccount -n monad-indexer-dev

# Check resource quotas
kubectl describe resourcequota -n monad-indexer-dev
```

---

### Issue: Database Connection Failed

**Symptoms:**
- Error: `FATAL: password authentication failed`
- Error: `could not connect to server`

**Diagnosis:**
```bash
# Check PostgreSQL status
kubectl get cluster -n monad-indexer-dev

# Get PostgreSQL logs
kubectl logs monad-indexer-dev-postgresql-1 -n monad-indexer-dev
```

**Fix:**
```bash
# Verify secret values
kubectl get secret monad-indexer-dev-postgresql-app -n monad-indexer-dev -o yaml

# Test connection manually
kubectl run -it --rm psql-test --image=postgres:17 \
  --env="PGHOST=monad-indexer-dev-postgresql-rw" \
  --env="PGUSER=blockscout" \
  --env="PGPASSWORD=$(kubectl get secret monad-indexer-dev-postgresql-app -n monad-indexer-dev -o jsonpath='{.data.password}' | base64 -d)" \
  --env="PGDATABASE=blockscout" \
  -- psql -c "SELECT version();"
```

---

### Issue: DELETE Takes Too Long

**Symptoms:**
- Job running for hours
- Table locks blocking writes
- High disk I/O

**Diagnosis:**
```bash
# Check active queries
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -c \
  "SELECT pid, now() - query_start as duration, state, query
   FROM pg_stat_activity
   WHERE state != 'idle'
   ORDER BY duration DESC;"

# Check table locks
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -c \
  "SELECT * FROM pg_locks WHERE granted = false;"
```

**Fix:**
1. Reduce `batchSize` in values.yaml (e.g., 10000 → 5000)
2. Increase `jobTimeoutSeconds`
3. Schedule during low-traffic periods
4. Consider migrating to pg_partman for faster deletion

---

### Issue: Disk Space Not Reclaimed

**Symptoms:**
- Data deleted but disk usage unchanged
- `pg_database_size()` still high

**Diagnosis:**
```bash
# Check dead tuples
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -c \
  "SELECT schemaname, relname, n_dead_tup, n_live_tup
   FROM pg_stat_user_tables
   WHERE schemaname = 'public'
   ORDER BY n_dead_tup DESC LIMIT 10;"
```

**Explanation:**
PostgreSQL marks deleted rows as "dead tuples" but doesn't immediately reclaim space. VACUUM is required.

**Fix:**
```bash
# Manual VACUUM (if job didn't run it)
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -c "VACUUM FULL ANALYZE blocks;"

# Or VACUUM all critical tables
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -c \
  "VACUUM FULL ANALYZE blocks, transactions, logs, token_transfers;"
```

**Note:** `VACUUM FULL` requires table lock and can take hours for large tables. Consider scheduling during maintenance window.

---

## Rollback Procedures

### Disable Retention CronJob

**If retention is causing issues:**

```bash
# Suspend CronJob (stops new jobs from starting)
kubectl patch cronjob monad-indexer-retention -n monad-indexer-dev \
  -p '{"spec":{"suspend":true}}'

# Verify suspension
kubectl get cronjob monad-indexer-retention -n monad-indexer-dev
```

### Stop Running Job

```bash
# Delete running job (stops active deletion)
kubectl delete job <job-name> -n monad-indexer-dev

# Or delete all retention jobs
kubectl delete job -l app.kubernetes.io/component=retention -n monad-indexer-dev
```

### Disable via Helm

```bash
# Update values-dev.yaml
# Set: retention.enabled: false

# Upgrade chart
helm upgrade --install monad-indexer ./charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

### Restore Data (No Backup Available)

**IMPORTANT:** Once data is deleted, it cannot be recovered unless:

1. You have CloudNativePG backups enabled
2. You have Velero cluster snapshots
3. You kept `dryRun: true` (no actual deletion occurred)

**Prevention:** Always test with `dryRun: true` first!

---

## Testing Checklist

### Phase 1: Dry Run Testing (Week 1)

- [ ] Deploy CronJob with `dryRun: true`
- [ ] Trigger manual job execution
- [ ] Verify job completes successfully
- [ ] Check logs for accurate data counts
- [ ] Validate no data was actually deleted
- [ ] Confirm monitoring metrics appear in Prometheus
- [ ] Test alert triggers (simulate failures)

### Phase 2: Small Deletion Test (Week 2)

- [ ] Set `retentionDays: 180` (large retention period)
- [ ] Set `dryRun: false`
- [ ] Trigger manual job
- [ ] Monitor job execution time
- [ ] Verify small amount of data deleted
- [ ] Check disk space reclaimed after VACUUM
- [ ] Confirm no application errors
- [ ] Validate Blockscout still functions correctly

### Phase 3: Gradual Rollout (Week 3-4)

- [ ] Reduce retention to 90 days
- [ ] Run weekly for 2 weeks
- [ ] Monitor database size trends
- [ ] Adjust based on growth rate
- [ ] Reduce to 60 days (if stable)
- [ ] Reduce to 30 days (final target)

### Phase 4: Production Deployment

- [ ] Test in staging environment first
- [ ] Enable monitoring and alerting
- [ ] Schedule during low-traffic window
- [ ] Document rollback procedure
- [ ] Notify team before first run
- [ ] Monitor first 3 executions closely

---

## Next Steps

After successful testing:

1. **Enable in Staging**: Test with production-like data volume
2. **Optimize Settings**: Adjust `retentionDays` and `batchSize` based on results
3. **Enable Monitoring**: Ensure Prometheus alerts are working
4. **Document Procedures**: Update runbooks for operations team
5. **Plan Migration**: Research pg_partman for long-term solution (see [research report](./retention-research.md))

---

## Additional Resources

- **CloudNativePG Docs**: https://cloudnative-pg.io/documentation/
- **PostgreSQL VACUUM**: https://www.postgresql.org/docs/17/sql-vacuum.html
- **Kubernetes CronJob**: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- **Prometheus Alerts**: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

---

## Support

If you encounter issues:

1. Check logs: `kubectl logs -n monad-indexer-dev job/<job-name>`
2. Review monitoring: Prometheus alerts and Grafana dashboards
3. Consult [troubleshooting section](#troubleshooting)
4. For pg_partman migration: See [pg_partman implementation guide](./pg-partman-migration.md) (to be created)
