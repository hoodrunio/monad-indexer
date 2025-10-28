#!/bin/bash

# Deploy CORS configuration to server
# This script updates microservices with CORS support and exposes ports

SERVER="root@46.62.226.167"
REMOTE_PATH="/root/indexer"

echo "🚀 Deploying CORS configuration to $SERVER..."
echo ""

# 1. Sync environment files with CORS configuration
echo "📦 Syncing environment files (CORS enabled)..."
scp envs/common-smart-contract-verifier.env $SERVER:$REMOTE_PATH/envs/
scp envs/common-sig-provider.env $SERVER:$REMOTE_PATH/envs/

# 2. Sync service files with exposed ports
echo "📦 Syncing service files (ports exposed)..."
scp services/smart-contract-verifier.yml $SERVER:$REMOTE_PATH/services/
scp services/sig-provider.yml $SERVER:$REMOTE_PATH/services/

# 3. Restart services
echo ""
echo "🔄 Restarting microservices..."
ssh $SERVER "cd $REMOTE_PATH && docker compose stop smart-contract-verifier sig-provider && docker compose rm -f smart-contract-verifier sig-provider && docker compose up -d"

echo ""
echo "⏳ Waiting for services to start..."
sleep 5

# 4. Test CORS
echo ""
echo "🧪 Testing CORS configuration..."
echo ""

echo "Testing smart-contract-verifier health endpoint:"
curl -I http://46.62.226.167:8051/health 2>&1 | grep -i "access-control-allow-origin" || echo "❌ No CORS header found"

echo ""
echo "Testing verifier API with Origin header:"
curl -H "Origin: http://localhost:9090" -I http://46.62.226.167:8051/api/v2/verifier/solidity/versions 2>&1 | grep -i "access-control-allow-origin" || echo "❌ No CORS header found"

echo ""
echo "Testing sig-provider API:"
curl -H "Origin: http://localhost:9090" -I "http://46.62.226.167:8050/api/v1/abi/function?txInput=0xa9059cbb" 2>&1 | grep -i "access-control-allow-origin" || echo "❌ No CORS header found"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Next steps:"
echo "1. Test from your UI at http://localhost:9090"
echo "2. Check browser console - CORS error should be gone"
echo "3. Verify endpoints:"
echo "   - http://46.62.226.167:8051/api/v2/verifier/solidity/versions"
echo "   - http://46.62.226.167:8050/api/v1/abi/function?txInput=0x..."
