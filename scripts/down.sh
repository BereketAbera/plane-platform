#!/usr/bin/env bash
# Stop the platform and keep every byte of data. `make up` resumes it. This never deletes anything.
source "$(dirname "$0")/lib/common.sh"

if docker inspect "$NODE_CONTAINER" >/dev/null 2>&1; then
  log "Stopping the cluster node (volumes and data are kept)"
  docker stop "$NODE_CONTAINER" >/dev/null
else
  warn "no cluster node found; nothing to stop"
fi
log "Stopping local services (registry and Git data are kept)"
docker compose -f "$ROOT/infrastructure/local-services/compose.yaml" stop 2>&1 | tail -1 || true
ok "stopped. Data is intact. Run 'make up' to resume, or 'make destroy CONFIRM=yes' to delete."
