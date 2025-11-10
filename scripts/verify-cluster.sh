#!/bin/bash
#
# Cluster Verification Script for 2-Node HA Setup
#
# This script verifies the health and proper configuration of the
# 2-node K3s cluster with PostgreSQL HA and distributed backend pods
#
# Usage: ./scripts/verify-cluster.sh [namespace]
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Critical failure (cluster not accessible)

set -euo pipefail

# Configuration
NAMESPACE="${1:-monad-indexer-production}"
CLUSTER_NAME="monad-indexer-production-postgresql"
MIN_BACKEND_PODS=4
EXPECTED_NODES=2
EXPECTED_PG_REPLICAS=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
}

print_check() {
    echo -e "\n${YELLOW}[CHECK]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAILED++))
}

print_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
    ((WARNINGS++))
}

print_info() {
    echo -e "${BLUE}ℹ INFO${NC}: $1"
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl not found in PATH${NC}"
        exit 2
    fi
}

# Check cluster connectivity
check_cluster_access() {
    print_check "Cluster Connectivity"
    if kubectl cluster-info &> /dev/null; then
        print_pass "Cluster is accessible"
    else
        print_fail "Cannot connect to cluster"
        exit 2
    fi
}

# Check node count and status
check_nodes() {
    print_header "NODE VERIFICATION"

    print_check "Node Count"
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | xargs)
    if [ "$NODE_COUNT" -eq "$EXPECTED_NODES" ]; then
        print_pass "Found $NODE_COUNT nodes (expected: $EXPECTED_NODES)"
    else
        print_fail "Found $NODE_COUNT nodes (expected: $EXPECTED_NODES)"
    fi

    print_check "Node Status"
    NOT_READY=$(kubectl get nodes --no-headers | grep -v "Ready" | wc -l | xargs)
    if [ "$NOT_READY" -eq 0 ]; then
        print_pass "All nodes are Ready"
    else
        print_fail "$NOT_READY node(s) are not Ready"
        kubectl get nodes
    fi

    print_check "Node Labels"
    PRIMARY_NODES=$(kubectl get nodes -l postgres-role=primary --no-headers | wc -l | xargs)
    REPLICA_NODES=$(kubectl get nodes -l postgres-role=replica --no-headers | wc -l | xargs)

    if [ "$PRIMARY_NODES" -eq 1 ] && [ "$REPLICA_NODES" -eq 1 ]; then
        print_pass "Node labels correct (primary: $PRIMARY_NODES, replica: $REPLICA_NODES)"
    else
        print_fail "Node labels incorrect (primary: $PRIMARY_NODES, replica: $REPLICA_NODES)"
        print_info "Run: kubectl label nodes <node1> postgres-role=primary"
        print_info "Run: kubectl label nodes <node2> postgres-role=replica"
    fi

    print_info "Node details:"
    kubectl get nodes -o wide --show-labels | grep -E "NAME|postgres-role"
}

# Check PostgreSQL cluster
check_postgresql() {
    print_header "POSTGRESQL VERIFICATION"

    print_check "PostgreSQL Cluster Status"
    if kubectl get cluster -n "$NAMESPACE" "$CLUSTER_NAME" &> /dev/null; then
        CLUSTER_STATUS=$(kubectl get cluster -n "$NAMESPACE" "$CLUSTER_NAME" -o jsonpath='{.status.phase}')
        CLUSTER_READY=$(kubectl get cluster -n "$NAMESPACE" "$CLUSTER_NAME" -o jsonpath='{.status.instances}')

        if [ "$CLUSTER_STATUS" == "Cluster in healthy state" ] || [ "$CLUSTER_STATUS" == "Healthy" ]; then
            print_pass "PostgreSQL cluster is healthy (instances: $CLUSTER_READY)"
        else
            print_fail "PostgreSQL cluster status: $CLUSTER_STATUS"
        fi
    else
        print_fail "PostgreSQL cluster '$CLUSTER_NAME' not found"
    fi

    print_check "PostgreSQL Pods"
    PG_PODS=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" --no-headers | wc -l | xargs)
    PG_READY=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" --field-selector=status.phase=Running --no-headers | wc -l | xargs)

    if [ "$PG_PODS" -eq "$EXPECTED_PG_REPLICAS" ] && [ "$PG_READY" -eq "$EXPECTED_PG_REPLICAS" ]; then
        print_pass "PostgreSQL pods running: $PG_READY/$PG_PODS (expected: $EXPECTED_PG_REPLICAS)"
    else
        print_fail "PostgreSQL pods: $PG_READY/$PG_PODS running (expected: $EXPECTED_PG_REPLICAS)"
        kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME"
    fi

    print_check "PostgreSQL Pod Distribution"
    NODE1_PG=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
    NODE2_PG=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=replica" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")

    if [ -n "$NODE1_PG" ] && [ -n "$NODE2_PG" ] && [ "$NODE1_PG" != "$NODE2_PG" ]; then
        print_pass "PostgreSQL pods distributed across nodes (primary: $NODE1_PG, replica: $NODE2_PG)"
    else
        print_warn "PostgreSQL pods may not be properly distributed"
        kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" -o wide
    fi

    print_check "PostgreSQL Replication"
    PRIMARY_POD=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$PRIMARY_POD" ]; then
        REPL_COUNT=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U postgres -tAc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")

        if [ "$REPL_COUNT" -ge 1 ]; then
            print_pass "Replication active ($REPL_COUNT replica(s) connected)"

            # Check replication lag
            LAG=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U postgres -tAc "SELECT COALESCE(MAX(replay_lag), '0'::interval) FROM pg_stat_replication;" 2>/dev/null || echo "unknown")
            print_info "Replication lag: $LAG"
        else
            print_fail "No replication connections found"
        fi
    else
        print_warn "Cannot find primary PostgreSQL pod"
    fi
}

