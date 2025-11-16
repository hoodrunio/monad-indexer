-- Citus Worker Registration Script
-- This script registers Citus worker nodes to the coordinator cluster
-- Run this on the COORDINATOR node after worker nodes are ready

\echo '==========================================
\echo 'Citus Worker Registration
\echo '==========================================

-- Step 1: Verify Citus extension is loaded
\echo 'Verifying Citus extension...'
SELECT extname, extversion FROM pg_extension WHERE extname = 'citus';

-- Step 2: Check existing worker nodes (should be empty for first run or show localhost only)
\echo ''
\echo 'Current worker nodes:'
SELECT nodeid, nodename, nodeport, isactive
FROM pg_dist_node
ORDER BY nodeid;

-- Step 3: Add coordinator itself as a worker (localhost)
-- This allows the coordinator to store shards locally
\echo ''
\echo 'Adding coordinator as local worker (localhost)...'
SELECT citus_add_node('localhost', 5432);

-- Step 4: Add remote worker node (ubuntu node)
-- Replace with actual Kubernetes service DNS name
\echo ''
\echo 'Adding remote worker node...'
SELECT citus_add_node('{{ include "monad-indexer.fullname" . }}-citus-worker-0.{{ include "monad-indexer.fullname" . }}-citus-worker.{{ .Release.Namespace }}.svc.cluster.local', 5432);

-- Step 5: Verify all workers are registered
\echo ''
\echo 'Registered worker nodes:'
SELECT nodeid, nodename, nodeport, isactive, noderole
FROM pg_dist_node
ORDER BY nodeid;

-- Step 6: Check worker health
\echo ''
\echo 'Checking worker node health...'
SELECT * FROM citus_check_cluster_node_health();

-- Step 7: Get active worker nodes
\echo ''
\echo 'Active worker nodes:'
SELECT * FROM citus_get_active_worker_nodes();

\echo ''
\echo '==========================================
\echo 'Worker registration complete!
\echo 'You can now proceed with shard rebalancing.
\echo '==========================================
