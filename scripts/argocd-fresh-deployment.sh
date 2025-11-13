#!/bin/bash
# ArgoCD Fresh Deployment Script for Monad Indexer
# This script safely removes and recreates deployment via ArgoCD
# WARNING: This will delete ALL data including PVCs!

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="monad-indexer-production"
ARGOCD_APP="monad-indexer-production"
ARGOCD_NAMESPACE="argocd"

echo -e "${YELLOW}================================================${NC}"
echo -e "${YELLOW}MONAD INDEXER - ARGOCD FRESH DEPLOYMENT${NC}"
echo -e "${YELLOW}================================================${NC}"
echo -e "${RED}WARNING: This will DELETE ALL DATA!${NC}"
echo ""
echo "Namespace: ${NAMESPACE}"
echo "ArgoCD App: ${ARGOCD_APP}"
echo ""

# Step 1: Verify ArgoCD app exists
echo -e "${BLUE}Step 1: Verifying ArgoCD application...${NC}"
if ! kubectl get application "${ARGOCD_APP}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    echo -e "${RED}Error: ArgoCD application '${ARGOCD_APP}' not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ ArgoCD application found${NC}"
echo ""

# Step 2: Show current state
echo -e "${BLUE}Step 2: Current deployment state${NC}"
echo ""
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" -o wide || true
echo ""
echo "PVCs:"
kubectl get pvc -n "${NAMESPACE}" || true
echo ""

read -p "Continue with deletion? (type 'yes' to confirm): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}Aborted by user${NC}"
    exit 0
fi

# Step 3: Delete ArgoCD application (with cascade)
echo ""
echo -e "${BLUE}Step 3: Deleting ArgoCD application...${NC}"
echo "This will remove all managed resources..."

# Delete application with cascade to remove all resources
kubectl delete application "${ARGOCD_APP}" -n "${ARGOCD_NAMESPACE}" --wait=true --timeout=10m

echo -e "${GREEN}✓ ArgoCD application deleted${NC}"

# Step 4: Wait for pods to terminate
echo ""
echo -e "${BLUE}Step 4: Waiting for all pods to terminate...${NC}"
echo "This may take a few minutes..."

# Wait up to 5 minutes for all pods to be deleted
timeout=300
elapsed=0
interval=5

while [ $elapsed -lt $timeout ]; do
    POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$POD_COUNT" -eq "0" ]; then
        echo -e "${GREEN}✓ All pods terminated${NC}"
        break
    fi
    echo "Waiting for pods to terminate... ($POD_COUNT pods remaining) - ${elapsed}s / ${timeout}s"
    sleep $interval
    elapsed=$((elapsed + interval))
done

if [ $elapsed -ge $timeout ]; then
    echo -e "${YELLOW}⚠ Timeout waiting for pods, some may still be terminating${NC}"
    echo "Remaining pods:"
    kubectl get pods -n "${NAMESPACE}" || true
fi

# Step 5: Delete PVCs
echo ""
echo -e "${BLUE}Step 5: Deleting PVCs (DATABASE DATA WILL BE LOST)${NC}"
echo ""
echo "Current PVCs:"
kubectl get pvc -n "${NAMESPACE}" || true
echo ""

read -p "Delete ALL PVCs? This is IRREVERSIBLE! (type 'DELETE' in caps): " CONFIRM_PVC

