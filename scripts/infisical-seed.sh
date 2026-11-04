#!/usr/bin/env bash
# Write each environment's Plane secrets to Infisical, generating only what does not exist yet.
# Infisical is the single copy: values are generated in memory, sent, and never stored here, printed
# or passed in argv. Existing values are never read or overwritten, so rerunning is always safe.
#
# Costs 3 requests per environment (list, batch create, verify) against the unlicensed limit of 40
# secret requests per minute, which is why one batch rather than nine single writes.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

guard_disk
need_commands curl jq openssl
ia_init
trap ia_cleanup EXIT
ia_load_admin
[[ -s "$MACHINE_FILE" ]] || die "$MACHINE_FILE is missing. Run scripts/infisical-bootstrap.sh."

REQUIRED_SECRETS="PG_USER PG_PASSWORD PG_DB RABBITMQ_USER RABBITMQ_PASSWORD SILO_ACCESS_KEY SILO_SECRET_KEY SECRET_KEY LIVE_SERVER_SECRET_KEY"
ENV_SLUG="$(jq -er '.environment_slug' "$MACHINE_FILE")"

# Hex throughout, because the chart and the operator templates do not URL-encode. User and database
# names are identifiers: a generated hex name could start with a digit and need quoting in every
# SQL statement, so they keep the chart's default.
generate_value() {
  case "$1" in
    PG_USER | PG_DB | RABBITMQ_USER) printf 'plane' ;;
    PG_PASSWORD | RABBITMQ_PASSWORD) openssl rand -hex 24 ;;
    SILO_ACCESS_KEY) openssl rand -hex 10 ;;
    SILO_SECRET_KEY) openssl rand -hex 20 ;;
    SECRET_KEY | LIVE_SERVER_SECRET_KEY) openssl rand -hex 32 ;;
    *) die "no generator for $1" ;;
  esac
}

list_keys() { # project id: secret names, one per line. Values stay on the server.
  ia_request GET "/api/v4/secrets?projectId=$1&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=false&expandSecretReferences=false&includeImports=false&recursive=false"
  [[ "$IA_STATUS" == 200 ]] || die "listing secrets in project $1 returned HTTP $IA_STATUS: $(ia_error)"
  printf '%s' "$IA_BODY" | jq -r '.secrets[].secretKey'
}

missing_from() { # newline-separated existing names
  local name existing=$'\n'"$1"$'\n'
  for name in $REQUIRED_SECRETS; do
    case "$existing" in
      *$'\n'"$name"$'\n'*) ;;
      *) printf '%s ' "$name" ;;
    esac
  done
}

seed_environment() {
  local env="$1" project existing missing name lines="" body
  project="$(machine_value project_ids "$env")"
  existing="$(list_keys "$project")"
  missing="$(missing_from "$existing")"
  if [[ -z "$missing" ]]; then
    ok "$env: all secrets already exist, nothing written"
    return 0
  fi

  for name in $missing; do
    lines+="$name"$'\t'"$(generate_value "$name")"$'\n'
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

  missing="$(missing_from "$(list_keys "$project")")"
  [[ -z "$missing" ]] || die "$env: still missing after the write: $missing"
  ok "$env: secrets written"
}

seed_environment dev
seed_environment prod-sim
