#!/usr/bin/env bash
# Restore a backup taken by scripts/backup.sh into the environment it came from, or bring the whole
# platform back into a clean environment.
#
#   scripts/restore.sh dev <backup-id|latest>
#   ENV=dev BACKUP=<backup-id|latest> CONFIRM=yes scripts/restore.sh
#   scripts/restore.sh clean <infisical-backup-id|latest>     or: make restore-clean BACKUP=latest
#
# CONFIRM=yes                    needed to overwrite an environment that already holds data
# ALLOW_SECRET_KEY_MISMATCH=yes  proceed although the live key differs from the backup's. Encrypted
#                                rows then decrypt silently to "", so the proofs fail and the script
#                                exits non-zero even though the data is back.
# ALLOW_STALE_PLANE_SECRETS=yes  restore Infisical in place from a dump older than the last rotation.
#                                The operators then render a password Plane's Postgres no longer takes.
# ALLOW_NEWER_INFISICAL_BACKUP=yes  restore a dump from a newer Infisical than the one that will run on it.
#                                Its migrations go forward only, so that server refuses to start until a
#                                newer image is deployed.
# ALLOW_NO_ADMIN_TOKEN=yes       restore Infisical in place with nothing here that can log in afterwards, as
#                                when its Postgres is lost. It stops after the restore with sign-in steps.
# ALLOW_NO_SENTINEL=yes          accept that a sentinel proof could not run, as with a backup taken before a
#                                sentinel existed. The step still reads NOT RUN, and the result lists it.
#
# Exit status: 0 everything proven. 1 something failed. 2 nothing failed, but something could not run or a
# person has to act, so this is not a pass, as in scripts/test.sh. A proof step recorded as NOT RUN is
# not a pass, except proof-probes, which says something about monitoring and not about the data.
# restore.sh infisical alone also has 3: Infisical is back, and a person has to sign in to prove it.
#
# Every refusal comes before anything is touched. Order for a Plane environment:
#   verify checksums and fingerprint, refuse, pause auto-sync (root first), stop the apps, restore
#   Postgres and check its counts, sync objects, flush Valkey, purge RabbitMQ, run the migrator,
#   start the apps, prove. Auto-sync comes back at the end, including on failure.
# Order for Infisical:
#   verify checksums and fingerprint, refuse, pause auto-sync on infisical only, stop the server, restore
#   into a second database and check its counts, swap it in, flush Redis, start the server, make sure
#   something here can log in, prove.
#
# Clean restore, for when the cluster and everything in it are gone. Infisical comes first, because it
# is the source of truth for every Plane secret:
#   1. Check the recovery set: every checksum, the keys it names, that each Plane backup was taken with
#      the SECRET_KEY this Infisical backup holds. Check what scripts/up.sh would stop on: uncommitted
#      changes, digests the local registry cannot serve, free disk. Refuse if the environment is not clean.
#   2. make up as far as Traefik: cluster, Terraform, secret zero. Plane cannot start, because it has
#      no identity Secret yet, so nothing can read or render a value.
#   3. Wait for the fresh Infisical server to finish its migrations, then replace its database, as above.
#      An admin token that has expired, or a file that is lost, is replaced here, once the database is back:
#      see "How a restore logs in" in infisical/lib/recovery.sh.
#   4. make up from there, with bootstrap in restored mode: same credentials, new cluster CA through
#      Terraform, identity Secrets published, no value written. The operators render the old values and
#      Plane's data services initialize with them. It waits for all Applications.
#   5. Restore each Plane environment's database and objects, as above, then check it all again.
# It can resume: run it again after any failure, including a hard stop that ran no trap. With the marker still
# there, a new run first puts back any auto-sync left paused and any Deployment left at zero. Options:
#   PLAN_ONLY=yes                  do step 1 and print the plan. Changes nothing, and works on a live cluster
#   ENVS="dev"                     restore only these Plane environments. Default: dev prod-sim
#   BACKUP_DEV=<id> BACKUP_PROD_SIM=<id>  instead of the Plane backup step 1 would pick
#   ALLOW_LOW_DISK="<reason>"      go past the disk check for a new cluster here and in scripts/up.sh. Logged
#
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/up-checks.sh
source "$ROOT/scripts/lib/up-checks.sh"
# shellcheck source=../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"
# shellcheck source=../infisical/lib/recovery.sh
source "$ROOT/infisical/lib/recovery.sh"

accept_assignments "ENV BACKUP CONFIRM ALLOW_SECRET_KEY_MISMATCH ALLOW_STALE_PLANE_SECRETS ALLOW_NEWER_INFISICAL_BACKUP ALLOW_NO_ADMIN_TOKEN ALLOW_NO_SENTINEL ALLOW_LOW_DISK RESTORE_MODE PLAN_ONLY ENVS BACKUP_DEV BACKUP_PROD_SIM" "$@"
positional=()
for arg in "$@"; do case "$arg" in *=*) ;; *) positional+=("$arg") ;; esac; done
if [[ ${#positional[@]} -ge 1 && -n "${positional[0]}" ]]; then ENV="${positional[0]}"; fi
if [[ ${#positional[@]} -ge 2 && -n "${positional[1]}" ]]; then BACKUP="${positional[1]}"; fi
[[ -n "${ENV:-}" && -n "${BACKUP:-}" ]] || die "usage: $0 dev|prod-sim|infisical|clean <backup-id|latest> [CONFIRM=yes]"
# clean: this run is step 3 of a clean restore, which needs the recovery set and has no live Plane to guard.
RESTORE_MODE="${RESTORE_MODE:-in-place}"

# What restore.sh infisical exits with when Infisical is back and a person has to sign in. Its parent, a clean
# restore, marks that step done and stops, and resumes with the replacement token.
EXIT_NEEDS_SIGN_IN=3
# The Deployments a Plane restore stops and starts.
APP_DEPLOYMENTS="plane-api-wl plane-worker-wl plane-beat-worker-wl plane-live-wl"

# ----- Clean restore ----------------------------------------------------------------------------

CLEAN_IID=""
CLEAN_ENVS=""
CLEAN_STEPS=""
CLEAN_PROBLEMS=""
CLEAN_IMAGES_NOTE=""
# Set before an exit 2 that means a person has to act, and not that a proof could not run.
CLEAN_RESULT_IF_2="NOT RUN"

clean_record() { # step status detail. Same shape as a single restore's evidence.
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$CLEAN_STEPS"
  case "$2" in
    PASS) ok "$1: ${3:-}" ;;
    FAIL) warn "$1 FAILED: ${3:-}" ;;
    *) warn "$1 $2: ${3:-}" ;;
  esac
}

clean_on_exit() {
  local rc=$? result
  trap - EXIT
  if [[ -n "$CLEAN_STEPS" && -f "$CLEAN_STEPS" ]]; then
    case "$rc" in
      0) result=PASS ;;
      2) result="$CLEAN_RESULT_IF_2" ;;
      *) result=FAIL ;;
    esac
    jq -Rn --arg backup "$CLEAN_IID" --arg at "$CLEAN_STAMP" --arg result "$result" '
      { kind: "clean-restore", infisical_backup: $backup, started_at: $at, result: $result,
        steps: [inputs | split("\t") | {step: .[0], status: .[1], detail: .[2]}] }
      | .not_run = [.steps[] | select(.status == "NOT RUN") | .step]' \
      < "$CLEAN_STEPS" > "$CLEAN_EVIDENCE" || true
    rm -f "$CLEAN_STEPS"
    case "$rc" in
      0) ok "clean restore from Infisical backup $CLEAN_IID complete. Evidence: $CLEAN_EVIDENCE" ;;
      2) warn "clean restore from Infisical backup $CLEAN_IID is not finished: $result, as said above. It stays marked as under way, and running the same command again resumes. Evidence: $CLEAN_EVIDENCE" ;;
      *) warn "clean restore from Infisical backup $CLEAN_IID stopped. Fix the cause and run the same command: it resumes. Evidence: $CLEAN_EVIDENCE" ;;
    esac
  fi
  ia_cleanup
  exit "$rc"
}

clean_done() { grep -qx "done $1" "$RESTORE_CLEAN_MARKER"; }
clean_mark() { printf 'done %s\n' "$1" >> "$RESTORE_CLEAN_MARKER"; }
clean_marker_value() { sed -n "s/^$1=//p" "$RESTORE_CLEAN_MARKER"; }

# Prints why this environment is not clean, and nothing if it is. Real data must never be overwritten
# by a command meant for a cluster that is gone.
clean_environment_problem() {
  local pvcs config
  cluster_exists || return 0
  if ! kc get --raw /readyz >/dev/null 2>&1; then
    printf 'cluster %s exists but does not answer, so what it holds cannot be told' "$CLUSTER_NAME"
    return 0
  fi
  pvcs="$({ kc -n plane-dev get pvc -o name; kc -n plane-prod-sim get pvc -o name; } 2>/dev/null | grep -v '/backups$' || true)"
  if [[ -n "$pvcs" ]]; then
    printf 'cluster %s already holds Plane volumes' "$CLUSTER_NAME"
    return 0
  fi
  config="$(curl -fsS --max-time 5 "$INFISICAL_URL/api/v1/admin/config" 2>/dev/null || true)"
  if [[ -n "$config" && "$(jq -r '.config.initialized | tostring' <<<"$config" 2>/dev/null)" == true ]]; then
    printf 'cluster %s already runs an initialized Infisical' "$CLUSTER_NAME"
  elif [[ -z "$config" ]] && kc -n infisical get pvc data-infisical-postgres-0 >/dev/null 2>&1; then
    printf 'cluster %s has an Infisical database, and Infisical does not answer, so what it holds cannot be told' "$CLUSTER_NAME"
  fi
}

