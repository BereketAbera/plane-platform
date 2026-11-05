#!/usr/bin/env bash
# Behaviour of promote.sh, rollback.sh, gitops-publish.sh and the failed-deploy drill, against a stub
# kubectl and a stub backup, in a throwaway clone with its own bare repository. Nothing here can reach
# a cluster or the real Git remote: KUBECONFIG, the bare repository and every tool on PATH belong to
# the clone. It runs what is on disk, so it tests a change before it is committed.
#
#   scripts/ci/test-promotion-flows.sh           every scenario, about three minutes
#   scripts/ci/test-promotion-flows.sh rollback  only the scenarios whose name contains "rollback"
#
# The repository's overlays are no input here. make promote changes them for real, and prod-sim level
# with dev and prod-sim behind it are both normal, so a result must not depend on which one the checkout
# is in. The clone gets both states of its own, at digests no registry has, and a scenario names the one
# it starts from. Its history stays, and no scenario reaches past the state it starts from.
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
echo "$*" >>"$STUB/kubectl-calls"
[[ "$(cat "$STUB/cluster")" == up ]] || exit 1
current_web_image() { yq -N -r 'select(.kind == "Deployment" and .metadata.name == "plane-web-wl") | .spec.template.spec.containers[0].image' "$CLONE/gitops/environments/dev/manifests.yaml"; }
web_is_bad() { current_web_image | grep -qF "@$BAD_DIGEST"; }
case "$args" in
  *" get --raw /readyz "*) exit 0 ;;
  *" get statefulset plane-pgdb-wl "*) cat "$STUB/prod-sim-database" ;;
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
git -C "$CLONE" status --porcelain -- helm gitops >>"$STUB/backup-saw-changes"
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
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
OUT="$WORK/output"
FAILURES="$WORK/scenario-failures"

git -C "$CLONE" add -A -- scripts tests/drills >/dev/null
git -C "$CLONE" commit --quiet --allow-empty -m 'scripts under test'

# ---- The states a scenario starts from.
#   BASE        prod-sim level with dev
#   BASE_AHEAD  dev ahead of prod-sim by four images, from another repository and with no tag. That is
#               the plan the first promotion of the branded images makes.
made_up_digest() { printf 'sha256:%s%063x' "$1" "$2"; } # made_up_digest <first hex digit> <number>
set_image() { (cd "$CLONE/helm/plane/overlays/$1" && kustomize edit set image "$2=$3"); } # set_image <env> <image name> <reference>
fixture_commit() {
  (cd "$CLONE" && ./scripts/render.sh) >/dev/null
  git -C "$CLONE" add -A -- helm gitops
  git -C "$CLONE" commit --quiet -m "$1"
  git -C "$CLONE" rev-parse HEAD
}

image_number=0
AHEAD_NAMES=()
AHEAD_REPOS=()
AHEAD_DIGESTS=()
while read -r image_name; do
  image_number=$((image_number + 1))
  short_name="${image_name##*/}"
  set_image dev "$image_name" "docker.io/fixture/$short_name:v0@$(made_up_digest 1 "$image_number")"
  set_image prod-sim "$image_name" "docker.io/fixture/$short_name:v0@$(made_up_digest 1 "$image_number")"
  case "$short_name" in
    plane-admin | plane-backend | plane-frontend | plane-space)
      AHEAD_NAMES+=("$image_name")
      AHEAD_REPOS+=("localhost:5001/fixture/$short_name")
      AHEAD_DIGESTS+=("$(made_up_digest 2 "$image_number")")
      ;;
  esac
