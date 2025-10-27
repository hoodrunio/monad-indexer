# Monad Testnet Indexer

Monad testnet için Blockscout tabanlı blockchain indexer ve API servisi.

## Servisler

- **Backend (Indexer + API)**: Port 4000
- **PostgreSQL Database**: Port 7432
- **Redis Cache**: Internal only

## Hızlı Başlangıç

### Servisleri Başlatma

```bash
docker compose -f docker-compose.monad.yml up -d
```

### Durum Kontrolü

```bash
docker compose -f docker-compose.monad.yml ps
```

### Logları İzleme

```bash
# Tüm servisler
docker compose -f docker-compose.monad.yml logs -f

# Sadece backend
docker logs -f backend
```

### Servisleri Durdurma

```bash
docker compose -f docker-compose.monad.yml down
```

## API Endpoints

Backend API'ye erişim: `http://localhost:4000`

### Örnek API Çağrıları

```bash
# Genel istatistikler
curl http://localhost:4000/api/v2/stats | jq

# Blokları listele
curl http://localhost:4000/api/v2/blocks | jq

# Transaction'ları listele
curl http://localhost:4000/api/v2/transactions | jq

# Belirli bir blok
curl http://localhost:4000/api/v2/blocks/{block_number} | jq

# Belirli bir adres
curl http://localhost:4000/api/v2/addresses/{address} | jq
```

## Konfigürasyon

### RPC Endpoints

Default olarak Monad testnet RPC kullanılıyor:
- HTTP: `https://testnet-rpc.monad.xyz`
- WebSocket: `wss://testnet-rpc.monad.xyz`
- Chain ID: `10143`

Farklı RPC kullanmak için environment variables ekleyin:

```bash
export ETHEREUM_JSONRPC_HTTP_URL=https://your-rpc-url
export ETHEREUM_JSONRPC_WS_URL=wss://your-rpc-url
docker compose -f docker-compose.monad.yml up -d
```

### Veritabanı

PostgreSQL database ayarları `services/db.yml` dosyasında:
- User: `blockscout`
- Password: `ceWb1MeLBEeOIfk65gU8EjF8`
- Database: `blockscout`
- Port: `7432` (host) → `5432` (container)

### Backend Ayarları

Backend konfigürasyonu `envs/common-blockscout.env` dosyasında bulunur.

## Sorun Giderme

### Rate Limit Hataları

Monad testnet public RPC'si rate limit uyguluyor. Logda şu hatayı görebilirsiniz:

```
25/second request limit reached - reduce calls per second or upgrade your account
```

Bu normal bir durumdur. Backend otomatik retry yapar. Daha hızlı indexing için:
- Kendi Monad node'unuzu çalıştırın
- Ücretli RPC servisi kullanın

### Container'lar Başlamıyorsa

```bash
# Logları kontrol edin
docker compose -f docker-compose.monad.yml logs

# Temiz başlangıç için
docker compose -f docker-compose.monad.yml down -v
docker compose -f docker-compose.monad.yml up -d
```

### Veritabanı Sorunları

```bash
# PostgreSQL'e bağlan
docker exec -it db psql -U blockscout -d blockscout

# Tablo sayısını kontrol et
\dt

# Çıkış
\q
```

## Teknik Detaylar

- **Platform**: Docker Compose
- **Blockscout Version**: Latest (9.0.2+)
- **PostgreSQL**: Version 17
- **Redis**: Alpine
- **Architecture**: ARM64 için AMD64 emulation (Apple Silicon)

## API Dokümantasyonu

Blockscout API v2 dokümantasyonu:
https://docs.blockscout.com/for-users/api

## Notlar

- İlk başlatmada veritabanı migration'ları çalışır (1-2 dakika sürebilir)
- Indexing genesis blokundan başlar ve güncel bloklara kadar devam eder
- Rate limit nedeniyle tam sync zamanı uzun olabilir
- Sadece backend (indexer + API) çalışıyor, UI servisleri devre dışı
