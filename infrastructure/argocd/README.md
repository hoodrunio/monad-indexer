# ArgoCD Configuration

## Overview

ArgoCD is configured with Cilium Gateway API for external access, supporting both Web UI and CLI access through the same domain using intelligent HTTP/gRPC routing.

- **Web UI**: Accessible via Gateway at https://cd.hoodscan.io
- **CLI**: Accessible via Gateway at https://cd.hoodscan.io (same domain)

## Architecture

### Gateway API HTTP/gRPC Routing

The Gateway API HTTPRoute intelligently routes traffic based on request headers:

- **HTTP Traffic** (Web UI): Routed to `argocd-server-http` service
- **gRPC Traffic** (CLI): Routed to `argocd-server-grpc` service with h2c protocol

Both services point to the same ArgoCD server pods (port 8080), which serve both HTTP and gRPC protocols simultaneously in insecure mode.

### Service Architecture

We use three services for ArgoCD:

1. **argocd-server**: Default ClusterIP service (managed by ArgoCD)
2. **argocd-server-http**: Custom service for Web UI traffic (HTTP/1.1)
3. **argocd-server-grpc**: Custom service for CLI traffic (HTTP/2 with h2c)

The HTTPRoute uses header matching to route `Content-Type: application/grpc` requests to the gRPC service, while all other traffic goes to the HTTP service.

## Access Methods

### Web UI

Access via Cilium Gateway (HTTPS with TLS termination):

```bash
# Open in browser
https://cd.hoodscan.io

# Credentials
Username: admin
Password: (from kubectl get secret argocd-initial-admin-secret)
```

### CLI Access

```bash
# Install ArgoCD CLI
brew install argocd  # macOS
# or download from https://github.com/argoproj/argo-cd/releases

# Login
argocd login cd.hoodscan.io

# Enter credentials when prompted
Username: admin
Password: (from kubectl get secret argocd-initial-admin-secret)
```

## Files

- `argocd-configmap.yaml`: Custom ArgoCD configuration (URL, resource exclusions)
- `argocd-cmd-params-cm.yaml`: Server parameters (insecure mode for Gateway TLS termination)
- `argocd-server-services.yaml`: Custom HTTP and gRPC services for Gateway routing
- `../environments/*/httproutes.yaml`: Gateway HTTPRoute configuration with header matching

## Configuration Details

### Server Configuration

- **Insecure Mode**: Enabled (`server.insecure: "true"`) because TLS is terminated at the Gateway
- **Proxy Extension**: Enabled for proper header forwarding
- **URL**: Configured to https://cd.hoodscan.io

### Gateway Configuration

- **Listener**: `https-argocd` on monad-indexer-gateway
- **TLS**: Terminated at Gateway using cert-manager certificates
- **Routing**: Header-based routing using `Content-Type: application/grpc`

### Service Configuration

#### argocd-server-http
```yaml
ports:
  - name: http
    port: 80
    targetPort: 8080
# No appProtocol - defaults to HTTP/1.1
```

#### argocd-server-grpc
```yaml
ports:
  - name: grpc
    port: 80
    targetPort: 8080
    appProtocol: kubernetes.io/h2c  # HTTP/2 Cleartext
```

### HTTPRoute Configuration

```yaml
rules:
  # Rule 1: gRPC traffic (CLI)
  - matches:
      - headers:
          - type: Exact
            name: content-type
            value: application/grpc
    backendRefs:
      - name: argocd-server-grpc
        port: 80

  # Rule 2: HTTP traffic (Web UI) - default
  - backendRefs:
      - name: argocd-server-http
        port: 80
```

## Troubleshooting

### CLI login fails

Make sure you're using the correct domain:
```bash
argocd login cd.hoodscan.io
```

Check Gateway and HTTPRoute status:
```bash
kubectl get gateway monad-indexer-gateway -n monad-indexer-production
kubectl get httproute argocd-http -n argocd
```

### Web UI shows "connection reset"

Check that:
1. HTTPRoute has both rules (gRPC and HTTP)
2. `argocd-server-grpc` service has `appProtocol: kubernetes.io/h2c`
3. `argocd-server-http` service does NOT have appProtocol set
4. Gateway has ALPN enabled in Cilium configuration

### Both UI and CLI fail

Check ArgoCD server is running:
```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

Verify services are pointing to correct pods:
```bash
kubectl get endpoints -n argocd argocd-server-http
kubectl get endpoints -n argocd argocd-server-grpc
```

## Technical Details

### Why h2c (HTTP/2 Cleartext)?

ArgoCD CLI uses gRPC, which requires HTTP/2 protocol. The Gateway terminates TLS and forwards traffic to backend services over unencrypted HTTP/2 (h2c). This is why we need `appProtocol: kubernetes.io/h2c` on the gRPC service.

### Why Header-Based Routing?

Gateway API evaluates HTTPRoute rules in order. By matching on the gRPC content-type header first, we can route gRPC traffic to the h2c service, while all other traffic (including web browsers) goes to the standard HTTP service.

This approach allows both HTTP and gRPC to coexist on the same hostname, which was previously thought to be a limitation of Gateway API.

## References

- [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
- [ArgoCD Ingress Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
- [Cilium Gateway API Documentation](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)
- [Kubernetes Service appProtocol](https://kubernetes.io/docs/concepts/services-networking/service/#application-protocol)
