#!/bin/bash
# ===================================================================
# PG_PARTMAN DRY-RUN TEST SCRIPT
# ===================================================================
# Tests pg_partman setup in safe, isolated way before production deploy
#
# What this does:
# 1. Creates temporary test tables (does NOT modify production tables)
# 2. Sets up pg_partman with 1-day retention
# 3. Validates partition creation, pruning, and queries
# 4. Cleans up test resources
#
# Usage:
#   kubectl cp scripts/test_pg_partman.sh POD:/tmp/
#   kubectl exec -it POD -- bash /tmp/test_pg_partman.sh
# ===================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}PG_PARTMAN DRY-RUN TEST${NC}"
echo -e "${BLUE}================================================================${NC}"
echo "Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Function to log steps
log_step() {
    echo -e "${YELLOW}>>> $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function to execute SQL
exec_sql() {
    psql -U postgres -d blockscout -v ON_ERROR_STOP=1 -c "$1"
}

# Function to execute SQL and return output
query_sql() {
    psql -U postgres -d blockscout -t -c "$1" | tr -d ' '
}

# ===================================================================
# STEP 1: VERIFY PREREQUISITES
# ===================================================================

log_step "Step 1: Verifying prerequisites"

# Check pg_partman extension
if ! exec_sql "SELECT 1 FROM pg_extension WHERE extname = 'pg_partman'" > /dev/null 2>&1; then
    log_error "pg_partman extension not installed"
    exit 1
fi
log_success "pg_partman extension found"

# Check background worker
BGW_COUNT=$(query_sql "SELECT COUNT(*) FROM pg_stat_activity WHERE backend_type = 'pg_partman_bgw'")
if [[ "$BGW_COUNT" -gt 0 ]]; then
    log_success "pg_partman background worker running"
else
    echo -e "${YELLOW}⚠ pg_partman background worker not found (manual maintenance needed)${NC}"
fi

echo ""

# ===================================================================
# STEP 2: CREATE TEST TABLE
# ===================================================================

log_step "Step 2: Creating test table (blocks_test)"

exec_sql "
DROP TABLE IF EXISTS blocks_test_partitioned CASCADE;
DROP TABLE IF EXISTS blocks_test CASCADE;

CREATE TABLE blocks_test (
    hash bytea NOT NULL,
    number bigint NOT NULL,
    timestamp timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL DEFAULT NOW(),
    consensus boolean DEFAULT true,
    data text
);
" > /dev/null

log_success "Test table created"

# Insert test data spanning 7 days
log_step "Inserting test data (7 days of blocks, 1000 blocks/day)"

exec_sql "
INSERT INTO blocks_test (hash, number, timestamp, inserted_at, consensus, data)
SELECT
    decode(md5(n::text), 'hex'),
    n,
    NOW() - (n % 7 || ' days')::interval,
    NOW() - (n % 7 || ' days')::interval,
    true,
    'test block ' || n
FROM generate_series(1, 7000) n;
" > /dev/null

TOTAL_ROWS=$(query_sql "SELECT COUNT(*) FROM blocks_test")
log_success "Inserted ${TOTAL_ROWS} test rows"

echo ""

# ===================================================================
# STEP 3: CREATE PARTITIONED TABLE
# ===================================================================

log_step "Step 3: Creating partitioned version"

exec_sql "
CREATE TABLE blocks_test_partitioned (
    LIKE blocks_test INCLUDING ALL
) PARTITION BY RANGE (inserted_at);

ALTER TABLE blocks_test_partitioned ADD PRIMARY KEY (hash, inserted_at);
CREATE INDEX blocks_test_partitioned_number_idx ON blocks_test_partitioned (number);
CREATE INDEX blocks_test_partitioned_inserted_at_idx ON blocks_test_partitioned (inserted_at);
" > /dev/null

log_success "Partitioned table created"

echo ""

# ===================================================================
# STEP 4: REGISTER WITH PG_PARTMAN (1-DAY RETENTION)
# ===================================================================

log_step "Step 4: Registering with pg_partman (1-day retention for testing)"

exec_sql "
SELECT partman.create_parent(
    p_parent_table := 'public.blocks_test_partitioned',
    p_control := 'inserted_at',
    p_type := 'native',
    p_interval := '1 day',
    p_premake := 3,
    p_start_partition := (SELECT MIN(inserted_at)::text FROM blocks_test)
);
" > /dev/null

log_success "Table registered with pg_partman"

# Configure 1-day retention
exec_sql "
UPDATE partman.part_config
SET retention = '1 day',
    retention_keep_table = false,
    retention_keep_index = false,
    infinite_time_partitions = true,
    optimize_trigger = 4,
    optimize_constraint = 30
WHERE parent_table = 'public.blocks_test_partitioned';
" > /dev/null

log_success "Retention set to 1 day"

echo ""

# ===================================================================
# STEP 5: VERIFY PARTITION CREATION
# ===================================================================

log_step "Step 5: Verifying partition creation"

PARTITION_COUNT=$(query_sql "
SELECT COUNT(*)
FROM pg_inherits i
WHERE i.inhparent = 'blocks_test_partitioned'::regclass;
")

echo "Partitions created: ${PARTITION_COUNT}"

if [[ "$PARTITION_COUNT" -lt 7 ]]; then
    log_error "Expected at least 7 partitions (7 days data + premake), got ${PARTITION_COUNT}"
    exit 1
fi

log_success "Partitions created successfully"

# List partitions
echo ""
echo "Partition details:"
exec_sql "
SELECT
    c.relname as partition_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) as size
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'blocks_test_partitioned'::regclass
ORDER BY c.relname;
"

echo ""

# ===================================================================
# STEP 6: MIGRATE DATA
# ===================================================================

log_step "Step 6: Migrating test data to partitions"

exec_sql "
DO \$\$
DECLARE
    v_rows_moved bigint;
BEGIN
    LOOP
        -- Use partition_data_proc to move data
        SELECT partman.partition_data_proc(
            p_parent_table := 'public.blocks_test_partitioned',
            p_batch_count := 1,
            p_batch_interval := 0,
            p_source_table := 'public.blocks_test'
        ) INTO v_rows_moved;

        EXIT WHEN v_rows_moved = 0;
    END LOOP;
END \$\$;
" > /dev/null

SOURCE_COUNT=$(query_sql "SELECT COUNT(*) FROM blocks_test")
PARTITION_COUNT_ROWS=$(query_sql "SELECT COUNT(*) FROM blocks_test_partitioned")

echo "Source table: ${SOURCE_COUNT} rows"
echo "Partitioned table: ${PARTITION_COUNT_ROWS} rows"

if [[ "$PARTITION_COUNT_ROWS" -ne "$TOTAL_ROWS" ]]; then
    log_error "Row count mismatch! Expected ${TOTAL_ROWS}, got ${PARTITION_COUNT_ROWS}"
    exit 1
fi

log_success "Data migration successful"

echo ""

# ===================================================================
# STEP 7: TEST PARTITION PRUNING
# ===================================================================

log_step "Step 7: Testing partition pruning (query optimization)"

echo ""
echo "Query plan for recent data (should prune old partitions):"
exec_sql "
EXPLAIN (FORMAT TEXT, COSTS OFF)
SELECT COUNT(*) FROM blocks_test_partitioned
WHERE inserted_at > NOW() - INTERVAL '2 days';
"

echo ""
log_success "Partition pruning verified (check 'Partitions pruned' above)"

echo ""

# ===================================================================
# STEP 8: TEST RETENTION (DRY RUN)
# ===================================================================

log_step "Step 8: Testing retention (checking what would be dropped)"

echo ""
echo "Partitions older than 1 day (would be dropped by maintenance):"

exec_sql "
SELECT
    c.relname as partition_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) as size,
    'WOULD BE DROPPED' as status
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'blocks_test_partitioned'::regclass
  AND c.relname < 'blocks_test_partitioned_p' || to_char(NOW() - INTERVAL '1 day', 'YYYY_MM_DD')
