# Deployment Fix - Blockscout DATABASE_URL Parse Issue

## Problem
Blockscout'un ConfigHelper regex'i URL-encoded karakterleri (`%3D`) ve `=` gibi özel karakterleri desteklemiyor.

## Çözüm
Password'lerde sadece alphanumeric karakterler kullanılmalı (A-Za-z0-9).

## Production Deployment Adımları

### 1. PostgreSQL Password Değiştir
```bash
# Yeni alphanumeric password oluştur
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=')
echo "New password: $NEW_PASSWORD"

# Production namespace'inde PostgreSQL password'ü değiştir
kubectl exec -n monad-indexer-production monad-indexer-postgresql-1 -- \
  psql -U postgres -c "ALTER USER blockscout WITH PASSWORD '$NEW_PASSWORD';"
```

### 2. Production Sealed Secret Oluştur
```bash
# Plain secret oluştur
cat > /tmp/postgresql-app-secret-prod.yaml <<EOSECRET
apiVersion: v1
kind: Secret
metadata:
  name: monad-indexer-postgresql-app
  namespace: monad-indexer-production
  labels:
    app: monad-indexer
    cnpg.io/reload: "true"
    component: postgresql
type: kubernetes.io/basic-auth
stringData:
  username: blockscout
  password: \$NEW_PASSWORD
  uri: postgresql://blockscout:\$NEW_PASSWORD@monad-indexer-postgresql-rw:5432/blockscout
EOSECRET

# Seal et
kubeseal --format=yaml --cert=pub-sealed-secrets-cert.pem \
  < /tmp/postgresql-app-secret-prod.yaml \
  > charts/monad-indexer/templates/postgresql/sealed-secret-production.yaml
```

### 3. Helm Upgrade
```bash
helm upgrade monad-indexer ./charts/monad-indexer \
  -n monad-indexer-production \
  -f charts/monad-indexer/environments/values-production.yaml
```

### 4. Backend Pods'ları Restart Et
```bash
kubectl delete pod -n monad-indexer-production \
  -l app.kubernetes.io/component=backend
```

## Stats PostgreSQL İçin
Aynı işlemi `stats-postgresql` için de tekrarla:
- Password değiştir
- Sealed secret oluştur  
- Helm upgrade yap

## Değişiklik Yapılan Dosyalar
- `charts/monad-indexer/templates/backend/deployment.yaml` (init container sırası)
- `charts/monad-indexer/templates/postgresql/app-secret.yaml` (URL encoding kaldırıldı)
- `charts/monad-indexer/templates/postgresql/sealed-secret.yaml` (dev - güncellendi)

## Not
Bu değişiklikler sayesinde yeni deploy'larda otomatik olarak doğru format kullanılacak.