clean_plane_var() { printf 'clean_plane_%s' "$(printf '%s' "$1" | tr '-' '_')"; }

clean_add_problem() { CLEAN_PROBLEMS+="$1"$'\n'; }

# The digests Git deploys that the local registry cannot serve, by the same check as scripts/up.sh. They are in no
# backup, so this is the one thing a clean restore needs that its recovery set cannot bring: see "What a clean
# restore cannot bring back" in infisical/README.md. A registry that is merely not running yet is up.sh's to start.
clean_check_images() {
  local missing env envs="" owner way1 way2
  [[ -n "$(up_referenced_local_images)" ]] || return 0
  if ! curl -fsS -o /dev/null --max-time 3 http://localhost:5001/v2/ 2>/dev/null; then
    if docker volume inspect plane-platform-local_registry-data >/dev/null 2>&1; then
      CLEAN_IMAGES_NOTE="the local registry is not running, and its volume is there. scripts/up.sh starts it and checks the digests then"
      return 0
    fi
    missing="$(up_referenced_local_images | sed 's/^/    /')"
  else
    missing="$(up_missing_local_images)"
  fi
  [[ -n "$missing" ]] || return 0
  for env in dev prod-sim; do
    if grep -F 'localhost:5001/' "$ROOT/gitops/environments/$env/manifests.yaml" >/dev/null; then envs="$envs $env"; fi
  done
  owner="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#' | tr '[:upper:]' '[:lower:]' || true)"
  way1=""
  way2="    make images"$'\n'
  for env in $envs; do
    way1+="    scripts/ci/copy-to-local-registry.sh ghcr.io/${owner:-<owner>}/wayline $env"$'\n'
    if [[ "$env" == dev ]]; then way2+="    make promote ENV=dev"$'\n'; else way2+="    make promote ENV=$env CONFIRM=yes SKIP_BACKUP=yes"$'\n'; fi
  done
  clean_add_problem "the local registry cannot serve these images, which Git deploys, and no backup holds them:
$missing
Two ways out, and neither touches the data. Both need the registry running, and make up UP_STOP_AFTER=cluster starts it and publishes nothing.
  If GHCR has these digests, which keeps them exact, after docker login ghcr.io:
$way1  Otherwise rebuild and promote, which commits new digests, because a rebuild does not reproduce a digest:
$way2  Then run this again."
}

