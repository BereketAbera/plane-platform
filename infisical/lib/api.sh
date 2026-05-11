#!/usr/bin/env bash
# Helpers for the Infisical scripts. Source after scripts/lib/common.sh; do not execute.
#
# Secrets must stay out of argv, stdout and shell history. So tokens reach curl through a 0600
# header file, JSON bodies through stdin, and jq takes values on stdin rather than with --arg.
set +x

INFISICAL_URL="${INFISICAL_URL:-http://infisical.localhost}"
SECRET_ZERO_DIR="$LOCAL_DIR/secret-zero"
ADMIN_FILE="$SECRET_ZERO_DIR/infisical-admin.json"
ADMIN_PASSWORD_FILE="$SECRET_ZERO_DIR/infisical-admin-password"
MACHINE_FILE="$SECRET_ZERO_DIR/infisical-machine.json"
export SECRET_ZERO_DIR ADMIN_FILE ADMIN_PASSWORD_FILE MACHINE_FILE

IA_TMP=""
IA_STATUS=""
IA_BODY=""

ia_init() {
  umask 077
  mkdir -p "$SECRET_ZERO_DIR"
  chmod 700 "$SECRET_ZERO_DIR"
  IA_TMP="$(mktemp -d "$SECRET_ZERO_DIR/.tmp.XXXXXX")"
  : > "$IA_TMP/auth"
}

ia_cleanup() {
  if [[ -n "$IA_TMP" ]]; then rm -rf "$IA_TMP"; fi
}

need_commands() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found. Run: make setup"
  done
}

env_namespace() {
  case "$1" in
    dev | prod-sim) printf 'plane-%s' "$1" ;;
    *) die "unknown environment '$1': expected dev or prod-sim" ;;
  esac
}

# One request. Curl's own failure becomes status 000.
ia_curl() {
  local method="$1" path="$2" body="$3"
  if [[ -n "$body" ]]; then
    curl -sS --max-time 60 -X "$method" -D "$IA_TMP/headers" -o "$IA_TMP/body" -w '%{http_code}' \
      -H 'Accept: application/json' -H 'Content-Type: application/json' -H "@$IA_TMP/auth" \
      --data-binary @- "$INFISICAL_URL$path" <<<"$body"
  else
    curl -sS --max-time 60 -X "$method" -D "$IA_TMP/headers" -o "$IA_TMP/body" -w '%{http_code}' \
      -H 'Accept: application/json' -H "@$IA_TMP/auth" "$INFISICAL_URL$path"
  fi
}

# ia_request METHOD PATH [JSON_BODY] sets IA_STATUS and IA_BODY. IA_BODY can hold secret values
# (the v4 secrets routes echo them), so callers never print it, only ia_error.
# Retries only 429, because a throttled request was never processed. Unlicensed self-hosted allows
# 40 secret requests per minute per client IP.
ia_request() {
  local method="$1" path="$2" body="${3-}" attempt retry_after
  for attempt in 1 2 3 4 5 6; do
    rm -f "$IA_TMP/body" "$IA_TMP/headers"
    IA_STATUS="$(ia_curl "$method" "$path" "$body" 2>/dev/null)" || IA_STATUS=000
    IA_BODY=""
    if [[ -f "$IA_TMP/body" ]]; then IA_BODY="$(cat "$IA_TMP/body")"; fi
    [[ "$IA_STATUS" == 429 ]] || return 0
    retry_after="$(awk 'tolower($1) == "retry-after:" { print $2 + 0 }' "$IA_TMP/headers" 2>/dev/null || true)"
    if [[ -z "$retry_after" || "$retry_after" -le 0 ]]; then retry_after=15; fi
    warn "Infisical rate limit, attempt $attempt: waiting ${retry_after}s"
    sleep "$retry_after"
  done
}

# The server's own message, for error reports. Validation errors name fields, not values.
ia_error() {
  printf '%s' "$IA_BODY" | jq -r '.message // .error // "no message in the response"' 2>/dev/null \
    | cut -c1-300 || true
}

# Loads the admin token for later requests. It carries a JWT exp capped at 90 days, and bootstrap
# is one-shot, so an expired token cannot be fetched again the same way. See infisical/README.md.
ia_load_admin() {
  local token exp now
  [[ -s "$ADMIN_FILE" ]] || die "$ADMIN_FILE is missing. Run scripts/infisical-bootstrap.sh first."
  token="$(jq -er '.token' "$ADMIN_FILE")" || die "$ADMIN_FILE holds no token"
  printf 'Authorization: Bearer %s\n' "$token" > "$IA_TMP/auth"
  exp="$(printf '%s' "$token" | jq -Rr 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
    | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson | .exp // 0' 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "$exp" -gt 0 && "$exp" -le "$now" ]]; then
    die "the Infisical admin token has expired. infisical/README.md, section Recovery, says how to replace it."
  elif [[ "$exp" -gt 0 && "$exp" -le $((now + 604800)) ]]; then
    warn "the Infisical admin token expires in under 7 days. See infisical/README.md, section Recovery."
  fi
}

ia_admin_token() {
  jq -er '.token' "$ADMIN_FILE"
}

machine_value() { # field env, for example: project_ids dev
  jq -er --arg env "$2" --arg field "$1" '.[$field][$env]' "$MACHINE_FILE" \
    || die "$MACHINE_FILE has no $1 for $2. Run scripts/infisical-bootstrap.sh."
}
