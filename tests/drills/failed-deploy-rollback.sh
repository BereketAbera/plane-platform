#!/usr/bin/env bash
# Failure drill: a bad image reaches dev through the real promotion path, Argo CD and the rollout
# refuse it, the old pods keep serving, and git revert restores the environment.
#
#   tests/drills/failed-deploy-rollback.sh
#
# Runs only against dev, and always through Git. It adds two commits to main: the promotion and
# its revert. Self-heal stays on: the bad state is the desired state in Git here, so Argo CD has
# nothing to undo. That is the point of the drill. Pausing it is needed only for changes made
# behind Git's back, and this drill makes none.
#
# The web image is used because only the web Deployment runs it, so the migrator hook still passes
# and the failure lands in the wave 3 rollout rather than in the hook.
#
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

guard_disk 2
cd "$ROOT"

APP=plane-dev
NS=plane-dev
DEPLOYMENT=plane-web-wl
HOST=plane.dev.localhost
# Syntactically valid, so every static check passes it, and no registry can serve it.
BAD_DIGEST="sha256:$(printf '0%.0s' {1..64})"

drill_start failed-deploy
NEEDS_RESTORE=no

# Only what this drill committed. If the promotion failed before its commit, the newest promotion on
# main belongs to someone else, and rolling back would revert that instead.
bad_digest_on_main() { git grep -qF "$BAD_DIGEST" HEAD -- helm/plane/overlays/dev/kustomization.yaml; }

restore() {
  local status=$?
  if [[ "$NEEDS_RESTORE" == yes ]] && ! bad_digest_on_main; then
    stage "Restore (exit trap)"
    pass "the bad digest never reached main, so there is nothing to revert"
  elif [[ "$NEEDS_RESTORE" == yes ]]; then
    stage "Restore (exit trap)"
    if "$ROOT/scripts/rollback.sh" dev; then
      refresh_app "$APP" || true
      pass "bad promotion reverted by the trap"
    else
      fail "automatic restore failed. Run scripts/rollback.sh dev and check Application $APP"
      status=1
    fi
  fi
  drill_result_on_abort
  exit "$status"
}
trap restore EXIT

stage "0. Preflight"
[[ -z "$(git status --porcelain -- helm/plane/overlays/dev gitops/environments/dev)" ]] || abort "dev overlay has uncommitted changes"
[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || abort "run from main"
kc get --raw /readyz >/dev/null || abort "cluster is not reachable"
app_is "$APP" Synced Healthy || abort "$APP must start Synced and Healthy, it is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status)"
[[ "$(http_status "$HOST")" == 200 ]] || abort "$HOST does not answer 200 before the drill"
OLD_IMAGE="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')"
OLD_PODS="$(kc -n "$NS" get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[*].metadata.uid}')"
[[ -n "$OLD_PODS" ]] || abort "no web pods found"
DEADLINE="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.progressDeadlineSeconds}')"
pass "$APP is Synced and Healthy, serving $OLD_IMAGE"

stage "1. Promote a digest that cannot be pulled"
NEEDS_RESTORE=yes
SKIP_REGISTRY_CHECK=yes "$ROOT/scripts/promote.sh" dev IMAGE=web DIGEST="$BAD_DIGEST"
BAD_COMMIT="$(git rev-parse HEAD)"
pass "promotion committed and published as ${BAD_COMMIT:0:12}"

stage "2. Argo CD applies it"
deployment_has_bad_image() { kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -qF "$BAD_DIGEST"; }
refresh_app "$APP"
if poll 300 deployment_has_bad_image; then
  pass "Deployment now asks for the bad digest"
else
  abort "Argo CD did not apply the commit within 300s. Sync status: $(app_field "$APP" .status.operationState.message)"
fi

stage "3. The new pod cannot start"
bad_pod_is_stuck() {
  kc -n "$NS" get pods -l app.kubernetes.io/component=web \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' |
    grep -qE '^(ErrImagePull|ImagePullBackOff)$'
}
if poll 180 bad_pod_is_stuck; then
  pass "new pod is in ErrImagePull or ImagePullBackOff"
else
  fail "no pod reached an image pull error within 180s"
fi

stage "4. Argo CD reports the failure while the old pods keep serving"
samples=0
bad_samples=0
degraded=no
# progressDeadlineSeconds decides when the Deployment, and so Argo CD, declares failure.
deadline=$((SECONDS + ${DEADLINE:-600} + 120))
while [[ $SECONDS -lt $deadline ]]; do
  samples=$((samples + 1))
  [[ "$(http_status "$HOST")" == 200 ]] || bad_samples=$((bad_samples + 1))
  if [[ "$(app_field "$APP" .status.health.status)" == Degraded ]]; then
    degraded=yes
    break
  fi
  sleep 10
done
if [[ "$degraded" == yes ]]; then
  pass "Application health is Degraded"
else
  available="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.status.updatedReplicas}/{.status.readyReplicas}')"
  condition="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')"
  if [[ "$condition" == ProgressDeadlineExceeded ]]; then
    pass "Deployment is ProgressDeadlineExceeded ($available updated/ready), though Application health is $(app_field "$APP" .status.health.status)"
  else
    fail "neither Degraded nor ProgressDeadlineExceeded after waiting. Progressing=$condition"
  fi
fi
if [[ "$bad_samples" -eq 0 ]]; then
  pass "$HOST answered 200 on all $samples samples during the failed rollout"
else
  fail "$HOST failed $bad_samples of $samples samples during the failed rollout"
fi
for uid in $OLD_PODS; do
  if kc -n "$NS" get pods -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.uid}{"\n"}{end}' | grep -qx "$uid"; then
    pass "old pod $uid is still Ready"
  else
    fail "old pod $uid is gone or not Ready"
  fi
done

stage "5. git revert restores"
"$ROOT/scripts/rollback.sh" dev
NEEDS_RESTORE=no
if git log -1 --format=%B | grep -qF "This reverts commit $BAD_COMMIT"; then
  pass "HEAD reverts ${BAD_COMMIT:0:12}"
else
  fail "HEAD is not the revert of the bad promotion"
fi
if grep -qF "$BAD_DIGEST" gitops/environments/dev/manifests.yaml; then
  fail "rendered dev manifests still name the bad digest"
else
  pass "rendered dev manifests no longer name the bad digest"
fi

deployment_has_old_image() { [[ "$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$OLD_IMAGE" ]]; }
app_recovered() { app_is "$APP" Synced Healthy; }
refresh_app "$APP"
if poll 300 deployment_has_old_image; then
  pass "Deployment is back on $OLD_IMAGE"
else
  fail "Deployment did not return to the old image within 300s"
fi
if poll 300 app_recovered; then
  pass "$APP is Synced and Healthy again"
else
  fail "$APP is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status) after 300s"
fi
if kc -n "$NS" get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -qF "$BAD_DIGEST"; then
  fail "a pod still references the bad digest"
else
  pass "no pod references the bad digest"
fi
status="$(http_status "$HOST")"
if [[ "$status" == 200 ]]; then pass "$HOST answers 200"; else fail "$HOST answers $status"; fi

drill_finish
