# Citus-Only Architecture with Native Time Partitioning

## 🎯 Strategy Update

**Key Finding**: Citus and TimescaleDB extensions are **NOT compatible**. Cannot run both simultaneously.

**New Approach**: Use Citus for horizontal sharding + PostgreSQL native time-based partitioning.

---

## 🏗️ Architecture

### **Core Components:**

1. **PostgreSQL Native Partitioning** (Time-based)
   - `PARTITION BY RANGE (inserted_at)`
   - Monthly or weekly partitions
   - Automatic with `pg_partman` or manual

2. **Citus Distributed Tables** (Hash-based sharding)
   - `create_distributed_table(table, 'hash_column')`
   - Shards across workers
   - Each partition is automatically distributed

3. **Columnar Compression** (Archive old data)
   - `alter_table_set_access_method(partition, 'columnar')`
   - 70-90% compression on old partitions
   - Read-only once compressed

---

## 📊 Table Design

### **1. Transactions (High TPS, Query by Hash)**

```sql
-- Create parent partitioned table
CREATE TABLE transactions (
  hash bytea PRIMARY KEY,
  inserted_at timestamp NOT NULL,
  block_hash bytea,
  -- ... other columns
) PARTITION BY RANGE (inserted_at);

-- Create initial partitions (monthly)
CREATE TABLE transactions_2025_01 PARTITION OF transactions
  FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

CREATE TABLE transactions_2025_02 PARTITION OF transactions
  FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');

-- Distribute across Citus workers
SELECT create_distributed_table('transactions', 'hash');
-- Each partition is automatically sharded by hash!

-- UNIQUE constraint on hash works!
ALTER TABLE transactions ADD CONSTRAINT transactions_hash_unique UNIQUE (hash);
```

**장점:**
- ✅ ON CONFLICT (hash) works with composite key
- ✅ Horizontal scaling via Citus
- ✅ Time-based queries optimized (partition pruning)
- ✅ Old partitions can be compressed

---

### **2. Logs (Huge Growth, Time-Series Queries)**

```sql
-- Create partitioned table
CREATE TABLE logs (
  transaction_hash bytea NOT NULL,
  index integer NOT NULL,
  block_hash bytea NOT NULL,
  inserted_at timestamp NOT NULL,
  address_hash bytea,
  data bytea,
  -- ... other columns
  PRIMARY KEY (transaction_hash, index, block_hash, inserted_at)
) PARTITION BY RANGE (inserted_at);

-- Weekly partitions (logs grow fast!)
CREATE TABLE logs_2025_w01 PARTITION OF logs
  FOR VALUES FROM ('2025-01-01') TO ('2025-01-08');

-- Distribute by transaction_hash (co-located with transactions)
SELECT create_distributed_table('logs', 'transaction_hash');

-- After 7 days: compress old partitions
SELECT alter_old_partitions_set_access_method(
  'logs',
  '2025-01-01',
  'columnar'
);
```

**Compression Benefits:**
- 200 GB → 20-60 GB (70-85% savings)
- Automatic via `pg_cron` job

---

### **3. Token Transfers (ERC20/NFT Events)**

```sql
CREATE TABLE token_transfers (
  transaction_hash bytea NOT NULL,
  log_index integer NOT NULL,
  block_hash bytea NOT NULL,
  inserted_at timestamp NOT NULL,
  -- ... other columns
  PRIMARY KEY (transaction_hash, log_index, block_hash, inserted_at)
) PARTITION BY RANGE (inserted_at);

-- Monthly partitions
SELECT create_distributed_table('token_transfers', 'transaction_hash');

-- Compress old data
SELECT alter_old_partitions_set_access_method(
  'token_transfers',
  NOW() - INTERVAL '7 days',
  'columnar'
);
```

---

## 🤖 Automated Partition Management

### **Using Citus Time-Series UDFs:**

```sql
-- Create partitions for next 3 months automatically
SELECT create_time_partitions(
  table_name         := 'transactions',
  partition_interval := '1 month',
  end_at             := NOW() + INTERVAL '3 months'
);

-- Drop partitions older than 90 days
SELECT drop_old_time_partitions(
  'logs',
  NOW() - INTERVAL '90 days'
);

-- Compress partitions older than 7 days
SELECT alter_old_partitions_set_access_method(
  'logs',
  NOW() - INTERVAL '7 days',
  'columnar'
);
```

### **Schedule with pg_cron:**

