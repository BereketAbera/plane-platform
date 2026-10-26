#!/usr/bin/env bash
# Write each environment's secrets to Infisical, generating only what does not exist yet: Plane's in each
# of its environments, and on hosted production Frameflow's in its own project too. Infisical is the
# single copy: values are generated in memory, sent, and never stored here, printed or passed in argv.
# Existing values are never read or overwritten, so rerunning is always safe.
#
# Costs 3 requests per environment: list, batch create, verify.
#
# SEED_VERIFY_ONLY=yes writes nothing and fails if a secret is missing. That is restored mode: a new
# value there would not match the data about to be restored.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# Hosted production opts in here. Without the variable this does nothing. See scripts/hosted/target.sh.
# shellcheck source=hosted/target.sh
if [[ -n "${WAYLINE_TARGET:-}" ]]; then source "$ROOT/scripts/hosted/target.sh"; fi
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

guard_disk
need_commands curl jq openssl
ia_init
trap ia_cleanup EXIT
ia_load_admin
[[ -s "$MACHINE_FILE" ]] || die "$MACHINE_FILE is missing. Run scripts/infisical-bootstrap.sh."

ENV_SLUG="$(jq -er '.environment_slug' "$MACHINE_FILE")"

# Each environment's own keys. Plane's are the same in every environment it runs in, here and on hosted production.
PLANE_SECRETS="PG_USER PG_PASSWORD PG_DB RABBITMQ_USER RABBITMQ_PASSWORD SILO_ACCESS_KEY SILO_SECRET_KEY SECRET_KEY LIVE_SERVER_SECRET_KEY"
# Frameflow's project, which holds Hatchet's too. Not HATCHET_CLIENT_TOKEN: Hatchet mints that once it runs, and
# scripts/hosted/frameflow-hatchet-token.sh writes it.
FRAMEFLOW_SECRETS="WORKER_CALLBACK_SECRET OWNER_SESSION_SECRET SILO_ROOT_USER SILO_ROOT_PASSWORD S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BACKUP_ACCESS_KEY_ID S3_BACKUP_SECRET_ACCESS_KEY HATCHET_PG_USER HATCHET_PG_DB HATCHET_PG_PASSWORD HATCHET_ADMIN_PASSWORD HATCHET_COOKIE_SECRETS"

# The environment's keys, then what HOSTED_SEED_FROM_FILES gives it from a file. Space-separated.
required_secrets() { # env
  local names pair
  case "$1" in
    dev | prod-sim | prod) names="$PLANE_SECRETS" ;;
    frameflow) names="$FRAMEFLOW_SECRETS" ;;
    *) die "no list of secrets for environment $1" ;;
  esac
  for pair in ${HOSTED_SEED_FROM_FILES:-}; do
    if [[ "${pair%%:*}" == "$1" ]]; then names="$names ${pair#*:}"; fi
  done
  printf '%s' "$names"
}

# Hex throughout, because the chart and the operator templates do not URL-encode. User and database
# names are identifiers: a generated hex name could start with a digit and need quoting in every
# SQL statement, so they keep the chart's default.
plane_value() {
  case "$1" in
    PG_USER | PG_DB | RABBITMQ_USER) printf 'plane' ;;
    PG_PASSWORD | RABBITMQ_PASSWORD) openssl rand -hex 24 ;;
    SILO_ACCESS_KEY) openssl rand -hex 10 ;;
    SILO_SECRET_KEY) openssl rand -hex 20 ;;
    SECRET_KEY | LIVE_SERVER_SECRET_KEY) openssl rand -hex 32 ;;
    *) die "no generator for $1" ;;
  esac
}

# A value the owner made once, from its file by name, so never in an argv. One line with no tab, because the
# request body is built a line to a value. None of these is generated here: nothing could make it again to match.
owner_file() { # path, and what makes it
  [[ -s "$1" ]] || die "$1 is missing. Run: $2"
  [[ "$(tr -d '\t\r\n' <"$1" | wc -c)" == "$(wc -c <"$1")" ]] || die "$1 holds a line break or a tab, which would become part of the value. Make it again: $2"
  cat "$1"
}

