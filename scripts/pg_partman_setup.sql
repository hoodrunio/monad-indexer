-- ===================================================================
-- PG_PARTMAN PARTITION SETUP SCRIPT
-- ===================================================================
-- This script converts existing Blockscout tables to partitioned tables
-- for efficient time-based data retention.
--
-- PREREQUISITES:
-- 1. pg_partman extension installed (via Cluster manifest)
-- 2. Background worker running (check pg_stat_activity)
-- 3. Full database backup completed
--
-- EXECUTION:
-- kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
--   psql -U postgres -d blockscout -f /tmp/pg_partman_setup.sql
--
-- DURATION: 2-4 hours (partition creation + initial setup)
-- ===================================================================

\set ON_ERROR_STOP on
\timing on

-- Verify pg_partman is installed
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        RAISE EXCEPTION 'pg_partman extension not installed!';
    END IF;
    RAISE NOTICE 'pg_partman extension found';
END $$;

-- ===================================================================
-- STEP 1: BACKUP FOREIGN KEY CONSTRAINTS (for documentation)
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'STEP 1: Backing up Foreign Key Constraints'
\echo '=================================================='

CREATE TEMP TABLE fk_backup AS
SELECT
    conname AS constraint_name,
    conrelid::regclass AS table_name,
    pg_get_constraintdef(oid) AS constraint_definition
FROM pg_constraint
WHERE contype = 'f'
  AND conrelid::regclass::text IN (
    'transactions',
    'logs',
    'token_transfers',
    'internal_transactions'
  );

\echo 'Foreign keys backed up:'
SELECT * FROM fk_backup;

-- ===================================================================
-- STEP 2: DROP FOREIGN KEY CONSTRAINTS
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'STEP 2: Dropping Foreign Key Constraints'
\echo 'WARNING: Referential integrity now managed by application'
\echo '=================================================='

-- Drop FKs from transactions
DO $$
DECLARE
    fk_record RECORD;
BEGIN
    FOR fk_record IN
        SELECT conname
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = 'transactions'::regclass
    LOOP
        EXECUTE 'ALTER TABLE transactions DROP CONSTRAINT IF EXISTS ' || fk_record.conname || ' CASCADE';
        RAISE NOTICE 'Dropped FK: %', fk_record.conname;
    END LOOP;
END $$;

-- Drop FKs from logs
DO $$
DECLARE
    fk_record RECORD;
BEGIN
    FOR fk_record IN
        SELECT conname
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = 'logs'::regclass
    LOOP
        EXECUTE 'ALTER TABLE logs DROP CONSTRAINT IF EXISTS ' || fk_record.conname || ' CASCADE';
        RAISE NOTICE 'Dropped FK: %', fk_record.conname;
    END LOOP;
END $$;

-- Drop FKs from token_transfers
DO $$
DECLARE
    fk_record RECORD;
BEGIN
    FOR fk_record IN
        SELECT conname
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = 'token_transfers'::regclass
    LOOP
        EXECUTE 'ALTER TABLE token_transfers DROP CONSTRAINT IF EXISTS ' || fk_record.conname || ' CASCADE';
        RAISE NOTICE 'Dropped FK: %', fk_record.conname;
    END LOOP;
END $$;

-- Drop FKs from internal_transactions
DO $$
DECLARE
    fk_record RECORD;
BEGIN
    FOR fk_record IN
        SELECT conname
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = 'internal_transactions'::regclass
    LOOP
        EXECUTE 'ALTER TABLE internal_transactions DROP CONSTRAINT IF EXISTS ' || fk_record.conname || ' CASCADE';
        RAISE NOTICE 'Dropped FK: %', fk_record.conname;
    END LOOP;
END $$;

\echo 'Foreign keys dropped successfully'

-- ===================================================================
-- STEP 3: CREATE PARTITIONED TABLES
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'STEP 3: Creating Partitioned Tables'
\echo 'This will create empty partitioned versions of tables'
\echo '=================================================='

-- -------------------------------------------------------------------
-- 3.1 BLOCKS TABLE
-- -------------------------------------------------------------------

\echo 'Creating blocks_partitioned...'

CREATE TABLE IF NOT EXISTS blocks_partitioned (
    LIKE blocks INCLUDING ALL EXCLUDING INDEXES EXCLUDING CONSTRAINTS
) PARTITION BY RANGE (inserted_at);

-- Copy primary key and unique constraints
ALTER TABLE blocks_partitioned ADD PRIMARY KEY (hash, inserted_at);

-- Recreate indexes (will be inherited by partitions)
CREATE INDEX IF NOT EXISTS blocks_partitioned_number_idx ON blocks_partitioned (number);
CREATE INDEX IF NOT EXISTS blocks_partitioned_timestamp_idx ON blocks_partitioned (timestamp);
CREATE INDEX IF NOT EXISTS blocks_partitioned_inserted_at_idx ON blocks_partitioned (inserted_at);
CREATE INDEX IF NOT EXISTS blocks_partitioned_consensus_idx ON blocks_partitioned (consensus);
CREATE INDEX IF NOT EXISTS blocks_partitioned_miner_hash_idx ON blocks_partitioned (miner_hash);