if [ "$CONFIRM_PVC" = "DELETE" ]; then
    echo "Deleting all PVCs..."

    # Delete PVCs one by one to avoid stuck terminating state
    for pvc in $(kubectl get pvc -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo "Deleting PVC: $pvc"
        kubectl delete pvc "$pvc" -n "${NAMESPACE}" --wait=false
    done

    # Wait for PVCs to be deleted
    echo "Waiting for PVCs to be deleted..."
    timeout=300
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        PVC_COUNT=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$PVC_COUNT" -eq "0" ]; then
            echo -e "${GREEN}✓ All PVCs deleted${NC}"
            break
        fi
        echo "Waiting for PVCs to delete... ($PVC_COUNT remaining) - ${elapsed}s / ${timeout}s"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        echo -e "${YELLOW}⚠ Some PVCs may still be terminating${NC}"
        kubectl get pvc -n "${NAMESPACE}" || true
        echo ""
        read -p "Continue anyway? (yes/no): " CONTINUE
        if [ "$CONTINUE" != "yes" ]; then
            exit 1
        fi
    fi
else
    echo -e "${RED}PVC deletion cancelled - deployment will NOT be fresh!${NC}"
    echo "Existing data will be reused."
    echo ""
    read -p "Continue with deployment using existing data? (yes/no): " CONTINUE
    if [ "$CONTINUE" != "yes" ]; then
        exit 0
    fi
fi

# Step 6: Clean up any remaining resources
echo ""
echo -e "${BLUE}Step 6: Cleaning up remaining resources...${NC}"

# Delete jobs
JOBS=$(kubectl get jobs -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$JOBS" ]; then
    echo "Deleting jobs..."
    for job in $JOBS; do
        kubectl delete job "$job" -n "${NAMESPACE}" --wait=false || true
    done
fi

# Wait a bit for cleanup
sleep 5

echo -e "${GREEN}✓ Cleanup complete${NC}"

# Step 7: Recreate ArgoCD application
echo ""
echo -e "${BLUE}Step 7: Recreating ArgoCD application...${NC}"
echo ""
echo -e "${YELLOW}You need to recreate the ArgoCD application manually:${NC}"
echo ""
echo "Option 1 - Using ArgoCD UI:"
echo "  1. Go to ArgoCD UI"
echo "  2. Click 'New App'"
echo "  3. Use these settings:"
echo "     - Name: ${ARGOCD_APP}"
echo "     - Project: monad-indexer"
echo "     - Sync Policy: Manual (or Automatic if you want)"
echo "     - Repository: https://github.com/hoodrunio/monad-indexer"
echo "     - Branch: stable"
echo "     - Path: charts/monad-indexer"
echo "     - Namespace: ${NAMESPACE}"
echo "     - Values: values.yaml, environments/values-production.yaml"
echo ""
echo "Option 2 - Using kubectl (restore from backup):"
echo "  If you have the original Application YAML, apply it:"
echo "  kubectl apply -f <application-yaml-file>"
echo ""
echo "Option 3 - Using ArgoCD CLI:"
echo "  argocd app create ${ARGOCD_APP} \\"
echo "    --repo https://github.com/hoodrunio/monad-indexer \\"
echo "    --revision stable \\"
echo "    --path charts/monad-indexer \\"
echo "    --dest-namespace ${NAMESPACE} \\"
echo "    --dest-server https://kubernetes.default.svc \\"
echo "    --helm-set-file values.yaml \\"
echo "    --helm-set-file environments/values-production.yaml \\"
echo "    --project monad-indexer \\"
echo "    --sync-option CreateNamespace=true"
echo ""

read -p "Press ENTER when you've recreated the ArgoCD application..."

# Step 8: Monitor deployment
echo ""
echo -e "${BLUE}Step 8: Monitoring deployment...${NC}"

# Wait for app to exist
timeout=60
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if kubectl get application "${ARGOCD_APP}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}✓ ArgoCD application recreated${NC}"
        break
    fi
    echo "Waiting for ArgoCD application... ${elapsed}s / ${timeout}s"
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    echo -e "${RED}✗ ArgoCD application not found after ${timeout}s${NC}"
    echo "Please check ArgoCD UI and recreate the application manually"
    exit 1
fi

# Sync the application
echo ""
echo "Syncing ArgoCD application..."
echo "You can sync via:"
echo "  - ArgoCD UI: Click 'Sync' button"
echo "  - ArgoCD CLI: argocd app sync ${ARGOCD_APP}"
echo "  - kubectl: kubectl patch application ${ARGOCD_APP} -n ${ARGOCD_NAMESPACE} --type merge -p '{\"operation\":{\"sync\":{}}}'"
echo ""

read -p "Sync now automatically? (yes/no): " SYNC_NOW
if [ "$SYNC_NOW" = "yes" ]; then
    if command -v argocd &>/dev/null; then
        argocd app sync "${ARGOCD_APP}" --prune
    else
        echo "ArgoCD CLI not available, using kubectl patch..."
        kubectl patch application "${ARGOCD_APP}" -n "${ARGOCD_NAMESPACE}" --type merge -p '{"operation":{"initiatedBy":{"username":"script"},"sync":{"revision":"stable","prune":true}}}'
    fi
fi

# Monitor pods
echo ""
echo "Monitoring pods (Ctrl+C to stop)..."
watch -n 5 "kubectl get pods -n ${NAMESPACE} -o wide"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Deployment process initiated!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Next steps:"
echo "1. Watch ArgoCD sync status: argocd app get ${ARGOCD_APP}"
echo "2. Monitor pods: kubectl get pods -n ${NAMESPACE} -w"
echo "3. Verify backend logs: kubectl logs -f -l app.kubernetes.io/component=backend -n ${NAMESPACE}"
