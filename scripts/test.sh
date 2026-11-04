#!/usr/bin/env bash
# Run the tests against the running platform and say plainly what ran. Labels follow contract section 12.
#
#   scripts/test.sh               day-1 gates, NetworkPolicy matrix, Infisical isolation, smoke in dev, then in prod-sim
#   scripts/test.sh e2e dev       smoke in one environment. Also: e2e ENV=dev, or ENV=dev scripts/test.sh e2e
#   scripts/test.sh infisical     Infisical isolation and rendered Secrets only
#
# The full form keeps going after a failure, so one run shows everything that is wrong.
#
# Exit status, the same as tests/e2e/smoke.py: 0 everything passed, 1 something failed, 2 nothing failed
# but something could not run. BLOCKED is not a pass, and nothing here reports it as one.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() { die "usage: $0 [e2e dev|prod-sim | infisical]"; }

ARGUMENTS="$*"
MODE=all
if [[ "${1:-}" == infisical ]]; then
  [[ $# -eq 1 ]] || usage
  MODE=infisical
elif [[ $# -gt 0 ]]; then
  [[ "$1" == e2e ]] || usage
  MODE=e2e
  shift
  for arg in "$@"; do
    case "$arg" in
      dev | prod-sim) ENV="$arg" ;;
      ENV=*) ENV="${arg#ENV=}" ;;
      *) usage ;;
    esac
  done
  ENV="${ENV:-dev}"
  [[ "$ENV" == dev || "$ENV" == prod-sim ]] || usage
fi

guard_disk 2
command -v python3 >/dev/null 2>&1 || die "python3 not found. Run: make setup"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="$LOCAL_DIR/evidence-raw"
SUMMARY="$EVIDENCE_DIR/test-$STAMP.txt"
mkdir -p "$EVIDENCE_DIR"
printf 'scripts/test.sh %s, started %s\n' "$ARGUMENTS" "$STAMP" >"$SUMMARY"

FAILED=0
BLOCKED=0
record() { # record <PASS|FAIL|BLOCKED> <test> <detail>
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
  esac
  printf '%-8s %-26s %s\n' "$1" "$2" "$3" >>"$SUMMARY"
}

run_gates() {
  local evidence="$EVIDENCE_DIR/gates-$STAMP.txt" status=0
  log "Day-1 gates"
  "$ROOT/tests/gates/day1.sh" > >(tee "$evidence") 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then record PASS gates "evidence: $evidence"; else record FAIL gates "exit $status, evidence: $evidence"; fi
}

run_netpol() {
  local status=0
  log "NetworkPolicy matrix"
  "$ROOT/scripts/test-netpol.sh" || status=$?
  # Sets its own evidence name, and writes the file only once its sentinel has passed.
  if [[ "$status" -eq 0 ]]; then record PASS netpol "evidence: $EVIDENCE_DIR/netpol-*.tsv"; else record FAIL netpol "exit $status, evidence if the sentinel passed: $EVIDENCE_DIR/netpol-*.tsv"; fi
}

run_infisical() {
  local script label evidence status
  for script in isolation rendered-secrets; do
    label="infisical $script"
    evidence="$EVIDENCE_DIR/infisical-$script-$STAMP.txt"
    status=0
    log "Infisical: $script"
    "$ROOT/infisical/tests/$script.sh" > >(tee "$evidence") 2>&1 || status=$?
    case "$status" in
      0) record PASS "$label" "evidence: $evidence" ;;
      2) record BLOCKED "$label" "a check could not run, so this is not a pass. Evidence: $evidence" ;;
      *) record FAIL "$label" "exit $status, evidence: $evidence" ;;
    esac
  done
}

run_e2e() { # run_e2e <env>
  local env="$1" evidence="$EVIDENCE_DIR/smoke-$1-$STAMP.json" status=0 control=""
  # Dev only: it pauses background jobs for about 20s to show the job check can fail.
  [[ "$env" != dev ]] || control="--worker-negative-control"
  log "End-to-end smoke test in $env"
  python3 -B "$ROOT/tests/e2e/smoke.py" --env "$env" --evidence "$evidence" ${control:+"$control"} || status=$?
  case "$status" in
    0) record PASS "e2e $env" "evidence: $evidence" ;;
    2) record BLOCKED "e2e $env" "a step could not run, so this is not a pass. Evidence: $evidence" ;;
    *) record FAIL "e2e $env" "exit $status, evidence: $evidence" ;;
  esac
}

# Everything here runs against the cluster, and smoke reaches Plane through Traefik inside it. With
# no cluster nothing can run, and calling that a failure of each test would say something untrue.
if ! kc get --raw /readyz >/dev/null 2>&1; then
  warn "the cluster is not reachable, so nothing can run. Run 'make up' first."
  if [[ "$MODE" == e2e ]]; then
    record BLOCKED "e2e $ENV" "cluster not reachable"
  elif [[ "$MODE" == infisical ]]; then
    record BLOCKED infisical "cluster not reachable"
  else
    for test_name in gates netpol infisical "e2e dev" "e2e prod-sim"; do record BLOCKED "$test_name" "cluster not reachable"; done
  fi
elif [[ "$MODE" == e2e ]]; then
  run_e2e "$ENV"
elif [[ "$MODE" == infisical ]]; then
  run_infisical
else
  run_gates
  run_netpol
  run_infisical
  run_e2e dev
  run_e2e prod-sim
fi

log "Summary, also in $SUMMARY"
sed '1d; s/^/    /' "$SUMMARY"
[[ "$FAILED" -eq 0 ]] || die "$FAILED failed, $BLOCKED blocked"
if [[ "$BLOCKED" -ne 0 ]]; then
  warn "nothing failed, but $BLOCKED could not run. That is not a pass."
  exit 2
fi
ok "all passed"
