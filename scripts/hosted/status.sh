#!/usr/bin/env bash
# What hosted production is doing, read-only.
#
#   TARGET=plane-prod scripts/hosted/status.sh
#   scripts/hosted/status.sh --selftest   what it says of the admin token's end, from a table, with no cluster, so CI can run it
#
# Keeps going when a section cannot be read, so one problem does not hide the rest. Exit 0 if the cluster answered. Alert delivery
# and off-VPS backups say COMPLETE or INCOMPLETE from local files, whether or not it did.

# The admin token's end, from its exp: when it ended, or when it ends and in how many whole days. Ended is read from the times themselves and
# not from the days, because the division rounds toward zero, and a token that ended in the last 24 hours would read as ending in 0 days.
token_end_words() { # <exp> <now>, in epoch seconds
  local ends days
  ends="$(date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ)"
  if [[ "$1" -le "$2" ]]; then
    printf 'ended %s' "$ends"
    return 0
  fi
  days=$((($1 - $2) / 86400))
  case "$days" in
    0) printf 'ends %s, in under a day' "$ends" ;;
    1) printf 'ends %s, in 1 day' "$ends" ;;
    *) printf 'ends %s, in %s days' "$ends" "$days" ;;
  esac
}

if [[ "${1:-}" == --selftest ]]; then
  failures=0
  now=1800000000
  # Seconds from now to the token's exp, then what follows the date: ended has nothing after it.
  while read -r offset want; do
    got="$(token_end_words "$((now + offset))" "$now")"
    if [[ "$want" == ended ]]; then
      [[ "$got" == "ended "* && "$got" != *", in "* ]] || { printf 'fail exp now%+d: %s, and wants it ended\n' "$offset" "$got"; failures=$((failures + 1)); }
    else
      [[ "$got" == "ends "*", $want" ]] || { printf 'fail exp now%+d: %s, and wants %s\n' "$offset" "$got" "$want"; failures=$((failures + 1)); }
    fi
  done <<'TABLE'
-7776000 ended
-86400 ended
-86399 ended
-3600 ended
-1 ended
0 ended
1 in under a day
3600 in under a day
86399 in under a day
86400 in 1 day
172799 in 1 day
172800 in 2 days
7776000 in 90 days
TABLE
  [[ "$failures" -eq 0 ]] || { printf 'fail selftest: %s failed\n' "$failures" >&2; exit 1; }
  printf ' ok selftest passed\n'
  exit 0
fi

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
  kc get certificate --all-namespaces 2>/dev/null || printf '  none yet\n'
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

section "Branch deploy/plane-prod"
GIT_TERMINAL_PROMPT=0 "$ROOT/scripts/ci/check-deploy-branch.sh" || true

section "Alert delivery"
"$ROOT/scripts/hosted/alerts.sh" state || true

section "Backups off the VPS"
"$ROOT/scripts/hosted/backup-dest.sh" status || true

# Scripts replace the admin token with the password, which stops at the code once Infisical's admin has two-factor on. Then a person
# makes the next one in the UI, so its end is worth seeing ahead of time. Read from the token's own payload here, and only its date shown.
section "Infisical's admin token"
token_exp="$(jq -r '.token // "" | split(".")[1] // "" | gsub("-"; "+") | gsub("_"; "/") | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson | .exp // 0' \
  "$LOCAL_DIR/secret-zero/infisical-admin.json" 2>/dev/null || echo 0)"
if [[ "$token_exp" =~ ^[0-9]+$ && "$token_exp" -gt 0 ]]; then
  token_end_words "$token_exp" "$(date +%s)"
  printf '. With two-factor on, a person replaces it in the UI: scripts/hosted/README.md, section Locked out of Infisical\n'
else
  printf 'none here that can be read: secret-zero/infisical-admin.json. infisical/README.md, section Recovery, says how one comes back\n'
fi

section "Recovery bundle"
newest="$(find "$LOCAL_DIR/recovery-bundle" -maxdepth 1 -type f -name 'wayline-recovery-*.tar.age' 2>/dev/null | sort -r | head -1 || true)"
if [[ -n "$newest" ]]; then printf '%s\n' "newest here: ${newest##*/}. A newer secret or Terraform state makes it stale: scripts/hosted/bundle.sh verify says so"; else printf 'INCOMPLETE: no bundle here. Run: scripts/hosted/bundle.sh\n'; fi

[[ "$reachable" == yes ]]
