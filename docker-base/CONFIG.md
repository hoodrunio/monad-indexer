# Configuration Guide

This guide explains how to customize your Monad Indexer setup.

## Configuration Files Structure

```
envs/
├── common-blockscout.env           # Main backend configuration
├── common-stats.env                # Statistics service
├── common-smart-contract-verifier.env  # Contract verification
├── common-sig-provider.env         # Function signature provider
├── common-visualizer.env           # Sol2UML visualizer
└── common-nft-media-handler.env    # NFT media (reference only)

.env                                # Microservice enable/disable flags
docker-compose.*.yml                # Service composition
```

## Quick Customization

### 1. Enable/Disable Microservices

Edit `.env` file:

```bash
# Enable all microservices (full stack)
MICROSERVICE_SC_VERIFIER_ENABLED=true
MICROSERVICE_VISUALIZE_SOL2UML_ENABLED=true
MICROSERVICE_SIG_PROVIDER_ENABLED=true

# Disable microservices (minimal setup)
MICROSERVICE_SC_VERIFIER_ENABLED=false
MICROSERVICE_VISUALIZE_SOL2UML_ENABLED=false
MICROSERVICE_SIG_PROVIDER_ENABLED=false
```

### 2. Change RPC Endpoint

Edit `.env` or set environment variables:

```bash
ETHEREUM_JSONRPC_HTTP_URL=https://your-custom-rpc.com
ETHEREUM_JSONRPC_TRACE_URL=https://your-custom-rpc.com
ETHEREUM_JSONRPC_WS_URL=wss://your-custom-rpc.com
```

### 3. Use External Database

Create `.env.external`:

```bash
DATABASE_URL=postgresql://user:pass@your-db-host:5432/blockscout
REDIS_URL=redis://your-redis-host:6379
```

Then deploy:

```bash
docker compose -f docker-compose.base.yml \
               -f docker-compose.backend.yml \
               -f docker-compose.external-db.yml \
               --env-file .env.external up -d
```

## Configuration Reference

### Backend Configuration
**File**: `envs/common-blockscout.env`

#### Essential Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | See file | PostgreSQL connection string |
| `PORT` | `4000` | API server port |
| `CHAIN_ID` | Set in compose | Blockchain chain ID |
| `POOL_SIZE` | `80` | Database connection pool for indexing |
| `POOL_SIZE_API` | `10` | Database connection pool for API |

#### Performance Tuning

```bash
# Indexer batch sizes (uncomment to customize)
INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=10
INDEXER_CATCHUP_BLOCKS_CONCURRENCY=10
INDEXER_RECEIPTS_BATCH_SIZE=250
INDEXER_RECEIPTS_CONCURRENCY=10
INDEXER_COIN_BALANCES_BATCH_SIZE=100
INDEXER_COIN_BALANCES_CONCURRENCY=10
```

**Guidelines**:
- Increase batch size for faster sync (uses more memory)
- Increase concurrency for parallel processing (uses more CPU)
- Reduce both if hitting rate limits or resource constraints

#### Block Range Limits

```bash
# Index specific block range
FIRST_BLOCK=1000000
LAST_BLOCK=2000000
```

#### Rate Limiting

```bash
# Enable API rate limiting
API_RATE_LIMIT_DISABLED=false
API_RATE_LIMIT_BY_IP=3000              # Requests per time interval
API_RATE_LIMIT_BY_IP_TIME_INTERVAL=5m  # Time window
```

#### IPFS Gateway

```bash
# For NFT metadata fetching
IPFS_GATEWAY_URL=https://ipfs.io/ipfs/
IPFS_PUBLIC_GATEWAY_URL=https://ipfs.io/ipfs/

# Or use your own IPFS gateway
# IPFS_GATEWAY_URL=https://your-ipfs-gateway.com/ipfs/
```

#### Gas Price Oracle

