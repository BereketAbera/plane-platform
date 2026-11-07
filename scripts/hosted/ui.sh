#!/usr/bin/env bash
# Reach an admin UI through the tunnel: a port-forward, on this machine only. Runs until Ctrl-C. None has a public route but Grafana's
# and Infisical's, and this still reaches each when its route is down.
#
#   TARGET=plane-prod scripts/hosted/ui.sh argocd|grafana|prometheus|alertmanager|infisical [local-port]
#
# Prints a URL on 127.0.0.1, and where the password lives, never the password itself.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

case "${1:-}" in
  argocd) NS=argocd SVC=svc/argocd-server REMOTE=80 FIRST=18080 NOTE="user admin, password in Secret argocd/argocd-initial-admin-secret, key password" ;;
  grafana) NS=monitoring SVC=svc/kps-grafana REMOTE=80 FIRST=18090 NOTE="the login for https://$HOSTED_GRAFANA_DOMAIN: make remote-grafana-admin TARGET=plane-prod VERB=login. Its session cookie is Secure, which some browsers refuse on http://localhost, and its links name the public host" ;;
  prometheus) NS=monitoring SVC=svc/kps-prometheus REMOTE=9090 FIRST=19090 NOTE="no login" ;;
  alertmanager) NS=monitoring SVC=svc/kps-alertmanager REMOTE=9093 FIRST=19093 NOTE="no login" ;;
  infisical) NS=infisical SVC=svc/infisical REMOTE=8080 FIRST=18100 NOTE="the login for https://$HOSTED_INFISICAL_DOMAIN: make remote-infisical-admin TARGET=plane-prod VERB=login. Its cookies are Secure, which Chrome and Firefox keep on http://localhost and Safari drops, so sign in here with one of those two" ;;
  *) die "usage: $0 argocd|grafana|prometheus|alertmanager|infisical [local-port]" ;;
esac

PORT="${2:-}"
if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "the local port must be a number, and got '$PORT'"
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then die "something already listens on 127.0.0.1:$PORT"; fi
else
  PORT="$(hosted_free_port "$FIRST")"
fi

log "$1 at http://localhost:$PORT ($NOTE). Ctrl-C ends it."
exec "$ROOT/.tools/bin/kubectl" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" -n "$NS" port-forward "$SVC" "$PORT:$REMOTE" --address 127.0.0.1
