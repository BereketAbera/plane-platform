#!/usr/bin/env bash
# Tail logs for one Plane service, or list what can be tailed.
source "$(dirname "$0")/lib/common.sh"

env_name="${1:-dev}"; svc="${2:-}"
ns="plane-$env_name"
if [[ -z "$svc" ]]; then
  echo "Usage: make logs ENV=$env_name SVC=<workload>. Workloads in $ns:"
  kc -n "$ns" get deploy,statefulset -o name | sed 's/^/  /'
  echo "For history and search across pods, use Grafana Explore: http://grafana.localhost"
  exit 0
fi
target="$(kc -n "$ns" get deploy,statefulset -o name | grep -E "/plane-$svc(-wl)?$|/$svc$" | head -1)"
[[ -n "$target" ]] || die "no workload matching '$svc' in $ns"
exec kubectl --context "$KUBE_CONTEXT" -n "$ns" logs -f "$target" --all-containers --tail=100
