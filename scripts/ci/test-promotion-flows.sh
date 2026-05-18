#!/usr/bin/env bash
# Behaviour of promote.sh, rollback.sh, gitops-publish.sh and the failed-deploy drill, against a stub
# kubectl and a stub backup, in a throwaway clone with its own bare repository. Nothing here can reach
# a cluster or the real Git remote: KUBECONFIG, the bare repository and every tool on PATH belong to
# the clone. It runs what is on disk, so it tests a change before it is committed.
#
#   scripts/ci/test-promotion-flows.sh           every scenario, a minute or two
#   scripts/ci/test-promotion-flows.sh rollback  only the scenarios whose name contains "rollback"
#
# It says nothing about a real cluster. It proves the scripts do what they say given these answers.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" helm kustomize yq >/dev/null

FILTER="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CLONE="$WORK/repo"
STUB="$WORK/stub"
mkdir -p "$STUB"
passed=0
failed=0

git clone --quiet "$ROOT" "$CLONE"
git -C "$CLONE" remote remove origin
git -C "$CLONE" checkout --quiet -B main
git -C "$CLONE" config user.name flow-test
git -C "$CLONE" config user.email flow-test@invalid
git -C "$CLONE" config commit.gpgsign false
# What is on disk, not what is committed. Only the scripts move, so history and the overlays stay clean.
rm -rf "$CLONE/scripts" "$CLONE/tests/drills"
cp -R "$ROOT/scripts" "$CLONE/scripts"
cp -R "$ROOT/tests/drills" "$CLONE/tests/drills"

