#!/usr/bin/env bash
# Infisical's one admin login, for its public route. scripts/infisical-bootstrap.sh made it, and keeps it in
# .local/hosted/plane-prod/secret-zero at mode 0600, so this only reads it.
#
#   TARGET=plane-prod scripts/hosted/infisical-admin.sh login   print the URL and email, and copy the password to the clipboard
#
# Two-factor is the authenticator app the owner set up on this account. scripts/hosted/README.md, section Locked out of Infisical, says
# how to get back in without it.
#
# No value reaches an argv or stdout: the clipboard reads the password from its file, through stdin.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SECRET_ZERO="$LOCAL_DIR/secret-zero"
PASSWORD_FILE="$SECRET_ZERO/infisical-admin-password"
ADMIN_FILE="$SECRET_ZERO/infisical-admin.json"

# The address scripts/hosted/target.sh gives the bootstrap, unless the bootstrap's own record names another. Only that field is read, and
# never the token beside it.
admin_email() {
  local email=""
  if [[ -s "$ADMIN_FILE" ]]; then email="$(jq -r '.email // empty' "$ADMIN_FILE" 2>/dev/null || true)"; fi
  printf '%s' "${email:-admin@$HOSTED_DOMAIN}"
}

login() {
  command -v jq >/dev/null 2>&1 || die "jq not found. Run: make setup"
  [[ -s "$PASSWORD_FILE" ]] ||
    die "no password in ${PASSWORD_FILE#"$ROOT"/}. scripts/hosted/bootstrap.sh writes it at step 6, and the recovery bundle holds a copy: scripts/hosted/bundle.sh"
  command -v pbcopy >/dev/null 2>&1 || die "pbcopy not found, because this copies to the macOS clipboard. The password is in ${PASSWORD_FILE#"$ROOT"/}"
  printf 'URL       https://%s\n' "$HOSTED_INFISICAL_DOMAIN"
  printf 'Email     %s\n' "$(admin_email)"
  pbcopy <"$PASSWORD_FILE"
  ok "the password is on the clipboard, and was not printed. Copy something else once you have pasted it. Then the code from your authenticator app."
}

case "${1:-}" in
  login) login ;;
  *) die "usage: $0 login" ;;
esac
