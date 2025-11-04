# Monad Indexer - Production-Ready Kurulum Rehberi

## 🎯 Gereksinimler

- Ubuntu 22.04 LTS (kernel 5.15+) veya uyumlu Linux dağıtımı
- Root erişimi veya sudo yetkisi
- helm 3.x yüklü
- AWS credentials (Secrets Manager için)
- DNS kayıtları (her subdomain için)

## 📋 Kurulum Sırası

0. **K3s + Cilium + Gateway API** (Common Infrastructure)
1. **Cert-Manager** (TLS Certificate Management)
2. **External Secrets Operator** (AWS Secrets Manager Integration)
3. **AWS Credentials Secret** (Per-namespace)
4. **GatewayClass** (Cluster-wide Gateway Controller)
5. **Environment Setup** (Dev/Staging/Production specific)
6. **ArgoCD** (GitOps - Optional)

---

## 0️⃣ K3s + Cilium Kurulumu

**Not:** K3s zaten kurulu ise bu adımı atlayın.

```bash
cd infrastructure
./k3s-install.sh
```

Bu script otomatik olarak:
- K3s'i Flannel, kube-proxy, ServiceLB, Traefik **olmadan** kurar
- **Gateway API CRD'lerini kurar** (v1.2.0 - Cilium uyumlu)
- Cilium CNI'ı production ayarlarıyla kurar:
  - kube-proxy replacement (eBPF)
  - **Gateway API etkin** (`gatewayAPI.enabled=true`)
  - **Ingress Controller kapalı** (Gateway API kullanacağız)
  - **Envoy proxy** (L7 routing için)
  - L2 announcements (LoadBalancer)
- Cilium CLI'ı yükler
- kubectl'i yapılandırır

**Doğrulama:**
```bash
kubectl get nodes
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
kubectl get crd | grep gateway
cilium status
```

**Beklenen çıktı:**
- Node: `Ready`
- Cilium agent pod'ları: `Running`
- **Cilium envoy pod'ları: `Running`**
- **Gateway API CRD'leri: 5 adet**
- Cilium status: `OK`

---

## 1️⃣ Cert-Manager Kurulumu

```bash
cd infrastructure
./cert-manager-install.sh
```

Bu script otomatik olarak:
- Cert-manager v1.16.2 kurar
- **Gateway API support'u etkinleştirir** (ExperimentalGatewayAPISupport=true)
- ClusterIssuer'ları oluşturur (letsencrypt-staging, letsencrypt-prod)

**Doğrulama:**
```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
```

**Beklenen çıktı:**
- 3 pod `Running` (cert-manager, webhook, cainjector)
- 2 ClusterIssuer `Ready`

---

## 2️⃣ External Secrets Operator Kurulumu

```bash
./external-secrets-operator-install.sh
```

**Doğrulama:**
```bash
kubectl get pods -n external-secrets-system
kubectl get crds | grep external-secrets
```

---

## 3️⃣ AWS Secrets Manager Hazırlığı

### 3.1. AWS Secret Oluştur (blockscout)

```bash
# Rastgele şifreler oluştur
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')
STATS_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=\n')

# AWS Secrets Manager'a secret oluştur
aws secretsmanager create-secret \
  --name "blockscout" \
  --description "All credentials for Monad Indexer" \
  --secret-string "{\
    \"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\",\
    \"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",\
    \"STATS_PASSWORD\":\"${STATS_PASSWORD}\"\
  }" \
  --region eu-north-1
```

### 3.2. AWS Credentials Secret Oluştur

Her environment için ayrı namespace'de:

```bash
# Dev environment
kubectl create namespace monad-indexer-dev
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n monad-indexer-dev

# ArgoCD namespace (eğer kullanılıyorsa)
kubectl create namespace argocd
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n argocd
```

**Doğrulama:**
```bash
kubectl get secret aws-credentials -n monad-indexer-dev
kubectl get secret aws-credentials -n argocd
```

---

## 4️⃣ GatewayClass Kurulumu

GatewayClass cluster-wide bir resource, tüm environment'lar için tek seferlik:

```bash
kubectl apply -f infrastructure/common/gatewayclass.yaml
```

**Doğrulama:**
```bash
kubectl get gatewayclass
```

**Beklenen çıktı:**
```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       10s
```

---

## 5️⃣ Environment Setup (Dev/Staging/Production)

### Environment-Specific Yaklaşım

Her environment'ın kendi:
- **Domain'leri** (cd.hoodscan.io, monad-tn1-indexer.hoodscan.io vs.)
- **Public IP'si** (95.216.177.23, 88.99.11.22 vs.)
- **Gateway'i** (listener'lar, TLS sertifikaları)
- **HTTPRoute'ları** (routing kuralları)

### Dev Environment Kurulumu

```bash
./infrastructure/install-environment.sh dev
```

