# Operator interface for the local platform. Every target calls a script, and CI calls the
# same scripts, so there is one implementation of each operation. See docs/platform-contract.md.
#
# ENV, BACKUP and SVC reach the scripts as positional arguments. Every other option named below is
# read from the environment, and make exports whatever is set on its command line.
.DEFAULT_GOAL := help
SHELL := /bin/bash
ENV ?= dev

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ---- lifecycle ------------------------------------------------------------------------------
.PHONY: setup up down destroy status logs
setup: ## Check prerequisites and install pinned CLIs into .tools/bin
	@./scripts/install-tools.sh
	@./scripts/prereqs.sh

up: ## Create or resume the whole platform (idempotent). [UP_STOP_AFTER=<step>] [ALLOW_LOW_DISK="<reason>"], see scripts/up.sh
	@./scripts/up.sh

down: ## Stop the cluster and keep ALL data (make up resumes it)
	@./scripts/down.sh

destroy: ## Delete the cluster: make destroy CONFIRM=yes [SKIP_BACKUP=yes] [PURGE=yes]
	@./scripts/destroy.sh

status: ## Show cluster, GitOps, workload health, URLs, and resource use
	@./scripts/status.sh

logs: ## Tail logs: make logs ENV=dev SVC=api. With no SVC, lists what can be tailed
	@./scripts/logs.sh "$(ENV)" "$(SVC)"

# ---- verification ---------------------------------------------------------------------------
.PHONY: test test-e2e test-netpol test-infisical test-routes test-separation test-alert test-load gates
test: ## Run gates, network policy matrix, Infisical isolation and rendered Secrets, internal routes, smoke in both environments, and their separation
	@./scripts/test.sh

gates: ## Run the day-1 runtime gates
	@./tests/gates/day1.sh

test-e2e: ## End-to-end smoke test: make test-e2e ENV=dev
	@./scripts/test.sh e2e "$(ENV)"

test-netpol: ## Execute the NetworkPolicy allow and deny matrix: make test-netpol [FROM_NS=plane-dev]
	@./scripts/test-netpol.sh

test-infisical: ## Infisical alone: each environment's identity is refused the other's project, and the rendered Secrets match
	@./scripts/test.sh infisical

test-routes: ## Who can reach the internal UIs through Traefik: the host can, a Plane api pod cannot
	@./scripts/test.sh routes

test-separation: ## Real attempts between dev and prod-sim, and what each holds. Needs make test-e2e to have run in both
	@./scripts/test.sh separation

test-alert: ## Prove alert delivery end to end: make test-alert ENV=dev
	@./scripts/test-alert.sh "$(ENV)"

test-load: ## Run the k6 load test and capture resource use, dev only: make test-load ENV=dev [THINK=0]
	@./tests/load/run.sh "$(ENV)"

.PHONY: scan-images
scan-images: ## Scan every image the platform runs and report it all. Fails on a fixable CRITICAL in an image we build, or a missed image. [SCAN_MIN_FREE_GIB=15] [SCAN_FLOOR_GIB=15]
	@./scripts/ci/scan-images.sh

.PHONY: publish-evidence
publish-evidence: ## Copy .local/evidence-raw to docs/evidence/runs with secrets scrubbed. Fails on any gitleaks finding
	@./scripts/publish-evidence.sh

# ---- failure drills -------------------------------------------------------------------------
.PHONY: drill-failed-deploy drill-pod-restart drill-clean-restore drill-clean-restore-harness
drill-failed-deploy: ## A bad image reaches dev through Git, the rollout refuses it, a revert restores it. Dev only
	@./tests/drills/failed-deploy-rollback.sh

drill-pod-restart: ## Restart each StatefulSet pod and prove the data survives: make drill-pod-restart ENV=dev
	@./tests/drills/pod-restart-persistence.sh "$(ENV)"

