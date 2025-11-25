# Gateway API Deployment Guide

Step-by-step guide to deploy Cilium Gateway API for monad-indexer.

## Prerequisites Check

Before starting, verify:

```bash
# 1. Cluster is accessible
kubectl cluster-info

# 2. ArgoCD is installed and accessible
argocd version

# 3. cert-manager is installed
kubectl get pods -n cert-manager

# 4. DNS A record is configured
dig monad-mainnet-indexer.hoodscan.io +short
# Should return: 95.216.177.23
```

## Deployment Steps

### Phase 1: Update Cilium Configuration (2-3 minutes)

Enable Gateway API and Envoy in Cilium.

```bash
# 1. Verify current Cilium status
cilium status

# 2. Sync Cilium via ArgoCD (picks up new values-production.yaml)
argocd app sync cilium --prune

# 3. Wait for Cilium to be ready
cilium status --wait

# 4. Verify Envoy pods are running
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy

# Expected output:
# NAME                  READY   STATUS    RESTARTS   AGE
# cilium-envoy-xxxxx    1/1     Running   0          2m

# 5. Verify Gateway API CRDs are installed
kubectl get crd | grep gateway
# Expected: gatewayclasses.gateway.networking.k8s.io
#           gateways.gateway.networking.k8s.io
#           httproutes.gateway.networking.k8s.io
```

**Troubleshooting**:
- If Envoy pods don't start: Check Cilium logs `kubectl logs -n kube-system ds/cilium-agent`
- If CRDs not installed: Verify `gatewayAPI.installCRDs: true` in values-production.yaml

### Phase 2: Update LoadBalancer IP Pool (1 minute)

Update Cilium LoadBalancer IP pool to include public IP.

```bash
# 1. Sync LoadBalancer IP pool via ArgoCD
argocd app sync cilium-lb-ippool

# 2. Verify IP pools exist
kubectl get ciliumloadbalancerippool
# Expected:
# NAME                          DISABLED   CONFLICTING   AGE
# monad-indexer-public-pool     false      False         1m
# monad-indexer-internal-pool   false      False         1m

# 3. Verify L2 announcement policy
kubectl get ciliuml2announcementpolicy
# Expected:
# NAME                      AGE
# monad-indexer-l2-policy   1m

# 4. Check IP pool details
kubectl describe ciliumloadbalancerippool monad-indexer-public-pool
```

**Troubleshooting**:
- If pools don't exist: Manually apply `kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml`

### Phase 3: Deploy Gateway API Infrastructure (1 minute)

Deploy GatewayClass (cluster-scoped resource).

```bash
# 1. Apply ArgoCD application for Gateway API infrastructure
kubectl apply -f argocd/applications/infrastructure-gateway.yaml

# 2. Sync Gateway API infrastructure
argocd app sync gateway-api-infrastructure

# 3. Verify GatewayClass exists
kubectl get gatewayclass
# Expected:
# NAME     CONTROLLER                      ACCEPTED   AGE
# cilium   io.cilium/gateway-controller    True       1m

# 4. Verify GatewayClass is accepted
kubectl describe gatewayclass cilium
```

**Troubleshooting**:
- If GatewayClass not accepted: Check Cilium operator logs `kubectl logs -n kube-system -l io.cilium/app=operator`

### Phase 4: Update cert-manager ClusterIssuer (30 seconds)

Update ClusterIssuer to support Gateway API HTTP-01 solver.

```bash
# 1. Apply updated ClusterIssuer
kubectl apply -f infrastructure/cert-manager-clusterissuer.yaml

# 2. Verify ClusterIssuers
kubectl get clusterissuer
# Expected:
# NAME                  READY   AGE
# letsencrypt-staging   True    5m
# letsencrypt-prod      True    5m

# 3. Check ClusterIssuer details
kubectl describe clusterissuer letsencrypt-prod
```

**Troubleshooting**:
- If ClusterIssuer not ready: Check cert-manager logs `kubectl logs -n cert-manager deploy/cert-manager`

### Phase 5: Deploy Gateway and Certificate (2-3 minutes)

Deploy dev environment Gateway and Certificate.

