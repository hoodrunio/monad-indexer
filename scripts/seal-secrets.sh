#!/usr/bin/env bash

#
# Auto-seal secrets for Monad Indexer
# This script automatically generates and seals all required secrets
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-monad-indexer-dev}"
CONTROLLER_NAMESPACE="kube-system"
CONTROLLER_NAME="sealed-secrets-controller"
CERT_FILE="pub-sealed-secrets-cert.pem"
CHARTS_DIR="charts/monad-indexer/templates"

# Function to print colored messages
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

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v kubeseal &> /dev/null; then
        error "kubeseal is not installed. Install it first:\n  brew install kubeseal"
    fi

    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed"
    fi

    if ! kubectl get namespace "${CONTROLLER_NAMESPACE}" &> /dev/null; then
        error "Namespace ${CONTROLLER_NAMESPACE} does not exist"
    fi

    info "Prerequisites OK"
}

# Fetch the sealing certificate
fetch_certificate() {
    info "Fetching sealing certificate from cluster..."

    if ! kubectl get deployment "${CONTROLLER_NAME}" -n "${CONTROLLER_NAMESPACE}" &> /dev/null; then
        error "Sealed Secrets controller not found. Install it first:\n  helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system"
    fi

    kubeseal --fetch-cert \
        --controller-namespace="${CONTROLLER_NAMESPACE}" \
        --controller-name="${CONTROLLER_NAME}" \
        > "${CERT_FILE}"

    info "Certificate saved to ${CERT_FILE}"
}

# Generate backend secret
seal_backend_secret() {
    info "Generating backend SECRET_KEY_BASE..."

    # Try to use mix if available, otherwise use openssl
    if command -v mix &> /dev/null; then
        SECRET_KEY=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 64 | tr -d '\n')
    else
        SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n')
    fi

    # Create temporary secret manifest
    cat > /tmp/backend-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-backend-secret
  namespace: ${NAMESPACE}
  labels:
    app: monad-indexer
    component: backend
type: Opaque
stringData:
  secret-key-base: ${SECRET_KEY}
EOF

    # Seal the secret
    mkdir -p "${CHARTS_DIR}/backend"
    kubeseal --format yaml \
        --cert "${CERT_FILE}" \
        < /tmp/backend-secret.yaml \
        > "${CHARTS_DIR}/backend/sealed-secret.yaml"

    rm /tmp/backend-secret.yaml

    info "Backend sealed secret created at ${CHARTS_DIR}/backend/sealed-secret.yaml"
}

# Generate PostgreSQL secret
seal_postgresql_secret() {
    info "Generating PostgreSQL password..."

    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
    POSTGRES_USERNAME="blockscout"
    POSTGRES_DATABASE="blockscout"

    # URL-encode password to handle special characters (/, =, +, etc.)
    # Important: PostgreSQL connection strings are URIs, special chars must be encoded
    ENCODED_PASSWORD=$(printf "%s" "${POSTGRES_PASSWORD}" | jq -sRr @uri)

    # CloudNativePG will use this secret for bootstrap
    # We'll reference the RW service endpoint in DATABASE_URL
    # Format: postgresql://username:password@host:5432/database
    # Note: Using "postgresql://" as per Blockscout standard (matches Docker env)
    DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${ENCODED_PASSWORD}@monad-indexer-postgresql-rw:5432/${POSTGRES_DATABASE}"

    cat > /tmp/postgres-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-postgresql-app
  namespace: ${NAMESPACE}
  labels:
    app: monad-indexer
    component: postgresql
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: ${POSTGRES_USERNAME}
  password: ${POSTGRES_PASSWORD}
  # Add database URL for application consumption
  uri: ${DATABASE_URL}
EOF

    mkdir -p "${CHARTS_DIR}/postgresql"
    kubeseal --format yaml \
        --cert "${CERT_FILE}" \
        < /tmp/postgres-secret.yaml \
        > "${CHARTS_DIR}/postgresql/sealed-secret.yaml"

    rm /tmp/postgres-secret.yaml

    info "PostgreSQL sealed secret created at ${CHARTS_DIR}/postgresql/sealed-secret.yaml"
    info "  - Username: ${POSTGRES_USERNAME}"
    info "  - Database: ${POSTGRES_DATABASE}"
    info "  - Connection: monad-indexer-postgresql-rw:5432"
}

# Generate Stats PostgreSQL secret
seal_stats_postgresql_secret() {
    info "Generating Stats PostgreSQL password..."

    STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
    STATS_USERNAME="stats"
    STATS_DATABASE="stats"

    # URL-encode password to handle special characters
    ENCODED_STATS_PASSWORD=$(printf "%s" "${STATS_PASSWORD}" | jq -sRr @uri)

    # Stats database connection URL
    # Note: Using "postgresql://" as per Blockscout standard (matches Docker env)
    STATS_DATABASE_URL="postgresql://${STATS_USERNAME}:${ENCODED_STATS_PASSWORD}@monad-indexer-stats-postgresql-rw:5432/${STATS_DATABASE}"

    cat > /tmp/stats-postgres-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-stats-postgresql-app
  namespace: ${NAMESPACE}
  labels:
    app: monad-indexer
    component: stats-postgresql
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: ${STATS_USERNAME}
  password: ${STATS_PASSWORD}
  # Add database URL for application consumption
  uri: ${STATS_DATABASE_URL}
EOF

    mkdir -p "${CHARTS_DIR}/stats-postgresql"
    kubeseal --format yaml \
        --cert "${CERT_FILE}" \
        < /tmp/stats-postgres-secret.yaml \
        > "${CHARTS_DIR}/stats-postgresql/sealed-secret.yaml"

    rm /tmp/stats-postgres-secret.yaml

    info "Stats PostgreSQL sealed secret created at ${CHARTS_DIR}/stats-postgresql/sealed-secret.yaml"
    info "  - Username: ${STATS_USERNAME}"
    info "  - Database: ${STATS_DATABASE}"
    info "  - Connection: monad-indexer-stats-postgresql-rw:5432"
}

# Main execution
main() {
    echo "==============================================="
    echo "  Monad Indexer - Auto Seal Secrets"
    echo "==============================================="
    echo ""

    check_prerequisites
    fetch_certificate

    echo ""
    warn "This will generate NEW sealed secrets. Existing secrets will be overwritten."
    read -p "Continue? (y/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Aborted by user"
    fi

    seal_backend_secret
    seal_postgresql_secret
    seal_stats_postgresql_secret

    # Clean up certificate
    rm -f "${CERT_FILE}"

    echo ""
    info "✓ All secrets sealed successfully!"
    echo ""
    echo "Sealed secrets created:"
    echo "  - ${CHARTS_DIR}/backend/sealed-secret.yaml"
    echo "  - ${CHARTS_DIR}/postgresql/sealed-secret.yaml"
    echo "  - ${CHARTS_DIR}/stats-postgresql/sealed-secret.yaml"
    echo ""
    echo "Next steps:"
    echo "  1. Review the generated sealed secrets"
    echo "  2. Commit them to Git (sealed secrets are safe to commit)"
    echo "  3. Deploy with: make deploy"
    echo ""
    echo "Note: values.yaml is already configured to use sealed secrets by default"
    echo ""
}

main "$@"
