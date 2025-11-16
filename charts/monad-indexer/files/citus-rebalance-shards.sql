-- Citus Shard Rebalancing Script
-- This script redistributes shards across worker nodes for load balancing
-- WARNING: This will cause downtime. Run during maintenance window.

\timing on

\echo '==========================================
\echo 'Citus Shard Rebalancing
\echo '==========================================

-- Step 1: Verify worker nodes are active
\echo ''
\echo 'Checking worker node status...'
SELECT nodeid, nodename, nodeport, isactive, noderole
FROM pg_dist_node
ORDER BY nodeid;

-- Verify health
\echo ''
\echo 'Checking cluster health...'
SELECT * FROM citus_check_cluster_node_health();

-- Step 2: Check current shard distribution BEFORE rebalancing
\echo ''
\echo '========== BEFORE REBALANCING ==========
\echo 'Current shard distribution per node:'
SELECT
    nodename,
    count(*) as shard_count,
    pg_size_pretty(sum(shard_size)) as total_size
FROM pg_dist_shard_placement
JOIN pg_dist_shard USING (shardid)
GROUP BY nodename
ORDER BY nodename;

\echo ''
\echo 'Shard distribution per table:'
SELECT
    logicalrelid::text as table_name,
    nodename,
    count(*) as shard_count,
    pg_size_pretty(sum(shard_size)) as total_size
FROM pg_dist_shard_placement
JOIN pg_dist_shard USING (shardid)
GROUP BY logicalrelid, nodename
ORDER BY logicalrelid, nodename;

-- Step 3: Rebalance distributed tables
-- Using 'block_writes' mode which blocks writes during shard movement (safest)
-- Alternative: 'force_logical' for zero-downtime (more complex)

\echo ''
\echo '========== STARTING REBALANCING ==========

\echo ''
\echo 'Rebalancing transactions table...'
SELECT rebalance_table_shards(
    'transactions',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing logs table...'
SELECT rebalance_table_shards(
    'logs',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing token_transfers table...'
SELECT rebalance_table_shards(
    'token_transfers',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing internal_transactions table...'
SELECT rebalance_table_shards(
    'internal_transactions',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing address_coin_balances table...'
SELECT rebalance_table_shards(
    'address_coin_balances',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing address_token_balances table...'
SELECT rebalance_table_shards(
    'address_token_balances',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing address_current_token_balances table...'
SELECT rebalance_table_shards(
    'address_current_token_balances',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing token_instances table...'
SELECT rebalance_table_shards(
    'token_instances',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

\echo ''
\echo 'Rebalancing block_rewards table...'
SELECT rebalance_table_shards(
    'block_rewards',
    shard_transfer_mode => 'block_writes',
    drain_only => false,
    rebalance_strategy => 'by_disk_size'
);

-- Step 4: Check shard distribution AFTER rebalancing
\echo ''
\echo '========== AFTER REBALANCING ==========
\echo 'Final shard distribution per node:'
SELECT
    nodename,
    count(*) as shard_count,
    pg_size_pretty(sum(shard_size)) as total_size
FROM pg_dist_shard_placement
JOIN pg_dist_shard USING (shardid)
GROUP BY nodename
ORDER BY nodename;

\echo ''
\echo 'Final shard distribution per table:'
SELECT
    logicalrelid::text as table_name,
    nodename,
    count(*) as shard_count,
    pg_size_pretty(sum(shard_size)) as total_size
FROM pg_dist_shard_placement
JOIN pg_dist_shard USING (shardid)
GROUP BY logicalrelid, nodename
ORDER BY logicalrelid, nodename;

-- Step 5: Update table statistics
\echo ''
\echo 'Updating table statistics...'
ANALYZE transactions;
ANALYZE logs;
ANALYZE token_transfers;
ANALYZE internal_transactions;
ANALYZE address_coin_balances;
ANALYZE address_token_balances;
ANALYZE address_current_token_balances;
ANALYZE token_instances;
ANALYZE block_rewards;

-- Step 6: Verify shard placement health
\echo ''
\echo 'Checking shard placement health...'
SELECT
    shardid,
    logicalrelid::text as table_name,
    count(*) as placement_count,
    array_agg(nodename) as nodes
FROM pg_dist_shard_placement
JOIN pg_dist_shard USING (shardid)
GROUP BY shardid, logicalrelid
HAVING count(*) != 1  -- Should be 1 for replication_factor=1
ORDER BY shardid;

\echo ''
\echo '==========================================
\echo 'Shard rebalancing complete!
\echo 'You can now restart backend and indexer services.
\echo '==========================================
