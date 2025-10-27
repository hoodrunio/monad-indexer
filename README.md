# Monad Blockscout PoC

Monad Testnet için tam özellikli Blockscout explorer kurulumu. Yüksek performanslı indexing, smart contract verification ve REST API içerir.

## 🚀 Hızlı Başlangıç (3 Adım)

```bash
# 1. .env dosyasını oluştur
cp .env.example .env

# 2. SECRET_KEY_BASE oluştur ve .env'e ekle
openssl rand -base64 64

# 3. Başlat!
docker compose up -d
```

**Explorer:** http://localhost  
**API:** http://localhost/api/v2/  
**Stats:** http://localhost:8080

## 📋 Gereksinimler

- Docker 20.10+
- Docker Compose v2+
- Minimum 8GB RAM (16GB+ önerilir)
- 100GB+ SSD disk alanı

## 🔧 Kurulum

### 1. Repository'yi İndir

Bu dizini bir yere kopyalayın veya zip olarak indirin.

### 2. Environment Variables

```bash
# .env dosyasını oluştur
cp .env.example .env
```

**.env dosyasını düzenle:**

```bash
# 1. PostgreSQL şifresini değiştir
POSTGRES_PASSWORD=güçlü_bir_şifre

# 2. Monad RPC endpoint'lerini ayarla (KENDİ NODE'UNUZU KULLANIN!)
ETHEREUM_JSONRPC_HTTP_URL=http://your-monad-node:8545
ETHEREUM_JSONRPC_TRACE_URL=http://your-monad-node:8545
ETHEREUM_JSONRPC_WS_URL=ws://your-monad-node:8546
```

### 3. SECRET_KEY_BASE Oluştur

```bash
# Secret key oluştur
openssl rand -base64 64

# Çıktıyı kopyala ve envs/common-blockscout.env dosyasında
# SECRET_KEY_BASE= satırına yapıştır
```

### 4. Servisleri Başlat

```bash
# Pre-built image'larla başlat (önerilen - hızlı)
docker compose up -d

# Veya source'dan build et (yavaş - sadece development için)
docker compose up -d --build
```

### 5. Logları İzle

```bash
# Tüm servislerin loglarını izle
docker compose logs -f

# Sadece backend
docker compose logs -f backend

# İlk indexing başladığını kontrol et
docker compose logs -f backend | grep "Imported"
```

## 📊 Servisler ve Portlar

| Servis | URL | Açıklama |
|--------|-----|----------|
| **Web Explorer** | http://localhost | Ana explorer UI |
| **API v2** | http://localhost/api/v2/ | REST API |
| **API Docs** | http://localhost/api-docs | Swagger documentation |
| **Stats** | http://localhost:8080 | İstatistik servisi |
| **Visualizer** | http://localhost:8081 | Contract visualizer |
| **Smart Contract Verifier** | http://localhost:8150 | Verification service |
| **Database** | localhost:7432 | PostgreSQL (postgres/YOUR_PASSWORD) |
| **Stats DB** | localhost:7433 | Stats PostgreSQL |

## 🎯 API Kullanımı

```bash
# Health check
curl http://localhost/api/v1/health

# Stats
curl http://localhost/api/v2/stats

# Latest block
curl http://localhost/api/v2/blocks/latest

# Transaction detayları
curl http://localhost/api/v2/transactions/{tx_hash}

# Address bilgisi
curl http://localhost/api/v2/addresses/{address}

# Smart contract bilgisi
curl http://localhost/api/v2/smart-contracts/{address}
```

## 🔐 Smart Contract Verification

### Web UI Üzerinden

1. Contract sayfasına git
2. "Code" tab'ine tıkla
3. "Verify & Publish" butonuna tıkla
4. Source code'u yükle ve compiler ayarlarını gir
5. "Verify" butonuna tıkla

### API Üzerinden

```bash
# Flattened source code ile
curl -X POST http://localhost/api/v2/smart-contracts/{address}/verification/via/flattened-code \
  -H "Content-Type: application/json" \
  -d '{
    "compiler_version": "v0.8.20+commit.a1b79de6",
    "source_code": "contract MyContract { ... }",
    "contract_name": "MyContract",
    "optimization": true,
    "optimization_runs": 200
  }'

# Sourcify ile (önerilen)
curl -X POST http://localhost/api/v2/smart-contracts/{address}/verification/via/sourcify \
  -F "files[]=@metadata.json" \
  -F "files[]=@MyContract.sol"
```

## ⚡ Performans Optimizasyonu

### Yüksek TPS İçin Ayarlar

**envs/common-blockscout.env** dosyasını düzenle:

```bash
# Memory limiti artır
INDEXER_MEMORY_LIMIT=8

# Concurrency artır
INDEXER_RECEIPTS_CONCURRENCY=40
INDEXER_CATCHUP_BLOCKS_CONCURRENCY=20

# Batch size'ları artır
INDEXER_RECEIPTS_BATCH_SIZE=1000
INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=100
```

### Internal Transactions'ı Devre Dışı Bırak (Hızlı Sync İçin)

```bash
# envs/common-blockscout.env'de
INDEXER_DISABLE_INTERNAL_TRANSACTIONS_FETCHER=true
```

**Not:** Bu, internal tx'leri indexlemez. Sadece hızlı test için kullanın.

### Kendi Monad Node'unuzu Kullanın

Public RPC slow olacaktır. En iyi performans için kendi node'unuzu kullanın:

