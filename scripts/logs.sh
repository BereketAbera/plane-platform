#!/usr/bin/env bash
# Tail logs for one workload in a Plane namespace, or list what can be tailed.
#
#   scripts/logs.sh <dev|prod-sim>                      list the names
#   scripts/logs.sh <dev|prod-sim> <name>               follow one workload
#   scripts/logs.sh <dev|prod-sim> <name> --no-follow   print its last lines and stop
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# One line per workload: comma-separated names people use, then the workload those names mean.
# Taken from gitops/environments/{dev,prod-sim}/manifests.yaml, which render the same names in both
# environments because the Helm release is `plane` in both. Matching drops `plane-` and `-wl` first, so
# the real name plane-beat-worker-wl needs no entry of its own. Only plane-api-migrate-1 does, as it has
# no -wl. A name this table does not know is looked up, exactly, among the namespace's live Deployments,
# StatefulSets and Jobs. That covers what runs there beyond those manifests: postgres-exporter,
# redis-exporter and iso-<env>-controller-manager.
WORKLOADS="api:deployment/plane-api-wl
worker:deployment/plane-worker-wl
beat,beat-worker:deployment/plane-beat-worker-wl
web:deployment/plane-web-wl
admin:deployment/plane-admin-wl
space:deployment/plane-space-wl
live:deployment/plane-live-wl
postgres,postgresql,pg,pgdb:statefulset/plane-pgdb-wl
valkey,redis:statefulset/plane-redis-wl
rabbitmq,rabbit:statefulset/plane-rabbitmq-wl
silo,minio:statefulset/plane-minio-wl
migrator,migrate,api-migrate-1:job/plane-api-migrate-1"

# Fills LIVE with one kind/name per line, the form the table and `kubectl logs` use. kubectl prints
# deployment.apps/x, and the sed also drops any warning that 2>&1 caught. On failure, LIVE_ERROR says why.
LIVE=""
LIVE_ERROR=""
load_live() {
  local listed
  if listed="$(kc -n "$ns" get deployments,statefulsets,jobs -o name --request-timeout=10s 2>&1)"; then
    LIVE="$(sed -nE 's#^(deployment|statefulset|job)\.[a-z.]+/#\1/#p' <<<"$listed")"
  else
    LIVE_ERROR="$(tail -1 <<<"$listed")"
  fi
}

print_names() { # The table, then whatever else is live. Call load_live first.
  local names target workload
  printf '  %-34s %s\n' "SVC" "workload in $ns"
  while IFS=: read -r names target; do
    printf '  %-34s %s\n' "${names//,/, }" "$target"
  done <<<"$WORKLOADS"
  while read -r workload; do
    [[ -n "$workload" ]] || continue
    case $'\n'"$WORKLOADS"$'\n' in
      *":$workload"$'\n'*) ;;
      *) printf '  %-34s %s\n' "${workload#*/}" "$workload" ;;
    esac
  done <<<"$LIVE"
  if [[ -n "$LIVE_ERROR" ]]; then
    printf '  Live workloads not listed, as kubectl failed: %s\n' "$LIVE_ERROR"
  fi
}

table_workload() { # <name>: prints the workload the table gives it. Non-zero if the table does not know it.
  local wanted="${1##*/}" names target
  wanted="${wanted#plane-}"
  wanted="${wanted%-wl}"
  while IFS=: read -r names target; do
    case ",$names," in
      *",$wanted,"*)
        echo "$target"
        return 0
        ;;
    esac
  done <<<"$WORKLOADS"
  return 1
}

live_matches() { # <name, or kind/name>: prints each live workload with exactly that name. Call load_live first.
  local workload
  while read -r workload; do
    [[ -n "$workload" ]] || continue
    case "$1" in
      "${workload#*/}" | "$workload" | "${workload%%/*}".*/"${workload#*/}") echo "$workload" ;;
    esac
  done <<<"$LIVE"
}

env_name="${1:-dev}"
svc="${2:-}"
case "$env_name" in
  dev | prod-sim) ;;
  *) die "ENV must be dev or prod-sim, not '$env_name'" ;;
esac
ns="plane-$env_name"
follow=true
case "${3:-}" in
  "") ;;
  --no-follow) follow=false ;;
  *) die "unknown option '$3'. The only option is --no-follow." ;;
esac

if [[ -z "$svc" ]]; then
  load_live
  echo "Usage: make logs ENV=$env_name SVC=<name>. Names in $ns:"
  print_names
  echo "For history and search across pods, use Grafana Explore: http://grafana.localhost"
  exit 0
fi

if ! target="$(table_workload "$svc")"; then
  load_live
  target="$(live_matches "$svc")"
  if [[ -n "$LIVE_ERROR" ]]; then
    print_names >&2
    die "'$svc' is not in the table above, and the live workloads could not be checked for it: $LIVE_ERROR"
  elif [[ -z "$target" ]]; then
    print_names >&2
    die "unknown service '$svc'. The valid names are listed above."
  elif [[ "$target" == *$'\n'* ]]; then
    die "'$svc' names more than one live workload in $ns. Say which, as kind/name: $(tr '\n' ' ' <<<"$target")"
  fi
fi
# Says why before tailing: no cluster, or an environment not deployed yet.
if ! found="$(kc -n "$ns" get "$target" -o name 2>&1)"; then
  die "cannot tail $target in $ns: $found"
fi
exec kubectl --context "$KUBE_CONTEXT" -n "$ns" logs --follow="$follow" "$target" --all-containers --tail=100
