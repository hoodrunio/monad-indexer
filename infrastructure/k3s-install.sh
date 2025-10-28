#!/bin/bash
set -e

# K3s + Cilium Installation Script for Monad Indexer
# Optimized for high-throughput blockchain indexer (5000 TPS)

echo "🚀 Installing K3s with Cilium CNI for Monad Indexer..."

# Detect node IP
NODE_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
echo "📍 Detected node IP: $NODE_IP"

# Check kernel version
KERNEL_VERSION=$(uname -r | cut -d. -f1,2)
echo "🔍 Checking kernel version: $(uname -r)"
REQUIRED_VERSION="5.10"

if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$KERNEL_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
  echo "❌ Error: Kernel version 5.10+ required for Cilium. Current: $(uname -r)"
  echo "   Upgrade kernel or use Ubuntu 22.04 LTS (kernel 5.15+)"
  exit 1
fi
echo "✅ Kernel version compatible"

# Verify eBPF support
echo "🔍 Verifying eBPF support..."
if [ ! -f "/boot/config-$(uname -r)" ]; then
  echo "⚠️  Warning: Cannot verify eBPF support (kernel config not found)"
  echo "   Proceeding anyway... If installation fails, check CONFIG_BPF=y in kernel"
elif ! grep -q "CONFIG_BPF=y" /boot/config-$(uname -r); then
  echo "❌ Error: eBPF not enabled in kernel. Recompile kernel with CONFIG_BPF=y"
  exit 1
else
  echo "✅ eBPF support verified"
fi

# Configure system for Cilium
echo "⚙️  Configuring system settings..."

# Load br_netfilter module first
sudo modprobe br_netfilter 2>/dev/null || echo "⚠️  br_netfilter module not available (will be loaded by K3s)"

cat <<EOF | sudo tee /etc/sysctl.d/99-cilium.conf
# Cilium eBPF configuration
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 0
EOF

# Apply settings (ignore errors for bridge settings if module not loaded yet)
sudo sysctl -p /etc/sysctl.d/99-cilium.conf 2>&1 | grep -v "cannot stat" || true
echo "✅ System settings configured"

# Install K3s with Cilium-compatible flags
echo "📦 Installing K3s (without Flannel, kube-proxy, ServiceLB, Traefik)..."
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable traefik \
  --disable servicelb \
  --kube-apiserver-arg "service-node-port-range=80-32767" \
  --cluster-init

# Wait for K3s API server
echo "⏳ Waiting for K3s API server..."
until sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null; do
  sleep 2
done

# Set KUBECONFIG
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Get API server details
API_SERVER_IP=$(sudo kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
API_SERVER_PORT=6443
echo "📍 API Server: $API_SERVER_IP:$API_SERVER_PORT"

# Install Cilium CLI
echo "📥 Installing Cilium CLI..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
echo "✅ Cilium CLI installed: $(cilium version --client)"

# Install Cilium with production configuration
echo "🔧 Installing Cilium CNI (production configuration)..."
cilium install \
  --version 1.18.3 \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set k8sServicePort=${API_SERVER_PORT} \
  --set routingMode=native \
  --set loadBalancer.acceleration=native \
  --set loadBalancer.mode=hybrid \
  --set l2announcements.enabled=true \
  --set hubble.enabled=false \
  --set bpf.events.trace.enabled=false \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=false \
  --set operator.replicas=1 \
  --wait

echo "💡 Note: Prometheus ServiceMonitor disabled (will be enabled after Prometheus Operator is installed)"

# Wait for Cilium to be ready
echo "⏳ Waiting for Cilium to be ready..."
cilium status --wait

# Validate installation
echo "🔍 Validating Cilium installation..."
echo ""
cilium status

# Run connectivity test (optional)
echo ""
read -p "🧪 Run Cilium connectivity test? Takes 5-10 minutes (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "🧪 Running connectivity test..."
  cilium connectivity test || echo "⚠️  Some connectivity tests failed (may be non-critical)"
fi

# Wait for nodes to be ready
echo "⏳ Waiting for nodes to be ready..."
sudo kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Wait for local-path-provisioner
echo "⏳ Waiting for local-path-provisioner..."
sudo kubectl wait --for=condition=Ready pod -l app=local-path-provisioner -n kube-system --timeout=60s

echo ""
echo "✅ K3s + Cilium installed successfully!"
echo ""
echo "📊 Cluster Information:"
sudo kubectl cluster-info
sudo kubectl get nodes -o wide
echo ""
echo "📦 Cilium Pods:"
sudo kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent -o wide
echo ""
echo "🎯 Next steps:"
echo "1. Export KUBECONFIG: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "2. Install ArgoCD: ./argocd-install.sh"
echo "3. Install CloudNativePG operator: ./cloudnativepg-operator-install.sh"
echo "4. Install External Secrets Operator: ./external-secrets-operator-install.sh"
echo "5. Deploy LoadBalancer IP pool: kubectl apply -f helm/cilium/lb-ippool.yaml"
echo ""
echo "💡 Tips:"
echo "   - Check Cilium status: cilium status"
echo "   - View Cilium logs: kubectl logs -n kube-system ds/cilium-agent"
echo "   - Enable Hubble: helm upgrade cilium cilium/cilium --set hubble.enabled=true --reuse-values -n kube-system"
echo "   - Monitor performance: watch 'kubectl top nodes'"
