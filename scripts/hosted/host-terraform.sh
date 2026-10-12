#!/usr/bin/env bash
# Terraform for what sits outside the cluster: reads the VPS from Contabo and owns the three DNS records.
#
#   TARGET=plane-prod scripts/hosted/host-terraform.sh plan
#   TARGET=plane-prod CONFIRM=plane-prod EXPECT='<the changes plan printed>' scripts/hosted/host-terraform.sh apply
#   scripts/hosted/host-terraform.sh --selftest    how a plan's changes are read, and the state check, with no Terraform, so CI can run it
#
# Credentials come from what the two CLIs already hold, ~/.cntb.yaml and the Vercel CLI's login, through the environment of
# this one process. They reach no command line, no file here and no output. Refresh Vercel's with: vercel whoami
#
# Its state is in this checkout's .local, and only one checkout holds it. Run from another, Terraform would start from nothing: import
# wayline's record again and create a second A record for each of the others. So both verbs stop here without it. apply makes a plan of its
# own and applies it at once, and only if its changes are the ones EXPECT names, as plan prints them: the same action on each of the same
# addresses. So it applies no change whose action and address a person did not read. It does not hold the values: a record whose content
# moved between the two runs is applied with what this run's plan shows, which it prints above the apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF="$ROOT/.tools/bin/terraform"
YQ="$ROOT/.tools/bin/yq"
CHDIR="$ROOT/infrastructure/terraform/environments/prod-host"
STATE="$ROOT/.local/hosted/plane-prod/terraform/host/terraform.tfstate"
VERCEL_DIR="$HOME/Library/Application Support/com.vercel.cli"

die() { printf 'fail %s\n' "$*" >&2; exit 1; }
ok() { printf ' ok %s\n' "$*"; }

# Each change a saved plan makes, sorted and joined by ", ": create, update, delete, replace or forget, with import in front of one that
# imports, then the resource's address. A data source is read, which changes nothing, so it is left out. Nothing at all prints nothing.
plan_changes() { # terraform show -json of a plan, on stdin
  jq -r '[.resource_changes[]? | select(.mode != "data")
    | (.change.actions | if . == ["no-op"] then "" elif . == ["delete", "create"] or . == ["create", "delete"] then "replace" else join("+") end) as $action
    | ([(if .change.importing then "import" else "" end), $action] | map(select(. != "")) | join("+")) as $what
    | select($what != "") | "\($what) \(.address)"] | sort | join(", ")'
}

# Why there is no state to plan from, or nothing. HOST_TERRAFORM_FIRST_STATE=yes is for a zone that holds none of these records yet.
state_problem() { # path
  if [[ -s "$1" || "${HOST_TERRAFORM_FIRST_STATE:-}" == yes ]]; then return 0; fi
  printf '%s is missing, so Terraform would import wayline again and make a second A record for each of the others. Run this from the checkout that holds .local/hosted/plane-prod, or bring the state back from the recovery bundle (scripts/hosted/bundle.sh)' "${1#"$ROOT"/}"
}

