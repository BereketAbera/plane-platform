#!/usr/bin/env bash
# The copies of the backups that are off the VPS: this machine's pull, and an S3-compatible destination when the owner has given
# one in .local/hosted/plane-prod/offsite-s3-*.
#
#   TARGET=plane-prod scripts/hosted/backup-dest.sh verify    restore the newest snapshot from each copy, into a temporary folder
#                                                             here, and check every file against the hashes sealed with it
#   TARGET=plane-prod scripts/hosted/backup-dest.sh push      copy the node's repositories to the S3 destination
#   TARGET=plane-prod scripts/hosted/backup-dest.sh status    complete or incomplete, from the local record alone
#
# Exit 0, 1 failed, 2 incomplete. Status reads incomplete until a restore from an off-VPS copy has been verified, in the last
# 35 days, for each namespace. A copy nobody has restored from is a hope.
#
# Push runs here too, and the S3 key stays here, so the VPS holds no key that can delete the copy. So a push needs this machine on.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-restic.sh
source "$(dirname "$0")/lib-restic.sh"

s3_configured() {
  [[ -s "$LOCAL_DIR/offsite-s3-endpoint" && -s "$LOCAL_DIR/offsite-s3-bucket" && -s "$LOCAL_DIR/offsite-s3-key-id" && -s "$LOCAL_DIR/offsite-s3-key-secret" ]]
}

s3_repo() { # namespace
  printf 's3:https://%s/%s/%s' "$(cat "$LOCAL_DIR/offsite-s3-endpoint")" "$(cat "$LOCAL_DIR/offsite-s3-bucket")" "$1"
}

with_s3_keys() { # command...: in a subshell, so the keys live only in that process's environment
  (
    AWS_ACCESS_KEY_ID="$(cat "$LOCAL_DIR/offsite-s3-key-id")"
    AWS_SECRET_ACCESS_KEY="$(cat "$LOCAL_DIR/offsite-s3-key-secret")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    "$@"
  )
}

push() {
  s3_configured || {
    warn "no S3 destination: .local/hosted/plane-prod/offsite-s3-* do not exist, so this machine's pull is the only off-VPS copy. To add one: scripts/hosted/owner-inputs.sh offsite"
    return 2
  }
  restic_need_local
  restic_pull_key_or_die
  local namespace repository failed=""
  for namespace in $BACKUP_NAMESPACES; do
    repository="$(s3_repo "$namespace")"
    log "Copying $namespace to S3"
    if with_s3_keys copy_from_node "$namespace" "$repository" && with_s3_keys retain_off_vps "$repository"; then
      ok "$namespace copied"
    else
      warn "$namespace did not copy"
      failed="$failed $namespace"
    fi
  done
  [[ -z "$failed" ]] || die "did not copy:$failed"
  log "Now prove it restores: make remote-backup-dest VERB=verify TARGET=plane-prod"
}

VERIFY_DIR=""
verify_cleanup() { if [[ -n "$VERIFY_DIR" ]]; then rm -rf "$VERIFY_DIR"; fi; }

# verify_one <destination> <namespace> <repository>. Restores into a folder here that goes when this ends: it is plaintext.
verify_one() {
  local destination="$1" namespace="$2" repository="$3" snapshot files created rc=0 backup
  VERIFY_DIR="$(mktemp -d "$LOCAL_DIR/.verify.XXXXXX")"
  repo_state "$repository" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    warn "$destination has no readable repository for $namespace, restic exit $rc"
    return 2
  fi
  restic -r "$repository" --password-file "$RESTIC_PASSWORD_LOCAL" check --read-data-subset=10% >/dev/null ||
    { warn "$destination: restic check failed for $namespace"; return 1; }
  snapshot="$(restic -r "$repository" --password-file "$RESTIC_PASSWORD_LOCAL" snapshots --host "$namespace" --tag wayline --latest 1 --json | jq -r '.[0].short_id // ""')"
  if [[ -z "$snapshot" ]]; then
    warn "$destination has no snapshot of $namespace"
    return 2
  fi
  restic -r "$repository" --password-file "$RESTIC_PASSWORD_LOCAL" restore "$snapshot" --target "$VERIFY_DIR" --verify >/dev/null ||
    { warn "$destination: restic restore failed for $namespace"; return 1; }
  # Under the path restic saved it from, which this need not know.
  backup="$(dirname "$(find "$VERIFY_DIR" -type f -name SHA256SUMS | head -1)")"
  [[ -s "$backup/SHA256SUMS" && -s "$backup/manifest.json" ]] || { warn "$destination: snapshot $snapshot of $namespace has no SHA256SUMS or manifest"; return 1; }
  (cd "$backup" && shasum -a 256 -c SHA256SUMS >/dev/null) || { warn "$destination: a file in snapshot $snapshot of $namespace does not match its hash"; return 1; }
  files="$(grep -c '' "$backup/SHA256SUMS" | tr -d ' ')"
  created="$(jq -r '.created_at' "$backup/manifest.json")"
  verify_cleanup
  VERIFY_DIR=""
  offsite_record "$namespace" "$destination" "$snapshot" "$files" "$created" "backup-dest verify"
  ok "$destination: $namespace snapshot $snapshot, taken $created, restored, and all $files files match their hashes"
}

