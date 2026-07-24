#!/usr/bin/env bash
# The recovery set: what a restore into a clean environment needs beyond the database dumps. Source
# after scripts/lib/common.sh and infisical/lib/api.sh; do not execute. Bash 3.2.
#
# Infisical is restored first, because it is the source of truth for every Plane secret. Its database
# alone does not bring it back, so each Infisical backup also holds or names the rest:
#
#   recovery/terraform.tfstate   Copied. The state of infisical/terraform that matches this dump.
#   recovery/set.json            Names the rest, and proves which values this dump can render:
#     secret_zero                sha256 of each file in .local/secret-zero. Secret zero stays where it
#                                is, at 0700, and is never copied into a backup. Without it a dump
#                                is unreadable, so the two must be kept apart and both kept.
#     admin                      Who the admin token belongs to and when it ends. Never the token.
#     identity                   Organization, project and identity ids.
#     plane_secrets              For each Plane secret: truncated hash of its value, version and id.
#
# Each Plane backup holds the test files that belong to its dump, because the accounts are rows in it:
#
#   recovery/test-accounts.env   That environment's lines of .local/test-accounts.env.
#   recovery/test-sentinel.json  .local/test-sentinel-<env>.json.
#   recovery/objects.types.tsv   Object key and Content-Type, which the host folder cannot keep.
#
# A hash truncated to 16 hex characters of a value of at least 80 random bits is safe beside the dump,
# as the fingerprints in the manifests are. PG_USER, PG_DB and RABBITMQ_USER are not random, and not secret.

# Needed to read or to trust the restored instance. Nothing else can stand in for them.
RECOVERY_ZERO_REQUIRED="ENCRYPTION_KEY AUTH_SECRET"
# A restore can do without these. Postgres and Redis start empty and take whatever the Secret says, so a new
# password works, and bootstrap rewrites the machine file. The admin token expires, and the file can be lost: with
# the keys and the dump, the first admin's password mints another, and without the password a person who has it
# can. So those two decide how a restore logs in, and neither decides whether it can start. See
# recovery_admin_plan. The checksum says which file belongs to this dump, because a token minted after the dump is
# not in it, and the server has the last word on any token.
RECOVERY_ZERO_OPTIONAL="infisical-admin.json infisical-admin-password DB_PASSWORD REDIS_PASSWORD infisical-machine.json"
# Backups are kept by count, and no schedule says how old that count gets, so this is how long a backup is
# assumed to stay in use. It only decides when to warn about a token ending.
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
RECOVERY_TF_STATE="$LOCAL_DIR/terraform/infisical/terraform.tfstate"
# Rendered Secret, key, and the Infisical secret it must hold. From helm/plane/overlays/*/infisical.yaml.
RECOVERY_RENDERED="
plane-pgdb POSTGRES_USER PG_USER
plane-pgdb POSTGRES_PASSWORD PG_PASSWORD
plane-pgdb POSTGRES_DB PG_DB
plane-rabbitmq RABBITMQ_DEFAULT_USER RABBITMQ_USER
plane-rabbitmq RABBITMQ_DEFAULT_PASS RABBITMQ_PASSWORD
plane-doc-store MINIO_ROOT_USER SILO_ACCESS_KEY
plane-doc-store MINIO_ROOT_PASSWORD SILO_SECRET_KEY
plane-doc-store AWS_ACCESS_KEY_ID SILO_ACCESS_KEY
plane-doc-store AWS_SECRET_ACCESS_KEY SILO_SECRET_KEY
plane-app-keys SECRET_KEY SECRET_KEY
plane-app-keys LIVE_SERVER_SECRET_KEY LIVE_SERVER_SECRET_KEY
"

recovery_sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The node's container id names a cluster. It outlives a stop and a restart of Docker, and make up makes a new one with
# a new cluster. Prints nothing if Docker will not say.
recovery_cluster_id() { docker inspect -f '{{.Id}}' "$NODE_CONTAINER" 2>/dev/null || true; }

# True if the cluster the marker's lines were written on is no longer here, with no cluster at all or another of the
# same name, as a plain make up leaves after a loss. What that restore finished went with it. A marker that names no
# cluster, or a Docker that will not say, cannot tell, and then the lines stand: nothing is replaced on their word, and
# whatever is not done still has the guard in front of it. kind is read by itself, and not through cluster_exists, where
# a read that failed looks like no cluster, which here would delete what came back from the marker and replace it.
recovery_marker_cluster_gone() {
  local was now list
  list="$(kind get clusters 2>/dev/null)" || return 1
  grep -qx "$CLUSTER_NAME" <<<"$list" || return 0
  was="$(sed -n 's/^cluster=//p' "$RESTORE_CLEAN_MARKER")"
  [[ -n "$was" ]] || return 1
  now="$(recovery_cluster_id)"
  [[ -n "$now" && "$now" != "$was" ]]
}

# The same hash the backup Jobs put in a manifest. Value on stdin, never in argv.
recovery_fp() { shasum -a 256 | cut -c1-16; }

