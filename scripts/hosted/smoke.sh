#!/usr/bin/env bash
# The smoke test for hosted production: tests/e2e/smoke.py --env hosted --mode verify, over https, signed in as an existing account.
# It creates no user and never claims the admin. It makes a project, a work item, an attachment, a page and a 2-hour API token, and
# removes them before it ends. See that file.
#
#   TARGET=plane-prod scripts/hosted/smoke.sh                       asks for the account's email and password at hidden prompts
#   SMOKE_WORKSPACE=<slug>                                          the workspace to work in, or the account's first
#   SMOKE_ALLOW_STAGING=yes                                         for a staging certificate. Nothing checks it, so at best this exits 2
#
# Exit status as smoke.py's: 0 passed, 1 failed, 2 something could not run. The prompts need a terminal, so with none this exits 2.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 not found. Run: make setup"
if [[ ! -t 0 ]]; then
  warn "BLOCKED: the smoke test signs in with a real account, whose email and password it asks for at a hidden prompt, and there is no terminal here. Run: make remote-smoke TARGET=plane-prod"
  exit 2
fi

read -r -s -p "Email of an existing account on $HOSTED_DOMAIN (hidden): " email
printf '\n' >&2
read -r -s -p "Its password (hidden): " password
printf '\n' >&2
if [[ -z "$email" || -z "$password" ]]; then
  warn "BLOCKED: one of the two was empty, so nothing ran."
  exit 2
fi

args=(--env hosted --mode verify --host "$HOSTED_DOMAIN" --connect "$HOSTED_DOMAIN:443"
  --credentials-stdin
  # Files that do not exist, so the local platform's test accounts stay out of this.
  --accounts "$LOCAL_DIR/smoke-no-accounts.env" --sentinel "$LOCAL_DIR/smoke-no-sentinel.json"
  --evidence "$HOSTED_EVIDENCE_DIR/smoke-plane-prod-$(hosted_stamp).json")
if [[ -n "${SMOKE_WORKSPACE:-}" ]]; then args+=(--workspace "$SMOKE_WORKSPACE"); fi
if [[ "${SMOKE_ALLOW_STAGING:-}" == yes ]]; then args+=(--allow-untrusted-certificate); fi

status=0
# printf is a builtin, so neither value reaches an argv, and stdin is gone once it is read.
printf '%s\n%s\n' "$email" "$password" | python3 -B "$ROOT/tests/e2e/smoke.py" "${args[@]}" || status=$?
email=""
password=""
exit "$status"
