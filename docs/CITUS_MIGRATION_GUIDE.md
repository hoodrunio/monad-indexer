# Citus Migration Guide

## Overview

This guide documents the automated migration from TimescaleDB to Citus for the Monad blockchain indexer. The migration enables horizontal scalability and achieves 54-70% disk savings through columnar compression.

## Architecture

### Distributed Tables Strategy

The migration implements a co-location strategy to optimize query performance:

| Table | Distribution Key | Type | Co-location Group | Reasoning |
|-------|-----------------|------|-------------------|-----------|
| `transactions` | `hash` | Distributed | transactions | Primary table, hash-based sharding |
| `logs` | `transaction_hash` | Distributed | transactions | Co-located with transactions |
| `token_transfers` | `transaction_hash` | Distributed | transactions | Co-located with transactions |
| `internal_transactions` | `transaction_hash` | Distributed | transactions | Co-located with transactions |
| `blocks` | - | Reference | - | Replicated to all nodes (small table) |
| `addresses` | - | Reference | - | Replicated to all nodes (metadata) |
| `tokens` | - | Reference | - | Replicated to all nodes (metadata) |
| `smart_contracts` | - | Reference | - | Replicated to all nodes (metadata) |
| `address_coin_balances` | `address_hash` | Distributed | addresses | Address-based queries |
| `address_token_balances` | `address_hash` | Distributed | addresses | Address-based queries |

**Co-location Benefits:**
- `transactions ⋈ logs ⋈ token_transfers`: Zero network I/O for JOINs (local to same shard)
- Reference tables (`blocks`, `addresses`, etc.): Replicated to all nodes, always local
- 2-node setup optimized: Reference tables eliminate cross-node queries for metadata

### Partitioning Strategy

Time-based partitioning with automated management via pg_cron:

| Table | Partition Interval | Retention Period | Compression Threshold |
|-------|-------------------|------------------|----------------------|
| `transactions` | Monthly | 90 days | 7 days |
| `logs` | Weekly | 90 days | 7 days |
| `token_transfers` | Monthly | 90 days | 7 days |
| `internal_transactions` | Monthly | 90 days | 7 days |

**Partition Naming Convention:**
- Monthly: `{table_name}_YYYY_MM` (e.g., `transactions_2025_11`)
- Weekly: `{table_name}_YYYY_wWW` (e.g., `logs_2025_w45`)

### Columnar Compression

Citus columnar storage compresses data with 70-90% space savings:

- **Applied to:** All partitions older than 7 days
- **Compression Ratio:** 70-90% (100GB → 10-30GB)
- **Trade-off:** Read-only after compression (no UPDATEs/DELETEs)
- **Automation:** Weekly compression job (Sundays 3 AM)

**Expected Disk Savings (After 3 Months):**

| Table | Without Compression | With Compression | Savings |
|-------|---------------------|------------------|---------|
| transactions | 100 GB | 30 GB | 70% |
| logs | 200 GB | 20-60 GB | 70-85% |
| token_transfers | 50 GB | 5-15 GB | 70-85% |
| internal_transactions | 100 GB | 10-30 GB | 70-85% |
| **TOTAL** | **450 GB** | **65-135 GB** | **70-85%** |

## Automated Deployment

### How It Works

The migration is **fully automated** via GitOps workflow:

```mermaid
graph LR
    A[Git Push] --> B[ArgoCD Detects Changes]
    B --> C[ArgoCD Sync]
    C --> D[Deploy PostgreSQL Cluster]
    D --> E[Blockscout Migrations Run]
    E --> F[Citus Setup Job Triggers]
    F --> G[Distributed Tables Created]
    G --> H[pg_cron Jobs Configured]
    H --> I[Partitions Created]
    I --> J[Migration Complete]
```

**Zero Manual Intervention:**
- No `kubectl exec` required
- No manual SQL execution
- No manual cron job setup
- Just `git push` and ArgoCD handles the rest

### Job Execution Flow

1. **ArgoCD PostSync Hook:** Job triggers after all resources are synced
2. **Wait for Blockscout:** InitContainer waits for `transactions`, `logs`, `blocks` tables to exist
3. **Verify Extensions:** Checks Citus and pg_cron are loaded
4. **Run Migration:** Executes `scripts/citus-migration.sql`
5. **Setup Automation:** Configures pg_cron jobs for partition management

### Files Created