env_prefix() { printf 'PLANE_%s_' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

# Lists SHA256SUMS again for everything under recovery/, so a restore checks those files like the rest.
# This is the last step of writing a set: a set.json that SHA256SUMS does not name is unfinished.
recovery_seal() { # backup-dir
  local dir="$1" sums f
  sums="$(grep -v ' \./recovery/' "$dir/SHA256SUMS" || true)"
  {
    printf '%s\n' "$sums"
    (cd "$dir" && find ./recovery -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done)
  } > "$dir/.SHA256SUMS.tmp"
  chmod 600 "$dir/.SHA256SUMS.tmp"
  mv "$dir/.SHA256SUMS.tmp" "$dir/SHA256SUMS"
  (cd "$dir" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "checksum verification failed for $dir after writing its recovery set"
}

# ------ Writing, from backup.sh ---------------------------------------------------------------------

# Prints {name: {fp, version, id}} for one environment's Plane secrets, in one request. The response
# holds values, so it stays in IA_BODY and reaches jq on stdin. Says why and fails if it cannot.
recovery_secret_table() { # env
  local env="$1" project slug key fp version id table='{}'
  project="$(jq -er --arg env "$env" '.project_ids[$env]' "$MACHINE_FILE")" || return 1
  slug="$(jq -er '.environment_slug' "$MACHINE_FILE")" || return 1
  ia_request GET "/api/v4/secrets?projectId=$project&environment=$slug&secretPath=%2F&viewSecretValue=true&expandSecretReferences=false&includeImports=false&recursive=false"
  if [[ "$IA_STATUS" != 200 ]]; then
    warn "reading the $env secrets from Infisical returned HTTP $IA_STATUS: $(ia_error)"
    return 1
  fi
  for key in $(printf '%s' "$IA_BODY" | jq -r '[.secrets[].secretKey] | sort | .[]'); do
    fp="$(printf '%s' "$IA_BODY" | jq -je --arg k "$key" '.secrets[] | select(.secretKey == $k) | .secretValue' | recovery_fp)" || return 1
    version="$(printf '%s' "$IA_BODY" | jq -r --arg k "$key" '.secrets[] | select(.secretKey == $k) | .version')"
    id="$(printf '%s' "$IA_BODY" | jq -r --arg k "$key" '.secrets[] | select(.secretKey == $k) | .id')"
    table="$(jq -cn --argjson t "$table" --arg k "$key" --arg fp "$fp" --argjson v "$version" --arg id "$id" \
      '$t + {($k): {fp: $fp, version: $v, id: $id}}')"
  done
  printf '%s\n' "$table"
}

# Writes recovery/ into a finished Infisical backup. Returns non-zero if the set is incomplete: the dump
# is still good for an in-place restore, but a clean restore will refuse it.
recovery_write_infisical() { # backup-dir
  local dir="$1" rec="$1/recovery" zero='{}' name state_json=null identity=null secrets=null env table complete=true admin=null problem
  mkdir -p "$rec"
  chmod 700 "$rec"

  # Bootstrap is the only writer, and it runs from this host, so no cluster action can tear this copy.
  if [[ -s "$RECOVERY_TF_STATE" ]] && jq -e '.serial' "$RECOVERY_TF_STATE" >/dev/null 2>&1; then
    cp "$RECOVERY_TF_STATE" "$rec/terraform.tfstate"
    chmod 600 "$rec/terraform.tfstate"
    state_json="$(jq -c --arg sha "$(recovery_sha256 "$rec/terraform.tfstate")" \
      '{path: "recovery/terraform.tfstate", sha256: $sha, serial: .serial, lineage: .lineage, resources: (.resources | length)}' "$rec/terraform.tfstate")"
  else
    warn "no Terraform state at $RECOVERY_TF_STATE, so this backup cannot serve a clean restore"
    complete=false
  fi

  for name in $RECOVERY_ZERO_REQUIRED $RECOVERY_ZERO_OPTIONAL; do
    if [[ -s "$SECRET_ZERO_DIR/$name" ]]; then
      zero="$(jq -cn --argjson z "$zero" --arg n "$name" --arg sha "$(recovery_sha256 "$SECRET_ZERO_DIR/$name")" '$z + {($n): {sha256: $sha}}')"
    else
      case " $RECOVERY_ZERO_REQUIRED " in
        *" $name "*) warn "$SECRET_ZERO_DIR/$name is missing, so this backup cannot serve a clean restore"; complete=false ;;
        *) warn "$SECRET_ZERO_DIR/$name is missing, so the recovery set does not name it" ;;
      esac
    fi
  done

  # The values are read back from Infisical itself, not from what an operator last rendered.
  problem="$(ia_admin_problem)"
  if [[ -n "$problem" ]]; then
    warn "$problem, so nothing can read the secrets back and this backup cannot serve a clean restore"
    complete=false
  elif [[ -s "$MACHINE_FILE" ]]; then
    ia_init
    ia_load_admin
    identity="$(jq -c '{organization: .organization.id, project_ids: .project_ids, identity_ids: .identity_ids}' "$MACHINE_FILE")"
    secrets='{}'
    for env in dev prod-sim; do
      if table="$(recovery_secret_table "$env")"; then
        secrets="$(jq -cn --argjson s "$secrets" --arg e "$env" --argjson t "$table" '$s + {($e): $t}')"
      else
        warn "could not read the $env secrets back from Infisical, so this backup cannot serve a clean restore"
        complete=false
      fi
    done
    ia_cleanup
  else
    warn "no machine file in $SECRET_ZERO_DIR, so this backup cannot serve a clean restore"
    complete=false
  fi
  if [[ -s "$ADMIN_FILE" ]]; then
    admin="$(jq -c --argjson exp "$(ia_file_token_exp "$ADMIN_FILE")" '{email, organization, identity, token_exp: $exp}' "$ADMIN_FILE")"
  fi

  jq -n --arg backup "${dir##*/}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson complete "$complete" \
    --argjson zero "$zero" --argjson state "$state_json" --argjson identity "$identity" --argjson secrets "$secrets" --argjson admin "$admin" '{
      schema: 1,
      backup: $backup,
      created_at: $at,
      complete: $complete,
      secret_zero: {location: ".local/secret-zero", files: $zero},
      terraform_state: $state,
      admin: $admin,
      identity: $identity,
      plane_secrets: $secrets
    }' > "$rec/set.json"
  chmod 600 "$rec/set.json"
  recovery_seal "$dir"
  # Asks the file rather than the flag: errexit is off in a function called from `||`.
  jq -e '.complete and .terraform_state != null and .identity != null
    and (.plane_secrets | has("dev") and has("prod-sim"))' "$rec/set.json" >/dev/null
}

