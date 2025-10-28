# External API Access Configuration

Bu dosya, Blockscout microservice'lerinin external (dış dünyadan) erişimine dair bilgileri içerir.

## Exposed Ports

Aşağıdaki portlar external erişim için expose edilmiştir:

| Service | Internal Port | External Port | Purpose |
|---------|--------------|---------------|---------|
| **backend** | 4000 | 4000 | Blockscout API (indexer data) |
| **frontend** | 3000 | 3000 | Web UI (optional) |
| **smart-contract-verifier** | 8051 | 8051 | Contract verification API |
| **sig-provider** | 8050 | 8050 | Function signature resolution API |
| **stats** | 8080 | 8080 | Statistics API |
| **visualizer** | 8050 | - | NOT exposed (internal only) |

## API Base URLs

Sunucu IP'niz: `46.62.226.167`

### 1. Blockscout Backend API
```
http://46.62.226.167:4000/api/v2/
```

**Kullanım:**
- Transaction data
- Address data
- Block data
- Token data
- All indexed blockchain data

**Örnek:**
```bash
curl http://46.62.226.167:4000/api/v2/stats
curl http://46.62.226.167:4000/api/v2/addresses/0x...
```

---

### 2. Smart Contract Verifier API
```
http://46.62.226.167:8051/api/v2/verifier/
```

**Kullanım:**
- Contract verification
- Get compiler versions
- Verify with different methods (Solidity, Vyper, Sourcify)

**Örnek:**
```bash
# Get Solidity versions
curl http://46.62.226.167:8051/api/v2/verifier/solidity/versions

# Verify contract
curl -X POST http://46.62.226.167:8051/api/v2/verifier/solidity/sources:verify-multi-part \
  -H "Content-Type: application/json" \
  -d @request.json
```

**Detaylı rehber:** `CONTRACT_VERIFICATION_API_GUIDE.md`

---

### 3. Sig-Provider API
```
http://46.62.226.167:8050/api/v1/
```

**Kullanım:**
- Function signature resolution
- Get function ABI from transaction input
- Import custom signatures

**Örnek:**
```bash
# Get function ABI from transaction input
curl "http://46.62.226.167:8050/api/v1/abi/function?txInput=0xa9059cbb..."

# Import custom ABI
curl -X POST "http://46.62.226.167:8050/api/v1/signatures" \
  -H "Content-Type: application/json" \
  -d '{"abi":"[{\"type\":\"function\",\"name\":\"transfer\",...}]"}'
```

---

### 4. Frontend (Optional)
```
http://46.62.226.167:3000
```

**Kullanım:**
- Web interface for blockchain explorer
- Contract verification UI
- Address/transaction browser

**Not:** Kendi UI'ınız varsa bu servise ihtiyacınız olmayabilir.

---

## Reverse Proxy Configuration

Production ortamında genellikle **Nginx** veya **Caddy** ile reverse proxy kullanılır:

### Örnek Nginx Configuration

```nginx
# Blockscout API
location /api/ {
    proxy_pass http://localhost:4000/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

# Contract Verifier
location /verifier/ {
    proxy_pass http://localhost:8051/api/v2/verifier/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

# Sig Provider
location /signatures/ {
    proxy_pass http://localhost:8050/api/v1/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

Bu sayede tüm API'lar tek bir domain üzerinden erişilebilir:
- `https://explorer.example.com/api/v2/stats`
- `https://explorer.example.com/verifier/solidity/versions`
- `https://explorer.example.com/signatures/abi/function?txInput=0x...`

---

## CORS Configuration

CORS (Cross-Origin Resource Sharing) yapılandırması **tamamlandı**. Tüm microservice'ler external API erişimi için CORS'u destekliyor.

### Backend CORS (envs/common-blockscout.env)
```bash
# CORS için tüm origin'lere izin ver (development için)
API_CORS_ALLOWED_ORIGINS=*

# Production için belirli origin'leri belirtin
# API_CORS_ALLOWED_ORIGINS=https://your-frontend.com,https://app.your-frontend.com
```

### Smart Contract Verifier CORS (✅ Configured)

```bash
# envs/common-smart-contract-verifier.env
SMART_CONTRACT_VERIFIER__SERVER__HTTP__CORS__ENABLED=true
SMART_CONTRACT_VERIFIER__SERVER__HTTP__CORS__ALLOWED_ORIGIN=*
```

