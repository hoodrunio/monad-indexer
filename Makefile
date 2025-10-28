.PHONY: help setup-sealed-secrets seal-secrets deploy install-kubeseal check-kubeseal verify-secrets clean

# Configuration
NAMESPACE ?= monad-indexer-dev
HELM_RELEASE ?= monad-indexer
CHART_PATH ?= charts/monad-indexer
VALUES_FILE ?= values.yaml
ENV ?= dev
ENV_VALUES_FILE ?= $(CHART_PATH)/environments/values-$(ENV).yaml

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'

check-kubeseal: ## Check if kubeseal is installed
	@command -v kubeseal >/dev/null 2>&1 || { echo "Error: kubeseal is not installed. Run 'make install-kubeseal' first."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl is not installed."; exit 1; }
	@echo "✓ Prerequisites OK"

install-kubeseal: ## Install kubeseal CLI tool (macOS only)
	@echo "Installing kubeseal..."
	@if [[ "$$(uname)" == "Darwin" ]]; then \
		brew install kubeseal; \
	else \
		echo "Please install kubeseal manually: https://github.com/bitnami-labs/sealed-secrets#installation"; \
		exit 1; \
	fi

setup-sealed-secrets: ## Install Sealed Secrets controller in Kubernetes cluster
	@echo "Setting up Sealed Secrets controller..."
	@helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
	@helm repo update
	@if helm status sealed-secrets-controller -n kube-system >/dev/null 2>&1; then \
		echo "✓ Sealed Secrets controller already installed"; \
	else \
		echo "Installing Sealed Secrets controller..."; \
		helm install sealed-secrets-controller sealed-secrets/sealed-secrets \
			--namespace kube-system \
			--create-namespace; \
	fi
	@echo "Waiting for controller to be ready..."
	@kubectl wait --for=condition=ready pod \
		-l app.kubernetes.io/name=sealed-secrets \
		-n kube-system \
		--timeout=300s
	@echo "✓ Sealed Secrets controller ready"

seal-secrets: check-kubeseal ## Generate and seal all secrets for the application
	@echo "Generating and sealing secrets..."
	@NAMESPACE=$(NAMESPACE) ./scripts/seal-secrets.sh
	@echo "✓ Secrets sealed successfully"

verify-secrets: ## Verify sealed secrets in the cluster
	@echo "Checking sealed secrets in namespace: $(NAMESPACE)"
	@kubectl get sealedsecrets -n $(NAMESPACE)
	@echo ""
	@echo "Checking decrypted secrets:"
	@kubectl get secrets -n $(NAMESPACE) | grep monad-indexer || echo "No secrets found"

apply-sealed-secrets: ## Apply existing sealed secrets to cluster (use existing files)
	@echo "Applying sealed secrets from templates..."
	@if [ -f "$(CHART_PATH)/templates/backend/sealed-secret.yaml" ]; then \
		echo "Applying backend sealed secret..."; \
		kubectl apply -f $(CHART_PATH)/templates/backend/sealed-secret.yaml; \
	else \
		echo "⚠️  Backend sealed secret not found. Run 'make seal-secrets' first."; \
	fi
	@if [ -f "$(CHART_PATH)/templates/postgresql/sealed-secret.yaml" ]; then \
		echo "Applying PostgreSQL sealed secret..."; \
		kubectl apply -f $(CHART_PATH)/templates/postgresql/sealed-secret.yaml; \
	else \
		echo "⚠️  PostgreSQL sealed secret not found. Run 'make seal-secrets' first."; \
	fi
	@if [ -f "$(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml" ]; then \
		echo "Applying Stats PostgreSQL sealed secret..."; \
		kubectl apply -f $(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml; \
	else \
		echo "⚠️  Stats PostgreSQL sealed secret not found. Run 'make seal-secrets' first."; \
	fi
	@echo "✓ Sealed secrets applied"
	@echo ""
	@echo "Waiting for secrets to be decrypted..."
	@sleep 3
	@kubectl get secrets -n $(NAMESPACE) | grep monad-indexer || echo "Secrets not yet available"

list-sealed-secrets: ## List all sealed secret files in the chart
	@echo "Sealed secret files in chart:"
	@find $(CHART_PATH)/templates -name "sealed-secret.yaml" -type f 2>/dev/null || echo "No sealed secrets found"

copy-sealed-secrets-to-namespace: ## Copy sealed secrets to a different namespace (usage: make copy-sealed-secrets-to-namespace TARGET_NS=production)
	@if [ -z "$(TARGET_NS)" ]; then \
		echo "Error: TARGET_NS not specified"; \
		echo "Usage: make copy-sealed-secrets-to-namespace TARGET_NS=production"; \
		exit 1; \
	fi
	@echo "Copying sealed secrets to namespace: $(TARGET_NS)"
	@kubectl create namespace $(TARGET_NS) --dry-run=client -o yaml | kubectl apply -f -
	@if [ -f "$(CHART_PATH)/templates/backend/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/backend/sealed-secret.yaml | \
		sed 's/namespace: .*/namespace: $(TARGET_NS)/' | \
		kubectl apply -f -; \
	fi
	@if [ -f "$(CHART_PATH)/templates/postgresql/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/postgresql/sealed-secret.yaml | \
		sed 's/namespace: .*/namespace: $(TARGET_NS)/' | \
		kubectl apply -f -; \
	fi
	@if [ -f "$(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml | \
		sed 's/namespace: .*/namespace: $(TARGET_NS)/' | \
		kubectl apply -f -; \
	fi
	@echo "✓ Sealed secrets copied to $(TARGET_NS)"

export-sealed-secrets: ## Export sealed secrets to a backup file
	@echo "Exporting sealed secrets to sealed-secrets-backup.yaml..."
	@echo "# Sealed Secrets Backup - $(shell date)" > sealed-secrets-backup.yaml
	@echo "# Namespace: $(NAMESPACE)" >> sealed-secrets-backup.yaml
	@echo "---" >> sealed-secrets-backup.yaml
	@if [ -f "$(CHART_PATH)/templates/backend/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/backend/sealed-secret.yaml >> sealed-secrets-backup.yaml; \
		echo "---" >> sealed-secrets-backup.yaml; \
	fi
	@if [ -f "$(CHART_PATH)/templates/postgresql/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/postgresql/sealed-secret.yaml >> sealed-secrets-backup.yaml; \
		echo "---" >> sealed-secrets-backup.yaml; \
	fi
	@if [ -f "$(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml" ]; then \
		cat $(CHART_PATH)/templates/stats-postgresql/sealed-secret.yaml >> sealed-secrets-backup.yaml; \
	fi
	@echo "✓ Sealed secrets exported to sealed-secrets-backup.yaml"

deploy: ## Deploy the Helm chart (uses sealed secrets by default, ENV=dev|staging|production)
	@echo "Deploying Monad Indexer to $(ENV) environment..."
	@if [ -f "$(ENV_VALUES_FILE)" ]; then \
		echo "Using environment file: $(ENV_VALUES_FILE)"; \
		helm upgrade --install $(HELM_RELEASE) $(CHART_PATH) \
			--namespace $(NAMESPACE) \
			--create-namespace \
			-f $(CHART_PATH)/$(VALUES_FILE) \
			-f $(ENV_VALUES_FILE); \
	else \
		echo "Environment file not found: $(ENV_VALUES_FILE)"; \
		echo "Deploying with base values only..."; \
		helm upgrade --install $(HELM_RELEASE) $(CHART_PATH) \
			--namespace $(NAMESPACE) \
			--create-namespace \
			-f $(CHART_PATH)/$(VALUES_FILE); \
	fi
	@echo "✓ Deployment complete"

deploy-dev: ## Deploy to dev environment
	@$(MAKE) deploy ENV=dev NAMESPACE=monad-indexer-dev

deploy-staging: ## Deploy to staging environment
	@$(MAKE) deploy ENV=staging NAMESPACE=monad-indexer-staging

deploy-prod: ## Deploy to production environment
	@$(MAKE) deploy ENV=production NAMESPACE=monad-indexer-prod

status: ## Check deployment status
	@echo "Helm Release Status:"
	@helm status $(HELM_RELEASE) -n $(NAMESPACE)
	@echo ""
	@echo "Pod Status:"
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(HELM_RELEASE)

logs: ## Show logs for backend pods
	@kubectl logs -n $(NAMESPACE) -l app=monad-indexer,component=backend --tail=100 -f

clean: ## Remove the deployment
	@echo "Removing Monad Indexer deployment..."
	helm uninstall $(HELM_RELEASE) -n $(NAMESPACE)
	@echo "✓ Deployment removed"

clean-secrets: ## Remove all sealed secrets (WARNING: destructive)
	@echo "WARNING: This will remove all sealed secrets from namespace $(NAMESPACE)"
	@read -p "Are you sure? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		kubectl delete sealedsecrets --all -n $(NAMESPACE); \
		echo "✓ Sealed secrets removed"; \
	else \
		echo "Aborted"; \
	fi

# Development helpers
dev-setup: setup-sealed-secrets seal-secrets ## Complete development setup
	@echo "✓ Development environment ready"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Review sealed secrets in $(CHART_PATH)/templates/"
	@echo "  2. Update $(VALUES_FILE) to use existingSecret"
	@echo "  3. Run: make deploy"

# Backup and restore
backup-sealing-key: ## Backup the sealed secrets encryption key
	@echo "Backing up sealed secrets encryption key..."
	@kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealed-secrets-key-backup-$$(date +%Y%m%d-%H%M%S).yaml
	@echo "✓ Key backed up to sealed-secrets-key-backup-*.yaml"
	@echo "⚠️  IMPORTANT: Store this file securely and DO NOT commit to Git!"