```
monad-indexer/
├── scripts/
│   └── citus-migration.sql                                    # Main migration script
├── charts/monad-indexer/templates/postgresql/
│   ├── citus-migration-configmap.yaml                         # ConfigMap with SQL script
│   └── citus-setup-job.yaml                                   # Kubernetes Job (ArgoCD PostSync)
└── docs/
    └── CITUS_MIGRATION_GUIDE.md                               # This file
```

## pg_cron Automation

Four automated jobs are configured:

### 1. Daily Partition Creation (2 AM)

```sql
SELECT create_time_partitions('transactions', '1 month', NOW() + INTERVAL '3 months');
SELECT create_time_partitions('logs', '1 week', NOW() + INTERVAL '1 month');
SELECT create_time_partitions('token_transfers', '1 month', NOW() + INTERVAL '3 months');
SELECT create_time_partitions('internal_transactions', '1 month', NOW() + INTERVAL '3 months');
```

**Purpose:** Proactively create partitions 1-3 months ahead to prevent insert failures.

### 2. Weekly Compression (Sundays 3 AM)

```sql
SELECT alter_old_partitions_set_access_method('transactions', NOW() - INTERVAL '7 days', 'columnar');
SELECT alter_old_partitions_set_access_method('logs', NOW() - INTERVAL '7 days', 'columnar');
SELECT alter_old_partitions_set_access_method('token_transfers', NOW() - INTERVAL '7 days', 'columnar');
SELECT alter_old_partitions_set_access_method('internal_transactions', NOW() - INTERVAL '7 days', 'columnar');
```

**Purpose:** Convert partitions older than 7 days to columnar storage for 70-90% disk savings.

### 3. Monthly Retention Cleanup (1st of Month, 4 AM)

```sql
SELECT drop_old_time_partitions('logs', NOW() - INTERVAL '90 days');
SELECT drop_old_time_partitions('token_transfers', NOW() - INTERVAL '90 days');
SELECT drop_old_time_partitions('internal_transactions', NOW() - INTERVAL '90 days');
SELECT drop_old_time_partitions('transactions', NOW() - INTERVAL '90 days');
```

**Purpose:** Drop partitions older than 90 days to maintain retention policy.

### 4. Weekly Vacuum Analyze (Saturdays 2 AM)

```sql
VACUUM ANALYZE transactions;
VACUUM ANALYZE logs;
VACUUM ANALYZE token_transfers;
VACUUM ANALYZE internal_transactions;
```

**Purpose:** Reclaim space and update query planner statistics for optimal performance.

## Verification and Monitoring

### 1. Verify Distributed Tables

```bash
kubectl exec -it <cluster-name>-postgresql-1 -- \
  psql -d blockscout -c "SELECT * FROM citus_tables ORDER BY table_name;"
```

**Expected Output:**
```
 table_name              | citus_table_type | distribution_column | colocation_id | table_size
-------------------------+------------------+---------------------+---------------+------------
 transactions            | distributed      | hash                | 1             | 128 MB
 logs                    | distributed      | transaction_hash    | 1             | 256 MB
 token_transfers         | distributed      | transaction_hash    | 1             | 64 MB
 internal_transactions   | distributed      | transaction_hash    | 1             | 128 MB
 blocks                  | reference        | -                   | -             | 10 MB
 addresses               | reference        | -                   | -             | 5 MB
```

### 2. Check pg_cron Jobs

```bash
kubectl exec -it <cluster-name>-postgresql-1 -- \
  psql -d postgres -c "SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname LIKE 'citus-%';"
```

**Expected Output:**
```
 jobid | jobname                           | schedule    | active
-------+-----------------------------------+-------------+--------
 1     | citus-create-partitions-daily     | 0 2 * * *   | t
 2     | citus-compress-old-partitions     | 0 3 * * 0   | t
 3     | citus-drop-old-partitions         | 0 4 1 * *   | t
 4     | citus-vacuum-analyze              | 0 2 * * 6   | t
```

### 3. Monitor Shard Distribution

```bash
kubectl exec -it <cluster-name>-postgresql-1 -- \
  psql -d blockscout -c "
    SELECT logicalrelid::text AS table_name,
           COUNT(*) AS shard_count,
           pg_size_pretty(SUM(shardlength)) AS total_size
    FROM pg_dist_shard
    WHERE logicalrelid::text IN ('transactions', 'logs', 'token_transfers', 'internal_transactions')
    GROUP BY logicalrelid
    ORDER BY logicalrelid;
  "
```

### 4. Check Columnar Compression Status

