#!/usr/bin/env bash
# Install cert-manager for automatic TLS certificate management
# Manages certificates from Let's Encrypt and other ACME issuers

set -euo pipefail

CERT_MANAGER_VERSION="v1.19.1"

echo "============================================"
echo "Installing cert-manager ${CERT_MANAGER_VERSION}"
echo "============================================"

# Apply cert-manager with Gateway API support
echo ""
echo "📦 Installing cert-manager with Gateway API support..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Enable Gateway API support (v1.15+ uses --enable-gateway-api flag instead of feature gate)
echo ""
echo "🔧 Enabling Gateway API support on cert-manager controller..."
kubectl patch deployment cert-manager -n cert-manager --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--enable-gateway-api"
  }
]'

# Wait for cert-manager to be ready
echo ""
echo "⏳ Waiting for cert-manager pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

# Verify installation
echo ""
echo "✅ cert-manager installation complete!"
echo ""
echo "Verifying installation:"
kubectl get pods -n cert-manager

# Wait for webhook to be ready with CA bundle injected
echo ""
echo "⏳ Waiting for webhook CA bundle to be injected..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
  ca_bundle=$(kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || echo "")
  if [ -n "$ca_bundle" ] && [ "$ca_bundle" != "null" ]; then
    echo "✅ Webhook CA bundle injected successfully"
    break
  fi

  attempt=$((attempt + 1))
  if [ $attempt -eq $max_attempts ]; then
    echo "⚠️  Warning: Webhook CA bundle not yet injected after ${max_attempts} seconds"
    echo "Continuing anyway, but ClusterIssuer apply might fail..."
    break
  fi

  sleep 5
done

# Apply ClusterIssuers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERISSUER_FILE="${SCRIPT_DIR}/common/cert-manager-clusterissuer.yaml"
if [ -f "$CLUSTERISSUER_FILE" ]; then
    echo ""
    echo "📝 Applying ClusterIssuers..."
    # Retry logic for ClusterIssuer apply (in case webhook is still settling)
    max_retries=3
    retry=0
    while [ $retry -lt $max_retries ]; do
      if kubectl apply -f "$CLUSTERISSUER_FILE" 2>/dev/null; then
        break
      fi

      retry=$((retry + 1))
      if [ $retry -lt $max_retries ]; then
        echo "⚠️  ClusterIssuer apply failed, retrying in 5 seconds... (attempt $retry/$max_retries)"
        sleep 5
      else
        echo "❌ ClusterIssuer apply failed after $max_retries attempts"
        echo "You can manually apply it later:"
        echo "  kubectl apply -f $CLUSTERISSUER_FILE"
      fi
    done

    echo ""
    echo "✅ ClusterIssuers created:"
    kubectl get clusterissuer
else
    echo ""
    echo "⚠️  ClusterIssuer file not found at: $CLUSTERISSUER_FILE"
    echo "You can create it manually or apply it later."
fi

echo ""
echo "============================================"
echo "cert-manager is ready!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Create ClusterIssuers (if not done): kubectl apply -f infrastructure/cert-manager-clusterissuer.yaml"
echo "2. Add annotation to Ingress: cert-manager.io/cluster-issuer: \"letsencrypt-prod\""
echo "3. Add tls section to Ingress with secretName and hosts"
echo ""
echo "Documentation: https://cert-manager.io/docs/"