# The checks of step 1, all of them, so one run names every problem. Sets CLEAN_IID and CLEAN_ENVS,
# each Plane backup's id in the variable clean_plane_<env>, and what stops it in CLEAN_PROBLEMS.
clean_resolve() {
  local env explicit id var line dir set_file fingerprints git_version backup_version newest dirty git_image disk
  local requested="$1"
  if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then
    CLEAN_IID="$(clean_marker_value infisical)"
    CLEAN_ENVS="$(clean_marker_value envs)"
    if [[ "$requested" != latest && "$requested" != "$CLEAN_IID" ]]; then
      die "a clean restore of Infisical backup $CLEAN_IID is under way ($RESTORE_CLEAN_MARKER). Finish it with BACKUP=$CLEAN_IID. To start over with another backup, run make destroy CONFIRM=yes SKIP_BACKUP=yes first."
    fi
    log "Resuming the clean restore of Infisical backup $CLEAN_IID"
  else
    CLEAN_ENVS="${ENVS:-dev prod-sim}"
    if [[ "$requested" == latest ]]; then
      CLEAN_IID="$(recovery_latest_infisical)" \
        || die "no Infisical backup with a complete recovery set in $LOCAL_DIR/backups/infisical. Infisical is the source of truth for every Plane secret, so Plane data cannot be restored without it. Nothing was changed."
    else
      CLEAN_IID="$(basename "$requested")"
      recovery_set_complete "$LOCAL_DIR/backups/infisical/$CLEAN_IID" \
        || die "Infisical backup $CLEAN_IID cannot serve a clean restore: $(recovery_why_incomplete "$LOCAL_DIR/backups/infisical/$CLEAN_IID"). Nothing was changed."
    fi
  fi
  dir="$LOCAL_DIR/backups/infisical/$CLEAN_IID"
  set_file="$(recovery_set_file "$dir")"
  recovery_set_complete "$dir" || die "Infisical backup $CLEAN_IID no longer checks out: $(recovery_why_incomplete "$dir")"

  if ! line="$(recovery_check_zero "$set_file")"; then clean_add_problem "$line"; fi

  # An older image refuses a newer schema, so a newer dump would leave the new server down, past the delete.
  backup_version="$(recovery_image_version "$(jq -r '.server_image // ""' "$dir/manifest.json")")"
  git_image="$(recovery_git_infisical_image)"
  git_version="$(recovery_image_version "$git_image")"
  if recovery_version_newer "$backup_version" "$git_version"; then
    if [[ "${ALLOW_NEWER_INFISICAL_BACKUP:-}" == yes ]]; then
      warn "Infisical backup $CLEAN_IID is from v$backup_version, and Git deploys v$git_version. Going on, because ALLOW_NEWER_INFISICAL_BACKUP=yes. The server will refuse to start on it until Git deploys that version."
    else
      clean_add_problem "Infisical backup $CLEAN_IID is from v$backup_version, and Git deploys v$git_version. Its migrations go forward only, so that server would refuse to start on it. Deploy v$backup_version or newer first, or pass ALLOW_NEWER_INFISICAL_BACKUP=yes."
    fi
  fi

  for env in $CLEAN_ENVS; do
    case "$env" in dev | prod-sim) ;; *) die "ENVS names '$env': expected dev, prod-sim or both" ;; esac
    var="$(clean_plane_var "$env")"
    if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then
      id="$(clean_marker_value "$env")"
    else
      if [[ "$env" == dev ]]; then explicit="${BACKUP_DEV:-}"; else explicit="${BACKUP_PROD_SIM:-}"; fi
      if ! id="$(recovery_pick_plane "$env" "$CLEAN_IID" "$explicit")"; then
        fingerprints="$(for i in $(recovery_ids "$env"); do printf '%s=%s ' "$i" "$(jq -r .secret_key_fp "$LOCAL_DIR/backups/$env/$i/manifest.json")"; done)"
        clean_add_problem "no backup of $env matches Infisical backup $CLEAN_IID, which holds SECRET_KEY $(jq -r --arg e "$env" '.plane_secrets[$e].SECRET_KEY.fp // "unknown"' "$set_file"). ${fingerprints:+Backups of $env: $fingerprints}${explicit:+You asked for $explicit. }Encrypted rows would decrypt silently to nothing. Choose another Infisical backup with BACKUP=<id>, or leave $env out with ENVS=..."
        printf -v "$var" '%s' ""
        continue
      fi
    fi
    printf -v "$var" '%s' "$id"
    if ! (cd "$LOCAL_DIR/backups/$env/$id" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
      clean_add_problem "backup $env/$id does not match its SHA256SUMS"
    fi
    # Django cannot migrate backwards, so the check restore.sh makes later can already be made from Git.
    backup_version="$(jq -r .plane_version "$LOCAL_DIR/backups/$env/$id/manifest.json")"
    git_version="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "plane-api-wl") | .spec.template.metadata.labels["app.kubernetes.io/version"]' "$ROOT/gitops/environments/$env/manifests.yaml" \
      | awk 'NF && !found { found = $0 } END { print found }')"
    newest="$(printf '%s\n%s\n' "${backup_version#v}" "${git_version#v}" | sort -V | tail -1)"
    if [[ "$newest" != "${git_version#v}" ]]; then
      clean_add_problem "backup $env/$id is from Plane $backup_version, and Git deploys $git_version. Migrations do not run backwards."
    fi
  done

  # What scripts/up.sh would stop on, asked here so the answer comes before a delete.
  dirty="$(up_uncommitted)"
  if [[ -n "$dirty" ]]; then
    clean_add_problem "uncommitted changes under paths Argo CD reads, and scripts/up.sh refuses to run with them. Commit or stash them, and keep those paths still until this finishes:
$(printf '%s\n' "$dirty" | sed 's/^/    /')"
  fi
  clean_check_images
  # This asks only about a cluster yet to be created. A resume, or an empty cluster that stays, creates nothing.
  if ! cluster_exists || { [[ ! -f "$RESTORE_CLEAN_MARKER" ]] && [[ -n "$(clean_environment_problem)" ]]; }; then
    disk="$(up_disk_problem)"
    if [[ -n "$disk" ]]; then
      if [[ -n "${ALLOW_LOW_DISK:-}" && "${PLAN_ONLY:-}" == yes ]]; then
        warn "$disk. ALLOW_LOW_DISK says to go on anyway: $ALLOW_LOW_DISK"
      elif [[ -n "${ALLOW_LOW_DISK:-}" ]]; then
        low_disk_log restore.sh "$disk"
      else
        clean_add_problem "$disk. Free space, or say why to go on with ALLOW_LOW_DISK=\"<reason>\", which is logged. See scripts/lib/up-checks.sh for what those numbers are based on."
      fi
    fi
  fi
}

clean_count() { # backup-dir table. Rows in that table of that dump, ? if it does not say.
  awk -F '\t' -v t="$2" '$1 == t { print $2; found = 1 } END { if (!found) print "?" }' "$1/postgres/rowcounts.tsv"
}

# What a Plane backup holds is the only way to see, before anything happens, that it is not the one meant. A
# make destroy after a mistaken make up backs up an empty platform, and that set is then the newest.
clean_warn_plane_content() { # env id
  local env="$1" id="$2" dir="$LOCAL_DIR/backups/$1/$2" users workspaces slug other name="" option
  users="$(clean_count "$dir" users)"
  workspaces="$(clean_count "$dir" workspaces)"
  slug="$(jq -r '.sentinel.slug // ""' "$dir/manifest.json")"
  if [[ "$users" == 0 ]]; then
    for other in $(recovery_ids "$env"); do
      if [[ "$other" != "$id" && "$(clean_count "$LOCAL_DIR/backups/$env/$other" users)" != 0 ]]; then name="$other"; fi
    done
    if [[ "$env" == dev ]]; then option=BACKUP_DEV; else option=BACKUP_PROD_SIM; fi
    warn "backup $env/$id holds 0 users, so it looks like a backup of an empty platform.${name:+ $env/$name holds $(clean_count "$LOCAL_DIR/backups/$env/$name" users) users: with an Infisical backup that matches it, $option=$name picks it, and BACKUP=<id> picks that Infisical backup.}"
  fi
  if [[ -n "$slug" && "$workspaces" == 0 ]]; then
    warn "backup $env/$id records sentinel workspace $slug, and its dump counts 0 workspaces. The sentinel file says what was on this machine, not what is in the dump, so the sentinel proof will fail."
  elif [[ -z "$slug" && "${ALLOW_NO_SENTINEL:-}" != yes ]]; then
    warn "backup $env/$id records no sentinel, so its proof cannot run and this exits 2 at the end, unless ALLOW_NO_SENTINEL=yes accepts that."
  fi
}

clean_print_plan() {
  local env var set_file dir id
  dir="$LOCAL_DIR/backups/infisical/$CLEAN_IID"
  set_file="$(recovery_set_file "$dir")"
  log "Clean restore plan"
  printf '    Infisical  %s, Terraform state serial %s with %s resources, identities %s, %s users, %s projects, %s secrets, server %s\n' "$CLEAN_IID" \
    "$(jq -r '.terraform_state.serial' "$set_file")" "$(jq -r '.terraform_state.resources' "$set_file")" \
    "$(jq -r '.identity.identity_ids | [to_entries[] | .key] | join(" and ")' "$set_file")" \
    "$(clean_count "$dir" users)" "$(clean_count "$dir" projects)" "$(clean_count "$dir" secrets_v2)" \
    "v$(recovery_image_version "$(jq -r '.server_image // ""' "$dir/manifest.json")")"
  for env in $CLEAN_ENVS; do
    var="$(clean_plane_var "$env")"
    id="${!var:-}"
    if [[ -z "$id" ]]; then
      printf '    %-10s no backup matches\n' "$env"
      continue
    fi
    printf '    %-10s %s, SECRET_KEY %s, %s users, %s workspaces, %s projects, %s work items, %s file rows, %s objects, sentinel %s\n' "$env" "$id" \
      "$(jq -r .secret_key_fp "$LOCAL_DIR/backups/$env/$id/manifest.json")" \
      "$(clean_count "$LOCAL_DIR/backups/$env/$id" users)" "$(clean_count "$LOCAL_DIR/backups/$env/$id" workspaces)" \
      "$(clean_count "$LOCAL_DIR/backups/$env/$id" projects)" "$(clean_count "$LOCAL_DIR/backups/$env/$id" issues)" \
      "$(clean_count "$LOCAL_DIR/backups/$env/$id" file_assets)" \
      "$(jq -r .objects.count "$LOCAL_DIR/backups/$env/$id/manifest.json")" \
      "$(jq -r '.sentinel.slug // "none"' "$LOCAL_DIR/backups/$env/$id/manifest.json")"
    clean_warn_plane_content "$env" "$id"
  done
  recovery_admin_plan "$set_file"
  if [[ "$RECOVERY_ADMIN_MODE" == token ]]; then
    printf '    %-10s %s\n' "admin" "$(recovery_admin_plan_text)"
    recovery_warn_token_horizon "$RECOVERY_ADMIN_EXP" "$RECOVERY_ADMIN_PASSWORD_FILE"
  else
    warn "$(recovery_admin_plan_text)"
  fi
  if [[ -n "$CLEAN_IMAGES_NOTE" ]]; then
    printf '    %-10s %s\n' "images" "$CLEAN_IMAGES_NOTE"
  else
    printf '    %-10s %s localhost:5001 digests in Git\n' "images" "$(up_referenced_local_images | wc -l | tr -d ' ')"
  fi
  printf '    %-10s %s\n' "disk" "$(up_disk_report)"
  if ! cluster_exists && [[ -e "$LOCAL_DIR/terraform/local/terraform.tfstate" ]]; then
    printf '    %-10s no cluster exists, so .local/terraform/local describes one that is gone, and a real run moves it aside\n' "terraform"
  fi
}

clean_refuse_problems() {
  local line
  [[ -n "$CLEAN_PROBLEMS" ]] || return 0
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then warn "$line"; fi
  done <<<"$CLEAN_PROBLEMS"
  die "this clean restore cannot work, for the reasons above. Nothing was changed."
}

clean_wait_infisical() {
  local started=$SECONDS timeout="${UP_WAIT_INFISICAL_SECONDS:-2400}" reported=$SECONDS state
  log "Waiting for the Infisical server: on a fresh one, its migrations run before it answers (up to ${timeout}s)"
  while :; do
    state="$(kc -n argocd get application infisical -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
    if [[ "$state" == Synced/Healthy ]] && curl -fsS -o /dev/null --max-time 5 "$INFISICAL_URL/api/status" 2>/dev/null; then break; fi
    [[ $((SECONDS - started)) -lt $timeout ]] || die "timed out after ${timeout}s waiting for Infisical. Check: kubectl -n argocd describe application infisical; kubectl -n infisical get pods"
    if [[ $((SECONDS - reported)) -ge 60 ]]; then
      reported=$SECONDS
      printf '    %ss. Application infisical: %s\n' "$((SECONDS - started))" "${state:-not there yet}"
    fi
    sleep 5
  done
  ok "Infisical answers, after $((SECONDS - started))s"
}

# A run stopped by SIGKILL or a power cut ran no trap, and then both of these are possible. Another run, or the
# child of one that was killed alone, would be undone by the repair below, so refuse first.
clean_refuse_another_run() {
  local pid="" ppid cmd processes others=""
  if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then pid="$(clean_marker_value pid)"; fi
  if [[ -n "$pid" && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then
    case "$(ps -o command= -p "$pid" 2>/dev/null || true)" in
      *restore.sh*) die "another clean restore is running here, as pid $pid. Wait for it, or stop it, and run this again." ;;
    esac
  fi
  processes="$(ps -ax -o pid=,ppid=,command= 2>/dev/null || true)"
  while read -r pid ppid cmd; do
    [[ "$pid" != "$$" && "$ppid" != "$$" && "$pid" != "$PPID" ]] || continue
    case "$cmd" in
      *"$ROOT/scripts/restore.sh"*) others="$others $pid" ;;
    esac
  done <<<"$processes"
  [[ -z "$others" ]] || die "a restore from an earlier run is still going here, as pid$others. Wait for it, or stop it, and run this again."
}

clean_claim_marker() { # So the next run can tell whether this one is still alive.
  sed '/^pid=/d' "$RESTORE_CLEAN_MARKER" > "$RESTORE_CLEAN_MARKER.tmp"
  printf 'pid=%s\n' "$$" >> "$RESTORE_CLEAN_MARKER.tmp"
  mv "$RESTORE_CLEAN_MARKER.tmp" "$RESTORE_CLEAN_MARKER"
}

clean_scale_to_git() { # namespace deployment replicas
  local have
  have="$(kc -n "$1" get deployment "$2" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [[ -n "$have" && "$have" != "$3" ]] || return 0
  kc -n "$1" scale "deployment/$2" --replicas="$3" >/dev/null
  clean_record "repair-$2" PASS "$1/$2 was at $have replicas after a hard stop, and Git says $3"
}

# What a hard stop can leave, with the marker still there: a restore Job with no client, auto-sync paused, and
# Infisical or Plane at zero. A clean-path wait would then run out on a state only this can change. Runs before
# anything waits. A Job is removed and not awaited, since nothing it finished counts until the marker says so,
# and the step starts over.
clean_repair_after_hard_stop() {
  local ns job name env deployment replicas leftover
  cluster_exists || return 0
  # After a power cut the node may be stopped, and what it left behind waits for it.
  if ! kc get --raw /readyz >/dev/null 2>&1; then
    log "cluster $CLUSTER_NAME does not answer, so starting it first"
    "$ROOT/scripts/cluster-up.sh"
  fi
  for ns in infisical plane-dev plane-prod-sim; do
    for job in $(kc -n "$ns" get jobs -l app.kubernetes.io/name=plane-restore -o json 2>/dev/null | jq -r '.items[] | select((.status.active // 0) > 0) | .metadata.name' 2>/dev/null || true); do
      kc -n "$ns" delete job "$job" --cascade=foreground --timeout=180s >/dev/null || die "could not remove $ns/$job, left running by an earlier run"
      clean_record "repair-$job" PASS "$ns/$job was left running by an earlier run. Removed, and its step starts over"
    done
  done
  for name in $(argo_unpause_all); do
    clean_record "repair-auto-sync-$name" PASS "auto-sync on $name was left paused by an earlier run"
  done
  if kc -n infisical get deployment infisical >/dev/null 2>&1; then
    clean_scale_to_git infisical infisical "$(yq -r '.infisical.replicaCount // 1' "$ROOT/helm/values/infisical.yaml")"
  fi
  for env in dev prod-sim; do
    for deployment in $APP_DEPLOYMENTS; do
      # shellcheck disable=SC2016 # strenv reads the variable, in yq.
      replicas="$(D="$deployment" yq -N 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.replicas // 1' "$ROOT/gitops/environments/$env/manifests.yaml")"
      clean_scale_to_git "plane-$env" "$deployment" "$replicas"
    done
  done
  # Anything a killed run held open. Some hold credentials, and nothing is reading them now.
  for leftover in "$LOCAL_DIR"/.restore-accounts.* "$LOCAL_DIR"/.restore-sentinel.* "$LOCAL_DIR"/.restore-steps.* "$LOCAL_DIR"/.restore-clean-steps.*; do
    if [[ -e "$leftover" && "$leftover" != "$CLEAN_STEPS" ]]; then rm -f "$leftover"; fi
  done
  find "$SECRET_ZERO_DIR" -maxdepth 1 -type d -name '.tmp.*' -mmin +10 -exec rm -rf {} + 2>/dev/null || true
}

# Infisical's database is back. Something here has to be able to log in before anything else reads a value.
clean_admin_step() { # set-file
  local rc=0
  ia_init
  recovery_admin_after_restore "$1" || rc=$?
  ia_cleanup
  case "$rc" in
    0) clean_record admin-token PASS "$RECOVERY_ADMIN_OUTCOME" ;;
    *) clean_stop_for_sign_in ;;
  esac
}