drill-clean-restore: ## Back up, DELETE THE CLUSTER, restore everything and prove it: make drill-clean-restore CONFIRM=yes [BACKUP=<id|latest> SKIP_BACKUP=yes] [PLAN_ONLY=yes] [SKIP_E2E=yes] [CLEAN_INSTALL_FIRST=yes COLD_INSTALL=yes] [LOSE_CLUSTER=yes] [ALLOW_LOW_DISK="<reason>"]
	@./tests/drills/clean-restore.sh

drill-clean-restore-harness: ## The order and refusals of a clean restore, with kubectl, kind, docker, Terraform and the API stubbed. Touches no cluster, and proves no platform: [ONLY="S1 S20"]
	@./tests/drills/clean-restore-harness.sh

# ---- data -----------------------------------------------------------------------------------
.PHONY: backup restore restore-clean rotate
backup: ## Back up an environment: make backup ENV=dev|prod-sim|infisical|all [KEEP=3] [ALLOW_BACKUP_DURING_RESTORE=yes]
	@./scripts/backup.sh "$(ENV)"

restore: ## Restore: make restore ENV=dev BACKUP=<backup-id|latest> [CONFIRM=yes]
	@./scripts/restore.sh "$(ENV)" "$(BACKUP)"

restore-clean: ## Bring the whole platform back into a clean environment: make restore-clean BACKUP=<infisical-backup-id|latest> [PLAN_ONLY=yes] [ENVS=dev] [ALLOW_LOW_DISK="<reason>"] [ALLOW_NO_SENTINEL=yes] [ALLOW_NEWER_INFISICAL_BACKUP=yes] [ALLOW_RESUME_OVERWRITE="dev prod-sim"]. The script exits 2 if a proof could not run or a person must sign in, and 4 if it overwrote what ALLOW_RESUME_OVERWRITE named. make exits 2 on any failure, and prints which, so read jq '.result, .not_run' on its evidence
	@./scripts/restore.sh clean "$(BACKUP)"

rotate: ## Rotate a database credential through Infisical: make rotate ENV=dev [RESUME=yes|ROLLBACK=yes] [CONFIRM=yes]
	@./scripts/rotate.sh "$(ENV)"

# ---- delivery -------------------------------------------------------------------------------
.PHONY: render images promote rollback gitops-publish ci
render: ## Re-render Plane manifests from helm/plane into gitops/environments
	@./scripts/render.sh
	@./scripts/render.sh --env prod

images: ## Build the Wayline images and push them to the local registry
	@./scripts/ci/build-images.sh localhost:5001/wayline

.PHONY: wayline-upgrade-check wayline-upstream-check
wayline-upgrade-check: ## After bumping apps/wayline/UPSTREAM: overlay lock, patches, tokens, contrast, upstream's Dockerfiles and nginx
	@./apps/wayline/checks/upgrade-check.sh

wayline-upstream-check: ## Size of the work for another upstream ref, with no build: make wayline-upstream-check REF=preview
	@./apps/wayline/checks/upstream-check.sh "$(REF)"

promote: ## Promote images: make promote ENV=dev [IMAGE=web DIGEST=sha256:... [REPO=<repository>]] [CONFIRM=yes] [SKIP_BACKUP=yes] [COMMIT=no] [OVERRIDE_DEV_CHECK="<reason>"]
	@./scripts/promote.sh "$(ENV)"

rollback: ## Revert the last promotion for an environment: make rollback ENV=dev [CONFIRM=yes] [SKIP_BACKUP=yes] [ROLLBACK_DUMP_TIMEOUT=<seconds>]
	@./scripts/rollback.sh "$(ENV)"

gitops-publish: ## Push the current main branch to the local Git remote that Argo CD reads. A prod-sim digest needs dev Synced and Healthy on it: [OVERRIDE_DEV_CHECK="<reason>"] goes ahead anyway and logs why
	@./scripts/gitops-publish.sh

ci: ## Run every CI check locally, the same scripts as GitHub Actions. Runs them all, then fails if any did
	@status=0; \
	for check in lint validate-manifests ownership security; do \
	  ./scripts/ci/$$check.sh || status=1; \
	done; \
	exit $$status
