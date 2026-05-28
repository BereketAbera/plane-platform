#!/usr/bin/env bash
# Failure drill: delete the pod of every StatefulSet in an environment, one at a time, and prove the
# data survives by re-reading the sentinel that tests/e2e/smoke.py wrote through the real API.
#
#   tests/drills/pod-restart-persistence.sh              dev
#   tests/drills/pod-restart-persistence.sh prod-sim
#
# Deleting a pod changes no spec, so Argo CD sees no drift, self-heal has nothing to revert, and
# there is no need to pause it. The exit trap only has to wait for whatever was interrupted.
#
# Each round also creates a new work item and waits for its background activity, because after a
# broker restart the old rows prove nothing about the async path.
#
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ENV="${ENV:-dev}"
accept_args ENV -- "$@"
case "$ENV" in
  dev) HOST=plane.dev.localhost ;;
  prod-sim) HOST=plane.prod-sim.localhost ;;
  *) die "usage: $0 [dev|prod-sim]" ;;
esac
NS="plane-$ENV"

guard_disk 2
cd "$ROOT"
drill_start "pod-restart-$ENV"

SMOKE=(python3 -B "$ROOT/tests/e2e/smoke.py" --env "$ENV" --mode verify --wait-seconds 300 --job-timeout 300)
restart_in_progress=""

restore() {
  local status=$?
  if [[ -n "$restart_in_progress" ]]; then
    stage "Restore (exit trap)"
    # The controller recreates the pod whatever happens here, so all that is left is to wait for it.
    if kc -n "$NS" rollout status "statefulset/$restart_in_progress" --timeout=300s; then
      pass "$restart_in_progress recovered after the interruption"
    else
      fail "$restart_in_progress is not ready. Check: kubectl -n $NS describe statefulset $restart_in_progress"
      status=1
    fi
  fi
  drill_result_on_abort
  exit "$status"
}
trap restore EXIT

stage "0. Preflight"
kc get --raw /readyz >/dev/null || abort "cluster is not reachable"
status="$(http_status "$HOST")"
[[ "$status" == 200 ]] || abort "$HOST answers $status before the drill"
STATEFULSETS="$(kc -n "$NS" get statefulset -o jsonpath='{.items[*].metadata.name}')"
[[ -n "$STATEFULSETS" ]] || abort "no StatefulSets in $NS"
pass "StatefulSets: $STATEFULSETS"

# Without a baseline, a sentinel lost before the drill would look like something the drill caused.
set +e
"${SMOKE[@]}" --evidence "$LOCAL_DIR/evidence-raw/drill-pod-restart-$ENV-baseline.json"
baseline=$?
set -e
[[ "$baseline" -eq 0 ]] || abort "sentinel not readable before the drill (smoke exit $baseline). Run make test-e2e ENV=$ENV first."
pass "sentinel is intact before any restart"

# A worker that has been through cancel_consumer runs normally until its next broker reconnect, which this
# drill causes, and then consumes nothing. That would read as the broker restart's fault, so stop here.
worker_log="$(kc -n "$NS" logs deploy/plane-worker-wl --tail=-1)" || abort "cannot read the worker's log"
if [[ "$worker_log" == *"Canceling queue"* ]]; then
  abort "the worker has been through cancel_consumer, so it would stop consuming when the broker restarts. Replace it first: kubectl -n $NS delete pod -l app.kubernetes.io/component=worker"
fi
pass "no cancel_consumer in the worker's log, so a broker restart tests the broker"

round=0
for statefulset in $STATEFULSETS; do
  round=$((round + 1))
  stage "$round. Restart $statefulset"
  replicas="$(kc -n "$NS" get statefulset "$statefulset" -o jsonpath='{.spec.replicas}')"
  # Every replica, last ordinal first, the same order the controller itself uses to scale down.
  ordinal="${replicas:-1}"
  while [[ "$ordinal" -gt 0 ]]; do
    ordinal=$((ordinal - 1))
    pod="$statefulset-$ordinal"
    old_uid="$(kc -n "$NS" get pod "$pod" -o jsonpath='{.metadata.uid}')"
    claims="$(kc -n "$NS" get pod "$pod" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')"
    volumes_before=""
    for claim in $claims; do
      volumes_before+="$claim=$(kc -n "$NS" get pvc "$claim" -o jsonpath='{.metadata.uid}') "
    done

    restart_in_progress="$statefulset"
    kc -n "$NS" delete pod "$pod" --wait=true --timeout=180s
    if ! kc -n "$NS" rollout status "statefulset/$statefulset" --timeout=300s; then
      abort "$statefulset did not become ready within 300s"
    fi
    kc -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null || abort "$pod is not Ready"
    restart_in_progress=""

    new_uid="$(kc -n "$NS" get pod "$pod" -o jsonpath='{.metadata.uid}')"
    if [[ "$new_uid" != "$old_uid" && -n "$new_uid" ]]; then
      pass "$pod was really replaced"
    else
      fail "$pod still has uid $old_uid, so nothing was restarted"
    fi

    volumes_after=""
    for claim in $claims; do
      volumes_after+="$claim=$(kc -n "$NS" get pvc "$claim" -o jsonpath='{.metadata.uid}') "
    done
    if [[ -z "$claims" ]]; then
      pass "$pod has no PersistentVolumeClaim, so its data is transient by design"
    elif [[ "$volumes_before" == "$volumes_after" ]]; then
      pass "$pod reattached the same claim: $claims"
    else
      fail "$pod claims changed: before $volumes_before, after $volumes_after"
    fi
  done

  set +e
  "${SMOKE[@]}" --job-probe --evidence "$LOCAL_DIR/evidence-raw/drill-pod-restart-$ENV-$statefulset.json"
  result=$?
  set -e
  if [[ "$result" -eq 0 ]]; then
    pass "after restarting $statefulset: sentinel row and attachment intact, background jobs run"
  else
    fail "after restarting $statefulset: smoke verify exit $result"
  fi
done

drill_finish
