#!/usr/bin/env bash
# Rotate one environment's Plane Postgres password through Infisical, and prove it took effect.
#
#   scripts/rotate.sh ENV=dev               rotate (also: scripts/rotate.sh dev)
#   scripts/rotate.sh ENV=dev RESUME=yes    finish a rotation that stopped halfway
#   scripts/rotate.sh ENV=dev ROLLBACK=yes  undo a rotation that stopped halfway
#   scripts/rotate.sh ENV=prod-sim CONFIRM=yes
#
# Why a script: native rotation is a paid feature. Why PG_PASSWORD: the role can be changed in place
# and the old value can be shown to fail. SECRET_KEY must never be rotated, because it derives the
# key for encrypted config rows and decrypt_data fails silently to "". This script touches no other
# Infisical secret and verifies SECRET_KEY did not move.
#
# What this is not: native or scheduled rotation, or per-pod credentials. There is an error window,
# measured below, because the one replica restarts with a password Postgres may not accept yet. The
# role is a shared superuser. In-flight Jobs keep the old value. Rolling the value back in Infisical
# by hand would not run ALTER ROLE; only ROLLBACK=yes keeps both sides together.
#
# Every step checks real state instead of trusting a log, so RESUME and ROLLBACK are the same code
# aimed at a different password. The journal holds both values until the rotation finishes.
#
# A finished rotation takes an Infisical backup, because an older dump would hold the old PG_PASSWORD
# (SKIP_BACKUP=yes skips it). If that backup fails the rotation stands, and this exits 3.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

for arg in "$@"; do
  case "$arg" in
    ENV=*) ENV="${arg#ENV=}" ;;
    RESUME=*) RESUME="${arg#RESUME=}" ;;
    ROLLBACK=*) ROLLBACK="${arg#ROLLBACK=}" ;;
    CONFIRM=*) CONFIRM="${arg#CONFIRM=}" ;;
    SKIP_BACKUP=*) SKIP_BACKUP="${arg#SKIP_BACKUP=}" ;;
    dev | prod-sim) ENV="$arg" ;;
    *) die "unknown argument '$arg'. Usage: scripts/rotate.sh ENV=dev [RESUME=yes|ROLLBACK=yes]" ;;
  esac
done
ENV="${ENV:-}"
RESUME="${RESUME:-}"
ROLLBACK="${ROLLBACK:-}"
CONFIRM="${CONFIRM:-}"
[[ -n "$ENV" ]] || die "ENV is required. Usage: scripts/rotate.sh ENV=dev"
NS="$(env_namespace "$ENV")"
[[ "$ENV" != prod-sim || "$CONFIRM" == yes ]] || die "rotating prod-sim causes an error window. Add CONFIRM=yes."
[[ "$RESUME" != yes || "$ROLLBACK" != yes ]] || die "choose RESUME=yes or ROLLBACK=yes, not both"

guard_disk
need_commands curl jq kubectl openssl
ia_init

SECRET_NAME=PG_PASSWORD
PG_POD=plane-pgdb-wl-0
PG_CONTAINER=plane-pgdb
APP_SECRET=plane-app-env
PG_SECRET=plane-pgdb
KEYS_SECRET=plane-app-keys
# /api/instances/ is cached in Valkey for two hours and answers 200 with Postgres down. This route
# runs DeployBoard.objects.get on a connection opened per request: 404 "does not exist" needs the
# database, and a failed login gives 500.
DB_PROBE_URL="${DB_PROBE_URL:-http://plane.$ENV.localhost/api/public/anchor/__probe__/settings/}"
JOURNAL="$SECRET_ZERO_DIR/rotation-$ENV"
EVIDENCE_DIR="$LOCAL_DIR/evidence-raw"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="$EVIDENCE_DIR/rotate-$ENV-$RUN_STAMP.log"
PROBE_LOG="$EVIDENCE_DIR/rotate-$ENV-$RUN_STAMP.probe"
PROBE_PID=""
JOURNAL_ACTIVE=""
WORKLOADS=""
PG_POD_IP=""
PROJECT_ID=""
ENV_SLUG=""
IA_VALUE=""
IA_VERSION=""

