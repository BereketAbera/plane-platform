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

# Needed to log in to, or to trust, the restored instance. Nothing else can stand in for them.
RECOVERY_ZERO_REQUIRED="ENCRYPTION_KEY AUTH_SECRET infisical-admin.json"
# The database keeps no copy of these, so a new one works: Postgres and Redis start empty and take
# whatever the Secret says, the UI password is only a way in if the token is lost, and bootstrap
# rewrites the machine file.
RECOVERY_ZERO_OPTIONAL="DB_PASSWORD REDIS_PASSWORD infisical-admin-password infisical-machine.json"
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
  local dir="$1" rec="$1/recovery" zero='{}' name state_json=null identity=null secrets=null env table complete=true
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
  if [[ -s "$ADMIN_FILE" && -s "$MACHINE_FILE" ]]; then
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
    warn "no admin or machine file in $SECRET_ZERO_DIR, so this backup cannot serve a clean restore"
    complete=false
  fi

  jq -n --arg backup "${dir##*/}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson complete "$complete" \
    --argjson zero "$zero" --argjson state "$state_json" --argjson identity "$identity" --argjson secrets "$secrets" '{
      schema: 1,
      backup: $backup,
      created_at: $at,
      complete: $complete,
      secret_zero: {location: ".local/secret-zero", files: $zero},
      terraform_state: $state,
      identity: $identity,
      plane_secrets: $secrets
    }' > "$rec/set.json"
  chmod 600 "$rec/set.json"
  recovery_seal "$dir"
  # Asks the file rather than the flag: errexit is off in a function called from `||`.
  jq -e '.complete and .terraform_state != null and .identity != null
    and (.plane_secrets | has("dev") and has("prod-sim"))' "$rec/set.json" >/dev/null
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
# the newest taken after this Infisical backup and before the next one, which is what `backup all`
# produces; else the newest before it; else the oldest later one. Prints the id, or fails.
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
    if [[ "$id" > "$iid" ]]; then next="$id"; break; fi
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

# Prints one line per problem that would stop a clean restore, and returns 1 if there is any.
recovery_check_zero() { # set-file
  local set_file="$1" name sha problems=0 where token exp
  for name in $RECOVERY_ZERO_REQUIRED; do
    sha="$(jq -r --arg n "$name" '.secret_zero.files[$n].sha256 // ""' "$set_file")"
    if [[ -z "$sha" ]]; then
      printf 'the recovery set names no %s\n' "$name"
      problems=1
    elif ! recovery_locate_zero "$name" "$sha" >/dev/null; then
      printf '%s with the content this backup needs is not in %s or any archive in it. %s\n' "$name" "$SECRET_ZERO_DIR" \
        "$(case "$name" in
          ENCRYPTION_KEY) printf 'Without it the dump is unreadable: restore the file from your off-machine copy.' ;;
          AUTH_SECRET) printf 'Without it the admin token in the database cannot be verified. See infisical/README.md, section Recovery.' ;;
          *) printf 'See infisical/README.md, section Recovery.' ;;
        esac)"
      problems=1
    fi
  done
  sha="$(jq -r '.secret_zero.files["infisical-admin.json"].sha256 // ""' "$set_file")"
  if [[ -n "$sha" ]] && where="$(recovery_locate_zero infisical-admin.json "$sha")"; then
    token="$(jq -er '.token' "$where" 2>/dev/null || true)"
    exp="$(printf '%s' "$token" | ia_token_exp)"
    if [[ "$exp" -gt 0 && "$exp" -le "$(date +%s)" ]]; then
      printf 'the admin token recorded with this backup has expired, so nothing could log in after the restore. See infisical/README.md, section Recovery.\n'
      problems=1
    fi
  fi
  return "$problems"
}

# Puts back any secret-zero file the recovery set names that is only in an archive. What it replaces
# goes to a new archive first, so nothing is lost.
recovery_reinstate_zero() { # set-file
  local set_file="$1" name sha where archive=""
  for name in $RECOVERY_ZERO_REQUIRED $RECOVERY_ZERO_OPTIONAL; do
    sha="$(jq -r --arg n "$name" '.secret_zero.files[$n].sha256 // ""' "$set_file")"
    [[ -n "$sha" ]] || continue
    where="$(recovery_locate_zero "$name" "$sha" || true)"
    if [[ -z "$where" ]]; then
      warn "the $name this backup was taken with is not on this machine. A new one works, because the database keeps no copy"
      continue
    fi
    [[ "$where" != "$SECRET_ZERO_DIR/$name" ]] || continue
    if [[ -e "$SECRET_ZERO_DIR/$name" ]]; then
      [[ -n "$archive" ]] || archive="$SECRET_ZERO_DIR/archive-pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$archive"
      mv "$SECRET_ZERO_DIR/$name" "$archive/"
    fi
    cp "$where" "$SECRET_ZERO_DIR/.$name.tmp"
    chmod 600 "$SECRET_ZERO_DIR/.$name.tmp"
    mv "$SECRET_ZERO_DIR/.$name.tmp" "$SECRET_ZERO_DIR/$name"
    ok "put back $name from ${where#"$SECRET_ZERO_DIR"/}"
  done
}

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

# The accounts and the sentinel that belong to a restored Plane dump, because a later smoke test logs in
# with them. The other environment's lines are left alone.
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
