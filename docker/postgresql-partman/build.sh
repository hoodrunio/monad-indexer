#!/bin/bash
# Build and push PostgreSQL + pg_partman image
# Supports multi-platform (ARM64 Mac + AMD64 K8s)

set -euo pipefail

IMAGE_NAME="ghcr.io/hoodrunio/postgresql-partman"
IMAGE_TAG="17"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=================================================="
echo "Building PostgreSQL + pg_partman Image"
echo "=================================================="
echo "Image: ${FULL_IMAGE}"
echo "Platforms: linux/amd64, linux/arm64"
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
    --platform linux/amd64,linux/arm64 \
    -t "${FULL_IMAGE}" \
    -t "${IMAGE_NAME}:latest" \
    -f docker/postgresql-partman/Dockerfile \
    --push \
    .

echo ""
echo "=================================================="
echo "Build Complete!"
echo "=================================================="
echo "Image pushed to: ${FULL_IMAGE}"
echo ""
echo "Next steps:"
echo "1. Update values-dev.yaml (already done)"
echo "2. Commit and push changes"
echo "3. Wait for ArgoCD sync"
echo "4. Run test script"
echo "=================================================="
