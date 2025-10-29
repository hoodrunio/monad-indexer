#!/bin/bash
set -euo pipefail

# Environment Installation Script
# Installs Gateway, LoadBalancer IP Pools, and TLS Certificates for a specific environment

ENVIRONMENT="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/environments/${ENVIRONMENT}"

if [ ! -d "$ENV_DIR" ]; then
  echo "❌ Environment '$ENVIRONMENT' not found at: $ENV_DIR"
  echo ""
  echo "Available environments:"
  ls -1 "${SCRIPT_DIR}/environments/" 2>/dev/null || echo "  (none)"
  exit 1
fi

# Load environment configuration
if [ ! -f "$ENV_DIR/config.env" ]; then
  echo "❌ Configuration file not found: $ENV_DIR/config.env"
  exit 1
fi

source "$ENV_DIR/config.env"

echo "============================================"
echo "Installing Environment: ${ENVIRONMENT}"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Public IP: ${PUBLIC_IP}"
echo "  Gateway: ${GATEWAY_NAME}"
echo ""

# 1. Create namespace
echo "📦 Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 2. Apply LoadBalancer IP Pool
echo ""
echo "📦 Creating LoadBalancer IP Pool..."
kubectl apply -f "$ENV_DIR/lb-ippool.yaml"

# Wait for IP pool to be ready
sleep 2

# 3. Apply Gateway (HTTP-only initially, for cert-manager challenges)
echo ""
echo "📦 Creating Gateway (HTTP-only for cert-manager)..."

# Create temporary HTTP-only Gateway for certificate challenges
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
  labels:
    gateway: monad-indexer
    environment: ${ENVIRONMENT}
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  addresses:
    - type: IPAddress
      value: "${PUBLIC_IP}"
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

# Wait for Gateway to be ready
echo ""
echo "⏳ Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed \
  gateway/${GATEWAY_NAME} \
  -n ${NAMESPACE} \
  --timeout=120s || {
    echo "⚠️  Gateway not ready yet, checking status..."
    kubectl describe gateway/${GATEWAY_NAME} -n ${NAMESPACE}
  }

# Check Gateway status
GATEWAY_STATUS=$(kubectl get gateway/${GATEWAY_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
if [ "$GATEWAY_STATUS" != "True" ]; then
  echo "❌ Gateway failed to become ready!"
  kubectl describe gateway/${GATEWAY_NAME} -n ${NAMESPACE}
  exit 1
fi

GATEWAY_IP=$(kubectl get gateway/${GATEWAY_NAME} -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
echo "✅ Gateway ready with IP: ${GATEWAY_IP}"

# 4. Verify ClusterIssuer exists
echo ""
echo "🔍 Checking for ClusterIssuer (letsencrypt-prod)..."
if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
  echo "❌ ClusterIssuer 'letsencrypt-prod' not found!"
  echo ""
  echo "Please run cert-manager installation first:"
  echo "  ./infrastructure/cert-manager-install.sh"
  echo ""
  echo "Or manually apply ClusterIssuers:"
  echo "  kubectl apply -f infrastructure/common/cert-manager-clusterissuer.yaml"
  exit 1
fi
echo "✅ ClusterIssuer 'letsencrypt-prod' found"

# 5. Apply TLS Certificates
echo ""
echo "📦 Creating TLS Certificates..."
kubectl apply -f "$ENV_DIR/certificates.yaml"

echo ""
echo "⏳ Waiting for certificates to be ready (this may take 1-2 minutes)..."

# Parse domains from config and wait for certificates
for domain_config in "${DOMAINS[@]}"; do
  IFS='|' read -r name hostname service service_ns port tls_secret <<< "$domain_config"

  # Determine which namespace the certificate is in
  cert_namespace="${service_ns}"

  echo "  - Waiting for certificate: ${tls_secret} in namespace: ${cert_namespace}"

  kubectl wait --for=condition=Ready \
    certificate/${tls_secret} \
    -n ${cert_namespace} \
    --timeout=180s || {
      echo "⚠️  Certificate ${tls_secret} not ready yet"
      kubectl describe certificate/${tls_secret} -n ${cert_namespace}
    }
done

# 6. Apply full Gateway with HTTPS listeners
echo ""
echo "📦 Upgrading Gateway to HTTPS..."
kubectl apply -f "$ENV_DIR/gateway.yaml"

# Wait for Gateway to reconfigure
sleep 5

# 7. Apply HTTPRoutes
echo ""
echo "📦 Creating HTTPRoutes..."
kubectl apply -f "$ENV_DIR/httproutes.yaml"

# Final verification
echo ""
echo "============================================"
echo "Environment Installation Complete!"
echo "============================================"
echo ""
echo "📊 Verification:"
echo ""

echo "Gateway Status:"
kubectl get gateway -n ${NAMESPACE}
echo ""

echo "LoadBalancer Services:"
kubectl get svc -n ${NAMESPACE} -l io.cilium.gateway/owning-gateway
echo ""

echo "Certificates:"
kubectl get certificate -A | grep -E "NAMESPACE|${ENVIRONMENT}|argocd" || echo "  (checking all namespaces...)"
for domain_config in "${DOMAINS[@]}"; do
  IFS='|' read -r name hostname service service_ns port tls_secret <<< "$domain_config"
  kubectl get certificate/${tls_secret} -n ${service_ns} 2>/dev/null || echo "  ${tls_secret} (not found)"
done
echo ""

echo "HTTPRoutes:"
kubectl get httproute -A | grep -E "NAMESPACE|${ENVIRONMENT}|argocd" || echo "  (none yet)"
echo ""

echo "============================================"
echo "Access URLs:"
echo "============================================"
for domain_config in "${DOMAINS[@]}"; do
  IFS='|' read -r name hostname service service_ns port tls_secret <<< "$domain_config"
  echo "  https://${hostname}"
done
echo ""

echo "💡 Next steps:"
echo "1. Ensure DNS records point to ${PUBLIC_IP}:"
for domain_config in "${DOMAINS[@]}"; do
  IFS='|' read -r name hostname service service_ns port tls_secret <<< "$domain_config"
  echo "   ${hostname} -> ${PUBLIC_IP}"
done
echo ""
echo "2. Wait for TLS certificates to be issued (check with: kubectl get certificate -A)"
echo "3. Test access: curl -I https://<hostname>"
echo ""