```bash
# Customize gas price calculations
GAS_PRICE_ORACLE_NUM_OF_BLOCKS=200
GAS_PRICE_ORACLE_SAFELOW_PERCENTILE=35
GAS_PRICE_ORACLE_AVERAGE_PERCENTILE=60
GAS_PRICE_ORACLE_FAST_PERCENTILE=90
```

### Stats Service Configuration
**File**: `envs/common-stats.env`

| Variable | Default | Description |
|----------|---------|-------------|
| `STATS__DEFAULT_SCHEDULE` | `0 0 1 * * * *` | Update schedule (daily at 1 AM) |
| `STATS__FORCE_UPDATE_ON_START` | `false` | Force stats update on startup |
| `STATS__BLOCKSCOUT_API_URL` | `http://backend:4000` | Backend API endpoint |

**Schedule Format**: `second minute hour day month weekday year` (cron-like)

Examples:
- `0 0 * * * * *` - Every hour
- `0 0 */6 * * * *` - Every 6 hours
- `0 30 2 * * * *` - Daily at 2:30 AM

### Smart Contract Verifier Configuration
**File**: `envs/common-smart-contract-verifier.env`

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_CONTRACT_VERIFIER__SOLIDITY__ENABLED` | `true` | Enable Solidity verification |
| `SMART_CONTRACT_VERIFIER__VYPER__ENABLED` | `true` | Enable Vyper verification |
| `SMART_CONTRACT_VERIFIER__SOURCIFY__ENABLED` | `true` | Enable Sourcify integration |

**Compiler refresh**: Automatically updates available compiler versions daily

### Signature Provider Configuration
**File**: `envs/common-sig-provider.env`

| Variable | Default | Description |
|----------|---------|-------------|
| `SIG_PROVIDER__METRICS__ENABLED` | `true` | Enable Prometheus metrics |
| `SIG_PROVIDER__METRICS__ADDR` | `0.0.0.0:6060` | Metrics endpoint |

Access metrics: `http://localhost:6060/metrics`

### Visualizer Configuration
**File**: `envs/common-visualizer.env`

Minimal configuration - uses HTTP by default on port 8050.

## Common Scenarios

### Scenario 1: Faster Indexing (More Resources)

Edit `envs/common-blockscout.env`:

```bash
# Increase batch sizes and concurrency
INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=50
INDEXER_CATCHUP_BLOCKS_CONCURRENCY=20
INDEXER_RECEIPTS_BATCH_SIZE=500
INDEXER_RECEIPTS_CONCURRENCY=20
INDEXER_COIN_BALANCES_CONCURRENCY=20
INDEXER_TOKEN_BALANCES_CONCURRENCY=20

# Increase database pool
POOL_SIZE=150
```

**Note**: Requires more CPU, memory, and database connections.

### Scenario 2: Resource-Constrained Environment

Edit `envs/common-blockscout.env`:

```bash
# Reduce batch sizes and concurrency
INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=5
INDEXER_CATCHUP_BLOCKS_CONCURRENCY=2
INDEXER_RECEIPTS_BATCH_SIZE=100
INDEXER_RECEIPTS_CONCURRENCY=2

# Reduce database pool
POOL_SIZE=30
POOL_SIZE_API=5
```

### Scenario 3: Index Only Recent Blocks

Edit `envs/common-blockscout.env`:

```bash
# Start from block 1,000,000
FIRST_BLOCK=1000000
```

### Scenario 4: Production Deployment with External Services

Create `.env.production`:

```bash
# External PostgreSQL
DATABASE_URL=postgresql://prod_user:secure_pass@db.example.com:5432/blockscout

# External Redis
REDIS_URL=redis://redis.example.com:6379

# Production RPC
ETHEREUM_JSONRPC_HTTP_URL=https://rpc.example.com
ETHEREUM_JSONRPC_TRACE_URL=https://rpc.example.com
ETHEREUM_JSONRPC_WS_URL=wss://rpc.example.com

# Enable microservices
MICROSERVICE_SC_VERIFIER_ENABLED=true
MICROSERVICE_VISUALIZE_SOL2UML_ENABLED=true
MICROSERVICE_SIG_PROVIDER_ENABLED=true
```