if [[ "${1:-}" == --selftest ]]; then
  command -v jq >/dev/null 2>&1 || die "jq not found"
  failures=0
  check() { # want got what
    if [[ "$1" == "$2" ]]; then printf ' ok %s\n' "$3"; else printf 'fail %s: got [%s], want [%s]\n' "$3" "$2" "$1"; failures=$((failures + 1)); fi
  }
  change() { # address actions-as-JSON [importing]
    if [[ -n "${3:-}" ]]; then
      printf '{"address":"%s","mode":"managed","change":{"actions":%s,"importing":{"id":"x"}}}' "$1" "$2"
    else
      printf '{"address":"%s","mode":"managed","change":{"actions":%s}}' "$1" "$2"
    fi
  }
  read_data='{"address":"data.contabo_instance.vps","mode":"data","change":{"actions":["read"]}}'
  noop="$(change vercel_dns_record.wayline '["no-op"]')"
  check "create vercel_dns_record.infisical" "$(printf '{"resource_changes":[%s,%s,%s]}' "$read_data" "$noop" "$(change vercel_dns_record.infisical '["create"]')" | plan_changes)" "one record to add"
  check "create vercel_dns_record.grafana, create vercel_dns_record.infisical, import vercel_dns_record.wayline" \
    "$(printf '{"resource_changes":[%s,%s,%s]}' "$(change vercel_dns_record.wayline '["no-op"]' importing)" "$(change vercel_dns_record.infisical '["create"]')" "$(change vercel_dns_record.grafana '["create"]')" | plan_changes)" "no state, as from another checkout"
  check "" "$(printf '{"resource_changes":[%s,%s]}' "$read_data" "$noop" | plan_changes)" "nothing to change"
  check "" "$(printf '{}' | plan_changes)" "no resource_changes at all"
  check "replace vercel_dns_record.grafana, update vercel_dns_record.wayline" "$(printf '{"resource_changes":[%s,%s]}' "$(change vercel_dns_record.wayline '["update"]')" "$(change vercel_dns_record.grafana '["delete","create"]')" | plan_changes)" "a replace and an update"
  check "import+update vercel_dns_record.wayline" "$(printf '{"resource_changes":[%s]}' "$(change vercel_dns_record.wayline '["update"]' importing)" | plan_changes)" "an import that changes the record"
  check "delete vercel_dns_record.infisical" "$(printf '{"resource_changes":[%s]}' "$(change vercel_dns_record.infisical '["delete"]')" | plan_changes)" "a delete"
  # What EXPECT cannot hold, written down: an update reads as its action and address, whatever values it changes.
  check "update vercel_dns_record.wayline" \
    "$(printf '{"resource_changes":[{"address":"vercel_dns_record.wayline","mode":"managed","change":{"actions":["update"],"before":{"value":"203.0.113.1"},"after":{"value":"203.0.113.2"}}}]}' | plan_changes)" \
    "an update's values are not part of what EXPECT compares"
  scratch="$(mktemp -d)"
  check "" "$(printf '{}' >"$scratch/state" && state_problem "$scratch/state")" "a state file is enough"
  check yes "$(problem="$(state_problem "$scratch/none")"; [[ "$problem" == *"is missing"* ]] && echo yes)" "a missing state stops both verbs"
  check "" "$(HOST_TERRAFORM_FIRST_STATE=yes state_problem "$scratch/none")" "a first state, when asked for"
  : >"$scratch/empty"
  check yes "$(problem="$(state_problem "$scratch/empty")"; [[ "$problem" == *"is missing"* ]] && echo yes)" "an empty state counts as none"
  rm -rf "$scratch"
  [[ "$failures" -eq 0 ]] || die "selftest: $failures failed"
  ok "selftest passed"
  exit 0
fi

[[ "${TARGET:-}" == plane-prod ]] || die "set TARGET=plane-prod"
[[ $# -eq 1 && "$1" =~ ^(plan|apply)$ ]] || die "usage: $0 plan|apply"
[[ "$1" != apply || "${CONFIRM:-}" == plane-prod ]] || die "apply changes DNS state: set CONFIRM=plane-prod"
[[ "$1" != apply || -n "${EXPECT:-}" ]] || die "apply needs EXPECT, the changes that plan printed, so that nothing else is applied"
command -v jq >/dev/null 2>&1 || die "jq not found. Run: make setup"
problem="$(state_problem "$STATE")"
[[ -z "$problem" ]] || die "$problem"
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

# The saved plan sits beside the state, which is 0700 and never in Git, and goes when this ends.
umask 077
mkdir -p "$(dirname "$STATE")"
PLAN="$(mktemp "$(dirname "$STATE")/host.tfplan.XXXXXX")"
trap 'rm -f "$PLAN"' EXIT

"$TF" -chdir="$CHDIR" init -input=false -lockfile=readonly >/dev/null
"$TF" -chdir="$CHDIR" plan -input=false -out="$PLAN"
changes="$("$TF" -chdir="$CHDIR" show -json "$PLAN" | plan_changes)"
case "$1" in
  plan)
    printf '\nThis plan: %s\n' "${changes:-nothing}"
    [[ -z "$changes" ]] || printf "To apply the same changes, which apply plans again and stops if they differ: TARGET=plane-prod CONFIRM=plane-prod EXPECT='%s' %s apply\n" "$changes" "$0"
    ;;
  apply)
    [[ "${changes:-nothing}" == "$EXPECT" ]] || die "this plan is: ${changes:-nothing}. EXPECT says: $EXPECT. Nothing was applied"
    if [[ -z "$changes" ]]; then ok "nothing to apply"; exit 0; fi
    "$TF" -chdir="$CHDIR" apply -input=false "$PLAN"
    ;;
esac
