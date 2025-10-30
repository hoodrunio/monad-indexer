#!/bin/bash
# Force kill Docker/OrbStack when it hangs
# Usage: ./kill-docker.sh

echo "🔪 Killing all Docker/OrbStack processes..."

# Kill all Docker-related processes
killall -9 OrbStack "OrbStack Helper" docker docker-compose docker-credential-osxkeychain containerd 2>/dev/null
pkill -9 -f "docker|orbstack|containerd" 2>/dev/null

sleep 2

# Verify
if pgrep -q "docker|OrbStack|containerd"; then
    echo "⚠️  Some processes still running:"
    pgrep -fl "docker|OrbStack|containerd"
    echo ""
    echo "Try running with sudo:"
    echo "  sudo ./kill-docker.sh"
else
    echo "✅ All Docker processes killed"
    echo ""
    echo "To restart:"
    echo "  open -a OrbStack"
fi
