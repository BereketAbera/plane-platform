#!/usr/bin/env bash
# Check the six Secrets the operators render in each Plane namespace against contract section 8.
#
#   infisical/tests/rendered-secrets.sh             both environments
#   infisical/tests/rendered-secrets.sh dev         one environment, and no comparison across the two
#
# Exit status as in scripts/test.sh: 0 everything passed, 1 something failed, 2 nothing failed but a
# namespace could not be read. Prints key names and verdicts, never a value. Values are compared in
# memory only, in this shell.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# Hosted production opts in here. Without the variable this does nothing. See scripts/hosted/target.sh.
# shellcheck source=../../scripts/hosted/target.sh
if [[ -n "${WAYLINE_TARGET:-}" ]]; then source "$ROOT/scripts/hosted/target.sh"; fi
# shellcheck source=../lib/api.sh
source "$ROOT/infisical/lib/api.sh"

need_commands jq kubectl

ENVIRONMENTS="${*:-${WAYLINE_ENVIRONMENTS:-dev prod-sim}}"
FAILED=0
BLOCKED=0

row() { # verdict what [detail]
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
  esac
  printf '%-8s %-66s %s\n' "$1" "$2" "${3:-}"
}

# Shell functions, not commands, so the values compared here never reach an argv.
expect() { # what test [args...]
  local what="$1"
  shift
  if "$@"; then row PASS "$what"; else row FAIL "$what"; fi
}
same() { [[ "$1" == "$2" ]]; }
differ() { [[ "$1" != "$2" ]]; }
none() { [[ -z "$1" ]]; }

expected_keys() { # secret: sorted, comma-separated
  case "$1" in
    plane-app-env) printf 'AMQP_URL,DATABASE_URL,REDIS_URL' ;;
    plane-app-keys) printf 'LIVE_SERVER_SECRET_KEY,SECRET_KEY' ;;
    plane-live-env) printf 'REDIS_URL' ;;
    plane-doc-store) printf 'AWS_ACCESS_KEY_ID,AWS_S3_BUCKET_NAME,AWS_S3_ENDPOINT_URL,AWS_SECRET_ACCESS_KEY,FILE_SIZE_LIMIT,MINIO_ROOT_PASSWORD,MINIO_ROOT_USER,USE_MINIO' ;;
    plane-pgdb) printf 'POSTGRES_DB,POSTGRES_PASSWORD,POSTGRES_USER' ;;
    plane-rabbitmq) printf 'RABBITMQ_DEFAULT_PASS,RABBITMQ_DEFAULT_USER' ;;
    *) die "no contract row for $1" ;;
  esac
}

value() { # json key: decoded value, in memory only
  printf '%s' "$1" | jq -r --arg k "$2" '.data[$k] // empty | @base64d'
}

