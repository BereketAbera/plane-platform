#!/usr/bin/env bash
# The SSH tunnel to the K3s API, which is the only way to it: 127.0.0.1:16443 here to 127.0.0.1:6443 on the node.
#
#   TARGET=plane-prod scripts/hosted/tunnel.sh start     up, or already up
#   TARGET=plane-prod scripts/hosted/tunnel.sh stop      down, or already down
#   TARGET=plane-prod scripts/hosted/tunnel.sh status    exit 0 up, 3 down
#
# One master connection on a control socket, so start and stop can tell whether it is theirs. Nothing here touches the node
# beyond logging in.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SOCKET="$LOCAL_DIR/tunnel.sock"
FORWARD="127.0.0.1:$HOSTED_TUNNEL_PORT:127.0.0.1:6443"

master_alive() { ssh -S "$SOCKET" -O check "$HOSTED_SSH_USER@$HOSTED_HOST" >/dev/null 2>&1; }
port_open() { nc -z 127.0.0.1 "$HOSTED_TUNNEL_PORT" >/dev/null 2>&1; }

start() {
  if master_alive; then
    # A master can outlive its forward, if the port was taken when it asked. Then it is no use, so it goes.
    if port_open; then
      ok "tunnel already up on 127.0.0.1:$HOSTED_TUNNEL_PORT"
      return 0
    fi
    warn "the tunnel's connection is up with nothing listening, so replacing it"
    stop
  fi
  rm -f "$SOCKET"
  if port_open; then
    die "something else already listens on 127.0.0.1:$HOSTED_TUNNEL_PORT. Free that port: this tunnel will not share it, and a stranger answering there must not be taken for the API"
  fi
  hosted_require_ssh
  ssh -f -N -M -S "$SOCKET" "${HOSTED_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L "$FORWARD" "$HOSTED_SSH_USER@$HOSTED_HOST" || die "could not open the tunnel to $HOSTED_SSH_USER@$HOSTED_HOST"
  local tries=0
  until port_open; do
    tries=$((tries + 1))
    [[ $tries -le 20 ]] || die "the tunnel started, and 127.0.0.1:$HOSTED_TUNNEL_PORT does not answer"
    sleep 0.5
  done
  ok "tunnel up on 127.0.0.1:$HOSTED_TUNNEL_PORT"
}

stop() {
  if master_alive; then
    ssh -S "$SOCKET" -O exit "$HOSTED_SSH_USER@$HOSTED_HOST" >/dev/null 2>&1 || warn "the tunnel's connection did not say it stopped"
  fi
  rm -f "$SOCKET"
  ok "tunnel down"
}

status() {
  if master_alive && port_open; then
    ok "tunnel up on 127.0.0.1:$HOSTED_TUNNEL_PORT"
    return 0
  fi
  log "tunnel down"
  return 3
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) die "usage: $0 start|stop|status" ;;
esac
