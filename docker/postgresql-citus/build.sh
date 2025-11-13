#!/bin/bash
# Build and push PostgreSQL + Citus + pg_cron image
# Supports multi-platform (ARM64 Mac + AMD64 K8s)

set -euo pipefail

IMAGE_NAME="ghcr.io/hoodrunio/postgresql-citus"
IMAGE_TAG="17-citus13.2"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=================================================="
echo "Building PostgreSQL + Citus + pg_cron Image"
echo "=================================================="
echo "Image: ${FULL_IMAGE}"
echo "Base: citusdata/citus:latest (PG 17.6 + Citus 13.2.0)"
echo "Extensions: citus, pg_cron"
echo "Platforms: linux/amd64"
echo ""

# Check if buildx builder exists
if ! docker buildx inspect multiplatform >/dev/null 2>&1; then
    echo "Creating buildx builder 'multiplatform'..."
    docker buildx create --name multiplatform --driver docker-container --use
    docker buildx inspect --bootstrap
fi

echo ""
echo "Building and pushing..."
echo ""

docker buildx build \
    --platform linux/amd64 \
    -t "${FULL_IMAGE}" \
    -t "${IMAGE_NAME}:latest" \
    -f docker/postgresql-citus/Dockerfile \
    --push \
    .

echo ""
echo "=================================================="
echo "Build Complete!"
echo "=================================================="
echo "Image pushed to: ${FULL_IMAGE}"
echo "Also tagged as: ${IMAGE_NAME}:latest"
echo ""
echo "Next steps:"
echo "1. Update values.yaml with:"
echo "   postgresql.image.registry: ghcr.io"
echo "   postgresql.image.repository: hoodrunio/postgresql-citus"
echo "   postgresql.image.tag: ${IMAGE_TAG}"
echo "2. Enable Citus: postgresql.citus.enabled: true"
echo "3. Commit and push changes"
echo "4. Deploy and verify extensions loaded"
echo "=================================================="
