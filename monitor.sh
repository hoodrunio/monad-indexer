#!/bin/bash

# Monad Blockscout - Monitoring Script
# =====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "======================================"
echo "Monad Blockscout - System Monitor"
echo "======================================"
echo ""

# Check if backend is running
if ! docker compose ps | grep -q "backend.*Up"; then
    echo -e "${RED}Error: Backend is not running!${NC}"
    echo "Start with: docker compose up -d"
    exit 1
fi

echo -e "${GREEN}✓ Backend is running${NC}"
echo ""

echo "📊 Database Metrics"
echo "=================="

# Block count
BLOCKS=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT COUNT(*) FROM blocks WHERE consensus = true;" 2>/dev/null | xargs)
echo -e "Indexed blocks: ${GREEN}${BLOCKS}${NC}"

# Latest block
LATEST=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT MAX(number) FROM blocks WHERE consensus = true;" 2>/dev/null | xargs)
echo -e "Latest block: ${GREEN}${LATEST}${NC}"

# Transaction count
TXS=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT COUNT(*) FROM transactions;" 2>/dev/null | xargs)
echo -e "Transactions: ${GREEN}${TXS}${NC}"

# Address count
ADDRESSES=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT COUNT(*) FROM addresses;" 2>/dev/null | xargs)
echo -e "Unique addresses: ${GREEN}${ADDRESSES}${NC}"

# Average tx per block
if [ "$BLOCKS" != "0" ] && [ ! -z "$BLOCKS" ]; then
    AVG_TX=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT ROUND(AVG(tx_count)::numeric, 2) FROM (SELECT COUNT(*) as tx_count FROM transactions GROUP BY block_hash LIMIT 1000) as tx_per_block;" 2>/dev/null | xargs)
    if [ ! -z "$AVG_TX" ]; then
        echo -e "Avg tx/block: ${GREEN}${AVG_TX}${NC}"
    fi
fi

# Database size
DB_SIZE=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT pg_size_pretty(pg_database_size('blockscout'));" 2>/dev/null | xargs)
echo -e "Database size: ${GREEN}${DB_SIZE}${NC}"

echo ""
echo "⏱️  Indexing Speed (last 5 minutes)"
echo "==================================="

CACHE_FILE="/tmp/monad_blockscout_monitor.cache"
CURRENT_TIME=$(date +%s)

if [ -f "$CACHE_FILE" ]; then
    LAST_TIME=$(cat "$CACHE_FILE" | cut -d',' -f1)
    LAST_BLOCKS=$(cat "$CACHE_FILE" | cut -d',' -f2)
    LAST_TXS=$(cat "$CACHE_FILE" | cut -d',' -f3)
    
    TIME_DIFF=$((CURRENT_TIME - LAST_TIME))
    if [ $TIME_DIFF -gt 0 ]; then
        BLOCK_DIFF=$((BLOCKS - LAST_BLOCKS))
        TX_DIFF=$((TXS - LAST_TXS))
        
        BLOCKS_PER_SEC=$(echo "scale=2; $BLOCK_DIFF / $TIME_DIFF" | bc 2>/dev/null || echo "N/A")
        TXS_PER_SEC=$(echo "scale=2; $TX_DIFF / $TIME_DIFF" | bc 2>/dev/null || echo "N/A")
        
        echo -e "Blocks/sec: ${GREEN}${BLOCKS_PER_SEC}${NC}"
        echo -e "Tx/sec: ${GREEN}${TXS_PER_SEC}${NC}"
        
        # Performance indicator
        if [ "$TXS_PER_SEC" != "N/A" ]; then
            PERF_NUM=$(echo "$TXS_PER_SEC" | cut -d'.' -f1)
            if [ $PERF_NUM -gt 5000 ]; then
                echo -e "${GREEN}✓ Excellent performance! (>5000 tx/s)${NC}"
            elif [ $PERF_NUM -gt 3000 ]; then
                echo -e "${YELLOW}⚡ Good performance (>3000 tx/s)${NC}"
            elif [ $PERF_NUM -gt 1000 ]; then
                echo -e "${YELLOW}⚠ Moderate performance (<3000 tx/s)${NC}"
                echo "  Consider optimizing (see README.md)"
            else
                echo -e "${RED}⚠ Slow indexing (<1000 tx/s)${NC}"
                echo "  Check RPC connection and increase concurrency"
            fi
        fi
    fi
fi

# Update cache
echo "$CURRENT_TIME,$BLOCKS,$TXS" > "$CACHE_FILE"

echo ""
echo "🔍 Internal Transactions Status"
echo "==============================="

PENDING_INTERNAL=$(docker exec postgres psql -U postgres -d blockscout -t -c "SELECT COUNT(*) FROM blocks WHERE internal_transactions_indexed_at IS NULL AND consensus = true;" 2>/dev/null | xargs)
echo -e "Pending blocks: ${YELLOW}${PENDING_INTERNAL}${NC}"

echo ""
echo "💻 Container Resources"
echo "====================="

# Backend stats
BACKEND_STATS=$(docker stats backend --no-stream --format "CPU: {{.CPUPerc}} | Mem: {{.MemUsage}}" 2>/dev/null)
echo -e "Backend:  ${GREEN}${BACKEND_STATS}${NC}"

# Database stats
DB_STATS=$(docker stats postgres --no-stream --format "CPU: {{.CPUPerc}} | Mem: {{.MemUsage}}" 2>/dev/null)
echo -e "Database: ${GREEN}${DB_STATS}${NC}"

# Stats service
STATS_STATS=$(docker stats stats --no-stream --format "CPU: {{.CPUPerc}} | Mem: {{.MemUsage}}" 2>/dev/null)
echo -e "Stats:    ${GREEN}${STATS_STATS}${NC}"

echo ""
echo "🌐 API Health Check"
echo "==================="

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/v1/health 2>/dev/null)
if [ "$API_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ API is healthy${NC}"
else
    echo -e "${RED}✗ API is not responding (HTTP $API_STATUS)${NC}"
fi

echo ""
echo "📋 Recent Logs"
echo "=============="
docker compose logs backend --tail=5 2>&1 | grep -v "password"

echo ""
echo "======================================"
echo "Monitor Commands:"
echo "  • Live logs:      docker compose logs -f backend"
echo "  • All services:   docker compose ps"
echo "  • Database shell: docker exec -it postgres psql -U postgres blockscout"
echo "  • Continuous monitor: watch -n 30 $0"
echo "======================================"