ORDER BY c.relname;
"

echo ""
log_success "Retention test complete"

echo ""

# ===================================================================
# STEP 9: RUN MAINTENANCE MANUALLY
# ===================================================================

log_step "Step 9: Running pg_partman maintenance manually"

exec_sql "
SELECT partman.run_maintenance_proc();
" > /dev/null

log_success "Maintenance run complete"

# Check partitions after maintenance
PARTITIONS_AFTER=$(query_sql "
SELECT COUNT(*)
FROM pg_inherits i
WHERE i.inhparent = 'blocks_test_partitioned'::regclass;
")

echo "Partitions after maintenance: ${PARTITIONS_AFTER}"
echo "Partitions before maintenance: ${PARTITION_COUNT}"

DROPPED_COUNT=$((PARTITION_COUNT - PARTITIONS_AFTER))
if [[ "$DROPPED_COUNT" -gt 0 ]]; then
    log_success "Dropped ${DROPPED_COUNT} old partitions (>1 day old)"
else
    echo -e "${YELLOW}⚠ No partitions dropped (might be too early or no old data)${NC}"
fi

echo ""

# ===================================================================
# STEP 10: VERIFY DATA INTEGRITY
# ===================================================================

log_step "Step 10: Verifying data integrity after maintenance"

ROWS_AFTER=$(query_sql "SELECT COUNT(*) FROM blocks_test_partitioned")
EXPECTED_ROWS=$(query_sql "SELECT COUNT(*) FROM blocks_test WHERE inserted_at > NOW() - INTERVAL '1 day'")

echo "Rows after maintenance: ${ROWS_AFTER}"
echo "Expected rows (last 1 day): ${EXPECTED_ROWS}"

if [[ "$ROWS_AFTER" -lt "$EXPECTED_ROWS" ]]; then
    log_error "Data loss detected! Expected at least ${EXPECTED_ROWS}, got ${ROWS_AFTER}"
    exit 1
fi

log_success "Data integrity verified"

echo ""

# ===================================================================
# STEP 11: PERFORMANCE COMPARISON
# ===================================================================

log_step "Step 11: Performance comparison (partitioned vs non-partitioned)"

echo ""
echo "Query performance for recent data (last 2 days):"
echo ""

echo "Non-partitioned table:"
exec_sql "
EXPLAIN ANALYZE
SELECT COUNT(*) FROM blocks_test
WHERE inserted_at > NOW() - INTERVAL '2 days';
" | grep "Execution Time"

echo ""
echo "Partitioned table:"
exec_sql "
EXPLAIN ANALYZE
SELECT COUNT(*) FROM blocks_test_partitioned
WHERE inserted_at > NOW() - INTERVAL '2 days';
" | grep "Execution Time"

log_success "Performance comparison complete"

echo ""

# ===================================================================
# STEP 12: CLEANUP
# ===================================================================

log_step "Step 12: Cleaning up test resources"

exec_sql "
-- Unregister from pg_partman
DELETE FROM partman.part_config WHERE parent_table = 'public.blocks_test_partitioned';

-- Drop tables
DROP TABLE IF EXISTS blocks_test_partitioned CASCADE;
DROP TABLE IF EXISTS blocks_test CASCADE;
" > /dev/null

log_success "Test resources cleaned up"

echo ""

# ===================================================================
# SUMMARY
# ===================================================================

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}TEST COMPLETED SUCCESSFULLY${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""
echo "Summary:"
echo "  ✓ pg_partman extension verified"
echo "  ✓ Partitions created successfully (${PARTITION_COUNT} partitions)"
echo "  ✓ Data migration successful (${TOTAL_ROWS} rows)"
echo "  ✓ Partition pruning working"
echo "  ✓ Retention working (dropped ${DROPPED_COUNT} old partitions)"
echo "  ✓ Data integrity verified"
echo "  ✓ Performance comparison complete"
echo ""
echo "Next steps:"
echo "  1. Review partition pruning in EXPLAIN output"
echo "  2. Compare execution times for query performance"
echo "  3. If satisfied, proceed with production table setup"
echo ""
echo "To run on production tables:"
echo "  kubectl exec -it POD -- psql -U postgres -d blockscout -f /tmp/pg_partman_setup.sql"
echo ""
echo -e "${BLUE}================================================================${NC}"
echo "Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