# Hex too, for the same reason: Hatchet's DATABASE_URL and the Silo setup take these through templates. Silo's
# user names are their access keys, so they are hex as Plane's Silo key is.
frameflow_value() {
  local hash block
  case "$1" in
    WORKER_CALLBACK_SECRET | OWNER_SESSION_SECRET) openssl rand -hex 32 ;;
    SILO_ROOT_USER | S3_ACCESS_KEY_ID | S3_BACKUP_ACCESS_KEY_ID) openssl rand -hex 10 ;;
    SILO_ROOT_PASSWORD | S3_SECRET_ACCESS_KEY | S3_BACKUP_SECRET_ACCESS_KEY | HATCHET_PG_PASSWORD) openssl rand -hex 24 ;;
    HATCHET_PG_USER | HATCHET_PG_DB) printf 'hatchet' ;;
    # Hatchet's seed refuses an admin password without an upper-case letter, a lower-case letter and a digit, or
    # outside 8 to 64 characters, and hex alone can lack the first: so a fixed start, and 51 in all.
    HATCHET_ADMIN_PASSWORD) { printf 'Ff1' && openssl rand -hex 24; } ;;
    # A hash key and a block key, one space between. The block key is an AES key, 16, 24 or 32 bytes, and Hatchet
    # stops at start on any other length: 32 hex characters are 32 bytes, and openssl rand -hex 32 would give 64.
    HATCHET_COOKIE_SECRETS)
      hash="$(openssl rand -hex 16)" && block="$(openssl rand -hex 16)" && printf '%s %s' "$hash" "$block"
      ;;
    # Made by scripts/hosted/frameflow-inputs.sh. The keysets must be the ones Hatchet's database was encrypted
    # with, and the owner holds the key whose sha256 this is.
    OWNER_TOKEN_SHA256 | HATCHET_MASTER_KEYSET | HATCHET_JWT_PRIVATE_KEYSET | HATCHET_JWT_PUBLIC_KEYSET)
      owner_file "$LOCAL_DIR/frameflow/$1" "make remote-frameflow-inputs TARGET=plane-prod"
      ;;
    *) die "no generator for $1 in frameflow" ;;
  esac
}

generate_value() { # env name
  case "$2" in
    # Hosted production's only: not generated, because GitHub issues it. Read from the file by name, so never in an argv.
    # Plane's project and Frameflow's each hold a copy, for their own ghcr-pull.
    GHCR_PULL_TOKEN)
      [[ -s "$LOCAL_DIR/ghcr-pull-token" ]] || die "$LOCAL_DIR/ghcr-pull-token is missing. Run: scripts/hosted/owner-inputs.sh ghcr"
      cat "$LOCAL_DIR/ghcr-pull-token"
      ;;
    *)
      case "$1" in
        dev | prod-sim | prod) plane_value "$2" ;;
        frameflow) frameflow_value "$2" ;;
        *) die "no generator for $2 in environment $1" ;;
      esac
      ;;
  esac
}

list_keys() { # project id: secret names, one per line. Values stay on the server.
  ia_request GET "/api/v4/secrets?projectId=$1&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=false&expandSecretReferences=false&includeImports=false&recursive=false"
  [[ "$IA_STATUS" == 200 ]] || die "listing secrets in project $1 returned HTTP $IA_STATUS: $(ia_error)"
  printf '%s' "$IA_BODY" | jq -r '.secrets[].secretKey'
}

missing_from() { # space-separated required names, newline-separated existing names
  local name existing=$'\n'"$2"$'\n'
  for name in $1; do
    case "$existing" in
      *$'\n'"$name"$'\n'*) ;;
      *) printf '%s ' "$name" ;;
    esac
  done
}

seed_environment() {
  local env="$1" required project existing missing name lines="" body
  required="$(required_secrets "$env")"
  project="$(machine_value project_ids "$env")"
  existing="$(list_keys "$project")"
  missing="$(missing_from "$required" "$existing")"
  if [[ -z "$missing" ]]; then
    ok "$env: all secrets already exist, nothing written"
    return 0
  fi
  if [[ "${SEED_VERIFY_ONLY:-}" == yes ]]; then
    die "$env: missing from the restored instance: $missing. Refusing to generate them, because new values would not match the data this backup belongs to. Is this the right Infisical backup?"
  fi

  for name in $missing; do
    lines+="$name"$'\t'"$(generate_value "$env" "$name")"$'\n'
  done
  # Through stdin, so generated values never reach an argv.
  body="$(printf '%s' "$lines" | jq -Rs --arg project "$project" --arg env_slug "$ENV_SLUG" '{
      projectId: $project,
      environment: $env_slug,
      secretPath: "/",
      secrets: [split("\n")[] | select(length > 0) | split("\t") | {secretKey: .[0], secretValue: .[1]}]
    }')"
  ia_request POST /api/v4/secrets/batch "$body"
  [[ "$IA_STATUS" == 200 ]] || die "$env: writing secrets returned HTTP $IA_STATUS: $(ia_error). Rerun: only what is missing gets written."

  missing="$(missing_from "$required" "$(list_keys "$project")")"
  [[ -z "$missing" ]] || die "$env: still missing after the write: $missing"
  ok "$env: secrets written"
}

for env_name in ${WAYLINE_ENVIRONMENTS:-dev prod-sim}; do
  seed_environment "$env_name"
done