clean_stop_for_sign_in() {
  clean_record admin-token "NOT RUN" "nothing on this machine can log in to the restored instance, so a person has to"
  ia_print_sign_in_steps "make restore-clean BACKUP=$CLEAN_IID"
  CLEAN_RESULT_IF_2=BLOCKED
  exit 2
}

clean_wait_applications() {
  local deadline=$((SECONDS + ${CLEAN_WAIT_APPS_SECONDS:-600})) json
  log "Waiting for every Application to settle after the restores"
  while [[ $SECONDS -lt $deadline ]]; do
    json="$(kc -n argocd get applications -o json 2>/dev/null || true)"
    if [[ -n "$json" ]] && jq -e 'all(.items[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")' <<<"$json" >/dev/null; then return 0; fi
    sleep 5
  done
  return 0 # verify-applications records what is wrong, with the names.
}

# Step 5's last part: everything once more from outside the restore that made it. Returns 0, 1 if something failed,
# 2 if nothing failed and a proof could not run, as the exit status means for the whole script.
clean_verify() {
  local set_file="$1" env var problems failed=0 not_run=0 rc paused apps_json sentinel step
  ia_init
  ia_load_admin
  if problems="$(recovery_compare_values "$set_file")"; then
    clean_record verify-infisical-values PASS "every Plane secret has the value, version and id the backup recorded"
  else
    clean_record verify-infisical-values FAIL "$(printf '%s' "$problems" | tr '\n' ';')"
    failed=1
  fi
  for env in $CLEAN_ENVS; do
    if problems="$(recovery_compare_rendered "$set_file" "$env")"; then
      clean_record "verify-rendered-$env" PASS "the operators rendered the backed-up values"
    else
      clean_record "verify-rendered-$env" FAIL "$(printf '%s' "$problems" | tr '\n' ';')"
      failed=1
    fi
    # With the files a later make test-e2e uses, unlike the proof in the restore, which reads the database.
    sentinel="$LOCAL_DIR/test-sentinel-$env.json"
    var="$(clean_plane_var "$env")"
    if [[ "$(jq -r '.sentinel // empty | .slug' "$LOCAL_DIR/backups/$env/${!var}/manifest.json")" == "" ]]; then
      clean_record "verify-sentinel-$env" "NOT RUN" "backup ${!var} was taken before tests/e2e/smoke.py created a sentinel"
      not_run=1
    else
      rc=0
      python3 -B "$ROOT/tests/e2e/smoke.py" --env "$env" --mode verify --wait-seconds 300 \
        --sentinel "$sentinel" --evidence "$LOCAL_DIR/evidence-raw/restore-clean-smoke-$env-$CLEAN_STAMP.json" || rc=$?
      case "$rc" in
        0) clean_record "verify-sentinel-$env" PASS "the restored accounts file reads the sentinel work item and its attachment" ;;
        2)
          clean_record "verify-sentinel-$env" "NOT RUN" "tests/e2e/smoke.py was blocked, which usually means no accounts in this backup"
          not_run=1
          ;;
        *)
          clean_record "verify-sentinel-$env" FAIL "tests/e2e/smoke.py exited $rc"
          failed=1
          ;;
      esac
    fi
  done
  # Proofs an earlier step of this restore could not run, which a resume must not forget.
  while read -r step; do
    if [[ -n "$step" ]]; then
      clean_record "$step" "NOT RUN" "a proof in that restore could not run. See restore-*.json"
      not_run=1
    fi
  done <<<"$(sed -n 's/^not-run //p' "$RESTORE_CLEAN_MARKER")"
  clean_wait_applications
  apps_json="$(kc -n argocd get applications -o json)"
  paused="$(jq -r '[.items[] | select(.spec.syncPolicy.automated.enabled == false) | .metadata.name] | join(" ")' <<<"$apps_json")"
  if [[ -z "$paused" ]] && jq -e 'all(.items[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")' <<<"$apps_json" >/dev/null; then
    clean_record verify-applications PASS "$(jq -r '.items | length' <<<"$apps_json") Applications Synced and Healthy, none paused"
  else
    clean_record verify-applications FAIL "paused: ${paused:-none}. Not Synced and Healthy: $(jq -r '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name] | join(" ")' <<<"$apps_json")"
    failed=1
  fi
  ia_cleanup
  if [[ "$failed" -ne 0 ]]; then return 1; fi
  if [[ "$not_run" -ne 0 && "${ALLOW_NO_SENTINEL:-}" != yes ]]; then return 2; fi
  return 0
}

restore_clean() {
  local env var problem dir set_file restore_script="$ROOT/scripts/restore.sh" rc=0 under_way=no aside_note=""
  guard_disk
  low_disk_check_value
  need_commands curl docker git jq kind kubectl openssl python3 shasum terraform yq
  # With Docker down, kind lists no clusters, and everything below would take that for a cluster that is gone.
  docker info >/dev/null 2>&1 || die "Docker is not running, so what exists cannot be told. Nothing was changed."
  umask 077
  CLEAN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$LOCAL_DIR/evidence-raw"
  CLEAN_EVIDENCE="$LOCAL_DIR/evidence-raw/restore-clean-$CLEAN_STAMP.json"
  trap clean_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  clean_resolve "$BACKUP"
  clean_print_plan
  clean_refuse_problems
  dir="$LOCAL_DIR/backups/infisical/$CLEAN_IID"
  set_file="$(recovery_set_file "$dir")"

  if [[ "${PLAN_ONLY:-}" == yes ]]; then
    problem="$(clean_environment_problem)"
    if [[ -n "$problem" ]]; then warn "a real run would refuse right now: $problem. Run make destroy first."; fi
    ok "PLAN_ONLY=yes: nothing was changed"
    return 0
  fi

  clean_refuse_another_run
  if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then
    under_way=yes
    # The cluster it was restoring into is gone, so nothing it finished still counts.
    if ! cluster_exists && grep -q '^done ' "$RESTORE_CLEAN_MARKER"; then
      warn "the cluster that restore was working on is gone, so it starts again from the beginning"
      sed -e '/^done /d' -e '/^not-run /d' "$RESTORE_CLEAN_MARKER" > "$RESTORE_CLEAN_MARKER.tmp"
      mv "$RESTORE_CLEAN_MARKER.tmp" "$RESTORE_CLEAN_MARKER"
    fi
  else
    problem="$(clean_environment_problem)"
    [[ -z "$problem" ]] || die "this is for a clean environment, and $problem. Nothing was changed. To replace it: make destroy CONFIRM=yes SKIP_BACKUP=yes, then make restore-clean BACKUP=$CLEAN_IID. Without SKIP_BACKUP=yes, make destroy backs up what is there now, and BACKUP=latest would then name that set. To restore one environment in place: make restore."
    {
      printf 'infisical=%s\nenvs=%s\n' "$CLEAN_IID" "$CLEAN_ENVS"
      for env in $CLEAN_ENVS; do
        var="$(clean_plane_var "$env")"
        printf '%s=%s\n' "$env" "${!var}"
      done
    } > "$RESTORE_CLEAN_MARKER"
    chmod 600 "$RESTORE_CLEAN_MARKER"
  fi
  clean_claim_marker
  CLEAN_STEPS="$(mktemp "$LOCAL_DIR/.restore-clean-steps.XXXXXX")"
  clean_record plan PASS "Infisical $CLEAN_IID; $(for env in $CLEAN_ENVS; do var="$(clean_plane_var "$env")"; printf '%s %s; ' "$env" "${!var}"; done)checksums and keys check out"

  if [[ "$under_way" == yes ]]; then clean_repair_after_hard_stop; fi

  # The disaster this is for is a cluster lost with no make destroy, which leaves state about it behind.
  if ! cluster_exists && [[ -e "$LOCAL_DIR/terraform/local/terraform.tfstate" ]]; then
    up_move_stale_local_state
    aside_note="$(find "$LOCAL_DIR/terraform" -maxdepth 1 -name 'local.stale-*' | LC_ALL=C sort | tail -1)"
    clean_record terraform-local-state PASS "no cluster existed, so the state describing the old one moved to ${aside_note#"$ROOT"/}"
  fi

  # Before anything reads them: secret-zero.sh applies these files, and bootstrap reads the state.
  recovery_reinstate_zero "$set_file"
  recovery_install_tf_state "$dir"
  recovery_rebuild_machine_file "$dir"

  log "make up as far as Traefik. Plane waits for an identity Secret that does not exist yet."
  UP_STOP_AFTER=traefik "$ROOT/scripts/up.sh"
  clean_record up-to-traefik PASS "cluster, Terraform, secret zero, Traefik"

  if clean_done infisical; then
    clean_record restore-infisical PASS "already restored by an earlier run"
    clean_wait_infisical
    clean_admin_step "$set_file"
  else
    clean_wait_infisical
    "$restore_script" infisical "$CLEAN_IID" CONFIRM=yes RESTORE_MODE=clean || rc=$?
    case "$rc" in
      0)
        clean_mark infisical
        clean_record restore-infisical PASS "$CLEAN_IID, see restore-infisical-*.json"
        ;;
      "$EXIT_NEEDS_SIGN_IN")
        clean_mark infisical
        clean_record restore-infisical PASS "$CLEAN_IID, see restore-infisical-*.json. Its values are checked at the end, since nothing could log in yet"
        clean_stop_for_sign_in
        ;;
      *) exit "$rc" ;;
    esac
    clean_record admin-token PASS "see admin-token in restore-infisical-*.json"
  fi

  # The wait for all Applications passes once, on the first way through. After that a Plane environment may be
  # part way through its restore, which that wait cannot get past, and the restore itself needs only what comes
  # before it. Each restore brings its apps back, and clean_verify waits for all of them at the end.
  if clean_done up-all; then
    log "make up from there, with bootstrap in restored mode. The wait for all Applications comes at the end this time."
    UP_STOP_AFTER=infisical INFISICAL_RESTORED=yes "$ROOT/scripts/up.sh"
    clean_record up-to-infisical PASS "bootstrap in restored mode. All Applications were Synced and Healthy on an earlier run"
  else
    log "make up from there, with bootstrap in restored mode"
    INFISICAL_RESTORED=yes "$ROOT/scripts/up.sh"
    clean_mark up-all
    clean_record up-to-all-applications PASS "bootstrap in restored mode, all Applications Synced and Healthy"
  fi

  for env in $CLEAN_ENVS; do
    var="$(clean_plane_var "$env")"
    if clean_done "$env"; then
      clean_record "restore-$env" PASS "already restored by an earlier run"
    else
      rc=0
      "$restore_script" "$env" "${!var}" CONFIRM=yes || rc=$?
      case "$rc" in
        0) clean_record "restore-$env" PASS "${!var}, see restore-$env-*.json" ;;
        2) printf 'not-run restore-%s\n' "$env" >> "$RESTORE_CLEAN_MARKER" ;;
        *) exit "$rc" ;;
      esac
      clean_mark "$env"
    fi
  done

  rc=0
  clean_verify "$set_file" || rc=$?
  case "$rc" in
    0) rm -f "$RESTORE_CLEAN_MARKER" ;;
    2)
      warn "the platform is back, and at least one proof could not run, so this is not a pass. If that is expected, as with a backup taken before a sentinel existed, run this again with ALLOW_NO_SENTINEL=yes."
      exit 2
      ;;
    *) die "the platform is back, but at least one check failed. It stays marked as under way: fix the cause and run this again." ;;
  esac
}