-- -------------------------------------------------------------------
-- 3.2 TRANSACTIONS TABLE
-- -------------------------------------------------------------------

\echo 'Creating transactions_partitioned...'

CREATE TABLE IF NOT EXISTS transactions_partitioned (
    LIKE transactions INCLUDING ALL EXCLUDING INDEXES EXCLUDING CONSTRAINTS
) PARTITION BY RANGE (inserted_at);

-- Copy primary key
ALTER TABLE transactions_partitioned ADD PRIMARY KEY (hash, inserted_at);

-- Recreate indexes
CREATE INDEX IF NOT EXISTS transactions_partitioned_block_hash_idx ON transactions_partitioned (block_hash, inserted_at);
CREATE INDEX IF NOT EXISTS transactions_partitioned_from_address_hash_idx ON transactions_partitioned (from_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS transactions_partitioned_to_address_hash_idx ON transactions_partitioned (to_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS transactions_partitioned_inserted_at_idx ON transactions_partitioned (inserted_at);
CREATE INDEX IF NOT EXISTS transactions_partitioned_nonce_idx ON transactions_partitioned (from_address_hash, nonce);

-- -------------------------------------------------------------------
-- 3.3 LOGS TABLE
-- -------------------------------------------------------------------

\echo 'Creating logs_partitioned...'

CREATE TABLE IF NOT EXISTS logs_partitioned (
    LIKE logs INCLUDING ALL EXCLUDING INDEXES EXCLUDING CONSTRAINTS
) PARTITION BY RANGE (inserted_at);

-- Copy primary key (logs may have composite key)
-- Note: Adjust based on actual schema
ALTER TABLE logs_partitioned ADD PRIMARY KEY (transaction_hash, block_hash, index, inserted_at);

-- Recreate indexes
CREATE INDEX IF NOT EXISTS logs_partitioned_transaction_hash_idx ON logs_partitioned (transaction_hash, inserted_at);
CREATE INDEX IF NOT EXISTS logs_partitioned_address_hash_idx ON logs_partitioned (address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS logs_partitioned_first_topic_idx ON logs_partitioned (first_topic);
CREATE INDEX IF NOT EXISTS logs_partitioned_second_topic_idx ON logs_partitioned (second_topic);
CREATE INDEX IF NOT EXISTS logs_partitioned_third_topic_idx ON logs_partitioned (third_topic);
CREATE INDEX IF NOT EXISTS logs_partitioned_fourth_topic_idx ON logs_partitioned (fourth_topic);
CREATE INDEX IF NOT EXISTS logs_partitioned_inserted_at_idx ON logs_partitioned (inserted_at);

-- -------------------------------------------------------------------
-- 3.4 TOKEN_TRANSFERS TABLE
-- -------------------------------------------------------------------

\echo 'Creating token_transfers_partitioned...'

CREATE TABLE IF NOT EXISTS token_transfers_partitioned (
    LIKE token_transfers INCLUDING ALL EXCLUDING INDEXES EXCLUDING CONSTRAINTS
) PARTITION BY RANGE (inserted_at);

-- Copy primary key
ALTER TABLE token_transfers_partitioned ADD PRIMARY KEY (transaction_hash, block_hash, log_index, inserted_at);

-- Recreate indexes
CREATE INDEX IF NOT EXISTS token_transfers_partitioned_transaction_hash_idx ON token_transfers_partitioned (transaction_hash, inserted_at);
CREATE INDEX IF NOT EXISTS token_transfers_partitioned_token_contract_address_hash_idx ON token_transfers_partitioned (token_contract_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS token_transfers_partitioned_from_address_hash_idx ON token_transfers_partitioned (from_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS token_transfers_partitioned_to_address_hash_idx ON token_transfers_partitioned (to_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS token_transfers_partitioned_inserted_at_idx ON token_transfers_partitioned (inserted_at);

-- -------------------------------------------------------------------
-- 3.5 INTERNAL_TRANSACTIONS TABLE
-- -------------------------------------------------------------------

\echo 'Creating internal_transactions_partitioned...'

CREATE TABLE IF NOT EXISTS internal_transactions_partitioned (
    LIKE internal_transactions INCLUDING ALL EXCLUDING INDEXES EXCLUDING CONSTRAINTS
) PARTITION BY RANGE (inserted_at);

-- Copy primary key
ALTER TABLE internal_transactions_partitioned ADD PRIMARY KEY (transaction_hash, index, inserted_at);

-- Recreate indexes
CREATE INDEX IF NOT EXISTS internal_transactions_partitioned_transaction_hash_idx ON internal_transactions_partitioned (transaction_hash, inserted_at);
CREATE INDEX IF NOT EXISTS internal_transactions_partitioned_from_address_hash_idx ON internal_transactions_partitioned (from_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS internal_transactions_partitioned_to_address_hash_idx ON internal_transactions_partitioned (to_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS internal_transactions_partitioned_created_contract_address_hash_idx ON internal_transactions_partitioned (created_contract_address_hash, inserted_at);
CREATE INDEX IF NOT EXISTS internal_transactions_partitioned_inserted_at_idx ON internal_transactions_partitioned (inserted_at);

\echo 'Partitioned tables created successfully'

-- ===================================================================
-- STEP 4: REGISTER WITH PG_PARTMAN
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'STEP 4: Registering Tables with pg_partman'
\echo '=================================================='

-- -------------------------------------------------------------------
-- 4.1 BLOCKS
-- -------------------------------------------------------------------

\echo 'Registering blocks_partitioned with pg_partman...'

SELECT partman.create_parent(
    p_parent_table := 'public.blocks_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 7,  -- Create 7 days of partitions ahead
    p_start_partition := (
        SELECT COALESCE(MIN(inserted_at), NOW())::text
        FROM blocks
    )
);

-- Configure retention (30 days)
UPDATE partman.part_config
SET retention = '90 days',  -- Conservative start (will reduce to 30 later)
    retention_keep_table = false,  -- Drop partitions completely
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.blocks_partitioned';

-- -------------------------------------------------------------------
-- 4.2 TRANSACTIONS
-- -------------------------------------------------------------------

\echo 'Registering transactions_partitioned with pg_partman...'

SELECT partman.create_parent(
    p_parent_table := 'public.transactions_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 7,
    p_start_partition := (
        SELECT COALESCE(MIN(inserted_at), NOW())::text
        FROM transactions
    )
);

UPDATE partman.part_config
SET retention = '90 days',
    retention_keep_table = false,
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.transactions_partitioned';

-- -------------------------------------------------------------------
-- 4.3 LOGS
-- -------------------------------------------------------------------

\echo 'Registering logs_partitioned with pg_partman...'

SELECT partman.create_parent(
    p_parent_table := 'public.logs_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 7,
    p_start_partition := (
        SELECT COALESCE(MIN(inserted_at), NOW())::text
        FROM logs
    )
);

UPDATE partman.part_config
SET retention = '90 days',
    retention_keep_table = false,
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.logs_partitioned';

-- -------------------------------------------------------------------
-- 4.4 TOKEN_TRANSFERS
-- -------------------------------------------------------------------

\echo 'Registering token_transfers_partitioned with pg_partman...'

SELECT partman.create_parent(
    p_parent_table := 'public.token_transfers_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 7,
    p_start_partition := (
        SELECT COALESCE(MIN(inserted_at), NOW())::text
        FROM token_transfers
    )
);

UPDATE partman.part_config
SET retention = '90 days',
    retention_keep_table = false,
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.token_transfers_partitioned';

-- -------------------------------------------------------------------
-- 4.5 INTERNAL_TRANSACTIONS
-- -------------------------------------------------------------------

\echo 'Registering internal_transactions_partitioned with pg_partman...'

SELECT partman.create_parent(
    p_parent_table := 'public.internal_transactions_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 7,
    p_start_partition := (
        SELECT COALESCE(MIN(inserted_at), NOW())::text
        FROM internal_transactions
    )
);

UPDATE partman.part_config
SET retention = '90 days',
    retention_keep_table = false,
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.internal_transactions_partitioned';

-- ===================================================================
-- STEP 5: VERIFY SETUP
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'STEP 5: Verification'
\echo '=================================================='

-- Check partman configuration
\echo 'pg_partman configuration:'
SELECT
    parent_table,
    partition_type,
    partition_interval,
    premake,
    retention,
    retention_keep_table
FROM partman.part_config
ORDER BY parent_table;

-- Check created partitions
\echo ''
\echo 'Created partitions:'
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE '%_partitioned_%'
  AND schemaname = 'public'
ORDER BY tablename
LIMIT 20;

-- Check partition count
\echo ''
\echo 'Partition counts:'
SELECT
    pc.parent_table,
    COUNT(*) AS partition_count
FROM partman.part_config pc
JOIN pg_inherits i ON i.inhparent = pc.parent_table::regclass
GROUP BY pc.parent_table
ORDER BY pc.parent_table;

-- ===================================================================
-- COMPLETION
-- ===================================================================

\echo ''
\echo '=================================================='
\echo 'SETUP COMPLETE!'
\echo '=================================================='
\echo ''
\echo 'Next Steps:'
\echo '1. Run migration job to copy historical data'
\echo '2. Test queries on *_partitioned tables'
\echo '3. Verify partition pruning with EXPLAIN ANALYZE'
\echo '4. Schedule table swap during maintenance window'
\echo ''
\echo 'Monitor background worker:'
\echo '  SELECT * FROM pg_stat_activity WHERE backend_type = ''pg_partman_bgw'';'
\echo ''
\echo 'Manual maintenance (if needed):'
\echo '  SELECT partman.run_maintenance();'
\echo '=================================================='
