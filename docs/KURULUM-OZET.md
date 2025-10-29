# Monad Indexer - Hızlı Kurulum Özeti

## 🚀 Tek Komutla Kurulum (Production-Ready)

### Sıfırdan Kurulum

```bash
# 1. K3s + Cilium + Gateway API
cd infrastructure
./k3s-install.sh

# 2. Cert-Manager (Gateway API support enabled)
./cert-manager-install.sh

# 3. External Secrets Operator
./external-secrets-operator-install.sh

# 4. AWS Secrets (Manuel)
# AWS Console'da "blockscout" secret'ı oluştur

# 5. AWS Credentials Secrets
kubectl create namespace monad-indexer-dev
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n monad-indexer-dev

kubectl create namespace argocd
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n argocd

# 6. GatewayClass (once, cluster-wide)
kubectl apply -f infrastructure/common/gatewayclass.yaml

# 7. Environment Setup (tek komut!)
./install-environment.sh dev

# 8. ArgoCD (optional)
./argocd-install.sh
```

---

## ✅ Environment-Specific Kurulum

Her environment için:

```bash
# Staging
./infrastructure/install-environment.sh staging

# Production
./infrastructure/install-environment.sh production
```

---

## 🔍 Doğrulama Komutları

```bash
# K3s ve Cilium
kubectl get nodes
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
kubectl get crd | grep gateway

# Gateway
kubectl get gatewayclass
kubectl get gateway -n monad-indexer-dev
kubectl get svc -n monad-indexer-dev -l io.cilium.gateway/owning-gateway

# TLS Certificates
kubectl get certificate -A
kubectl get challenges -A

# HTTPRoutes
kubectl get httproute -A

# ArgoCD
kubectl get pods -n argocd
```

---

## 🌐 Erişim Bilgileri

### Dev Environment
- **ArgoCD**: https://cd.hoodscan.io
- **Monad Indexer**: https://monad-tn1-indexer.hoodscan.io
- **Public IP**: 65.21.183.30

**Admin Şifresi (ArgoCD):**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 📋 Kritik Noktalar

### ✅ Gateway API (Ingress YOK!)
- ✅ Sadece Gateway API kullanıyoruz
- ✅ Ingress Controller kapalı
- ✅ Cert-manager Gateway API HTTP-01 challenge kullanıyor
- ✅ Her environment kendi Gateway'i

### ✅ Environment Separation
- ✅ Her environment: kendi IP, domain, gateway, certificates
- ✅ Dev, Staging, Production tamamen izole
- ✅ Config'ler `infrastructure/environments/*/`

### ✅ Otomatik TLS
- ✅ Gateway HTTP listener (cert-manager için)
- ✅ Cert-manager otomatik HTTPRoute oluşturur
- ✅ Let's Encrypt sertifikası alınır
- ✅ Gateway HTTPS listener'larla upgrade edilir

### ✅ Cilium Best Practices
- ✅ kube-proxy replacement (eBPF)
- ✅ Gateway API v1.2.0 CRDs
- ✅ Envoy proxy (L7 routing)
- ✅ L2 announcements (LoadBalancer)
- ✅ Native routing mode

---

## 🏗️ Yeni Environment Ekleme

```bash
# 1. Klasör oluştur
mkdir -p infrastructure/environments/new-env

# 2. Dev'den kopyala
cp infrastructure/environments/dev/* infrastructure/environments/new-env/

# 3. Config'leri düzenle
vim infrastructure/environments/new-env/config.env
vim infrastructure/environments/new-env/gateway.yaml
vim infrastructure/environments/new-env/lb-ippool.yaml

# 4. Deploy et
./infrastructure/install-environment.sh new-env
```

---

## 🔧 Troubleshooting Quick Fix

```bash
# Gateway çalışmıyor
kubectl describe gateway <gateway-name> -n <namespace>
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy

# Cert-manager Gateway API challenge oluşturamıyor
kubectl get deployment cert-manager -n cert-manager -o yaml | grep ExperimentalGatewayAPISupport

# LoadBalancer IP atanmıyor
kubectl get ciliumloadbalancerippool
kubectl describe ciliumloadbalancerippool <pool-name>

# TLS sertifika ready olmuyor
kubectl describe certificate <cert-name> -n <namespace>
kubectl get challenges -A

# Cilium durumu
cilium status
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent --tail=50
```

---

## 📂 Dosya Yapısı

```
infrastructure/
├── common/                        # Cluster-wide resources
│   ├── gatewayclass.yaml
│   ├── cert-manager-clusterissuer.yaml
│   └── cilium-values.yaml
│
├── environments/                  # Environment-specific configs
│   ├── dev/
│   │   ├── config.env
│   │   ├── gateway.yaml
│   │   ├── lb-ippool.yaml
│   │   ├── certificates.yaml
│   │   └── httproutes.yaml
│   ├── staging/
│   └── production/
│
├── k3s-install.sh
├── cert-manager-install.sh
├── external-secrets-operator-install.sh
├── install-environment.sh         # NEW: Environment deployment
└── argocd-install.sh
```

---

## 🎯 Deployment Checklist

- [ ] K3s + Cilium kuruldu
- [ ] Cert-Manager kuruldu (Gateway API support enabled)
- [ ] External Secrets Operator kuruldu
- [ ] AWS secret oluşturuldu (blockscout)
- [ ] AWS credentials secrets oluşturuldu (per namespace)
- [ ] GatewayClass oluşturuldu (cluster-wide)
- [ ] Environment deploy edildi (`install-environment.sh`)
- [ ] DNS kayıtları oluşturuldu (domain -> public IP)
- [ ] TLS sertifikaları ready (kubectl get certificate -A)
- [ ] Gateway programmed (kubectl get gateway -A)
- [ ] HTTPRoutes oluşturuldu (kubectl get httproute -A)
- [ ] Erişim test edildi (curl -I https://domain)

---

Detaylı açıklamalar için: [KURULUM-REHBERI.md](./KURULUM-REHBERI.md)