# Before the dump, so the token a backup names is a row in that dump. A token minted after it is not, and a restore
# of that dump would then have to mint another.
recovery_prepare_admin() {
  local rc=0
  ia_init
  ia_ensure_admin "$(jq -r '.organization.id // empty' "$MACHINE_FILE" 2>/dev/null || true)" || rc=$?
  ia_cleanup
  if [[ "$rc" -ne 0 ]]; then
    warn "$(ia_admin_problem), and nothing here could replace it. The dump goes ahead, and its recovery set will not be whole."
    ia_print_sign_in_steps "make backup ENV=infisical"
  fi
}

# Retention for Infisical, from the host, and only once the backup just taken has a complete recovery set, so a run
# of backups that cannot finish theirs removes nothing. Only a complete set counts toward KEEP, so the newest one
# cannot go. A backup with no complete set is kept while it is newer than the oldest set kept, since an in-place
# restore can still use its dump, and goes after that.
recovery_prune_infisical() { # keep
  local keep="$1" root="$LOCAL_DIR/backups/infisical" id complete=0
  for id in $(recovery_ids infisical | LC_ALL=C sort -r); do
    if recovery_set_complete "$root/$id"; then
      complete=$((complete + 1))
      if [[ "$complete" -gt "$keep" ]]; then
        rm -rf -- "${root:?}/$id" || warn "retention could not remove $id"
        ok "retention: removed $id, past the newest $keep complete sets"
      fi
    elif [[ "$complete" -ge "$keep" ]]; then
      rm -rf -- "${root:?}/$id" || warn "retention could not remove $id"
      ok "retention: removed $id, which has no complete recovery set and is older than every set kept"
    fi
  done
}

# Writes recovery/ into a finished Plane backup. Best effort apart from the seal: a missing accounts
# file costs only the proofs that need it, and the restore reports those as NOT RUN.
recovery_write_plane() { # backup-dir env
  local dir="$1" env="$2" rec="$1/recovery" accounts="$LOCAL_DIR/test-accounts.env" sentinel prefix
  mkdir -p "$rec"
  chmod 700 "$rec"
  prefix="$(env_prefix "$env")"
  if [[ -f "$accounts" ]]; then
    grep "^$prefix" "$accounts" > "$rec/test-accounts.env" || rm -f "$rec/test-accounts.env"
  fi
  sentinel="$LOCAL_DIR/test-sentinel-$env.json"
  if [[ -f "$sentinel" ]]; then cp "$sentinel" "$rec/test-sentinel.json"; fi
  jq -r '.[] | select(.IsDir | not) | [.Path, .MimeType] | @tsv' "$dir/objects.lsjson" > "$rec/objects.types.tsv"
  find "$rec" -type f -exec chmod 600 {} +
  recovery_seal "$dir"
}

# ------ Reading, from restore.sh and the drill --------------------------------------------------------

recovery_set_file() { printf '%s/recovery/set.json' "$1"; }

