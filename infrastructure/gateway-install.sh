#!/bin/bash
set -e

echo "🚀 Installing Gateway Infrastructure..."

# Check if Gateway API CRDs are installed
if ! kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  echo "❌ Error: Gateway API CRDs not found!"
  echo "   Gateway API CRDs should be installed by k3s-install.sh"
  echo "   Run: kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
  exit 1
fi
echo "✅ Gateway API CRDs found"

# Check if Cilium Gateway API is enabled
if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy &>/dev/null; then
  echo "⚠️  Warning: Cilium Envoy pods not found!"
  echo "   Gateway API may not be enabled in Cilium."
  echo "   Check: cilium status | grep -i gateway"
  echo "   Continuing anyway..."
fi

# Create namespace
echo "📦 Creating monad-indexer-dev namespace..."
kubectl create namespace monad-indexer-dev --dry-run=client -o yaml | kubectl apply -f -

# Install GatewayClass
echo "📦 Installing GatewayClass..."
kubectl apply -f infrastructure/gateway/gatewayclass.yaml

# Wait for GatewayClass to be accepted
echo "⏳ Waiting for GatewayClass to be accepted..."
kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=60s || echo "⚠️  GatewayClass not accepted yet"

# Install Gateway
echo "📦 Installing Gateway..."
kubectl apply -f infrastructure/gateway/gateway-dev.yaml

# Wait for Gateway to be ready
echo "⏳ Waiting for Gateway to be programmed..."
sleep 5
kubectl wait --for=condition=Programmed gateway/monad-indexer-gateway -n monad-indexer-dev --timeout=120s || echo "⚠️  Gateway not ready yet"

# Check Gateway status
echo ""
echo "📊 Gateway Status:"
kubectl get gateway -n monad-indexer-dev
kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev | grep -A10 "Status:"

# Check if LoadBalancer IP is assigned
GATEWAY_IP=$(kubectl get gateway monad-indexer-gateway -n monad-indexer-dev -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
if [ -n "$GATEWAY_IP" ]; then
  echo ""
  echo "✅ Gateway LoadBalancer IP assigned: $GATEWAY_IP"
else
  echo ""
  echo "⚠️  Gateway LoadBalancer IP not assigned yet"
  echo "   Check: kubectl get svc -n monad-indexer-dev"
fi

# Install ArgoCD Gateway TLS certificate
echo ""
echo "📦 Installing ArgoCD Gateway TLS certificate..."
kubectl apply -f infrastructure/gateway/argocd-gateway-tls.yaml

echo ""
echo "✅ Gateway infrastructure installed!"
echo ""
echo "🎯 Next steps:"
echo "1. Install ArgoCD: ./infrastructure/argocd-install.sh"
echo "2. Configure DNS:"
echo "   - cd.hoodscan.io -> ${GATEWAY_IP:-65.21.183.30}"
echo "   - monad-tn1-indexer.hoodscan.io -> ${GATEWAY_IP:-65.21.183.30}"
echo "3. Deploy ArgoCD HTTPRoute: kubectl apply -f argocd/argocd-httproute.yaml"
echo "4. Access ArgoCD at: https://cd.hoodscan.io"
echo ""
