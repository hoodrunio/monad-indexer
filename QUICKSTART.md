# 🚀 Quick Start Guide - Monad Blockscout PoC

## En Hızlı Yol (3 Komut!)

```bash
./start.sh
```

Evet, bu kadar! Script sizin için her şeyi yapacak:
- ✅ .env dosyası oluşturur
- ✅ SECRET_KEY_BASE generate eder
- ✅ Docker image'ları indirir
- ✅ Servisleri başlatır
- ✅ Health check yapar

**Tahmini süre:** 5-10 dakika (internet hızınıza bağlı)

---

## Manuel Kurulum (İsterseniz)

### 1️⃣ Environment Setup

```bash
# .env dosyası oluştur
cp .env.example .env

# .env'i düzenle (opsiyonel)
nano .env
```

### 2️⃣ Secret Key Oluştur

```bash
# Key oluştur
openssl rand -base64 64

# Çıktıyı kopyala ve envs/common-blockscout.env'deki 
# SECRET_KEY_BASE= satırına yapıştır
nano envs/common-blockscout.env
```

### 3️⃣ Başlat

```bash
docker compose up -d
```

### 4️⃣ Kontrol Et

```bash
# Servislerin durumunu kontrol et
docker compose ps

# Logları izle
docker compose logs -f backend
```

---

## ⚡ İlk Erişim

5-10 dakika sonra (ilk sync başladıktan sonra):

- **Explorer**: http://localhost
- **API**: http://localhost/api/v2/stats
- **API Docs**: http://localhost/api-docs

---

## 📊 İzleme

```bash
# Monitoring script çalıştır
./monitor.sh

# Veya sürekli izle (30 saniyede bir günceller)
watch -n 30 ./monitor.sh

# Canlı loglar
docker compose logs -f backend
```

---

## 🔧 Yaygın Sorunlar

### "Backend başlamıyor"

```bash
# Logları kontrol et
docker compose logs backend

# Muhtemelen SECRET_KEY_BASE eksik
# ./start.sh scriptini kullan veya manuel olarak ayarla
```

### "Database connection error"

```bash
# Database'in hazır olmasını bekle
docker compose ps

# Restart dene
docker compose restart backend
```

### "Port already in use"

```bash
# docker-compose.yml'de portları değiştir
# Örnek: 80 → 8000
nano docker-compose.yml
```

---

## 🎯 Performans İpuçları

### Hızlı İlk Sync İçin

**envs/common-blockscout.env** dosyasında:

```bash
# Internal tx'leri geçici olarak devre dışı bırak
INDEXER_DISABLE_INTERNAL_TRANSACTIONS_FETCHER=true

# Pending tx'leri devre dışı bırak
INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER=true
```

### Kendi Node'unuzu Kullanın

.env dosyasında:

```bash
ETHEREUM_JSONRPC_HTTP_URL=http://your-monad-node:8545
ETHEREUM_JSONRPC_TRACE_URL=http://your-monad-node:8545
```

Public RPC yavaş olacaktır!

---

## 📚 Daha Fazla Bilgi

Detaylı dokümantasyon için **README.md** dosyasını okuyun.

---

## 🆘 Yardım

```bash
# Monitoring
./monitor.sh

# Tüm loglar
docker compose logs -f

# Servislerin durumu
docker compose ps

# Durdur
docker compose down

# Yeniden başlat
docker compose restart
```

---

**🎉 Başarılar!**

Sorularınız için: [Blockscout Discord](https://discord.gg/blockscout)