# True for a finished Infisical backup whose recovery set is whole, sealed and matches its checksums.
recovery_set_complete() { # backup-dir
  local dir="$1" set_file
  set_file="$(recovery_set_file "$dir")"
  [[ -f "$dir/manifest.json" && -f "$set_file" ]] || return 1
  grep -F ' ./recovery/set.json' "$dir/SHA256SUMS" >/dev/null 2>&1 || return 1
  (cd "$dir" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || return 1
  [[ "$(jq -r '.complete' "$set_file" 2>/dev/null)" == true ]]
}

# Why a backup cannot serve a clean restore, for the message that refuses it.
recovery_why_incomplete() { # backup-dir
  local dir="$1" set_file
  set_file="$(recovery_set_file "$dir")"
  if [[ ! -f "$dir/manifest.json" ]]; then
    printf 'it is not a finished backup'
  elif [[ ! -f "$set_file" ]]; then
    printf 'it has no recovery set, so it holds no Terraform state and names no secret zero'
  elif ! (cd "$dir" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
    printf 'its files do not match SHA256SUMS'
  elif ! grep -F ' ./recovery/set.json' "$dir/SHA256SUMS" >/dev/null 2>&1; then
    printf 'its recovery set was never finished'
  else
    printf 'the backup that wrote its recovery set could not complete it'
  fi
}

# Backup ids of one environment in ascending order. Names are UTC timestamps and globs sort.
recovery_ids() { # env
  local candidate
  for candidate in "$LOCAL_DIR/backups/$1"/[0-9]*T[0-9]*Z; do
    if [[ -f "$candidate/manifest.json" ]]; then printf '%s\n' "${candidate##*/}"; fi
  done
}

# The newest Infisical backup that can serve a clean restore, naming any newer one it had to pass over.
recovery_latest_infisical() {
  local id best="" skipped=""
  for id in $(recovery_ids infisical); do
    if recovery_set_complete "$LOCAL_DIR/backups/infisical/$id"; then
      best="$id"
      skipped=""
    else
      skipped="$skipped $id"
    fi
  done
  [[ -n "$best" ]] || return 1
  if [[ -n "$skipped" ]]; then warn "newer Infisical backups have no complete recovery set, so they were passed over:$skipped"; fi
  printf '%s' "$best"
}

# The Plane backup to pair with an Infisical backup. Only one this Infisical can decrypt qualifies,
# meaning the SECRET_KEY hash in its manifest equals the one in the recovery set. Among those, in order:
# the newest taken after this Infisical backup and before the next one with a complete set, which is what
# `backup all` produces, and a next one with no complete set does not end that window, because `backup all` goes on
# to the Plane backups when Infisical's set fails; else the newest before it; else the oldest later one. Prints the
# id, or fails.
recovery_pick_plane() { # env infisical-id explicit-id-or-empty
  local env="$1" iid="$2" explicit="$3" set_file want next="" id fp in_window="" before="" after=""
  set_file="$(recovery_set_file "$LOCAL_DIR/backups/infisical/$iid")"
  want="$(jq -r --arg e "$env" '.plane_secrets[$e].SECRET_KEY.fp // ""' "$set_file")"
  [[ -n "$want" ]] || return 1
  if [[ -n "$explicit" ]]; then
    [[ -f "$LOCAL_DIR/backups/$env/$explicit/manifest.json" ]] || return 1
    [[ "$(jq -r '.secret_key_fp' "$LOCAL_DIR/backups/$env/$explicit/manifest.json")" == "$want" ]] || return 1
    printf '%s' "$explicit"
    return 0
  fi
  for id in $(recovery_ids infisical); do
    if [[ "$id" > "$iid" ]] && recovery_set_complete "$LOCAL_DIR/backups/infisical/$id"; then
      next="$id"
      break
    fi
  done
  for id in $(recovery_ids "$env"); do
    fp="$(jq -r '.secret_key_fp' "$LOCAL_DIR/backups/$env/$id/manifest.json")"
    [[ "$fp" == "$want" ]] || continue
    if [[ "$id" < "$iid" ]]; then
      before="$id"
    elif [[ -z "$next" || "$id" < "$next" ]]; then
      in_window="$id"
    elif [[ -z "$after" ]]; then
      after="$id"
    fi
  done
  if [[ -n "$in_window" ]]; then
    printf '%s' "$in_window"
  elif [[ -n "$before" ]]; then
    printf '%s' "$before"
  elif [[ -n "$after" ]]; then
    printf '%s' "$after"
  else
    return 1
  fi
}

# The newest Plane backup taken after the one given, with the SECRET_KEY the recovery set holds, or nothing. A plan
# warns about it, because restoring the older one leaves out what the newer one holds.
recovery_newer_plane() { # env id set-file
  local env="$1" chosen="$2" want id newest=""
  want="$(jq -r --arg e "$env" '.plane_secrets[$e].SECRET_KEY.fp // ""' "$3")"
  [[ -n "$want" ]] || return 0
  for id in $(recovery_ids "$env"); do
    if [[ "$id" > "$chosen" && "$(jq -r '.secret_key_fp' "$LOCAL_DIR/backups/$env/$id/manifest.json")" == "$want" ]]; then newest="$id"; fi
  done
  printf '%s' "$newest"
}

# Prints where the content the recovery set names can be found: in place, or in an archive that bootstrap
# or secret-zero.sh moved it to. Fails if it is nowhere.
recovery_locate_zero() { # name sha256
  local f
  for f in "$SECRET_ZERO_DIR/$1" "$SECRET_ZERO_DIR"/archive-*/"$1"; do
    [[ -f "$f" ]] || continue
    if [[ "$(recovery_sha256 "$f")" == "$2" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# A helper and not a case inside the "$(...)" that calls it: bash 3.2, which macOS ships, reads the ) of a case
# pattern as the end of the substitution. bash -n passes it, and it fails only when that line runs.
recovery_zero_hint() { # name
  case "$1" in
    ENCRYPTION_KEY) printf 'Without it the dump is unreadable: restore the file from your off-machine copy.' ;;
    AUTH_SECRET) printf 'Without it nothing this instance signed can be verified: restore the file from your off-machine copy. See infisical/README.md, section Recovery.' ;;
    *) printf 'See infisical/README.md, section Recovery.' ;;
  esac
}

# Prints one line per problem that would stop a clean restore, and returns 1 if there is any.
recovery_check_zero() { # set-file
  local set_file="$1" name sha problems=0
  for name in $RECOVERY_ZERO_REQUIRED; do
    sha="$(jq -r --arg n "$name" '.secret_zero.files[$n].sha256 // ""' "$set_file")"
    if [[ -z "$sha" ]]; then
      printf 'the recovery set names no %s\n' "$name"
      problems=1
    elif ! recovery_locate_zero "$name" "$sha" >/dev/null; then
      printf '%s with the content this backup needs is not in %s or any archive in it. %s\n' "$name" "$SECRET_ZERO_DIR" "$(recovery_zero_hint "$name")"
      problems=1
    fi
  done
  return "$problems"
}

# ------ How a restore logs in ---------------------------------------------------------------------------------

RECOVERY_ADMIN_MODE=""          # token: the file this backup names is here and has not ended
                                # mint: it is not, and the password this backup names is here to make another with
                                # unknown-password: it is not, and a password is here that this backup does not
                                # name, so it may not be the one the dump holds
                                # sign-in: neither, so a person has to, after Infisical is back
RECOVERY_ADMIN_WHY=""           # Why not token
RECOVERY_ADMIN_TOKEN_FILE=""    # Where the file this backup names is, in place or in an archive, if it can log in
RECOVERY_ADMIN_PASSWORD_FILE="" # The password to try: the one this backup names, or whatever is in place
RECOVERY_ADMIN_EXP=0
# shellcheck disable=SC2034 # scripts/restore.sh reads it.
RECOVERY_ADMIN_OUTCOME=""       # What recovery_admin_after_restore did, for the record

# The login route trims a password, so a trailing newline, as echo leaves, is the same password and another checksum.
recovery_password_named() { # file sha256
  [[ "$(recovery_sha256 "$1")" == "$2" ]] && return 0
  [[ "$(tr -d '\r\n' < "$1" | shasum -a 256 | cut -d' ' -f1)" == "$2" ]] && return 0
  [[ "$({ tr -d '\r\n' < "$1"; printf '\n'; } | shasum -a 256 | cut -d' ' -f1)" == "$2" ]]
}

# Decides from the files alone, so it can run before anything is touched. Not in a command substitution: it sets these.
# With no set file, as for a backup with no recovery set, the backup names nothing, so what is in place is all there
# is to go on: a token that has not ended may work, and a password may be the right one. The server has the last word.
recovery_admin_plan() { # [set-file]
  local set_file="${1:-}" sha="" where="" exp password_named=no
  RECOVERY_ADMIN_MODE=""
  RECOVERY_ADMIN_WHY=""
  RECOVERY_ADMIN_TOKEN_FILE=""
  RECOVERY_ADMIN_PASSWORD_FILE=""
  RECOVERY_ADMIN_EXP=0
  if [[ -n "$set_file" ]]; then sha="$(jq -r '.secret_zero.files["infisical-admin-password"].sha256 // ""' "$set_file")"; fi
  if [[ -n "$sha" ]]; then RECOVERY_ADMIN_PASSWORD_FILE="$(recovery_locate_zero infisical-admin-password "$sha" || true)"; fi
  if [[ -n "$RECOVERY_ADMIN_PASSWORD_FILE" ]]; then
    password_named=yes
  elif [[ -s "$ADMIN_PASSWORD_FILE" ]]; then
    RECOVERY_ADMIN_PASSWORD_FILE="$ADMIN_PASSWORD_FILE"
    if [[ -n "$sha" ]] && recovery_password_named "$ADMIN_PASSWORD_FILE" "$sha"; then password_named=yes; fi
  fi

  sha=""
  if [[ -n "$set_file" ]]; then sha="$(jq -r '.secret_zero.files["infisical-admin.json"].sha256 // ""' "$set_file")"; fi
  if [[ -n "$sha" ]]; then
    where="$(recovery_locate_zero infisical-admin.json "$sha" || true)"
  elif [[ -z "$set_file" && -s "$ADMIN_FILE" ]]; then
    where="$ADMIN_FILE"
  fi
  if [[ -n "$where" ]]; then
    exp="$(ia_file_token_exp "$where")"
    RECOVERY_ADMIN_EXP="$exp"
    if [[ "$exp" -le 0 || "$exp" -gt $(($(date +%s) + IA_TOKEN_MARGIN_SECONDS)) ]]; then
      RECOVERY_ADMIN_MODE=token
      RECOVERY_ADMIN_TOKEN_FILE="$where"
      return 0
    fi
    RECOVERY_ADMIN_WHY="the admin token ${set_file:+this backup names }ends at $(ia_date "$exp")"
  elif [[ -n "$set_file" ]]; then
    RECOVERY_ADMIN_WHY="the infisical-admin.json this backup names is not on this machine"
  else
    RECOVERY_ADMIN_WHY="this backup names no admin token, and no infisical-admin.json is on this machine"
  fi
  if [[ -z "$RECOVERY_ADMIN_PASSWORD_FILE" ]]; then
    RECOVERY_ADMIN_MODE=sign-in
  elif [[ "$password_named" == yes ]]; then
    RECOVERY_ADMIN_MODE=mint
  else
    RECOVERY_ADMIN_MODE=unknown-password
  fi
}

recovery_admin_plan_text() { # What the plan says. After recovery_admin_plan.
  case "$RECOVERY_ADMIN_MODE" in
    token) printf 'the file this backup names, ending %s' "$(ia_date "$RECOVERY_ADMIN_EXP")" ;;
    mint) printf '%s. Once the database is back, this signs in with %s, mints another and records it' "$RECOVERY_ADMIN_WHY" "${RECOVERY_ADMIN_PASSWORD_FILE#"$SECRET_ZERO_DIR"/}" ;;
    unknown-password) printf '%s, and the %s here is not the password this backup names by checksum, so it may not be the one this dump holds. Once the database is back this tries it, and if the server refuses it, this stops with sign-in steps, and resumes with the replacement' "$RECOVERY_ADMIN_WHY" "${RECOVERY_ADMIN_PASSWORD_FILE#"$SECRET_ZERO_DIR"/}" ;;
    *) printf '%s, and no password is on this machine. This restores Infisical, then stops with sign-in steps, and resumes with the replacement' "$RECOVERY_ADMIN_WHY" ;;
  esac
  if [[ -s "$ADMIN_TOKEN_DROP" ]]; then printf '. %s is there, and is tried first' "${ADMIN_TOKEN_DROP##*/}"; fi
}

