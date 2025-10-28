#!/bin/bash
set -e

# K3s Worker Node Installation Script
# For joining worker nodes to existing K3s + Cilium cluster

echo "🚀 Installing K3s worker node..."

# Get master node details
read -p "Enter K3s master node IP: " MASTER_IP
echo ""
echo "To get the node token from master, run:"
echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
echo ""
read -p "Enter K3s token: " NODE_TOKEN

if [ -z "$MASTER_IP" ] || [ -z "$NODE_TOKEN" ]; then
  echo "❌ Error: Master IP and token are required"
  exit 1
fi

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

# Configure system for Cilium
echo "⚙️  Configuring system settings..."
cat <<EOF | sudo tee /etc/sysctl.d/99-cilium.conf
# Cilium eBPF configuration
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 0
EOF
sudo sysctl -p /etc/sysctl.d/99-cilium.conf

# Install K3s agent (worker node)
echo "📦 Installing K3s agent..."
curl -sfL https://get.k3s.io | K3S_URL="https://${MASTER_IP}:6443" \
  K3S_TOKEN="${NODE_TOKEN}" sh -s - \
  --flannel-backend=none \
  --disable-kube-proxy

echo ""
echo "✅ K3s worker node installed successfully!"
echo ""
echo "📊 Check node status on master:"
echo "   kubectl get nodes"
echo ""
echo "💡 If node doesn't appear:"
echo "   1. Check master IP is correct: ping ${MASTER_IP}"
echo "   2. Verify token matches: sudo cat /var/lib/rancher/k3s/server/node-token (on master)"
echo "   3. Check firewall: Port 6443 must be open on master"
echo "   4. View agent logs: sudo journalctl -u k3s-agent -f"