```bash
# .env dosyasında
ETHEREUM_JSONRPC_HTTP_URL=http://your-monad-node:8545
ETHEREUM_JSONRPC_TRACE_URL=http://your-monad-node:8545
ETHEREUM_JSONRPC_WS_URL=ws://your-monad-node:8546
```

## 📈 Monitoring

### Database İstatistikleri

```bash
# Container'a bağlan
docker exec -it postgres psql -U postgres blockscout

-- İndexlenen block sayısı
SELECT COUNT(*) FROM blocks WHERE consensus = true;

-- Son block
SELECT MAX(number) FROM blocks WHERE consensus = true;

-- Transaction sayısı
SELECT COUNT(*) FROM transactions;

-- Database boyutu
SELECT pg_size_pretty(pg_database_size('blockscout'));
```

### Container Resource Kullanımı

```bash
# Tüm container'ların resource kullanımı
docker stats

# Backend resource kullanımı
docker stats backend --no-stream
```

### Indexing Progress

```bash
# İlk sync ilerlemesini izle
docker compose logs -f backend | grep -E "Imported|blocks"

# Error kontrolü
docker compose logs backend | grep -i error
```

## 🔄 Yönetim Komutları

```bash
# Servisleri durdur
docker compose down

# Servisleri yeniden başlat
docker compose restart

# Belirli bir servisi yeniden başlat
docker compose restart backend

# Image'ları güncelle
docker compose pull

# Container'ları ve volume'leri tamamen sil (DİKKAT: Data silinir!)
docker compose down -v

# Logları temizle
docker compose logs --tail=0 -f
```

## 🗄️ Backup ve Restore

### Backup

```bash
# Database backup
docker exec postgres pg_dump -U postgres blockscout > backup_$(date +%Y%m%d).sql

# Stats database backup
docker exec stats-db pg_dump -U postgres stats > stats_backup_$(date +%Y%m%d).sql
```

### Restore

```bash
# Database restore
cat backup_20250101.sql | docker exec -i postgres psql -U postgres blockscout

# Stats database restore
cat stats_backup_20250101.sql | docker exec -i stats-db psql -U postgres stats
```

## 🐛 Troubleshooting

### Backend başlamıyor

```bash
# Logları kontrol et
docker compose logs backend

# Yaygın sorunlar:
# 1. SECRET_KEY_BASE eksik veya yanlış
# 2. Database bağlantı problemi
# 3. RPC endpoint erişilemiyor

# Database'in hazır olmasını bekle
docker compose ps
# "backend" servisi "healthy" olmalı
```

### Indexing çok yavaş

1. **Kendi Monad node'unuzu kullanın** - Public RPC yavaş
2. Concurrency ve batch size'ları artırın
3. Internal transactions'ı geçici olarak devre dışı bırakın
4. Memory limit'i artırın
5. Database'i daha güçlü bir sunucuya taşıyın

### Database connection errors

```bash
# Connection pool'u artırın
# envs/common-blockscout.env'de:
POOL_SIZE=100
POOL_SIZE_API=100

# PostgreSQL max_connections artırın
# services/db.yml'de:
command: postgres -c 'max_connections=300'
```

### Out of memory

```bash
# Docker'a daha fazla memory ayırın
# Docker Desktop → Settings → Resources → Memory: 8GB+

# Indexer memory limit'i azaltın
# envs/common-blockscout.env'de:
INDEXER_MEMORY_LIMIT=2
```

### Port conflicts

Eğer 80, 8080 vs. portları kullanılıyorsa, docker-compose.yml'de portları değiştirin:

```yaml
services:
  proxy:
    ports:
      - "8000:80"  # 80 yerine 8000 kullan
```

## 🎓 İleri Seviye

### Sadece API Modu (UI Olmadan)

**envs/common-blockscout.env** dosyasında:

```bash
DISABLE_WEBAPP=true
API_V1_READ_METHODS_DISABLED=false
API_V1_WRITE_METHODS_DISABLED=false
```

### External Database Kullanma

```bash
# Kendi PostgreSQL'iniz varsa:
# docker-compose.yml'de db servisini kaldırın
# envs/common-blockscout.env'de:
DATABASE_URL=postgresql://user:password@external-db:5432/blockscout
```

### SSL/TLS Ekleme

Nginx proxy'ye SSL sertifikası ekleyin veya Traefik/Caddy gibi reverse proxy kullanın.

### Monitoring ve Alerting

Prometheus + Grafana ekleyin:

```yaml
# docker-compose.yml'e ekleyin
  prometheus:
    image: prom/prometheus
    # ... config

  grafana:
    image: grafana/grafana
    # ... config
```

## 📚 Ek Kaynaklar

- [Blockscout Resmi Dokümantasyon](https://docs.blockscout.com)
- [Blockscout GitHub](https://github.com/blockscout/blockscout)
- [Blockscout API Dokümantasyonu](https://docs.blockscout.com/for-users/api)
- [Monad Dokümantasyon](https://docs.monad.xyz)

## 🤝 Destek

- Blockscout Discord: https://discord.gg/blockscout
- GitHub Issues: https://github.com/blockscout/blockscout/issues

## 📝 License

Blockscout is licensed under GPL-3.0

---

**🎉 Başarılı bir şekilde kurulum yaptıysanız, explorer'ınız http://localhost adresinde çalışıyor olmalı!**

**Performans sonuçlarınızı bizimle paylaşmayı unutmayın! 🚀**
