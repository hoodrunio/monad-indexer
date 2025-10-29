# Monad Indexer - Hızlı Kurulum Özeti

## 🚀 Tek Komutla Kurulum

```bash
# 0. K3s + Cilium + Gateway API
cd infrastructure
./k3s-install.sh

# 1. Cert-Manager
./cert-manager-install.sh

# 2. External Secrets Operator
./external-secrets-operator-install.sh

# 3. AWS Secrets Manager
# (Manuel: AWS Console'da "blockscout" secret'ı oluştur)
# AWS credentials secret'larını oluştur:
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n kube-system

kubectl create namespace monad-indexer-dev
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n monad-indexer-dev

# 4. Cilium LoadBalancer IP Pool
kubectl apply -f helm/cilium/lb-ippool.yaml

# 5. Gateway Infrastructure
./gateway-install.sh

# 6. ArgoCD
./argocd-install.sh

# 7. ArgoCD Gateway Erişimi
kubectl apply -f ../argocd/argocd-referencegrant.yaml
kubectl apply -f ../argocd/argocd-httproute.yaml

# 8. ArgoCD Bootstrap
kubectl apply -f ../argocd/bootstrap/root-app.yaml
```

---

## ✅ Doğrulama Komutları

```bash
# K3s ve Cilium
kubectl get nodes
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
kubectl get crd | grep gateway

# Gateway
kubectl get gatewayclass
kubectl get gateway -n monad-indexer-dev
kubectl get httproute -A

# ArgoCD
kubectl get pods -n argocd
kubectl get applications -n argocd

# Certificates
kubectl get certificate -A
```

---

## 🌐 Erişim Bilgileri

### ArgoCD UI
- **URL**: https://cd.hoodscan.io
- **Username**: admin
- **Password**:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
  ```

### Monad Indexer Backend
- **URL**: https://monad-tn1-indexer.hoodscan.io

---

## 📋 Kritik Noktalar

1. **K3s kurulumu** Gateway API CRD'lerini otomatik kurar
2. **Cilium** Gateway API ve Envoy desteği ile kurulur
3. **AWS Secrets Manager** tüm credential'ları merkezi olarak yönetir
4. **Gateway API** production-ready ingress çözümü sağlar
5. **ArgoCD** GitOps pattern ile tüm uygulamaları yönetir

---

## 🔧 Troubleshooting Quick Fix

```bash
# Gateway çalışmıyorsa
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set gatewayAPI.enabled=true \
  --set envoy.enabled=true \
  --reuse-values

# Cilium durumu
cilium status

# Loglar
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent --tail=50
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy --tail=50
```

---

Detaylı açıklamalar için: [KURULUM-REHBERI.md](./KURULUM-REHBERI.md)
