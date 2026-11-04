#!/usr/bin/env bash
# Delete the cluster, which destroys all Plane and Infisical data still inside it.
# Takes a backup first, and refuses to run without explicit confirmation.
# The local registry, caches, Git remote, backups and secret zero all survive unless PURGE=yes.
source "$(dirname "$0")/lib/common.sh"

if [[ "${CONFIRM:-}" != "yes" ]]; then
  cat >&2 <<MSG
This deletes the cluster and all data in it: both Plane environments and Infisical.
Backups in .local/backups and secret zero in .local/secret-zero are kept.
Re-run with: make destroy CONFIRM=yes
MSG
  exit 1
fi

if cluster_exists; then
  if [[ "${SKIP_BACKUP:-}" == "yes" ]]; then
    warn "SKIP_BACKUP=yes: deleting with no new backup"
  else
    log "Backing up all environments before deletion"
    "$ROOT/scripts/backup.sh" all || die "backup failed, so nothing was deleted. Use SKIP_BACKUP=yes to override."
  fi
  log "Deleting kind cluster $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
else
  warn "cluster $CLUSTER_NAME does not exist"
fi

# Terraform state describes the cluster that just went away. Keeping it would make the next
# apply plan against resources that no longer exist.
rm -rf "$LOCAL_DIR/terraform/local" "$LOCAL_DIR/terraform/infisical"

if [[ "${PURGE:-}" == "yes" ]]; then
  log "PURGE=yes: removing local services and their volumes"
  docker compose -f "$ROOT/infrastructure/local-services/compose.yaml" down --volumes 2>&1 | tail -2
fi
ok "cluster deleted. Next: 'make up' for an empty platform, then 'make restore' to bring data back."
