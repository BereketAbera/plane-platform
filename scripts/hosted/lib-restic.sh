#!/usr/bin/env bash
# shellcheck disable=SC2034  # what is set here is read by the scripts that source this
# What pull-backups.sh and backup-dest.sh share: restic on this machine, reading the node's repositories over the read-only
# SFTP user. Source after lib.sh; do not execute.
#
# The VPS holds no credential for anywhere off it. This machine holds them all, and reads the node over SFTP, so a compromised
# VPS can neither reach nor delete a copy. The cost: nothing leaves the VPS while this machine is off.

BACKUP_NAMESPACES="infisical plane-prod"
RESTIC_PASSWORD_LOCAL="$LOCAL_DIR/restic-password"
PULL_USER="wayline-pull"
PULL_KEY="$LOCAL_DIR/wayline-pull_ed25519"
OFFSITE_DIR="$LOCAL_DIR/offsite-restic"
OFFSITE_RECORD="$LOCAL_DIR/offsite-verified.json"
# A restore is proved again at least this often, or status goes back to incomplete.
OFFSITE_VERIFY_MAX_AGE_DAYS=35

restic_need_local() {
  hosted_need_restic
  [[ -s "$RESTIC_PASSWORD_LOCAL" ]] || die "${RESTIC_PASSWORD_LOCAL#"$ROOT"/} is missing. It is made once, by scripts/hosted/bootstrap.sh, and the recovery bundle holds a copy."
}

node_repo() { printf 'sftp:%s@%s:%s/%s/restic' "$PULL_USER" "$HOSTED_HOST" "$HOSTED_BACKUP_ROOT" "$1"; } # namespace

# One word to restic's -o, split by it as a shell would. So no path here may hold a space, and the tree's own root does not.
sftp_command() {
  printf 'sftp.command=ssh %s@%s -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -s sftp' \
    "$PULL_USER" "$HOSTED_HOST" "$PULL_KEY" "$HOSTED_KNOWN_HOSTS"
}

# For a test with no node: the same restic calls against any SFTP command and repository.
if [[ -n "${HOSTED_TEST_SFTP_COMMAND:-}" ]]; then
  sftp_command() { printf 'sftp.command=%s' "$HOSTED_TEST_SFTP_COMMAND"; }
  node_repo() { printf 'sftp:test:%s/%s/restic' "$HOSTED_TEST_NODE_ROOT" "$1"; }
fi

restic_pull_key_or_die() {
  [[ -s "$PULL_KEY" || -n "${HOSTED_TEST_SFTP_COMMAND:-}" ]] || die "${PULL_KEY#"$ROOT"/} is missing. Run: make remote-pull-setup TARGET=plane-prod CONFIRM=plane-prod"
}

# restic's exit for no repository there, since 0.17.
RESTIC_NO_REPOSITORY=10

# repo_state <repository> [restic options...]: 0 it is there, 10 it is not, and anything else is a real failure.
repo_state() {
  local repository="$1" rc=0
  shift
  restic -r "$repository" --password-file "$RESTIC_PASSWORD_LOCAL" "$@" cat config >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# copy_from_node <namespace> <destination repository>. Makes the destination first if it is not there, with the source's chunker,
# or nothing would deduplicate. --no-lock, because the read-only user cannot write a lock. It applies to the source: this writes
# its own lock on the destination.
copy_from_node() {
  local namespace="$1" destination="$2" source_repo option rc=0
  source_repo="$(node_repo "$namespace")"
  option="$(sftp_command)"
  repo_state "$destination" || rc=$?
  if [[ "$rc" -eq "$RESTIC_NO_REPOSITORY" ]]; then
    restic -r "$destination" --password-file "$RESTIC_PASSWORD_LOCAL" -o "$option" init \
      --from-repo "$source_repo" --from-password-file "$RESTIC_PASSWORD_LOCAL" --copy-chunker-params --no-lock >/dev/null
  elif [[ "$rc" -ne 0 ]]; then
    warn "cannot read the repository at $destination, restic exit $rc"
    return 1
  fi
  restic -r "$destination" --password-file "$RESTIC_PASSWORD_LOCAL" -o "$option" copy \
    --from-repo "$source_repo" --from-password-file "$RESTIC_PASSWORD_LOCAL" --no-lock --host "$namespace" --tag wayline
}

# Keeps 90 days by time alone. Keeping the newest N could be defeated: a compromised VPS could send N fake snapshots.
retain_off_vps() { # repository
  restic -r "$1" --password-file "$RESTIC_PASSWORD_LOCAL" forget --keep-within 90d --prune >/dev/null
}

# What says an off-VPS copy really restores. backup-dest.sh status reads only this.
offsite_record() { # namespace destination snapshot files taken how
  local tmp
  tmp="$(mktemp "$LOCAL_DIR/.record.XXXXXX")"
  if [[ -s "$OFFSITE_RECORD" ]]; then cp "$OFFSITE_RECORD" "$tmp"; else printf '{}' >"$tmp"; fi
  jq --arg ns "$1" --arg dest "$2" --arg snapshot "$3" --argjson files "$4" --arg taken "$5" --arg how "$6" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$ns][$dest] = {verified_at: $at, snapshot: $snapshot, files: $files, snapshot_taken: $taken, how: $how}' "$tmp" >"$tmp.new"
  mv "$tmp.new" "$OFFSITE_RECORD"
  rm -f "$tmp"
  chmod 600 "$OFFSITE_RECORD"
}
