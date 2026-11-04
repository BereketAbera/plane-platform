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
DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml
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
# The drill copies its output through tee, which can outlive it by a moment.
run_drill() {
  local status=0
  printf '#!/usr/bin/env bash\nprintf 200\n' >"$CLONE/.tools/bin/curl"
  chmod +x "$CLONE/.tools/bin/curl"
  in_clone ./tests/drills/failed-deploy-rollback.sh || status=$?
  sleep 1
  return "$status"
}
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

# ---- rollback
rollback_rerun_after_failed_publish() {
  local status=0 first second revert
  promote_dev "$DIGEST_A" || status=$?
  first="$(head_commit)"
  promote_dev "$DIGEST_B" || status=$?
  second="$(head_commit)"
  expect "both promotions work" [ "$status" -eq 0 ]
  printf '#!/bin/sh\nexit 1\n' >"$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"

  status=0
  rollback dev || status=$?
  expect "the failed publish is reported" [ "$status" -ne 0 ]
  expect "the operator is told what a re-run does" said "it publishes that revert and reverts nothing else"
  revert="$(head_commit)"
  expect "one revert on main" equal "$(reverts_on_main)" 1
  expect "it is the revert of the newest promotion" grep -qF "This reverts commit $second" <(git -C "$CLONE" log -1 --format=%B)
  expect "not published" equal "$(published)" "$second"

  rm -f "$BARE/hooks/pre-receive"
  status=0
  rollback dev || status=$?
  expect "the re-run works" [ "$status" -eq 0 ]
  expect "it says it is publishing the earlier revert" said "was never published"
  expect "no second revert" equal "$(reverts_on_main)" 1
  expect "HEAD is still that revert" equal "$(head_commit)" "$revert"
  expect "published now" equal "$(published)" "$revert"
  expect "the first promotion still stands" equal "$(web_digest_in "$DEV_OVERLAY")" "$DIGEST_A"

  # And once published, a run does step back one further, as the header says.
  status=0
  rollback dev || status=$?
  expect "stepping back works" [ "$status" -eq 0 ]
  expect "two reverts now" equal "$(reverts_on_main)" 2
  expect "it reverted the first promotion" grep -qF "This reverts commit $first" <(git -C "$CLONE" log -1 --format=%B)
}
promote_prod_sim_committed() {
  # dev first, then prod-sim with a commit and a publish, so there is a prod-sim promotion to roll back.
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  promote_prod_sim || status=$?
  expect "the setup works" [ "$status" -eq 0 ]
  rm -f "$STUB/backup-calls"
}
rollback_prod_sim_with_broken_backup() {
  local status=0 promoted
  promote_prod_sim_committed
  promoted="$(web_digest_in "$DEV_OVERLAY")"
  echo fail >"$STUB/backup-mode"
  rollback prod-sim || status=$?
  expect "the rollback works anyway" [ "$status" -eq 0 ]
  expect "it says the dump failed" said "best-effort dump failed"
  expect "it says how it published" said "Publishing with SKIP_BACKUP=yes"
  expect "only its own attempt, no second from the publish" equal "$(wc -l <"$STUB/backup-calls" | tr -d ' ')" 1
  expect "published" equal "$(published)" "$(head_commit)"
  expect "prod-sim is back" not_equal_digest "$promoted"
}
not_equal_digest() { [[ "$(web_digest_in "$PROD_SIM_OVERLAY")" != "$1" ]]; }
rollback_prod_sim_with_hung_backup() {
  local status=0
  promote_prod_sim_committed
  echo hang >"$STUB/backup-mode"
  ROLLBACK_DUMP_TIMEOUT=2 rollback prod-sim || status=$?
  expect "the rollback does not wait for it" [ "$status" -eq 0 ]
  expect "it says time ran out" said "failed or ran out of time"
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_prod_sim_names_the_older_dump() {
  local status=0 older
  promote_prod_sim_committed
  older=20260101T000000Z
  mkdir -p "$CLONE/.local/backups/prod-sim/$older"
  echo '{}' >"$CLONE/.local/backups/prod-sim/$older/manifest.json"
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "it took a dump of its own" equal "$(wc -l <"$STUB/backup-calls" | tr -d ' ')" 1
  expect "it names the dump to restore from" said "BACKUP=$older"
  expect "and warns about latest" said "BACKUP=latest may name the dump taken just now"
}
rollback_prod_sim_skip_backup() {
  local status=0
  promote_prod_sim_committed
  in_clone env CONFIRM=yes SKIP_BACKUP=yes ./scripts/rollback.sh prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "no dump at all" [ ! -e "$STUB/backup-calls" ]
  expect "it says so" said "no dump taken before this rollback"
}
rollback_dev_takes_no_dump() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  rollback dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "no dump" [ ! -e "$STUB/backup-calls" ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "dev is back" equal "$(web_digest_in "$DEV_OVERLAY")" "$(git -C "$CLONE" show "$BASE:$DEV_OVERLAY" | yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest')"
}
rollback_leaves_other_staged_files_alone() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo staged >"$CLONE/docs/staged-by-someone.txt"
  git -C "$CLONE" add docs/staged-by-someone.txt
  rollback dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "the revert did not take the file" equal "$(git -C "$CLONE" show --name-only --format= HEAD | grep -c staged-by-someone || true)" 0
  expect "it is still staged" equal "$(git -C "$CLONE" diff --cached --name-only)" docs/staged-by-someone.txt
  git -C "$CLONE" reset --quiet
  rm -f "$CLONE/docs/staged-by-someone.txt"
}

