#!/usr/bin/env bash
# Helpers for the Infisical scripts. Source after scripts/lib/common.sh; do not execute.
#
# Secrets must stay out of argv, stdout and shell history. So tokens reach curl through a 0600
# header file, JSON bodies through stdin, and jq takes values on stdin rather than with --arg.
set +x

INFISICAL_URL="${INFISICAL_URL:-http://infisical.localhost}"
INFISICAL_ADMIN_EMAIL="${HOSTED_INFISICAL_ADMIN_EMAIL:-admin@wayline.localhost}"
SECRET_ZERO_DIR="$LOCAL_DIR/secret-zero"
ADMIN_FILE="$SECRET_ZERO_DIR/infisical-admin.json"
ADMIN_PASSWORD_FILE="$SECRET_ZERO_DIR/infisical-admin-password"
MACHINE_FILE="$SECRET_ZERO_DIR/infisical-machine.json"
# Where a person puts a token made by hand after a sign-in: one line, mode 0600. Checked against the server,
# moved into $ADMIN_FILE and removed.
ADMIN_TOKEN_DROP="$SECRET_ZERO_DIR/infisical-admin-token.new"
# One JSON line for each time $ADMIN_FILE was replaced: when, why, how, and the sha256 of the file before and
# after. A backup's checksum of $ADMIN_FILE proves which file it was taken with, and this says how the one in
# use descends from it. The old file goes to archive-token-<time>, where a restore can still find it by checksum.
ADMIN_TOKEN_LEDGER="$SECRET_ZERO_DIR/infisical-admin-replaced.log"
# A token this close to its end cannot be trusted to last through a restore or a long make up.
IA_TOKEN_MARGIN_SECONDS=3600
# Present only while `make restore-clean` is under way. Bootstrap reads it: on a fresh instance it must
# not create new credentials and values while a restore of the old ones is half done.
RESTORE_CLEAN_MARKER="$LOCAL_DIR/restore-clean.state"
export SECRET_ZERO_DIR ADMIN_FILE ADMIN_PASSWORD_FILE MACHINE_FILE RESTORE_CLEAN_MARKER INFISICAL_ADMIN_EMAIL ADMIN_TOKEN_DROP ADMIN_TOKEN_LEDGER

IA_TMP=""
IA_STATUS=""
IA_BODY=""

