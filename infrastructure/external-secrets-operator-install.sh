#!/bin/bash
set -e

echo "🚀 Installing External Secrets Operator..."

# Add Helm repository
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install External Secrets Operator
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --wait

echo ""
echo "✅ External Secrets Operator installed successfully!"
echo ""
echo "📊 Operator Status:"
kubectl get pods -n external-secrets-system

echo ""
echo "🎯 Next steps:"
echo "1. Create SecretStore for your secrets backend (AWS, GCP, Vault, etc.)"
echo "2. Example: kubectl apply -f examples/secret-store-aws.yaml"
echo "3. Create ExternalSecret resources in your Helm chart"
