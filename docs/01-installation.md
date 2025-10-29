# Installation Guide - Monad Indexer

Complete step-by-step guide for installing the Monad blockchain indexer infrastructure.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Infrastructure Setup](#infrastructure-setup)
3. [ArgoCD Installation](#argocd-installation)
4. [Operators Installation](#operators-installation)
   - [CloudNativePG Operator](#install-cloudnativepg-operator)
   - [External Secrets Operator](#install-external-secrets-operator)
   - [Gateway API (Cilium Native Ingress)](#configure-gateway-api-cilium-native-ingress)
5. [Helm Chart Deployment](#helm-chart-deployment)
6. [Verification](#verification)
7. [Next Steps](#next-steps)

## Prerequisites

### Hardware Requirements

**Minimum (Development)**:
- 1 server: 8 CPU, 16GB RAM, 200GB SSD
- Monthly cost: ~$50-100

**Recommended (Production)**:
- 3 servers: 16 CPU, 64GB RAM, 2TB NVMe each
- Monthly cost: ~$600-1500

### Software Requirements

- **Linux** (Ubuntu 22.04 LTS recommended)
  - Kernel 5.10+ (for Cilium eBPF support, Ubuntu 22.04 has 5.15+)
- **Kubernetes** 1.25+ (we'll install K3s)
- **Helm** 3.12+
- **kubectl**
- **Git**

## Infrastructure Setup

### Step 1: Install K3s + Cilium CNI

On your bare metal server(s):

```bash
# Clone repository
git clone https://github.com/hoodrunio/monad-indexer
cd monad-indexer

# Run K3s + Cilium installation
sudo ./infrastructure/k3s-install.sh
```

This script will:
- Check kernel version and eBPF support
- Install K3s without Flannel/kube-proxy (Cilium will replace them)
- Install Cilium CLI
- Deploy Cilium CNI with production-optimized configuration
- Configure local-path-provisioner for storage
- Optionally run connectivity tests

**Why Cilium?**
- 41% better throughput vs Flannel (9.2 Gbps vs 6.5 Gbps)
- 50% lower latency (0.20ms vs 0.40ms)
- Native NetworkPolicy support (Flannel doesn't support it)
- Integrated LoadBalancer for bare metal (replaces MetalLB)
- See `docs/CILIUM.md` for detailed guide

**Verify installation**:

```bash
# Export KUBECONFIG
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Check K3s nodes
kubectl get nodes

# Check Cilium status
cilium status

# All components should show "OK"
# Cilium agent pods should be Running
kubectl get pods -n kube-system -l k8s-app=cilium
```

**Deploy LoadBalancer IP Pool**:

```bash
# Apply LoadBalancer IP pool for bare metal
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml

# Verify
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

### Step 2: Configure kubectl (if remote)

If installing from your local machine to a remote server:

```bash
# Copy kubeconfig from server
scp root@your-server:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Edit config to use server IP
sed -i 's/127.0.0.1/YOUR_SERVER_IP/g' ~/.kube/config

# Test connection
kubectl get nodes
```

## ArgoCD Installation

### Install ArgoCD

```bash
./infrastructure/argocd-install.sh
```

This will:
- Install ArgoCD in HA mode (3 replicas)
- Create argocd namespace
- Display admin credentials

**Access ArgoCD UI**:

```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Visit https://localhost:8080
# Username: admin
# Password: (displayed by install script)
```

### Install ArgoCD CLI (Optional but Recommended)

```bash
# macOS
brew install argocd

# Linux
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Login
argocd login localhost:8080
```

## Operators Installation

### Install CloudNativePG Operator

```bash
./infrastructure/cloudnativepg-operator-install.sh
```

This operator manages PostgreSQL clusters with:
- Automatic failover
- Streaming replication
- Backup/restore with pgBackRest
- Connection pooling with PgBouncer

**Verify**:

```bash
kubectl get pods -n cnpg-system
```

### Install cert-manager

```bash
./infrastructure/cert-manager-install.sh
```

This operator automates TLS certificate management with:
- Automatic certificate issuance from Let's Encrypt
- Automatic certificate renewal (every 90 days)
- HTTP-01 and DNS-01 challenge support
- Integration with Ingress resources

**Verify**:

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
```

### Install External Secrets Operator

```bash
./infrastructure/external-secrets-operator-install.sh
```

This operator synchronizes secrets from external stores (AWS Secrets Manager, Vault, etc.).

**Verify**:

```bash
kubectl get pods -n external-secrets-system
```

### Configure AWS Secrets

For detailed secrets management, see [secrets-management.md](secrets-management.md).

**Quick setup**:

```bash
# 1. Create AWS secret with credentials
make create-aws-secret ENV=prod

# 2. Create AWS credentials in Kubernetes
make create-aws-credentials-secret ENV=prod

# 3. Verify SecretStore is ready (created by Helm chart)
make verify-secrets ENV=prod
```

The Helm chart automatically creates:
- **SecretStore**: Connects to AWS Secrets Manager
- **ExternalSecrets**: Syncs credentials to Kubernetes Secrets
- **Kubernetes Secrets**: Auto-generated with correct formats

### Configure Gateway API (Cilium Native Ingress)

Gateway API is already enabled in Cilium. No separate ingress controller needed!

**Verify Gateway API is ready**:

```bash
# Check Gateway API CRDs
kubectl get crd | grep gateway

# Check GatewayClass
kubectl get gatewayclass

# Check LoadBalancer IP pool
kubectl get ciliumloadbalancerippool
```

**For detailed Gateway API setup, see [GATEWAY-API.md](GATEWAY-API.md).**

## Helm Chart Deployment

### Option A: GitOps Deployment (Recommended)

1. **Fork and customize the repository**:

```bash
git clone https://github.com/hoodrunio/monad-indexer-gitops
cd monad-indexer-gitops
```

2. **Update configuration**:

Edit `argocd/applications/monad-indexer-production.yaml`:

```yaml
source:
  repoURL: https://github.com/hoodrunio/monad-indexer  # Update this
```

Edit `charts/monad-indexer/environments/values-production.yaml`:

```yaml
backend:
  env:
    ETHEREUM_JSONRPC_HTTP_URL: "https://your-rpc-endpoint"  # Update this
    CHAIN_ID: "10143"

postgresql:
  backup:
    barmanObjectStore:
      destinationPath: "s3://your-bucket/backups"  # Update this
```

3. **Commit and push**:

```bash
git add .
git commit -m "Configure Monad indexer"
git push
```

4. **Deploy root application**:

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

This will automatically deploy all environments:
- `monad-indexer-dev` (auto-sync enabled)
- `monad-indexer-staging` (auto-sync enabled)
- `monad-indexer-production` (manual sync required)

5. **Sync production application**:

```bash
# Via CLI
argocd app sync monad-indexer-production

# Or via UI
# Navigate to https://localhost:8080
# Click on "monad-indexer-production"
# Click "Sync"
```

### Option B: Direct Helm Installation

If you prefer not to use ArgoCD:

```bash
cd charts/monad-indexer

# Add Helm dependencies
helm dependency update

# Install for production
helm install monad-indexer . \
  -f values.yaml \
  -f environments/values-production.yaml \
  -n monad-indexer-prod \
  --create-namespace \
  --wait
```

## Verification

### Check All Pods are Running

```bash
kubectl get pods -n monad-indexer-prod
```

Expected output:

```
NAME                                      READY   STATUS    RESTARTS   AGE
monad-indexer-backend-xxx                 1/1     Running   0          5m
monad-indexer-backend-xxx                 1/1     Running   0          5m
monad-indexer-postgresql-1                1/1     Running   0          5m
monad-indexer-postgresql-2                1/1     Running   0          5m
monad-indexer-postgresql-3                1/1     Running   0          5m
monad-indexer-pooler-rw-xxx              1/1     Running   0          5m
monad-indexer-smart-contract-verifier-xxx 1/1     Running   0          5m
monad-indexer-sig-provider-xxx           1/1     Running   0          5m
monad-indexer-redis-master-0             1/1     Running   0          5m
monad-indexer-redis-replicas-0           1/1     Running   0          5m
```

### Check PostgreSQL Cluster

```bash
kubectl get cluster -n monad-indexer-prod
```

Expected output:

```
NAME                       AGE    INSTANCES   READY   STATUS                     PRIMARY
monad-indexer-postgresql   5m     3           3       Cluster in healthy state   monad-indexer-postgresql-1
```

### Check Database Connectivity

**Option 1: Via Gateway (if configured)**

```bash
# Test API via Gateway
curl https://indexer.monad.example.com/api/v2/stats | jq
```

**Option 2: Via Port Forward**

```bash
# Port forward to backend
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-prod

# Test API
curl http://localhost:4000/api/v2/stats | jq
```

Expected output:

```json
{
  "total_blocks": "0",
  "total_transactions": "0",
  "total_addresses": "0",
  ...
}
```

### Check Logs

```bash
# Backend logs
kubectl logs -f deployment/monad-indexer-backend -n monad-indexer-prod

# PostgreSQL logs
kubectl logs -f monad-indexer-postgresql-1 -n monad-indexer-prod
```

### Check Monitoring

```bash
# List ServiceMonitors
kubectl get servicemonitor -n monad-indexer-prod

# Check Prometheus targets (if Prometheus installed)
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring
# Visit http://localhost:9090/targets
```

## Next Steps

### 1. Configure Backup Destination

Update S3 credentials for PostgreSQL backups:

```bash
# Create secret with AWS credentials
kubectl create secret generic postgres-backup-creds \
  --from-literal=ACCESS_KEY_ID=YOUR_ACCESS_KEY \
  --from-literal=SECRET_ACCESS_KEY=YOUR_SECRET_KEY \
  -n monad-indexer-prod
```

### 2. Set Up Monitoring

See [03-monitoring.md](03-monitoring.md) for:
- Installing Prometheus + Grafana
- Importing dashboards
- Configuring alerts

### 3. Configure Gateway with TLS

Gateway API is already configured with automatic HTTPS via cert-manager.

**To expose your domain**:

1. Update DNS A record to point to your cluster IP
2. Update domain in `values-production.yaml`:
```yaml
gateway:
  enabled: true
  hosts:
    - host: indexer.monad.example.com
```

3. Deploy Gateway resources:
```bash
argocd app sync gateway-api-production
```

**Verify certificate**:

```bash
kubectl get certificate -n monad-indexer-prod
kubectl get gateway -n monad-indexer-prod
```

**For detailed Gateway setup, see [GATEWAY-API-DEPLOYMENT.md](GATEWAY-API-DEPLOYMENT.md).**

### 4. Test Failover

See [04-ha-testing.md](04-ha-testing.md) for:
- Simulating pod failures
- Testing database failover
- Validating PodDisruptionBudgets

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod <pod-name> -n monad-indexer-prod

# Check logs
kubectl logs <pod-name> -n monad-indexer-prod
```

Common issues:
- **ImagePullBackOff**: Check image name and registry credentials
- **CrashLoopBackOff**: Check logs for application errors
- **Pending**: Check resource availability and node selectors

### Database Connection Issues

```bash
# Test connection from backend pod
kubectl exec -it deployment/monad-indexer-backend -n monad-indexer-prod -- \
  psql -h monad-indexer-pooler-rw -U blockscout -d blockscout

# Check PgBouncer status
kubectl logs deployment/monad-indexer-pooler-rw -n monad-indexer-prod
```

### ArgoCD Sync Issues

```bash
# Check application status
argocd app get monad-indexer-production

# View sync errors
argocd app sync monad-indexer-production --dry-run

# Force sync (if needed)
argocd app sync monad-indexer-production --force
```

## Summary

You now have:

✅ K3s Kubernetes cluster running
✅ ArgoCD for GitOps deployments
✅ CloudNativePG operator for PostgreSQL management
✅ cert-manager for automatic TLS certificate management
✅ External Secrets Operator for secrets management
✅ Monad indexer deployed with full HA
✅ Monitoring and alerting configured

**Next**: Proceed to [02-scaling-guide.md](02-scaling-guide.md) to learn how to scale your deployment.