# Says so when a token ends inside the time a backup is expected to stay in use. Why a restore does not depend on
# it is in recovery_admin_plan, and what is left to lose depends on the password being there.
recovery_warn_token_horizon() { # exp password-file-or-empty
  local exp="$1" password="$2" now
  now="$(date +%s)"
  [[ "$exp" -gt 0 ]] || return 0
  [[ "$exp" -le $((now + BACKUP_RETENTION_DAYS * 86400)) ]] || return 0
  if [[ -n "$password" ]]; then
    warn "the admin token ends at $(ia_date "$exp"), inside the $BACKUP_RETENTION_DAYS days a backup is expected to stay in use. A restore after that signs in with ${password##*/} and mints another, so keep that file. Before then, RENEW_ADMIN_TOKEN=yes scripts/infisical-bootstrap.sh and a new backup move the date."
  else
    warn "the admin token ends at $(ia_date "$exp"), inside the $BACKUP_RETENTION_DAYS days a backup is expected to stay in use, and no password is on this machine. A restore after that stops after Infisical for a person to sign in."
  fi
}

# Follows the record of replacements. True if the file with the second checksum descends from the file with the first.
recovery_admin_descends() { # old-sha new-sha
  local at="$1" want="$2" next hops=0
  [[ -s "$ADMIN_TOKEN_LEDGER" ]] || [[ "$at" == "$want" ]] || return 1
  while [[ "$hops" -lt 50 ]]; do
    if [[ "$at" == "$want" ]]; then return 0; fi
    next="$(jq -r --arg old "$at" 'select(.old_sha256 == $old) | .new_sha256' "$ADMIN_TOKEN_LEDGER" 2>/dev/null | tail -1)"
    [[ -n "$next" ]] || return 1
    at="$next"
    hops=$((hops + 1))
  done
  return 1
}

