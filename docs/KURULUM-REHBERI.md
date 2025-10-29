# Monad Indexer - Sıfırdan Kurulum Rehberi

## 🎯 Gereksinimler

- Ubuntu 22.04 LTS (kernel 5.15+) veya uyumlu Linux dağıtımı
- Root erişimi veya sudo yetkisi
- helm 3.x yüklü
- AWS credentials (Secrets Manager için)

## 📋 Kurulum Sırası

0. K3s + Cilium + Gateway API Kurulumu
1. Cert-Manager
2. External Secrets Operator
3. AWS Credentials Secret
4. Cilium LoadBalancer IP Pool
5. Gateway Infrastructure (Gateway, GatewayClass)
6. ArgoCD
7. ArgoCD HTTPRoute (Gateway üzerinden erişim)
8. ArgoCD Bootstrap (Root App)

---

## 0️⃣ K3s + Cilium Kurulumu

**Not:** K3s zaten Cilium ile kurulu ise bu adımı atlayın ve Adım 1'e geçin.

```bash
cd infrastructure
./k3s-install.sh
```

Bu script:
- K3s'i Flannel, kube-proxy, ServiceLB, Traefik **olmadan** kurar
- **Gateway API CRD'lerini kurar** (v1.2.1)
- Cilium CNI'ı production ayarlarıyla kurar:
  - kube-proxy replacement (eBPF)
  - **Gateway API desteği** (`gatewayAPI.enabled=true`)
  - **Envoy proxy** (L7 routing için)
  - L2 announcements (LoadBalancer)
- Cilium CLI'ı yükler
- kubectl'i tüm kullanıcılar için yapılandırır

**Doğrulama:**
```bash
kubectl get nodes
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
kubectl get crd | grep gateway
cilium status
```

**Beklenen çıktı:**
- Node durumu: `Ready`
- Cilium agent pod'ları: `Running`
- **Cilium envoy pod'ları: `Running`**
- **Gateway API CRD'leri: 5 adet (gateways, httproutes, grpcroutes, gatewayclass, referencegrants)**
- Cilium status: `OK`

---

## 1️⃣ Cert-Manager Kurulumu

```bash
./infrastructure/cert-manager-install.sh
```

**Doğrulama:**
```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
```

---

## 2️⃣ External Secrets Operator Kurulumu

```bash
./infrastructure/external-secrets-operator-install.sh
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

# Kubernetes API server bilgileri (cluster IP:PORT)
K8S_SERVICE_HOST=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
K8S_SERVICE_PORT="6443"

# AWS Secrets Manager'a secret oluştur
aws secretsmanager create-secret \
  --name "blockscout" \
  --description "All credentials for Monad Indexer" \
  --secret-string "{
    \"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\",
    \"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",
    \"STATS_PASSWORD\":\"${STATS_PASSWORD}\",
    \"Prodk8sServiceHost\":\"${K8S_SERVICE_HOST}\",
    \"Prodk8sServicePort\":\"${K8S_SERVICE_PORT}\"
  }" \
  --region eu-north-1
```

**Not:** `Prodk8sServiceHost` ve `Prodk8sServicePort` Cilium için gerekli!

### 3.2. AWS Credentials Secret Oluştur (kube-system için)

```bash
# Cilium için kube-system namespace'inde
kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n kube-system
```

### 3.3. AWS Credentials Secret Oluştur (monad-indexer-dev için)

```bash
# Uygulama için monad-indexer-dev namespace'inde
kubectl create namespace monad-indexer-dev

kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=YOUR_AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_AWS_SECRET_ACCESS_KEY \
  -n monad-indexer-dev
```

**Doğrulama:**
```bash
kubectl get secret aws-credentials -n kube-system
kubectl get secret aws-credentials -n monad-indexer-dev
```

---

## 4️⃣ Cilium LoadBalancer IP Pool Kurulumu

**Not:** K3s kurulumu sırasında Cilium zaten kuruldu. Bu adımda sadece LoadBalancer IP pool'larını oluşturacağız.

```bash
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml
```

Bu dosya şunları oluşturur:
- **monad-indexer-public-pool**: Gateway için public IP (65.21.183.30)
- **monad-indexer-internal-pool**: Internal servisler için IP'ler (10.0.0.100/27)
- **monad-indexer-l2-policy**: L2 announcement policy (ARP)

**Doğrulama:**
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

**Beklenen çıktı:**
```
NAME                            DISABLED   CONFLICTING   IPS AVAILABLE   AGE
monad-indexer-public-pool       false      False         1               10s
monad-indexer-internal-pool     false      False         32              10s
```

---

## 5️⃣ Gateway Infrastructure Kurulumu

**Not:** Bu adım Gateway, GatewayClass ve gerekli TLS sertifikalarını oluşturur.

```bash
cd infrastructure
./gateway-install.sh
```

Bu script:
- GatewayClass oluşturur (Cilium controller)
- Gateway oluşturur (65.21.183.30 public IP ile)
- ArgoCD için TLS sertifikası oluşturur
- Gateway'in hazır olmasını bekler

**Doğrulama:**
```bash
kubectl get gatewayclass
kubectl get gateway -n monad-indexer-dev
kubectl get certificate -n monad-indexer-dev
```

**Beklenen çıktı:**
```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       10s

NAME                    CLASS    ADDRESS          PROGRAMMED   AGE
monad-indexer-gateway   cilium   65.21.183.30     True         10s
```

---

## 6️⃣ ArgoCD Kurulumu

```bash
cd infrastructure
./argocd-install.sh
```

**Admin Şifresi Görüntüle:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

**Doğrulama:**
```bash
kubectl get pods -n argocd
```

Tüm pod'lar `Running` durumunda olmalı.