if [[ "$ENV" == clean ]]; then
  restore_clean
  exit 0
fi

# ----- One environment --------------------------------------------------------------------------

select_env "$ENV"
guard_disk
need_cluster
umask 077

backups_dir="$LOCAL_DIR/backups/$ENV_NAME"
if [[ "$BACKUP" == latest ]]; then
  # Names are UTC timestamps and globs sort, so the last finished one is the newest.
  BACKUP=""
  for candidate in "$backups_dir"/[0-9]*T[0-9]*Z; do
    if [[ -f "$candidate/manifest.json" ]]; then BACKUP="${candidate##*/}"; fi
  done
  [[ -n "$BACKUP" ]] || die "no finished backups in $backups_dir"
fi
BACKUP_ID="$(basename "$BACKUP")"
backup_dir="$backups_dir/$BACKUP_ID"
manifest="$backup_dir/manifest.json"
[[ -f "$manifest" ]] || die "no manifest at $manifest. Each environment's PVC mounts only its own folder, so a backup restores only into the environment that took it."

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JOB_SUFFIX="$(printf '%s' "$STAMP" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$LOCAL_DIR/evidence-raw"
evidence="$LOCAL_DIR/evidence-raw/restore-$ENV_NAME-$STAMP.json"
steps_file="$(mktemp "$LOCAL_DIR/.restore-steps.XXXXXX")"
secret_tmp=""
sentinel_tmp=""
INFISICAL_STOPPED=no
ANYTHING_CHANGED=no # Until a refusal has passed, a failure is a refusal.

record() { # step status detail. Status is PASS, FAIL or NOT RUN, as the contract requires.
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$steps_file"
  case "$2" in
    PASS) ok "$1: ${3:-}" ;;
    FAIL) warn "$1 FAILED: ${3:-}" ;;
    *) warn "$1 $2: ${3:-}" ;;
  esac
}

on_exit() {
  local rc=$? result not_run
  trap - EXIT
  if [[ "$INFISICAL_STOPPED" == yes ]]; then
    kc -n "$NS" scale deployment/infisical --replicas=1 >/dev/null \
      || warn "COULD NOT START the Infisical server. Run: kubectl -n $NS scale deployment/infisical --replicas=1"
  fi
  argo_resume
  ia_cleanup
  [[ -z "$secret_tmp" ]] || rm -f "$secret_tmp"
  [[ -z "$sentinel_tmp" ]] || rm -f "$sentinel_tmp"
  # A proof that could not run is not a pass. proof-probes is about monitoring and not the data, as in the drill.
  not_run="$(awk -F '\t' '$2 == "NOT RUN" && $1 != "proof-probes" { printf "%s ", $1 }' "$steps_file")"
  if [[ "$rc" -eq 0 && -n "$not_run" && "${ALLOW_NO_SENTINEL:-}" != yes ]]; then rc=2; fi
  case "$rc" in
    0) result=PASS ;;
    2) result="NOT RUN" ;;
    "$EXIT_NEEDS_SIGN_IN") result=BLOCKED ;;
    *) result=FAIL ;;
  esac
  jq -Rn --arg env "$ENV_NAME" --arg backup "$BACKUP_ID" --arg at "$STAMP" --arg result "$result" '
    { environment: $env, backup: $backup, started_at: $at, result: $result,
      steps: [inputs | split("\t") | {step: .[0], status: .[1], detail: .[2]}] }
    | .not_run = [.steps[] | select(.status == "NOT RUN") | .step]' \
    < "$steps_file" > "$evidence" || true
  rm -f "$steps_file"
  case "$rc" in
    0) ok "restore of $BACKUP_ID into $ENV_NAME complete. Evidence: $evidence" ;;
    2) warn "the data of $BACKUP_ID is back in $ENV_NAME, and these proofs could not run, so this is not a pass: $not_run. ALLOW_NO_SENTINEL=yes accepts that. Evidence: $evidence" ;;
    "$EXIT_NEEDS_SIGN_IN") warn "the data of $BACKUP_ID is back in $ENV_NAME, and nothing here can log in to prove it, as the steps above say. Evidence: $evidence" ;;
    *)
      if [[ "$ANYTHING_CHANGED" == no ]]; then
        warn "restore of $BACKUP_ID into $ENV_NAME refused, as said above. Nothing was changed. Evidence: $evidence"
      else
        warn "restore of $BACKUP_ID into $ENV_NAME FAILED. Auto-sync is back on, so Argo CD restarts the apps against whatever was restored, unless the warnings above say it was terminated. Evidence: $evidence"
      fi
      ;;
  esac
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ----- Refusals. Nothing below this block runs until all of them pass. ------------------------

log "Verifying $BACKUP_ID"
(cd "$backup_dir" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "checksum verification failed for $backup_dir: refusing to restore"
record checksums PASS "$(wc -l < "$backup_dir/SHA256SUMS" | tr -d ' ') files match"

[[ "$(jq -r .env "$manifest")" == "$ENV_NAME" ]] || die "manifest says env $(jq -r .env "$manifest"), not $ENV_NAME"

live_key_fp() { # secret key. Byte-exact: no shell variable holds the value and no newline is added.
  kc -n "$NS" get secret "$1" -o json | jq -je --arg k "$2" '.data[$k] | @base64d' | shasum -a 256 | cut -c1-16
}

check_fingerprint() { # manifest-field secret key
  local want have
  want="$(jq -r ".$1" "$manifest")"
  have="$(live_key_fp "$2" "$3")" || die "cannot read $3 from Secret $2 in $NS"
  if [[ "$want" == "$have" ]]; then
    record key-fingerprint PASS "$3 matches the backup"
  elif [[ "${ALLOW_SECRET_KEY_MISMATCH:-}" == yes ]]; then
    record key-fingerprint FAIL "$3 differs from the backup, proceeding on ALLOW_SECRET_KEY_MISMATCH=yes"
  else
    die "$3 differs from the one this backup was taken with (live $have, backup $want). Encrypted data would decrypt silently to nothing. Restore the right key, or pass ALLOW_SECRET_KEY_MISMATCH=yes to accept the loss."
  fi
}

# Reports whether the target holds data. A Job rather than exec, for the same network path a backup
# uses. A failed listing stops the restore: it must not read as "empty" and skip the guard.
inspect_target() { # pg-image db-service db-secret
  local job="plane-restore-guard-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "PG_IMAGE=$1" "DB_SERVICE=$2" "DB_SECRET=$3" <<'YAML' | run_job "$NS" "$job" 300
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: database
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: PGHOST, value: __DB_SERVICE__ }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 64Mi }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              if [ "$(psql -XAt -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$POSTGRES_DB'")" = 0 ]; then
                echo USERS=0
              elif [ "$(psql -XAt -d "$POSTGRES_DB" -c "SELECT to_regclass('public.users') IS NOT NULL")" = t ]; then
                echo "USERS=$(psql -XAt -d "$POSTGRES_DB" -c 'SELECT count(*) FROM users')"
              else
                echo USERS=0
              fi