check_environment() {
  local env="$1" ns name json keys bad cr_status dir owned
  ns="$(env_namespace "$env")"
  dir="$WORK/$env"
  mkdir -p "$dir"
  for name in plane-app-env plane-app-keys plane-live-env plane-doc-store plane-pgdb plane-rabbitmq; do
    if ! json="$(kc -n "$ns" get secret "$name" -o json 2>/dev/null)"; then
      row FAIL "$ns/$name exists" "not found"
      continue
    fi
    printf '%s' "$json" > "$dir/$name"
    keys="$(printf '%s' "$json" | jq -r '.data // {} | keys | sort | join(",")')"
    if [[ "$keys" == "$(expected_keys "$name")" ]]; then
      row PASS "$ns/$name holds exactly the contract's keys" "$keys"
    else
      row FAIL "$ns/$name holds exactly the contract's keys" "got $keys"
    fi
    # Operator #121: a template over a missing key renders this literally and reports success.
    bad="$(printf '%s' "$json" | jq -r '[.data // {} | to_entries[] | select((.value | @base64d) == "" or ((.value | @base64d) | contains("<no value>"))) | .key] | join(",")')"
    expect "$ns/$name has no empty or '<no value>' value $bad" none "$bad"

    owned="$(printf '%s' "$json" | jq -r --arg cr "$name" '.metadata.ownerReferences // [] | any(.kind == "InfisicalStaticSecret" and .name == $cr)')"
    expect "$ns/$name is owned by its InfisicalStaticSecret" same "$owned" true
    # Copied tracking data would make Argo CD treat the Secret as its own.
    bad="$(printf '%s' "$json" | jq -r '[(.metadata.annotations // {} | keys[]), (.metadata.labels // {} | keys[])] | map(select(startswith("argocd.argoproj.io/") or . == "app.kubernetes.io/instance")) | join(",")')"
    expect "$ns/$name carries no Argo CD tracking data $bad" none "$bad"

    cr_status="$(kc -n "$ns" get infisicalstaticsecret "$name" -o json 2>/dev/null \
      | jq -r 'if .status.error == false and .status.observedGeneration == .metadata.generation then "ok" else "not-ok" end')" || cr_status=missing
    expect "$ns InfisicalStaticSecret/$name reconciled at this generation" same "$cr_status" ok
  done

  local pgdb app docs rabbit keys_json
  pgdb="$(cat "$dir/plane-pgdb" 2>/dev/null || true)"
  app="$(cat "$dir/plane-app-env" 2>/dev/null || true)"
  docs="$(cat "$dir/plane-doc-store" 2>/dev/null || true)"
  rabbit="$(cat "$dir/plane-rabbitmq" 2>/dev/null || true)"
  keys_json="$(cat "$dir/plane-app-keys" 2>/dev/null || true)"
  if [[ -z "$pgdb" || -z "$app" || -z "$docs" || -z "$rabbit" || -z "$keys_json" ]]; then
    row BLOCKED "$ns value rules" "a Secret is missing, reported above"
    return 0
  fi

  # Fixed values from the contract. Not secret, so they can be named.
  expect "$ns plane-doc-store USE_MINIO=1" same "$(value "$docs" USE_MINIO)" 1
  expect "$ns plane-doc-store AWS_S3_BUCKET_NAME=uploads" same "$(value "$docs" AWS_S3_BUCKET_NAME)" uploads
  expect "$ns plane-doc-store AWS_S3_ENDPOINT_URL=http://plane-minio:9000" same "$(value "$docs" AWS_S3_ENDPOINT_URL)" "http://plane-minio:9000"
  expect "$ns plane-doc-store FILE_SIZE_LIMIT=5242880, in bytes" same "$(value "$docs" FILE_SIZE_LIMIT)" 5242880

  # Hex, because neither the chart nor the templates URL-encode.
  local secret_value non_hex="" pair
  for pair in \
    plane-pgdb:POSTGRES_PASSWORD plane-rabbitmq:RABBITMQ_DEFAULT_PASS plane-doc-store:MINIO_ROOT_PASSWORD \
    plane-doc-store:MINIO_ROOT_USER plane-app-keys:SECRET_KEY plane-app-keys:LIVE_SERVER_SECRET_KEY; do
    secret_value="$(value "$(cat "$dir/${pair%%:*}")" "${pair#*:}")"
    if [[ ! "$secret_value" =~ ^[0-9a-f]+$ ]]; then non_hex="$non_hex ${pair#*:}"; fi
  done
  expect "$ns generated values are all hex$non_hex" none "$non_hex"

  # One source per shared value. Each Secret takes it from the same flat Infisical key.
  local password user db url rabbit_user rabbit_pass amqp
  password="$(value "$pgdb" POSTGRES_PASSWORD)"
  user="$(value "$pgdb" POSTGRES_USER)"
  db="$(value "$pgdb" POSTGRES_DB)"
  url="$(value "$app" DATABASE_URL)"
  expect "$ns DATABASE_URL matches plane-pgdb and names its own namespace" \
    same "$url" "postgresql://$user:$password@plane-pgdb.$ns.svc.cluster.local/$db"
  rabbit_user="$(value "$rabbit" RABBITMQ_DEFAULT_USER)"
  rabbit_pass="$(value "$rabbit" RABBITMQ_DEFAULT_PASS)"
  amqp="$(value "$app" AMQP_URL)"
  expect "$ns AMQP_URL matches plane-rabbitmq and names its own namespace" \
    same "$amqp" "amqp://$rabbit_user:$rabbit_pass@plane-rabbitmq.$ns.svc.cluster.local/"
  expect "$ns Silo user is also the S3 access key" same "$(value "$docs" MINIO_ROOT_USER)" "$(value "$docs" AWS_ACCESS_KEY_ID)"
  expect "$ns Silo password is also the S3 secret key" same "$(value "$docs" MINIO_ROOT_PASSWORD)" "$(value "$docs" AWS_SECRET_ACCESS_KEY)"
  expect "$ns REDIS_URL names its own namespace" same "$(value "$app" REDIS_URL)" "redis://plane-redis.$ns.svc.cluster.local:6379/"
  expect "$ns REDIS_URL agrees in plane-app-env and plane-live-env" \
    same "$(value "$app" REDIS_URL)" "$(value "$(cat "$dir/plane-live-env" 2>/dev/null || true)" REDIS_URL)"
}

check_across() { # nothing shared between the environments
  local pair a b
  for pair in \
    plane-pgdb:POSTGRES_PASSWORD plane-rabbitmq:RABBITMQ_DEFAULT_PASS plane-doc-store:MINIO_ROOT_USER \
    plane-doc-store:MINIO_ROOT_PASSWORD plane-app-keys:SECRET_KEY plane-app-keys:LIVE_SERVER_SECRET_KEY; do
    a="$(value "$(cat "$WORK/dev/${pair%%:*}" 2>/dev/null || true)" "${pair#*:}")"
    b="$(value "$(cat "$WORK/prod-sim/${pair%%:*}" 2>/dev/null || true)" "${pair#*:}")"
    if [[ -z "$a" || -z "$b" ]]; then
      row BLOCKED "dev and prod-sim differ in ${pair#*:}" "missing in one environment"
    else
      expect "dev and prod-sim differ in ${pair#*:}" differ "$a" "$b"
    fi
  done
}

umask 077
WORK="$(mktemp -d "$LOCAL_DIR/.rendered-secrets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for env in $ENVIRONMENTS; do
  log "$env"
  set +e
  check_environment "$env"
  set -e
done
if [[ "$ENVIRONMENTS" == *dev*prod-sim* ]]; then
  log "Across environments"
  set +e
  check_across
  set -e
fi

if [[ "$FAILED" -gt 0 ]]; then
  log "rendered secrets: $FAILED FAILED, $BLOCKED BLOCKED"
  exit 1
elif [[ "$BLOCKED" -gt 0 ]]; then
  log "rendered secrets: $BLOCKED BLOCKED, none failed. BLOCKED is not a pass."
  exit 2
fi
ok "rendered secrets: every row passed"
