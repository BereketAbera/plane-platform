#!/usr/bin/env bash
# Shared helpers for every script. Source this file; do not execute it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT="$ROOT"
export PATH="$ROOT/.tools/bin:$PATH"
export CLUSTER_NAME="plane-platform"
export KUBE_CONTEXT="kind-$CLUSTER_NAME"
export NODE_CONTAINER="$CLUSTER_NAME-control-plane"
export LOCAL_DIR="$ROOT/.local"
export KUBECONFIG="$LOCAL_DIR/kubeconfig"

# Refuse to run if the host is about to run out of space. The Docker VM reports hundreds of
# free GiB on its sparse disk, so nothing inside the cluster can see this limit.
MIN_FREE_DISK_GIB="${MIN_FREE_DISK_GIB:-10}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }

free_disk_gib() { df -g "$ROOT" 2>/dev/null | awk 'NR==2{print $4}' || df -BG --output=avail "$ROOT" | tail -1 | tr -dc 0-9; }

guard_disk() {
  local need="${1:-$MIN_FREE_DISK_GIB}" free
  free="$(free_disk_gib)"
  [[ "$free" -ge "$need" ]] || die "only ${free} GiB free on the host, need at least ${need} GiB. Free space first."
}

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }

# wait_for <seconds> <description> <command...>
wait_for() {
  local timeout="$1" what="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || die "timed out after ${timeout}s waiting for: $what"
    sleep 3
  done
}