mkdir -p "$EVIDENCE_DIR"

# Lines hold results and counts, never values, so this file may be copied to docs/evidence.
evidence() { # PASS|FAIL|INFO text
  printf '%s %-4s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" | tee -a "$EVIDENCE"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "$PROBE_PID" ]]; then kill "$PROBE_PID" 2>/dev/null || true; fi
  if [[ "$rc" -ne 0 && -n "$JOURNAL_ACTIVE" && -d "$JOURNAL" ]]; then report_half_rotated || true; fi
  ia_cleanup
  exit "$rc"
}
trap on_exit EXIT

# ---- Infisical ---------------------------------------------------------------------------------
ia_read_password() { # Sets IA_VALUE and IA_VERSION
  ia_request GET "/api/v4/secrets/$SECRET_NAME?projectId=$PROJECT_ID&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=true&expandSecretReferences=false&includeImports=false"
  [[ "$IA_STATUS" == 200 ]] || die "reading $SECRET_NAME from Infisical returned HTTP $IA_STATUS: $(ia_error)"
  IA_VALUE="$(printf '%s' "$IA_BODY" | jq -er '.secret.secretValue')"
  IA_VERSION="$(printf '%s' "$IA_BODY" | jq -er '.secret.version')"
}

ia_write_password() {
  local body
  body="$(printf '%s' "$1" | jq -Rs --arg project "$PROJECT_ID" --arg env_slug "$ENV_SLUG" \
    '{projectId: $project, environment: $env_slug, secretPath: "/", secretValue: .}')"
  ia_request PATCH "/api/v4/secrets/$SECRET_NAME" "$body"
  [[ "$IA_STATUS" == 200 ]] || die "writing $SECRET_NAME to Infisical returned HTTP $IA_STATUS: $(ia_error)"
}

# ---- Kubernetes Secrets the operator owns ------------------------------------------------------
secret_value() { # secret key
  kc -n "$NS" get secret "$1" -o json | jq -r --arg key "$2" '.data[$key] // "" | @base64d'
}

secret_version() {
  kc -n "$NS" get secret "$APP_SECRET" -o json | jq -r '.metadata.annotations["secrets.infisical.com/version"] // ""'
}

secrets_hold() { # value
  [[ "$(secret_value "$PG_SECRET" POSTGRES_PASSWORD)" == "$1" ]] \
    && [[ "$(secret_value "$APP_SECRET" DATABASE_URL)" == *":$1@"* ]]
}

# The operator polls every refreshInterval (60s here), since instant updates are paid. Its predicate
# reconciles on an annotation change, so this shortens the wait. targets[].metadata keeps the
# annotation off the Secrets.
nudge_operator() {
  kc -n "$NS" annotate infisicalstaticsecrets.secrets.infisical.com "$PG_SECRET" "$APP_SECRET" \
    "plane-platform/rotation-nudge=$(date +%s)" --overwrite >/dev/null
}

no_value_count() { # A template that once rendered with a missing key leaves this literal (operator #121)
  kc -n "$NS" get secrets -o json | jq '[.items[] | select(.metadata.name | startswith("plane-"))
    | (.data // {}) | to_entries[] | .value | @base64d | select(contains("<no value>"))] | length'
}

# ---- Postgres ----------------------------------------------------------------------------------
# Exit 0: accepted. 1: rejected. 2: could not tell.
# Over the pod IP on purpose. The image's pg_hba.conf trusts the socket and 127.0.0.1, so a login
# there succeeds with any password and would prove nothing. Only other addresses reach scram-sha-256.
# shellcheck disable=SC2016  # Expanded by the shell in the pod.
pg_login() { # password, read by the shell in the pod from stdin
  local out rc=0
  out="$(printf '%s\n' "$1" | kc -n "$NS" exec -i "$PG_POD" -c "$PG_CONTAINER" -- sh -c \
    'IFS= read -r PGPASSWORD; export PGPASSWORD PGCONNECT_TIMEOUT=5; exec psql -X -w -h "$0" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select 1"' \
    "$PG_POD_IP" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 && "$out" == 1 ]]; then return 0; fi
  case "$out" in
    *"password authentication failed"*) return 1 ;;
    *) return 2 ;;
  esac
}

