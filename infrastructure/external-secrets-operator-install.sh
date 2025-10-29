#!/usr/bin/env bash

#
# External Secrets Operator Installation
# Installs External Secrets Operator for managing secrets from AWS Secrets Manager
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="external-secrets-system"
RELEASE_NAME="external-secrets"
CHART_VERSION="0.9.11"  # Latest stable version

# Functions
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed"
    fi

    if ! command -v helm &> /dev/null; then
        error "helm is not installed"
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
    fi

    success "Prerequisites check passed"
}

# Add Helm repository
add_helm_repo() {
    info "Adding External Secrets Helm repository..."

    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update

    success "Helm repository added"
}

# Install External Secrets Operator
install_operator() {
    info "Installing External Secrets Operator..."

    helm upgrade --install "${RELEASE_NAME}" \
        external-secrets/external-secrets \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --version "${CHART_VERSION}" \
        --set installCRDs=true \
        --set webhook.port=9443 \
        --wait \
        --timeout 5m

    success "External Secrets Operator installed"
}

# Verify installation
verify_installation() {
    info "Verifying installation..."

    # Wait for pods to be ready
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=external-secrets \
        -n "${NAMESPACE}" \
        --timeout=300s

    # Check CRDs
    info "Checking CRDs..."
    kubectl get crd | grep external-secrets

    # Check pods
    info "Checking pods..."
    kubectl get pods -n "${NAMESPACE}"

    success "Installation verified successfully"
}

# Display next steps
display_next_steps() {
    echo ""
    echo "=========================================="
    echo "  External Secrets Operator Installed!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Create AWS Secrets in AWS Secrets Manager (eu-north-1):"
    echo "   See docs/secrets-management.md for exact commands"
    echo ""
    echo "2. Create Kubernetes Secret with AWS credentials:"
    echo "   kubectl create secret generic aws-credentials \\"
    echo "     --from-literal=access-key-id=YOUR_ACCESS_KEY \\"
    echo "     --from-literal=secret-access-key=YOUR_SECRET_KEY \\"
    echo "     -n monad-indexer-dev"
    echo ""
    echo "3. Deploy your application with ArgoCD:"
    echo "   kubectl apply -f argocd/applications/monad-indexer-dev.yaml"
    echo ""
    echo "4. Verify ExternalSecrets are working:"
    echo "   kubectl get externalsecrets -n monad-indexer-dev"
    echo "   kubectl get secrets -n monad-indexer-dev"
    echo ""
}

# Main execution
main() {
    echo "=========================================="
    echo "  External Secrets Operator Installation"
    echo "=========================================="
    echo ""

    check_prerequisites
    add_helm_repo
    install_operator
    verify_installation
    display_next_steps
}

main "$@"