done < <(yq -r '.images[].name' "$CLONE/$DEV_OVERLAY")
[[ ${#AHEAD_NAMES[@]} -eq 4 ]] || die "the fixture wants four images to move and found ${#AHEAD_NAMES[@]} in $DEV_OVERLAY"
BASE="$(fixture_commit 'fixture: prod-sim level with dev')"
for index in 0 1 2 3; do
  set_image dev "${AHEAD_NAMES[$index]}" "${AHEAD_REPOS[$index]}@${AHEAD_DIGESTS[$index]}"
done
BASE_AHEAD="$(fixture_commit 'fixture: dev ahead of prod-sim by four images')"

admin_digest() { yq -r '.images[] | select(.name | test("plane-admin$")) | .digest' "$CLONE/$PROD_SIM_OVERLAY"; }
web_digest_in() { yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest' "$CLONE/$1"; }
web_image() { # A pod list with one ready container running this digest of web, or one not yet ready.
  cat >"$STUB/pods.json" <<JSON
{"items":[{"metadata":{"name":"web-1"},"status":{"phase":"Running","containerStatuses":[{"name":"web","ready":$2}]},
"spec":{"containers":[{"name":"web","image":"docker.io/makeplane/plane-frontend:v1.4.3@$1"}]}}]}
JSON
}

images_of() { yq -r '.images[] | .name + " " + (.newName // "-") + " " + (.newTag // "-") + " " + .digest' "$CLONE/$1"; }
dev_runs_its_overlay() { # dev_runs_its_overlay [<digest left out>] [<digest not ready>]: a ready container for every other image
  local left_out="${1:-}" not_ready="${2:-}" comma="" name repo digest ready
  {
    printf '{"items":['
    while read -r name repo digest; do
      [[ "$digest" != "$left_out" ]] || continue
      ready=true
      [[ "$digest" != "$not_ready" ]] || ready=false
      printf '%s{"metadata":{"name":"%s"},"status":{"phase":"Running","containerStatuses":[{"name":"main","ready":%s}]},' "$comma" "${name##*/}" "$ready"
      printf '"spec":{"containers":[{"name":"main","image":"%s@%s"}]}}' "$repo" "$digest"
      comma=,
    done < <(yq -r '.images[] | .name + " " + .newName + " " + .digest' "$CLONE/$DEV_OVERLAY")
    printf ']}\n'
  } >"$STUB/pods.json"
}
registry_lacks() { # registry_lacks [<digest>]: a local registry that has every other digest, and notes what it was asked
  printf '%s\n' "${1:-}" >"$STUB/registry-lacks"
  cat >"$CLONE/.tools/bin/curl" <<'STUB_CURL'
#!/usr/bin/env bash
echo "$*" >>"$STUB/curl-calls"
lacks="$(cat "$STUB/registry-lacks")"
if [[ -n "$lacks" && "$*" == *"$lacks"* ]]; then exit 22; fi
STUB_CURL
  chmod +x "$CLONE/.tools/bin/curl"
}

reset_clone() { # reset_clone <commit to start from>
  git -C "$CLONE" reset --quiet --hard "$1"
  git -C "$CLONE" update-ref -d refs/remotes/origin/main 2>/dev/null || true
  git -C "$CLONE" clean --quiet -fd -- helm gitops
  rm -rf "$CLONE/.local/git" "$CLONE/.local/backups" "$CLONE/.local/evidence-raw" "$CLONE/.build" "$STUB/backup-calls" "$STUB/backup-saw-changes" "$STUB/kubectl-calls" "$STUB/curl-calls"
  echo statefulset.apps/plane-pgdb-wl >"$STUB/prod-sim-database"
  rm -f "$CLONE/.tools/bin/curl"
  touch "$CLONE/.local/kubeconfig"
  echo up >"$STUB/cluster"
  echo Synced/Healthy >"$STUB/app-status"
  echo ok >"$STUB/backup-mode"
  web_image "$DIGEST_A" true
  : >"$OUT"
  # A published main to start from, as a running platform has. Quiet about origin, which a clone lacks.
  (cd "$CLONE" && ./scripts/gitops-publish.sh) >/dev/null 2>&1 || die "the starting state could not be published"
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
backup_calls() { if [[ -e "$STUB/backup-calls" ]]; then wc -l <"$STUB/backup-calls" | tr -d ' '; else echo 0; fi; }
OVERRIDE_LOG="$CLONE/.local/evidence-raw/promotion-overrides.log"

expect() { # expect <description> <command...>: one assertion inside a scenario
  local what="$1"
  shift
  if "$@"; then return 0; fi
  warn "  expected: $what"
  printf '%s\n' "$what" >>"$FAILURES"
}
said() { grep -qF -- "$1" "$OUT"; }
not_said() { ! grep -qF -- "$1" "$OUT"; }
equal() { [[ "$1" == "$2" ]]; }

scenario() { # scenario <name> <function> [<commit to start from, BASE by default>]
  [[ -z "$FILTER" || "$1" == *"$FILTER"* ]] || return 0
  local stopped=0
  reset_clone "${3:-$BASE}"
  : >"$FAILURES"
  # A command that fails in a scenario's own setup ends that scenario and not the run, or every scenario
  # after it goes unread. Not under `if`, which would switch errexit off inside the function.
  set +e
  (
    set -e
    "$2"
  )
  stopped=$?
  set -e
  if [[ "$stopped" -ne 0 ]]; then
    warn "  a command in the scenario itself failed, with status $stopped"
    printf 'stopped\n' >>"$FAILURES"
  fi
  if [[ ! -s "$FAILURES" ]]; then
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
  expect "the override is printed" said "OVERRIDE_DEV_CHECK: going ahead anyway"
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
  expect "only its own attempt, no second from the publish" equal "$(backup_calls)" 1
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
  expect "it took a dump of its own" equal "$(backup_calls)" 1
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
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "the publish works" [ "$status" -eq 0 ]
  expect "it took the dump" equal "$(backup_calls)" 1
}
publish_warns_when_a_shared_change_reaches_prod_sim() {
  local status=0
  cat >>"$CLONE/helm/plane/components/hardening/serviceaccounts.yaml" <<'YAML'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flow-test
automountServiceAccountToken: false
YAML
  commit_a_change_to_helm 'a change to the hardening component'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes anyway" [ "$status" -eq 0 ]
  expect "the warning" said "that are not images"
  expect "it says who gets it" said "they reach dev and prod-sim together"
  expect "it names the source" said "helm/plane/components/hardening/serviceaccounts.yaml"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "no dump" equal "$(backup_calls)" 0
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
}
publish_warns_when_the_chart_reaches_prod_sim() {
  local status=0 template
  template="$(cd "$CLONE" && find helm/plane/vendor -type f -path '*/templates/*.yaml' | LC_ALL=C sort | head -n 1)"
  printf '\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: flow-test\n' >>"$CLONE/$template"
  commit_a_change_to_helm 'a change to the vendored chart'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes anyway" [ "$status" -eq 0 ]
  expect "the warning" said "they reach dev and prod-sim together"
  expect "it names the source" said "$template"
  expect "published" equal "$(published)" "$(head_commit)"
}
publish_warns_when_only_prod_sim_changes() {
  local status=0
  printf 'commonAnnotations:\n  flow-test: "yes"\n' >>"$CLONE/$PROD_SIM_OVERLAY"
  commit_a_change_to_helm 'a change to the prod-sim overlay alone'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes anyway" [ "$status" -eq 0 ]
  expect "the warning" said "that are not images"
  expect "dev is not in it" said "they reach prod-sim with this push"
}
publish_warns_and_checks_a_mixed_push() {
  # A shared change committed and not published, then a promotion, which publishes all of main.
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  printf -- '---\napiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: flow-test\nautomountServiceAccountToken: false\n' >>"$CLONE/helm/plane/components/hardening/serviceaccounts.yaml"
  commit_a_change_to_helm 'a change to the hardening component'
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "the image is checked on dev" said "passed: plane-dev was Synced and Healthy"
  expect "the promotion took its dump" equal "$(backup_calls)" 1
  expect "the rest is still called out" said "they reach dev and prod-sim together"
  expect "published" equal "$(published)" "$(head_commit)"
}
publish_quiet_when_a_shared_change_renders_to_nothing() {
  local status=0
  printf '# only a comment\n' >>"$CLONE/helm/plane/components/hardening/serviceaccounts.yaml"
  commit_a_change_to_helm 'a comment in the hardening component'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "no warning" not_said "that are not images"
  expect "published" equal "$(published)" "$(head_commit)"
}
publish_quiet_when_only_dev_changes() {
  local status=0
  printf 'commonAnnotations:\n  flow-test: "yes"\n' >>"$CLONE/$DEV_OVERLAY"
  commit_a_change_to_helm 'a change to the dev overlay alone'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "no warning" not_said "that are not images"
}
commit_a_change_to_helm() { # commit_a_change_to_helm <subject>: renders what is on disk and commits it, as a person would
  in_clone ./scripts/render.sh
  git -C "$CLONE" add -A -- helm gitops
  git -C "$CLONE" commit --quiet -m "$1"
}

# ---- publish: a promotion merged on GitHub has to prove itself on plane-dev here
merged_prod_sim_promotion() {
  # What a merged pull request leaves: dev promoted and published, then a prod-sim commit made where no
  # cluster was in reach, so it says the check was skipped, and it has not been published.
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo down >"$STUB/cluster"
  promote_prod_sim COMMIT=no || status=$?
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  echo up >"$STUB/cluster"
  expect "the setup works" [ "$status" -eq 0 ]
  expect "the commit says the check was skipped" grep -q '^Promote-Dev-Check: skipped' <(git -C "$CLONE" log -1 --format=%B)
  PUBLISHED_BEFORE="$(published)"
  rm -f "$STUB/backup-calls" "$STUB/kubectl-calls"
}
expect_refused() { # expect_refused <exit status> <the reason it must print>
  expect "a refusal" [ "$1" -ne 0 ]
  expect "the reason" said "$2"
  expect "the way out" said "OVERRIDE_DEV_CHECK"
  expect "it says nothing was published" said "Nothing was published"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
  expect "a refused publish takes no dump" equal "$(backup_calls)" 0
}
merged_dev_proven() {
  local status=0
  merged_prod_sim_promotion
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says the check passed" said "passed: plane-dev was Synced and Healthy"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "it took the dump" equal "$(backup_calls)" 1
}
merged_dev_out_of_sync() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Healthy >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is OutOfSync/Healthy"
}
merged_dev_degraded() {
  local status=0
  merged_prod_sim_promotion
  echo Synced/Degraded >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is Synced/Degraded"
}
merged_dev_application_missing() {
  local status=0
  merged_prod_sim_promotion
  : >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is unknown"
}
merged_dev_running_another_digest() {
  local status=0
  merged_prod_sim_promotion
  web_image "$DIGEST_B" true
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "no ready container in namespace plane-dev runs $DIGEST_A"
}
merged_dev_container_not_ready() {
  local status=0
  merged_prod_sim_promotion
  web_image "$DIGEST_A" false
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "no ready container in namespace plane-dev runs $DIGEST_A"
}
merged_override_is_logged() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone env OVERRIDE_DEV_CHECK="dev is down for maintenance" ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "the override is printed" said "OVERRIDE_DEV_CHECK: going ahead anyway"
  expect "the log keeps script, reason and state" grep -q 'gitops-publish.sh.overridden.*dev is down for maintenance.*OutOfSync/Degraded' "$OVERRIDE_LOG"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "the dump is still taken" equal "$(backup_calls)" 1
}
merged_refused_then_retried() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Healthy >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is OutOfSync/Healthy"
  echo Synced/Healthy >"$STUB/app-status"
  status=0
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes once dev is fine" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
}
merged_no_cluster_says_skipped() {
  local status=0
  merged_prod_sim_promotion
  echo down >"$STUB/cluster"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "the skip is printed" said "plane-dev check skipped"
  expect "published" equal "$(published)" "$(head_commit)"
}
skip_backup_is_no_way_past() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is OutOfSync/Degraded"
  status=0
  in_clone env SKIP_BACKUP=yes SKIP_DEV_CHECK= ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is OutOfSync/Degraded"
}
skip_dev_check_is_recorded() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone env SKIP_BACKUP=yes SKIP_DEV_CHECK="a reason" ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says so" said "plane-dev check not run for this publish: a reason"
  expect "the log keeps the reason and the digest" grep -q "not-run.*$DIGEST_A.*a reason" "$OVERRIDE_LOG"
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
}
prod_sim_not_deployed() {
  # make up after make destroy: the bare repository is older than main, and nothing is running yet.
  local status=0
  merged_prod_sim_promotion
  : >"$STUB/prod-sim-database"
  : >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says why" said "nothing running for the plane-dev check to protect"
  expect "no dump" equal "$(backup_calls)" 0
  expect "published" equal "$(published)" "$(head_commit)"
}
dev_change_needs_no_dev_check() {
  # A fix for a broken dev has to be able to reach dev.
  local status=0
  echo OutOfSync/Degraded >"$STUB/app-status"
  promote_dev "$DIGEST_A" || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
  expect "published" equal "$(published)" "$(head_commit)"
}
promote_override_reaches_the_publish() {
  # With a commit, promote.sh publishes, and the publish asks again. The override has to carry through.
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo OutOfSync/Degraded >"$STUB/app-status"
  promote_prod_sim OVERRIDE_DEV_CHECK="dev is down for maintenance" || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "both are logged" equal "$(grep -c 'dev is down for maintenance' "$OVERRIDE_LOG")" 2
}
rollback_prod_sim_with_unhealthy_dev() {
  local status=0
  promote_prod_sim_committed
  echo OutOfSync/Degraded >"$STUB/app-status"
  web_image "$DIGEST_B" false
  rm -f "$STUB/kubectl-calls"
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "it says the check was not run" said "plane-dev check not run for this publish: rollback of"
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
  expect "the log keeps the reason" grep -q 'gitops-publish.sh.not-run.*rollback of' "$OVERRIDE_LOG"
  expect "the revert commit says so" grep -q '^Promote-Dev-Check: not run' <(git -C "$CLONE" log -1 --format=%B)
}
rollback_prod_sim_rerun_with_unhealthy_dev() {
  local status=0
  promote_prod_sim_committed
  echo OutOfSync/Degraded >"$STUB/app-status"
  printf '#!/bin/sh\nexit 1\n' >"$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  rollback prod-sim || status=$?
  expect "the failed publish is reported" [ "$status" -ne 0 ]
  rm -f "$BARE/hooks/pre-receive"
  status=0
  rollback prod-sim || status=$?
  expect "the re-run works" [ "$status" -eq 0 ]
  expect "no second revert" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
  expect "the log keeps the reason" grep -q 'gitops-publish.sh.not-run.*rollback of' "$OVERRIDE_LOG"
}
make_passes_the_documented_options() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone make promote ENV=prod-sim COMMIT=no CONFIRM=yes SKIP_BACKUP=yes SKIP_REGISTRY_CHECK=yes OVERRIDE_DEV_CHECK="through make" || status=$?
  expect "make promote works" [ "$status" -eq 0 ]
  expect "the reason reached the script" grep -q '^Promote-Dev-Check: overridden: through make' "$CLONE/.build/promote-message.txt"
  git -C "$CLONE" restore --source=HEAD --staged --worktree -- helm gitops
  in_clone make rollback ENV=dev SKIP_BACKUP=yes ROLLBACK_DUMP_TIMEOUT=5 || status=$?
  expect "make rollback works" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
}