Bu script otomatik olarak:
1. ✅ Namespace oluşturur (`monad-indexer-dev`)
2. ✅ LoadBalancer IP Pool oluşturur (95.216.177.23)
3. ✅ Gateway'i HTTP-only başlatır (cert-manager için)
4. ✅ TLS sertifikalarını oluşturur
5. ✅ Sertifikalar hazır olana kadar bekler
6. ✅ Gateway'i HTTPS listener'larla upgrade eder
7. ✅ HTTPRoute'ları oluşturur

**Doğrulama:**
```bash
# Gateway durumu
kubectl get gateway -n monad-indexer-dev

# LoadBalancer IP
kubectl get svc -n monad-indexer-dev -l io.cilium.gateway/owning-gateway

# TLS Sertifikalar
kubectl get certificate -A

# HTTPRoute'lar
kubectl get httproute -A
```

**Beklenen çıktı:**
```
# Gateway
NAME                    CLASS    ADDRESS          PROGRAMMED   AGE
monad-indexer-gateway   cilium   95.216.177.23     True         2m

# LoadBalancer
NAME                                   TYPE           EXTERNAL-IP
cilium-gateway-monad-indexer-gateway   LoadBalancer   95.216.177.23

# Certificates (tümü READY=True olmalı)
NAMESPACE           NAME                 READY
argocd              argocd-tls           True
monad-indexer-dev   monad-indexer-tls    True
```

### DNS Yapılandırması

Environment kurulduktan sonra, DNS kayıtlarını oluşturun:

```bash
# Dev environment için
cd.hoodscan.io                    A    95.216.177.23
monad-tn1-indexer.hoodscan.io     A    95.216.177.23
```

---

## 6️⃣ ArgoCD Kurulumu (Optional)

```bash
cd infrastructure
./argocd-install.sh
```

**Admin Şifresi:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

**Erişim:**
- **URL**: https://cd.hoodscan.io
- **Username**: admin
- **Password**: (yukarıdaki komuttan)

---

## 📊 Environment Yapısı

```
infrastructure/
├── environments/
│   ├── dev/
│   │   ├── config.env           # Environment config
│   │   ├── lb-ippool.yaml       # IP: 95.216.177.23
│   │   ├── gateway.yaml         # cd.hoodscan.io, monad-tn1-indexer.hoodscan.io
│   │   ├── certificates.yaml    # TLS sertifikalar
│   │   └── httproutes.yaml      # Routing kuralları
│   │
│   ├── staging/
│   │   ├── config.env           # Farklı IP, farklı domain'ler
│   │   ├── lb-ippool.yaml
│   │   ├── gateway.yaml
│   │   ├── certificates.yaml
│   │   └── httproutes.yaml
│   │
│   └── production/
│       ├── config.env
│       ├── lb-ippool.yaml
│       ├── gateway.yaml
│       ├── certificates.yaml
│       └── httproutes.yaml
```

### Yeni Environment Ekleme

1. `infrastructure/environments/new-env/` klasörü oluştur
2. `dev/` klasöründen dosyaları kopyala
3. `config.env` dosyasını güncelle (IP, domain'ler)
4. YAML dosyalarını environment'a göre düzenle
5. `./infrastructure/install-environment.sh new-env` çalıştır

---

## 🔍 Troubleshooting

### Gateway "Waiting for controller" hatası

**Kontrol:**
```bash
kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
```

**Sebep:** Cilium Gateway API etkin değil

**Çözüm:** K3s'i tekrar kur veya Cilium'u manuel güncelle:
```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set gatewayAPI.enabled=true \
  --set envoy.enabled=true \
  --reuse-values
```

### TLS Sertifikası Ready olmuyor

**Kontrol:**
```bash
kubectl get certificate <cert-name> -n <namespace>
kubectl describe certificate <cert-name> -n <namespace>
kubectl get challenges -A
```

**Sebep:** Cert-manager Gateway API challenge oluşturamıyor

**Çözüm:** Cert-manager Gateway API support'u kontrol et:
```bash
kubectl get deployment cert-manager -n cert-manager -o yaml | grep ExperimentalGatewayAPISupport
```

### LoadBalancer IP Atanmıyor

**Kontrol:**
```bash
kubectl get ciliumloadbalancerippool
kubectl get svc -n <namespace>
```

**Sebep:** IP pool Gateway service'i match edemiyor

**Çözüm:** IP pool selector'ı kontrol et:
```bash
kubectl describe ciliumloadbalancerippool monad-indexer-dev-public-pool
```

---

## ✅ Kurulum Tamamlandı!

**Erişim URL'leri (Dev):**
- **ArgoCD**: https://cd.hoodscan.io
- **Monad Indexer**: https://monad-tn1-indexer.hoodscan.io

**Test:**
```bash
curl -I https://cd.hoodscan.io
curl -I https://monad-tn1-indexer.hoodscan.io
```

---

## 📚 Daha Fazla Bilgi

- [Cilium Gateway API Docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [Cert-Manager Gateway API](https://cert-manager.io/docs/usage/gateway/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
