# ArgoCD Configuration

## Overview

ArgoCD is configured with Cilium Gateway API for external access. Due to Gateway API limitations and Cilium constraints, we use a hybrid approach:

- **Web UI**: Accessible via Cilium Gateway at https://cd.hoodscan.io
- **CLI**: Accessible via NodePort on port 30080

## Architecture

### Gateway API Limitation (GEP-1016)

According to the Kubernetes Gateway API specification (GEP-1016), **HTTPRoute and GRPCRoute cannot share the same hostname**. This is a technical limitation in the Gateway API specification itself.

> "If a route (A) of type HTTPRoute or GRPCRoute is attached to a Listener and that listener already has another Route (B) of the other type attached and the intersection of the hostnames of A and B is non-empty, then the implementation must reject Route A."

Since ArgoCD serves both HTTP (Web UI) and gRPC (CLI) on the same port (8080), we cannot route both through the Gateway on the same hostname.

### Cilium Port-Forward Issue

Additionally, `kubectl port-forward` doesn't work properly with Cilium due to network namespace issues:

```
Error: failed to execute portforward in network namespace "/var/run/netns/cni-..."
```

This is a known issue with Cilium CNI.

## Solution

We use three different services:

1. **argocd-server** (default): Original ClusterIP service (kept for compatibility)
2. **argocd-server-http**: Custom ClusterIP for Gateway routing (Web UI only)
3. **argocd-server-nodeport**: NodePort service for CLI access (port 30080)

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

**Option 1: NodePort (Recommended)**

```bash
# Install ArgoCD CLI
brew install argocd

# Login via NodePort
argocd login <node-ip>:30080 --insecure --plaintext

# Example
argocd login 65.21.183.30:30080 --insecure --plaintext
```

**Option 2: SSH Tunnel**

If NodePort is not accessible from your location:

```bash
# Create SSH tunnel
ssh -L 8080:localhost:30080 root@<node-ip>

# In another terminal
argocd login localhost:8080 --insecure --plaintext
```

## Files

- `argocd-configmap.yaml`: Custom ArgoCD configuration (URL, resource exclusions)
- `argocd-cmd-params-cm.yaml`: Server parameters (insecure mode for Gateway TLS termination)
- `argocd-server-services.yaml`: Custom HTTP service for Gateway routing
- `argocd-server-nodeport.yaml`: NodePort service for CLI access
- `../environments/dev/httproutes.yaml`: Gateway HTTPRoute configuration

## Configuration Details

### Server Configuration

- **Insecure Mode**: Enabled (`server.insecure: "true"`) because TLS is terminated at the Gateway
- **Proxy Extension**: Enabled for proper header forwarding
- **URL**: Configured to https://cd.hoodscan.io

### Gateway Configuration

- **Listener**: `https-argocd` on monad-indexer-gateway
- **TLS**: Terminated at Gateway using cert-manager certificates
- **Protocol**: HTTP/1.1 (for web UI compatibility)

## Troubleshooting

### CLI login fails via Gateway

This is expected. Use NodePort instead. Gateway API doesn't support mixed HTTP/gRPC protocols.

### Port-forward doesn't work

This is a known Cilium issue. Use NodePort or SSH tunnel instead.

### Web UI shows "connection reset"

Check that:
1. HTTPRoute is using `argocd-server-http` service (not the default)
2. Service doesn't have `appProtocol: kubernetes.io/h2c` (would break web UI)
3. Gateway has ALPN enabled in Cilium

## References

- [Gateway API GEP-1016: GRPCRoute](https://gateway-api.sigs.k8s.io/geps/gep-1016/)
- [ArgoCD Ingress Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
- [Cilium Gateway API Documentation](https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/)