> Not: Argo CD senkronizasyonunda sırasıyla `ReferenceGrant`/`Certificate` (`sync-wave: -1`), HTTP-only Gateway (`gateway-http.yaml`, `sync-wave: -0.5`) ve en son HTTPS Gateway (`gateway.yaml`, `sync-wave: 0`) uygulanır. `Certificate` manifestlerindeki `cert-manager.io/issue-temporary-certificate` ve `acme.cert-manager.io/http01-edit-in-place` anotasyonlarıyla cert-manager geçici bir Secret üretir; HTTP-only Gateway ise ACME trafiğini taşıdığı için Cilium'un `listener-insecure` bug'ı tetiklenmez.

```bash
# 1. Sync Gateway API dev environment
argocd app sync gateway-api-dev

# 2. Verify namespace exists
kubectl get namespace monad-indexer-dev

# 3. Verify Gateway exists and gets IP
kubectl get gateway -n monad-indexer-dev
# Expected:
# NAME                      CLASS    ADDRESS         PROGRAMMED   AGE
# monad-indexer-http-gateway   cilium   95.216.177.23   True         1m
# monad-indexer-gateway        cilium   95.216.177.23   True         1m

# 4. Check Gateway status details
kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev

# 5. Verify HTTP Gateway status
kubectl describe gateway monad-indexer-http-gateway -n monad-indexer-dev

# 6. Verify HTTPS Gateway listeners are ready
kubectl get gateway monad-indexer-gateway -n monad-indexer-dev \
  -o jsonpath='{.status.listeners[*].conditions[*].message}'

# 7. Verify Certificate is being requested
kubectl get certificate -n monad-indexer-dev
# Expected (initially):
# NAME                        READY   SECRET                      AGE
# monad-tn1-indexer-tls      False   monad-tn1-indexer-tls       30s

# 8. Wait for certificate to be issued (1-2 minutes)
kubectl wait --for=condition=Ready certificate/monad-tn1-indexer-tls \
  -n monad-indexer-dev --timeout=5m

# 9. Verify certificate is ready
kubectl get certificate -n monad-indexer-dev
# Expected (after ~2 min):
# NAME                        READY   SECRET                      AGE
# monad-tn1-indexer-tls      True    monad-tn1-indexer-tls       2m
```

**Troubleshooting**:
- **Gateway not getting IP**:
  ```bash
  # Check LoadBalancer service
  kubectl get svc -n monad-indexer-dev -l gateway=monad-indexer

  # Check Cilium logs
  kubectl logs -n kube-system ds/cilium-agent | grep -i "loadbalancer\|ipam"
  ```

- **Certificate stuck in pending**:
  ```bash
  # Check Certificate details
  kubectl describe certificate monad-tn1-indexer-tls -n monad-indexer-dev

  # Check challenges
  kubectl get challenges -n monad-indexer-dev
  kubectl describe challenges -n monad-indexer-dev

  # Check challenge pods
  kubectl get pods -n monad-indexer-dev -l acme.cert-manager.io/http01-solver=true
  kubectl logs -n monad-indexer-dev -l acme.cert-manager.io/http01-solver=true
  ```

### Phase 6: Deploy Application with HTTPRoute (2-3 minutes)

Deploy monad-indexer application with HTTPRoute.

```bash
# 1. Sync monad-indexer dev environment
argocd app sync monad-indexer-dev

# 2. Wait for backend pods to be ready
kubectl get pods -n monad-indexer-dev -l app.kubernetes.io/name=monad-indexer
# Wait until STATUS is Running and READY is 1/1

# 3. Verify backend service exists
kubectl get svc monad-indexer-backend -n monad-indexer-dev

# 4. Verify backend service has endpoints
kubectl get endpoints monad-indexer-backend -n monad-indexer-dev

# 5. Verify HTTPRoute exists
kubectl get httproute -n monad-indexer-dev
# Expected:
# NAME                        HOSTNAMES                            PARENT REFS
# monad-indexer-backend       ["monad-mainnet-indexer.hoodscan.io"]   monad-indexer-gateway

# 6. Check HTTPRoute status
kubectl describe httproute monad-indexer-backend -n monad-indexer-dev

# 7. Verify HTTPRoute is attached to Gateway
kubectl get httproute monad-indexer-backend -n monad-indexer-dev \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True
```