# Puts one file where it belongs, keeping what it replaces. For a file found only in an archive.
recovery_put_back() { # name where archive
  local name="$1" where="$2" archive="$3"
  if [[ -e "$SECRET_ZERO_DIR/$name" ]]; then
    mkdir -p "$archive"
    mv "$SECRET_ZERO_DIR/$name" "$archive/"
  fi
  cp "$where" "$SECRET_ZERO_DIR/.$name.tmp"
  chmod 600 "$SECRET_ZERO_DIR/.$name.tmp"
  mv "$SECRET_ZERO_DIR/.$name.tmp" "$SECRET_ZERO_DIR/$name"
  ok "put back $name from ${where#"$SECRET_ZERO_DIR"/}"
}

# The server now answers with the restored database, so ask it. Leaves in $ADMIN_FILE a token it accepts, trying in
# turn: the file this backup names, a token a person left, what is in place, and a password login. Returns 0 with
# what it did in RECOVERY_ADMIN_OUTCOME, or 3 if a person has to sign in. Needs ia_init. The caller prints the steps,
# because only it knows what command goes on from there.
# shellcheck disable=SC2034 # scripts/restore.sh reads RECOVERY_ADMIN_OUTCOME.
recovery_admin_after_restore() { # [set-file]
  local set_file="${1:-}" org="" named="" have why archive rc=0
  if [[ -n "$set_file" ]]; then
    org="$(jq -r '.identity.organization // ""' "$set_file")"
    named="$(jq -r '.secret_zero.files["infisical-admin.json"].sha256 // ""' "$set_file")"
  fi
  # A set that could not finish may name no organization, and a backup with no set names nothing.
  if [[ -z "$org" ]]; then org="$(jq -r '.organization.id // ""' "$ADMIN_FILE" 2>/dev/null || true)"; fi
  if [[ -z "$org" ]]; then org="$(jq -r '.organization.id // ""' "$MACHINE_FILE" 2>/dev/null || true)"; fi
  RECOVERY_ADMIN_OUTCOME=""
  recovery_admin_plan "$set_file"
  archive="$SECRET_ZERO_DIR/archive-pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "$RECOVERY_ADMIN_MODE" == token && "$RECOVERY_ADMIN_TOKEN_FILE" != "$ADMIN_FILE" ]]; then
    recovery_put_back infisical-admin.json "$RECOVERY_ADMIN_TOKEN_FILE" "$archive"
  fi
  # The dump holds this password's hash, so the file should hold this password, in place as on a clean restore.
  if [[ -n "$RECOVERY_ADMIN_PASSWORD_FILE" && "$RECOVERY_ADMIN_PASSWORD_FILE" != "$ADMIN_PASSWORD_FILE" ]]; then
    recovery_put_back infisical-admin-password "$RECOVERY_ADMIN_PASSWORD_FILE" "$archive"
    RECOVERY_ADMIN_PASSWORD_FILE="$ADMIN_PASSWORD_FILE"
  fi

  ia_adopt_dropped_token "the restored instance had no usable token, and a person made one" "$org" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    RECOVERY_ADMIN_OUTCOME="replaced with the token a person made, and recorded in ${ADMIN_TOKEN_LEDGER##*/}"
    return 0
  fi

  why="$(ia_admin_problem)"
  if [[ -z "$why" ]]; then
    jq -er '"Authorization: Bearer " + .token' "$ADMIN_FILE" > "$IA_TMP/auth"
    if ia_token_accepted "$org"; then
      have="$(recovery_sha256 "$ADMIN_FILE")"
      if [[ "$have" == "$named" ]]; then
        RECOVERY_ADMIN_OUTCOME="the file this backup names, and the server accepts it"
      elif [[ -z "$named" ]]; then
        RECOVERY_ADMIN_OUTCOME="the file in place, and the server accepts it. This backup names no token"
      else
        jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg old "$named" --arg new "$have" --argjson exp "$(ia_file_token_exp "$ADMIN_FILE")" \
          '{at: $at, method: "accepted-in-place", why: "not the file the backup names, and the restored server accepts it", old_sha256: $old, new_sha256: $new, token_exp: $exp}' >> "$ADMIN_TOKEN_LEDGER"
        chmod 600 "$ADMIN_TOKEN_LEDGER"
        RECOVERY_ADMIN_OUTCOME="a file this backup does not name, and the server accepts it. Recorded in ${ADMIN_TOKEN_LEDGER##*/}"
      fi
      return 0
    fi
    why="the restored server answers HTTP $IA_STATUS to the token in ${ADMIN_FILE##*/}"
  fi

  rc=0
  if [[ -n "$RECOVERY_ADMIN_PASSWORD_FILE" ]]; then
    ia_mint_admin_token "$why" "$org" "$RECOVERY_ADMIN_PASSWORD_FILE" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      RECOVERY_ADMIN_OUTCOME="$why, so it was replaced after a password login, and recorded in ${ADMIN_TOKEN_LEDGER##*/}"
      return 0
    fi
  fi
  warn "$why, and no password here could replace it"
  return 3
}

