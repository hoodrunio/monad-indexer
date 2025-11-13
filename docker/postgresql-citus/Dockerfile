# PostgreSQL with Citus + pg_cron extensions
# Based on official Citus Data image
# Multi-platform support: linux/amd64, linux/arm64
FROM citusdata/citus:latest

USER root

# Install pg_cron extension and barman-cli-cloud for backups
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-17-cron \
        barman-cli-cloud \
    ; \
    rm -rf /var/lib/apt/lists/*

USER postgres

# Verify extensions are available (optional - remove to speed up build)
RUN echo "Installed extensions:" && \
    ls -la /usr/share/postgresql/17/extension/ | grep -E "(citus|cron)" || echo "Warning: Extension files not found"