pg_accepts() { # password. Fails closed on "could not tell".
  local rc=0
  pg_login "$1" || rc=$?
  [[ "$rc" -eq 0 ]]
}

# Over the socket, which the image trusts, so this works whichever password is current. The statement
# arrives on stdin, and these settings keep it out of the server log even if it fails.
# shellcheck disable=SC2016  # Expanded by the shell in the pod.
pg_set_password() { # password
  local user
  user="$(secret_value "$PG_SECRET" POSTGRES_USER)"
  [[ "$user" =~ ^[a-z_][a-z0-9_]*$ ]] || die "unexpected role name in $PG_SECRET"
  [[ "$1" =~ ^[0-9a-f]+$ ]] || die "refusing to put a non-hex password into SQL"
  printf "SET log_statement = 'none';\nSET log_min_error_statement = 'panic';\nALTER ROLE \"%s\" PASSWORD '%s';\n" "$user" "$1" \
    | kc -n "$NS" exec -i "$PG_POD" -c "$PG_CONTAINER" -- sh -c \
      'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
}

# ---- Workloads ---------------------------------------------------------------------------------
# Newline-separated "<kind>/<name> <auto-reload value>" of everything that reads DATABASE_URL.
discover_consumers() {
  kc -n "$NS" get deployments,statefulsets -o json | jq -r --arg secret "$APP_SECRET" '
    .items[]
    | select([.spec.template.spec.containers[].envFrom[]?.secretRef.name?] | index($secret))
    | "\(.kind | ascii_downcase)/\(.metadata.name) \(.metadata.annotations["secrets.infisical.com/auto-reload"] // "false")"'
}

# The operator hashes the target name into the annotation key, first 16 bytes of its sha256.
etag_annotation() {
  printf 'secrets.infisical.com/managed-secret.%s' \
    "$(printf '%s' "$APP_SECRET" | openssl dgst -sha256 -r | cut -c1-32)"
}

workload_etag() { # kind/name
  kc -n "$NS" get "$1" -o json | jq -r --arg key "$(etag_annotation)" '.spec.template.metadata.annotations[$key] // ""'
}

# Taken before the first write, so a rollback can tell "never left the starting version" apart.
journal_versions() {
  local w
  secret_version > "$JOURNAL/version"
  for w in $WORKLOADS; do workload_etag "$w" > "$JOURNAL/etag.${w##*/}"; done
}

