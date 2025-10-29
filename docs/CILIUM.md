# Cilium CNI Guide - Monad Indexer

Comprehensive guide for Cilium Container Network Interface (CNI) in production.

## Table of Contents

- [Overview](#overview)
- [Why Cilium for Monad Indexer](#why-cilium-for-monad-indexer)
- [Architecture](#architecture)
- [Installation](#installation)
- [Configuration](#configuration)
- [NetworkPolicies](#networkpolicies)
- [LoadBalancer](#loadbalancer)
- [Monitoring & Observability](#monitoring--observability)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

---

## Overview

**Cilium** is an eBPF-based networking, observability, and security solution for cloud-native environments.

### Key Features for Monad Indexer

- **41% better throughput** vs Flannel (9.2 Gbps vs 6.5 Gbps)
- **50% lower latency** (0.20ms vs 0.40ms)
- **kube-proxy replacement** with eBPF for better scalability
- **Native NetworkPolicy support** (Flannel doesn't support it)
- **Integrated LoadBalancer** for bare metal (replaces MetalLB)
- **L3-L7 security policies** with identity-based enforcement
- **Hubble observability** for network visibility (optional)

### Version

- **Cilium**: 1.18.3
- **Kubernetes**: 1.24+
- **Kernel**: 5.10+ (Ubuntu 22.04 LTS: 5.15+)

---

## Why Cilium for Monad Indexer

### Performance Comparison

| Metric | Flannel (VXLAN) | Cilium (eBPF) | Improvement |
|--------|-----------------|---------------|-------------|
| **Throughput** | 6.5 Gbps | 9.2 Gbps | +41% |
| **Latency** | 0.40 ms | 0.20 ms | -50% |
| **CPU Overhead** | 2% | 7% | +5% (acceptable) |
| **TPS Capacity** | 5000 | 7000+ | +40% |
| **Scale Limit** | ~500 services | ~5000 services | 10x |

### Why It Matters for 5000 TPS Blockchain Indexer

1. **Database-Intensive Workload**
   - PostgreSQL cluster handles 5000+ TPS with heavy read/write
   - Lower latency = faster transaction processing
   - Reduced network overhead for backend → database connections

2. **High Connection Volume**
   - Backend pods (2-20 replicas) → PgBouncer → PostgreSQL
   - Redis Sentinel with high request rates
   - Cilium's socket-level forwarding eliminates full network stack traversal

3. **Microservices Architecture**
   - Multiple services with inter-pod communication
   - Flannel's iptables rules grow exponentially with endpoints
   - Cilium's eBPF maps scale linearly

4. **NetworkPolicy Requirement**
   - Security best practice for production deployments
   - Flannel doesn't support NetworkPolicies at all
   - Cilium provides L3/L4 and optionally L7 policies

### Trade-offs

**Pros:**
- ✅ Significantly better performance
- ✅ Production-proven with CloudNativePG, PostgreSQL, Redis
- ✅ Future-proof architecture (eBPF is industry standard)
- ✅ CNCF graduated project with strong community

**Cons:**
- ⚠️ 5% higher CPU overhead (worth it for 40% throughput gain)
- ⚠️ More complex than Flannel (but manageable with good docs)
- ⚠️ Requires kernel 5.10+ (Ubuntu 22.04+ is fine)

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    K3s Cluster (Bare Metal)                  │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────┐    ┌─────────────────┐                 │
│  │  Cilium Agent   │    │  Cilium Agent   │                 │
│  │   (DaemonSet)   │    │   (DaemonSet)   │                 │
│  │                 │    │                 │                 │
│  │  - eBPF Dataplane│   │  - eBPF Dataplane│                 │
│  │  - kube-proxy  │    │  - kube-proxy  │                 │
│  │    replacement  │    │    replacement  │                 │
│  │  - L2 LB       │    │  - L2 LB       │                 │
│  └────────┬────────┘    └────────┬────────┘                 │
│           │                      │                          │
│  ┌────────┴──────────────────────┴────────┐                 │
│  │      Cilium Operator (Deployment)      │                 │
│  │  - IPAM (10.42.0.0/16)                │                 │
│  │  - CRD management                      │                 │
│  │  - LoadBalancer IP allocation          │                 │
│  └────────────────────────────────────────┘                 │
│                                                               │
│  Optional:                                                   │
│  ┌────────────────────┐  ┌──────────────────┐               │
│  │   Hubble Relay     │  │   Hubble UI      │               │
│  │  (Observability)   │  │  (Web Interface) │               │
│  └────────────────────┘  └──────────────────┘               │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Data Plane: eBPF vs iptables

**Traditional (Flannel/kube-proxy):**
```
Pod → iptables → netfilter → routing → iptables → Pod
     (1000s of rules, linear search, kernel-userspace context switches)
```

**Cilium (eBPF):**
```
Pod → eBPF program → routing → eBPF program → Pod
     (hash maps, O(1) lookup, all in kernel space)
```

**Same-node optimization:**
```
Pod A → Cilium socket redirect → Pod B
     (direct socket forwarding, no network stack!)
```

### IP Addressing

- **Pod CIDR**: `10.42.0.0/16` (K3s default, ~65k pods)
- **Service CIDR**: `10.43.0.0/16` (K3s default)
- **LoadBalancer IP Pool**: `10.0.0.100/27` (32 IPs for external services)

---

## Installation

### Prerequisites Check

```bash
# 1. Kernel version
uname -r
# Must be 5.10+

# 2. eBPF support
grep CONFIG_BPF= /boot/config-$(uname -r)
# Should output: CONFIG_BPF=y

# 3. Required kernel modules
lsmod | grep -E 'bpf|xfrm'
```

### Method 1: Automated Script (Recommended)

```bash
cd monad-indexer/infrastructure
sudo ./k3s-install.sh

# Script performs:
# 1. Kernel version & eBPF check
# 2. K3s installation (--flannel-backend=none --disable-kube-proxy)
# 3. Cilium CLI installation
# 4. Cilium CNI deployment (production config)
# 5. Validation & connectivity test (optional)

# Export KUBECONFIG
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### Method 2: Manual Installation

**Step 1: Install K3s**

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable traefik \
  --disable servicelb \
  --kube-apiserver-arg "service-node-port-range=80-32767" \
  --cluster-init

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**Step 2: Install Cilium CLI**

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

**Step 3: Install Cilium CNI**

```bash
# Get API server IP
API_SERVER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Install with production configuration
cilium install \
  --version 1.18.3 \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set k8sServicePort=6443 \
  --set routingMode=native \
  --set loadBalancer.acceleration=native \
  --set loadBalancer.mode=hybrid \
  --set l2announcements.enabled=true \
  --set hubble.enabled=false \
  --set bpf.events.trace.enabled=false \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --wait
```

**Step 4: Validate Installation**

```bash
# Check Cilium status
cilium status

# Expected output:
#     /¯¯\
#  /¯¯\__/¯¯\    Cilium:             OK
#  \__/¯¯\__/    Operator:           OK
#  /¯¯\__/¯¯\    Envoy DaemonSet:    disabled (using native mode)
#  \__/¯¯\__/    Hubble Relay:       disabled
#     \__/       ClusterMesh:        disabled

# Run connectivity test (optional, 5-10 minutes)
cilium connectivity test
```

### Method 3: Helm (for GitOps with ArgoCD)

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

# Get API server IP
API_SERVER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Install with production values
helm install cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  -f infrastructure/helm/cilium/values-production.yaml \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set k8sServicePort=6443
```

### Multi-Node Cluster

**Master Node:** (already installed above)

**Worker Nodes:**

```bash
cd monad-indexer/infrastructure
sudo ./k3s-worker-install.sh

# Script will prompt for:
# - Master node IP
# - Node token (get from master: sudo cat /var/lib/rancher/k3s/server/node-token)

# Verify on master:
kubectl get nodes
# All nodes should show Ready status
```

---

## Configuration

### Production vs Development

**Production** (`infrastructure/helm/cilium/values-production.yaml`):
- Hubble: **disabled** (max performance)
- BPF trace events: **disabled**
- Resources: 4 CPU / 4GB RAM
- LoadBalancer: **enabled**
- Monitoring: **enabled**

**Development** (`infrastructure/helm/cilium/values-dev.yaml`):
- Hubble: **enabled** (debugging)
- BPF trace events: **enabled**
- Resources: 2 CPU / 2GB RAM
- LoadBalancer: **enabled**
- Monitoring: **optional**

### Key Configuration Options

#### 1. Kube-proxy Replacement

```yaml
kubeProxyReplacement: "true"  # CRITICAL for performance
k8sServiceHost: "10.0.0.1"    # API server IP (required when replacing kube-proxy)
k8sServicePort: "6443"
```

**Why it matters:**
- iptables-based kube-proxy has O(n) complexity
- Cilium eBPF service routing is O(1)
- 40% better throughput, 50% lower latency

#### 2. Routing Mode

```yaml
routingMode: "native"  # Best for bare metal
```

**Options:**
- `native`: Direct routing (no encapsulation) - **recommended for bare metal**
- `tunnel`: VXLAN/Geneve encapsulation - use if direct routing not possible

#### 3. IPAM (IP Address Management)

```yaml
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: "10.42.0.0/16"  # Match K3s pod CIDR
```

#### 4. BPF Tuning (for 5000 TPS)

```yaml
bpf:
  eventsQueueSize: 32768  # 2x default for high TPS
  ctMax: 524288           # Connection tracking table size
  natMax: 524288          # NAT table size
  events:
    trace:
      enabled: false      # Disable for production (saves 5-10% CPU)
```

#### 5. LoadBalancer

```yaml
loadBalancer:
  acceleration: "native"  # eBPF-accelerated
  mode: "hybrid"          # DSR (Direct Server Return) for better performance
  serviceTopology: true   # Prefer same-node backends

l2announcements:
  enabled: true           # Required for bare metal LoadBalancer
```

#### 6. Monitoring

```yaml
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus  # Match your Prometheus operator
```

### Update Configuration

```bash
# Edit values file
vim infrastructure/helm/cilium/values-production.yaml

# Apply changes
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  -f infrastructure/helm/cilium/values-production.yaml \
  --reuse-values

# Verify
cilium status
```

---

## NetworkPolicies

### Standard Kubernetes NetworkPolicies

Located in `charts/monad-indexer/templates/networkpolicies/`

**Example: Backend NetworkPolicy**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: monad-indexer-backend
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        # Allow from Cilium Gateway (Envoy proxy)
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: cilium-envoy
      ports:
        - protocol: TCP
          port: 4000
  egress:
    # Allow to PostgreSQL
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: monad-indexer
      ports:
        - protocol: TCP
          port: 5432
    # Allow to Redis
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: redis
      ports:
        - protocol: TCP
          port: 6379
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

### Cilium NetworkPolicies (Optional, Enhanced)

Enable in `values.yaml`:
```yaml
networkPolicies:
  enabled: true
  enableCiliumPolicies: true  # Opt-in for Cilium-specific features
```

**Advantages of CiliumNetworkPolicy:**
- **Identity-based** (pod labels persist across restarts, more resilient than IP-based)
- **DNS-aware** (allow traffic by FQDN: `s3.amazonaws.com`)
- **L7 policies** (HTTP method/path filtering - optional, has performance cost)
- **Better performance** (eBPF enforcement vs iptables)

**Example: PostgreSQL CiliumNetworkPolicy**
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: monad-indexer-postgresql
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: monad-indexer
  ingress:
    # Allow from backend
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/component: backend
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
  egress:
    # Allow replication
    - toEndpoints:
        - matchLabels:
            cnpg.io/cluster: monad-indexer
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
    # Allow DNS
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
```

### Testing NetworkPolicies

```bash
# Enable policy audit mode (logs but doesn't enforce)
cilium config set PolicyEnforcement=audit -n monad-indexer-prod

# Check logs for denials
kubectl logs -n kube-system ds/cilium-agent | grep "Policy verdict"

# Enable enforcement
cilium config set PolicyEnforcement=default -n monad-indexer-prod
```

---

## LoadBalancer

### IP Pool Configuration

**File:** `infrastructure/helm/cilium/lb-ippool.yaml`

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: monad-indexer-pool
spec:
  cidrs:
    - cidr: "10.0.0.100/27"  # 32 IPs: 10.0.0.100-131
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: monad-indexer
```

**Deploy IP pool:**
```bash
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml
```

### L2 Announcements (ARP/NDP)

Cilium announces LoadBalancer IPs via Layer 2 (ARP for IPv4, NDP for IPv6).

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: monad-indexer-l2-policy
spec:
  interfaces:
    - ^eth[0-9]+
    - ^ens[0-9]+
    - ^enp[0-9]+s[0-9]+
  loadBalancerIPs: true
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: monad-indexer
```

### Create LoadBalancer Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: monad-indexer-backend-lb
  labels:
    app.kubernetes.io/name: monad-indexer
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 4000
      protocol: TCP
  selector:
    app.kubernetes.io/component: backend
```

**Verify:**
```bash
kubectl get svc monad-indexer-backend-lb

# EXTERNAL-IP should show IP from pool (10.0.0.100-131)
# If <pending>, check:
# 1. IP pool exists: kubectl get ciliumloadbalancerippool
# 2. L2 policy exists: kubectl get ciliuml2announcementpolicy
# 3. Cilium logs: kubectl logs -n kube-system ds/cilium-agent | grep -i loadbalancer
```

---

## Monitoring & Observability

### Prometheus Metrics

**Cilium Agent Metrics:**
- `cilium_bpf_map_ops_total` - BPF map operations
- `cilium_datapath_errors_total` - Datapath errors
- `cilium_policy_l7_total` - L7 policy verdicts
- `cilium_endpoint_state` - Endpoint health
- `cilium_services_events_total` - Service events

**Query examples:**
```promql
# Service routing errors
rate(cilium_datapath_errors_total[5m])

# Policy drops
rate(cilium_drop_count_total{reason="Policy denied"}[5m])

# Endpoint count
sum(cilium_endpoint_state{state="ready"})
```

**Grafana Dashboards:**
- [Cilium Metrics](https://grafana.com/grafana/dashboards/16611)
- [Cilium Operator](https://grafana.com/grafana/dashboards/16612)

### Hubble Observability (Optional)

**Enable Hubble:**
```bash
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --reuse-values

# Wait for Hubble pods
kubectl wait --for=condition=Ready pod -l k8s-app=hubble-relay -n kube-system --timeout=120s
```

**Access Hubble CLI:**
```bash
# Port forward Hubble relay
cilium hubble port-forward &

# Check status
hubble status

# Observe flows
hubble observe

# Filter by namespace
hubble observe --namespace monad-indexer-prod

# Filter by pod
hubble observe --pod monad-indexer-backend

# Show drops
hubble observe --verdict DROPPED
```

**Access Hubble UI:**
```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open browser: http://localhost:12000
```

**Disable Hubble (restore performance):**
```bash
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --set hubble.enabled=false \
  --reuse-values
```

---

## Performance Tuning

### For 5000 TPS Blockchain Indexer

#### 1. BPF Map Sizes

```yaml
bpf:
  eventsQueueSize: 32768  # 2x default (16384)
  ctMax: 524288           # Connection tracking: 2x default
  natMax: 524288          # NAT table: same as default
```

**When to increase:**
- `eventsQueueSize`: If you see BPF event drops in metrics
- `ctMax`: If you have >100k concurrent connections
- `natMax`: If you have many Services with many pods

#### 2. Disable Unnecessary Features

```yaml
hubble:
  enabled: false  # Saves 5-10% CPU

bpf:
  events:
    trace:
      enabled: false  # Saves 5-10% CPU

debug:
  enabled: false  # Production should have this off
```

#### 3. Resource Limits

**Production (3-node cluster):**
```yaml
# Cilium Agent (per node)
resources:
  limits:
    cpu: 4000m
    memory: 4Gi
  requests:
    cpu: 1000m
    memory: 2Gi

# Cilium Operator (cluster-wide)
operator:
  replicas: 2  # HA
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 128Mi
```

#### 4. Bandwidth Manager (QoS)

```yaml
bandwidthManager:
  enabled: true
  bbr: true  # TCP BBR congestion control for better throughput
```

#### 5. BIG TCP (for 100Gbit+ networks)

```yaml
enableIPv4BIGTCP: true  # If you have high-bandwidth NICs
```

### Benchmarking

```bash
# Install netperf
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/main/examples/kubernetes/netperf/netperf.yaml

# Run benchmark
kubectl exec -it netperf-client -- netperf -H netperf-server -t TCP_STREAM

# Compare with baseline (before Cilium)
# Should see 40% improvement in throughput
```

---

## Troubleshooting

### 1. Pods Stuck in "ContainerCreating"

**Symptoms:**
```bash
kubectl get pods -n monad-indexer-prod
# monad-indexer-backend-xxx   0/1   ContainerCreating
```

**Diagnosis:**
```bash
kubectl describe pod monad-indexer-backend-xxx -n monad-indexer-prod
# Look for: "network is not ready"

cilium status
# Check if all components are OK
```

**Fix:**
```bash
# Restart Cilium
kubectl rollout restart ds/cilium-agent -n kube-system

# Wait for readiness
cilium status --wait

# Force recreate pod
kubectl delete pod monad-indexer-backend-xxx -n monad-indexer-prod
```

### 2. Service Not Accessible

**Symptoms:**
```bash
curl http://monad-indexer-backend:4000
# Connection refused or timeout
```

**Diagnosis:**
```bash
# Check service endpoints
kubectl get endpoints monad-indexer-backend -n monad-indexer-prod

# Check Cilium service resolution
cilium service list | grep monad-indexer

# Check if kube-proxy replacement is working
cilium status | grep "KubeProxyReplacement"
# Should show: Enabled
```

**Fix:**
```bash
# If kube-proxy replacement is missing k8sServiceHost
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --set k8sServiceHost=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') \
  --set k8sServicePort=6443 \
  --reuse-values

# Restart Cilium
kubectl rollout restart ds/cilium-agent -n kube-system
```

### 3. NetworkPolicy Blocking Traffic

**Symptoms:**
```bash
# Backend can't connect to PostgreSQL
kubectl logs -n monad-indexer-prod deployment/monad-indexer-backend
# "could not connect to server"
```

**Diagnosis:**
```bash
# Check policy drops
cilium monitor --type drop

# Check policy status
kubectl get networkpolicy -n monad-indexer-prod
kubectl describe networkpolicy monad-indexer-backend -n monad-indexer-prod
```

**Fix:**
```bash
# Temporarily disable policies for debugging
kubectl delete networkpolicy --all -n monad-indexer-prod

# Test connectivity
kubectl exec -it -n monad-indexer-prod deployment/monad-indexer-backend -- \
  nc -zv monad-indexer-pooler-rw 5432

# If works, re-enable policies and fix rules
helm upgrade monad-indexer charts/monad-indexer \
  -f charts/monad-indexer/values.yaml \
  -f charts/monad-indexer/environments/values-production.yaml \
  -n monad-indexer-prod
```

### 4. High CPU Usage on Cilium Agent

**Symptoms:**
```bash
kubectl top pods -n kube-system | grep cilium
# cilium-agent-xxx   2000m   3Gi
```

**Diagnosis:**
```bash
# Check if Hubble is enabled
kubectl get configmap cilium-config -n kube-system -o yaml | grep hubble

# Check if trace events are enabled
kubectl get configmap cilium-config -n kube-system -o yaml | grep trace
```

**Fix:**
```bash
# Disable Hubble and trace events
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --set hubble.enabled=false \
  --set bpf.events.trace.enabled=false \
  --reuse-values

# Restart Cilium
kubectl rollout restart ds/cilium-agent -n kube-system
```

### 5. LoadBalancer IP Stuck in Pending

**Symptoms:**
```bash
kubectl get svc monad-indexer-backend-lb -n monad-indexer-prod
# EXTERNAL-IP: <pending>
```

**Diagnosis:**
```bash
# Check IP pool
kubectl get ciliumloadbalancerippool

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy

# Check Cilium logs
kubectl logs -n kube-system ds/cilium-agent | grep -i loadbalancer
```

**Fix:**
```bash
# Create IP pool if missing
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml

# Restart service
kubectl delete svc monad-indexer-backend-lb -n monad-indexer-prod
kubectl apply -f <service-manifest>
```

### 6. Connectivity Test Failures

**Symptoms:**
```bash
cilium connectivity test
# Some tests fail
```

**Common Failures:**
- `pod-to-world`: DNS or external connectivity issue
- `pod-to-pod`: NetworkPolicy or routing issue
- `service`: kube-proxy replacement issue

**Fix:**
```bash
# Check Cilium status
cilium status

# View detailed logs
kubectl logs -n kube-system ds/cilium-agent --tail=100

# Check NetworkPolicies
kubectl get networkpolicy --all-namespaces

# If DNS fails, check coredns
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

---

## Maintenance

### Upgrade Cilium

```bash
# Check current version
cilium version

# Upgrade with Helm
helm repo update
helm upgrade cilium cilium/cilium \
  --version 1.19.0 \
  --namespace kube-system \
  --reuse-values

# Verify upgrade
cilium status
cilium connectivity test
```

### Backup Configuration

```bash
# Backup Cilium config
kubectl get configmap cilium-config -n kube-system -o yaml > cilium-config-backup.yaml

# Backup custom policies
kubectl get ciliumnetworkpolicies -A -o yaml > cilium-policies-backup.yaml

# Backup IP pools
kubectl get ciliumloadbalancerippool -o yaml > cilium-ippools-backup.yaml
```

### Rollback

```bash
# Rollback Helm release
helm rollback cilium -n kube-system

# Or reinstall specific version
helm upgrade cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --reuse-values
```

### Uninstall

```bash
# Uninstall Cilium
cilium uninstall

# Or with Helm
helm uninstall cilium -n kube-system

# Clean up CRDs (optional, be careful!)
kubectl delete crds -l app.kubernetes.io/name=cilium
```

---

## Best Practices

### 1. Always Use kube-proxy Replacement

```yaml
kubeProxyReplacement: "true"
k8sServiceHost: "<API_SERVER_IP>"
k8sServicePort: "6443"
```

This provides 40% better throughput.

### 2. Disable Hubble in Production

Enable Hubble only for debugging specific issues, then disable it:
```yaml
hubble:
  enabled: false  # Saves 5-10% CPU
```

### 3. Use Native Routing on Bare Metal

```yaml
routingMode: "native"
```

No encapsulation overhead (VXLAN/Geneve adds ~5% latency).

### 4. Monitor Cilium Metrics

Set up Prometheus alerts for:
- `cilium_datapath_errors_total` (should be 0)
- `cilium_endpoint_state{state!="ready"}` (should be 0)
- `cilium_policy_l7_denied_total` (unexpected denials)

### 5. Test NetworkPolicies in Audit Mode

```bash
cilium config set PolicyEnforcement=audit
# Test your app
cilium config set PolicyEnforcement=default
```

### 6. Use CiliumNetworkPolicy for Better Performance

If you're on Cilium anyway, use CiliumNetworkPolicy instead of standard NetworkPolicy:
- Better performance (eBPF vs iptables)
- More features (DNS-aware, identity-based)
- More resilient (labels persist across pod restarts)

---

## References

- [Cilium Documentation](https://docs.cilium.io/)
- [Cilium Performance Guide](https://docs.cilium.io/en/stable/operations/performance/)
- [CloudNativePG + Cilium](https://cloudnative-pg.io/documentation/current/networking/)
- [K3s + Cilium](https://docs.cilium.io/en/stable/installation/k3s/)
- [eBPF Introduction](https://ebpf.io/)

---

**Version**: 1.0
**Last Updated**: 2025-10-28
**Cilium Version**: 1.18.3
