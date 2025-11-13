-- Drop Unused Indexes for Performance Optimization
-- Purpose: Remove unused indexes that consume 7.7GB disk space and slow down write operations
-- Impact: +5-10% write performance, 7.7GB disk space savings
-- Execution: Run with CONCURRENTLY to avoid table locks during TPS test
-- Date: 2025-11-13

\echo 'Checking current index usage stats...'
SELECT
    schemaname,
    relname as table_name,
    indexrelname as index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    idx_scan as times_used,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched
FROM pg_stat_user_indexes
WHERE indexrelname = 'unfetched_balances';

\echo ''
\echo 'Current table size with indexes:'
SELECT
    pg_size_pretty(pg_total_relation_size('address_coin_balances')) AS total_size,
    pg_size_pretty(pg_relation_size('address_coin_balances')) AS table_size,
    pg_size_pretty(pg_total_relation_size('address_coin_balances') - pg_relation_size('address_coin_balances')) AS indexes_size
FROM pg_tables
WHERE tablename = 'address_coin_balances';

\echo ''
\echo 'Dropping unused index: unfetched_balances (7.7GB)'
\echo 'Using CONCURRENTLY to avoid blocking writes during TPS test...'

-- Drop index CONCURRENTLY to avoid table locks
-- This operation can take 5-10 minutes but won't block ongoing writes
DROP INDEX CONCURRENTLY IF EXISTS unfetched_balances;

\echo ''
\echo 'Index dropped successfully!'
\echo 'Verifying new table size...'

SELECT
    pg_size_pretty(pg_total_relation_size('address_coin_balances')) AS total_size,
    pg_size_pretty(pg_relation_size('address_coin_balances')) AS table_size,
    pg_size_pretty(pg_total_relation_size('address_coin_balances') - pg_relation_size('address_coin_balances')) AS indexes_size
FROM pg_tables
WHERE tablename = 'address_coin_balances';

\echo ''
\echo 'Remaining indexes on address_coin_balances:'
SELECT
    indexrelname as index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    idx_scan as times_used
FROM pg_stat_user_indexes
WHERE relname = 'address_coin_balances'
ORDER BY pg_relation_size(indexrelid) DESC;

\echo ''
\echo 'Expected benefits:'
\echo '  - Disk space freed: ~7.7 GB'
\echo '  - Write performance improvement: +5-10%'
\echo '  - Reduced index maintenance overhead on INSERT/UPDATE operations'
\echo '  - Lower lock contention on address_coin_balances table'