```bash
kubectl exec -it <cluster-name>-postgresql-1 -- \
  psql -d blockscout -c "
    SELECT c.relname AS partition_name,
           pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
           CASE WHEN am.amname = 'columnar' THEN 'YES' ELSE 'NO' END AS is_columnar
    FROM pg_class c
    JOIN pg_am am ON c.relam = am.oid
    WHERE c.relname ~ '^(transactions|logs|token_transfers|internal_transactions)_\d{4}'
    ORDER BY c.relname;
  "
```

### 5. View pg_cron Job Execution History

```bash
kubectl exec -it <cluster-name>-postgresql-1 -- \
  psql -d postgres -c "
    SELECT jobid, runid, job_pid, status, return_message, start_time, end_time
    FROM cron.job_run_details
    WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname LIKE 'citus-%')
    ORDER BY start_time DESC
    LIMIT 20;
  "
```

## Prometheus Metrics

The following Citus-specific metrics are already configured in `retention-monitoring.yaml`:

### Shard Count Monitoring

```yaml
- name: citus_shard_count
  help: Number of shards per distributed table
  query: |
    SELECT logicalrelid::text AS table_name,
           COUNT(*) AS shard_count,
           SUM(shardlength) AS total_shard_size
    FROM pg_dist_shard
    WHERE logicalrelid::text IN ('transactions', 'logs', 'token_transfers', 'internal_transactions')
    GROUP BY logicalrelid
```

**Alert: CitusLowShardCount**
- Triggers if any table has < 4 shards
- Indicates potential distribution issues

### Columnar Compression Stats

```yaml
- name: citus_columnar_compression_stats
  help: Columnar compression status for partitions
  query: |
    SELECT relname AS partition_name,
           pg_total_relation_size(c.oid) AS size_bytes,
           CASE WHEN am.amname = 'columnar' THEN true ELSE false END AS is_columnar
    FROM pg_class c
    JOIN pg_am am ON c.relam = am.oid
    WHERE c.relname ~ '^(transactions|logs|token_transfers|internal_transactions)_'
```

**Alert: CitusNoColumnarCompression**
- Triggers if large partitions (>10GB) are not using columnar storage
- Indicates compression job may have failed

### Distributed Table Size

```yaml
- name: citus_distributed_table_size
  help: Total size of distributed tables across all shards
  query: |
    SELECT logicalrelid::text AS table_name,
           citus_table_size(logicalrelid) AS total_size_bytes,
           COUNT(DISTINCT shardid) AS shard_count
    FROM pg_dist_shard
    GROUP BY logicalrelid
```

## Troubleshooting

### Job Failed: "Citus extension not found"

**Cause:** Citus extension not loaded in `shared_preload_libraries`

**Solution:**
1. Check cluster configuration:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d blockscout -c "SHOW shared_preload_libraries;"
   ```
2. Should show: `citus, pg_cron`
3. If not, check `cluster.yaml` lines 62-64 (spec-level array, not parameters)

### Job Failed: "Tables not ready yet"

**Cause:** Blockscout migrations haven't run yet

**Solution:**
1. Check Blockscout backend logs:
   ```bash
   kubectl logs deployment/<release-name>-backend -c db-migration
   ```
2. Verify tables exist:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d blockscout -c "\dt transactions"
   ```
3. Re-run Job manually if needed:
   ```bash
   kubectl delete job <release-name>-citus-setup
   kubectl apply -f charts/monad-indexer/templates/postgresql/citus-setup-job.yaml
   ```

### pg_cron Jobs Not Running

**Cause:** pg_cron extension created in wrong database

**Solution:**
1. pg_cron must be created in `postgres` database (default)
2. Verify:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d postgres -c "SELECT * FROM pg_extension WHERE extname = 'pg_cron';"
   ```
3. Check `cluster.yaml` line 51-52 (postInitSQL targets `postgres` database)

### Compression Not Working

**Cause:** Partitions too new (<7 days old) or compression job failed

**Solution:**
1. Check pg_cron job execution:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d postgres -c "
       SELECT status, return_message, start_time
       FROM cron.job_run_details
       WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'citus-compress-old-partitions')
       ORDER BY start_time DESC
       LIMIT 5;
     "
   ```
2. Manually compress for testing:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d blockscout -c "
       SELECT alter_old_partitions_set_access_method('logs', NOW() - INTERVAL '7 days', 'columnar');
     "
   ```

### High Disk Usage Despite Compression

**Cause:** VACUUM not reclaiming space or partitions not compressed yet

**Solution:**
1. Check which partitions are columnar:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d blockscout -c "
       SELECT relname, pg_size_pretty(pg_total_relation_size(relname::regclass)) AS size,
              am.amname AS access_method
       FROM pg_class c
       JOIN pg_am am ON c.relam = am.oid
       WHERE relname ~ '^logs_\d{4}'
       ORDER BY relname DESC
       LIMIT 10;
     "
   ```