ia_init() {
  # Reached only through a port-forward. Anything else, the default above most of all, is the local cluster's Infisical, while the files
  # and kubeconfig these scripts hold are hosted production's. scripts/hosted/bootstrap.sh makes the port-forward and passes this.
  if [[ -n "${WAYLINE_TARGET:-}" && ! "$INFISICAL_URL" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then
    die "WAYLINE_TARGET=$WAYLINE_TARGET and INFISICAL_URL is $INFISICAL_URL, which is not its port-forward. Run this through scripts/hosted/bootstrap.sh, or pass INFISICAL_URL=http://127.0.0.1:<port>"
  fi
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
    *)
      # Only what scripts/hosted/target.sh opted in. Nothing local sets this.
      [[ "${WAYLINE_ENVIRONMENTS:-}" == "$1" ]] || die "unknown environment '$1': expected dev or prod-sim"
      printf 'plane-%s' "$1"
      ;;
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
# Retries only 429, because a throttled request was never processed. v0.167.6 registers its limiter
# only on Infisical Cloud, and 240 reads in 4s all passed here, so this path has not run for real.
# It stays for a later version or a licensed instance.
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

# Prints a JWT's claims as JSON, {} if it cannot be read. Reads stdin, so no token in argv. The signature is
# not checked: this says what a token claims, and only the server says whether to believe it.
ia_token_claims() {
  jq -Rr 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
    | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson' 2>/dev/null || echo '{}'
}

# Prints the admin token's JWT exp in epoch seconds, 0 if it has none. Reads stdin, so no token in argv.
ia_token_exp() {
  jq -Rr 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
    | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson | .exp // 0' 2>/dev/null || echo 0
}

ia_date() { # epoch seconds, as UTC
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

ia_file_token_exp() { # file. Like ia_token_exp, for a file in the shape of $ADMIN_FILE.
  local token
  token="$(jq -er '.token' "$1" 2>/dev/null)" || {
    echo 0
    return 0
  }
  printf '%s' "$token" | ia_token_exp
}

# Why $ADMIN_FILE cannot log in, by what the file itself says. Prints nothing if it can try, and only the
# server can say yes to that: see ia_token_accepted.
ia_admin_problem() {
  local exp
  if [[ ! -s "$ADMIN_FILE" ]]; then
    printf '%s is missing' "${ADMIN_FILE##*/}"
    return 0
  fi
  exp="$(ia_file_token_exp "$ADMIN_FILE")"
  if [[ "$exp" -gt 0 && "$exp" -le $(($(date +%s) + IA_TOKEN_MARGIN_SECONDS)) ]]; then
    printf 'the admin token ends at %s' "$(ia_date "$exp")"
  fi
}

# Loads the admin token for later requests. It carries a JWT exp capped at 90 days, and bootstrap
# is one-shot, so an expired token cannot be fetched again the same way. See infisical/README.md.
ia_load_admin() {
  local token exp now
  [[ -s "$ADMIN_FILE" ]] || die "$ADMIN_FILE is missing. scripts/infisical-bootstrap.sh brings it back if it can sign in. See infisical/README.md, section Recovery."
  token="$(jq -er '.token' "$ADMIN_FILE")" || die "$ADMIN_FILE holds no token"
  printf 'Authorization: Bearer %s\n' "$token" > "$IA_TMP/auth"
  exp="$(printf '%s' "$token" | ia_token_exp)"
  now="$(date +%s)"
  if [[ "$exp" -gt 0 && "$exp" -le "$now" ]]; then
    die "the Infisical admin token has expired. scripts/infisical-bootstrap.sh replaces it if it can sign in. See infisical/README.md, section Recovery."
  elif [[ "$exp" -gt 0 && "$exp" -le $((now + 604800)) ]]; then
    warn "the Infisical admin token expires in under 7 days. RENEW_ADMIN_TOKEN=yes scripts/infisical-bootstrap.sh replaces it. See infisical/README.md, section Recovery."
  fi
}

# True if the server takes whatever $IA_TMP/auth holds, for this organization.
ia_token_accepted() { # org-id
  ia_request GET "/api/v2/organizations/$1/identity-memberships?limit=1"
  [[ "$IA_STATUS" == 200 ]]
}

# ------ Replacing the admin token -------------------------------------------------------------------------
# The token expires and the file can be lost, and neither is a reason to lose the instance: the first admin's
# password, or a person who has it, can always make another. What the database holds decides, so these are for
# a server that answers, and they run after a restore, not before it.

# What is known locally about an organization. Prints JSON, with only the id if nothing else is known.
ia_org_json() { # org-id
  local file json
  for file in "$ADMIN_FILE" "$MACHINE_FILE"; do
    [[ -s "$file" ]] || continue
    json="$(jq -c --arg id "$1" '.organization | select(.id == $id) | {id, name, slug}' "$file" 2>/dev/null || true)"
    if [[ -n "$json" ]]; then
      printf '%s' "$json"
      return 0
    fi
  done
  jq -cn --arg id "$1" '{id: $id, name: null, slug: null}'
}

# Token on stdin, already accepted by the server. Moves what it replaces to an archive and records the change.
ia_install_admin_token() { # method why org-json
  local method="$1" why="$2" org="$3" stamp old_sha="" new_sha
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  jq -Rs --arg email "$INFISICAL_ADMIN_EMAIL" --argjson org "$org" '
    gsub("[[:space:]]"; "") as $token
    | ($token | split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
       | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson) as $claims
    | {email: $email, token: $token, organization: $org, identity: {id: $claims.identityId, name: $claims.identityName}}' \
    > "$ADMIN_FILE.tmp" || {
    rm -f "$ADMIN_FILE.tmp"
    warn "that token could not be read, so ${ADMIN_FILE##*/} was not replaced"
    return 1
  }
  chmod 600 "$ADMIN_FILE.tmp"
  new_sha="$(shasum -a 256 "$ADMIN_FILE.tmp" | cut -d' ' -f1)"
  if [[ -e "$ADMIN_FILE" ]]; then
    old_sha="$(shasum -a 256 "$ADMIN_FILE" | cut -d' ' -f1)"
    mkdir -p "$SECRET_ZERO_DIR/archive-token-$stamp"
    mv "$ADMIN_FILE" "$SECRET_ZERO_DIR/archive-token-$stamp/"
  fi
  mv "$ADMIN_FILE.tmp" "$ADMIN_FILE"
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg method "$method" --arg why "$why" --arg old "$old_sha" --arg new "$new_sha" \
    --argjson exp "$(ia_file_token_exp "$ADMIN_FILE")" \
    '{at: $at, method: $method, why: $why, old_sha256: $old, new_sha256: $new, token_exp: $exp}' >> "$ADMIN_TOKEN_LEDGER"
  chmod 600 "$ADMIN_TOKEN_LEDGER"
  warn "replaced ${ADMIN_FILE##*/}, because $why. How: $method. Recorded in ${ADMIN_TOKEN_LEDGER##*/}, and the token it replaced is not revoked"
}

# Signs in with the first admin's password and mints a token for the instance admin identity. Leaves it in
# $ADMIN_FILE. Returns 0 if so, 3 if there is no password to try, 1 if the server refused, and says why.
ia_mint_admin_token() { # why [org-id] [password-file]
  local why="$1" org="${2:-}" password_file="${3:-$ADMIN_PASSWORD_FILE}" orgs org_json identity new body
  [[ -s "$password_file" ]] || return 3
  : > "$IA_TMP/auth"
  body="$(jq -Rs --arg email "$INFISICAL_ADMIN_EMAIL" '{email: $email, password: .}' < "$password_file")"
  ia_request POST /api/v3/auth/login "$body"
  body=""
  if [[ "$IA_STATUS" != 200 ]]; then
    warn "signing in as $INFISICAL_ADMIN_EMAIL with ${password_file#"$SECRET_ZERO_DIR"/} answered HTTP $IA_STATUS: $(ia_error)"
    return 1
  fi
  printf '%s' "$IA_BODY" | jq -er '"Authorization: Bearer " + .accessToken' > "$IA_TMP/auth"

  ia_request GET /api/v1/organization
  orgs="$IA_BODY"
  if [[ -z "$org" ]]; then
    org="$(jq -r 'if (.organizations | length) == 1 then .organizations[0].id else "" end' <<<"$orgs" 2>/dev/null || true)"
    [[ -n "$org" ]] || {
      warn "signed in, but cannot tell which organization to use, with no local file naming it"
      return 1
    }
  fi
  org_json="$(jq -c --arg id "$org" '.organizations[] | select(.id == $id) | {id, name, slug}' <<<"$orgs" 2>/dev/null || true)"
  if [[ -z "$org_json" ]]; then org_json="$(ia_org_json "$org")"; fi

  ia_request POST /api/v3/auth/select-organization "$(jq -cn --arg org "$org" '{organizationId: $org}')"
  if [[ "$IA_STATUS" != 200 ]]; then
    warn "selecting organization $org answered HTTP $IA_STATUS: $(ia_error)"
    return 1
  fi
  # With two-factor on, the server asks for the code here, before any token, and a script has no code to give. A person makes the token.
  if [[ "$(printf '%s' "$IA_BODY" | jq -r '.isMfaEnabled')" == true ]]; then
    warn "$INFISICAL_ADMIN_EMAIL has two-factor on, so no script can finish a sign-in with the password. A person makes the token in the UI, as the steps say"
    return 1
  fi
  printf '%s' "$IA_BODY" | jq -er '"Authorization: Bearer " + .token' > "$IA_TMP/auth"

  # The server's own record of which identity is the instance admin.
  ia_request GET /api/v1/admin/config
  identity="$(printf '%s' "$IA_BODY" | jq -r '.config.adminIdentityIds[0] // ""')"
  if [[ -z "$identity" ]]; then
    warn "the server does not name an instance admin identity to this user, HTTP $IA_STATUS"
    return 1
  fi
  ia_request POST "/api/v1/auth/token-auth/identities/$identity/tokens" "$(jq -cn --arg n "minted-$(date -u +%Y%m%dT%H%M%SZ)" '{name: $n}')"
  if [[ "$IA_STATUS" != 200 ]]; then
    warn "minting a token for identity $identity answered HTTP $IA_STATUS: $(ia_error)"
    return 1
  fi
  new="$(printf '%s' "$IA_BODY" | jq -er '.accessToken')" || return 1
  printf 'Authorization: Bearer %s\n' "$new" > "$IA_TMP/auth"
  if ! ia_token_accepted "$org"; then
    warn "the server refused the token it just minted, HTTP $IA_STATUS"
    return 1
  fi
  if ! printf '%s' "$new" | ia_install_admin_token password "$why" "$org_json"; then
    new=""
    return 1
  fi
  new=""
}

# Takes a token a person put in $ADMIN_TOKEN_DROP, if the server accepts it. Returns 0 if it did, 1 if there
# is nothing there, and 2 if it refused it, which leaves the file in place and says why.
ia_adopt_dropped_token() { # why [org-id]
  local why="$1" want="${2:-}" org
  [[ -s "$ADMIN_TOKEN_DROP" ]] || return 1
  org="$(tr -d '[:space:]' < "$ADMIN_TOKEN_DROP" | ia_token_claims | jq -r '.orgId // ""')"
  if [[ -z "$org" ]]; then
    warn "${ADMIN_TOKEN_DROP##*/} does not hold a token this can read"
    return 2
  fi
  if [[ -n "$want" && "$org" != "$want" ]]; then
    warn "the token in ${ADMIN_TOKEN_DROP##*/} is for organization ${org:-unknown}, and this instance's is $want"
    return 2
  fi
  {
    printf 'Authorization: Bearer '
    tr -d '[:space:]' < "$ADMIN_TOKEN_DROP"
    printf '\n'
  } > "$IA_TMP/auth"
  if ! ia_token_accepted "$org"; then
    warn "the server refused the token in ${ADMIN_TOKEN_DROP##*/}, HTTP $IA_STATUS: $(ia_error)"
    return 2
  fi
  if ! tr -d '[:space:]' < "$ADMIN_TOKEN_DROP" | ia_install_admin_token sign-in "$why" "$(ia_org_json "$org")"; then
    return 2
  fi
  rm -f "$ADMIN_TOKEN_DROP"
}

# For a live instance: make sure $ADMIN_FILE can log in, as far as the file can tell. RENEW_ADMIN_TOKEN=yes
# replaces one that still works, which is how to get ahead of its end. Returns as ia_mint_admin_token does.
ia_ensure_admin() { # [org-id]
  local org="${1:-}" problem rc=0
  ia_adopt_dropped_token "a person made a replacement" "$org" || rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi
  problem="$(ia_admin_problem)"
  if [[ -z "$problem" && "${RENEW_ADMIN_TOKEN:-}" != yes ]]; then return 0; fi
  rc=0
  ia_mint_admin_token "${problem:-RENEW_ADMIN_TOKEN=yes asked for a new one}" "$org" || rc=$?
  return "$rc"
}

# The way back with no token and no password on this machine. For a run that has stopped and will resume.
ia_print_sign_in_steps() { # the command that goes on afterwards
  cat >&2 <<STEPS
Nothing on this machine can log in to Infisical. Either of these lets it go on:

  By hand, in the UI, which works with two-factor on:
    1. Open $INFISICAL_URL and sign in as $INFISICAL_ADMIN_EMAIL, with the code if two-factor is on. A port-forward's address goes
       when its script ends: open Infisical the way you usually do instead.
    2. Go to Access Control, Machine Identities, Instance Admin Identity, Token Auth, Add Token, and create one.
    3. Write that token to ${ADMIN_TOKEN_DROP#"$ROOT"/}, one line, mode 0600.
    4. Run: $1
       It checks the token against the server, moves it into place and records that it did.

  Or with the password of $INFISICAL_ADMIN_EMAIL, from wherever you keep a copy, only while that account has no two-factor:
    1. Write it to ${ADMIN_PASSWORD_FILE#"$ROOT"/}, mode 0600.
    2. Run: $1
       It signs in by itself, mints a token for the instance admin identity and records that it did. With two-factor on the server asks
       for a code, and this stops there.

With no copy of the password either way, see "Admin token and password both gone" in infisical/README.md.
STEPS
}

ia_admin_token() {
  jq -er '.token' "$ADMIN_FILE"
}

machine_value() { # field env, for example: project_ids dev
  jq -er --arg env "$2" --arg field "$1" '.[$field][$env]' "$MACHINE_FILE" \
    || die "$MACHINE_FILE has no $1 for $2. Run scripts/infisical-bootstrap.sh."
}