# A copy that fails today says nothing good about the proof from last month, so that proof goes.
unrecord() { # namespace destination
  local tmp
  [[ -s "$OFFSITE_RECORD" ]] || return 0
  tmp="$(mktemp "$LOCAL_DIR/.record.XXXXXX")"
  jq --arg ns "$1" --arg dest "$2" 'if .[$ns] then del(.[$ns][$dest]) else . end' "$OFFSITE_RECORD" >"$tmp"
  mv "$tmp" "$OFFSITE_RECORD"
  chmod 600 "$OFFSITE_RECORD"
}

verify() {
  restic_need_local
  trap verify_cleanup EXIT
  guard_disk
  # A kill leaves a restored copy behind, plaintext. Old enough to be from no run still going.
  find "$LOCAL_DIR" -maxdepth 1 -type d -name '.verify.*' -mmin +720 -exec rm -rf {} +
  local namespace worst=0 rc any=no
  for namespace in $BACKUP_NAMESPACES; do
    if [[ -d "$OFFSITE_DIR/$namespace" ]]; then
      any=yes
      rc=0
      verify_one laptop "$namespace" "$OFFSITE_DIR/$namespace" || rc=$?
      if [[ "$rc" -ne 0 ]]; then unrecord "$namespace" laptop; fi
      if [[ "$rc" -eq 1 || "$worst" -eq 1 ]]; then worst=1; elif [[ "$rc" -ne 0 ]]; then worst=2; fi
      verify_cleanup
    fi
    if s3_configured; then
      any=yes
      rc=0
      with_s3_keys verify_one s3 "$namespace" "$(s3_repo "$namespace")" || rc=$?
      if [[ "$rc" -ne 0 ]]; then unrecord "$namespace" s3; fi
      if [[ "$rc" -eq 1 || "$worst" -eq 1 ]]; then worst=1; elif [[ "$rc" -ne 0 ]]; then worst=2; fi
      # The subshell's own record of its folder went with it, and so did its trap. So sweep here.
      find "$LOCAL_DIR" -maxdepth 1 -type d -name '.verify.*' -exec rm -rf {} +
    fi
  done
  if [[ "$any" == no ]]; then
    warn "there is no off-VPS copy to verify. Pull one first: make remote-pull-backups TARGET=plane-prod"
    return 2
  fi
  status || true
  return "$worst"
}

# Prints the state from the record alone. No network, so status.sh can call it.
status() {
  local namespace problems="" verified age_days newest now
  now="$(date +%s)"
  for namespace in $BACKUP_NAMESPACES; do
    newest="$(jq -r --arg ns "$namespace" '[.[$ns] // {} | to_entries[] | .value.verified_at] | sort | last // ""' "$OFFSITE_RECORD" 2>/dev/null || true)"
    if [[ -z "$newest" ]]; then
      problems="$problems $namespace has never been restored from an off-VPS copy."
      continue
    fi
    verified="$(python3 -I -c 'import datetime, sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$newest")"
    age_days=$(((now - verified) / 86400))
    if [[ "$age_days" -gt "$OFFSITE_VERIFY_MAX_AGE_DAYS" ]]; then
      problems="$problems $namespace was last restored from an off-VPS copy $age_days days ago."
    fi
  done
  if [[ -n "$problems" ]]; then
    printf 'off-VPS backups incomplete:%s Run: make remote-pull-backups, then make remote-backup-dest VERB=verify\n' "$problems"
    return 2
  fi
  if s3_configured; then
    printf 'off-VPS backups complete: each namespace was restored from an off-VPS copy in the last %s days, with an S3 destination set\n' "$OFFSITE_VERIFY_MAX_AGE_DAYS"
  else
    printf 'off-VPS backups complete: each namespace was restored from this machine'"'"'s copy in the last %s days. No S3 destination, so this machine is the only copy off the VPS\n' "$OFFSITE_VERIFY_MAX_AGE_DAYS"
  fi
}

case "${1:-}" in
  verify) verify ;;
  push) push ;;
  status) status ;;
  *) die "usage: $0 verify|push|status" ;;
esac
