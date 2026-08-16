#!/usr/bin/env bash
# What hosted production is doing, read-only.
#
#   TARGET=plane-prod scripts/hosted/status.sh
#
# Keeps going when a section cannot be read, so one problem does not hide the rest. Exit 0 if the cluster answered. Alert delivery
# and off-VPS backups say COMPLETE or INCOMPLETE from local files, whether or not it did.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "Target"
printf '%s: %s on %s, node %s, tunnel 127.0.0.1:%s\n' "$HOSTED_NAME" "$HOSTED_DOMAIN" "$HOSTED_HOST" "$HOSTED_NODE" "$HOSTED_TUNNEL_PORT"

reachable=yes
problem="$(hosted_problem)"
if [[ -n "$problem" ]]; then
  warn "not reading the cluster, because $problem"
  reachable=no
else
  ok "kube-system UID and node name match target.yaml"
fi

if [[ "$reachable" == yes ]]; then
  section "Node"
  kc get nodes -o wide
  # Disk is the thing that ends a one-node platform, and nothing in the cluster's own view says it plainly.
  node_ssh_quiet "df -h / $HOSTED_BACKUP_ROOT 2>/dev/null; test -f /var/run/reboot-required && echo 'reboot required' || true" || warn "could not read the node over SSH"

  section "Argo CD"
  kc -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null ||
    warn "could not read Applications"

  section "Pods that are not ready"
  kc get pods --all-namespaces -o json |
    jq -r '.items[]
      | select(.status.phase != "Succeeded")
      | select(any(.status.containerStatuses[]?; .ready == false) or .status.phase != "Running")
      | "\(.metadata.namespace)/\(.metadata.name)  \(.status.phase)  \([.status.containerStatuses[]? | .state.waiting.reason // empty] | join(","))"' |
    sed 's/^/  /' || true

  section "Certificates"
  kc -n plane-prod get certificate 2>/dev/null || printf '  none yet\n'
  kc get clusterissuer 2>/dev/null || true

  section "Backups"
  for namespace in infisical plane-prod; do
    kc -n "$namespace" get cronjob plane-backup -o json 2>/dev/null |
      jq -r --arg ns "$namespace" '"  \($ns): last success \(.status.lastSuccessfulTime // "never"), last started \(.status.lastScheduleTime // "never")"' ||
      printf '  %s: no CronJob yet\n' "$namespace"
  done

  section "Firewall"
  node_script 'grep -E "dport (80|443)" /etc/wayline/edge.nft 2>/dev/null | sed "s/^ */  /"; nft list table inet wayline_edge >/dev/null 2>&1 && echo "  table loaded" || echo "  table NOT loaded"' </dev/null ||
    warn "could not read the firewall over SSH"
fi

section "Alert delivery"
"$ROOT/scripts/hosted/alerts.sh" state || true

section "Backups off the VPS"
"$ROOT/scripts/hosted/backup-dest.sh" status || true

section "Recovery bundle"
newest="$(find "$LOCAL_DIR/recovery-bundle" -maxdepth 1 -type f -name 'wayline-recovery-*.tar.age' 2>/dev/null | sort -r | head -1 || true)"
if [[ -n "$newest" ]]; then printf '%s\n' "newest here: ${newest##*/}. A newer secret or Terraform state makes it stale: scripts/hosted/bundle.sh verify says so"; else printf 'INCOMPLETE: no bundle here. Run: scripts/hosted/bundle.sh\n'; fi

[[ "$reachable" == yes ]]
