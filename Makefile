.PHONY: help setup-external-secrets verify-secrets deploy clean

# Configuration
NAMESPACE ?= monad-indexer-dev
HELM_RELEASE ?= monad-indexer
CHART_PATH ?= charts/monad-indexer
VALUES_FILE ?= values.yaml
ENV ?= dev
ENV_VALUES_FILE ?= $(CHART_PATH)/environments/values-$(ENV).yaml
AWS_REGION ?= eu-north-1
AWS_SECRET_NAME ?= blockscout

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'

# External Secrets Operator setup
setup-external-secrets: ## Install External Secrets Operator in the cluster
	@echo "Installing External Secrets Operator..."
	@./infrastructure/external-secrets-operator-install.sh
	@echo "✓ External Secrets Operator installed"

verify-external-secrets: ## Verify External Secrets Operator is running
	@echo "Checking External Secrets Operator status..."
	@kubectl get pods -n external-secrets-system
	@echo ""
	@echo "Checking SecretStore in namespace: $(NAMESPACE)"
	@kubectl get secretstore -n $(NAMESPACE) 2>/dev/null || echo "No SecretStore found in $(NAMESPACE)"
	@echo ""
	@echo "Checking ExternalSecrets in namespace: $(NAMESPACE)"
	@kubectl get externalsecret -n $(NAMESPACE) 2>/dev/null || echo "No ExternalSecrets found in $(NAMESPACE)"

# AWS Secrets Management
create-aws-secret: ## Create AWS Secrets Manager secret (interactive)
	@echo "Creating AWS Secrets Manager secret: $(AWS_SECRET_NAME)"
	@echo "Generating random credentials..."
	@SECRET_KEY_BASE=$$(openssl rand -base64 64 | tr -d '\n'); \
	POSTGRES_PASSWORD=$$(openssl rand -base64 32 | tr -d '+/=\n'); \
	STATS_PASSWORD=$$(openssl rand -base64 32 | tr -d '+/=\n'); \
	echo ""; \
	echo "Generated credentials:"; \
	echo "  SECRET_KEY_BASE: $$SECRET_KEY_BASE"; \
	echo "  POSTGRES_PASSWORD: $$POSTGRES_PASSWORD"; \
	echo "  STATS_PASSWORD: $$STATS_PASSWORD"; \
	echo ""; \
	read -p "Create secret in AWS Secrets Manager? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		aws secretsmanager create-secret \
			--name "$(AWS_SECRET_NAME)" \
			--description "Credentials for Blockscout/Monad Indexer ($(ENV) environment)" \
			--secret-string "{\"SECRET_KEY_BASE\":\"$$SECRET_KEY_BASE\",\"POSTGRES_PASSWORD\":\"$$POSTGRES_PASSWORD\",\"STATS_PASSWORD\":\"$$STATS_PASSWORD\"}" \
			--region $(AWS_REGION); \
		echo "✓ AWS secret created: $(AWS_SECRET_NAME)"; \
	else \
		echo "Aborted"; \
	fi

update-aws-secret: ## Update existing AWS Secrets Manager secret (interactive)
	@echo "Updating AWS Secrets Manager secret: $(AWS_SECRET_NAME)"
	@echo "Current secret contents:"
	@aws secretsmanager get-secret-value --secret-id "$(AWS_SECRET_NAME)" --region $(AWS_REGION) --query SecretString --output text | jq .
	@echo ""
	@read -p "Rotate POSTGRES_PASSWORD? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		CURRENT=$$(aws secretsmanager get-secret-value --secret-id $(AWS_SECRET_NAME) --region $(AWS_REGION) --query SecretString --output text); \
		NEW_PASSWORD=$$(openssl rand -base64 32 | tr -d '+/=\n'); \
		aws secretsmanager update-secret \
			--secret-id "$(AWS_SECRET_NAME)" \
			--secret-string "$$(echo $$CURRENT | jq --arg pwd "$$NEW_PASSWORD" '.POSTGRES_PASSWORD = $$pwd')" \
			--region $(AWS_REGION); \
		echo "✓ POSTGRES_PASSWORD rotated"; \
	fi

view-aws-secret: ## View AWS Secrets Manager secret contents
	@echo "Secret: $(AWS_SECRET_NAME) (region: $(AWS_REGION))"
	@aws secretsmanager get-secret-value --secret-id "$(AWS_SECRET_NAME)" --region $(AWS_REGION) --query SecretString --output text | jq .

# Kubernetes AWS credentials
create-k8s-aws-credentials: ## Create Kubernetes secret with AWS credentials
	@echo "Creating AWS credentials secret in namespace: $(NAMESPACE)"
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] || [ -z "$$AWS_SECRET_ACCESS_KEY" ]; then \
		echo "Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set"; \
		echo "Usage: AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=yyy make create-k8s-aws-credentials"; \
		exit 1; \
	fi
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic aws-credentials \
		--from-literal=access-key-id=$$AWS_ACCESS_KEY_ID \
		--from-literal=secret-access-key=$$AWS_SECRET_ACCESS_KEY \
		-n $(NAMESPACE) \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✓ AWS credentials secret created"

