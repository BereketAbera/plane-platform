#!/usr/bin/env bash
# Provision the hosted node over SSH. Each stage can run again and changes only what differs. Nothing here reinstalls the OS.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh access
#       an admin user and key-only SSH, proving a new login works before the old way closes
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh os
#       packages, resolvers, sysctls, automatic security updates, and the firewall at "closed" unless already set
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh k3s
#       K3s at the pinned version, its configuration written first
#
# Deliberately stands alone from scripts/hosted/lib.sh, because that one needs a cluster to compare with, and this makes it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOSTED="$ROOT/infrastructure/hosted/plane-prod"
TARGET_FILE="$HOSTED/target.yaml"
YQ="$ROOT/.tools/bin/yq"
KNOWN_HOSTS="$ROOT/.local/hosted/known_hosts"

die() { printf 'fail %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
ok() { printf ' ok %s\n' "$*"; }

[[ "${TARGET:-}" == plane-prod ]] || die "set TARGET=plane-prod"
[[ "${CONFIRM:-}" == plane-prod ]] || die "this changes the server: set CONFIRM=plane-prod"
[[ $# -eq 1 ]] || die "usage: $0 access|os|k3s"
[[ -f "$KNOWN_HOSTS" ]] || die "$KNOWN_HOSTS is missing. Record the host key with ssh-keyscan first"

HOST="$("$YQ" -r .host "$TARGET_FILE")"
ADMIN="$("$YQ" -r .ssh_user "$TARGET_FILE")"
KEY="$("$YQ" -r .ssh_key "$TARGET_FILE")"
KEY="${KEY/#\~/$HOME}"
K3S_VERSION="$("$YQ" -r .k3s_version "$TARGET_FILE")"
[[ -f "$KEY" ]] || die "no SSH key at $KEY"

SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
as_admin() { ssh "${SSH_OPTS[@]}" "$ADMIN@$HOST" "$@"; }
as_root() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

# Reaches root whichever way is open, so a later stage works once root login has closed.
# The probe gets no stdin, or it would swallow the script the caller is feeding this function.
root_shell() {
  if ssh "${SSH_OPTS[@]}" -n "$ADMIN@$HOST" 'sudo -n true' 2>/dev/null; then
    as_admin 'sudo -n bash -s'
  else
    as_root 'bash -s'
  fi
}

install_file() { # install_file <local> <remote> <mode>: only through stdin, so nothing lands in a process list
  local content
  content="$(base64 <"$1" | tr -d '\n')"
  root_shell <<EOF
set -euo pipefail
mkdir -p "\$(dirname "$2")"
tmp="\$(mktemp "$2.XXXXXX")"
printf '%s' '$content' | base64 -d >"\$tmp"
chmod $3 "\$tmp"
if cmp -s "\$tmp" "$2" 2>/dev/null; then rm -f "\$tmp"; else mv "\$tmp" "$2"; echo "changed $2"; fi
EOF
}

stage_access() {
  log "Admin user $ADMIN"
  root_shell <<EOF
set -euo pipefail
id "$ADMIN" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN"
passwd -l "$ADMIN" >/dev/null
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.ssh"
EOF
  install_file "$KEY.pub" "/home/$ADMIN/.ssh/authorized_keys" 600
  root_shell <<EOF
set -euo pipefail
chown "$ADMIN:$ADMIN" "/home/$ADMIN/.ssh/authorized_keys"
printf '%s\n' '$ADMIN ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-wayline-admin
chmod 440 /etc/sudoers.d/90-wayline-admin
visudo -cf /etc/sudoers.d/90-wayline-admin >/dev/null
EOF
  as_admin 'sudo -n true' || die "$ADMIN cannot log in and sudo, so nothing was restricted"
  ok "$ADMIN logs in with the key and has sudo"

  log "Key-only SSH, with a timer that undoes it unless a new login is proved"
  root_shell <<'EOF'
set -euo pipefail
systemctl stop ssh-rollback.timer ssh-rollback.service 2>/dev/null || true
systemctl reset-failed ssh-rollback.timer ssh-rollback.service 2>/dev/null || true
EOF
  install_file "$HOSTED/sshd-wayline.conf" /etc/ssh/sshd_config.d/00-wayline.conf 644
  root_shell <<'EOF'
set -euo pipefail
mkdir -p /run/sshd
sshd -t
systemd-run --quiet --on-active=10min --unit=ssh-rollback /bin/sh -c 'rm -f /etc/ssh/sshd_config.d/00-wayline.conf; systemctl restart ssh.service'
systemctl restart ssh.service
EOF
  sleep 2
  as_admin 'sudo -n true' || die "a new login failed. The timer on the server restores SSH within 10 minutes. Change nothing until then"
  ok "a new login as $ADMIN works"
  local methods
  methods="$(ssh -o BatchMode=yes -o PreferredAuthentications=none -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$ADMIN@$HOST" true 2>&1 | tail -1 || true)"
  [[ "$methods" == *"(publickey)"* ]] || die "the server still offers: $methods. The timer restores SSH within 10 minutes"
  ok "the server offers publickey only"
  if as_root true 2>/dev/null; then
    die "root can still log in. The timer restores the old settings within 10 minutes"
  fi
  ok "root login is refused"
  as_admin 'sudo -n systemctl stop ssh-rollback.timer'
  as_admin 'sudo -n sshd -T' | grep -Ei '^(authenticationmethods|passwordauthentication|permitrootlogin|allowusers|allowtcpforwarding|maxauthtries) ' | sed 's/^/    /'
  ok "rollback timer stopped. The root password still works on Contabo's VNC console, for a lockout"
}

stage_os() {
  log "Packages"
  root_shell <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# kube-router needs ipset, and without it K3s only warns and NetworkPolicy is silently not enforced.
apt-get install -y -qq --no-install-recommends ipset nftables conntrack curl jq >/dev/null
systemctl is-enabled unattended-upgrades >/dev/null
grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
EOF
  ok "packages present, automatic security updates on (no automatic reboot)"

  log "Resolvers and sysctls"
  install_file "$HOSTED/resolved-wayline.conf" /etc/systemd/resolved.conf.d/wayline.conf 644
  install_file "$HOSTED/sysctl.conf" /etc/sysctl.d/90-wayline.conf 644
  root_shell <<'EOF'
set -euo pipefail
systemctl restart systemd-resolved
sysctl --system >/dev/null
install -d -m 755 /srv/wayline /etc/wayline
EOF
  ok "resolvers and sysctls set"

  log "Reboot-required metric for node-exporter"
  install_file "$HOSTED/reboot-metric.sh" /usr/local/sbin/wayline-reboot-metric 755
  root_shell <<'EOF'
set -euo pipefail
printf '%s\n' '*/5 * * * * root /usr/local/sbin/wayline-reboot-metric' >/etc/cron.d/wayline-reboot-metric
chmod 644 /etc/cron.d/wayline-reboot-metric
/usr/local/sbin/wayline-reboot-metric
EOF
  ok "reboot and firewall metrics written every 5 minutes"

  log "Firewall unit"
  install_file "$HOSTED/wayline-edge.service" /etc/systemd/system/wayline-edge.service 644
  if root_shell <<'EOF'
test -s /etc/wayline/edge.nft
EOF
  then
    ok "firewall already has a stage: leaving it. Change it with scripts/hosted/edge.sh"
  else
    "$ROOT/scripts/hosted/edge.sh" closed
  fi
  root_shell <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable wayline-edge.service >/dev/null 2>&1
EOF
  ok "firewall unit enabled, so the rules return after a reboot"
}

stage_k3s() {
  log "K3s configuration, written before K3s starts"
  install_file "$HOSTED/k3s-config.yaml" /etc/rancher/k3s/config.yaml 600
  install_file "$HOSTED/registries.yaml" /etc/rancher/k3s/registries.yaml 600
  install_file "$HOSTED/k3s-resolv.conf" /etc/rancher/k3s/resolv.conf 644
  install_file "$HOSTED/audit.yaml" /var/lib/rancher/k3s/server/audit.yaml 600
  install_file "$HOSTED/kubelet.conf" /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-plane-prod.conf 644

  log "K3s $K3S_VERSION"
  # shellcheck disable=SC2087 # the version is ours to expand, the rest stays for the server
  root_shell <<EOF
set -euo pipefail
install -d -m 700 /var/lib/rancher/k3s/server/logs
if command -v k3s >/dev/null && k3s --version | grep -qF "$K3S_VERSION"; then
  echo "already at $K3S_VERSION"
  systemctl is-active --quiet k3s || systemctl start k3s
else
  # The installer comes from the tag of the version it installs, and it checks the binary's sha256 itself.
  curl -sfL "https://raw.githubusercontent.com/k3s-io/k3s/$(printf '%s' "$K3S_VERSION" | sed 's/+/%2B/')/install.sh" |
    INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
fi
EOF
  log "Waiting for the node"
  local tries=0
  until as_admin "sudo -n k3s kubectl get node --no-headers 2>/dev/null | grep -q ' Ready '"; do
    tries=$((tries + 1))
    [[ $tries -le 40 ]] || die "the node is not Ready after 200 s. Read: journalctl -u k3s"
    sleep 5
  done
  as_admin "sudo -n k3s kubectl get node -o wide --no-headers" | cut -c1-120
  ok "K3s is up. Next: scripts/hosted/kubeconfig.sh, then record the UID it prints in target.yaml"
}

case "$1" in
  access) stage_access ;;
  os) stage_os ;;
  k3s) stage_k3s ;;
  *) die "usage: $0 access|os|k3s" ;;
esac
