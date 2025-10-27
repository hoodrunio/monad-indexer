#!/bin/bash

# Monad Blockscout PoC - Quick Start Script
# ==========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo "Monad Blockscout PoC - Quick Start"
echo "======================================"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker not installed!${NC}"
    echo "Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check Docker Compose
if ! docker compose version &> /dev/null 2>&1; then
    echo -e "${RED}Error: Docker Compose v2 not installed!${NC}"
    echo "Install Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi

echo -e "${GREEN}✓ Docker and Docker Compose installed${NC}"
echo ""

# Check .env file
if [ ! -f .env ]; then
    echo -e "${YELLOW}Creating .env file from example...${NC}"
    cp .env.example .env
    echo -e "${GREEN}✓ .env file created${NC}"
else
    echo -e "${GREEN}✓ .env file exists${NC}"
fi

echo ""

# Check SECRET_KEY_BASE
if ! grep -q "SECRET_KEY_BASE=" envs/common-blockscout.env; then
    echo -e "${YELLOW}WARNING: SECRET_KEY_BASE not found!${NC}"
else
    if grep -q "PLEASE_REPLACE_THIS" envs/common-blockscout.env; then
        echo -e "${YELLOW}⚠ WARNING: SECRET_KEY_BASE needs to be changed!${NC}"
        echo ""
        read -p "Would you like to generate a new SECRET_KEY_BASE? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v openssl &> /dev/null; then
                NEW_KEY=$(openssl rand -base64 64 | tr -d '\n')
                # Escape special characters for sed
                ESCAPED_KEY=$(printf '%s\n' "$NEW_KEY" | sed 's/[[\.*^$/]/\\&/g')
                sed -i.bak "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$NEW_KEY|" envs/common-blockscout.env
                echo -e "${GREEN}✓ SECRET_KEY_BASE generated and saved${NC}"
                echo -e "${YELLOW}Backup saved as envs/common-blockscout.env.bak${NC}"
            else
                echo -e "${RED}OpenSSL not found!${NC}"
                echo "Generate manually: openssl rand -base64 64"
                echo "Then add to envs/common-blockscout.env"
                exit 1
            fi
        else
            echo -e "${YELLOW}Please edit envs/common-blockscout.env and set SECRET_KEY_BASE${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✓ SECRET_KEY_BASE is set${NC}"
    fi
fi

echo ""
echo "🔧 Configuration Check"
echo "====================="

# Show current configuration
echo -e "${BLUE}RPC Endpoint:${NC} $(grep ETHEREUM_JSONRPC_HTTP_URL .env | cut -d'=' -f2)"
echo -e "${BLUE}Database Password:${NC} $(grep POSTGRES_PASSWORD .env | cut -d'=' -f2)"
echo ""

read -p "Configuration looks good? Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted. Please edit .env and envs/common-blockscout.env files."
    exit 1
fi

echo ""
echo "🚀 Starting Blockscout..."
echo "========================"

# Pull images
echo "📥 Pulling Docker images (this may take a while)..."
docker compose pull

# Start services
echo ""
echo "🔧 Starting services..."
docker compose up -d

# Wait for services
echo ""
echo "⏳ Waiting for services to be ready..."
sleep 15

# Check if backend is running
MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker compose ps | grep -q "backend.*Up"; then
        echo -e "${GREEN}✓ Backend is running${NC}"
        break
    fi
    echo -n "."
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}✗ Backend failed to start${NC}"
    echo "Check logs: docker compose logs backend"
    exit 1
fi

echo ""
echo "======================================"
echo "✅ Blockscout Started Successfully!"
echo "======================================"
echo ""
echo "🌐 Access Points:"
echo "  • Explorer:  http://localhost"
echo "  • API:       http://localhost/api/v2/"
echo "  • API Docs:  http://localhost/api-docs"
echo "  • Stats:     http://localhost:8080"
echo ""
echo "📊 Useful Commands:"
echo "  • View logs:      docker compose logs -f"
echo "  • View backend:   docker compose logs -f backend"
echo "  • Check status:   docker compose ps"
echo "  • Stop services:  docker compose down"
echo ""
echo "⏳ Initial indexing has started!"
echo "   Monitor progress: docker compose logs -f backend | grep 'Imported'"
echo ""
echo "💡 Tips:"
echo "  • First sync will take time depending on chain height"
echo "  • Use your own Monad node for best performance"
echo "  • Check README.md for optimization tips"
echo ""
echo "======================================"

# Offer to show logs
read -p "Would you like to view the logs now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose logs -f
fi