Deploy:

```bash
docker compose -f docker-compose.backend.yml \
               -f docker-compose.microservices.yml \
               -f docker-compose.stats.yml \
               -f docker-compose.external-db.yml \
               --env-file .env.production up -d
```

## Database Configuration

### PostgreSQL Settings
**File**: `services/db.yml`

Default credentials:
- Username: `blockscout`
- Password: `ceWb1MeLBEeOIfk65gU8EjF8`
- Database: `blockscout`
- Port: `7432` (host) → `5432` (container)

**Change credentials**:

1. Edit `services/db.yml`:
```yaml
environment:
  POSTGRES_PASSWORD: your_new_password
  POSTGRES_USER: your_user
  POSTGRES_DB: your_db
```

2. Update `envs/common-blockscout.env`:
```bash
DATABASE_URL=postgresql://your_user:your_new_password@db:5432/your_db
```

### Stats Database
**File**: `services/stats.yml`

Similar configuration for stats database (`stats-db` service).

## Monitoring & Debugging

### Enable Metrics

Edit `envs/common-sig-provider.env`:
```bash
SIG_PROVIDER__METRICS__ENABLED=true
```

Access at: `http://localhost:6060/metrics`

### View Backend Logs

```bash
# Follow all logs
docker compose logs -f backend

# Search for errors
docker compose logs backend | grep -i error

# Check indexing progress
docker compose logs backend | grep -i "block"
```

### Check Database Stats

```bash
# Connect to PostgreSQL
docker exec -it db psql -U blockscout -d blockscout

# View block count
SELECT COUNT(*) FROM blocks;

# View transaction count
SELECT COUNT(*) FROM transactions;

# Check latest indexed block
SELECT number, timestamp FROM blocks ORDER BY number DESC LIMIT 1;
```

## Environment Variables Priority

Environment variables are loaded in this order (later overwrites earlier):

1. `envs/common-*.env` files (base configuration)
2. `docker-compose.*.yml` environment sections (service-specific)
3. `.env` file in project root (microservice flags)
4. Shell environment variables (runtime overrides)

Example:

```bash
# Override RPC endpoint at runtime
ETHEREUM_JSONRPC_HTTP_URL=https://custom-rpc.com docker compose up -d
```

## Validation

After changing configuration, validate with:

```bash
# Check compose file syntax
docker compose config

# Verify environment variables
docker compose config | grep ETHEREUM_JSONRPC

# Test backend connection
docker compose up backend -d
docker compose logs backend | grep "Started"
```

## Troubleshooting

### Issue: Backend won't start

Check environment variables:
```bash
docker compose exec backend env | grep DATABASE_URL
docker compose exec backend env | grep ETHEREUM_JSONRPC
```

### Issue: Slow indexing

Increase concurrency in `envs/common-blockscout.env` and restart:
```bash
docker compose restart backend
```

### Issue: Rate limit errors

Reduce batch sizes or add delays:
```bash
# In envs/common-blockscout.env
INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=5
INDEXER_CATCHUP_BLOCK_INTERVAL=2000  # 2 second delay
```

## Best Practices

1. **Always backup** `.env` and `envs/` before changes
2. **Test changes** in development before production
3. **Use external databases** for production (see Scenario 4)
4. **Monitor resources** after tuning performance settings
5. **Keep secrets secure** - never commit passwords to git
6. **Version control** your configuration (except secrets)

## Security Notes

- Change default database passwords in production
- Use strong `SECRET_KEY_BASE` for production
- Enable API rate limiting in production
- Consider firewall rules for exposed ports
- Use HTTPS for external RPC endpoints
- Regularly update Docker images

## Getting Help

- Check logs: `docker compose logs -f backend`
- Validate config: `docker compose config`
- Review README.md for deployment options
- Check Blockscout docs: https://docs.blockscout.com
