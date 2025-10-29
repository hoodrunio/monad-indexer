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

# Apply custom services (HTTP/gRPC split services and NodePort for CLI access)
if [ -f "$(dirname "$0")/argocd/argocd-server-services.yaml" ]; then
  echo "📦 Applying ArgoCD custom services..."
  kubectl apply -f "$(dirname "$0")/argocd/argocd-server-services.yaml"
fi

if [ -f "$(dirname "$0")/argocd/argocd-server-nodeport.yaml" ]; then
  echo "📦 Applying ArgoCD NodePort service for CLI access..."
  kubectl apply -f "$(dirname "$0")/argocd/argocd-server-nodeport.yaml"
fi

if [ -f "$(dirname "$0")/argocd/argocd-configmap.yaml" ] || [ -f "$(dirname "$0")/argocd/argocd-cmd-params-cm.yaml" ]; then
  echo "🔄 Restarting ArgoCD server to pick up new configuration..."
  kubectl rollout restart deployment/argocd-server -n argocd
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
fi

# Get initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Get node IP for NodePort access
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')

echo ""
echo "✅ ArgoCD installed successfully!"
echo ""
echo "🔑 Initial Admin Credentials:"
echo "   Username: admin"
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "🌐 Access ArgoCD:"
echo "   Web UI: https://cd.hoodscan.io (via Cilium Gateway)"
echo ""
echo "📝 ArgoCD CLI Login Options:"
echo "   brew install argocd"
echo ""
echo "   Option 1 - NodePort (Recommended for CLI):"
echo "   argocd login ${NODE_IP}:30080 --insecure --plaintext"
echo ""
echo "   Option 2 - SSH Tunnel (if NodePort not accessible):"
echo "   ssh -L 8080:localhost:30080 root@${NODE_IP}"
echo "   argocd login localhost:8080 --insecure --plaintext"
echo ""
echo "   Option 3 - Via Gateway (Web UI only, CLI not supported):"
echo "   # Gateway doesn't support mixed HTTP/gRPC on same hostname (Gateway API limitation)"
echo "   # Use NodePort for CLI access instead"
echo ""
echo "💡 Note: Port-forward doesn't work with Cilium due to network namespace issues."
echo "   Use NodePort (port 30080) for CLI access instead."
echo ""
echo "🎯 Next step: Deploy root application"
echo "   kubectl apply -f argocd/bootstrap/root-app.yaml"
