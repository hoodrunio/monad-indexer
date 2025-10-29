# Development Setup - Monad Indexer

Quick start guide for local development environment.

## Prerequisites

- **Linux kernel 5.10+** (for Cilium eBPF support)
  - Ubuntu 22.04 LTS: kernel 5.15+ ✅
  - macOS: N/A (Docker Desktop uses Linux VM)
- **Docker** (for K3s/Docker Desktop Kubernetes)
- **kubectl** & **helm** CLI tools
- **Git**
- 4GB+ RAM, 20GB+ disk space

## Quick Start (20 minutes)

### 1. Install K3s with Cilium CNI

**Linux/macOS (Bare Metal K3s):**
```bash
cd monad-indexer/infrastructure
sudo ./k3s-install.sh

# Script will:
# - Check kernel version (requires 5.10+)
# - Verify eBPF support
# - Install K3s without Flannel/kube-proxy
# - Install Cilium CLI
# - Deploy Cilium CNI with production config
# - Optionally run connectivity test

# Export KUBECONFIG
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**Docker Desktop (for macOS development):**
```bash
# Settings → Kubernetes → Enable Kubernetes
# Wait for "Kubernetes is running" status
kubectl cluster-info

# Install Cilium manually
# Note: For local dev, Cilium can use values.yaml directly
# External Secrets is optional for dev environments

# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-amd64.tar.gz{,.sha256sum}
shasum -a 256 -c cilium-darwin-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-darwin-amd64.tar.gz /usr/local/bin
rm cilium-darwin-amd64.tar.gz{,.sha256sum}

# Install Cilium with production configuration
# For dev, values.yaml works fine (production-optimized but works for dev too)
helm repo add cilium https://helm.cilium.io/
helm repo update

# Option 1: With External Secrets (recommended, same as production)
# First setup External Secrets for API server IP
kubectl apply -f infrastructure/helm/cilium/api-server-config-secret.yaml
# Then install Cilium
helm install cilium cilium/cilium \
  --version 1.19.0-pre.1 \
  --namespace kube-system \
  -f infrastructure/helm/cilium/values.yaml

# Option 2: Without External Secrets (quick dev setup)
# Get API server IP manually
API_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
helm install cilium cilium/cilium \
  --version 1.19.0-pre.1 \
  --namespace kube-system \
  -f infrastructure/helm/cilium/values.yaml \
  --set k8sServiceHostRef=null \
  --set k8sServicePortRef=null \
  --set k8sServiceHost=${API_IP} \
  --set k8sServicePort=6443

# Verify Cilium
cilium status
```

### 2. Deploy LoadBalancer IP Pool

```bash
# Apply LoadBalancer IP pool for bare metal
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml

# Verify IP pool
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

### 3. Install Operators

```bash
cd monad-indexer

# Install CloudNativePG
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml

# Wait for operator
kubectl wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=120s
```

### 3. Deploy Development Environment

```bash
# Update Helm dependencies
cd charts/monad-indexer
helm dependency update

# Install with dev configuration
helm install monad-indexer . \
  -f values.yaml \
  -f environments/values-dev.yaml \
  -n monad-indexer-dev \
  --create-namespace \
  --wait \
  --timeout 10m
```

### 4. Verify Deployment

```bash
# Check all pods running
kubectl get pods -n monad-indexer-dev

# Expected output:
# NAME                                      READY   STATUS    RESTARTS   AGE
# monad-indexer-backend-xxx                 1/1     Running   0          2m
# monad-indexer-postgresql-1                1/1     Running   0          3m
# monad-indexer-pooler-rw-xxx              1/1     Running   0          2m
# monad-indexer-redis-master-0             1/1     Running   0          3m
# monad-indexer-smart-contract-verifier-xxx 1/1     Running   0          2m
```

### 5. Access Application

```bash
# Port forward to backend
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-dev

# Test API (in another terminal)
curl http://localhost:4000/api/v2/stats
```

## Configuration

### Update RPC Endpoint

Edit `charts/monad-indexer/environments/values-dev.yaml`:

```yaml
backend:
  env:
    ETHEREUM_JSONRPC_HTTP_URL: "https://your-rpc-endpoint"
    ETHEREUM_JSONRPC_WS_URL: "wss://your-rpc-endpoint"
    CHAIN_ID: "10143"
```

Apply changes:

```bash
helm upgrade monad-indexer . \
  -f values.yaml \
  -f environments/values-dev.yaml \
  -n monad-indexer-dev
```

## Common Tasks

### View Logs

```bash
# Backend logs
kubectl logs -f deployment/monad-indexer-backend -n monad-indexer-dev

# PostgreSQL logs
kubectl logs -f monad-indexer-postgresql-1 -n monad-indexer-dev

# All pods
kubectl logs -l app.kubernetes.io/name=monad-indexer -n monad-indexer-dev --tail=100
```

### Database Access

```bash
# Connect to database
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-dev -- \
  psql -U blockscout -d blockscout

# Example queries
SELECT COUNT(*) FROM blocks;
SELECT MAX(number) FROM blocks;
```