# State, not history: true when each workload's pod template names the Secret's current version. The
# second test covers a rollback before the operator ever synced: nothing changed, so nothing restarts,
# and the template of a workload created after its Secret may carry no etag at all.
workloads_propagated() {
  local want w etag
  want="$(secret_version)"
  [[ -n "$want" ]] || return 1
  for w in $WORKLOADS; do
    etag="$(workload_etag "$w")"
    [[ "$etag" != "$want" ]] || continue
    if [[ "$want" == "$(cat "$JOURNAL/version")" && "$etag" == "$(cat "$JOURNAL/etag.${w##*/}")" ]]; then continue; fi
    return 1
  done
}

propagated_within() { # seconds
  local deadline=$((SECONDS + $1))
  until workloads_propagated; do
    [[ $SECONDS -lt $deadline ]] || return 1
    sleep 3
  done
}

generations() {
  local w
  for w in $WORKLOADS; do
    printf '%s=%s ' "$w" "$(kc -n "$NS" get "$w" -o jsonpath='{.metadata.generation}')"
  done
}

# ---- Application probe -------------------------------------------------------------------------
db_probe() {
  local out code
  out="$(curl -s --max-time 5 -w '\n%{http_code}' "$DB_PROBE_URL" 2>/dev/null || true)"
  code="${out##*$'\n'}"
  [[ "$code" == 404 && "$out" == *"does not exist"* ]]
}

# Ends with this script. A SIGKILL runs no trap, and nothing else would stop this loop, which would go on spending the
# anonymous rate limit for good. In a subshell $$ is still the script's pid.
start_probe_loop() {
  (
    trap - EXIT
    while kill -0 "$$" 2>/dev/null; do
      if db_probe; then printf '%s ok\n' "$(date +%s)"; else printf '%s fail\n' "$(date +%s)"; fi
      sleep 1
    done
  ) >>"$PROBE_LOG" 2>/dev/null &
  PROBE_PID=$!
  disown "$PROBE_PID" 2>/dev/null || true # No "Terminated" line when it is killed
}

report_error_window() {
  if [[ -n "$PROBE_PID" ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""
  fi
  local failed total first last
  total="$(wc -l <"$PROBE_LOG" | tr -d ' ')"
  failed="$(grep -c ' fail$' "$PROBE_LOG" || true)"
  first="$(awk '$2 == "fail" { print $1; exit }' "$PROBE_LOG")"
  last="$(awk '$2 == "fail" { v = $1 } END { print v }' "$PROBE_LOG")"
  if [[ -n "$first" ]]; then
    evidence INFO "error window: $((last - first + 1))s from first to last failed probe, $failed of $total probes failed"
  else
    evidence INFO "error window: none seen across $total probes"
  fi
}

# ---- Failure handling --------------------------------------------------------------------------
describe() { # value: which password it is, without saying what it is
  if [[ "$1" == "$(cat "$JOURNAL/new")" ]]; then
    printf new
  elif [[ "$1" == "$(cat "$JOURNAL/old")" ]]; then
    printf old
  else
    printf other
  fi
}

report_half_rotated() {
  local infisical_state secret_state postgres_state=unknown
  printf '\n' >&2
  warn "Rotation of $ENV stopped partway. What each side holds right now:"
  # A subshell, because ia_read_password dies on failure and this report must reach the end.
  infisical_state="$( (ia_read_password && describe "$IA_VALUE") 2>/dev/null || printf unknown)"
  secret_state="$(describe "$(secret_value "$PG_SECRET" POSTGRES_PASSWORD 2>/dev/null)")"
  if pg_accepts "$(cat "$JOURNAL/new")"; then
    postgres_state=new
  elif pg_accepts "$(cat "$JOURNAL/old")"; then
    postgres_state=old
  fi
  warn "  Infisical: $infisical_state    Secret $PG_SECRET: $secret_state    Postgres role: $postgres_state"
  warn "Plane connects with the value in its Secret once restarted, so it fails while Secret and role differ."
  warn "Finish it:  scripts/rotate.sh ENV=$ENV RESUME=yes"
  warn "Undo it:    scripts/rotate.sh ENV=$ENV ROLLBACK=yes"
  warn "Both values stay in $JOURNAL (mode 0600) until one of those succeeds."
}

# ---- Preflight ---------------------------------------------------------------------------------
preflight() {
  [[ -s "$MACHINE_FILE" ]] || die "$MACHINE_FILE is missing. Run scripts/infisical-bootstrap.sh."
  ia_load_admin
  PROJECT_ID="$(machine_value project_ids "$ENV")"
  ENV_SLUG="$(jq -er '.environment_slug' "$MACHINE_FILE")"

  kc -n "$NS" get pod "$PG_POD" >/dev/null || die "$PG_POD not found in $NS"
  PG_POD_IP="$(kc -n "$NS" get pod "$PG_POD" -o jsonpath='{.status.podIP}')"
  [[ -n "$PG_POD_IP" ]] || die "$PG_POD has no IP yet"
  kc -n "$NS" get infisicalstaticsecrets.secrets.infisical.com "$PG_SECRET" "$APP_SECRET" >/dev/null \
    || die "InfisicalStaticSecret $PG_SECRET and $APP_SECRET must exist in $NS"

  local consumers name annotation
  consumers="$(discover_consumers)"
  [[ -n "$consumers" ]] || die "nothing in $NS consumes $APP_SECRET"
  WORKLOADS=""
  while IFS=' ' read -r name annotation; do
    # An unannotated consumer would keep the old password until something restarted it.
    [[ "$annotation" == true ]] || die "$name consumes $APP_SECRET without secrets.infisical.com/auto-reload=true, so it would not roll"
    WORKLOADS="$WORKLOADS $name"
  done <<<"$consumers"
  case "$WORKLOADS" in
    *deployment/plane-api-wl*) ;;
    *) die "plane-api-wl does not consume $APP_SECRET. The Plane manifests are not what this script expects." ;;
  esac

  local stale
  stale="$(no_value_count)"
  [[ "$stale" == 0 ]] || die "$stale Secret values in $NS contain a literal <no value>. Fix the seed before rotating."

  # A negative control: if a random password logs in, the rejection proof below would mean nothing.
  local control_rc=0
  pg_login "$(openssl rand -hex 24)" || control_rc=$?
  case "$control_rc" in
    1) ;;
    0) die "Postgres accepted a random password over the pod IP, so old-value-rejected cannot be shown. Check pg_hba.conf." ;;
    *) die "could not complete a test login over the pod IP. Is $PG_POD ready?" ;;
  esac
}

