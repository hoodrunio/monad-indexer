# Monad Testnet Indexer

Full-featured blockchain indexer and API service for Monad testnet, powered by Blockscout.

## Services

### Core Services
- **Backend (Indexer + API)**: Port 4000 - Indexes blocks, transactions, logs, addresses
- **PostgreSQL Database**: Port 7432 - Complete blockchain data storage
- **Redis Cache**: Internal only - Caching layer

### Microservices (Full Data Indexing)
- **Smart Contract Verifier**: Contract verification service
- **Sig-Provider**: Function signature provider (resolves method names)
- **Visualizer**: Sol2UML contract visualization
- **Stats**: Blockchain statistics and analytics service (with separate database)

## Quick Start

### Deployment Options

The indexer supports modular deployment for different use cases:

#### 1. Full Stack (Recommended)
All services including backend, microservices, and statistics:
```bash
docker compose up -d
```

#### 2. Minimal Setup
Only core indexer and database (no microservices):
```bash
docker compose -f docker-compose.base.yml -f docker-compose.backend.yml up -d
```

#### 3. With Statistics
Core indexer + statistics service:
```bash
docker compose -f docker-compose.base.yml -f docker-compose.backend.yml -f docker-compose.stats.yml up -d
```

#### 4. With Microservices
Core indexer + all microservices (no stats):
```bash
docker compose -f docker-compose.base.yml -f docker-compose.backend.yml -f docker-compose.microservices.yml up -d
```

### Check Status

```bash
docker compose ps
```

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker logs -f backend
docker logs -f stats
```

### Stop Services

```bash
docker compose down
```

## API Endpoints

Backend API is accessible at: `http://localhost:4000`

### Example API Calls

```bash
# General statistics
curl http://localhost:4000/api/v2/stats | jq

# List blocks
curl http://localhost:4000/api/v2/blocks | jq

# List transactions
curl http://localhost:4000/api/v2/transactions | jq

# Get specific block
curl http://localhost:4000/api/v2/blocks/{block_number} | jq

# Get specific address
curl http://localhost:4000/api/v2/addresses/{address} | jq
```

## Configuration

### RPC Endpoints

By default, uses Monad testnet RPC:
- HTTP: `https://testnet-rpc.monad.xyz`
- WebSocket: `wss://testnet-rpc.monad.xyz`
- Chain ID: `10143`

To use a different RPC, set environment variables:

```bash
export ETHEREUM_JSONRPC_HTTP_URL=https://your-rpc-url
export ETHEREUM_JSONRPC_WS_URL=wss://your-rpc-url
docker compose -f docker-compose.monad.yml up -d
```

### Database

PostgreSQL database settings in `services/db.yml`:
- User: `blockscout`
- Password: `ceWb1MeLBEeOIfk65gU8EjF8`
- Database: `blockscout`
- Port: `7432` (host) → `5432` (container)

### Backend Settings

Backend configuration is in `envs/common-blockscout.env`

## Troubleshooting

### Rate Limit Errors

Monad testnet public RPC has rate limits. You may see this error in logs:

```
25/second request limit reached - reduce calls per second or upgrade your account
```

This is normal. The backend automatically retries. For faster indexing:
- Run your own Monad node
- Use a paid RPC service

### Containers Won't Start

```bash
# Check logs
docker compose -f docker-compose.monad.yml logs

# Fresh start
docker compose -f docker-compose.monad.yml down -v
docker compose -f docker-compose.monad.yml up -d
```

### Database Issues

```bash
# Connect to PostgreSQL
docker exec -it db psql -U blockscout -d blockscout

# Check table count
\dt

# Exit
\q
```

## Technical Details

- **Platform**: Docker Compose
- **Blockscout Version**: Latest (9.0.2+)
- **PostgreSQL**: Version 17
- **Redis**: Alpine
- **Architecture**: AMD64 emulation for ARM64 (Apple Silicon)

## API Documentation

Blockscout API v2 documentation:
https://docs.blockscout.com/for-users/api

## Indexed Data

✅ **Blocks** - All block details and metadata
✅ **Transactions** - Transaction details, input data, gas information
✅ **Logs** - Event logs and contract events
✅ **Addresses** - All address information and balances
✅ **Contracts** - Smart contract information
✅ **Internal Transactions** - Internal calls and traces
✅ **Token Transfers** - ERC20/ERC721/ERC1155 transfers
✅ **NFTs** - NFT metadata, images, and ownership tracking
✅ **Function Signatures** - Method signature resolution
✅ **Contract Verification** - Smart contract source code verification
✅ **Statistics** - Daily transaction counts, charts, trends, and analytics

## Notes

- Initial startup runs database migrations (1-2 minutes)
- Indexing starts from genesis block and continues to latest blocks
- Full sync may take time due to rate limits
- **Only backend + microservices are running**, UI services disabled for performance
- All blockchain data is accessible via API