**Troubleshooting**:
- **HTTPRoute not attached**:
  ```bash
  # Check HTTPRoute parent refs
  kubectl get httproute monad-indexer-backend -n monad-indexer-dev -o yaml

  # Verify Gateway name matches
  kubectl get gateway -n monad-indexer-dev
  ```

- **Backend pods not ready**:
  ```bash
  # Check pod status
  kubectl describe pod -n monad-indexer-dev -l app.kubernetes.io/name=monad-indexer

  # Check logs
  kubectl logs -n monad-indexer-dev -l app.kubernetes.io/name=monad-indexer --tail=50
  ```

### Phase 7: Verify Connectivity (1 minute)

Test end-to-end connectivity.

```bash
# 1. Check Gateway external IP
kubectl get gateway monad-indexer-gateway -n monad-indexer-dev \
  -o jsonpath='{.status.addresses[0].value}'
# Expected: 95.216.177.23

# 2. Test HTTP (should redirect to HTTPS)
curl -I http://monad-mainnet-indexer.hoodscan.io
# Expected: HTTP/1.1 301 Moved Permanently or 308 Permanent Redirect

# 3. Test HTTPS
curl -I https://monad-mainnet-indexer.hoodscan.io
# Expected: HTTP/2 200

# 4. Test API health endpoint
curl https://monad-mainnet-indexer.hoodscan.io/api/health/liveness
# Expected: {"healthy":true}

# 5. Verify TLS certificate
echo | openssl s_client -connect monad-mainnet-indexer.hoodscan.io:443 \
  -servername monad-mainnet-indexer.hoodscan.io 2>/dev/null | \
  openssl x509 -noout -issuer -dates
# Expected:
# issuer=C = US, O = Let's Encrypt, CN = R12
# notBefore=...
# notAfter=... (90 days from now)
```

**Troubleshooting**:
- **HTTP connection refused**:
  ```bash
  # Check if port 80 is accessible
  nc -zv 95.216.177.23 80

  # Check Gateway listeners
  kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev
  ```

- **HTTPS certificate error**:
  ```bash
  # Check certificate status
  kubectl get certificate -n monad-indexer-dev

  # Check certificate details
  kubectl describe certificate monad-tn1-indexer-tls -n monad-indexer-dev
  ```

- **502 Bad Gateway**:
  ```bash
  # Check backend pods are running
  kubectl get pods -n monad-indexer-dev -l app.kubernetes.io/name=monad-indexer

  # Check service endpoints
  kubectl get endpoints monad-indexer-backend -n monad-indexer-dev

  # Check Envoy logs
  kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy --tail=50
  ```

## Post-Deployment Verification

### Complete System Check

```bash
# Run this comprehensive check script
cat > /tmp/gateway-check.sh << 'EOF'
#!/bin/bash
set -e

echo "=== Cilium Gateway API Deployment Check ==="
echo ""

echo "1. Checking GatewayClass..."
kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' | grep -q "True" && echo "✓ GatewayClass accepted" || echo "✗ GatewayClass NOT accepted"
echo ""

echo "2. Checking Gateway..."
kubectl get gateway monad-indexer-gateway -n monad-indexer-dev -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' | grep -q "True" && echo "✓ Gateway programmed" || echo "✗ Gateway NOT programmed"
kubectl get gateway monad-indexer-gateway -n monad-indexer-dev -o jsonpath='{.status.addresses[0].value}' | grep -q "95.216.177.23" && echo "✓ Gateway has correct IP" || echo "✗ Gateway IP incorrect"
echo ""

echo "3. Checking Certificate..."
kubectl get certificate monad-tn1-indexer-tls -n monad-indexer-dev -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True" && echo "✓ Certificate ready" || echo "✗ Certificate NOT ready"
echo ""

echo "4. Checking HTTPRoute..."
kubectl get httproute monad-indexer-backend -n monad-indexer-dev -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -q "True" && echo "✓ HTTPRoute attached" || echo "✗ HTTPRoute NOT attached"
echo ""

echo "5. Checking Backend Service..."
kubectl get svc monad-indexer-backend -n monad-indexer-dev >/dev/null 2>&1 && echo "✓ Backend service exists" || echo "✗ Backend service NOT found"
ENDPOINTS=$(kubectl get endpoints monad-indexer-backend -n monad-indexer-dev -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w)
[ "$ENDPOINTS" -gt 0 ] && echo "✓ Backend has $ENDPOINTS endpoint(s)" || echo "✗ Backend has NO endpoints"
echo ""

echo "6. Testing HTTP connectivity..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://monad-mainnet-indexer.hoodscan.io || echo "000")
[ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ] && echo "✓ HTTP redirects to HTTPS (${HTTP_CODE})" || echo "✗ HTTP unexpected response (${HTTP_CODE})"
echo ""

echo "7. Testing HTTPS connectivity..."
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://monad-mainnet-indexer.hoodscan.io || echo "000")
[ "$HTTPS_CODE" = "200" ] && echo "✓ HTTPS returns 200 OK" || echo "✗ HTTPS unexpected response (${HTTPS_CODE})"
echo ""

echo "8. Checking TLS certificate..."
ISSUER=$(echo | openssl s_client -connect monad-mainnet-indexer.hoodscan.io:443 -servername monad-mainnet-indexer.hoodscan.io 2>/dev/null | openssl x509 -noout -issuer | grep "Let's Encrypt")
[ -n "$ISSUER" ] && echo "✓ TLS certificate issued by Let's Encrypt" || echo "✗ TLS certificate NOT from Let's Encrypt"
echo ""

echo "=== Deployment Check Complete ==="
EOF

chmod +x /tmp/gateway-check.sh
/tmp/gateway-check.sh
```

