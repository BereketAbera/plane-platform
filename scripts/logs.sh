#!/usr/bin/env bash
# Tail logs for one Plane service, or list what can be tailed.
#
#   scripts/logs.sh <dev|prod-sim>            list the names
#   scripts/logs.sh <dev|prod-sim> <name>     tail one workload
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# One line per workload: comma-separated names people use, then the workload those names mean.
# Taken from gitops/environments/{dev,prod-sim}/manifests.yaml, which render the same names in both
# environments because the Helm release is `plane` in both. A real workload name also works, so
# plane-beat-worker-wl needs no entry of its own. Only plane-api-migrate-1 does, as it has no -wl.
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

print_names() {
  local names target
  printf '  %-34s %s\n' "SVC" "workload in $ns"
  while IFS=: read -r names target; do
    printf '  %-34s %s\n' "${names//,/, }" "$target"
  done <<<"$WORKLOADS"
}

resolve_workload() { # <name>: prints the workload. Non-zero if the name means nothing.
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

env_name="${1:-dev}"
svc="${2:-}"
case "$env_name" in
  dev | prod-sim) ;;
  *) die "ENV must be dev or prod-sim, not '$env_name'" ;;
esac
ns="plane-$env_name"

if [[ -z "$svc" ]]; then
  echo "Usage: make logs ENV=$env_name SVC=<name>. Names in $ns:"
  print_names
  echo "For history and search across pods, use Grafana Explore: http://grafana.localhost"
  exit 0
fi

if ! target="$(resolve_workload "$svc")"; then
  print_names >&2
  die "unknown service '$svc'. The valid names are listed above."
fi
# Says why before tailing: no cluster, or an environment not deployed yet.
if ! found="$(kc -n "$ns" get "$target" -o name 2>&1)"; then
  die "cannot tail $target in $ns: $found"
fi
exec kubectl --context "$KUBE_CONTEXT" -n "$ns" logs -f "$target" --all-containers --tail=100