# ---- publish
publish_warns_when_ahead_of_origin() {
  local status=0
  git -C "$CLONE" update-ref refs/remotes/origin/main "$BASE"
  promote_dev "$DIGEST_A" || status=$?
  expect "it publishes anyway" [ "$status" -eq 0 ]
  expect "the warning" said "not on origin/main"
  expect "published" equal "$(published)" "$(head_commit)"
}
publish_quiet_when_level_with_origin() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  git -C "$CLONE" update-ref refs/remotes/origin/main "$(head_commit)"
  in_clone git commit --quiet --allow-empty -m 'another commit'
  git -C "$CLONE" update-ref refs/remotes/origin/main "$(head_commit)"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "no warning" not_said "not on origin/main"
}
publish_says_when_origin_is_unknown() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says it cannot tell" said "origin/main is unknown"
}
publish_still_backs_up_prod_sim_change() {
  # The flow a merged pull request takes: no SKIP_BACKUP, so the publish takes the dump.
  local status=0
  in_clone env SKIP_REGISTRY_CHECK=yes COMMIT=no ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A" || status=$?
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -m 'promote(dev): by hand'
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes COMMIT=no ./scripts/promote.sh prod-sim || status=$?
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -m 'promote(prod-sim): by hand'
  expect "the setup works" [ "$status" -eq 0 ]
  # The stub kubectl answers no statefulset question, so gitops-publish falls through to the backup.
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "the publish works" [ "$status" -eq 0 ]
  expect "it took the dump" equal "$(wc -l <"$STUB/backup-calls" | tr -d ' ')" 1
}

# ---- the failed-deploy drill, with Traefik stubbed too
drill_runs_to_a_pass() {
  local status=0
  run_drill || status=$?
  expect "the drill passes" [ "$status" -eq 0 ]
  expect "RESULT PASS" said "RESULT PASS"
  expect "promotion and revert on main" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
drill_failed_promotion_reverts_nothing_else() {
  # A real promotion is on main, then the drill's own promotion fails before its commit: stale render.
  local status=0 before
  promote_dev "$DIGEST_A" || status=$?
  printf '# stale\n' >>"$CLONE/gitops/environments/dev/manifests.yaml"
  git -C "$CLONE" add -- gitops
  git -C "$CLONE" commit --quiet -m 'a change that leaves the render stale'
  before="$(head_commit)"
  status=0
  run_drill || status=$?
  expect "the drill fails" [ "$status" -ne 0 ]
  expect "it says nothing needs reverting" said "the bad digest never reached main"
  expect "HEAD did not move" equal "$(head_commit)" "$before"
  expect "no revert" equal "$(reverts_on_main)" 0
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
scenario rollback-rerun-after-failed-publish rollback_rerun_after_failed_publish
scenario rollback-prod-sim-with-broken-backup rollback_prod_sim_with_broken_backup
scenario rollback-prod-sim-with-hung-backup rollback_prod_sim_with_hung_backup
scenario rollback-prod-sim-names-the-older-dump rollback_prod_sim_names_the_older_dump
scenario rollback-prod-sim-skip-backup rollback_prod_sim_skip_backup
scenario rollback-dev-takes-no-dump rollback_dev_takes_no_dump
scenario rollback-leaves-other-staged-files-alone rollback_leaves_other_staged_files_alone
scenario publish-warns-when-ahead-of-origin publish_warns_when_ahead_of_origin
scenario publish-quiet-when-level-with-origin publish_quiet_when_level_with_origin
scenario publish-says-when-origin-is-unknown publish_says_when_origin_is_unknown
scenario publish-still-backs-up-prod-sim-change publish_still_backs_up_prod_sim_change
scenario drill-runs-to-a-pass drill_runs_to_a_pass
scenario drill-failed-promotion-reverts-nothing-else drill_failed_promotion_reverts_nothing_else

[[ $((passed + failed)) -gt 0 ]] || die "no scenario matches '$FILTER'"
[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) promotion flow scenarios failed"
ok "$passed of $passed promotion flow scenarios passed, with a stub cluster"
