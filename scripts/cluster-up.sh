#!/usr/bin/env bash
# Create the kind cluster and the local services around it. Idempotent.
source "$(dirname "$0")/lib/common.sh"

guard_disk 15
mkdir -p "$LOCAL_DIR/backups" "$LOCAL_DIR/git" "$LOCAL_DIR/rendered"

NODE_IMAGE="$(grep -E 'image: kindest/node' "$ROOT/infrastructure/kind/cluster.yaml.tmpl" | awk '{print $2}')"
NODE_DIGEST="${NODE_IMAGE#*@}"

ensure_node_image() {
  # Docker Hub's anonymous quota is easy to exhaust from a shared IP, so fetch the node
  # image from mirror.gcr.io by digest and tag it under its canonical name.
  docker image inspect "$NODE_IMAGE" >/dev/null 2>&1 && return 0
  log "Fetching node image $NODE_DIGEST"
  if docker pull "mirror.gcr.io/kindest/node@$NODE_DIGEST"; then
    docker tag "mirror.gcr.io/kindest/node@$NODE_DIGEST" "${NODE_IMAGE%@*}"
    docker image inspect "$NODE_IMAGE" >/dev/null 2>&1 && return 0
  fi
  docker pull "$NODE_IMAGE"
}

if cluster_exists; then
  node_state="$(docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || echo missing)"
  if [[ "$node_state" == "exited" || "$node_state" == "created" ]]; then
    log "Starting the stopped cluster node (data is preserved)"
    docker start "$NODE_CONTAINER" >/dev/null
  else
    ok "cluster $CLUSTER_NAME already running"
  fi
else
  ensure_node_image
  log "Creating kind cluster $CLUSTER_NAME"
  sed "s|__REPO_ROOT__|$ROOT|g" "$ROOT/infrastructure/kind/cluster.yaml.tmpl" > "$LOCAL_DIR/kind-cluster.yaml"
  kind create cluster --config "$LOCAL_DIR/kind-cluster.yaml" --kubeconfig "$KUBECONFIG" --wait 120s
fi
kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1

log "Starting local services (registry, pull-through caches, Git remote)"
docker compose -f "$ROOT/infrastructure/local-services/compose.yaml" up -d --build --quiet-pull 2>&1 | tail -8

wait_for 180 "Kubernetes API" kc get --raw /readyz
wait_for 180 "node Ready" kc wait --for=condition=Ready node --all --timeout=5s
ok "cluster ready: context $KUBE_CONTEXT, kubeconfig $KUBECONFIG"
