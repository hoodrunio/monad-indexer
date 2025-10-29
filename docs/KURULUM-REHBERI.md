# Monad Indexer - Sıfırdan Kurulum Rehberi

## 🎯 Gereksinimler

- K3s cluster hazır ve çalışır durumda
- kubectl cluster'a erişebiliyor
- helm 3.x yüklü
- AWS credentials (Secrets Manager için)

## 📋 Kurulum Sırası

1. Cert-Manager
2. External Secrets Operator
3. AWS Credentials Secret
4. Cilium (Network Plugin)
5. ArgoCD
6. ArgoCD Bootstrap (Root App)

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

## 4️⃣ Cilium Network Plugin Kurulumu

### 4.1. Cilium API Server Config ExternalSecret Oluştur

```bash
kubectl apply -f infrastructure/helm/cilium/api-server-config-secret.yaml
```

**Bekleme (ExternalSecret senkronize olsun):**
```bash
kubectl wait --for=jsonpath='{.status.conditions[0].status}'=True \
  externalsecret/cilium-api-server-config -n kube-system --timeout=60s
```

**Doğrulama:**
```bash
kubectl get externalsecret -n kube-system
kubectl get secret cilium-api-server-config -n kube-system
```

### 4.2. Cilium Helm Repo Ekle

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

### 4.3. Cilium Kur

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.18.3 \
  --namespace kube-system \
  --values infrastructure/helm/cilium/values.yaml \
  --wait \
  --timeout 10m
```

**Doğrulama:**
```bash
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get pods -n kube-system -l name=cilium-operator
kubectl get pods -n kube-system -l k8s-app=cilium-envoy
```

### 4.4. Cilium LoadBalancer IP Pool Oluştur

```bash
kubectl apply -f infrastructure/helm/cilium/lb-ippool.yaml
```

**Doğrulama:**
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

---

## 5️⃣ ArgoCD Kurulumu

```bash
./infrastructure/argocd-install.sh
```

**Admin Şifresi Görüntüle:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

**ArgoCD UI'ya Erişim:**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Tarayıcıda: https://localhost:8080
- Username: `admin`
- Password: (yukarıdaki komuttan alınan şifre)

**Doğrulama:**
```bash
kubectl get pods -n argocd
```

---

## 6️⃣ ArgoCD Root Application (Bootstrap)

### 6.1. ArgoCD Repository Credentials Oluştur (Eğer private repo ise)

```bash
# Private GitHub repo için
kubectl apply -f argocd/repository-credentials.yaml
```

**Not:** Eğer public repo kullanıyorsanız bu adımı atlayın.

### 6.2. Root Application Deploy Et

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

## 7️⃣ Final Doğrulama

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

### Monad Indexer Backend Durumu
```bash
kubectl get pods -n monad-indexer-dev
kubectl get ingress -n monad-indexer-dev
kubectl get certificates -n monad-indexer-dev
```

---

## 🔍 Troubleshooting

### Cilium pod'ları CrashLoopBackOff
```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=50
```

Muhtemel sebep: `cilium-api-server-config` secret'ı yok veya hatalı.

### ExternalSecret senkronize olmuyor
```bash
kubectl describe externalsecret cilium-api-server-config -n kube-system
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

Muhtemel sebep: AWS credentials yanlış veya AWS secret'ta alan eksik.

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
- Backend: https://monad-tn1-indexer.hoodscan.io
- ArgoCD: https://localhost:8080 (port-forward)
