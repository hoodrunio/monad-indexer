#!/bin/bash
set -e

echo "🚀 Installing ArgoCD..."

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
# Use non-HA for single node, HA for multi-node clusters
# For HA mode, uncomment the line below and comment out the non-HA line
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml

# Wait for ArgoCD to be ready
echo "⏳ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Apply custom ArgoCD configuration (URL, resource exclusions, etc.)
if [ -f "$(dirname "$0")/argocd/argocd-configmap.yaml" ]; then
  echo "📦 Applying ArgoCD configuration overrides..."
  kubectl apply -f "$(dirname "$0")/argocd/argocd-configmap.yaml"
fi

if [ -f "$(dirname "$0")/argocd/argocd-cmd-params-cm.yaml" ]; then
  echo "📦 Applying ArgoCD command parameters..."
  kubectl apply -f "$(dirname "$0")/argocd/argocd-cmd-params-cm.yaml"
fi

if [ -f "$(dirname "$0")/argocd/argocd-configmap.yaml" ] || [ -f "$(dirname "$0")/argocd/argocd-cmd-params-cm.yaml" ]; then
  echo "🔄 Restarting ArgoCD server to pick up new configuration..."
  kubectl rollout restart deployment/argocd-server -n argocd
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
fi

# Get initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "✅ ArgoCD installed successfully!"
echo ""
echo "🔑 Initial Admin Credentials:"
echo "   Username: admin"
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "🌐 Access ArgoCD:"
echo "   Web UI: https://cd.hoodscan.io (via Cilium Gateway with HTTPS)"
echo "   Or port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "   Then visit: http://localhost:8080"
echo ""
echo "📝 ArgoCD CLI Login:"
echo "   brew install argocd"
echo "   # Via Gateway (requires Gateway with ALPN enabled):"
echo "   argocd login cd.hoodscan.io"
echo "   # Or via port-forward:"
echo "   argocd login localhost:8080 --insecure --plaintext"
echo ""
echo "💡 Note: CLI access via Gateway requires:"
echo "   - Cilium Gateway API with ALPN enabled (enableAlpn: true)"
echo "   - GRPCRoute configured for ArgoCD"
echo "   - Valid TLS certificate"
echo ""
echo "🎯 Next step: Deploy root application"
echo "   kubectl apply -f argocd/bootstrap/root-app.yaml"
