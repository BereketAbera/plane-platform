#!/usr/bin/env bash
# Fetch K3s's kubeconfig over SSH and rewrite it for the tunnel: one context, plane-prod, on https://127.0.0.1:16443, at mode
# 0600 in .local/hosted/plane-prod/kubeconfig. It is never merged into ~/.kube/config, so no other tool can pick it up.
# Then it prints the kube-system UID, which target.yaml records and every later script compares with.
#
#   TARGET=plane-prod scripts/hosted/kubeconfig.sh
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp "$LOCAL_DIR/.kubeconfig.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

log "Fetching /etc/rancher/k3s/k3s.yaml from $HOSTED_HOST"
node_ssh_quiet 'sudo -n cat /etc/rancher/k3s/k3s.yaml' >"$tmp" || die "could not read K3s's kubeconfig. Has provision-node.sh k3s run?"

[[ "$(yq -r '[(.clusters | length), (.users | length), (.contexts | length)] | join(" ")' "$tmp")" == "1 1 1" ]] ||
  die "K3s's kubeconfig holds more than one cluster, user or context, so this will not guess which to rewrite"

SERVER="https://127.0.0.1:$HOSTED_TUNNEL_PORT" yq -i '
    .clusters[0].name = "plane-prod"
  | .clusters[0].cluster.server = strenv(SERVER)
  | .users[0].name = "plane-prod"
  | .contexts[0].name = "plane-prod"
  | .contexts[0].context.cluster = "plane-prod"
  | .contexts[0].context.user = "plane-prod"
  | .current-context = "plane-prod"' "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$KUBECONFIG"
ok "kubeconfig written to ${KUBECONFIG#"$ROOT"/}, mode 0600, one context: plane-prod"

"$ROOT/scripts/hosted/tunnel.sh" start
kube_system_uid="$(kc --request-timeout=20s get namespace kube-system -o jsonpath='{.metadata.uid}')" ||
  die "the API server does not answer through the tunnel"
live_nodes="$(kc --request-timeout=20s get nodes -o jsonpath='{.items[*].metadata.name}')"

[[ "$live_nodes" == "$HOSTED_NODE" ]] || die "the live nodes are \"$live_nodes\", and target.yaml records \"$HOSTED_NODE\". Stop here: this is not the machine target.yaml describes"

printf 'kube_system_uid: %s\n' "$kube_system_uid"
case "$HOSTED_UID" in
  pending) log "Record that line in ${HOSTED_TARGET_FILE#"$ROOT"/} and commit it. Until then only provisioning is allowed." ;;
  "$kube_system_uid") ok "it matches target.yaml" ;;
  *) die "target.yaml records $HOSTED_UID, so this is a different cluster from the one it describes. K3s was reinstalled, or this is the wrong machine. Find out which before changing that file." ;;
esac