# Check PgBouncer pooler
check_pgbouncer() {
    print_header "PGBOUNCER VERIFICATION"

    print_check "PgBouncer Pods"
    POOLER_PODS=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/poolerName" --no-headers | wc -l | xargs)
    POOLER_READY=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/poolerName" --field-selector=status.phase=Running --no-headers | wc -l | xargs)

    if [ "$POOLER_PODS" -ge 1 ] && [ "$POOLER_READY" -eq "$POOLER_PODS" ]; then
        print_pass "PgBouncer pods running: $POOLER_READY/$POOLER_PODS"
    else
        print_fail "PgBouncer pods: $POOLER_READY/$POOLER_PODS running"
        kubectl get pods -n "$NAMESPACE" -l "cnpg.io/poolerName"
    fi

    print_check "PgBouncer Configuration"
    if [ "$POOLER_READY" -gt 0 ]; then
        POOLER_POD=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/poolerName" -o jsonpath='{.items[0].metadata.name}')
        DEFAULT_POOL_SIZE=$(kubectl exec -n "$NAMESPACE" "$POOLER_POD" -- cat /etc/pgbouncer/pgbouncer.ini 2>/dev/null | grep "^default_pool_size" | awk -F= '{print $2}' | xargs || echo "unknown")
        MAX_CLIENT_CONN=$(kubectl exec -n "$NAMESPACE" "$POOLER_POD" -- cat /etc/pgbouncer/pgbouncer.ini 2>/dev/null | grep "^max_client_conn" | awk -F= '{print $2}' | xargs || echo "unknown")

        print_info "default_pool_size: $DEFAULT_POOL_SIZE (expected: 500)"
        print_info "max_client_conn: $MAX_CLIENT_CONN (expected: 10000)"

        if [ "$DEFAULT_POOL_SIZE" -ge 500 ]; then
            print_pass "PgBouncer pool size adequate"
        else
            print_warn "PgBouncer pool size may be too small"
        fi
    fi
}

# Check backend pods
check_backend() {
    print_header "BACKEND VERIFICATION"

    print_check "Backend Pods"
    BACKEND_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" --no-headers | wc -l | xargs)
    BACKEND_READY=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" --field-selector=status.phase=Running --no-headers | wc -l | xargs)

    if [ "$BACKEND_PODS" -ge "$MIN_BACKEND_PODS" ] && [ "$BACKEND_READY" -eq "$BACKEND_PODS" ]; then
        print_pass "Backend pods running: $BACKEND_READY/$BACKEND_PODS (minimum: $MIN_BACKEND_PODS)"
    else
        print_fail "Backend pods: $BACKEND_READY/$BACKEND_PODS running (minimum: $MIN_BACKEND_PODS)"
        kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend"
    fi

    print_check "Backend Pod Distribution"
    NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in $NODES; do
        NODE_BACKEND_COUNT=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" --field-selector="spec.nodeName=$node" --no-headers | wc -l | xargs)
        print_info "$node: $NODE_BACKEND_COUNT backend pods"
    done

    # Check if pods are distributed (at least 2 pods on each node)
    MIN_PER_NODE=$(kubectl get nodes -o name | xargs -I {} sh -c "kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=backend --field-selector=spec.nodeName={} --no-headers 2>/dev/null | wc -l" | sort -n | head -1 | xargs)

    if [ "$MIN_PER_NODE" -ge 2 ]; then
        print_pass "Backend pods well distributed (minimum per node: $MIN_PER_NODE)"
    else
        print_warn "Backend pods not evenly distributed (minimum per node: $MIN_PER_NODE)"
    fi

    print_check "Backend Pod Restarts"
    MAX_RESTARTS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | tr ' ' '\n' | sort -rn | head -1)

    if [ -z "$MAX_RESTARTS" ]; then
        MAX_RESTARTS=0
    fi

    if [ "$MAX_RESTARTS" -le 5 ]; then
        print_pass "Backend pod restarts acceptable (max: $MAX_RESTARTS)"
    else
        print_warn "High restart count detected (max: $MAX_RESTARTS)"
        kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount
    fi

    print_check "Backend Connection Errors"
    ERROR_COUNT=$(kubectl logs -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" --tail=500 --since=5m 2>/dev/null | grep -i "connection.*error\|connection not available\|timeout" | wc -l | xargs)

    if [ "$ERROR_COUNT" -eq 0 ]; then
        print_pass "No recent connection errors"
    elif [ "$ERROR_COUNT" -lt 10 ]; then
        print_warn "Some connection errors detected ($ERROR_COUNT in last 5 min)"
    else
        print_fail "High connection error rate ($ERROR_COUNT in last 5 min)"
    fi
}