# The clone's own tool directory: links to the real tools, then stubs on top.
mkdir -p "$CLONE/.tools/bin" "$CLONE/.local"
for tool in "$ROOT"/.tools/bin/* "$ROOT"/.tools/bin/.[!.]*; do
  [[ -e "$tool" ]] && ln -sf "$tool" "$CLONE/.tools/bin/$(basename "$tool")"
done
rm -f "$CLONE/.tools/bin/kubectl"

cat >"$CLONE/.tools/bin/kubectl" <<'STUB_KUBECTL'
#!/usr/bin/env bash
# Answers what the promotion scripts and the drill ask, from the files in $STUB. Anything else fails.
args=" $* "
current_web_image() { grep -m1 -E 'image: .*plane-frontend' "$CLONE/gitops/environments/dev/manifests.yaml" | sed 's/.*image: //'; }
web_is_bad() { current_web_image | grep -qF "@$BAD_DIGEST"; }
case "$args" in
  *" get --raw /readyz "*) [[ "$(cat "$STUB/cluster")" == up ]] ;;
  *" annotate application "*) exit 0 ;;
  *" get application plane-dev -o jsonpath={.status.sync.status}/{.status.health.status} "*) cat "$STUB/app-status" ;;
  # The drill's own view: Degraded while the bad digest is what Git asks for, and back after the revert.
  *" get application plane-dev -o jsonpath={.status.sync.status} "*) printf Synced ;;
  *" get application plane-dev -o jsonpath={.status.health.status} "*) if web_is_bad; then printf Degraded; else printf Healthy; fi ;;
  *" get application plane-dev -o jsonpath={.status.operationState.message} "*) printf stubbed ;;
  *" -n plane-dev get pods -o json "*) cat "$STUB/pods.json" ;;
  *" get deployment plane-web-wl -o jsonpath={.spec.template.spec.containers[0].image} "*) current_web_image ;;
  *" get deployment plane-web-wl -o jsonpath={.spec.progressDeadlineSeconds} "*) printf 60 ;;
  *" get pods -l app.kubernetes.io/component=web -o jsonpath={.items[*].metadata.uid} "*) printf uid-old-pod ;;
  *" get pods -l app.kubernetes.io/component=web -o jsonpath={range .items[*]}{.status.containerStatuses[0].state.waiting.reason}"*)
    if web_is_bad; then printf 'ImagePullBackOff\n'; fi ;;
  *" get pods -o jsonpath={range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.uid}"*) printf 'uid-old-pod\n' ;;
  *" get pods -o jsonpath={range .items[*]}{.spec.containers[0].image}"*) current_web_image ;;
  *) echo "stub kubectl: not expected: $*" >&2; exit 97 ;;
esac
STUB_KUBECTL
chmod +x "$CLONE/.tools/bin/kubectl"

# Records each call, and does what $STUB/backup-mode says.
cat >"$CLONE/scripts/backup.sh" <<'STUB_BACKUP'
#!/usr/bin/env bash
echo "$*" >>"$STUB/backup-calls"
case "$(cat "$STUB/backup-mode")" in
  ok)
    id="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$CLONE/.local/backups/$1/$id"
    echo '{}' >"$CLONE/.local/backups/$1/$id/manifest.json"
    ;;
  hang) sleep 300 ;;
  *) echo "stub backup: failing as told" >&2; exit 1 ;;
esac
STUB_BACKUP

export STUB CLONE
BAD_DIGEST="sha256:$(printf '0%.0s' {1..64})"
export BAD_DIGEST
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
BARE="$CLONE/.local/git/plane-platform.git"
PROD_SIM_OVERLAY=helm/plane/overlays/prod-sim/kustomization.yaml
OUT="$WORK/output"

git -C "$CLONE" add -A -- scripts tests/drills >/dev/null
git -C "$CLONE" commit --quiet --allow-empty -m 'scripts under test'
BASE="$(git -C "$CLONE" rev-parse HEAD)"

admin_digest() { yq -r '.images[] | select(.name | test("plane-admin$")) | .digest' "$CLONE/$PROD_SIM_OVERLAY"; }
web_digest_in() { yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest' "$CLONE/$1"; }
web_image() { # A pod list with one ready container running this digest of web, or one not yet ready.
  cat >"$STUB/pods.json" <<JSON
{"items":[{"metadata":{"name":"web-1"},"status":{"phase":"Running","containerStatuses":[{"name":"web","ready":$2}]},
"spec":{"containers":[{"name":"web","image":"docker.io/makeplane/plane-frontend:v1.4.3@$1"}]}}]}
JSON
}

reset_clone() {
  git -C "$CLONE" reset --quiet --hard "$BASE"
  git -C "$CLONE" update-ref -d refs/remotes/origin/main 2>/dev/null || true
  git -C "$CLONE" clean --quiet -fd -- helm gitops
  rm -rf "$CLONE/.local/git" "$CLONE/.local/backups" "$CLONE/.local/evidence-raw" "$CLONE/.build" "$STUB/backup-calls"
  rm -f "$CLONE/.tools/bin/curl"
  touch "$CLONE/.local/kubeconfig"
  echo up >"$STUB/cluster"
  echo Synced/Healthy >"$STUB/app-status"
  echo ok >"$STUB/backup-mode"
  web_image "$DIGEST_A" true
  : >"$OUT"
  # A published main to start from, as a running platform has. Quiet about origin, which a clone lacks.
  (cd "$CLONE" && ./scripts/gitops-publish.sh) >/dev/null 2>&1
}

in_clone() { (cd "$CLONE" && "$@") >"$OUT" 2>&1; }
promote_dev() { in_clone env SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev IMAGE=web DIGEST="$1"; }
promote_prod_sim() { in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim "$@"; }
rollback() { in_clone env CONFIRM=yes ROLLBACK_DUMP_TIMEOUT="${ROLLBACK_DUMP_TIMEOUT:-5}" ./scripts/rollback.sh "$@"; }
head_commit() { git -C "$CLONE" rev-parse HEAD; }
published() { git --git-dir="$BARE" rev-parse refs/heads/main; }
reverts_on_main() { git -C "$CLONE" log --format=%B "$BASE..HEAD" | grep -c '^This reverts commit' || true; }

scenario_failures=0
expect() { # expect <description> <command...>: one assertion inside a scenario
  local what="$1"
  shift
  if "$@"; then return 0; fi
  warn "  expected: $what"
  scenario_failures=$((scenario_failures + 1))
}
said() { grep -qF -- "$1" "$OUT"; }
not_said() { ! grep -qF -- "$1" "$OUT"; }
equal() { [[ "$1" == "$2" ]]; }

scenario() { # scenario <name> <function>
  [[ -z "$FILTER" || "$1" == *"$FILTER"* ]] || return 0
  reset_clone
  scenario_failures=0
  "$2"
  if [[ "$scenario_failures" -eq 0 ]]; then
    ok "$1"
    passed=$((passed + 1))
  else
    warn "$1 FAILED. Its last command printed:"
    sed 's/^/    /' "$OUT" | tail -n 25 >&2
    failed=$((failed + 1))
  fi
}

# ---- promotion to prod-sim: the digest must belong to that image
digest_under_another_image() {
  local status=0 admin
  admin="$(admin_digest)"
  promote_prod_sim IMAGE=web DIGEST="$admin" COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "under another image"
  expect "no overlay change" equal "$(git -C "$CLONE" status --porcelain -- "$PROD_SIM_OVERLAY")" ""
}
digest_never_recorded() {
  local status=0
  promote_prod_sim IMAGE=web DIGEST="$DIGEST_B" COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "never recorded for dev"
}

# ---- promotion to prod-sim: dev must be healthy and running it
dev_healthy_and_running() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  expect "the dev promotion works" [ "$status" -eq 0 ]
  promote_prod_sim COMMIT=no || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  expect "a recorded pass" grep -q '^Promote-Dev-Check: passed' "$CLONE/.build/promote-message.txt"
  expect "the prod-sim overlay moved" equal "$(web_digest_in "$PROD_SIM_OVERLAY")" "$DIGEST_A"
}
dev_out_of_sync() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo OutOfSync/Healthy >"$STUB/app-status"
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "Application plane-dev is OutOfSync/Healthy"
  expect "no overlay change" equal "$(git -C "$CLONE" status --porcelain -- "$PROD_SIM_OVERLAY")" ""
}
dev_degraded() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo Synced/Degraded >"$STUB/app-status"
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "Application plane-dev is Synced/Degraded"
}
dev_application_missing() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  : >"$STUB/app-status"
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal, failing closed" [ "$status" -ne 0 ]
  expect "the reason" said "Application plane-dev is unknown"
}
dev_running_another_digest() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  web_image "$DIGEST_B" true
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "no ready container in namespace plane-dev runs $DIGEST_A"
}
dev_container_not_ready() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  web_image "$DIGEST_A" false
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "no ready container in namespace plane-dev runs $DIGEST_A"
}
no_cluster_says_skipped() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo down >"$STUB/cluster"
  promote_prod_sim COMMIT=no || status=$?
  expect "the promotion goes ahead, as CI needs" [ "$status" -eq 0 ]
  expect "the skip is printed" said "plane-dev check skipped"
  expect "the skip is in the commit message" grep -q '^Promote-Dev-Check: skipped' "$CLONE/.build/promote-message.txt"
}
override_is_logged() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo OutOfSync/Degraded >"$STUB/app-status"
  promote_prod_sim COMMIT=no OVERRIDE_DEV_CHECK="dev is down for maintenance" || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  expect "the override is printed" said "OVERRIDE_DEV_CHECK: promoting anyway"
  expect "the commit message keeps the reason" grep -q '^Promote-Dev-Check: overridden: dev is down for maintenance' "$CLONE/.build/promote-message.txt"
  expect "the log keeps reason and state" grep -q 'dev is down for maintenance.*OutOfSync/Degraded' "$CLONE/.local/evidence-raw/promotion-overrides.log"
}
override_unused_when_dev_is_fine() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  promote_prod_sim COMMIT=no OVERRIDE_DEV_CHECK="not needed" || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  expect "a pass, not an override" grep -q '^Promote-Dev-Check: passed' "$CLONE/.build/promote-message.txt"
  expect "nothing logged" [ ! -e "$CLONE/.local/evidence-raw/promotion-overrides.log" ]
}

scenario promote-digest-under-another-image digest_under_another_image
scenario promote-digest-never-recorded digest_never_recorded
scenario promote-dev-healthy-and-running dev_healthy_and_running
scenario promote-dev-out-of-sync dev_out_of_sync
scenario promote-dev-degraded dev_degraded
scenario promote-dev-application-missing dev_application_missing
scenario promote-dev-running-another-digest dev_running_another_digest
scenario promote-dev-container-not-ready dev_container_not_ready
scenario promote-no-cluster-says-skipped no_cluster_says_skipped
scenario promote-override-is-logged override_is_logged
scenario promote-override-unused-when-dev-is-fine override_unused_when_dev_is_fine

[[ $((passed + failed)) -gt 0 ]] || die "no scenario matches '$FILTER'"
[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) promotion flow scenarios failed"
ok "$passed of $passed promotion flow scenarios passed, with a stub cluster"
