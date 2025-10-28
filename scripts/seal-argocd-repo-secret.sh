#!/bin/bash
# Script to create sealed secret for ArgoCD repository credentials
set -e

echo "🔐 Creating Sealed Secret for ArgoCD Repository Credentials"

# Check if kubeseal is installed
if ! command -v kubeseal &> /dev/null; then
    echo "❌ kubeseal not found. Installing..."
    wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
    tar xfz kubeseal-0.24.0-linux-amd64.tar.gz
    sudo install -m 755 kubeseal /usr/local/bin/kubeseal
    rm kubeseal-0.24.0-linux-amd64.tar.gz kubeseal
fi

# Get GitHub token
echo "Enter your GitHub Personal Access Token:"
read -s GITHUB_TOKEN
echo ""

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Token cannot be empty"
    exit 1
fi

# Create sealed secret
echo "🔒 Sealing secret..."
kubectl create secret generic monad-indexer-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/hoodrunio/monad-indexer.git \
  --from-literal=username=hoodrunio \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | \
  kubectl label -f - argocd.argoproj.io/secret-type=repository --local -o yaml | \
  kubeseal -o yaml > argocd/sealed-repository-credentials.yaml

echo "✅ Sealed secret created: argocd/sealed-repository-credentials.yaml"
echo ""
echo "📝 Next steps:"
echo "   1. git add argocd/sealed-repository-credentials.yaml"
echo "   2. git commit -m 'Add sealed ArgoCD repo credentials'"
echo "   3. git push"
echo "   4. kubectl apply -f argocd/sealed-repository-credentials.yaml"
echo ""
echo "🗑️  Cleaning up plain-text credentials..."
if [ -f argocd/repository-credentials.yaml ]; then
    git checkout argocd/repository-credentials.yaml 2>/dev/null || true
    echo "   ✓ Reverted argocd/repository-credentials.yaml to template"
fi
