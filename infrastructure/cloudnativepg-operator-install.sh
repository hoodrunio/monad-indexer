#!/bin/bash
set -e

echo "🚀 Installing CloudNativePG Operator..."

# Install CloudNativePG operator
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.1.yaml

# Wait for operator to be ready
echo "⏳ Waiting for CloudNativePG operator to be ready..."
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system --timeout=120s

echo ""
echo "✅ CloudNativePG operator installed successfully!"
echo ""
echo "📊 Operator Status:"
kubectl get pods -n cnpg-system

echo ""
echo "🎯 PostgreSQL clusters will be managed by CloudNativePG"
echo "   Helm chart will automatically create Cluster CRDs"