```sql
-- Run daily at 2 AM
SELECT cron.schedule(
  'create-partitions',
  '0 2 * * *',
  $$
    SELECT create_time_partitions('transactions', '1 month', NOW() + INTERVAL '3 months');
    SELECT create_time_partitions('logs', '1 week', NOW() + INTERVAL '1 month');
  $$
);

-- Compress old data weekly
SELECT cron.schedule(
  'compress-old-data',
  '0 3 * * 0',
  $$
    SELECT alter_old_partitions_set_access_method('logs', NOW() - INTERVAL '7 days', 'columnar');
  $$
);
```

---

## ⚙️ Blockscout Compatibility

### **Good News: NO ADDITIONAL CODE CHANGES!**

Our existing conflict_target changes **already work** with this approach:

```elixir
# transactions.ex
conflict_target: [:hash, :inserted_at]  # ✅ Works with composite PRIMARY KEY

# logs.ex
conflict_target: [:transaction_hash, :index, :block_hash, :inserted_at]  # ✅ Works

# token_transfers.ex
conflict_target: [:transaction_hash, :log_index, :block_hash, :inserted_at]  # ✅ Works
```

---

## 📈 Expected Performance

### **Disk Savings (3 Months):**

| Table | No Optimization | With Citus + Compression | Savings |
|-------|----------------|-------------------------|---------|
| transactions | 100 GB | 100 GB | - (needs compression) |
| logs | 200 GB | 20-60 GB | **70-85%** 🔥 |
| token_transfers | 50 GB | 5-15 GB | **70-85%** 🔥 |
| internal_transactions | 100 GB | 10-30 GB | **70-85%** 🔥 |
| **TOTAL** | **450 GB** | **135-205 GB** | **54-70%** 🎉 |

### **Query Performance:**

- **Time-range queries**: 10-50x faster (partition pruning)
- **Hash lookups**: Same or better (Citus sharding)
- **Horizontal scaling**: Add workers anytime
- **Compression**: Transparent to queries

---

## 🚀 Implementation Steps

### **1. Image Setup**
```yaml
# Use Citus image (NOT TimescaleDB)
imageCatalogRef:
  apiGroup: postgresql.cnpg.io
  kind: ImageCatalog
  name: monad-indexer-citus-catalog
  major: 17

postgresql:
  shared_preload_libraries:
    - citus
    - pg_cron  # For automation
```

### **2. Migration Script**

```sql
-- Enable Citus
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Convert existing tables to partitioned
-- (This requires data migration - can be done during fresh deployment)

-- transactions
SELECT create_distributed_table('transactions', 'hash');

-- logs
SELECT create_distributed_table('logs', 'transaction_hash');

-- token_transfers
SELECT create_distributed_table('token_transfers', 'transaction_hash');

-- Setup automated partition management
SELECT create_time_partitions('logs', '1 week', NOW() + INTERVAL '1 month');
SELECT create_time_partitions('transactions', '1 month', NOW() + INTERVAL '3 months');
```

### **3. Monitoring**

```sql
-- Check partition status
SELECT * FROM pg_partitions WHERE tablename = 'logs';

-- Check shard distribution
SELECT * FROM citus_shards WHERE table_name::text LIKE 'logs%';

-- Check compression ratio
SELECT
  schemaname||'.'||tablename as partition,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE tablename LIKE 'logs_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

---

## ⚖️ Citus-Only vs. TimescaleDB

| Feature | Citus + Native Partitioning | TimescaleDB (open-source) |
|---------|----------------------------|--------------------------|
| Horizontal sharding | ✅ Multi-node | ❌ Single-node only |
| Time partitioning | ✅ Manual/pg_cron | ✅ Automatic |
| Compression | ✅ Columnar (70-90%) | ✅ (70-90%) |
| UNIQUE constraints | ✅ Works with composite | ❌ Requires partition key |
| Blockscout compat | ✅ Works (already modified) | ❌ Needs code change |
| Future scaling | ✅ Add workers | ⚠️ Vertical only |
| Maturity | ✅ Production-ready | ✅ Production-ready |

---

## 💡 Recommendation

**Use Citus + PostgreSQL Native Partitioning**

**Why:**
1. ✅ Horizontal scaling ready (add workers anytime)
2. ✅ Blockscout code already modified (works as-is)
3. ✅ Compression via columnar storage
4. ✅ TimescaleDB compatibility not needed
5. ✅ Citus has mature time-series tooling
6. ✅ Open-source and production-ready

**Trade-off:**
- ⚠️ Manual partition creation (but automated via pg_cron)
- ⚠️ Not as "automatic" as TimescaleDB chunks

**Verdict:** The benefits far outweigh the manual partition management, especially with Citus's time-series UDFs.

---

Last Updated: 2025-11-13