YAML
}

inspect_bucket() {
  local job="plane-restore-guard-objects-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "RCLONE_IMAGE=$RCLONE_IMAGE" <<'YAML' | run_job "$NS" "$job" 300
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 64Mi }
      containers:
        - name: bucket
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: HOME, value: /tmp }
            - { name: RCLONE_CONFIG, value: /tmp/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
          command: [/bin/sh, -c]
          args:
            - |
              set -u
              rclone lsf -R --files-only "dst:$BUCKET" > /tmp/objects
              rc=$?
              case "$rc" in
                0) echo "OBJECTS=$(wc -l < /tmp/objects | tr -d ' ')" ;;
                3) echo OBJECTS=0 ;; # rclone's exit code for "directory not found": no bucket yet
                *) exit "$rc" ;;
              esac
YAML
}

refuse_if_not_empty() { # users objects
  if [[ "$1" -eq 0 && "$2" -eq 0 ]]; then
    record overwrite-guard PASS "target is empty"
  elif [[ "${CONFIRM:-}" == yes ]]; then
    record overwrite-guard PASS "target holds $1 users and $2 objects, overwriting on CONFIRM=yes"
  else
    die "$NS already holds data ($1 users, $2 objects). Re-run with CONFIRM=yes to overwrite it."
  fi
}

live_image() { # kind name container
  kc -n "$NS" get "$1" "$2" -o json \
    | jq -r --arg c "$3" '.spec.template.spec.containers[] | select(.name == $c) | .image'
}

# ----- Plane ------------------------------------------------------------------------------------

no_app_pods() {
  [[ -z "$(kc -n "$NS" get pods -l 'app.kubernetes.io/component in (api,worker,beat,live)' -o name 2>/dev/null)" ]]
}

desired_replicas() { # deployment. From Git, so a run that died at zero cannot make zero the target.
  D="$1" yq -N 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.replicas // 1' \
    "$ROOT/gitops/environments/$ENV_NAME/manifests.yaml"
}

restore_data() { # pg-image
  local job="plane-restore-$JOB_SUFFIX"
  log "Restoring Postgres and objects from $BACKUP_ID"
  fill "JOB=$job" "NS=$NS" "ID=$BACKUP_ID" "PG_IMAGE=$1" "RCLONE_IMAGE=$RCLONE_IMAGE" <<'YAML' | run_job "$NS" "$job" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: backups, readOnly: true }
        - name: work
          emptyDir: { sizeLimit: 64Mi }
      initContainers:
        - name: postgres
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: PGHOST, value: plane-pgdb }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              B="/backups/$BACKUP_ID"
              TAB="$(printf '\t')"
              # dropdb and not pg_restore --clean, so tables newer than the dump cannot survive.
              # --force, because the exporter holds a connection. --single-transaction makes the
              # restore all or nothing, and rules out --jobs.
              dropdb --maintenance-db=postgres --force --if-exists "$POSTGRES_DB"
              createdb --maintenance-db=postgres "$POSTGRES_DB"
              pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d "$POSTGRES_DB" "$B/postgres/plane.dump"
              vacuumdb --analyze-only "$POSTGRES_DB"

              # The apps are down, so this must equal the scratch restore exactly.
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" -f "$B/postgres/rowcounts.sql" > /work/rowcounts.tsv
              diff "$B/postgres/rowcounts.tsv" /work/rowcounts.tsv
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" -f "$B/postgres/content.sql" > /work/content.tsv
              diff "$B/postgres/content.tsv" /work/content.tsv
              echo "GATE1 ok: $(wc -l < /work/rowcounts.tsv) tables equal the backup"

              # For the gate below: a row the app believes is uploaded must have its object.
              psql -XAt -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" \
                -c "SELECT asset FROM file_assets WHERE is_uploaded AND NOT is_deleted AND deleted_at IS NULL" \
                | LC_ALL=C sort > /work/keys.txt
        - name: objects
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: HOME, value: /work }
            - { name: RCLONE_CONFIG, value: /work/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 500m, memory: 192Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              B="/backups/$BACKUP_ID"
              TAB="$(printf '\t')"
              # sync and not copy: objects that are not in the backup must go.
              rclone sync "$B/objects" "dst:$BUCKET" --checksum --transfers 4 --stats 0
              rclone check "$B/objects" "dst:$BUCKET" --one-way --download
              echo "objects: sync and downloading check ok"
              # The upload guessed each Content-Type from the name, because the host folder cannot keep
              # it. Plane's presigned GET serves what is stored, so put back what the backup recorded.
              if [ -s "$B/recovery/objects.types.tsv" ]; then
                LC_ALL=C sort "$B/recovery/objects.types.tsv" > /work/types.want
                rclone lsf -R --files-only --format pm --separator "$TAB" "dst:$BUCKET" | LC_ALL=C sort > /work/types.now
                LC_ALL=C comm -13 /work/types.now /work/types.want > /work/types.fix
                while IFS="$TAB" read -r key type; do
                  rclone copyto "$B/objects/$key" "dst:$BUCKET/$key" --ignore-times --header-upload "Content-Type: $type" --stats 0
                done < /work/types.fix
                rclone lsf -R --files-only --format pm --separator "$TAB" "dst:$BUCKET" | LC_ALL=C sort > /work/types.now
                left="$(LC_ALL=C comm -13 /work/types.now /work/types.want)"
                if [ -n "$left" ]; then
                  echo "objects: Content-Type still differs:" >&2
                  echo "$left" >&2
                  exit 1
                fi
                echo "objects: Content-Type put back on $(wc -l < /work/types.fix | tr -d ' ') of $(wc -l < /work/types.want | tr -d ' ') objects"
              fi
      containers:
        # Catches a database and a bucket that came from different backups.
        - name: gate
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: HOME, value: /work }
            - { name: RCLONE_CONFIG, value: /work/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              rclone lsf -R --files-only "dst:$BUCKET" | LC_ALL=C sort > /work/objects.txt
              missing="$(LC_ALL=C comm -23 /work/keys.txt /work/objects.txt)"
              if [ -n "$missing" ]; then
                echo "GATE2 failed: rows marked uploaded with no object:" >&2
                echo "$missing" >&2
                exit 1
              fi
              echo "GATE2 ok: $(wc -l < /work/keys.txt) uploaded assets all have an object"
YAML
}

# wait_for_migrations blocks the API, worker and beat forever on an unapplied migration, and the
# Argo hook does not run again here. The rendered Job is the template, so this cannot differ from
# what Argo CD runs, except that it uses the image the API is running now.
run_migrator() {
  local job="plane-restore-migrate-$JOB_SUFFIX" api_image
  api_image="$(live_image deployment plane-api-wl plane-api)"
  log "Running the migrator"
  JOB_NAME="$job" API_IMAGE="$api_image" yq '
      select(.kind == "Job" and (.metadata.name | test("^plane-api-migrate")))
      | .metadata.name = strenv(JOB_NAME)
      | del(.metadata.annotations)
      | .spec.ttlSecondsAfterFinished = 86400
      | .spec.template.spec.containers[0].image = strenv(API_IMAGE)
    ' "$ROOT/gitops/environments/$ENV_NAME/manifests.yaml" | run_job "$NS" "$job" 900
}

prove_decrypt() {
  local expected out sentinel undecryptable rows
  expected="$(jq -r '.encrypted_sentinel // "none"' "$manifest")"
  out="$(plane_python "
from plane.license.models import InstanceConfiguration as C
from plane.license.utils.encryption import decrypt_data as d
row = C.objects.filter(key='$ENCRYPTED_SENTINEL_KEY').first()
print('@@SENTINEL=' + ('missing' if row is None else ('ok' if d(row.value) == '$ENCRYPTED_SENTINEL_VALUE' else 'wrong')))
rows = C.objects.filter(is_encrypted=True).exclude(value__isnull=True).exclude(value='')
print('@@ROWS=%d' % rows.count())
print('@@UNDECRYPTABLE=' + ','.join(c.key for c in rows if not d(c.value)))
")" || true
  sentinel="$(printf '%s\n' "$out" | sed -n 's/^SENTINEL=//p')"
  rows="$(printf '%s\n' "$out" | sed -n 's/^ROWS=//p')"
  undecryptable="$(printf '%s\n' "$out" | sed -n 's/^UNDECRYPTABLE=//p')"

  [[ -n "$rows" ]] || { record proof-decrypt FAIL "could not run the check in the API pod"; return 1; }
  if [[ "$expected" != ok ]]; then
    record proof-encrypted-sentinel "NOT RUN" "this backup was taken with no encrypted sentinel"
  elif [[ "$sentinel" == ok ]]; then
    record proof-encrypted-sentinel PASS "sentinel row decrypts to its seeded value"
  else
    record proof-encrypted-sentinel FAIL "sentinel row is $sentinel"
    return 1
  fi
  if [[ -n "$undecryptable" ]]; then
    record proof-no-empty-decrypt FAIL "these rows decrypt to nothing: $undecryptable"
    return 1
  fi
  record proof-no-empty-decrypt PASS "$rows encrypted rows all decrypt"
}

