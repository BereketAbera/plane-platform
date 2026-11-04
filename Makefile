# Operator interface for the local platform. Every target calls a script, and CI calls the
# same scripts, so there is one implementation of each operation. See docs/platform-contract.md.
.DEFAULT_GOAL := help
SHELL := /bin/bash
ENV ?= dev

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ---- lifecycle ------------------------------------------------------------------------------
.PHONY: setup up down destroy status logs
setup: ## Check prerequisites and install pinned CLIs into .tools/bin
	@./scripts/install-tools.sh
	@./scripts/prereqs.sh

up: ## Create or resume the whole platform (idempotent)
	@./scripts/up.sh

down: ## Stop the cluster and keep ALL data (make up resumes it)
	@./scripts/down.sh

destroy: ## Delete the cluster. Needs CONFIRM=yes; backs up first unless SKIP_BACKUP=yes
	@./scripts/destroy.sh

status: ## Show cluster, GitOps, workload health, URLs, and resource use
	@./scripts/status.sh

logs: ## Tail logs: make logs ENV=dev SVC=api
	@./scripts/logs.sh "$(ENV)" "$(SVC)"

# ---- verification ---------------------------------------------------------------------------
.PHONY: test test-e2e test-netpol test-alert test-load gates
test: ## Run gates, network policy matrix, and end-to-end smoke tests in both environments
	@./scripts/test.sh

gates: ## Run the day-1 runtime gates
	@./tests/gates/day1.sh

test-e2e: ## End-to-end smoke test: make test-e2e ENV=dev
	@./scripts/test.sh e2e "$(ENV)"

test-netpol: ## Execute the NetworkPolicy allow and deny matrix
	@./scripts/test-netpol.sh

test-alert: ## Prove alert delivery end to end: make test-alert ENV=dev
	@./scripts/test-alert.sh "$(ENV)"

test-load: ## Run the k6 load test and capture resource use: make test-load ENV=dev
	@./tests/load/run.sh "$(ENV)"

# ---- data -----------------------------------------------------------------------------------
.PHONY: backup restore rotate
backup: ## Back up an environment: make backup ENV=dev (or ENV=all)
	@./scripts/backup.sh "$(ENV)"

restore: ## Restore: make restore ENV=dev BACKUP=<dir> [CONFIRM=yes]
	@./scripts/restore.sh "$(ENV)" "$(BACKUP)"

rotate: ## Rotate a database credential through Infisical: make rotate ENV=dev
	@./scripts/rotate.sh "$(ENV)"

# ---- delivery -------------------------------------------------------------------------------
.PHONY: render images promote rollback gitops-publish ci
render: ## Re-render Plane manifests from helm/plane into gitops/environments
	@./scripts/render.sh

images: ## Build the Wayline images and push them to the local registry
	@./scripts/ci/build-images.sh localhost:5001/wayline

promote: ## Promote images: make promote ENV=dev [IMAGE=web DIGEST=sha256:...]
	@./scripts/promote.sh "$(ENV)"

rollback: ## Revert the last promotion for an environment: make rollback ENV=dev
	@./scripts/rollback.sh "$(ENV)"

gitops-publish: ## Push the current main branch to the local Git remote that Argo CD reads
	@./scripts/gitops-publish.sh

ci: ## Run every CI check locally, using the same scripts as GitHub Actions
	@./scripts/ci/lint.sh
	@./scripts/ci/validate-manifests.sh
	@./scripts/ci/ownership.sh
	@./scripts/ci/security.sh