# ---- prod-sim level with dev: nothing to do, and nothing asked of anyone
level_has_nothing_to_promote() {
  local status=0 before
  before="$(head_commit)"
  in_clone make promote ENV=prod-sim CONFIRM=yes || status=$?
  expect "it succeeds" [ "$status" -eq 0 ]
  expect "it says so" said "prod-sim already runs these digests"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "no message for the workflow to find" [ ! -e "$CLONE/.build/promote-message.txt" ]
  expect "no dump" equal "$(backup_calls)" 0
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
}

# ---- prod-sim behind dev by four images: one plan, one dump, one commit, and each digest checked
changes_nothing_since() { # changes_nothing_since <commit>
  [[ "$(head_commit)" == "$1" && "$(published)" == "$1" && -z "$(git -C "$CLONE" status --porcelain -- helm gitops)" ]]
}
four_images_through_make() {
  local status=0 before index digest
  before="$(head_commit)"
  dev_runs_its_overlay
  registry_lacks
  # Other work goes on in this checkout, so what someone else has staged must stay out of the commit.
  echo staged >"$CLONE/docs/staged-by-someone.txt"
  git -C "$CLONE" add docs/staged-by-someone.txt
  in_clone make promote ENV=prod-sim CONFIRM=yes || status=$?
  expect "the promotion works" [ "$status" -eq 0 ]
  expect "the staged file is still staged" equal "$(git -C "$CLONE" diff --cached --name-only)" docs/staged-by-someone.txt
  git -C "$CLONE" reset --quiet
  rm -f "$CLONE/docs/staged-by-someone.txt"
  for index in 0 1 2 3; do
    digest="${AHEAD_DIGESTS[$index]}"
    expect "the plan names $digest" said "${AHEAD_NAMES[$index]##*/} -> ${AHEAD_REPOS[$index]}@$digest"
    expect "the registry was asked for $digest" grep -qF "/manifests/$digest" "$STUB/curl-calls"
    expect "the commit records $digest" grep -qxF "Promote-Image: ${AHEAD_NAMES[$index]##*/}=${AHEAD_REPOS[$index]}@$digest" <(git -C "$CLONE" log -1 --format=%B)
  done
  expect "each digest was checked against dev's history" equal "$(grep -c 'recorded for dev under the same name' "$OUT")" 4
  expect "prod-sim's images are dev's, with no tag left on the four" equal "$(images_of "$PROD_SIM_OVERLAY")" "$(images_of "$DEV_OVERLAY")"
  expect "one commit" equal "$(git -C "$CLONE" rev-list --count "$before..HEAD")" 1
  expect "of the overlay and its render only" equal "$(git -C "$CLONE" show --name-only --format= HEAD | LC_ALL=C sort | tr '\n' ' ')" "$PROD_SIM_RENDERED $PROD_SIM_OVERLAY "
  expect "only image lines changed in the render" equal "$(git -C "$CLONE" diff -U0 "$before" HEAD -- "$PROD_SIM_RENDERED" | grep -E '^[-+]' | grep -vcE '^(---|\+\+\+) |^[-+][[:space:]-]*image: ')" 0
  expect "no warning about anything but images" not_said "that are not images"
  expect "a recorded pass" grep -q '^Promote-Dev-Check: passed' <(git -C "$CLONE" log -1 --format=%B)
  expect "dev was asked by the promotion and again by the publish" equal "$(grep -c 'get pods -o json' "$STUB/kubectl-calls")" 2
  expect "one dump" equal "$(backup_calls)" 1
  expect "the dump came before any change" [ ! -s "$STUB/backup-saw-changes" ]
  expect "published" equal "$(published)" "$(head_commit)"
  in_clone ./scripts/ci/check-promoted-digests.sh || status=$?
  expect "the invariant CI checks holds" [ "$status" -eq 0 ]
  in_clone ./scripts/render.sh --check || status=$?
  expect "the render is current" [ "$status" -eq 0 ]
  in_clone make promote ENV=prod-sim CONFIRM=yes || status=$?
  expect "a second run has nothing to do" said "prod-sim already runs these digests"
  expect "and takes no second dump" equal "$(backup_calls)" 1
}
four_images_one_at_a_time() {
  # The workflow's image and digest inputs. The digest's repository travels with it, and the other three stay.
  local status=0 before
  before="$(images_of "$PROD_SIM_OVERLAY")"
  dev_runs_its_overlay "${AHEAD_DIGESTS[0]}"
  promote_prod_sim COMMIT=no IMAGE=web DIGEST="$(web_digest_in "$DEV_OVERLAY")" || status=$?
  expect "it goes ahead, whatever dev runs of the other three" [ "$status" -eq 0 ]
  expect "one image in the plan" equal "$(grep -c 'recorded for dev under the same name' "$OUT")" 1
  expect "web moved with its repository" equal "$(grep -c 'plane-frontend localhost:5001/fixture/plane-frontend - ' <<<"$(images_of "$PROD_SIM_OVERLAY")")" 1
  expect "and nothing else" equal "$(diff <(cat <<<"$before") <(images_of "$PROD_SIM_OVERLAY") | grep -c '^>')" 1
}
four_images_each_must_run_in_dev() {
  local status before digest
  before="$(head_commit)"
  for digest in "${AHEAD_DIGESTS[@]}"; do
    dev_runs_its_overlay "$digest"
    status=0
    in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
    expect "a refusal when no pod runs $digest" [ "$status" -ne 0 ]
    expect "it names $digest" said "no ready container in namespace plane-dev runs $digest"
    expect "and no other" equal "$(grep -c 'no ready container' "$OUT")" 1
    dev_runs_its_overlay "" "$digest"
    status=0
    in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
    expect "a refusal when $digest is not ready" [ "$status" -ne 0 ]
    expect "it names $digest" said "no ready container in namespace plane-dev runs $digest"
  done
  dev_runs_its_overlay "${AHEAD_DIGESTS[0]}" "${AHEAD_DIGESTS[3]}"
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal for two at once" [ "$status" -ne 0 ]
  expect "it names both" equal "$(grep -c 'no ready container' "$OUT")" 2
  expect "nothing moved" changes_nothing_since "$before"
  expect "a refused promotion takes no dump" equal "$(backup_calls)" 0
}
four_images_each_must_be_recorded() {
  # Digests in dev's overlay on disk that no commit holds. The plan runs in overlay order, so the count
  # of passes before the refusal shows the loop reached that image and read the rest of the plan intact.
  local status before index digest
  before="$(head_commit)"
  dev_runs_its_overlay
  for index in 0 1 2 3; do
    digest="$(made_up_digest 3 "$index")"
    set_image dev "${AHEAD_NAMES[$index]}" "${AHEAD_REPOS[$index]}@$digest"
    status=0
    promote_prod_sim || status=$?
    expect "a refusal for $digest" [ "$status" -ne 0 ]
    expect "it says why" said "$digest was never recorded for dev"
    expect "the plan's earlier images passed first" equal "$(grep -c 'recorded for dev under the same name' "$OUT")" "$index"
    git -C "$CLONE" restore -- "$DEV_OVERLAY"
  done
  expect "nothing moved" changes_nothing_since "$before"
}
four_images_each_must_be_in_the_registry() {
  local status before digest
  before="$(head_commit)"
  dev_runs_its_overlay
  for digest in "${AHEAD_DIGESTS[@]}"; do
    registry_lacks "$digest"
    status=0
    in_clone env SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
    expect "a refusal for $digest" [ "$status" -ne 0 ]
    expect "it says why" said "$digest is not in the local registry"
  done
  expect "nothing moved" changes_nothing_since "$before"
}
four_images_override_names_them_all() {
  local status=0 digest
  printf '{"items":[]}\n' >"$STUB/pods.json"
  promote_prod_sim OVERRIDE_DEV_CHECK="dev is down for maintenance" || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  for digest in "${AHEAD_DIGESTS[@]}"; do
    expect "the log keeps $digest" grep -q "promote.sh.overridden.*$digest" "$OVERRIDE_LOG"
    expect "and the publish's check of it" grep -q "gitops-publish.sh.overridden.*$digest" "$OVERRIDE_LOG"
  done
  expect "prod-sim's images are dev's" equal "$(images_of "$PROD_SIM_OVERLAY")" "$(images_of "$DEV_OVERLAY")"
  expect "published" equal "$(published)" "$(head_commit)"
}
four_images_merged_checks_each() {
  # What the promotion workflow leaves: the commit made where no cluster was in reach, not yet published.
  local status=0 digest
  echo down >"$STUB/cluster"
  promote_prod_sim COMMIT=no || status=$?
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  echo up >"$STUB/cluster"
  expect "the setup works" [ "$status" -eq 0 ]
  expect "the commit says the check was skipped" grep -q '^Promote-Dev-Check: skipped' <(git -C "$CLONE" log -1 --format=%B)
  PUBLISHED_BEFORE="$(published)"
  rm -f "$STUB/kubectl-calls"
  for digest in "${AHEAD_DIGESTS[@]}"; do
    dev_runs_its_overlay "$digest"
    status=0
    in_clone ./scripts/gitops-publish.sh || status=$?
    expect_refused "$status" "no ready container in namespace plane-dev runs $digest"
  done
  dev_runs_its_overlay
  status=0
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes once dev runs all four" [ "$status" -eq 0 ]
  expect "it took the dump" equal "$(backup_calls)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
four_images_roll_back_together() {
  local status=0 before promoted
  before="$(head_commit)"
  dev_runs_its_overlay
  promote_prod_sim || status=$?
  expect "the setup works" [ "$status" -eq 0 ]
  promoted="$(head_commit)"
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "one revert" equal "$(reverts_on_main)" 1
  expect "of that promotion" grep -qF "This reverts commit $promoted" <(git -C "$CLONE" log -1 --format=%B)
  expect "the overlay and its render are as they were" equal "$(git -C "$CLONE" diff "$before" HEAD -- "$PROD_SIM_OVERLAY" "$PROD_SIM_RENDERED")" ""
  expect "published" equal "$(published)" "$(head_commit)"
  promote_prod_sim || status=$?
  expect "the same promotion can be made again" [ "$status" -eq 0 ]
  expect "prod-sim's images are dev's again" equal "$(images_of "$PROD_SIM_OVERLAY")" "$(images_of "$DEV_OVERLAY")"
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
scenario publish-warns-when-a-shared-change-reaches-prod-sim publish_warns_when_a_shared_change_reaches_prod_sim
scenario publish-warns-when-the-chart-reaches-prod-sim publish_warns_when_the_chart_reaches_prod_sim
scenario publish-warns-when-only-prod-sim-changes publish_warns_when_only_prod_sim_changes
scenario publish-warns-and-checks-a-mixed-push publish_warns_and_checks_a_mixed_push
scenario publish-quiet-when-a-shared-change-renders-to-nothing publish_quiet_when_a_shared_change_renders_to_nothing
scenario publish-quiet-when-only-dev-changes publish_quiet_when_only_dev_changes
scenario publish-merged-promotion-dev-proven merged_dev_proven
scenario publish-merged-promotion-dev-out-of-sync merged_dev_out_of_sync
scenario publish-merged-promotion-dev-degraded merged_dev_degraded
scenario publish-merged-promotion-dev-application-missing merged_dev_application_missing
scenario publish-merged-promotion-dev-running-another-digest merged_dev_running_another_digest
scenario publish-merged-promotion-dev-container-not-ready merged_dev_container_not_ready
scenario publish-merged-promotion-override-is-logged merged_override_is_logged
scenario publish-merged-promotion-refused-then-retried merged_refused_then_retried
scenario publish-merged-promotion-no-cluster-says-skipped merged_no_cluster_says_skipped
scenario publish-skip-backup-is-no-way-past-the-dev-check skip_backup_is_no_way_past
scenario publish-skip-dev-check-is-recorded skip_dev_check_is_recorded
scenario publish-prod-sim-not-deployed-needs-no-dev-check prod_sim_not_deployed
scenario publish-dev-change-needs-no-dev-check dev_change_needs_no_dev_check
scenario promote-override-reaches-the-publish promote_override_reaches_the_publish
scenario rollback-prod-sim-with-unhealthy-dev rollback_prod_sim_with_unhealthy_dev
scenario rollback-prod-sim-rerun-with-unhealthy-dev rollback_prod_sim_rerun_with_unhealthy_dev
scenario make-passes-the-documented-options make_passes_the_documented_options
scenario promote-level-has-nothing-to-do level_has_nothing_to_promote
scenario promote-four-images-through-make four_images_through_make "$BASE_AHEAD"
scenario promote-four-images-one-at-a-time four_images_one_at_a_time "$BASE_AHEAD"
scenario promote-four-images-each-must-run-in-dev four_images_each_must_run_in_dev "$BASE_AHEAD"
scenario promote-four-images-each-must-be-recorded four_images_each_must_be_recorded "$BASE_AHEAD"
scenario promote-four-images-each-must-be-in-the-registry four_images_each_must_be_in_the_registry "$BASE_AHEAD"
scenario promote-four-images-override-names-them-all four_images_override_names_them_all "$BASE_AHEAD"
scenario publish-merged-four-images-checks-each four_images_merged_checks_each "$BASE_AHEAD"
scenario rollback-four-images-together four_images_roll_back_together "$BASE_AHEAD"
scenario drill-runs-to-a-pass drill_runs_to_a_pass
scenario drill-failed-promotion-reverts-nothing-else drill_failed_promotion_reverts_nothing_else

[[ $((passed + failed)) -gt 0 ]] || die "no scenario matches '$FILTER'"
[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) promotion flow scenarios failed"
ok "$passed of $passed promotion flow scenarios passed, with a stub cluster"
