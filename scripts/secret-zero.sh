#!/usr/bin/env bash
# Generate the secrets that must exist before Infisical does, keep them in .local/secret-zero/, and
# apply them to the infisical namespace. Idempotent: existing files are reused and never replaced.
#
#   scripts/secret-zero.sh                          create what is missing, apply
#   REGENERATE=yes CONFIRM=yes scripts/secret-zero.sh   archive the current set and start over
#
# Losing ENCRYPTION_KEY makes every secret in the Infisical database unrecoverable, hence the care.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

guard_disk
need_commands kubectl openssl jq yq
umask 077
mkdir -p "$SECRET_ZERO_DIR"
chmod 700 "$SECRET_ZERO_DIR"
# Dumps hold password hashes and API tokens. This runs on every make up, ahead of any possible backup.
mkdir -p "$LOCAL_DIR/backups"
chmod 700 "$LOCAL_DIR/backups"

NS=infisical
DB_USER=infisical
DB_NAME=infisical
DB_HOST="infisical-postgres.$NS.svc.cluster.local"
REDIS_HOST="infisical-redis.$NS.svc.cluster.local"

cluster_value() { # secret key: prints the decoded value, or nothing
  kc -n "$NS" get secret "$1" -o json 2>/dev/null \
    | jq -r --arg key "$2" '.data[$key] // empty | @base64d' 2>/dev/null || true
}

generate_value() {
  case "$1" in
    ENCRYPTION_KEY) openssl rand -hex 16 ;; # The format Infisical documents
    AUTH_SECRET) openssl rand -base64 32 ;;
    *) openssl rand -hex 24 ;; # Hex, because these go unencoded into connection URLs
  esac
}

write_secret_file() { # name value. The rename keeps a crash from leaving a truncated key.
  local tmp="$SECRET_ZERO_DIR/.$1.tmp"
  printf '%s' "$2" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SECRET_ZERO_DIR/$1"
}

ensure_file() { # name secret key. A file lost while the cluster lives is recovered from the cluster.
  local name="$1" value=""
  if [[ -s "$SECRET_ZERO_DIR/$name" ]]; then
    chmod 600 "$SECRET_ZERO_DIR/$name"
    return 0
  fi
  if [[ "${REGENERATE:-}" != yes ]]; then value="$(cluster_value "$2" "$3")"; fi
  if [[ -n "$value" ]]; then
    warn "$name was missing locally: restored it from Secret $2"
  else
    value="$(generate_value "$name")"
    log "Generated $name"
  fi
  write_secret_file "$name" "$value"
}

if [[ "${REGENERATE:-}" == yes ]]; then
  [[ "${CONFIRM:-}" == yes ]] || die "REGENERATE=yes replaces ENCRYPTION_KEY, which makes an existing Infisical database unreadable. Add CONFIRM=yes to proceed."
  archive="$SECRET_ZERO_DIR/archive-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$archive"
  for name in ENCRYPTION_KEY AUTH_SECRET DB_PASSWORD REDIS_PASSWORD; do
    if [[ -f "$SECRET_ZERO_DIR/$name" ]]; then mv "$SECRET_ZERO_DIR/$name" "$archive/"; fi
  done
  warn "Previous secret zero moved to $archive. Postgres keeps its old password until its volume is recreated."
fi

ensure_file ENCRYPTION_KEY infisical-secrets ENCRYPTION_KEY
ensure_file AUTH_SECRET infisical-secrets AUTH_SECRET
ensure_file DB_PASSWORD infisical-db POSTGRES_PASSWORD
ensure_file REDIS_PASSWORD infisical-redis REDIS_PASSWORD

kc get namespace "$NS" >/dev/null 2>&1 \
  || die "namespace $NS does not exist yet (Terraform creates it). The files in $SECRET_ZERO_DIR are ready; rerun this script afterwards."

# Last line of defence against the scenario above: a key generated while the cluster was unreachable
# must not replace the one the database is encrypted with.
live_key="$(cluster_value infisical-secrets ENCRYPTION_KEY)"
if [[ -n "$live_key" && "$live_key" != "$(cat "$SECRET_ZERO_DIR/ENCRYPTION_KEY")" && "${CONFIRM:-}" != yes ]]; then
  die "the local ENCRYPTION_KEY differs from the one in Secret infisical-secrets. Refusing to replace it: the database is encrypted with the live one. Inspect both, then rerun with CONFIRM=yes if you are certain."
fi

apply_secret() { # name, KEY=VALUE lines on stdin. Stdin keeps values out of argv.
  kc create secret generic "$1" --namespace "$NS" --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | yq '.metadata.labels."plane-platform/managed-by" = "secret-zero"' \
    | kc apply --server-side --field-manager=secret-zero --force-conflicts -f - >/dev/null
  ok "applied Secret $NS/$1"
}

secret_fingerprint() {
  kc -n "$NS" get secret infisical-secrets -o json | jq -cS '.data' | openssl dgst -sha256 -r
}

before=""
if kc -n "$NS" get secret infisical-secrets >/dev/null 2>&1; then before="$(secret_fingerprint)"; fi

db_password="$(cat "$SECRET_ZERO_DIR/DB_PASSWORD")"
redis_password="$(cat "$SECRET_ZERO_DIR/REDIS_PASSWORD")"

printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=%s\n' "$DB_USER" "$db_password" "$DB_NAME" \
  | apply_secret infisical-db

printf 'REDIS_PASSWORD=%s\n' "$redis_password" | apply_secret infisical-redis

{
  printf 'ENCRYPTION_KEY=%s\n' "$(cat "$SECRET_ZERO_DIR/ENCRYPTION_KEY")"
  printf 'AUTH_SECRET=%s\n' "$(cat "$SECRET_ZERO_DIR/AUTH_SECRET")"
  printf 'DB_CONNECTION_URI=postgresql://%s:%s@%s:5432/%s\n' "$DB_USER" "$db_password" "$DB_HOST" "$DB_NAME"
  printf 'REDIS_URL=redis://default:%s@%s:6379\n' "$redis_password" "$REDIS_HOST"
} | apply_secret infisical-secrets

# rolloutOnEveryRender is off under Argo CD, so nothing else picks up a changed Secret. On first
# creation the pod is only waiting for the Secret and recovers without help.
if [[ -n "$before" && "$before" != "$(secret_fingerprint)" ]] && kc -n "$NS" get deployment infisical >/dev/null 2>&1; then
  log "infisical-secrets changed: restarting the Infisical Deployment"
  kc -n "$NS" rollout restart deployment/infisical >/dev/null
fi

ok "secret zero in place. Back up $SECRET_ZERO_DIR/ENCRYPTION_KEY outside this machine: nothing can recreate it."
