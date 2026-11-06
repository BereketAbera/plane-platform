#!/usr/bin/env bash
# Move the public firewall between its stages. Every change has a timer on the server that removes the firewall unless a new
# SSH login proves this one did not lock us out.
#
#   scripts/hosted/edge.sh closed        22 only
#   scripts/hosted/edge.sh http          22, and 80 so Let's Encrypt can reach the HTTP-01 challenge
#   scripts/hosted/edge.sh owner <ipv4>  22, 80, and 443 from one address, while the first admin is created
#   scripts/hosted/edge.sh open          22, 80, 443: the site is public
#   scripts/hosted/edge.sh status        the stage in force
#   scripts/hosted/edge.sh scan          ports reachable from this machine, which is the check that counts
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOSTED="$ROOT/infrastructure/hosted/plane-prod"
TARGET_FILE="$HOSTED/target.yaml"
YQ="$ROOT/.tools/bin/yq"
KNOWN_HOSTS="$ROOT/.local/hosted/known_hosts"

die() { printf 'fail %s\n' "$*" >&2; exit 1; }
ok() { printf ' ok %s\n' "$*"; }

HOST="$("$YQ" -r .host "$TARGET_FILE")"
KEY="$("$YQ" -r .ssh_key "$TARGET_FILE")"
KEY="${KEY/#\~/$HOME}"
ADMIN="$("$YQ" -r .ssh_user "$TARGET_FILE")"
SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

server() { # server: a root shell on stdin, through the admin user, or as root until that user exists
  # The probe gets no stdin, or it would swallow the script the caller is feeding this function.
  if ssh "${SSH_OPTS[@]}" -n "$ADMIN@$HOST" 'sudo -n true' 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" "$ADMIN@$HOST" 'sudo -n bash -s'
  else
    ssh "${SSH_OPTS[@]}" "root@$HOST" 'bash -s'
  fi
}
login_works() {
  ssh "${SSH_OPTS[@]}" -n "$ADMIN@$HOST" true 2>/dev/null || ssh "${SSH_OPTS[@]}" -n "root@$HOST" true 2>/dev/null
}

scan() {
  local port
  # 6443 is the API, 10250 the kubelet, 9100 node-exporter, 30000 and 32767 the NodePort range's ends.
  for port in 22 80 443 6443 10250 9100 2379 30000 32767; do
    if nc -z -G 5 "$HOST" "$port" 2>/dev/null; then printf '  %-6s open\n' "$port"; else printf '  %-6s closed\n' "$port"; fi
  done
}

STAGE="${1:-}"
OWNER_IP="${2:-}"
case "$STAGE" in
  closed) rules='' ;;
  http) rules='    tcp dport 80 accept' ;;
  owner)
    [[ "$OWNER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 owner <your public ipv4>"
    rules="    tcp dport 80 accept
    ip saddr $OWNER_IP tcp dport 443 accept"
    ;;
  open)
    rules='    tcp dport 80 accept
    tcp dport 443 accept'
    ;;
  status)
    server <<'EOF'
grep -E 'dport (80|443)' /etc/wayline/edge.nft 2>/dev/null | sed 's/^ */  /' || true
nft list table inet wayline_edge >/dev/null 2>&1 && echo '  table loaded' || echo '  table NOT loaded'
EOF
    exit 0
    ;;
  scan) scan; exit 0 ;;
  *) die "usage: $0 closed|http|owner <ipv4>|open|status|scan" ;;
esac

[[ "${TARGET:-}" == plane-prod ]] || die "set TARGET=plane-prod"
[[ "${CONFIRM:-}" == plane-prod ]] || die "this changes the server's firewall: set CONFIRM=plane-prod"

rendered="$(TEMPLATE="$HOSTED/edge.nft.tmpl" RULES="$rules" python3 -I -c '
import os
print(open(os.environ["TEMPLATE"]).read().replace("@@PUBLIC_RULES@@", os.environ["RULES"]), end="")')"
encoded="$(printf '%s' "$rendered" | base64 | tr -d '\n')"

server <<EOF
set -euo pipefail
install -d -m 755 /etc/wayline
tmp="\$(mktemp /etc/wayline/edge.nft.XXXXXX)"
printf '%s' '$encoded' | base64 -d >"\$tmp"
chmod 644 "\$tmp"
nft -c -f "\$tmp"
systemctl stop edge-rollback.timer 2>/dev/null || true
systemctl reset-failed edge-rollback.timer edge-rollback.service 2>/dev/null || true
systemd-run --quiet --on-active=120 --unit=edge-rollback /usr/sbin/nft delete table inet wayline_edge
nft -f "\$tmp"
mv "\$tmp" /etc/wayline/edge.nft
EOF
sleep 1
login_works || die "a new login failed. The timer on the server removes the firewall within 2 minutes. Change nothing until then"
server <<'EOF'
set -euo pipefail
systemctl stop edge-rollback.timer
EOF
ok "firewall at stage $STAGE, a new login works, rollback timer stopped"
scan