### Expected Output

```
=== Cilium Gateway API Deployment Check ===

1. Checking GatewayClass...
✓ GatewayClass accepted

2. Checking Gateway...
✓ Gateway programmed
✓ Gateway has correct IP

3. Checking Certificate...
✓ Certificate ready

4. Checking HTTPRoute...
✓ HTTPRoute attached

5. Checking Backend Service...
✓ Backend service exists
✓ Backend has 1 endpoint(s)

6. Testing HTTP connectivity...
✓ HTTP redirects to HTTPS (308)

7. Testing HTTPS connectivity...
✓ HTTPS returns 200 OK

8. Checking TLS certificate...
✓ TLS certificate issued by Let's Encrypt

=== Deployment Check Complete ===
```

## Monitoring Setup

After deployment, set up monitoring:

```bash
# 1. Verify Prometheus is scraping Envoy metrics
kubectl get servicemonitor -n kube-system -l app.kubernetes.io/name=cilium-envoy

# 2. Check Envoy metrics endpoint
kubectl port-forward -n kube-system svc/cilium-envoy-metrics 9964:9964
curl http://localhost:9964/stats/prometheus | grep envoy_http

# 3. Import Grafana dashboard for Envoy
# Dashboard ID: 11022
# Or use custom dashboard from docs/GATEWAY-API.md
```

## Rollback Plan

If you need to rollback:

```bash
# 1. Re-enable nginx-ingress in values-dev.yaml
# Edit: ingress.enabled: true, gateway.enabled: false

# 2. Sync application
argocd app sync monad-indexer-dev

# 3. Disable Gateway API in Cilium
argocd app set cilium --helm-set gatewayAPI.enabled=false --helm-set envoy.enabled=false
argocd app sync cilium

# 4. Delete Gateway resources
kubectl delete gateway monad-indexer-gateway -n monad-indexer-dev
kubectl delete gatewayclass cilium

# Total rollback time: ~3-5 minutes
```

## Summary

**Total deployment time**: 10-15 minutes

**Deployment order**:
1. Update Cilium with Gateway API (2-3 min)
2. Update LoadBalancer IP pool (1 min)
3. Deploy Gateway API infrastructure (1 min)
4. Update cert-manager ClusterIssuer (30 sec)
5. Deploy Gateway and Certificate (2-3 min)
6. Deploy application with HTTPRoute (2-3 min)
7. Verify connectivity (1 min)

**Success criteria**:
- ✓ Gateway gets IP: 95.216.177.23
- ✓ Certificate issued by Let's Encrypt
- ✓ HTTPRoute attached to Gateway
- ✓ HTTPS returns 200 OK
- ✓ TLS certificate valid

**Next steps**:
- Set up Grafana dashboards for monitoring
- Configure alerting for Gateway metrics
- Test performance vs nginx-ingress
- Document any environment-specific configurations