# Puts back any secret-zero file the recovery set names that is only in an archive. What it replaces
# goes to a new archive first, so nothing is lost. An admin token that has ended stays where it is: the
# plan already says what happens instead, and it would only put a dead token over a live one.
recovery_reinstate_zero() { # set-file
  local set_file="$1" name sha where archive
  archive="$SECRET_ZERO_DIR/archive-pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  for name in $RECOVERY_ZERO_REQUIRED $RECOVERY_ZERO_OPTIONAL; do
    sha="$(jq -r --arg n "$name" '.secret_zero.files[$n].sha256 // ""' "$set_file")"
    [[ -n "$sha" ]] || continue
    where="$(recovery_locate_zero "$name" "$sha" || true)"
    if [[ -z "$where" ]]; then
      case "$name" in
        infisical-admin.json | infisical-admin-password) ;;                    # The plan said what this means.
        infisical-machine.json) ;;                                             # recovery_rebuild_machine_file sees to it.
        *) warn "the $name this backup was taken with is not on this machine. A new one works, because the database keeps no copy" ;;
      esac
      continue
    fi
    [[ "$where" != "$SECRET_ZERO_DIR/$name" ]] || continue
    if [[ "$name" == infisical-admin.json ]]; then
      recovery_admin_plan "$set_file"
      [[ "$RECOVERY_ADMIN_MODE" == token ]] || continue
    fi
    recovery_put_back "$name" "$where" "$archive"
  done
}

# ------ Versions ----------------------------------------------------------------------------------------------

# The version in an image reference's tag, without a leading v, or nothing if the tag is not a version.
recovery_image_version() { # reference, as in docker.io/infisical/infisical:v0.167.6@sha256:...
  local tag="${1%%@*}"
  case "$tag" in
    *:*) tag="${tag##*:}" ;;
    *) return 0 ;;
  esac
  case "$tag" in
    */*) ;;
    v[0-9]* | [0-9]*) printf '%s' "${tag#v}" ;;
  esac
}

recovery_git_infisical_image() { # What Git deploys. The chart joins repository:tag, and the digest travels in the tag.
  yq -r '.infisical.image.repository + ":" + .infisical.image.tag' "$ROOT/helm/values/infisical.yaml"
}

# True if the first version is newer than the second. Unknown on either side is not a reason to refuse.
recovery_version_newer() { # version version
  [[ -n "$1" && -n "$2" && "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# ------ Terraform and test files ------------------------------------------------------------------------------

# Terraform state and database are a pair: state from any other moment plans to create or delete.
recovery_install_tf_state() { # backup-dir
  local src="$1/recovery/terraform.tfstate"
  [[ -f "$src" ]] || return 0
  mkdir -p "${RECOVERY_TF_STATE%/*}"
  chmod 700 "${RECOVERY_TF_STATE%/*}"
  if [[ -f "$RECOVERY_TF_STATE" ]]; then
    [[ "$(recovery_sha256 "$RECOVERY_TF_STATE")" != "$(recovery_sha256 "$src")" ]] || return 0
    cp "$RECOVERY_TF_STATE" "$RECOVERY_TF_STATE.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  cp "$src" "$RECOVERY_TF_STATE.tmp"
  chmod 600 "$RECOVERY_TF_STATE.tmp"
  mv "$RECOVERY_TF_STATE.tmp" "$RECOVERY_TF_STATE"
  ok "Terraform state of infisical/terraform now matches this backup"
}

# True if the machine file is there and names the ids this backup's set names.
recovery_machine_ids_match() { # backup-dir
  local have want
  [[ -s "$MACHINE_FILE" ]] || return 1
  have="$(jq -cS '{organization: .organization.id, project_ids, identity_ids}' "$MACHINE_FILE" 2>/dev/null)" || return 1
  want="$(jq -cS '.identity' "$(recovery_set_file "$1")" 2>/dev/null)" || return 1
  [[ "$have" == "$want" ]]
}

# Bootstrap rewrites the machine file from Terraform, but a restore reads it to prove the values before that, so one
# from another instance would fail those proofs on every resume and point at a dump that is fine. What this backup
# needs is in its Terraform state, so a lost or wrong one costs nothing. The one it replaces goes to an archive.
recovery_rebuild_machine_file() { # backup-dir
  local dir="$1" org archive
  if recovery_machine_ids_match "$dir"; then return 0; fi
  [[ -f "$dir/recovery/terraform.tfstate" ]] || return 0
  org="$(jq -c '.identity.organization | {id: ., name: null, slug: null}' "$(recovery_set_file "$dir")")"
  if jq --argjson org "$org" '{
      organization: $org,
      environment_slug: .outputs.environment_slug.value,
      project_ids: .outputs.project_ids.value,
      project_slugs: .outputs.project_slugs.value,
      identity_ids: .outputs.identity_ids.value
    }' "$dir/recovery/terraform.tfstate" > "$MACHINE_FILE.tmp"; then
    chmod 600 "$MACHINE_FILE.tmp"
    # Both come from one backup, and a state with other ids is no better than the file it would replace.
    if [[ "$(jq -cS '{organization: .organization.id, project_ids, identity_ids}' "$MACHINE_FILE.tmp")" != "$(jq -cS '.identity' "$(recovery_set_file "$dir")")" ]]; then
      rm -f "$MACHINE_FILE.tmp"
      warn "this backup's Terraform state does not name the ids its recovery set does, so ${MACHINE_FILE##*/} was left as it is"
      return 0
    fi
    if [[ -e "$MACHINE_FILE" ]]; then
      archive="$SECRET_ZERO_DIR/archive-pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$archive"
      mv "$MACHINE_FILE" "$archive/"
      warn "${MACHINE_FILE##*/} did not name the ids this backup does, so it moved to ${archive#"$SECRET_ZERO_DIR"/}"
    fi
    mv "$MACHINE_FILE.tmp" "$MACHINE_FILE"
    ok "rebuilt ${MACHINE_FILE##*/} from this backup's Terraform state"
  else
    rm -f "$MACHINE_FILE.tmp"
  fi
}

