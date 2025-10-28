#!/bin/bash
set -e

# Kube-Prometheus-Stack Installation Script
# Installs Prometheus Operator + Prometheus + Grafana + AlertManager
# Provides all CRDs needed for ServiceMonitor, PodMonitor, PrometheusRule

echo "📊 Installing Kube-Prometheus-Stack..."

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Error: kubectl not configured. Please set KUBECONFIG."
  exit 1
fi

# Add Prometheus Community Helm repo
echo "📦 Adding Prometheus Community Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Determine environment (default: production)
ENVIRONMENT="${1:-production}"
VALUES_FILE="helm/kube-prometheus-stack/values-${ENVIRONMENT}.yaml"

if [ ! -f "$VALUES_FILE" ]; then
  echo "❌ Error: Values file not found: $VALUES_FILE"
  echo "Usage: $0 [production|dev]"
  exit 1
fi

echo "🔧 Installing with environment: $ENVIRONMENT"
echo "📄 Using values file: $VALUES_FILE"

# Create monitoring namespace
echo "📁 Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install kube-prometheus-stack
echo "🚀 Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$VALUES_FILE" \
  --version 66.3.1 \
  --wait \
  --timeout 10m

# Wait for operator to be ready
echo "⏳ Waiting for Prometheus Operator to be ready..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus-operator \
  -n monitoring \
  --timeout=300s

# Wait for Prometheus to be ready
echo "⏳ Waiting for Prometheus to be ready..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring \
  --timeout=300s

# Wait for Grafana to be ready
if [ "$ENVIRONMENT" != "production" ] || kubectl get deployment -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
  echo "⏳ Waiting for Grafana to be ready..."
  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=grafana \
    -n monitoring \
    --timeout=300s
fi

echo ""
echo "✅ Kube-Prometheus-Stack installed successfully!"
echo ""
echo "📊 Installed Components:"
kubectl get pods -n monitoring
echo ""

# Get Grafana admin password (if enabled)
if kubectl get secret -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
  GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
  echo "🔑 Grafana Credentials:"
  echo "   Username: admin"
  echo "   Password: $GRAFANA_PASSWORD"
  echo ""
fi

echo "🎯 Access Services:"
echo ""
echo "Prometheus:"
echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  Access at: http://localhost:9090"
echo ""

if kubectl get service -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
  echo "Grafana:"
  echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
  echo "  Access at: http://localhost:3000"
  echo ""
fi

if kubectl get service -n monitoring kube-prometheus-stack-alertmanager &>/dev/null; then
  echo "AlertManager:"
  echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093"
  echo "  Access at: http://localhost:9093"
  echo ""
fi

echo "💡 Tips:"
echo "   - View Prometheus targets: http://localhost:9090/targets"
echo "   - View ServiceMonitors: kubectl get servicemonitors -A"
echo "   - View PodMonitors: kubectl get podmonitors -A"
echo "   - View PrometheusRules: kubectl get prometheusrules -A"
echo ""
echo "🔄 Next Steps:"
echo "   1. Deploy your application with ServiceMonitors enabled"
echo "   2. Check Prometheus is scraping: http://localhost:9090/targets"
echo "   3. View metrics in Grafana: http://localhost:3000"
echo ""
