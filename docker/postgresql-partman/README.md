# PostgreSQL + pg_partman for CloudNativePG

Custom PostgreSQL image with pg_partman extension for partition-based data retention.

## Build (Multi-platform with buildx)

### One-time setup (if not already done)
```bash
# Create buildx builder
docker buildx create --name multiplatform --driver docker-container --use
docker buildx inspect --bootstrap
```

### Build and push (supports ARM64 Mac + AMD64 servers)
```bash
cd /Users/errorist/Documents/new-projects/monad-indexer

# Build for both platforms and push to registry
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/hoodrunio/postgresql-partman:17 \
  -f docker/postgresql-partman/Dockerfile \
  --push \
  .
```

### Local build only (for testing)
```bash
# Build for current platform only
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/hoodrunio/postgresql-partman:17 \
  -f docker/postgresql-partman/Dockerfile \
  --load \
  .
```

### Verify
```bash
# Check image
docker run --rm ghcr.io/hoodrunio/postgresql-partman:17 \
  ls -la /usr/share/postgresql/17/extension/ | grep partman
```

## Usage

Update `values-dev.yaml`:

```yaml
postgresql:
  image:
    registry: ghcr.io
    repository: hoodrunio/postgresql-partman
    tag: "17"
```

## Includes

- PostgreSQL 17 (CloudNativePG optimized)
- pg_partman extension
- All CloudNativePG features (backup, HA, monitoring)
