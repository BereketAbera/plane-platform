#!/usr/bin/env bash
# Behaviour of promote.sh, rollback.sh, gitops-publish.sh and the failed-deploy drill, against a stub
# kubectl and a stub backup, in a throwaway clone with its own bare repository. Nothing here can reach
# a cluster or the real Git remote: KUBECONFIG, the bare repository and every tool on PATH belong to
# the clone. It runs what is on disk, so it tests a change before it is committed.
#
#   scripts/ci/test-promotion-flows.sh           every scenario, about six minutes
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

# Their stub clusters are not a promotion. On GitHub, each scenario with no cluster in reach would write
# to the job's summary that the plane-dev check was skipped.
unset GITHUB_STEP_SUMMARY

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
rm -f "$CLONE/.tools/bin/kubectl" "$CLONE/.tools/bin/kustomize"

# The real one, unless $STUB/kustomize-mode says to fail a build, to end the script that is rendering as
# Ctrl-C would, or to leave .git/index.lock behind after the last build of a render, as a git add running
# at that moment would. With -after-edit it waits for an edit, so the render.sh --check before promote's
# edit passes. $STUB/index-lock-seconds lets the lock go that much later. Otherwise it stays until the
# scenario removes it.
cat >"$CLONE/.tools/bin/kustomize" <<STUB_KUSTOMIZE
#!/usr/bin/env bash
mode="\$(cat "\$STUB/kustomize-mode" 2>/dev/null || true)"
if [[ "\$1" == edit ]]; then touch "\$STUB/kustomize-edited"; fi
armed=no
case "\$mode" in
  fail | lock | end) armed=yes ;;
  *-after-edit) if [[ -e "\$STUB/kustomize-edited" ]]; then armed=yes; fi ;;
esac
if [[ "\$1" == build && "\$armed" == yes && "\$mode" == fail* ]]; then
  echo "stub kustomize: failing as told" >&2
  exit 1
fi
if [[ "\$1" == build && "\$armed" == yes && "\$mode" == end* ]]; then
  kill -TERM "\$(ps -o ppid= -p "\$PPID" | tr -d ' ')" "\$PPID"
  exit 1
fi
"$ROOT/.tools/bin/kustomize" "\$@"
status=\$?
if [[ "\$1" == build && "\$*" == *overlays/prod-sim* && "\$armed" == yes && "\$mode" == lock* ]]; then
  touch "\$CLONE/.git/index.lock"
  if [[ -e "\$STUB/index-lock-seconds" ]]; then
    (sleep "\$(cat "\$STUB/index-lock-seconds")"; rm -f "\$CLONE/.git/index.lock") >/dev/null 2>&1 &
  fi
fi
exit "\$status"
STUB_KUSTOMIZE
chmod +x "$CLONE/.tools/bin/kustomize"

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
# A dump takes minutes, and other work must not wait that long on the commit lock.
if [[ -d "$CLONE/.git/agent-commit.lockdir" ]]; then echo held >>"$STUB/backup-saw-lock"; fi
mode="$(cat "$STUB/backup-mode")"
case "$mode" in
  ok | dev-goes-bad | someone-commits | someone-publishes | someone-edits)
    id="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$CLONE/.local/backups/$1/$id"
    echo '{}' >"$CLONE/.local/backups/$1/$id/manifest.json"
    # What can happen while a dump runs: a rollout starts in dev, or other work goes on in this checkout.
    case "$mode" in
      dev-goes-bad) echo Synced/Degraded >"$STUB/app-status" ;;
      someone-commits) git -C "$CLONE" commit --quiet --allow-empty -m 'committed during the dump' ;;
      someone-publishes)
        git -C "$CLONE" commit --quiet --allow-empty -m 'committed and published during the dump'
        (cd "$CLONE" && SKIP_BACKUP=yes ./scripts/gitops-publish.sh) >/dev/null 2>&1
        ;;
      someone-edits) printf '# an edit made during the dump\n' >>"$CLONE/helm/plane/overlays/$1/kustomization.yaml" ;;
    esac
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
fixture_commit() { # A failure here must end the run with its own message, not as 58 failed scenarios.
  (cd "$CLONE" && ./scripts/render.sh) >/dev/null &&
    git -C "$CLONE" add -A -- helm gitops &&
    git -C "$CLONE" commit --quiet -m "$1" &&
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

# Pushing all of history takes a second, which would be a quarter of the time of a scenario. So the bare
# repository of each one borrows these objects, and publish-creates-the-bare-repository pushes for real.
HISTORY="$WORK/history.git"
git init --quiet --bare "$HISTORY"
git -C "$CLONE" push --quiet "$HISTORY" "$BASE_AHEAD:refs/heads/history"

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
  # Whatever a scenario that failed halfway left behind.
  rm -f "$CLONE/.git/index.lock" "$CLONE/.git/hooks/pre-commit"
  rmdir "$CLONE/.git/agent-commit.lockdir" 2>/dev/null || true
  git -C "$CLONE" revert --quit 2>/dev/null || true
  git -C "$CLONE" checkout --quiet --force -B main "$1"
  git -C "$CLONE" reset --quiet --hard "$1"
  git -C "$CLONE" update-ref -d refs/remotes/origin/main 2>/dev/null || true
  git -C "$CLONE" clean --quiet -fd -- helm gitops docs
  rm -rf "$CLONE/.local/git" "$CLONE/.local/backups" "$CLONE/.local/evidence-raw" "$CLONE/.local/publishes.log" "$CLONE/.build" "$STUB/backup-calls" "$STUB/backup-saw-changes" "$STUB/backup-saw-lock" "$STUB/kubectl-calls" "$STUB/curl-calls" \
    "$STUB/kustomize-mode" "$STUB/kustomize-edited" "$STUB/index-lock-seconds" "$STUB/lock-at-commit" "$STUB/lock-at-push"
  echo statefulset.apps/plane-pgdb-wl >"$STUB/prod-sim-database"
  rm -f "$CLONE/.tools/bin/curl"
  touch "$CLONE/.local/kubeconfig"
  echo up >"$STUB/cluster"
  echo Synced/Healthy >"$STUB/app-status"
  echo ok >"$STUB/backup-mode"
  web_image "$DIGEST_A" true
  : >"$OUT"
  # A published main to start from, as a running platform has.
  git init --quiet --bare --initial-branch=main "$BARE"
  echo "$HISTORY/objects" >"$BARE/objects/info/alternates"
  git --git-dir="$BARE" update-ref refs/heads/main "$1"
}