# ---- The rotation ------------------------------------------------------------------------------
converge() { # target password, password being replaced
  local value="$1" replaced="$2" version_before pg_started keys_before
  ia_read_password
  version_before="$IA_VERSION"
  pg_started="$(kc -n "$NS" get pod "$PG_POD" -o jsonpath='{.status.startTime}')"
  keys_before="$(secret_value "$KEYS_SECRET" SECRET_KEY)"

  if [[ "$IA_VALUE" != "$value" ]]; then
    log "Writing the password to Infisical"
    ia_write_password "$value"
    ia_read_password
    [[ "$IA_VALUE" == "$value" ]] || die "Infisical does not hold the value just written"
  fi
  evidence PASS "Infisical $SECRET_NAME version $version_before -> $IA_VERSION"

  if ! secrets_hold "$value"; then
    log "Waiting for the operator to sync $PG_SECRET and $APP_SECRET"
    nudge_operator
    wait_for "${SYNC_TIMEOUT_SECONDS:-240}" "the operator to sync the new password" secrets_hold "$value"
  fi
  evidence PASS "operator synced $PG_SECRET and $APP_SECRET"

  # ALTER immediately after the sync: the operator has started rolling Plane by now, and those new
  # pods crash-loop until the role has this password (wait_for_migrations connects, under set -e).
  if ! pg_accepts "$value"; then
    log "Running ALTER ROLE in $PG_POD"
    pg_set_password "$value"
  fi
  pg_accepts "$value" || die "Postgres does not accept the new password after ALTER ROLE"
  evidence PASS "Postgres accepts the target password over TCP, where passwords are checked"

  local replaced_rc=0
  pg_login "$replaced" || replaced_rc=$?
  case "$replaced_rc" in
    1) evidence PASS "Postgres rejects the replaced password: password authentication failed" ;;
    0) die "Postgres still accepts the replaced password" ;;
    *) die "could not test the replaced password" ;;
  esac

  log "Waiting for the operator to restart:$WORKLOADS"
  local w
  if ! propagated_within 120; then
    # Two causes, neither fixed by waiting: the operator patches only in the reconcile that changed the
    # Secret, so a failed patch is never retried, and Argo CD may have stripped the annotation (critique
    # gate 8). Restarting by hand gets the pods onto the new Secret either way.
    evidence INFO "operator did not mark every pod template within 120s: restarting them directly"
    for w in $WORKLOADS; do kc -n "$NS" rollout restart "$w" >/dev/null; done
  fi
  for w in $WORKLOADS; do
    kc -n "$NS" rollout status "$w" --timeout="${ROLLOUT_TIMEOUT_SECONDS:-600}s" >/dev/null \
      || die "$w did not finish rolling out"
    evidence PASS "$w rolled out with the new Secret version"
  done

  # A 404 from this route needs a database login made with what the pods now hold.
  wait_for 120 "Plane to answer through a new database connection" db_probe
  evidence PASS "Plane API answered a database-backed request after the rollout"

  if [[ "$(kc -n "$NS" get pod "$PG_POD" -o jsonpath='{.status.startTime}')" == "$pg_started" ]]; then
    evidence PASS "Postgres pod was not restarted"
  else
    evidence FAIL "Postgres pod restarted during rotation. It must not carry auto-reload."
  fi

  if [[ "$(secret_value "$KEYS_SECRET" SECRET_KEY)" == "$keys_before" ]]; then
    evidence PASS "SECRET_KEY unchanged"
  else
    die "SECRET_KEY changed during rotation. This script did not write it: investigate at once."
  fi

  # Critique gate 8: a self-heal fight with the operator's template annotation would keep rolling Plane.
  local gen_a gen_b
  gen_a="$(generations)"
  sleep "${STABILITY_SECONDS:-20}"
  gen_b="$(generations)"
  if [[ "$gen_a" == "$gen_b" ]]; then
    evidence PASS "workload generations stable for ${STABILITY_SECONDS:-20}s, no sync loop seen"
  else
    evidence FAIL "workload generations are still moving: suspect Argo CD reverting the operator's annotation"
  fi
}