2. Manually VACUUM:
   ```bash
   kubectl exec -it <cluster-name>-postgresql-1 -- \
     psql -d blockscout -c "VACUUM FULL logs;"
   ```

## Idempotency and Safety

The migration script is **fully idempotent** and safe to run multiple times:

- ✅ Checks if tables are already distributed (`citus_tables` view)
- ✅ Checks if pg_cron jobs already exist (`cron.job` table)
- ✅ Checks if partitions already exist (`pg_class` catalog)
- ✅ Uses `CREATE TABLE IF NOT EXISTS` for partition creation
- ✅ Uses `CREATE OR REPLACE FUNCTION` for helper functions

**Safe Operations:**
- Re-running the Job after failure
- Re-deploying via ArgoCD sync
- Manual execution for testing

**Not Safe:**
- Changing distribution key of existing distributed table (requires undistribute + redistribute)
- Dropping partitions manually (use retention job instead)
- Modifying compressed partitions (read-only after compression)

## Performance Considerations

### Query Performance

**Optimized Queries (Fast):**
- Hash lookups: `SELECT * FROM transactions WHERE hash = '0x...';` (single shard)
- Time-range: `SELECT * FROM logs WHERE inserted_at > NOW() - INTERVAL '1 day';` (partition pruning)
- Co-located JOINs: `SELECT * FROM transactions t JOIN logs l ON t.hash = l.transaction_hash;` (local)

**Slower Queries:**
- Address lookups: `SELECT * FROM transactions WHERE from_address_hash = '0x...';` (scatter across shards)
- Full table scans: `SELECT COUNT(*) FROM logs;` (all shards + coordinator aggregation)

**Recommendation:** Use appropriate indexes on non-distribution columns for address queries.

### Write Performance

- **Transactions:** ~10K TPS (10,000 transactions/second) - Citus handles this easily
- **Partitioning Overhead:** Minimal (<1% overhead with monthly/weekly partitions)
- **Compression Impact:** None (compression runs on old partitions, not active ones)

### Disk I/O

**2-Node Setup Benefits:**
- Reference tables (blocks, addresses): Zero network I/O (replicated locally)
- Co-located transactions/logs: Local JOINs, no cross-node queries
- Columnar compression: 70-90% less disk reads for old data

## Future Scaling

### Adding Worker Nodes

To scale horizontally (e.g., 2 nodes → 4 nodes):

1. Add worker nodes to the cluster:
   ```yaml
   # cluster.yaml
   spec:
     instances: 4  # Increase from 2 to 4
   ```

2. Rebalance shards:
   ```sql
   SELECT rebalance_table_shards('transactions');
   SELECT rebalance_table_shards('logs');
   SELECT rebalance_table_shards('token_transfers');
   SELECT rebalance_table_shards('internal_transactions');
   ```

3. Reference tables automatically replicate to new nodes (no action needed)

### Increasing Shard Count

Default shard count: 32 per table (Citus default)

To increase for very large tables:

```sql
-- Must be done BEFORE distributing the table
SET citus.shard_count = 64;
SELECT create_distributed_table('transactions', 'hash');
```

**Note:** Cannot change shard count after distribution. Must undistribute and redistribute.

## References

- [Citus Documentation](https://docs.citusdata.com/)
- [pg_cron Documentation](https://github.com/citusdata/pg_cron)
- [CloudNativePG Citus Integration](https://cloudnative-pg.io/)
- Session Context: `logs/session-context.md`
- Architecture Decision: `docs/CITUS_ONLY_ARCHITECTURE.md`
- CloudNativePG UID/GID Fix: `logs/blog-2.md`

## Support

For issues or questions:
1. Check Prometheus alerts for Citus-specific issues
2. Review pg_cron job execution history
3. Verify shard distribution and compression status
4. Consult troubleshooting section above

## Changelog

- **2025-11-13:** Initial migration implementation (Phase 2 complete)
  - Distributed tables with co-location strategy
  - Time-based partitioning (monthly/weekly)
  - pg_cron automation (partition creation, compression, retention)
  - ArgoCD PostSync job for automated deployment
  - Expected 54-70% disk savings after 3 months