# tests/e2e/smoke.py owns these checks, so a restore proves exactly what the smoke test proves: the
# sentinel work item through the API, the attachment's checksum through a presigned URL, and a
# worker finishing a new job. The token comes from the restored database, which also proves the
# tokens survived, and it stays in a 0600 file for the length of the call.
prove_sentinel() {
  local slug token prefix rc=0
  slug="$(jq -r '.sentinel.slug // ""' "$manifest")"
  if [[ -z "$slug" ]]; then
    record proof-sentinel "NOT RUN" "this backup was taken before tests/e2e/smoke.py created a sentinel"
    return 0
  fi
  token="$(plane_python "
from plane.db.models import APIToken, Workspace
w = Workspace.objects.filter(slug='$slug').first()
t = APIToken.objects.filter(user=w.owner, is_active=True).order_by('-created_at').first() if w else None
print('@@' + (t.token if t else ''))
" | tail -1)" || true
  if [[ -z "$token" ]]; then
    record proof-sentinel FAIL "workspace $slug or its owner's API token is not in the restored database"
    return 1
  fi
  secret_tmp="$(mktemp "$LOCAL_DIR/.restore-accounts.XXXXXX")"
  sentinel_tmp="$(mktemp "$LOCAL_DIR/.restore-sentinel.XXXXXX")"
  prefix="PLANE_$(printf '%s' "$ENV_NAME" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s_API_TOKEN=%s\n' "$prefix" "$token" > "$secret_tmp"
  jq '.sentinel' "$manifest" > "$sentinel_tmp"
  python3 "$ROOT/tests/e2e/smoke.py" --env "$ENV_NAME" --mode verify --job-probe \
    --accounts "$secret_tmp" --sentinel "$sentinel_tmp" \
    --evidence "$LOCAL_DIR/evidence-raw/restore-smoke-$ENV_NAME-$STAMP.json" || rc=$?
  if [[ $rc -eq 0 ]]; then
    record proof-sentinel PASS "work item read through the API, attachment checksum matches, a worker ran a new job"
  else
    record proof-sentinel FAIL "tests/e2e/smoke.py exited $rc, see restore-smoke-$ENV_NAME-$STAMP.json"
    return 1
  fi
}

