#!/usr/bin/env bash
# Reach an admin UI through the tunnel: a port-forward, on this machine only. Runs until Ctrl-C. None has a public route but Grafana's
# and Infisical's, and this still reaches each when its route is down.
#
#   TARGET=plane-prod scripts/hosted/ui.sh argocd|grafana|prometheus|alertmanager|infisical|hatchet|frameflow-silo [local-port]
#
# Prints a URL on 127.0.0.1, and where the password lives, never the password itself.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Frameflow's Hatchet takes one port. Its SERVER_URL is http://localhost:18888, which every token it mints carries and which cannot move
# while one is in use, and its sign-in cookie is for localhost. So its dashboard is forwarded there alone, and opened as localhost, not
# 127.0.0.1.
ONLY_PORT=""
case "${1:-}" in
  argocd) NS=argocd SVC=svc/argocd-server REMOTE=80 FIRST=18080 NOTE="user admin, password in Secret argocd/argocd-initial-admin-secret, key password" ;;
  grafana) NS=monitoring SVC=svc/kps-grafana REMOTE=80 FIRST=18090 NOTE="the login for https://$HOSTED_GRAFANA_DOMAIN: make remote-grafana-admin TARGET=plane-prod VERB=login. Its session cookie is Secure, which some browsers refuse on http://localhost, and its links name the public host" ;;
  prometheus) NS=monitoring SVC=svc/kps-prometheus REMOTE=9090 FIRST=19090 NOTE="no login" ;;
  alertmanager) NS=monitoring SVC=svc/kps-alertmanager REMOTE=9093 FIRST=19093 NOTE="no login" ;;
  infisical) NS=infisical SVC=svc/infisical REMOTE=8080 FIRST=18100 NOTE="the login for https://$HOSTED_INFISICAL_DOMAIN: make remote-infisical-admin TARGET=plane-prod VERB=login. Its cookies are Secure, which Chrome and Firefox keep on http://localhost and Safari drops, so sign in here with one of those two" ;;
  hatchet) NS=frameflow SVC=svc/hatchet REMOTE=8888 FIRST=18888 ONLY_PORT=18888 NOTE="user admin@frameflow.local, password in Secret frameflow/hatchet-server, key ADMIN_PASSWORD" ;;
  frameflow-silo) NS=frameflow SVC=svc/frameflow-silo REMOTE=9090 FIRST=18110 NOTE="Frameflow's Silo console. Its root login is in Secret frameflow/frameflow-silo-root, keys MINIO_ROOT_USER and MINIO_ROOT_PASSWORD" ;;
  *) die "usage: $0 argocd|grafana|prometheus|alertmanager|infisical|hatchet|frameflow-silo [local-port]" ;;
esac

PORT="${2:-}"
if [[ -n "$ONLY_PORT" ]]; then
  [[ -z "$PORT" || "$PORT" == "$ONLY_PORT" ]] || die "$1 is forwarded to port $ONLY_PORT alone, the one its SERVER_URL names, and got '$PORT'"
  PORT="$ONLY_PORT"
fi
if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "the local port must be a number, and got '$PORT'"
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then die "something already listens on 127.0.0.1:$PORT"; fi
else
  PORT="$(hosted_free_port "$FIRST")"
fi

log "$1 at http://localhost:$PORT ($NOTE). Ctrl-C ends it."
exec "$ROOT/.tools/bin/kubectl" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" -n "$NS" port-forward "$SVC" "$PORT:$REMOTE" --address 127.0.0.1
