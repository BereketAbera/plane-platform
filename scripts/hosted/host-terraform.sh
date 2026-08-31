#!/usr/bin/env bash
# Terraform for what sits outside the cluster: reads the VPS from Contabo and owns the two DNS records.
#
#   TARGET=plane-prod scripts/hosted/host-terraform.sh plan
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/host-terraform.sh apply
#
# Credentials come from what the two CLIs already hold, ~/.cntb.yaml and the Vercel CLI's login, through the environment of
# this one process. They reach no command line, no file here and no output. Refresh Vercel's with: vercel whoami
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF="$ROOT/.tools/bin/terraform"
YQ="$ROOT/.tools/bin/yq"
CHDIR="$ROOT/infrastructure/terraform/environments/prod-host"
VERCEL_DIR="$HOME/Library/Application Support/com.vercel.cli"

die() { printf 'fail %s\n' "$*" >&2; exit 1; }
[[ "${TARGET:-}" == plane-prod ]] || die "set TARGET=plane-prod"
[[ $# -eq 1 && "$1" =~ ^(plan|apply)$ ]] || die "usage: $0 plan|apply"
[[ "$1" != apply || "${CONFIRM:-}" == plane-prod ]] || die "apply changes DNS state: set CONFIRM=plane-prod"
[[ -f "$HOME/.cntb.yaml" ]] || die "no ~/.cntb.yaml. Run scripts/hosted/contabo-login.sh"
[[ -f "$VERCEL_DIR/auth.json" ]] || die "the Vercel CLI is not logged in. Run: vercel login"

# So the access token in that file is current, because the CLI renews it only when it runs.
vercel whoami >/dev/null 2>&1 || die "the Vercel CLI's login does not work. Run: vercel login"

export CNTB_OAUTH2_CLIENT_ID CNTB_OAUTH2_CLIENT_SECRET CNTB_OAUTH2_USER CNTB_OAUTH2_PASS VERCEL_API_TOKEN VERCEL_TEAM
CNTB_OAUTH2_CLIENT_ID="$("$YQ" -r '.["oauth2-clientid"]' "$HOME/.cntb.yaml")"
CNTB_OAUTH2_CLIENT_SECRET="$("$YQ" -r '.["oauth2-client-secret"]' "$HOME/.cntb.yaml")"
CNTB_OAUTH2_USER="$("$YQ" -r '.["oauth2-user"]' "$HOME/.cntb.yaml")"
CNTB_OAUTH2_PASS="$("$YQ" -r '.["oauth2-password"]' "$HOME/.cntb.yaml")"
VERCEL_API_TOKEN="$("$YQ" -r .token "$VERCEL_DIR/auth.json")"
VERCEL_TEAM="$("$YQ" -r '.currentTeam // ""' "$VERCEL_DIR/config.json")"

"$TF" -chdir="$CHDIR" init -input=false -lockfile=readonly >/dev/null
case "$1" in
  plan) "$TF" -chdir="$CHDIR" plan -input=false ;;
  apply) "$TF" -chdir="$CHDIR" apply -input=false -auto-approve ;;
esac
