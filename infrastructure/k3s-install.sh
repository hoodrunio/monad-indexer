#!/bin/bash
set -e

# K3s Installation Script for Monad Indexer
# This script installs K3s with optimized settings for blockchain indexer workload

echo "🚀 Installing K3s for Monad Indexer..."

# Install K3s
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --kube-apiserver-arg "service-node-port-range=80-32767"

# Wait for K3s to be ready
echo "⏳ Waiting for K3s to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Install local-path-provisioner (default in K3s, but ensure it's ready)
kubectl wait --for=condition=Ready pod -l app=local-path-provisioner -n kube-system --timeout=60s

echo "✅ K3s installed successfully!"

# Display cluster info
echo ""
echo "📊 Cluster Information:"
kubectl cluster-info
kubectl get nodes

echo ""
echo "🎯 Next steps:"
echo "1. Install ArgoCD: ./argocd-install.sh"
echo "2. Install CloudNativePG operator: ./cloudnativepg-operator-install.sh"
echo "3. Install External Secrets Operator: ./external-secrets-operator-install.sh"