# The accounts and the sentinel that belong to a restored Plane dump, because a later smoke test logs in
# with them. The other environment's lines are left alone.
# A resume that keeps the data still puts the backup's test accounts and sentinel back, and the data it kept may have
# moved on from them, as after a password changed since. So what they replace is copied beside them first, as with the
# other files a resume puts back. Only if it differs, so a second resume leaves no second copy of the same thing.
recovery_keep_test_files() { # backup-dir env
  local dir="$1" env="$2" accounts="$LOCAL_DIR/test-accounts.env" sentinel="$LOCAL_DIR/test-sentinel-$2.json" prefix stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  prefix="$(env_prefix "$env")"
  if [[ -s "$dir/recovery/test-accounts.env" && -f "$accounts" ]] \
    && ! cmp -s <(grep "^$prefix" "$accounts") "$dir/recovery/test-accounts.env"; then
    (umask 077 && cp "$accounts" "$accounts.pre-restore-$stamp") || die "could not keep a copy of $accounts, so it was not replaced"
    warn "this resume keeps the data, and puts back the test accounts of $env that the backup recorded. If a password was changed since, the database holds the new one. The file it replaces is in ${accounts#"$ROOT"/}.pre-restore-$stamp"
  fi
  if [[ -s "$dir/recovery/test-sentinel.json" && -f "$sentinel" ]] && ! cmp -s "$sentinel" "$dir/recovery/test-sentinel.json"; then
    (umask 077 && cp "$sentinel" "$sentinel.pre-restore-$stamp") || die "could not keep a copy of $sentinel, so it was not replaced"
    warn "this resume keeps the data, and puts back the sentinel of $env that the backup recorded. The file it replaces is in ${sentinel#"$ROOT"/}.pre-restore-$stamp"
  fi
}

recovery_reinstate_test_files() { # backup-dir env
  local dir="$1" env="$2" accounts="$LOCAL_DIR/test-accounts.env" prefix tmp
  if [[ -s "$dir/recovery/test-accounts.env" ]]; then
    prefix="$(env_prefix "$env")"
    tmp="$(mktemp "$LOCAL_DIR/.test-accounts.XXXXXX")"
    if [[ -f "$accounts" ]]; then grep -v "^$prefix" "$accounts" > "$tmp" || true; fi
    cat "$dir/recovery/test-accounts.env" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$accounts"
  fi
  if [[ -s "$dir/recovery/test-sentinel.json" ]]; then
    cp "$dir/recovery/test-sentinel.json" "$LOCAL_DIR/.test-sentinel-$env.tmp"
    chmod 600 "$LOCAL_DIR/.test-sentinel-$env.tmp"
    mv "$LOCAL_DIR/.test-sentinel-$env.tmp" "$LOCAL_DIR/test-sentinel-$env.json"
  fi
}

# Every Plane secret read back through the API, against the set: same value, version and id, so nothing
# was generated or rewritten. Prints one line per mismatch, naming keys only. Needs ia_init and ia_load_admin.
recovery_compare_values() { # set-file
  local set_file="$1" env table diff problems=0
  for env in dev prod-sim; do
    if ! table="$(recovery_secret_table "$env")"; then
      printf '%s: could not read the secrets back\n' "$env"
      problems=1
      continue
    fi
    diff="$(jq -nr --argjson have "$table" --argjson want "$(jq -c --arg e "$env" '.plane_secrets[$e]' "$set_file")" --arg env "$env" '
      (($have | keys) + ($want | keys) | unique)[] as $k
      | if $have[$k] == null then "\($env) \($k): missing from the restored instance"
        elif $want[$k] == null then "\($env) \($k): exists but is not in the recovery set"
        elif $have[$k].fp != $want[$k].fp then "\($env) \($k): value differs"
        elif $have[$k].version != $want[$k].version or $have[$k].id != $want[$k].id then "\($env) \($k): rewritten, same value"
        else empty end')"
    if [[ -n "$diff" ]]; then
      printf '%s\n' "$diff"
      problems=1
    fi
  done
  return "$problems"
}

# What the operators rendered in one namespace, against the set. Prints mismatches, keys only.
recovery_compare_rendered() { # set-file env
  local set_file="$1" env="$2" ns="plane-$2" secret key source want have problems=0
  while read -r secret key source; do
    [[ -n "$secret" ]] || continue
    want="$(jq -r --arg e "$env" --arg k "$source" '.plane_secrets[$e][$k].fp // ""' "$set_file")"
    have="$(kc -n "$ns" get secret "$secret" -o json 2>/dev/null | jq -je --arg k "$key" '.data[$k] | @base64d' 2>/dev/null | recovery_fp || true)"
    if [[ "$have" != "$want" ]]; then
      printf '%s/%s %s does not hold %s\n' "$ns" "$secret" "$key" "$source"
      problems=1
    fi
  done <<<"$RECOVERY_RENDERED"
  return "$problems"
}