verify-k8s-aws-credentials: ## Verify Kubernetes AWS credentials secret
	@echo "Checking aws-credentials secret in namespace: $(NAMESPACE)"
	@kubectl get secret aws-credentials -n $(NAMESPACE) -o jsonpath='{.data.access-key-id}' | base64 -d | head -c 20 && echo "..."
	@echo "Secret exists and contains access-key-id"

# Secrets verification
verify-secrets: ## Verify all secrets (ExternalSecrets and generated K8s secrets)
	@echo "=== SecretStore Status ==="
	@kubectl get secretstore -n $(NAMESPACE)
	@echo ""
	@echo "=== ExternalSecrets Status ==="
	@kubectl get externalsecret -n $(NAMESPACE)
	@echo ""
	@echo "=== Generated Kubernetes Secrets ==="
	@kubectl get secrets -n $(NAMESPACE) | grep monad-indexer || echo "No secrets found"
	@echo ""
	@echo "=== Backend Secret Content (first 50 chars) ==="
	@kubectl get secret monad-indexer-$(ENV)-backend-secret -n $(NAMESPACE) -o jsonpath='{.data.secret-key-base}' 2>/dev/null | base64 -d | head -c 50 && echo "..." || echo "Secret not found"
	@echo ""
	@echo "=== PostgreSQL URI ==="
	@kubectl get secret monad-indexer-$(ENV)-postgresql-app -n $(NAMESPACE) -o jsonpath='{.data.uri}' 2>/dev/null | base64 -d || echo "Secret not found"

describe-externalsecret: ## Describe ExternalSecret for debugging (usage: make describe-externalsecret NAME=backend)
	@if [ -z "$(NAME)" ]; then \
		echo "Error: NAME not specified"; \
		echo "Usage: make describe-externalsecret NAME=backend|postgresql|stats-postgresql"; \
		exit 1; \
	fi
	@kubectl describe externalsecret monad-indexer-$(ENV)-$(NAME) -n $(NAMESPACE)

force-refresh-externalsecret: ## Force refresh an ExternalSecret (usage: make force-refresh-externalsecret NAME=backend)
	@if [ -z "$(NAME)" ]; then \
		echo "Error: NAME not specified"; \
		echo "Usage: make force-refresh-externalsecret NAME=backend|postgresql|stats-postgresql"; \
		exit 1; \
	fi
	@echo "Forcing refresh of ExternalSecret: monad-indexer-$(ENV)-$(NAME)"
	@kubectl annotate externalsecret monad-indexer-$(ENV)-$(NAME) \
		force-sync=$$(date +%s) \
		-n $(NAMESPACE) --overwrite
	@echo "✓ ExternalSecret annotated for refresh"
	@sleep 2
	@kubectl get externalsecret monad-indexer-$(ENV)-$(NAME) -n $(NAMESPACE)

# ArgoCD operations
argocd-sync: ## Sync ArgoCD application
	@echo "Syncing ArgoCD application: monad-indexer-$(ENV)"
	@argocd app sync monad-indexer-$(ENV)

argocd-status: ## Check ArgoCD application status
	@argocd app get monad-indexer-$(ENV)