# Check resource usage
check_resources() {
    print_header "RESOURCE VERIFICATION"

    print_check "Node Resources"
    kubectl top nodes 2>/dev/null | while read -r line; do
        if [[ "$line" =~ ^NAME ]]; then
            continue
        fi
        NODE=$(echo "$line" | awk '{print $1}')
        CPU_PERCENT=$(echo "$line" | awk '{print $3}' | sed 's/%//')
        MEM_PERCENT=$(echo "$line" | awk '{print $5}' | sed 's/%//')

        if [ "$CPU_PERCENT" -lt 80 ] && [ "$MEM_PERCENT" -lt 80 ]; then
            print_pass "$NODE: CPU ${CPU_PERCENT}%, Memory ${MEM_PERCENT}%"
        elif [ "$CPU_PERCENT" -ge 80 ] || [ "$MEM_PERCENT" -ge 80 ]; then
            print_warn "$NODE: CPU ${CPU_PERCENT}%, Memory ${MEM_PERCENT}% (high utilization)"
        fi
    done

    print_check "PostgreSQL Resources"
    PG_PODS_LIST=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" -o jsonpath='{.items[*].metadata.name}')
    for pod in $PG_PODS_LIST; do
        RESOURCES=$(kubectl top pod -n "$NAMESPACE" "$pod" 2>/dev/null | tail -1)
        print_info "$pod: $RESOURCES"
    done

    print_check "Backend Resources"
    BACKEND_AVG_CPU=$(kubectl top pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" 2>/dev/null | tail -n +2 | awk '{sum+=$2} END {print int(sum/NR)}')
    BACKEND_AVG_MEM=$(kubectl top pods -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" 2>/dev/null | tail -n +2 | awk '{sum+=$3} END {print int(sum/NR)}')

    if [ -n "$BACKEND_AVG_CPU" ]; then
        print_info "Backend average: ${BACKEND_AVG_CPU}m CPU, ${BACKEND_AVG_MEM}Mi Memory"
    fi
}

# Check application health
check_application() {
    print_header "APPLICATION VERIFICATION"

    print_check "Indexing Progress"
    RECENT_LOGS=$(kubectl logs -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" --tail=100 --since=2m 2>/dev/null | grep -i "fetching\|imported\|inserted" | tail -5)

    if [ -n "$RECENT_LOGS" ]; then
        print_pass "Indexing active (recent activity detected)"
        print_info "Recent logs:"
        echo "$RECENT_LOGS" | head -3
    else
        print_warn "No recent indexing activity detected"
    fi

    print_check "Stats Service"
    STATS_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=stats" --field-selector=status.phase=Running --no-headers | wc -l | xargs)

    if [ "$STATS_PODS" -ge 1 ]; then
        STATS_RESTARTS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=stats" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | tr ' ' '\n' | sort -rn | head -1)

        if [ "$STATS_RESTARTS" -le 5 ]; then
            print_pass "Stats service healthy (restarts: $STATS_RESTARTS)"
        else
            print_warn "Stats service has high restart count: $STATS_RESTARTS"
        fi
    else
        print_fail "Stats service not running"
    fi

    print_check "API Health"
    # Try to get backend service
    BACKEND_SVC=$(kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/component=backend" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$BACKEND_SVC" ]; then
        # Port forward and test (with timeout)
        kubectl port-forward -n "$NAMESPACE" "svc/$BACKEND_SVC" 4000:4000 &>/dev/null &
        PF_PID=$!
        sleep 2

        if curl -s --max-time 5 http://localhost:4000/api/v2/stats &>/dev/null; then
            print_pass "API responding successfully"
        else
            print_warn "API health check failed"
        fi

        kill $PF_PID 2>/dev/null || true
    else
        print_info "Backend service not found (skipping API check)"
    fi
}

# Print summary
print_summary() {
    print_header "VERIFICATION SUMMARY"

    TOTAL=$((PASSED + FAILED + WARNINGS))

    echo -e "\nResults:"
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${BLUE}Total:${NC}    $TOTAL"

    if [ "$FAILED" -eq 0 ]; then
        if [ "$WARNINGS" -eq 0 ]; then
            echo -e "\n${GREEN}✓ All checks passed! Cluster is healthy.${NC}"
            return 0
        else
            echo -e "\n${YELLOW}⚠ All critical checks passed, but there are warnings.${NC}"
            return 0
        fi
    else
        echo -e "\n${RED}✗ Some checks failed. Please review the output above.${NC}"
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "=========================================="
    echo "  2-Node HA Cluster Verification"
    echo "=========================================="
    echo -e "${NC}"
    echo "Namespace: $NAMESPACE"
    echo "Timestamp: $(date)"
    echo ""

    check_kubectl
    check_cluster_access
    check_nodes
    check_postgresql
    check_pgbouncer
    check_backend
    check_resources
    check_application

    print_summary
}

# Run main function
main
exit $?