### Sig-Provider CORS (✅ Configured)

```bash
# envs/common-sig-provider.env
SIG_PROVIDER__SERVER__HTTP__CORS__ENABLED=true
SIG_PROVIDER__SERVER__HTTP__CORS__ALLOWED_ORIGIN=*
```

### Production CORS (Optional)

Production'da belirli origin'lere sınırlamak için wildcard yerine domain belirtin:

```bash
# Tek bir origin
SMART_CONTRACT_VERIFIER__SERVER__HTTP__CORS__ALLOWED_ORIGIN=https://explorer.example.com

# Birden fazla origin için reverse proxy kullanın
```

**Not:** Microservice'ler artık CORS header'ları gönderiyor, reverse proxy'ye gerek yok.

```nginx
location /verifier/ {
    if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'Content-Type';
        return 204;
    }

    add_header 'Access-Control-Allow-Origin' '*' always;
    proxy_pass http://localhost:8051/api/v2/verifier/;
}
```

---

## Security Considerations

### 1. Rate Limiting

Backend'de rate limiting aktiftir:
```bash
# envs/common-blockscout.env
API_RATE_LIMIT_BY_IP=3000  # 3000 requests per 5 minutes
```

### 2. Firewall

Production'da sadece gerekli portları açın:
```bash
# Backend API
ufw allow 4000/tcp

# Verifier API
ufw allow 8051/tcp

# Sig-provider API (optional)
ufw allow 8050/tcp

# HTTPS (Nginx kullanıyorsanız)
ufw allow 443/tcp
```

### 3. SSL/TLS

Production'da **mutlaka HTTPS** kullanın. Let's Encrypt ile ücretsiz:
```bash
certbot --nginx -d explorer.example.com
```

---

## Testing External Access

Sunucu restart ettikten sonra test edin:

```bash
# Backend API
curl http://46.62.226.167:4000/api/v2/stats

# Verifier API
curl http://46.62.226.167:8051/api/v2/verifier/solidity/versions

# Sig-provider API
curl http://46.62.226.167:8050/api/v1/abi/function?txInput=0xa9059cbb

# Health checks
curl http://46.62.226.167:8051/health
```

---

## Deployment Changes

Bu değişiklikleri sunucuya uygulamak için:

```bash
# 1. Environment dosyalarını sync edin (CORS ayarları eklendi)
scp envs/common-smart-contract-verifier.env root@46.62.226.167:/root/indexer/envs/
scp envs/common-sig-provider.env root@46.62.226.167:/root/indexer/envs/

# 2. Servis dosyalarını sync edin (port expose edildi)
scp services/smart-contract-verifier.yml root@46.62.226.167:/root/indexer/services/
scp services/sig-provider.yml root@46.62.226.167:/root/indexer/services/

# 3. Servisleri restart edin
ssh root@46.62.226.167 "cd /root/indexer && docker compose stop smart-contract-verifier sig-provider && docker compose rm -f smart-contract-verifier sig-provider && docker compose up -d"

# 4. CORS header'ları test edin
curl -I http://46.62.226.167:8051/health
curl -H "Origin: http://localhost:9090" -I http://46.62.226.167:8051/api/v2/verifier/solidity/versions

# Access-Control-Allow-Origin: * header'ını görmelisiniz
```

---

## Environment Variables for Your UI

Kendi UI'ınızda bu URL'leri environment variable olarak kullanın:

```env
# .env.local
NEXT_PUBLIC_BACKEND_API_URL=http://46.62.226.167:4000
NEXT_PUBLIC_VERIFIER_API_URL=http://46.62.226.167:8051
NEXT_PUBLIC_SIG_PROVIDER_API_URL=http://46.62.226.167:8050

# Production
NEXT_PUBLIC_BACKEND_API_URL=https://api.explorer.example.com
NEXT_PUBLIC_VERIFIER_API_URL=https://api.explorer.example.com/verifier
NEXT_PUBLIC_SIG_PROVIDER_API_URL=https://api.explorer.example.com/signatures
```

Sonra kodunuzda:
```typescript
const VERIFIER_API = process.env.NEXT_PUBLIC_VERIFIER_API_URL;

// Fetch compiler versions
const response = await fetch(`${VERIFIER_API}/api/v2/verifier/solidity/versions`);
```