# stdin is not a terminal, whoever runs this, so a script that asks refuses instead of waiting.
in_clone() { (cd "$CLONE" && "$@") >"$OUT" 2>&1 </dev/null; }
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
argo_reads_web() { git --git-dir="$BARE" show "refs/heads/main:helm/plane/overlays/$1/kustomization.yaml" | yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest'; } # argo_reads_web <env>
nothing_in_progress() { [[ ! -e "$CLONE/.git/REVERT_HEAD" && ! -e "$CLONE/.git/MERGE_MSG" && ! -d "$CLONE/.git/agent-commit.lockdir" ]]; }
helm_and_gitops_clean() { [[ -z "$(git -C "$CLONE" status --porcelain -- helm gitops)" ]]; }
staged_names() { git -C "$CLONE" diff --cached --name-only | LC_ALL=C sort | tr '\n' ' '; }
failing_hook() { # failing_hook <hook path>
  printf '#!/bin/sh\necho "hook: no" >&2\nexit 1\n' >"$1"
  chmod +x "$1"
}
one_pod() { # one_pod <more metadata> <phase> <container statuses> <containers>: a pod list holding just this pod
  printf '{"items":[{"metadata":{"name":"web-1"%s},"status":{"phase":"%s","containerStatuses":[%s]},"spec":{"containers":[%s]}}]}\n' "$1" "$2" "$3" "$4" >"$STUB/pods.json"
}
web_container() { printf '{"name":"web","image":"docker.io/makeplane/plane-frontend:v1.4.3@%s"}' "$1"; }

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
  expect "the operator is told what a re-run does" said "it publishes that and reverts nothing else"
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
  expect "the attempt did not hold the commit lock" [ ! -e "$STUB/backup-saw-lock" ]
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
rollback_prod_sim_past_a_later_change_beside_the_image() {
  # The revert conflicts in the rendered file only, which render replaces. This is the emergency path.
  local status=0
  promote_prod_sim_committed
  sed -i.bak 's/imagePullPolicy, value: IfNotPresent/imagePullPolicy, value: Never/' "$CLONE/helm/plane/components/hardening/kustomization.yaml"
  rm -f "$CLONE/helm/plane/components/hardening/kustomization.yaml.bak"
  commit_a_change_to_helm 'a later change beside the image line'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "the setup works" [ "$status" -eq 0 ]
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "it says why it went on" said "conflicts only in $PROD_SIM_RENDERED"
  expect "one revert" equal "$(reverts_on_main)" 1
  expect "prod-sim's image is back" not_equal_digest "$DIGEST_A"
  expect "and the render says so" equal "$(grep -c "@$DIGEST_A" "$CLONE/$PROD_SIM_RENDERED")" 0
  expect "the later change stays" grep -q 'imagePullPolicy: Never' "$CLONE/$PROD_SIM_RENDERED"
  expect "no conflict markers" equal "$(grep -c '^<<<<<<<' "$CLONE/$PROD_SIM_RENDERED")" 0
  expect "nothing left of the conflict in the message" equal "$(git -C "$CLONE" log -1 --format=%B | grep -c '^#')" 0
  expect "the revert commit says so" grep -q '^Promote-Dev-Check: not run' <(git -C "$CLONE" log -1 --format=%B)
  expect "nothing left in progress" [ ! -e "$CLONE/.git/REVERT_HEAD" ]
  expect "clean" equal "$(git -C "$CLONE" status --porcelain -- helm gitops)" ""
  expect "published" equal "$(published)" "$(head_commit)"
  in_clone ./scripts/render.sh --check || status=$?
  expect "the render is current" [ "$status" -eq 0 ]
}
rollback_dev_past_a_later_change_beside_the_image() {
  # The same for the other environment, whose rollback drills use.
  local status=0
  promote_dev "$DIGEST_A"
  sed -i.bak 's/imagePullPolicy, value: IfNotPresent/imagePullPolicy, value: Never/' "$CLONE/helm/plane/components/hardening/kustomization.yaml"
  rm -f "$CLONE/helm/plane/components/hardening/kustomization.yaml.bak"
  commit_a_change_to_helm 'a later change beside the image line'
  in_clone ./scripts/gitops-publish.sh
  rollback dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "it says why it went on" said "conflicts only in gitops/environments/dev/manifests.yaml"
  expect "dev's image is back" [ "$(web_digest_in "$DEV_OVERLAY")" != "$DIGEST_A" ]
  expect "the later change stays" grep -q 'imagePullPolicy: Never' "$CLONE/gitops/environments/dev/manifests.yaml"
  expect "published" equal "$(published)" "$(head_commit)"
  in_clone ./scripts/render.sh --check || status=$?
  expect "the render is current" [ "$status" -eq 0 ]
}
rollback_stops_on_a_conflict_in_the_overlay() {
  local status=0 before
  promote_prod_sim_committed
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_B"
  commit_a_change_to_helm 'a digest changed by hand, so not a promotion'
  before="$(head_commit)"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "the revert conflicts with a later change to helm/plane/overlays/prod-sim"
  expect "git's own words are shown" said "could not revert"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "nothing left in progress" [ ! -e "$CLONE/.git/REVERT_HEAD" ]
  expect "nothing changed" equal "$(git -C "$CLONE" status --porcelain -- helm gitops)" ""
}
rollback_dev_takes_no_dump() {
  local status=0
  promote_dev "$DIGEST_A" || status=$?
  rollback dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "no dump" [ ! -e "$STUB/backup-calls" ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "dev is back" equal "$(web_digest_in "$DEV_OVERLAY")" "$(git -C "$CLONE" show "$BASE:$DEV_OVERLAY" | yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest')"
  expect "no waiver: only a rollback of prod-sim has one" not_said "SKIP_DEV_CHECK"
  expect "nothing logged" [ ! -e "$OVERRIDE_LOG" ]
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
  # A fix for a broken dev has to be able to reach dev, when nothing is waiting for prod-sim.
  # publish-names-the-prod-sim-commit-a-dev-change-waits-behind is what happens when something is.
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
  expect "the dump did not hold the commit lock" [ ! -e "$STUB/backup-saw-lock" ]
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
  expect "and nothing else" equal "$(diff <(printf '%s\n' "$before") <(images_of "$PROD_SIM_OVERLAY") | grep -c '^>')" 1
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

# ---- what the pods in plane-dev have to show
refused_by_the_pods() { # The promotion of $DIGEST_A stops at what $STUB/pods.json shows.
  local status=0
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "no ready container in namespace plane-dev runs $DIGEST_A"
  expect "no overlay change" helm_and_gitops_clean
}
terminating_pod_proves_nothing() {
  promote_dev "$DIGEST_A"
  one_pod ',"deletionTimestamp":"2026-11-05T00:00:00Z"' Running '{"name":"web","ready":true}' "$(web_container "$DIGEST_A")"
  refused_by_the_pods
}
pod_not_running_proves_nothing() {
  promote_dev "$DIGEST_A"
  one_pod '' Failed '{"name":"web","ready":true}' "$(web_container "$DIGEST_A")"
  refused_by_the_pods
}
ready_sibling_proves_nothing() {
  promote_dev "$DIGEST_A"
  one_pod '' Running '{"name":"web","ready":false},{"name":"sidecar","ready":true}' \
    "$(web_container "$DIGEST_A"),{\"name\":\"sidecar\",\"image\":\"docker.io/fixture/sidecar@$DIGEST_B\"}"
  refused_by_the_pods
}

# ---- what a promotion refuses before it touches anything
failure_drill_digest_stays_out_of_prod_sim() {
  local status=0
  promote_dev "$BAD_DIGEST"
  web_image "$BAD_DIGEST" true
  promote_prod_sim COMMIT=no || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "is the failure-drill digest and may not reach prod-sim"
  expect "no overlay change" helm_and_gitops_clean
}
promote_stops_when_the_dump_fails() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  echo fail >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "backup failed, nothing was promoted"
  expect "it tried once" equal "$(backup_calls)" 1
  expect "nothing moved" changes_nothing_since "$before"
}
publish_stops_when_the_dump_fails() {
  local status=0
  merged_prod_sim_promotion
  echo fail >"$STUB/backup-mode"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "backup failed, nothing was published"
  expect "it asked plane-dev first" said "passed: plane-dev was Synced and Healthy"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
}
promote_prod_sim_needs_confirmation() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  in_clone env SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "prod-sim needs CONFIRM=yes when not run from a terminal"
  expect "no dump" equal "$(backup_calls)" 0
  expect "nothing moved" changes_nothing_since "$before"
}
rollback_prod_sim_needs_confirmation() {
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  in_clone ./scripts/rollback.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "prod-sim needs CONFIRM=yes when not run from a terminal"
  expect "no dump" equal "$(backup_calls)" 0
  expect "nothing moved" changes_nothing_since "$before"
}
promote_refuses_a_dirty_overlay() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  printf '# an edit in progress\n' >>"$CLONE/$PROD_SIM_OVERLAY"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "has uncommitted changes"
  expect "before it spends a dump" equal "$(backup_calls)" 0
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the edit is still there" grep -q 'an edit in progress' "$CLONE/$PROD_SIM_OVERLAY"
}
rollback_refuses_a_dirty_overlay() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  printf '# an edit in progress\n' >>"$CLONE/$DEV_OVERLAY"
  rollback dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "has uncommitted changes"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the edit is still there" grep -q 'an edit in progress' "$CLONE/$DEV_OVERLAY"
}
promote_refuses_off_main() {
  local status=0 before
  git -C "$CLONE" checkout --quiet -B elsewhere
  before="$(head_commit)"
  promote_dev "$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "promote from main, or use COMMIT=no"
  expect "no commit" equal "$(head_commit)" "$before"
  in_clone env SKIP_REGISTRY_CHECK=yes COMMIT=no ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A"
  expect "COMMIT=no works anywhere, for CI" equal "$(web_digest_in "$DEV_OVERLAY")" "$DIGEST_A"
}
rollback_refuses_off_main() {
  local status=0 before
  promote_dev "$DIGEST_A"
  git -C "$CLONE" checkout --quiet -B elsewhere
  before="$(head_commit)"
  rollback dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "roll back from main"
  expect "no commit" equal "$(head_commit)" "$before"
}
promote_refuses_while_a_revert_is_under_way() {
  # A commit would finish that revert, in whatever state it is.
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  git -C "$CLONE" revert --no-commit HEAD
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "REVERT_HEAD says a git operation is under way"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the revert is still as it was" [ -e "$CLONE/.git/REVERT_HEAD" ]
}
write_digests_file() { # write_digests_file <image to leave out> <image to give a bad digest>
  local image digest
  mkdir -p "$CLONE/.build"
  : >"$CLONE/.build/digests.tsv"
  for image in web admin space backend; do
    [[ "$image" != "$1" ]] || continue
    digest="$DIGEST_A"
    [[ "$image" != "$2" ]] || digest=sha256:short
    printf '%s\tlocalhost:5001/wayline/%s\t%s\n' "$image" "$image" "$digest" >>"$CLONE/.build/digests.tsv"
  done
}
promote_takes_a_whole_digests_file() {
  local status=0 before
  before="$(head_commit)"
  write_digests_file "" ""
  in_clone env SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev || status=$?
  expect "the promotion works" [ "$status" -eq 0 ]
  expect "four images moved, each with its repository" equal "$(images_of "$DEV_OVERLAY" | grep -c "localhost:5001/wayline/.* $DIGEST_A")" 4
  expect "one commit" equal "$(git -C "$CLONE" rev-list --count "$before..HEAD")" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
promote_refuses_a_partial_digests_file() {
  local status=0 before
  before="$(head_commit)"
  write_digests_file space ""
  in_clone env SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "does not name every image"
  expect "nothing moved" changes_nothing_since "$before"
}
promote_refuses_a_malformed_digests_file() {
  local status=0 before
  before="$(head_commit)"
  write_digests_file "" admin
  in_clone env SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "bad digest for admin"
  expect "nothing moved" changes_nothing_since "$before"
}
promote_checks_its_arguments() {
  local status before
  before="$(head_commit)"
  status=0
  in_clone ./scripts/promote.sh dev IMAGE=web DIGEST=sha256:short || status=$?
  expect "a short digest is refused" [ "$status" -ne 0 ]
  expect "and says why" said "DIGEST must be sha256"
  status=0
  in_clone ./scripts/promote.sh dev IMAGE=web || status=$?
  expect "an image with no digest is refused" [ "$status" -ne 0 ]
  expect "and says why" said "IMAGE and DIGEST go together"
  status=0
  in_clone ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A" "REPO=not a repository" || status=$?
  expect "a bad repository is refused" [ "$status" -ne 0 ]
  expect "and says why" said "REPO is not a repository name"
  status=0
  in_clone ./scripts/promote.sh dev IMAGE=no-such-image DIGEST="$DIGEST_A" || status=$?
  expect "an unknown image is refused" [ "$status" -ne 0 ]
  expect "and says why" said "no image matching 'no-such-image'"
  expect "nothing moved" changes_nothing_since "$before"
}
promote_refuses_an_ambiguous_image() {
  local status=0 before
  set_image dev fixture.invalid/plane-frontend "docker.io/fixture/other@$DIGEST_B"
  commit_a_change_to_helm 'a second image with that last segment'
  in_clone ./scripts/gitops-publish.sh
  before="$(head_commit)"
  promote_dev "$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "'web' matches more than one image"
  expect "nothing moved" changes_nothing_since "$before"
}

# ---- a promotion that fails after it has edited the overlay
promote_render_failure_puts_the_overlay_back() {
  local status=0 before
  before="$(head_commit)"
  echo "someone's work" >"$CLONE/docs/staged-by-someone.txt"
  git -C "$CLONE" add docs/staged-by-someone.txt
  echo fail-after-edit >"$STUB/kustomize-mode"
  promote_dev "$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "rendering the promotion failed"
  expect "the kustomize edit did happen" [ -e "$STUB/kustomize-edited" ]
  expect "nothing moved" changes_nothing_since "$before"
  expect "someone's work is still staged" equal "$(staged_names)" "docs/staged-by-someone.txt "
  expect "the commit lock is free" nothing_in_progress
}
promote_ended_halfway_puts_the_overlay_back() {
  local status=0 before
  before="$(head_commit)"
  echo end-after-edit >"$STUB/kustomize-mode"
  promote_dev "$DIGEST_A" || status=$?
  expect "it did not succeed" [ "$status" -ne 0 ]
  expect "the kustomize edit did happen" [ -e "$STUB/kustomize-edited" ]
  expect "nothing moved" changes_nothing_since "$before"
  expect "the commit lock is free" nothing_in_progress
}
promote_commit_failure_puts_the_overlay_back() {
  local status=0 before
  before="$(head_commit)"
  failing_hook "$CLONE/.git/hooks/pre-commit"
  promote_dev "$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "could not commit the promotion"
  expect "git's own words" said "hook: no"
  expect "nothing moved" changes_nothing_since "$before"
  expect "the commit lock is free" nothing_in_progress
  rm -f "$CLONE/.git/hooks/pre-commit"
  promote_dev "$DIGEST_A"
  expect "a second run works" equal "$(published)" "$(head_commit)"
}
promote_waits_out_a_git_add() {
  echo lock-after-edit >"$STUB/kustomize-mode"
  echo 2 >"$STUB/index-lock-seconds"
  promote_dev "$DIGEST_A"
  expect "the promotion got through" equal "$(published)" "$(head_commit)"
  expect "and is dev's" equal "$(argo_reads_web dev)" "$DIGEST_A"
}
promote_says_what_to_do_when_the_index_stays_held() {
  local status=0 before
  before="$(head_commit)"
  echo lock-after-edit >"$STUB/kustomize-mode"
  in_clone env INDEX_LOCK_WAIT=1 SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "could not stage the promotion"
  expect "it says the overlay still holds it" said "still hold this promotion"
  expect "and the way out" said "git restore --source=HEAD --staged --worktree -- helm/plane/overlays/dev gitops/environments/dev/manifests.yaml"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the commit lock is free" nothing_in_progress
  rm -f "$CLONE/.git/index.lock" "$STUB/kustomize-mode"
  git -C "$CLONE" restore --source=HEAD --staged --worktree -- helm/plane/overlays/dev gitops/environments/dev/manifests.yaml
  promote_dev "$DIGEST_A"
  expect "the way out works" equal "$(published)" "$(head_commit)"
}
promote_rechecks_the_overlay_after_the_dump() {
  # The dump took minutes. Cleanup restores these paths, so an edit made meanwhile must stop this.
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  echo someone-edits >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "made since this started"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the edit is still there" grep -q 'an edit made during the dump' "$CLONE/$PROD_SIM_OVERLAY"
  expect "the commit lock is free" nothing_in_progress
}

# ---- the commit lock, held by whatever else commits in this checkout
lock_probes() { # Hooks that note whether the lock is held at the commit and at the push.
  printf '#!/bin/sh\nif [ -d "$CLONE/.git/agent-commit.lockdir" ]; then echo held >"$STUB/lock-at-commit"; fi\n' >"$CLONE/.git/hooks/pre-commit"
  printf '#!/bin/sh\nif [ -d "$CLONE/.git/agent-commit.lockdir" ]; then echo held >"$STUB/lock-at-push"; fi\n' >"$BARE/hooks/pre-receive"
  chmod +x "$CLONE/.git/hooks/pre-commit" "$BARE/hooks/pre-receive"
}
promote_holds_the_commit_lock_for_its_commit() {
  lock_probes
  promote_dev "$DIGEST_A"
  expect "held at the commit" [ -e "$STUB/lock-at-commit" ]
  expect "not at the publish" [ ! -e "$STUB/lock-at-push" ]
  expect "free at the end" nothing_in_progress
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_holds_the_commit_lock_for_its_commit() {
  promote_dev "$DIGEST_A"
  lock_probes
  rollback dev
  expect "held at the commit" [ -e "$STUB/lock-at-commit" ]
  expect "not at the publish" [ ! -e "$STUB/lock-at-push" ]
  expect "free at the end" nothing_in_progress
  expect "published" equal "$(published)" "$(head_commit)"
}
someone_commits_until_this_waits() { # Someone else's commit holds the lock, and ends once the script says it waits.
  mkdir "$CLONE/.git/agent-commit.lockdir"
  (
    waited=0
    until grep -qF 'Waiting for .git/agent-commit.lockdir' "$OUT"; do
      [[ "$waited" -lt 120 ]] || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    rmdir "$CLONE/.git/agent-commit.lockdir"
  ) >/dev/null 2>&1 &
  SOMEONE=$!
}
promote_waits_for_the_commit_lock() {
  someone_commits_until_this_waits
  promote_dev "$DIGEST_A"
  kill "$SOMEONE" 2>/dev/null || true
  expect "it says what it waits for" said "Waiting for .git/agent-commit.lockdir"
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_waits_for_the_commit_lock() {
  promote_dev "$DIGEST_A"
  someone_commits_until_this_waits
  rollback dev
  kill "$SOMEONE" 2>/dev/null || true
  expect "it says what it waits for" said "Waiting for .git/agent-commit.lockdir"
  expect "one revert" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
promote_gives_up_on_a_commit_lock_left_behind() {
  local status=0 before
  before="$(head_commit)"
  mkdir "$CLONE/.git/agent-commit.lockdir"
  in_clone env COMMIT_LOCK_WAIT=2 SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason and the way out" said "rmdir .git/agent-commit.lockdir"
  expect "nothing moved" changes_nothing_since "$before"
  expect "it is not this script's to remove" [ -d "$CLONE/.git/agent-commit.lockdir" ]
}
rollback_gives_up_on_a_commit_lock_left_behind() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  mkdir "$CLONE/.git/agent-commit.lockdir"
  in_clone env COMMIT_LOCK_WAIT=2 ./scripts/rollback.sh dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason and the way out" said "rmdir .git/agent-commit.lockdir"
  expect "nothing moved" changes_nothing_since "$before"
  expect "it is not this script's to remove" [ -d "$CLONE/.git/agent-commit.lockdir" ]
}

# ---- a promotion whose publish failed: the commit stays on main, and a false green must not follow
promote_again_publishes_after_a_refused_push() {
  local status=0 argo_before
  argo_before="$(argo_reads_web prod-sim)"
  dev_runs_its_overlay
  failing_hook "$BARE/hooks/pre-receive"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it says the commit stays" said "stays on main, and Argo CD has not read it"
  expect "and how it can leave" said "It leaves with the next publish of any kind"
  expect "Argo CD still reads the old digest" equal "$(argo_reads_web prod-sim)" "$argo_before"
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a second run with the push still refused does not exit 0" [ "$status" -ne 0 ]
  expect "and it does not say all is well" not_said "already runs these digests"
  expect "it says what happened" said "main could not be published"
  rm -f "$BARE/hooks/pre-receive"
  status=0
  rm -f "$STUB/backup-calls"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a run with the push working succeeds" [ "$status" -eq 0 ]
  expect "and published" equal "$(published)" "$(head_commit)"
  expect "Argo CD reads the new digest" equal "$(argo_reads_web prod-sim)" "$(web_digest_in "$DEV_OVERLAY")"
  expect "this run took its own dump before the digest moved" equal "$(backup_calls)" 1
}
promote_again_publishes_after_a_refused_check() {
  # A rollout starting during the dump is enough: the publish repeats the check after it.
  local status=0 argo_before
  argo_before="$(argo_reads_web prod-sim)"
  dev_runs_its_overlay
  echo dev-goes-bad >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "Application plane-dev is Synced/Degraded"
  expect "it says the commit stays" said "stays on main, and Argo CD has not read it"
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a second run with dev still bad does not exit 0" [ "$status" -ne 0 ]
  expect "and it does not say all is well" not_said "already runs these digests"
  expect "Argo CD still reads the old digest" equal "$(argo_reads_web prod-sim)" "$argo_before"
  echo ok >"$STUB/backup-mode"
  echo Synced/Healthy >"$STUB/app-status"
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a run with dev healthy succeeds" [ "$status" -eq 0 ]
  expect "it says the check passed" said "passed: plane-dev was Synced and Healthy"
  expect "and published" equal "$(published)" "$(head_commit)"
}
promote_dev_again_publishes_after_a_refused_push() {
  local status=0
  failing_hook "$BARE/hooks/pre-receive"
  promote_dev "$DIGEST_A" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it says the commit stays" said "stays on main, and Argo CD has not read it"
  rm -f "$BARE/hooks/pre-receive"
  promote_dev "$DIGEST_A"
  expect "the second run publishes it" equal "$(published)" "$(head_commit)"
  expect "Argo CD reads it" equal "$(argo_reads_web dev)" "$DIGEST_A"
}
promote_commit_no_publishes_nothing() {
  # CI has no bare repository to speak of, and turns the change into a pull request.
  merged_prod_sim_promotion
  in_clone env SKIP_REGISTRY_CHECK=yes COMMIT=no ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A"
  expect "it says so" said "dev already runs these digests"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
  expect "no dump" equal "$(backup_calls)" 0
}

# ---- a dev change on main with a prod-sim promotion waiting, because a publish is all of main
promote_dev_takes_the_dump_a_carried_prod_sim_change_needs() {
  merged_prod_sim_promotion
  promote_dev "$DIGEST_B"
  expect "it says what moves" said "promote(prod-sim): plane-frontend"
  expect "it took the dump" equal "$(backup_calls)" 1
  expect "the dump did not hold the commit lock" [ ! -e "$STUB/backup-saw-lock" ]
  expect "published" equal "$(published)" "$(head_commit)"
}
promote_dev_stops_when_a_carried_dump_fails() {
  local status=0
  merged_prod_sim_promotion
  echo fail >"$STUB/backup-mode"
  promote_dev "$DIGEST_B" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "backup failed, nothing was published"
  expect "it says the commit stays" said "stays on main, and Argo CD has not read it"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
}
publish_names_what_a_dev_change_waits_behind() {
  local status=0 pending
  merged_prod_sim_promotion
  pending="$(git -C "$CLONE" log -1 --format='%h %s')"
  echo OutOfSync/Degraded >"$STUB/app-status"
  promote_dev "$DIGEST_B" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it names the commit" said "held behind what moves prod-sim: $pending"
  expect "and the way past it" said "OVERRIDE_DEV_CHECK"
  expect "and says the dev commit stays" said "stays on main, and Argo CD has not read it"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
  # What it says works: the fix for dev gets out, and prod-sim does not move.
  rollback prod-sim
  expect "the rest of main is out" equal "$(published)" "$(head_commit)"
  expect "with dev's change" equal "$(argo_reads_web dev)" "$DIGEST_B"
  expect "and prod-sim where it was" equal "$(argo_reads_web prod-sim)" "$(git -C "$CLONE" show "$BASE:$PROD_SIM_OVERLAY" | yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest')"
}
publish_refusal_of_prod_sim_alone_says_nothing_of_dev() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect_refused "$status" "Application plane-dev is OutOfSync/Degraded"
  expect "no word of a dev change" not_said "held behind"
}

# ---- a rollback of dev has no business moving prod-sim
rollback_dev_stops_before_moving_prod_sim() {
  local status=0 before pending
  merged_prod_sim_promotion
  before="$(head_commit)"
  pending="$(git -C "$CLONE" log -1 --format='%h %s')"
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone ./scripts/rollback.sh dev || status=$?
  expect "a stop" [ "$status" -ne 0 ]
  expect "it names the commit" said "$pending"
  expect "and the way out" said "OVERRIDE_DEV_CHECK"
  expect "and says nothing changed" said "Nothing changed"
  expect "no revert" equal "$(head_commit)" "$before"
  expect "nothing was published" equal "$(published)" "$PUBLISHED_BEFORE"
  expect "no dump" equal "$(backup_calls)" 0
  expect "it asked the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
  expect "nothing logged" [ ! -e "$OVERRIDE_LOG" ]
  expect "nothing left behind" nothing_in_progress
}
rollback_chain_after_a_refused_promotion() {
  # Each step a normal command. prod-sim's promotion is refused at its publish because dev went bad during
  # the dump, and its commit stays on main. Then the operator rolls dev back, as dev is what looks broken.
  local status=0 dev_before prod_sim_before pending
  dev_before="$(argo_reads_web dev)"
  prod_sim_before="$(argo_reads_web prod-sim)"
  promote_dev "$DIGEST_A"
  echo dev-goes-bad >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the promotion is refused at its publish" [ "$status" -ne 0 ]
  expect "it says the commit stays and how it leaves" said "It leaves with the next publish of any kind"
  pending="$(git -C "$CLONE" log -1 --format='%h %s')"
  echo ok >"$STUB/backup-mode"

  status=0
  in_clone ./scripts/rollback.sh dev || status=$?
  expect "the rollback of dev stops" [ "$status" -ne 0 ]
  expect "it names the commit" said "$pending"
  expect "no revert yet" equal "$(reverts_on_main)" 0
  expect "prod-sim did not take the digest" equal "$(argo_reads_web prod-sim)" "$prod_sim_before"

  rollback prod-sim
  expect "withdrawing it publishes" equal "$(published)" "$(head_commit)"
  expect "and moves nothing in prod-sim" equal "$(argo_reads_web prod-sim)" "$prod_sim_before"

  in_clone ./scripts/rollback.sh dev
  expect "now dev rolls back" equal "$(argo_reads_web dev)" "$dev_before"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "prod-sim never moved" equal "$(argo_reads_web prod-sim)" "$prod_sim_before"
}
rollback_dev_override_keeps_the_checks() {
  local status=0
  merged_prod_sim_promotion
  echo OutOfSync/Degraded >"$STUB/app-status"
  in_clone make rollback ENV=dev OVERRIDE_DEV_CHECK="prod-sim has to have it today" || status=$?
  expect "it goes on" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "the stop's override is logged" grep -q 'rollback.sh.overridden.*prod-sim has to have it today.*rollback of dev carries' "$OVERRIDE_LOG"
  expect "plane-dev was still asked" grep -q 'gitops-publish.sh.overridden.*prod-sim has to have it today.*OutOfSync/Degraded' "$OVERRIDE_LOG"
  expect "no waiver" not_said "plane-dev check not run"
  expect "the dump was still taken" equal "$(backup_calls)" 1
}
rollback_dev_rerun_stops_too() {
  # An earlier run's revert that never got out, and a prod-sim change that has joined it since.
  local status=0 revert
  promote_dev "$DIGEST_A"
  failing_hook "$BARE/hooks/pre-receive"
  rollback dev || status=$?
  expect "the publish failed" [ "$status" -ne 0 ]
  rm -f "$BARE/hooks/pre-receive"
  revert="$(head_commit)"
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_B"
  commit_a_change_to_helm 'a digest changed by hand'
  # plane-dev has proven it, so the publish itself would let it through. Dev's rollback still may not.
  web_image "$DIGEST_B" true
  status=0
  rollback dev || status=$?
  expect "a stop" [ "$status" -ne 0 ]
  expect "it names the commit" said "a digest changed by hand"
  expect "nothing was published" [ "$(published)" != "$revert" ]
  expect "the revert did not leave" [ "$(argo_reads_web dev)" == "$DIGEST_A" ]
}
rollback_dev_goes_on_past_what_does_not_move_prod_sim() {
  local status=0
  promote_dev "$DIGEST_A"
  printf 'commonAnnotations:\n  flow-test: "yes"\n' >>"$CLONE/$PROD_SIM_OVERLAY"
  commit_a_change_to_helm 'a change to the prod-sim overlay that is no image'
  in_clone ./scripts/rollback.sh dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "the other change is called out" said "that are not images"
}
rollback_dev_goes_on_when_a_promotion_was_withdrawn() {
  # A promotion and its revert, both unpublished, move nothing.
  local status=0
  merged_prod_sim_promotion
  git -C "$CLONE" revert --no-edit HEAD >/dev/null
  in_clone ./scripts/rollback.sh dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
  expect "no dump" equal "$(backup_calls)" 0
}

# ---- a rollback that stops undoes only what it started
a_later_change_conflicts_in_the_overlay() {
  promote_prod_sim_committed
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_B"
  commit_a_change_to_helm 'a digest changed by hand, so not a promotion'
}
someone_has_staged_work() {
  echo "someone's new file" >"$CLONE/docs/staged-by-someone.txt"
  echo "someone's edit" >>"$CLONE/README.md"
  git -C "$CLONE" add docs/staged-by-someone.txt README.md
}
someones_work_is_still_there() {
  expect "someone's work is still staged" equal "$(staged_names)" "README.md docs/staged-by-someone.txt "
  expect "the new file is on disk" [ -e "$CLONE/docs/staged-by-someone.txt" ]
  expect "the edit is on disk" grep -q "someone's edit" "$CLONE/README.md"
}
rollback_conflict_keeps_someones_staged_work() {
  local status=0
  a_later_change_conflicts_in_the_overlay
  someone_has_staged_work
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it says nothing changed" said "Nothing changed"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  someones_work_is_still_there
}
rollback_conflict_with_a_partly_staged_file() {
  # git revert --abort cannot get past a file with staged and unstaged edits.
  local status=0
  a_later_change_conflicts_in_the_overlay
  echo "staged edit" >>"$CLONE/README.md"
  git -C "$CLONE" add README.md
  echo "unstaged edit" >>"$CLONE/README.md"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it says nothing changed" said "Nothing changed"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  expect "the file is as it was" equal "$(git -C "$CLONE" status --porcelain -- README.md)" "MM README.md"
  status=0
  rollback prod-sim || status=$?
  expect "a second run stops for the same reason" said "the revert conflicts with a later change"
  expect "not for what the first left" not_said "uncommitted changes"
}
rollback_render_failure_keeps_someones_staged_work() {
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  someone_has_staged_work
  echo fail >"$STUB/kustomize-mode"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "rendering after the revert failed"
  expect "it says nothing changed" said "Nothing changed"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  someones_work_is_still_there
}
rollback_commit_failure_can_run_again() {
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  failing_hook "$CLONE/.git/hooks/pre-commit"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "could not commit the revert"
  expect "git's own words" said "hook: no"
  expect "it says nothing changed" said "Nothing changed"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  rm -f "$CLONE/.git/hooks/pre-commit"
  rollback prod-sim
  expect "a second run finishes it" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_ended_halfway_puts_the_revert_back() {
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  someone_has_staged_work
  echo end >"$STUB/kustomize-mode"
  rollback dev || status=$?
  expect "it did not succeed" [ "$status" -ne 0 ]
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  someones_work_is_still_there
}
rollback_waits_out_a_git_add() {
  promote_prod_sim_committed
  echo lock >"$STUB/kustomize-mode"
  echo 2 >"$STUB/index-lock-seconds"
  rollback prod-sim
  expect "the rollback got through" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_says_what_to_do_when_the_index_stays_held() {
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  echo lock >"$STUB/kustomize-mode"
  in_clone env INDEX_LOCK_WAIT=1 CONFIRM=yes SKIP_BACKUP=yes ./scripts/rollback.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "could not stage the revert"
  expect "it does not claim nothing changed" not_said "Nothing changed"
  expect "it says the revert is still here" said "The revert is still in this checkout"
  expect "and the way out" said "git restore --source=HEAD --staged --worktree -- $PROD_SIM_RENDERED"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the commit lock is free" [ ! -d "$CLONE/.git/agent-commit.lockdir" ]
  rm -f "$CLONE/.git/index.lock" "$STUB/kustomize-mode"
  status=0
  in_clone env CONFIRM=yes SKIP_BACKUP=yes ./scripts/rollback.sh prod-sim || status=$?
  expect "a second run does not make it worse" [ "$status" -ne 0 ]
  expect "it says a revert is under way" said "is under way in this checkout"
  expect "and how to clear it" said "git revert --quit"
  # What it says works.
  git -C "$CLONE" restore --source=HEAD --staged --worktree -- "$PROD_SIM_RENDERED" helm/plane/overlays/prod-sim/kustomization.yaml
  git -C "$CLONE" revert --quit
  rollback prod-sim
  expect "after that it works" equal "$(reverts_on_main)" 1
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_says_when_the_revert_cannot_start() {
  # A held index before the revert is no conflict, whatever else it is.
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  touch "$CLONE/.git/index.lock"
  in_clone env INDEX_LOCK_WAIT=1 CONFIRM=yes SKIP_BACKUP=yes ./scripts/rollback.sh prod-sim || status=$?
  rm -f "$CLONE/.git/index.lock"
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "git could not start the revert"
  expect "git's own words" said "index.lock"
  expect "no talk of a conflict" not_said "conflicts with a later change"
  expect "it says nothing changed" said "Nothing changed"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
}
rollback_leaves_someones_merge_alone() {
  # A revert commit cannot be made beside a merge, and clearing a revert would forget the merge too.
  local status=0 before
  promote_dev "$DIGEST_A"
  before="$(head_commit)"
  git -C "$CLONE" checkout --quiet -B someones-branch "$BASE"
  echo "someone's edit" >>"$CLONE/README.md"
  git -C "$CLONE" commit --quiet -am 'a commit to merge'
  git -C "$CLONE" checkout --quiet main
  git -C "$CLONE" merge --quiet --no-commit --no-ff someones-branch >/dev/null
  in_clone ./scripts/rollback.sh dev || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "MERGE_HEAD says a git operation is under way"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the merge is still under way" [ -e "$CLONE/.git/MERGE_HEAD" ]
  expect "with what it staged" equal "$(staged_names)" "README.md "
  expect "helm and gitops are clean" helm_and_gitops_clean
}
rollback_says_a_promotion_put_back_by_hand_is_undone() {
  local status=0 before
  promote_prod_sim_committed
  git -C "$CLONE" show "$BASE:$PROD_SIM_OVERLAY" >"$CLONE/$PROD_SIM_OVERLAY"
  commit_a_change_to_helm 'prod-sim image put back by hand'
  before="$(head_commit)"
  rollback prod-sim || status=$?
  expect "it succeeds" [ "$status" -eq 0 ]
  expect "it says so" said "is already undone"
  expect "no new commit" equal "$(head_commit)" "$before"
  expect "the revert is gone" nothing_in_progress
  expect "helm and gitops are clean" helm_and_gitops_clean
  expect "what put it back reached Argo CD" equal "$(published)" "$before"
  expect "it says how to step back further" said "then run this again, which publishes that revert"
  expect "and says the schema did not go back" said "the schema is not"
  status=0
  rollback prod-sim || status=$?
  expect "a second run says the same" said "is already undone"
  expect "and succeeds" [ "$status" -eq 0 ]
  expect "still no new commit" equal "$(head_commit)" "$before"
}
promotion_that_added_a_file() {
  promote_dev "$DIGEST_A"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes COMMIT=no ./scripts/promote.sh prod-sim
  echo note >"$CLONE/docs/added-with-the-promotion.txt"
  git -C "$CLONE" add -- helm gitops docs/added-with-the-promotion.txt
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
}
rollback_promotion_that_added_a_file() {
  local status=0
  promotion_that_added_a_file
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "the file went with it" [ ! -e "$CLONE/docs/added-with-the-promotion.txt" ]
  expect "in the revert" equal "$(git -C "$CLONE" show --name-status --format= HEAD -- docs/added-with-the-promotion.txt | cut -c1)" D
  expect "the revert is finished" nothing_in_progress
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_promotion_whose_added_file_is_gone() {
  local status=0
  promotion_that_added_a_file
  git -C "$CLONE" rm --quiet docs/added-with-the-promotion.txt
  git -C "$CLONE" commit --quiet -m 'that file goes'
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "one revert" equal "$(reverts_on_main)" 1
  expect "the revert is finished" nothing_in_progress
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_refuses_an_edit_in_a_file_the_promotion_touched() {
  # Stopping puts back every path the revert can touch, so it must not start with someone's edit in one.
  local status=0 before
  promotion_that_added_a_file
  before="$(head_commit)"
  rm -f "$STUB/backup-calls"
  echo "someone's edit" >>"$CLONE/docs/added-with-the-promotion.txt"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "uncommitted changes"
  expect "no dump spent on it" equal "$(backup_calls)" 0
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the edit is still there" grep -q "someone's edit" "$CLONE/docs/added-with-the-promotion.txt"
  expect "the revert did not start" nothing_in_progress
}
rollback_rechecks_after_the_dump() {
  local status=0 before
  promote_prod_sim_committed
  before="$(head_commit)"
  echo someone-edits >"$STUB/backup-mode"
  rollback prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "uncommitted changes"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "the edit is still there" grep -q 'an edit made during the dump' "$CLONE/$PROD_SIM_OVERLAY"
  expect "the revert did not start" nothing_in_progress
}

rollback_leaves_the_other_render_as_git_has_it() {
  # render.sh writes both environments. A stale render of the other one is not this rollback's to commit,
  # and left on disk it would make the next promotion of that environment refuse.
  local status=0
  promote_dev "$DIGEST_A"
  printf '# a hand edit\n' >>"$CLONE/$PROD_SIM_RENDERED"
  git -C "$CLONE" add -- gitops
  git -C "$CLONE" commit --quiet -m 'a hand edit of the render'
  rollback dev || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "helm and gitops are clean" helm_and_gitops_clean
  expect "the other render is not in the revert" equal "$(git -C "$CLONE" show --name-only --format= HEAD | grep -c prod-sim || true)" 0
  expect "published" equal "$(published)" "$(head_commit)"
}

# ---- which promotion, and which dump
rollback_finds_a_subject_only_promotion() {
  # A squash merge on GitHub may drop the trailer but keeps the subject.
  local status=0 promoted
  promote_dev "$DIGEST_A"
  promote_prod_sim COMMIT=no
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -m 'promote(prod-sim): plane-frontend aaaaaaaaaaaa'
  promoted="$(head_commit)"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "of that commit" grep -qF "This reverts commit $promoted" <(git -C "$CLONE" log -1 --format=%B)
  expect "prod-sim is back" not_equal_digest "$DIGEST_A"
}
rollback_finds_a_trailer_only_promotion() {
  local status=0 promoted
  promote_dev "$DIGEST_A"
  promote_prod_sim COMMIT=no
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -m 'bring web to prod-sim' -m 'Promote-Env: prod-sim'
  promoted="$(head_commit)"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "of that commit" grep -qF "This reverts commit $promoted" <(git -C "$CLONE" log -1 --format=%B)
}
rollback_second_attempt_names_the_dump_from_before_the_promotion() {
  # The first attempt's own dump holds what the bad promotion left, and it is the newest there is.
  local status=0 older conflict first_dump
  older=20260101T000000Z
  mkdir -p "$CLONE/.local/backups/prod-sim/$older"
  echo '{}' >"$CLONE/.local/backups/prod-sim/$older/manifest.json"
  a_later_change_conflicts_in_the_overlay
  conflict="$(head_commit)"
  sleep 1
  rollback prod-sim || status=$?
  expect "the first attempt stops" [ "$status" -ne 0 ]
  first_dump="$(find "$CLONE/.local/backups/prod-sim" -mindepth 1 -maxdepth 1 -type d ! -name "$older" -exec basename {} \;)"
  expect "and took a dump" [ -n "$first_dump" ]
  git -C "$CLONE" revert --no-edit "$conflict" >/dev/null
  rollback prod-sim
  expect "it names the older dump" said "BACKUP=$older"
  expect "not the first attempt's" not_said "BACKUP=$first_dump"
}
rollback_says_when_no_dump_is_older() {
  promote_prod_sim_committed
  rollback prod-sim
  expect "it took a dump of its own" equal "$(backup_calls)" 1
  expect "it says none predates the promotion" said "no finished dump older than"
  expect "and names none" not_said "BACKUP=2"
}
rollback_skips_an_unfinished_dump() {
  local older=20260101T000000Z unfinished=20260102T000000Z
  mkdir -p "$CLONE/.local/backups/prod-sim/$older" "$CLONE/.local/backups/prod-sim/$unfinished"
  echo '{}' >"$CLONE/.local/backups/prod-sim/$older/manifest.json"
  promote_prod_sim_committed
  rollback prod-sim
  expect "it names the finished one" said "BACKUP=$older"
}

# ---- a rollback says what there is to restore, going by when the promotion first went out
a_dump_exists() { # a_dump_exists <name>
  mkdir -p "$CLONE/.local/backups/prod-sim/$1"
  echo '{}' >"$CLONE/.local/backups/prod-sim/$1/manifest.json"
}
rollback_of_a_refused_promotion_says_nothing_to_restore() {
  local status=0 prod_sim_before
  a_dump_exists 20260101T000000Z
  prod_sim_before="$(argo_reads_web prod-sim)"
  promote_dev "$DIGEST_A"
  echo dev-goes-bad >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the promotion is refused at its publish" [ "$status" -ne 0 ]
  echo ok >"$STUB/backup-mode"
  status=0
  rollback prod-sim || status=$?
  expect "taking it off main works" [ "$status" -eq 0 ]
  expect "it says why there is nothing to do" said "never reached Argo CD"
  expect "and says so" said "There is nothing to restore"
  expect "it sends nobody to a dump" not_said "make restore"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "prod-sim did not move" equal "$(argo_reads_web prod-sim)" "$prod_sim_before"
}
rollback_of_a_retried_promotion_names_the_dump_of_the_run_that_sent_it() {
  # Restoring the refused attempt's dump would lose every write between the two dumps.
  local status=0 first_dump second_dump
  promote_dev "$DIGEST_A"
  echo dev-goes-bad >"$STUB/backup-mode"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the first attempt is refused at its publish" [ "$status" -ne 0 ]
  first_dump="$(find "$CLONE/.local/backups/prod-sim" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
  sleep 1
  echo ok >"$STUB/backup-mode"
  echo Synced/Healthy >"$STUB/app-status"
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim
  expect "the second run sends it" equal "$(published)" "$(head_commit)"
  second_dump="$(find "$CLONE/.local/backups/prod-sim" -mindepth 1 -maxdepth 1 -type d ! -name "$first_dump" -exec basename {} \;)"
  expect "and took its own dump" [ -n "$second_dump" ]
  sleep 1
  rollback prod-sim
  expect "it names the dump from just before the digest went out" said "BACKUP=$second_dump"
  expect "not the refused attempt's" not_said "BACKUP=$first_dump"
  expect "it says what it goes by" said "the publish that first sent"
}
rollback_rerun_names_the_dump() {
  # The run that finally sends the revert is the one that can say what to restore.
  local status=0 older=20260101T000000Z
  a_dump_exists "$older"
  promote_prod_sim_committed
  failing_hook "$BARE/hooks/pre-receive"
  sleep 1
  rollback prod-sim || status=$?
  expect "the publish fails" [ "$status" -ne 0 ]
  expect "and it names no dump yet" not_said "make restore"
  rm -f "$BARE/hooks/pre-receive"
  rollback prod-sim
  expect "it publishes the revert" said "was never published"
  expect "and names the dump" said "make restore ENV=prod-sim BACKUP=$older"
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_rerun_of_a_withdrawal_says_nothing_to_restore() {
  local status=0 prod_sim_before
  a_dump_exists 20260101T000000Z
  prod_sim_before="$(argo_reads_web prod-sim)"
  promote_dev "$DIGEST_A"
  failing_hook "$BARE/hooks/pre-receive"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the promotion's publish fails" [ "$status" -ne 0 ]
  status=0
  rollback prod-sim || status=$?
  expect "the rollback's publish fails too" [ "$status" -ne 0 ]
  rm -f "$BARE/hooks/pre-receive"
  rollback prod-sim
  expect "it publishes the revert" said "was never published"
  expect "and says so" said "There is nothing to restore"
  expect "it sends nobody to a dump" not_said "make restore"
  expect "prod-sim did not move" equal "$(argo_reads_web prod-sim)" "$prod_sim_before"
}
rollback_goes_by_the_commit_with_no_record_of_the_publish() {
  # What was published before the record began. A later publish holds it, and did not first send it.
  local older=20260101T000000Z later
  a_dump_exists "$older"
  promote_prod_sim_committed
  rm -f "$CLONE/.local/publishes.log"
  sleep 1
  later="$(date -u +%Y%m%dT%H%M%SZ)"
  a_dump_exists "$later"
  sleep 1
  git -C "$CLONE" commit --quiet --allow-empty -m 'something later'
  in_clone ./scripts/gitops-publish.sh
  rollback prod-sim
  expect "it names the dump from before the commit" said "BACKUP=$older"
  expect "not the one from after it" not_said "BACKUP=$later"
  expect "it says what it goes by" said "goes by its commit"
  expect "and which came later" said "Finished since the commit: $later"
}
rollback_reverts_a_refused_promotion_above_an_unpublished_revert() {
  # Publishing the revert would send the newer promotion too, under the waiver, and moving forward is no rollback.
  local status=0 argo_before refused
  promote_prod_sim_committed
  argo_before="$(argo_reads_web prod-sim)"
  promote_dev "$DIGEST_B"
  web_image "$DIGEST_B" true
  failing_hook "$BARE/hooks/pre-receive"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the promotion's publish fails" [ "$status" -ne 0 ]
  status=0
  rollback prod-sim || status=$?
  expect "the rollback's publish fails too" [ "$status" -ne 0 ]
  rm -f "$BARE/hooks/pre-receive"
  echo dev-goes-bad >"$STUB/backup-mode"
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the next promotion is refused" [ "$status" -ne 0 ]
  refused="$(head_commit)"
  echo ok >"$STUB/backup-mode"
  status=0
  rollback prod-sim || status=$?
  expect "the rollback works" [ "$status" -eq 0 ]
  expect "it reverts that promotion" grep -qF "This reverts commit $refused" <(git -C "$CLONE" log -1 --format=%B)
  expect "it does not send it" equal "$(argo_reads_web prod-sim)" "$argo_before"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "and says so" said "There is nothing to restore"
}
rollback_stops_before_sending_what_waits_under_a_withdrawal() {
  local status=0 argo_before first second
  argo_before="$(argo_reads_web prod-sim)"
  promote_dev "$DIGEST_A"
  failing_hook "$BARE/hooks/pre-receive"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the first promotion's publish fails" [ "$status" -ne 0 ]
  first="$(head_commit)"
  status=0
  promote_dev "$DIGEST_B" || status=$?
  web_image "$DIGEST_B" true
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "the second promotion's publish fails" [ "$status" -ne 0 ]
  second="$(head_commit)"
  rm -f "$BARE/hooks/pre-receive" "$STUB/backup-calls"
  status=0
  rollback prod-sim || status=$?
  expect "a stop" [ "$status" -ne 0 ]
  expect "it names what waits" said "$(git -C "$CLONE" log -1 --format='%h %s' "$first")"
  expect "and why that matters" said "with no check of plane-dev and no dump"
  expect "and says nothing changed" said "Nothing changed"
  expect "no revert" equal "$(head_commit)" "$second"
  expect "no dump spent on it" equal "$(backup_calls)" 0
  expect "Argo CD still reads the old digest" equal "$(argo_reads_web prod-sim)" "$argo_before"
  # What it says works.
  git -C "$CLONE" revert --no-edit "$second" >/dev/null
  git -C "$CLONE" revert --no-edit "$first" >/dev/null
  rollback prod-sim
  expect "it publishes those reverts" said "was never published"
  expect "and says there is nothing to restore" said "There is nothing to restore"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "prod-sim did not move" equal "$(argo_reads_web prod-sim)" "$argo_before"
}

# ---- a publish someone else got in first, and a refusal that names the right commit
publish_says_when_another_publish_sent_it() {
  local status=0 checked
  merged_prod_sim_promotion
  checked="$(head_commit)"
  echo someone-publishes >"$STUB/backup-mode"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it succeeds" [ "$status" -eq 0 ]
  expect "it says who sent it" said "another publish already sent ${checked:0:12}"
  expect "no talk of a rewrite" not_said "rewritten"
  expect "and no advice to delete the bare repository" not_said "delete $BARE"
  expect "git's refusal is not shown" not_said "non-fast-forward"
  expect "Argo CD reads the other publish" equal "$(published)" "$(head_commit)"
}
promote_says_nothing_of_a_stay_when_another_publish_sent_it() {
  local status=0
  merged_prod_sim_promotion
  echo someone-publishes >"$STUB/backup-mode"
  promote_dev "$DIGEST_B" || status=$?
  expect "it succeeds" [ "$status" -eq 0 ]
  expect "it does not say the commit stays" not_said "stays on main"
  expect "Argo CD reads the digest" equal "$(argo_reads_web dev)" "$DIGEST_B"
}
promote_names_its_own_commit_when_the_publish_fails() {
  local status=0
  merged_prod_sim_promotion
  echo someone-commits >"$STUB/backup-mode"
  failing_hook "$BARE/hooks/pre-receive"
  promote_dev "$DIGEST_B" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "a commit did land during the dump" equal "$(git -C "$CLONE" log -1 --format=%s)" 'committed during the dump'
  expect "it names the promotion" said "promote(dev): plane-frontend ${DIGEST_B:7:12} stays on main"
  expect "not what landed since" not_said "committed during the dump stays on main"
  expect "push refused says why" said "hook: no"
}
rollback_names_its_own_commit_when_the_publish_fails() {
  local status=0
  promote_prod_sim_committed
  # Someone commits while the push runs, and then the push is refused.
  cat >"$BARE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
unset GIT_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_PUSH_OPTION_COUNT
git -C "$CLONE" commit --quiet --allow-empty -m 'committed during the push'
exit 1
HOOK
  chmod +x "$BARE/hooks/pre-receive"
  rollback prod-sim || status=$?
  expect "a failure" [ "$status" -ne 0 ]
  expect "a commit did land during the push" equal "$(git -C "$CLONE" log -1 --format=%s)" 'committed during the push'
  expect "it names the revert" said '" is on main but did not reach Argo CD'
  expect "not what landed since" not_said "committed during the push is on main"
}

# ---- advice that works when followed
publish_advice_fits_a_change_by_hand() {
  # What waits is no promotion, so make rollback would revert a good one and send this under its waiver.
  local status=0 argo_before hand
  promote_prod_sim_committed
  argo_before="$(argo_reads_web prod-sim)"
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_B"
  commit_a_change_to_helm 'a digest changed by hand, so not a promotion'
  hand="$(head_commit)"
  echo OutOfSync/Degraded >"$STUB/app-status"
  promote_dev "$DIGEST_B" || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "it names it" said "held behind what moves prod-sim: $(git -C "$CLONE" log -1 --format='%h %s' "$hand")"
  expect "it says what to do in either case" said "If that is a promotion, make rollback ENV=prod-sim withdraws it and publishes the rest. If not, git revert it."
  # What it says works, and asks plane-dev nothing, as prod-sim no longer moves.
  git -C "$CLONE" revert --no-edit "$hand" >/dev/null
  in_clone ./scripts/gitops-publish.sh
  expect "dev's change is out" equal "$(argo_reads_web dev)" "$DIGEST_B"
  expect "prod-sim did not move" equal "$(argo_reads_web prod-sim)" "$argo_before"
}
rollback_advice_on_a_conflict_works_with_dev_broken() {
  # This is the emergency path, so its own advice cannot run through a publish that asks plane-dev.
  local status=0 older=20260101T000000Z promotion
  a_dump_exists "$older"
  a_later_change_conflicts_in_the_overlay
  promotion="$(git -C "$CLONE" log -1 --format=%H HEAD^)"
  sleep 1
  rollback prod-sim || status=$?
  expect "a stop" [ "$status" -ne 0 ]
  expect "it says what to run after" said "fix the conflict, then run this again, which publishes that revert"
  expect "and not the normal path" not_said "make gitops-publish"
  # By hand, as it says, and prod-sim's digest goes back to where it was before the promotion.
  git -C "$CLONE" revert --no-edit "$promotion" >/dev/null 2>&1 || true
  git -C "$CLONE" show "$BASE:$PROD_SIM_OVERLAY" >"$CLONE/$PROD_SIM_OVERLAY"
  in_clone ./scripts/render.sh
  git -C "$CLONE" add -A -- helm gitops
  git -C "$CLONE" -c core.editor=true revert --continue >/dev/null
  echo OutOfSync/Degraded >"$STUB/app-status"
  status=0
  rollback prod-sim || status=$?
  expect "running it again works with plane-dev broken" [ "$status" -eq 0 ]
  expect "it publishes that revert" said "was never published"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "it names the dump" said "BACKUP=$older"
  expect "plane-dev was not asked" not_said "Application plane-dev is OutOfSync/Degraded"
}

# ---- an empty plan compares the overlay, and Argo CD reads the render
promote_empty_plan_reads_the_render() {
  local status=0
  promote_dev "$DIGEST_A"
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_A"
  git -C "$CLONE" add -- "$PROD_SIM_OVERLAY"
  git -C "$CLONE" commit --quiet -m 'the prod-sim overlay edited by hand, and not rendered'
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "a refusal" [ "$status" -ne 0 ]
  expect "the reason" said "the rendered manifests do not match the overlays"
  expect "it does not say all is well" not_said "already runs these digests"
  expect "nothing went out" [ "$(published)" != "$(head_commit)" ]
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes COMMIT=no ./scripts/promote.sh prod-sim || status=$?
  expect "CI reads it the same way" [ "$status" -ne 0 ]
  in_clone ./scripts/render.sh
  git -C "$CLONE" add -A -- gitops
  git -C "$CLONE" commit --quiet -m 'rendered'
  status=0
  in_clone env SKIP_REGISTRY_CHECK=yes CONFIRM=yes ./scripts/promote.sh prod-sim || status=$?
  expect "once rendered it publishes" [ "$status" -eq 0 ]
  expect "and says so" said "already runs these digests"
  expect "published" equal "$(published)" "$(head_commit)"
}

# ---- a promotion commit that holds more than its own overlay and render
commit_named_a_promotion_touching_both() { # commit_named_a_promotion_touching_both <the environment its subject names>
  set_image dev artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_A"
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-frontend:v0@$DIGEST_A"
  commit_a_change_to_helm "promote($1): plane-frontend, made by hand across both environments"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
}
rollback_stops_on_a_commit_touching_both_environments() {
  local status=0 before env other
  for env in dev prod-sim; do
    if [[ "$env" == dev ]]; then other=prod-sim; else other=dev; fi
    reset_clone "$BASE"
    commit_named_a_promotion_touching_both "$env"
    before="$(head_commit)"
    status=0
    rollback "$env" || status=$?
    expect "a stop for $env" [ "$status" -ne 0 ]
    expect "it says why" said "also changes $other"
    expect "and what to do" said "then run this again, which publishes that revert"
    expect "no revert" equal "$(head_commit)" "$before"
    expect "no dump" equal "$(backup_calls)" 0
    expect "nothing left behind" nothing_in_progress
    expect "helm and gitops are clean" helm_and_gitops_clean
  done
}
rollback_stops_cleanly_when_a_later_commit_removed_a_file() {
  local status=0 before promotion
  echo base >"$CLONE/docs/x.txt"
  git -C "$CLONE" add docs/x.txt
  git -C "$CLONE" commit --quiet -m 'a file'
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  promote_dev "$DIGEST_A"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes COMMIT=no ./scripts/promote.sh prod-sim
  echo changed >"$CLONE/docs/x.txt"
  git -C "$CLONE" add -- helm gitops docs/x.txt
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  promotion="$(head_commit)"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  git -C "$CLONE" rm --quiet docs/x.txt
  git -C "$CLONE" commit --quiet -m 'that file goes'
  before="$(head_commit)"
  rollback prod-sim || status=$?
  expect "a stop" [ "$status" -ne 0 ]
  expect "the reason" said "the revert conflicts with a later change to docs/x.txt"
  expect "it says nothing changed" said "Nothing changed"
  expect "and not that the index was the cause" not_said "could not write the index"
  expect "no commit" equal "$(head_commit)" "$before"
  expect "nothing left in progress" nothing_in_progress
  expect "the checkout is clean" equal "$(git -C "$CLONE" status --porcelain -- helm gitops docs/x.txt)" ""
  expect "the file stays gone" [ ! -e "$CLONE/docs/x.txt" ]
  # By hand, as it says.
  git -C "$CLONE" revert --no-edit "$promotion" >/dev/null 2>&1 || true
  git -C "$CLONE" rm --force --quiet docs/x.txt
  git -C "$CLONE" -c core.editor=true revert --continue >/dev/null
  status=0
  rollback prod-sim || status=$?
  expect "running it again publishes that" [ "$status" -eq 0 ]
  expect "published" equal "$(published)" "$(head_commit)"
}
rollback_how_to_clear_works_on_a_path_head_lacks() {
  # The index is held through the stop too, so the script cannot clear the revert, and what it prints has to.
  local status=0
  echo base >"$CLONE/docs/x.txt"
  git -C "$CLONE" add docs/x.txt
  git -C "$CLONE" commit --quiet -m 'a file'
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  promote_dev "$DIGEST_A"
  in_clone env SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes COMMIT=no ./scripts/promote.sh prod-sim
  echo changed >"$CLONE/docs/x.txt"
  git -C "$CLONE" add -- helm gitops docs/x.txt
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  in_clone env SKIP_BACKUP=yes ./scripts/gitops-publish.sh
  git -C "$CLONE" rm --quiet docs/x.txt
  git -C "$CLONE" commit --quiet -m 'that file goes'
  # The index stays held from right after the revert has written its conflict.
  in_clone env INDEX_LOCK_WAIT=1 CONFIRM=yes SKIP_BACKUP=yes bash -c '
    git() {
      command git "$@"; local status=$?
      if [[ "$1" == revert && "$2" == --no-commit ]]; then touch "$CLONE/.git/index.lock"; fi
      return "$status"
    }
    export -f git
    ./scripts/rollback.sh prod-sim' || status=$?
  rm -f "$CLONE/.git/index.lock"
  expect "a stop" [ "$status" -ne 0 ]
  expect "it says the revert is still here" said "The revert is still in this checkout"
  expect "and what to run for the path HEAD lacks" said "git rm --force --quiet --cached --ignore-unmatch -- docs/x.txt, rm -f -- docs/x.txt"
  # What it says works.
  git -C "$CLONE" restore --source=HEAD --staged --worktree -- "$PROD_SIM_RENDERED" "$PROD_SIM_OVERLAY"
  git -C "$CLONE" rm --force --quiet --cached --ignore-unmatch -- docs/x.txt
  rm -f "$CLONE/docs/x.txt"
  git -C "$CLONE" revert --quit
  expect "nothing left in progress" nothing_in_progress
  expect "the checkout is clean" equal "$(git -C "$CLONE" status --porcelain -- helm gitops docs/x.txt)" ""
}

# ---- publish: what it sends, and what its warning says
publish_creates_the_bare_repository() {
  local status=0
  rm -rf "${BARE:?}"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says so" said "created $BARE"
  expect "published" equal "$(published)" "$(head_commit)"
  expect "a first publish has nothing to compare, so it asks the cluster nothing" [ ! -s "$STUB/kubectl-calls" ]
}
publish_sends_what_it_checked() {
  # A dump takes minutes, and a commit made meanwhile has not been checked.
  local status=0 checked
  merged_prod_sim_promotion
  checked="$(head_commit)"
  echo someone-commits >"$STUB/backup-mode"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "a commit did land during the dump" [ "$(head_commit)" != "$checked" ]
  expect "it stays for the next publish" equal "$(published)" "$checked"
}
publish_warning_leaves_dev_out_when_it_only_moves_an_image() {
  local status=0
  in_clone env SKIP_REGISTRY_CHECK=yes COMMIT=no ./scripts/promote.sh dev IMAGE=web DIGEST="$DIGEST_A"
  git -C "$CLONE" add -- helm gitops
  git -C "$CLONE" commit --quiet -F "$CLONE/.build/promote-message.txt"
  printf 'commonAnnotations:\n  flow-test: "yes"\n' >>"$CLONE/$PROD_SIM_OVERLAY"
  commit_a_change_to_helm 'a change to the prod-sim overlay alone'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "dev is not in it" said "they reach prod-sim with this push"
}
publish_warning_says_when_its_list_is_cut() {
  local status=0 n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do printf 'note\n' >"$CLONE/helm/plane/components/hardening/zz-note-$n.txt"; done
  printf -- '---\napiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: flow-test\nautomountServiceAccountToken: false\n' >>"$CLONE/helm/plane/components/hardening/serviceaccounts.yaml"
  commit_a_change_to_helm 'many paths'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "ten paths named" equal "$(grep -c '^       helm/plane' "$OUT")" 10
  expect "and the rest counted" said "and 4 more"
}
publish_warning_says_nothing_of_more_when_all_are_named() {
  local status=0
  printf -- '---\napiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: flow-test\nautomountServiceAccountToken: false\n' >>"$CLONE/helm/plane/components/hardening/serviceaccounts.yaml"
  commit_a_change_to_helm 'one path'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it names the path" said "helm/plane/components/hardening/serviceaccounts.yaml"
  expect "no count" not_said " more"
}
publish_warning_says_when_no_source_changed() {
  local status=0
  printf '# a hand edit\n' >>"$CLONE/$PROD_SIM_RENDERED"
  git -C "$CLONE" add -- gitops
  git -C "$CLONE" commit --quiet -m 'a hand edit of the render'
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "it says so" said "The render changed with no source change"
  expect "and promises no list" not_said "Changed under helm/plane:"
}
publish_warns_when_a_digest_by_hand_breaks_the_invariant() {
  # dev runs it, so the plane-dev check is content, but it is admin's digest under web.
  local status=0 admin
  admin="$(admin_digest)"
  dev_runs_its_overlay
  set_image prod-sim artifacts.plane.so/makeplane/plane-frontend "docker.io/fixture/plane-admin:v0@$admin"
  commit_a_change_to_helm 'by hand, not through promote: web takes the admin digest'
  one_pod '' Running '{"name":"admin","ready":true}' "{\"name\":\"admin\",\"image\":\"docker.io/fixture/plane-admin:v0@$admin\"}"
  in_clone ./scripts/gitops-publish.sh || status=$?
  expect "it publishes" [ "$status" -eq 0 ]
  expect "the check of plane-dev passes" said "passed: plane-dev was Synced and Healthy"
  expect "the warning" said "in a way make promote would refuse"
  expect "and why" said "recorded for dev under another image"
}
publish_quiet_about_the_invariant_for_a_promotion() {
  local status=0
  promote_dev "$DIGEST_A"
  promote_prod_sim
  expect "no warning" not_said "in a way make promote would refuse"
  expect "published" equal "$(published)" "$(head_commit)"
}
step_summary_says_the_check_was_skipped() {
  # This script clears the variable for every other scenario, so this one sets it.
  local status=0
  promote_dev "$DIGEST_A"
  echo down >"$STUB/cluster"
  in_clone env GITHUB_STEP_SUMMARY="$STUB/step-summary" SKIP_REGISTRY_CHECK=yes SKIP_BACKUP=yes CONFIRM=yes COMMIT=no ./scripts/promote.sh prod-sim || status=$?
  expect "the promotion goes ahead" [ "$status" -eq 0 ]
  expect "the job summary says so" grep -q 'The plane-dev check was skipped' "$STUB/step-summary"
  rm -f "$STUB/step-summary"
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
scenario rollback-prod-sim-past-a-later-change-beside-the-image rollback_prod_sim_past_a_later_change_beside_the_image
scenario rollback-dev-past-a-later-change-beside-the-image rollback_dev_past_a_later_change_beside_the_image
scenario rollback-stops-on-a-conflict-in-the-overlay rollback_stops_on_a_conflict_in_the_overlay
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
scenario promote-refuses-a-terminating-pod terminating_pod_proves_nothing
scenario promote-refuses-a-pod-not-running pod_not_running_proves_nothing
scenario promote-refuses-a-ready-sibling ready_sibling_proves_nothing
scenario promote-refuses-the-failure-drill-digest failure_drill_digest_stays_out_of_prod_sim
scenario promote-stops-when-the-dump-fails promote_stops_when_the_dump_fails
scenario publish-stops-when-the-dump-fails publish_stops_when_the_dump_fails
scenario promote-prod-sim-needs-confirmation promote_prod_sim_needs_confirmation
scenario rollback-prod-sim-needs-confirmation rollback_prod_sim_needs_confirmation
scenario promote-refuses-a-dirty-overlay promote_refuses_a_dirty_overlay
scenario rollback-refuses-a-dirty-overlay rollback_refuses_a_dirty_overlay
scenario promote-refuses-off-main promote_refuses_off_main
scenario rollback-refuses-off-main rollback_refuses_off_main
scenario promote-refuses-while-a-revert-is-under-way promote_refuses_while_a_revert_is_under_way
scenario promote-takes-a-whole-digests-file promote_takes_a_whole_digests_file
scenario promote-refuses-a-partial-digests-file promote_refuses_a_partial_digests_file
scenario promote-refuses-a-malformed-digests-file promote_refuses_a_malformed_digests_file
scenario promote-checks-its-arguments promote_checks_its_arguments
scenario promote-refuses-an-ambiguous-image promote_refuses_an_ambiguous_image
scenario promote-render-failure-puts-the-overlay-back promote_render_failure_puts_the_overlay_back
scenario promote-ended-halfway-puts-the-overlay-back promote_ended_halfway_puts_the_overlay_back
scenario promote-commit-failure-puts-the-overlay-back promote_commit_failure_puts_the_overlay_back
scenario promote-waits-out-a-git-add promote_waits_out_a_git_add
scenario promote-says-what-to-do-when-the-index-stays-held promote_says_what_to_do_when_the_index_stays_held
scenario promote-rechecks-the-overlay-after-the-dump promote_rechecks_the_overlay_after_the_dump
scenario promote-holds-the-commit-lock-for-its-commit promote_holds_the_commit_lock_for_its_commit
scenario rollback-holds-the-commit-lock-for-its-commit rollback_holds_the_commit_lock_for_its_commit
scenario promote-waits-for-the-commit-lock promote_waits_for_the_commit_lock
scenario rollback-waits-for-the-commit-lock rollback_waits_for_the_commit_lock
scenario promote-gives-up-on-a-commit-lock-left-behind promote_gives_up_on_a_commit_lock_left_behind
scenario rollback-gives-up-on-a-commit-lock-left-behind rollback_gives_up_on_a_commit_lock_left_behind
scenario promote-again-publishes-after-a-refused-push promote_again_publishes_after_a_refused_push "$BASE_AHEAD"
scenario promote-again-publishes-after-a-refused-check promote_again_publishes_after_a_refused_check "$BASE_AHEAD"
scenario promote-dev-again-publishes-after-a-refused-push promote_dev_again_publishes_after_a_refused_push
scenario promote-commit-no-publishes-nothing promote_commit_no_publishes_nothing
scenario promote-dev-takes-the-dump-a-carried-prod-sim-change-needs promote_dev_takes_the_dump_a_carried_prod_sim_change_needs
scenario promote-dev-stops-when-a-carried-dump-fails promote_dev_stops_when_a_carried_dump_fails
scenario publish-names-the-prod-sim-commit-a-dev-change-waits-behind publish_names_what_a_dev_change_waits_behind
scenario publish-refusal-of-prod-sim-alone-says-nothing-of-dev publish_refusal_of_prod_sim_alone_says_nothing_of_dev
scenario rollback-dev-stops-before-moving-prod-sim rollback_dev_stops_before_moving_prod_sim
scenario rollback-chain-after-a-refused-promotion rollback_chain_after_a_refused_promotion
scenario rollback-dev-override-keeps-the-checks rollback_dev_override_keeps_the_checks
scenario rollback-dev-rerun-stops-too rollback_dev_rerun_stops_too
scenario rollback-dev-goes-on-past-what-does-not-move-prod-sim rollback_dev_goes_on_past_what_does_not_move_prod_sim
scenario rollback-dev-goes-on-when-a-promotion-was-withdrawn rollback_dev_goes_on_when_a_promotion_was_withdrawn
scenario rollback-conflict-keeps-someones-staged-work rollback_conflict_keeps_someones_staged_work
scenario rollback-conflict-with-a-partly-staged-file rollback_conflict_with_a_partly_staged_file
scenario rollback-render-failure-keeps-someones-staged-work rollback_render_failure_keeps_someones_staged_work
scenario rollback-commit-failure-can-run-again rollback_commit_failure_can_run_again
scenario rollback-ended-halfway-puts-the-revert-back rollback_ended_halfway_puts_the_revert_back
scenario rollback-waits-out-a-git-add rollback_waits_out_a_git_add
scenario rollback-says-what-to-do-when-the-index-stays-held rollback_says_what_to_do_when_the_index_stays_held
scenario rollback-says-when-the-revert-cannot-start rollback_says_when_the_revert_cannot_start
scenario rollback-leaves-someones-merge-alone rollback_leaves_someones_merge_alone
scenario rollback-says-a-promotion-put-back-by-hand-is-undone rollback_says_a_promotion_put_back_by_hand_is_undone
scenario rollback-promotion-that-added-a-file rollback_promotion_that_added_a_file
scenario rollback-promotion-whose-added-file-is-gone rollback_promotion_whose_added_file_is_gone
scenario rollback-refuses-an-edit-in-a-file-the-promotion-touched rollback_refuses_an_edit_in_a_file_the_promotion_touched
scenario rollback-rechecks-after-the-dump rollback_rechecks_after_the_dump
scenario rollback-leaves-the-other-render-as-git-has-it rollback_leaves_the_other_render_as_git_has_it
scenario rollback-finds-a-subject-only-promotion rollback_finds_a_subject_only_promotion
scenario rollback-finds-a-trailer-only-promotion rollback_finds_a_trailer_only_promotion
scenario rollback-second-attempt-names-the-dump-from-before-the-promotion rollback_second_attempt_names_the_dump_from_before_the_promotion
scenario rollback-says-when-no-dump-is-older rollback_says_when_no_dump_is_older
scenario rollback-skips-an-unfinished-dump rollback_skips_an_unfinished_dump
scenario publish-says-when-another-publish-sent-it publish_says_when_another_publish_sent_it
scenario promote-says-nothing-of-a-stay-when-another-publish-sent-it promote_says_nothing_of_a_stay_when_another_publish_sent_it
scenario promote-names-its-own-commit-when-the-publish-fails promote_names_its_own_commit_when_the_publish_fails
scenario rollback-names-its-own-commit-when-the-publish-fails rollback_names_its_own_commit_when_the_publish_fails
scenario publish-advice-fits-a-change-by-hand publish_advice_fits_a_change_by_hand
scenario rollback-advice-on-a-conflict-works-with-dev-broken rollback_advice_on_a_conflict_works_with_dev_broken
scenario promote-empty-plan-reads-the-render promote_empty_plan_reads_the_render
scenario rollback-stops-on-a-commit-touching-both-environments rollback_stops_on_a_commit_touching_both_environments
scenario rollback-stops-cleanly-when-a-later-commit-removed-a-file rollback_stops_cleanly_when_a_later_commit_removed_a_file
scenario rollback-how-to-clear-works-on-a-path-head-lacks rollback_how_to_clear_works_on_a_path_head_lacks
scenario rollback-of-a-refused-promotion-says-nothing-to-restore rollback_of_a_refused_promotion_says_nothing_to_restore
scenario rollback-of-a-retried-promotion-names-the-dump-of-the-run-that-sent-it rollback_of_a_retried_promotion_names_the_dump_of_the_run_that_sent_it
scenario rollback-rerun-names-the-dump rollback_rerun_names_the_dump
scenario rollback-rerun-of-a-withdrawal-says-nothing-to-restore rollback_rerun_of_a_withdrawal_says_nothing_to_restore
scenario rollback-goes-by-the-commit-with-no-record-of-the-publish rollback_goes_by_the_commit_with_no_record_of_the_publish
scenario rollback-reverts-a-refused-promotion-above-an-unpublished-revert rollback_reverts_a_refused_promotion_above_an_unpublished_revert
scenario rollback-stops-before-sending-what-waits-under-a-withdrawal rollback_stops_before_sending_what_waits_under_a_withdrawal
scenario publish-creates-the-bare-repository publish_creates_the_bare_repository
scenario publish-sends-what-it-checked publish_sends_what_it_checked
scenario publish-warning-leaves-dev-out-when-it-only-moves-an-image publish_warning_leaves_dev_out_when_it_only_moves_an_image
scenario publish-warning-says-when-its-list-is-cut publish_warning_says_when_its_list_is_cut
scenario publish-warning-says-nothing-of-more-when-all-are-named publish_warning_says_nothing_of_more_when_all_are_named
scenario publish-warning-says-when-no-source-changed publish_warning_says_when_no_source_changed
scenario publish-warns-when-a-digest-by-hand-breaks-the-invariant publish_warns_when_a_digest_by_hand_breaks_the_invariant
scenario publish-quiet-about-the-invariant-for-a-promotion publish_quiet_about_the_invariant_for_a_promotion
scenario promote-no-cluster-writes-the-job-summary step_summary_says_the_check_was_skipped

[[ $((passed + failed)) -gt 0 ]] || die "no scenario matches '$FILTER'"
[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) promotion flow scenarios failed"
ok "$passed of $passed promotion flow scenarios passed, with a stub cluster"