# Ties the restore to monitoring. Only a warning if Prometheus is unreachable: the data is proven
# above, and a broken dashboard path should not fail a restore.
prove_probes() {
  local deadline=$((SECONDS + 180)) value
  while [[ $SECONDS -lt $deadline ]]; do
    value="$(prom_query "min(probe_success{namespace=\"$NS\",probe=~\"api-instance|api-db\"})" 2>/dev/null \
      | jq -r '.data.result[0].value[1] // "none"' 2>/dev/null || echo none)"
    if [[ "$value" == 1 ]]; then
      record proof-probes PASS "API and database probes are green"
      return 0
    fi
    sleep 10
  done
  record proof-probes "NOT RUN" "probes did not report green within 180s (last value: ${value:-none})"
}

restore_plane() {
  local pg_image plane_version live_version newest users objects deployment replicas failed=0 inspect
  pg_image="$(live_image statefulset plane-pgdb-wl plane-pgdb)"
  [[ -n "$pg_image" ]] || die "cannot read plane-pgdb-wl in $NS. Is the Plane Application synced?"

  # Django cannot migrate backwards, so a dump from a newer release cannot run on this image.
  plane_version="$(jq -r .plane_version "$manifest")"
  live_version="$(kc -n "$NS" get deployment plane-api-wl -o json | jq -r '.spec.template.metadata.labels["app.kubernetes.io/version"] // "unknown"')"
  newest="$(printf '%s\n%s\n' "${plane_version#v}" "${live_version#v}" | sort -V | tail -1)"
  [[ "$newest" == "${live_version#v}" ]] || die "backup is from Plane $plane_version but $NS runs $live_version. Migrations do not run backwards."
  record version PASS "backup $plane_version, running $live_version"

  check_fingerprint secret_key_fp plane-app-keys SECRET_KEY

  log "Waiting for the data services"
  for deployment in plane-pgdb-wl plane-minio-wl plane-redis-wl plane-rabbitmq-wl; do
    kc -n "$NS" rollout status "statefulset/$deployment" --timeout=300s >/dev/null || die "$deployment is not ready"
  done

  inspect="$(inspect_target "$pg_image" plane-pgdb plane-pgdb)" || { printf '%s\n' "$inspect" >&2; die "could not inspect the database"; }
  users="$(printf '%s\n' "$inspect" | sed -n 's/.*USERS=//p' | tail -1)"
  inspect="$(inspect_bucket)" || { printf '%s\n' "$inspect" >&2; die "could not list the bucket"; }
  objects="$(printf '%s\n' "$inspect" | sed -n 's/.*OBJECTS=//p' | tail -1)"
  [[ -n "$users" && -n "$objects" ]] || die "could not read the state of $NS"
  refuse_if_not_empty "$users" "$objects"

  # ----- Past this line the environment is being changed. -----
  ANYTHING_CHANGED=yes
  argo_pause "$APP"
  log "Stopping the apps"
  for deployment in $APP_DEPLOYMENTS; do
    kc -n "$NS" scale "deployment/$deployment" --replicas=0 >/dev/null
  done
  wait_for 180 "app pods to exit" no_app_pods
  record apps-stopped PASS "api, worker, beat and live at zero with auto-sync paused"

  restore_data "$pg_image"
  record postgres PASS "dump restored in one transaction, row counts and content hashes equal the backup"
  record objects PASS "synced and checked by download, every uploaded asset has its object"
  recovery_reinstate_test_files "$backup_dir" "$ENV_NAME"

  # Old cache entries and queued tasks describe rows from before the restore.
  kc -n "$NS" exec plane-redis-wl-0 -c plane-redis -- valkey-cli FLUSHALL >/dev/null
  record valkey PASS "flushed"
  # No grep -q: it exits at the first match, kubectl takes SIGPIPE, and pipefail reads that as absent.
  if kc -n "$NS" exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q list_queues name | grep -x celery >/dev/null; then
    kc -n "$NS" exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q purge_queue celery >/dev/null
    record rabbitmq PASS "queue celery purged"
  else
    record rabbitmq PASS "no celery queue to purge"
  fi

  run_migrator
  record migrator PASS "completed"

  # API first: its boot clears the cache and re-registers, and worker and live want it up.
  log "Starting the apps"
  for deployment in $APP_DEPLOYMENTS; do
    replicas="$(desired_replicas "$deployment")"
    kc -n "$NS" scale "deployment/$deployment" --replicas="$replicas" >/dev/null
    kc -n "$NS" rollout status "deployment/$deployment" --timeout=600s >/dev/null || die "$deployment did not become ready"
  done
  record apps-started PASS "api, worker, beat and live are ready"

  log "Proving the restore"
  prove_decrypt || failed=1
  prove_sentinel || failed=1
  prove_probes
  [[ $failed -eq 0 ]] || die "the data is back, but at least one proof failed"
}

# ----- Infisical --------------------------------------------------------------------------------

restore_infisical_db() { # pg-image
  local job="plane-restore-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "ID=$BACKUP_ID" "PG_IMAGE=$1" <<'YAML' | run_job "$NS" "$job" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: backups, readOnly: true }
        - name: work
          emptyDir: { sizeLimit: 64Mi }
      containers:
        - name: postgres
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: PGHOST, value: infisical-postgres }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              B="/backups/$BACKUP_ID"
              T="${POSTGRES_DB}_restoring"
              TAB="$(printf '\t')"
              # Into a second database, then a rename. --single-transaction is not possible here:
              # 3,000 partition indexes need more locks in one transaction than this server has
              # (out of shared memory, measured). So until the rename the live database is untouched,
              # a bad dump costs nothing, and a server that starts now cannot see half a restore.
              dropdb --maintenance-db=postgres --force --if-exists "$T"
              createdb --maintenance-db=postgres "$T"
              pg_restore --no-owner --no-privileges --exit-on-error -d "$T" "$B/postgres/infisical.dump"
              vacuumdb --analyze-only "$T"
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$T" -f "$B/postgres/rowcounts.sql" > /work/rowcounts.tsv
              diff "$B/postgres/rowcounts.tsv" /work/rowcounts.tsv
              echo "GATE1 ok: $(wc -l < /work/rowcounts.tsv) tables equal the backup"
              # Two renames in one transaction, so that wherever this stops, a database of the right name exists
              # and is whole. Only then is the old one dropped. The server is at zero, and this ends any other session.
              O="${POSTGRES_DB}_replaced"
              dropdb --maintenance-db=postgres --force --if-exists "$O"
              psql -XAt -v ON_ERROR_STOP=1 -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB'" > /dev/null
              if [ "$(psql -XAt -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$POSTGRES_DB'")" = 0 ]; then
                psql -X -v ON_ERROR_STOP=1 -d postgres -c "ALTER DATABASE \"$T\" RENAME TO \"$POSTGRES_DB\""
              else
                psql -X -v ON_ERROR_STOP=1 --single-transaction -d postgres \
                  -c "ALTER DATABASE \"$POSTGRES_DB\" RENAME TO \"$O\"" \
                  -c "ALTER DATABASE \"$T\" RENAME TO \"$POSTGRES_DB\""
                dropdb --maintenance-db=postgres --force --if-exists "$O"
              fi
              echo "swapped in: $POSTGRES_DB is now the restored database"
YAML
}

# A rotation after this dump leaves Plane's Postgres on a password the dump does not hold. Restoring it
# in place would have the operators render the old value, and Plane's next restart would fail to log in.
# Not an issue on a clean restore, where Postgres initializes with whatever Infisical says.
refuse_stale_plane_secrets() { # set-file
  local env details stale=""
  for env in dev prod-sim; do
    kc -n "plane-$env" get secret plane-pgdb >/dev/null 2>&1 || continue # nothing rendered, so nothing to go stale
    if ! details="$(recovery_compare_rendered "$1" "$env")"; then
      stale="$stale $env ($(printf '%s' "$details" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'))"
    fi
  done
  [[ -n "$stale" ]] || return 0
  if [[ "${ALLOW_STALE_PLANE_SECRETS:-}" == yes ]]; then
    record stale-plane-secrets FAIL "this dump holds other values than run in:$stale, proceeding on ALLOW_STALE_PLANE_SECRETS=yes"
  else
    die "this dump holds other values than run in:$stale, so a rotation or a manual change happened after it. The operators would render the old values, and Plane would fail to log in at its next restart. Use a newer backup, or pass ALLOW_STALE_PLANE_SECRETS=yes and repair it with ALTER ROLE."
  fi
}

no_server_pods() {
  [[ -z "$(kc -n "$NS" get pods -l app=infisical-standalone,component=infisical -o name 2>/dev/null)" ]]
}

restore_infisical() {
  local pg_image server_image backup_image inspect users status set_file="" problems initialized flushed backup_version live_version stopped_at started_seconds admin_rc=0
  pg_image="$(live_image statefulset infisical-postgres postgres)"
  [[ -n "$pg_image" ]] || die "cannot read infisical-postgres. Is the infisical Application synced?"
  # The dump is useless without the key that encrypted its root key. Infisical cannot run on a wrong
  # one, so unlike Plane this mismatch is fatal to the secret store, not just to a few rows.
  check_fingerprint encryption_key_fp infisical-secrets ENCRYPTION_KEY

  if recovery_set_complete "$backup_dir"; then
    set_file="$(recovery_set_file "$backup_dir")"
  elif [[ "$RESTORE_MODE" == clean ]]; then
    die "backup $BACKUP_ID cannot serve a clean restore: $(recovery_why_incomplete "$backup_dir")"
  else
    warn "backup $BACKUP_ID has no complete recovery set: $(recovery_why_incomplete "$backup_dir"). The Terraform state and Plane secrets on this machine will not be checked against it."
  fi

  # Migrations only go forward, so an older image than the dump's will refuse to start on it, which in place would
  # replace a working database and leave the server down.
  server_image="$(live_image deployment infisical infisical-standalone-infisical)"
  backup_image="$(jq -r '.server_image // ""' "$manifest")"
  backup_version="$(recovery_image_version "$backup_image")"
  live_version="$(recovery_image_version "$server_image")"
  if recovery_version_newer "$backup_version" "$live_version"; then
    if [[ "${ALLOW_NEWER_INFISICAL_BACKUP:-}" != yes ]]; then
      die "this backup is from Infisical v$backup_version, and the server runs v$live_version. Its migrations go forward only, so that server would refuse to start on it. Deploy v$backup_version or newer first, or pass ALLOW_NEWER_INFISICAL_BACKUP=yes."
    fi
    record version FAIL "backup v$backup_version, running v$live_version, proceeding on ALLOW_NEWER_INFISICAL_BACKUP=yes"
  elif [[ -n "$backup_image" && "$backup_image" != "$server_image" ]]; then
    warn "this backup was taken on $backup_image and the server runs $server_image."
    record version PASS "backup v${backup_version:-unknown}, running v${live_version:-unknown}"
  else
    record version PASS "backup v${backup_version:-unknown}, running v${live_version:-unknown}"
  fi

  if [[ -n "$set_file" && "$RESTORE_MODE" != clean ]]; then refuse_stale_plane_secrets "$set_file"; fi

  # After the swap a token has to log in to prove anything, and the time to find out there is none is now.
  if [[ -n "$set_file" ]]; then
    recovery_admin_plan "$set_file"
    case "$RECOVERY_ADMIN_MODE" in
      token) ;;
      mint) warn "$(recovery_admin_plan_text)" ;;
      *)
        if [[ "$RESTORE_MODE" != clean && "${ALLOW_NO_ADMIN_TOKEN:-}" != yes ]]; then
          die "$RECOVERY_ADMIN_WHY, and no password is on this machine, so nothing could log in after this restore. Nothing was changed. Write the password of $INFISICAL_ADMIN_EMAIL to ${ADMIN_PASSWORD_FILE#"$ROOT"/}, mode 0600, and run this again: it signs in afterwards and mints a token. A token made now would not help, because this dump does not hold it. If this instance's Postgres is lost there is nothing to sign in to now, and ALLOW_NO_ADMIN_TOKEN=yes restores it and then stops with the steps. With no copy of the password, see \"Admin token and password both gone\" in infisical/README.md."
        fi
        warn "$(recovery_admin_plan_text)"
        ;;
    esac
  fi

  kc -n "$NS" rollout status statefulset/infisical-postgres --timeout=300s >/dev/null || die "infisical-postgres is not ready"
  kc -n "$NS" rollout status statefulset/infisical-redis --timeout=300s >/dev/null || die "infisical-redis is not ready"
  inspect="$(inspect_target "$pg_image" infisical-postgres infisical-db)" || { printf '%s\n' "$inspect" >&2; die "could not inspect the database"; }
  users="$(printf '%s\n' "$inspect" | sed -n 's/.*USERS=//p' | tail -1)"
  [[ -n "$users" ]] || die "could not read the state of $NS"
  refuse_if_not_empty "$users" 0

  # ----- Past this line the environment is being changed. -----
  ANYTHING_CHANGED=yes
  recovery_install_tf_state "$backup_dir"
  if [[ -n "$set_file" ]]; then recovery_rebuild_machine_file "$backup_dir"; fi

  # This one Application: root may be busy for as long as Plane waits, and its waves do not depend on
  # this pause. See argo_pause_child.
  argo_pause_child "$APP"
  INFISICAL_STOPPED=yes
  stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_seconds=$SECONDS
  kc -n "$NS" scale deployment/infisical --replicas=0 >/dev/null
  wait_for 180 "the Infisical server to exit" no_server_pods
  record app-stopped PASS "infisical at zero with auto-sync paused"

  restore_infisical_db "$pg_image"
  record postgres PASS "dump restored into a second database, row counts equal the backup, swapped in"

  # The server caches into Redis what describes the old database: admin config, secrets, permissions,
  # identity revocation versions, KMS material, and queued jobs. From a list of its keys, 2026-11-05.
  flushed="$(kc -n "$NS" exec infisical-redis-0 -c redis -- redis-cli FLUSHALL)" || die "could not flush Infisical's Redis"
  [[ "$flushed" == OK ]] || die "flushing Infisical's Redis answered: $flushed"
  record redis PASS "flushed, so no cache or queued job from before the restore survives"

  kc -n "$NS" scale deployment/infisical --replicas=1 >/dev/null
  kc -n "$NS" rollout status deployment/infisical --timeout=600s >/dev/null || die "infisical did not become ready"
  INFISICAL_STOPPED=no

  status="000"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    status="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$INFISICAL_URL/api/status" || true)"
    [[ "$status" != 200 ]] || break
    sleep 5
  done
  if [[ "$status" == 200 ]]; then
    record proof-status PASS "/api/status answers 200 through Traefik"
    record server-downtime PASS "told to stop at $stopped_at, answering by $(date -u +%Y-%m-%dT%H:%M:%SZ), $((SECONDS - started_seconds))s"
  else
    record proof-status FAIL "/api/status answered $status"
    die "Infisical did not answer after the restore"
  fi
  initialized="$(curl -fsS -m 10 "$INFISICAL_URL/api/v1/admin/config" | jq -r '.config.initialized | tostring')" || initialized=unknown
  if [[ "$initialized" == true ]]; then
    record proof-initialized PASS "the server reads the restored admin config"
  else
    record proof-initialized FAIL "config.initialized is $initialized"
    die "the server does not see a restored instance"
  fi

  if [[ -n "$set_file" ]]; then
    # Decrypting them needs ENCRYPTION_KEY, and being let in needs AUTH_SECRET and the token row.
    ia_init
    recovery_admin_after_restore "$set_file" || admin_rc=$?
    if [[ "$admin_rc" -ne 0 ]]; then
      record admin-token "NOT RUN" "nothing on this machine can log in to the restored instance"
      record proof-values "NOT RUN" "nothing could log in to read them"
      if [[ "$RESTORE_MODE" == clean ]]; then exit "$EXIT_NEEDS_SIGN_IN"; fi
      ia_print_sign_in_steps "INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh"
      exit "$EXIT_NEEDS_SIGN_IN"
    fi
    record admin-token PASS "$RECOVERY_ADMIN_OUTCOME"
    ia_load_admin
    if problems="$(recovery_compare_values "$set_file")"; then
      record proof-values PASS "every Plane secret decrypts to the value, version and id the backup recorded"
    else
      record proof-values FAIL "$(printf '%s' "$problems" | tr '\n' ';')"
      die "the restored instance does not hold what the backup recorded"
    fi
  else
    record proof-values "NOT RUN" "this backup has no recovery set to compare with"
  fi
  if [[ "$RESTORE_MODE" != clean ]]; then
    ok "Next, to refresh the cluster CA and the identity Secrets: INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh"
  fi
}

if [[ "$ENV_NAME" == infisical ]]; then restore_infisical; else restore_plane; fi