### Restart Services

```bash
# Restart backend
kubectl rollout restart deployment/monad-indexer-backend -n monad-indexer-dev

# Restart all
kubectl rollout restart deployment -n monad-indexer-dev
```

### Scale Backend

```bash
# Scale to 2 replicas
kubectl scale deployment/monad-indexer-backend --replicas=2 -n monad-indexer-dev
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod <pod-name> -n monad-indexer-dev

# Common fixes:
# 1. Insufficient resources → Close other apps
# 2. Image pull error → Check internet connection
# 3. Init container failing → Check logs
```

### Database Connection Errors

```bash
# Check PostgreSQL status
kubectl get cluster -n monad-indexer-dev

# Should show: "Cluster in healthy state"

# Check pooler
kubectl get pods -l cnpg.io/poolerName=monad-indexer-pooler -n monad-indexer-dev
```

### Port Already in Use

```bash
# Kill existing port-forward
pkill -f "port-forward.*4000"

# Use different local port
kubectl port-forward svc/monad-indexer-backend 4001:4000 -n monad-indexer-dev
```

### Cilium Issues

**Pods stuck in "ContainerCreating":**
```bash
# Check Cilium status
cilium status

# View Cilium logs
kubectl logs -n kube-system ds/cilium-agent --tail=50

# Restart Cilium if needed
kubectl rollout restart ds/cilium-agent -n kube-system

# Wait for Cilium to be ready
cilium status --wait
```

**NetworkPolicy blocking traffic:**
```bash
# Check if Cilium policies are blocking connections
cilium monitor --type drop

# Temporarily disable NetworkPolicies for debugging
kubectl delete networkpolicy --all -n monad-indexer-dev

# Re-enable after debugging
helm upgrade monad-indexer . \
  -f values.yaml \
  -f environments/values-dev.yaml \
  -n monad-indexer-dev
```

**Enable/Disable Hubble (observability):**
```bash
# Enable Hubble for debugging network issues
helm upgrade cilium cilium/cilium \
  --version 1.19.0-pre.1 \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --reuse-values

# Access Hubble UI
cilium hubble port-forward &
hubble status

# Open UI in browser
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Disable Hubble to restore performance
helm upgrade cilium cilium/cilium \
  --version 1.19.0-pre.1 \
  --namespace kube-system \
  --set hubble.enabled=false \
  --reuse-values
```

**Service not accessible:**
```bash
# Verify service endpoints
kubectl get endpoints -n monad-indexer-dev

# Check Cilium service resolution
cilium service list | grep monad-indexer

# Test connectivity from pod
kubectl run -it --rm debug --image=nicolaka/netshoot -n monad-indexer-dev -- /bin/bash
# Inside pod:
curl http://monad-indexer-backend:4000/api/v2/stats
```

## Cleanup

### Remove Deployment

```bash
# Delete everything
helm uninstall monad-indexer -n monad-indexer-dev

# Delete namespace (optional)
kubectl delete namespace monad-indexer-dev

# Delete operators (optional)
kubectl delete namespace cnpg-system
```

### Reset Kubernetes

**Docker Desktop:**
```bash
# Settings → Kubernetes → Reset Kubernetes Cluster
```

**K3s:**
```bash
/usr/local/bin/k3s-uninstall.sh
```

## Development Workflow

### 1. Make Configuration Changes

Edit files in `charts/monad-indexer/environments/values-dev.yaml`

### 2. Update Deployment

```bash
helm upgrade monad-indexer charts/monad-indexer \
  -f charts/monad-indexer/values.yaml \
  -f charts/monad-indexer/environments/values-dev.yaml \
  -n monad-indexer-dev
```

### 3. Test Changes

```bash
# Watch pod rollout
kubectl get pods -n monad-indexer-dev -w

# Check logs
kubectl logs -f deployment/monad-indexer-backend -n monad-indexer-dev
```

### 4. Verify API

```bash
curl http://localhost:4000/api/v2/stats | jq
```

## Resource Usage (Development)

| Component | CPU | Memory |
|-----------|-----|--------|
| Backend | 500m | 1Gi |
| PostgreSQL | 1000m | 4Gi |
| Redis | 250m | 512Mi |
| Verifier | 500m | 512Mi |
| **Total** | ~2.5 CPU | ~6GB RAM |

## Next Steps

- **Production Deployment**: See `docs/01-installation.md`
- **Scaling Guide**: See `docs/02-scaling-guide.md`
- **Troubleshooting**: See `docs/04-troubleshooting.md`

## Quick Reference

```bash
# Status check
kubectl get all -n monad-indexer-dev

# Logs
kubectl logs -l app.kubernetes.io/name=monad-indexer -n monad-indexer-dev --tail=50

# Port forward
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-dev

# Restart
kubectl rollout restart deployment/monad-indexer-backend -n monad-indexer-dev

# Uninstall
helm uninstall monad-indexer -n monad-indexer-dev
```

---

**Need help?** Check `docs/04-troubleshooting.md` or open an issue.
