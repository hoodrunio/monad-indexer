#!/usr/bin/env bash
# Install cert-manager for automatic TLS certificate management
# Manages certificates from Let's Encrypt and other ACME issuers

set -euo pipefail

CERT_MANAGER_VERSION="v1.16.2"

echo "============================================"
echo "Installing cert-manager ${CERT_MANAGER_VERSION}"
echo "============================================"

# Apply cert-manager CRDs and deployment
echo ""
echo "📦 Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

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

# Apply ClusterIssuers if they exist
if [ -f "infrastructure/cert-manager-clusterissuer.yaml" ]; then
    echo ""
    echo "📝 Applying ClusterIssuers..."
    kubectl apply -f infrastructure/cert-manager-clusterissuer.yaml

    echo ""
    echo "✅ ClusterIssuers created:"
    kubectl get clusterissuer
else
    echo ""
    echo "⚠️  ClusterIssuer file not found at: infrastructure/cert-manager-clusterissuer.yaml"
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
