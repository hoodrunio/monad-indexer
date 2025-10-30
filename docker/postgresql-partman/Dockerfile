# PostgreSQL with pg_partman extension for CloudNativePG
# Based on official CloudNativePG image
# Multi-platform support: linux/amd64, linux/arm64
FROM ghcr.io/cloudnative-pg/postgresql:17

USER root

# Install pg_partman extension
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-17-partman \
    ; \
    rm -rf /var/lib/apt/lists/*

USER 26

# Verify installation (optional - remove to speed up build)
RUN ls -la /usr/share/postgresql/17/extension/ | grep partman || echo "Warning: pg_partman files not found"