---

## 7️⃣ ArgoCD Gateway Erişimi (HTTPRoute)

**Not:** ArgoCD'ye production'da erişim için Gateway API kullanıyoruz.

### 7.1. DNS Kaydı Oluştur

```bash
# DNS sağlayıcınızda A kaydı oluşturun:
cd.hoodscan.io -> 65.21.183.30
```

### 7.2. ReferenceGrant Oluştur

Cross-namespace erişim için gerekli:

```bash
kubectl apply -f argocd/argocd-referencegrant.yaml
```

### 7.3. HTTPRoute Deploy Et

```bash
kubectl apply -f argocd/argocd-httproute.yaml
```

Bu dosya:
- `cd.hoodscan.io` için HTTPRoute oluşturur
- Let's Encrypt TLS sertifikası talep eder
- ArgoCD server'a trafiği yönlendirir

**Doğrulama:**
```bash
kubectl get httproute -n argocd
kubectl get certificate -n argocd
```

**Sertifika Hazır Olmasını Bekle (1-2 dakika):**
```bash
kubectl wait --for=condition=Ready certificate/argocd-tls -n argocd --timeout=120s
```

**ArgoCD UI'ya Erişim:**

Tarayıcıda: https://cd.hoodscan.io
- Username: `admin`
- Password: (Adım 6'daki komuttan alınan şifre)

**Alternative: Port Forward (Development/Test):**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Tarayıcıda: https://localhost:8080

---

## 8️⃣ ArgoCD Root Application (Bootstrap)

### 8.1. ArgoCD Repository Credentials Oluştur (Eğer private repo ise)

```bash
# Private GitHub repo için
kubectl apply -f argocd/repository-credentials.yaml
```

**Not:** Eğer public repo kullanıyorsanız bu adımı atlayın.

### 8.2. Root Application Deploy Et

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

**ArgoCD Senkronize Edecek:**
- infrastructure-cilium (cilium-lb-ippool)
- infrastructure-gateway (Gateway API resources)
- infrastructure-monitoring (kube-prometheus-stack)
- monad-indexer-dev
- monad-indexer-staging (optional)
- monad-indexer-production (optional)

**Doğrulama:**
```bash
kubectl get applications -n argocd
```

**ArgoCD UI'dan takip edin:**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## 9️⃣ Final Doğrulama

### Namespace'leri Kontrol Et
```bash
kubectl get namespaces
```

Beklenen:
- argocd
- cert-manager
- external-secrets-system
- kube-system
- monad-indexer-dev
- monitoring

### Tüm Pod'ları Kontrol Et
```bash
kubectl get pods --all-namespaces
```

### ArgoCD Applications Durumu
```bash
kubectl get applications -n argocd
```

Tüm uygulamalar `Synced` ve `Healthy` olmalı.

### Gateway ve HTTPRoute Durumu
```bash
kubectl get gateway -n monad-indexer-dev
kubectl get httproute -A
kubectl get certificate -A
```

Beklenen:
- Gateway: `Programmed=True`, `ADDRESS=65.21.183.30`
- HTTPRoute: `cd.hoodscan.io`, `monad-tn1-indexer.hoodscan.io`
- Certificates: Tüm sertifikalar `READY=True`

### Monad Indexer Backend Durumu
```bash
kubectl get pods -n monad-indexer-dev
kubectl get httproute -n monad-indexer-dev
kubectl get certificates -n monad-indexer-dev
```

---

## 🔍 Troubleshooting

### Gateway "Waiting for controller" hatası
```bash
kubectl describe gateway monad-indexer-gateway -n monad-indexer-dev
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
```

Muhtemel sebepler:
- Cilium Gateway API etkin değil (k3s-install.sh'de `--set gatewayAPI.enabled=true` gerekli)
- Envoy pod'ları çalışmıyor (`kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy`)
- Gateway API CRD'leri eksik (`kubectl get crd | grep gateway`)

**Çözüm:**
```bash
# Gateway API desteğini etkinleştir
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set gatewayAPI.enabled=true \
  --set envoy.enabled=true \
  --reuse-values
```

### Cilium pod'ları CrashLoopBackOff
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent --tail=50
cilium status
```

Muhtemel sebepler:
- API server bilgileri hatalı (k3s-install.sh sırasında otomatik algılandı)
- Kernel eBPF desteği yok (kernel 5.10+ gerekli)
- Network interface bulunamıyor

### ExternalSecret senkronize olmuyor
```bash
kubectl get externalsecret -A
kubectl describe externalsecret <secret-name> -n <namespace>
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

Muhtemel sebepler:
- AWS credentials yanlış (`aws-credentials` secret'ını kontrol edin)
- AWS secret'ta alan eksik (blockscout secret'ında tüm alanlar var mı?)
- AWS Secrets Manager region'u yanlış (eu-north-1 olmalı)
- IAM permissions yetersiz

### ArgoCD application sync olmuyorsa
```bash
kubectl describe application monad-indexer-dev -n argocd
```

ArgoCD UI'dan "Sync" butonuna tıklayın veya:
```bash
kubectl patch application monad-indexer-dev -n argocd \
  --type merge \
  -p '{"operation":{"sync":{}}}'
```

---

## 📚 Daha Fazla Bilgi

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Cilium Documentation](https://docs.cilium.io/)
- [External Secrets Documentation](https://external-secrets.io/)
- [Cert-Manager Documentation](https://cert-manager.io/docs/)

---

## ✅ Kurulum Tamamlandı!

Monad Indexer artık çalışıyor olmalı:
- **ArgoCD UI**: https://cd.hoodscan.io
- **Backend**: https://monad-tn1-indexer.hoodscan.io
- **Alternative (port-forward)**: https://localhost:8080
