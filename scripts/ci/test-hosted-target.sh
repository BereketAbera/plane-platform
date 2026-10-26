#!/usr/bin/env bash
# scripts/hosted/target.sh, sourced as the shared scripts source it, with no cluster: which environments it hands Infisical's bootstrap,
# its seed and infisical/terraform, and that HOSTED_RESTORE_WITHOUT_APPS=yes leaves the apps' out for a restore of Infisical and nowhere
# else, because anywhere else Terraform would destroy each project left out, with every secret in it. It runs in a throwaway copy of this
# repository's scripts, whose install-tools is a stub, and a refusal must come before lib.sh, which would open the tunnel.
#
#   scripts/ci/test-hosted-target.sh
#
# It runs what is on disk, in a few seconds, and says nothing about Infisical or Terraform themselves.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" yq >/dev/null
command -v jq >/dev/null 2>&1 || die "jq not found"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/repo"
OUTPUT="$WORK/output"
mkdir -p "$COPY/scripts" "$COPY/infrastructure/hosted/plane-prod" "$COPY/.tools/bin"
cp -R "$ROOT/scripts/lib" "$ROOT/scripts/hosted" "$COPY/scripts/"
cp "$ROOT/infrastructure/hosted/plane-prod/target.yaml" "$COPY/infrastructure/hosted/plane-prod/"
ln -s "$ROOT/.tools/bin/yq" "$COPY/.tools/bin/yq"
printf '#!/usr/bin/env bash\nexit 0\n' >"$COPY/scripts/install-tools.sh"
# A refusal that came after lib.sh would reach for the cluster, and no tunnel may open from here.
printf '#!/usr/bin/env bash\nexit 1\n' >"$COPY/scripts/hosted/tunnel.sh"
chmod +x "$COPY/scripts/install-tools.sh" "$COPY/scripts/hosted/tunnel.sh"

# What target.sh hands on, for these variables and nothing else of this shell's: the environments to act on, the keys of
# TF_VAR_environments, and prod's entry in it. CLUSTER is yes for a source that may go past lib.sh, which then skips the cluster's
# check, as a script's own unexported HOSTED_NO_CLUSTER=yes does. A refusal is run without it, so one that came after lib.sh would
# fail on the missing kubeconfig and not say what is wanted.
STATUS=0
source_target() { # source_target <no-cluster: yes or no> <VAR=value...>
  local no_cluster="$1"
  shift
  STATUS=0
  env -i PATH="$PATH" HOME="$WORK" WAYLINE_TARGET=plane-prod CONFIRM=plane-prod "$@" bash -c '
    if [[ "$2" == yes ]]; then HOSTED_NO_CLUSTER=yes; fi
    source "$1/scripts/hosted/target.sh"
    printf "%s|%s|%s\n" "$WAYLINE_ENVIRONMENTS" "$(jq -c keys <<<"$TF_VAR_environments")" "$(jq -cS .prod <<<"$TF_VAR_environments")"
  ' _ "$COPY" "$no_cluster" >"$OUTPUT" 2>&1 || STATUS=$?
}

passed=0
failed=0
expect() { # expect <what> <test...>
  local what="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    ok "$what"
  else
    failed=$((failed + 1))
    warn "FAILED: $what. Sourcing target.sh exited $STATUS and said:"
    sed 's/^/    /' "$OUTPUT" >&2
  fi
}
handed() { [[ "$STATUS" -eq 0 && "$(tail -n 1 "$OUTPUT")" == "$1" ]]; }
refused() { [[ "$STATUS" -ne 0 ]] && grep -qF -- "$1" "$OUTPUT" && ! grep -q '|' "$OUTPUT"; }

PROD='{"namespace":"plane-prod","project":"plane-prod"}'

source_target yes
expect "Plane's environment and Frameflow's, by default" handed "prod frameflow|[\"frameflow\",\"prod\"]|$PROD"
source_target yes INFISICAL_RESTORED=yes
expect "restored mode keeps the apps' unless asked" handed "prod frameflow|[\"frameflow\",\"prod\"]|$PROD"
source_target yes INFISICAL_RESTORED=yes HOSTED_RESTORE_WITHOUT_APPS=yes
expect "a restore without the apps: prod's alone, under the same key and project" handed "prod|[\"prod\"]|$PROD"
source_target no HOSTED_RESTORE_WITHOUT_APPS=yes
expect "the apps left out by a plain run: refused, before lib.sh" refused "is for INFISICAL_RESTORED=yes alone"
source_target no HOSTED_RESTORE_WITHOUT_APPS=yes PLAN_ONLY=yes
expect "the apps left out by a plan: refused, before lib.sh" refused "is for INFISICAL_RESTORED=yes alone"
source_target no INFISICAL_RESTORED=no HOSTED_RESTORE_WITHOUT_APPS=yes
expect "the apps left out beside INFISICAL_RESTORED=no: refused" refused "is for INFISICAL_RESTORED=yes alone"
source_target no INFISICAL_RESTORED=yes HOSTED_RESTORE_WITHOUT_APPS=true
expect "any value but yes: refused, not read as no" refused "takes yes or nothing"

[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) checks on target.sh failed"
ok "target.sh: $passed checks passed with no cluster"