argocd-refresh: ## Refresh ArgoCD application (pull latest from Git)
	@argocd app get monad-indexer-$(ENV) --refresh

# Deployment
deploy: ## Deploy via Helm directly (NOT recommended, use ArgoCD instead)
	@echo "⚠️  WARNING: Direct Helm deployment is not recommended."
	@echo "⚠️  This will bypass ArgoCD GitOps workflow."
	@echo ""
	@read -p "Continue anyway? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "Deploying Monad Indexer to $(ENV) environment..."; \
		if [ -f "$(ENV_VALUES_FILE)" ]; then \
			helm upgrade --install $(HELM_RELEASE) $(CHART_PATH) \
				--namespace $(NAMESPACE) \
				--create-namespace \
				-f $(CHART_PATH)/$(VALUES_FILE) \
				-f $(ENV_VALUES_FILE); \
		else \
			helm upgrade --install $(HELM_RELEASE) $(CHART_PATH) \
				--namespace $(NAMESPACE) \
				--create-namespace \
				-f $(CHART_PATH)/$(VALUES_FILE); \
		fi; \
		echo "✓ Deployment complete"; \
	else \
		echo "Aborted. Use ArgoCD instead: make argocd-sync"; \
	fi

deploy-dev: ## Deploy to dev environment via ArgoCD
	@$(MAKE) argocd-sync ENV=dev NAMESPACE=monad-indexer-dev

deploy-staging: ## Deploy to staging environment via ArgoCD
	@$(MAKE) argocd-sync ENV=staging NAMESPACE=monad-indexer-staging

deploy-prod: ## Deploy to production environment via ArgoCD
	@$(MAKE) argocd-sync ENV=production NAMESPACE=monad-indexer-prod

# Status and logs
status: ## Check deployment status
	@echo "=== ArgoCD Application Status ==="
	@argocd app get monad-indexer-$(ENV) 2>/dev/null || echo "ArgoCD application not found"
	@echo ""
	@echo "=== Pod Status ==="
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=monad-indexer-$(ENV)
	@echo ""
	@echo "=== External Secrets Status ==="
	@kubectl get externalsecret,secretstore -n $(NAMESPACE)

logs: ## Show logs for backend pods
	@kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/component=backend --tail=100 -f

logs-external-secrets: ## Show External Secrets Operator logs
	@kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets --tail=100 -f

# Cleanup
clean: ## Remove the deployment via ArgoCD
	@echo "⚠️  WARNING: This will delete the ArgoCD application: monad-indexer-$(ENV)"
	@read -p "Are you sure? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		argocd app delete monad-indexer-$(ENV) --yes; \
		echo "✓ ArgoCD application deleted"; \
	else \
		echo "Aborted"; \
	fi

clean-namespace: ## Remove entire namespace (WARNING: destructive)
	@echo "⚠️  WARNING: This will delete the entire namespace: $(NAMESPACE)"
	@read -p "Are you sure? (y/N) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		kubectl delete namespace $(NAMESPACE); \
		echo "✓ Namespace deleted"; \
	else \
		echo "Aborted"; \
	fi

# Development helpers
dev-setup: setup-external-secrets create-k8s-aws-credentials ## Complete development setup
	@echo "✓ Development environment ready"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Create AWS secret: make create-aws-secret ENV=dev"
	@echo "  2. Deploy via ArgoCD: kubectl apply -f argocd/applications/monad-indexer-dev.yaml"
	@echo "  3. Sync: make argocd-sync ENV=dev"
	@echo "  4. Verify: make verify-secrets ENV=dev"

# Documentation
docs: ## Show External Secrets documentation
	@cat docs/secrets-management.md

show-env-config: ## Show current environment configuration
	@echo "Current configuration:"
	@echo "  Environment: $(ENV)"
	@echo "  Namespace: $(NAMESPACE)"
	@echo "  Helm Release: $(HELM_RELEASE)"
	@echo "  Values File: $(VALUES_FILE)"
	@echo "  Env Values: $(ENV_VALUES_FILE)"
	@echo "  AWS Region: $(AWS_REGION)"
	@echo "  AWS Secret: $(AWS_SECRET_NAME)"
