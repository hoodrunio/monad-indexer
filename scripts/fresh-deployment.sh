#!/bin/bash
# Fresh Deployment Script for Monad Indexer
# This script completely removes the existing deployment and recreates it from scratch
# WARNING: This will delete ALL data including PVCs!

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-monad-indexer-production}"
RELEASE_NAME="${RELEASE_NAME:-monad-indexer-production}"
HELM_CHART_PATH="${HELM_CHART_PATH:-./charts/monad-indexer}"
VALUES_FILE="${VALUES_FILE:-values-production.yaml}"

echo -e "${YELLOW}================================================${NC}"
echo -e "${YELLOW}MONAD INDEXER - FRESH DEPLOYMENT${NC}"
echo -e "${YELLOW}================================================${NC}"
echo -e "${RED}WARNING: This will DELETE ALL DATA!${NC}"
echo ""
echo "Namespace: ${NAMESPACE}"
echo "Release: ${RELEASE_NAME}"
echo "Chart: ${HELM_CHART_PATH}"
echo "Values: ${VALUES_FILE}"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}Aborted by user${NC}"
    exit 0
fi

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 1: Uninstalling Helm release${NC}"
echo -e "${GREEN}================================================${NC}"

if helm list -n "${NAMESPACE}" | grep -q "${RELEASE_NAME}"; then
    echo "Uninstalling Helm release: ${RELEASE_NAME}"
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 10m
    echo -e "${GREEN}✓ Helm release uninstalled${NC}"
else
    echo "Helm release not found, skipping uninstall"
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 2: Waiting for pods to terminate${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Waiting for all pods to terminate..."
kubectl wait --for=delete pod --all -n "${NAMESPACE}" --timeout=300s || true
echo -e "${GREEN}✓ All pods terminated${NC}"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 3: Deleting PVCs (including database data)${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Listing all PVCs in namespace:"
kubectl get pvc -n "${NAMESPACE}"
echo ""

read -p "Delete ALL PVCs? This will erase all database data! (type 'yes'): " CONFIRM_PVC

if [ "$CONFIRM_PVC" = "yes" ]; then
    echo "Deleting all PVCs..."
    kubectl delete pvc --all -n "${NAMESPACE}" --wait=true --timeout=300s || true
    echo -e "${GREEN}✓ All PVCs deleted${NC}"
else
    echo -e "${YELLOW}Skipping PVC deletion - deployment may not be truly fresh!${NC}"
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 4: Cleaning up remaining resources${NC}"
echo -e "${GREEN}================================================${NC}"

# Delete any lingering jobs
echo "Checking for lingering jobs..."
if kubectl get jobs -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q .; then
    echo "Deleting all jobs..."
    kubectl delete jobs --all -n "${NAMESPACE}" --wait=true --timeout=60s || true
fi

# Delete configmaps (except system ones)
echo "Checking for configmaps..."
if kubectl get configmap -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q "${RELEASE_NAME}"; then
    echo "Deleting release-specific configmaps..."
    kubectl delete configmap -l "app.kubernetes.io/instance=${RELEASE_NAME}" -n "${NAMESPACE}" --wait=true || true
fi

# Delete secrets (except system ones)
echo "Checking for secrets..."
if kubectl get secret -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q "${RELEASE_NAME}"; then
    echo "Deleting release-specific secrets..."
    kubectl delete secret -l "app.kubernetes.io/instance=${RELEASE_NAME}" -n "${NAMESPACE}" --wait=true || true
fi

echo -e "${GREEN}✓ Cleanup complete${NC}"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 5: Installing fresh Helm release${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Installing Helm chart..."
if [ -f "${VALUES_FILE}" ]; then
    helm install "${RELEASE_NAME}" "${HELM_CHART_PATH}" \
        -n "${NAMESPACE}" \
        -f "${VALUES_FILE}" \
        --wait \
        --timeout 15m \
        --debug
else
    echo -e "${RED}Error: Values file not found: ${VALUES_FILE}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Helm release installed${NC}"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 6: Monitoring deployment${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Waiting for pods to become ready..."
kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
    -n "${NAMESPACE}" \
    --timeout=600s || true

echo ""
echo "Current pod status:"
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 7: Checking TimescaleDB migration job${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Waiting for TimescaleDB migration job to complete..."
sleep 10  # Give job time to start

JOB_NAME="${RELEASE_NAME}-timescaledb-hypertable"
if kubectl get job "${JOB_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo "Monitoring job: ${JOB_NAME}"

    # Follow job logs in background
    kubectl logs -f "job/${JOB_NAME}" -n "${NAMESPACE}" --all-containers=true 2>&1 &
    LOG_PID=$!

    # Wait for job completion
    kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout=1800s || {
        echo -e "${RED}✗ Job did not complete successfully${NC}"
        echo "Checking job status:"
        kubectl describe job "${JOB_NAME}" -n "${NAMESPACE}"
        exit 1
    }

    # Stop log following
    kill $LOG_PID 2>/dev/null || true

    echo -e "${GREEN}✓ TimescaleDB migration completed${NC}"
else
    echo -e "${YELLOW}⚠ TimescaleDB job not found - may be disabled in values${NC}"
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Step 8: Verifying deployment${NC}"
echo -e "${GREEN}================================================${NC}"

echo "Checking backend pods:"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=backend

echo ""
echo "Checking PostgreSQL:"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=postgresql

echo ""
echo "Verifying TimescaleDB hypertable:"
PGPOD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
if [ -n "$PGPOD" ]; then
    kubectl exec -n "${NAMESPACE}" "${PGPOD}" -- psql -U postgres -d blockscout -c "SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = 'transactions';" || {
        echo -e "${YELLOW}⚠ Could not verify hypertable (may not be created yet if backend is still migrating)${NC}"
    }
else
    echo -e "${RED}✗ PostgreSQL pod not found${NC}"
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✓ FRESH DEPLOYMENT COMPLETE!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Next steps:"
echo "1. Monitor backend logs: kubectl logs -f -n ${NAMESPACE} -l app.kubernetes.io/component=backend"
echo "2. Check indexing status: Check Blockscout UI or API"
echo "3. Verify data ingestion: Check if blocks/transactions are being indexed"
echo ""
echo -e "${YELLOW}Note: Initial sync may take 15-30 minutes depending on blockchain state${NC}"
