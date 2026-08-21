#!/usr/bin/env bash
# Pull the node's restic repositories onto this machine, over a read-only SFTP user, into .local/hosted/plane-prod/offsite-restic.
# restic copy keeps them encrypted, and a compromised VPS can neither reach this copy nor delete it.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/pull-backups.sh setup    make the key and the user wayline-pull on the node
#   TARGET=plane-prod scripts/hosted/pull-backups.sh                             pull now
#
# A pull alone does not make off-VPS status complete. Only a restore from the copy does: scripts/hosted/backup-dest.sh verify, or
# scripts/hosted/restore-test.sh with RESTORE_ON=kind.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-restic.sh
source "$(dirname "$0")/lib-restic.sh"

# The account can do one thing. A key option forces internal-sftp in read-only mode, in sshd itself, so its login shell is never
# run and can be nologin. It reads through group 70, the backup Jobs' GID, which restic's files carry. A plain dump under predeploy,
# until the night seals it, stays owner-only, so this account cannot read it, and it holds no sudo.
setup() {
  hosted_require_confirm "this makes a user on the node"
  hosted_require_ssh
  if [[ ! -s "$PULL_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "wayline-pull@$HOSTED_NAME" -f "$PULL_KEY"
    ok "made the key ${PULL_KEY#"$ROOT"/}"
  fi
  local public
  public="$(cut -d' ' -f1,2 "$PULL_KEY.pub")"
  node_root <<EOF
set -euo pipefail
owner="\$(getent group 70 | cut -d: -f1 || true)"
case "\$owner" in
  "") groupadd --gid 70 wayline-backup ;;
  wayline-backup) ;;
  *) echo "group 70 already belongs to \$owner" >&2; exit 1 ;;
esac
if ! id $PULL_USER >/dev/null 2>&1; then
  useradd --create-home --shell /usr/sbin/nologin --groups wayline-backup $PULL_USER
fi
usermod --append --groups wayline-backup $PULL_USER
passwd -l $PULL_USER >/dev/null
install -d -m 700 -o $PULL_USER -g $PULL_USER /home/$PULL_USER/.ssh
printf '%s\n' 'restrict,command="internal-sftp -R" $public' >/home/$PULL_USER/.ssh/authorized_keys
chown $PULL_USER:$PULL_USER /home/$PULL_USER/.ssh/authorized_keys
chmod 600 /home/$PULL_USER/.ssh/authorized_keys
mkdir -p /run/sshd
# grep reads to the end, not -q: with -q it can stop early, and under pipefail the writer's SIGPIPE reads as no match.
sshd -T | grep -i '^allowusers.*$PULL_USER' >/dev/null || { echo "sshd's AllowUsers does not name $PULL_USER. Run provision-node.sh access" >&2; exit 1; }
EOF
  ok "user $PULL_USER is on the node: read-only SFTP, no shell, no sudo"
}

pull() {
  restic_need_local
  restic_pull_key_or_die
  mkdir -p "$OFFSITE_DIR"
  chmod 700 "$OFFSITE_DIR"
  guard_disk
  local namespace failed="" rc
  for namespace in $BACKUP_NAMESPACES; do
    log "Pulling $namespace"
    rc=0
    copy_from_node "$namespace" "$OFFSITE_DIR/$namespace" || rc=$?
    if [[ "$rc" -eq "$RESTIC_NO_REPOSITORY" ]]; then
      warn "$namespace has no repository on the node yet: no nightly has sealed one. Run: make remote-backup TARGET=plane-prod CONFIRM=plane-prod"
      failed="$failed $namespace"
    elif [[ "$rc" -ne 0 ]]; then
      warn "$namespace did not pull, restic exit $rc. A nightly's prune can remove what a pull is reading, so try again once it has finished."
      failed="$failed $namespace"
    else
      retain_off_vps "$OFFSITE_DIR/$namespace"
      ok "$namespace is at snapshot $(restic -r "$OFFSITE_DIR/$namespace" --password-file "$RESTIC_PASSWORD_LOCAL" snapshots --latest 1 --json | jq -r '.[0] | "\(.short_id), taken \(.time)"')"
    fi
  done
  [[ -z "$failed" ]] || die "did not pull:$failed"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{pulled_at: $at}' >"$OFFSITE_DIR/last-pull.json"
  log "Now prove the copy restores: make remote-backup-dest VERB=verify TARGET=plane-prod"
}

case "${1:-pull}" in
  setup) setup ;;
  pull) pull ;;
  *) die "usage: $0 [setup|pull]" ;;
esac