finish() {
  rm -rf "$JOURNAL"
  JOURNAL_ACTIVE=""
}

preflight

if [[ -d "$JOURNAL" ]]; then
  JOURNAL_ACTIVE=yes
  [[ -s "$JOURNAL/old" && -s "$JOURNAL/new" && -f "$JOURNAL/version" ]] \
    || die "$JOURNAL is incomplete, so nothing was written to Infisical yet. Check that Infisical and Postgres agree, then remove it."
  if [[ "$ROLLBACK" == yes ]]; then
    start_probe_loop
    evidence INFO "$ENV: rolling back a stopped rotation"
    converge "$(cat "$JOURNAL/old")" "$(cat "$JOURNAL/new")"
  elif [[ "$RESUME" == yes ]]; then
    start_probe_loop
    evidence INFO "$ENV: resuming a stopped rotation"
    converge "$(cat "$JOURNAL/new")" "$(cat "$JOURNAL/old")"
  else
    die "a rotation of $ENV is already in progress. Choose RESUME=yes or ROLLBACK=yes."
  fi
else
  [[ "$RESUME" != yes && "$ROLLBACK" != yes ]] || die "no stopped rotation of $ENV to act on: $JOURNAL does not exist"

  ia_read_password
  old="$IA_VALUE"
  # Starting from a pair that already disagrees would hide the cause and make rollback wrong.
  pg_accepts "$old" || die "Postgres does not accept the current Infisical value, so they had already diverged. Fix that first."
  secrets_hold "$old" || die "$PG_SECRET and $APP_SECRET do not match Infisical yet. Wait for the operator, or check its status."
  db_probe || die "Plane API is not healthy before the rotation ($DB_PROBE_URL). Rotating now could not show anything."
  evidence PASS "preflight: Infisical, Secrets and Postgres agree; Plane answers; negative control rejected"

  new="$(openssl rand -hex 24)"
  # Journal first: if anything after this fails, both values are recoverable.
  mkdir -p "$JOURNAL"
  chmod 700 "$JOURNAL"
  printf '%s' "$old" > "$JOURNAL/old"
  printf '%s' "$new" > "$JOURNAL/new"
  chmod 600 "$JOURNAL/old" "$JOURNAL/new"
  journal_versions
  JOURNAL_ACTIVE=yes

  start_probe_loop
  evidence INFO "$ENV: rotating $SECRET_NAME"
  converge "$new" "$old"
fi

report_error_window
finish
evidence PASS "$ENV: done. Evidence in $EVIDENCE"

if [[ "${SKIP_BACKUP:-}" == yes ]]; then
  evidence INFO "SKIP_BACKUP=yes: no Infisical backup, so older dumps hold the previous $SECRET_NAME"
elif "$ROOT/scripts/backup.sh" infisical; then
  evidence PASS "Infisical backed up, so the newest dump holds the new $SECRET_NAME"
else
  evidence FAIL "the rotation is complete and proven, but the Infisical backup after it failed. Run: make backup ENV=infisical. Until then every dump holds the previous $SECRET_NAME"
  exit 3
fi
