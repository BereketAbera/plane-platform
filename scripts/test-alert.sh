#!/usr/bin/env bash
# Prove the alert path end to end: blackbox probe, Prometheus rule, Alertmanager, webhook sink, for
# firing and for resolved, and prove the other environment stays quiet throughout.
#
#   scripts/test-alert.sh dev            or prod-sim
#
# Scaling the API to zero is the injection. Auto-sync must be paused or self-heal undoes that in
# about 5 seconds, long before for: 1m elapses. A trap scales it back and restores auto-sync on any
# exit, including Ctrl-C. Each stage has its own deadline, derived from the 5s preStop sleep the old
# pod still answers through, the 15s probe, 15s rule group, for: 1m and group_wait 10s: worst case
# about 125s to the sink.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"

accept_assignments "ENV" "$@"
for arg in "$@"; do case "$arg" in *=*) ;; *) ENV="$arg" ;; esac; done
ENV="${ENV:-dev}"
select_env "$ENV"
case "$ENV_NAME" in
  dev) OTHER_NS=plane-prod-sim ;;
  prod-sim) OTHER_NS=plane-dev ;;
  *) die "this drill applies to a Plane environment: dev or prod-sim" ;;
esac

guard_disk
need_cluster
for tool in curl jq; do command -v "$tool" >/dev/null || die "$tool is required"; done

ALERT=PlaneApiDown
DEPLOY=plane-api-wl
PENDING_DEADLINE=60
FIRING_DEADLINE=150
ALERTMANAGER_DEADLINE=165
SINK_DEADLINE=180
RESOLVE_DEADLINE=300

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$LOCAL_DIR/evidence-raw"
evidence="$LOCAL_DIR/evidence-raw/alert-test-$ENV_NAME-$STAMP.json"

original_replicas=""
injected=no
t_pending=null t_firing=null t_alertmanager=null t_sink=null t_resolved=null
isolation=NOT_RUN stage_failed=""

write_evidence() { # result
  jq -n --arg alert "$ALERT" --arg ns "$NS" --arg other "$OTHER_NS" --arg result "$1" --arg at "$STAMP" \
    --arg isolation "$isolation" --arg failed "$stage_failed" \
    --argjson pending "$t_pending" --argjson firing "$t_firing" --argjson am "$t_alertmanager" \
    --argjson sink "$t_sink" --argjson resolved "$t_resolved" \
    '{alert: $alert, namespace: $ns, other_namespace: $other, started_at: $at, result: $result,
      failed_stage: (if $failed == "" then null else $failed end), isolation: $isolation,
      seconds_after_injection: {pending: $pending, firing: $firing, alertmanager: $am, sink_firing: $sink},
      seconds_after_recovery: {sink_resolved: $resolved}}' > "$evidence"
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$injected" == yes && -n "$original_replicas" ]]; then
    kc -n "$NS" scale "deployment/$DEPLOY" --replicas="$original_replicas" >/dev/null || warn "could not scale $DEPLOY back to $original_replicas"
  fi
  argo_resume
  if [[ $rc -eq 0 ]]; then
    write_evidence PASS
    ok "$ALERT delivered and resolved, $OTHER_NS stayed quiet. Evidence: $evidence"
  else
    write_evidence FAIL
    warn "alert test FAILED at stage: ${stage_failed:-before injection}. Evidence: $evidence"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_stage() { # stage message
  stage_failed="$1"
  die "$2"
}

prom_alert_state() { # namespace. Prints firing, pending or none.
  curl -fsS -m 10 "$PROM_URL/api/v1/alerts" | jq -r --arg a "$ALERT" --arg n "$1" '
    [.data.alerts[] | select(.labels.alertname == $a and .labels.namespace == $n) | .state] as $s
    | if any($s[]; . == "firing") then "firing" elif ($s | length) > 0 then "pending" else "none" end'
}

am_active_count() { # namespace
  curl -fsS -m 10 -G "$AM_URL/api/v2/alerts" --data-urlencode 'active=true' --data-urlencode 'silenced=false' \
    --data-urlencode 'inhibited=false' --data-urlencode "filter=alertname=\"$ALERT\"" \
    --data-urlencode "filter=namespace=\"$1\"" | jq 'length'
}

sink_has() { # status namespace. -R plus fromjson? tolerates a non-JSON line.
  [[ -n "$(kc -n monitoring logs deploy/alert-sink --since-time="$T0_ISO" 2>/dev/null | jq -Rc --arg a "$ALERT" --arg n "$2" --arg s "$1" '
    fromjson? | select(.payload.status == $s) | select(any(.payload.alerts[]; .labels.alertname == $a and .labels.namespace == $n))')" ]]
}

# Scaling an api to zero could only reach the other environment through the probes that exercise the api
# and the frontends that call it, so those are the alerts that would mean the environments are not isolated.
# Anything else there is unrelated and says nothing about this drill, such as CPUThrottlingHigh on a pod that
# just started, or an Argo alert carrying dest_namespace.
ISOLATION_ALERTS='^(PlaneApiDown|PlaneApiDatabaseProbeFailing|PlaneFrontendDown)$'

# Those alerts in the other environment, as sorted name|fingerprint pairs, to compare before and after.
# One that was already firing there is unrelated to this drill, so only new ones count.
other_env_alerts() {
  curl -fsS -m 10 -G "$AM_URL/api/v2/alerts" --data-urlencode 'active=true' | jq -r --arg n "$OTHER_NS" --arg re "$ISOLATION_ALERTS" '
    [.[] | select(.labels.namespace == $n and (.labels.alertname | test($re))) | "\(.labels.alertname)|\(.fingerprint)"] | sort | join(" ")'
}

check_isolation() { # baseline
  local current new
  [[ "$(am_active_count "$OTHER_NS")" == 0 ]] || { isolation=FAIL; fail_stage isolation "$ALERT is active in $OTHER_NS too"; }
  ! sink_has firing "$OTHER_NS" || { isolation=FAIL; fail_stage isolation "the sink received a firing $ALERT for $OTHER_NS"; }
  current="$(other_env_alerts)"
  new=""
  for item in $current; do
    case " $1 " in *" $item "*) ;; *) new="$new $item" ;; esac
  done
  [[ -z "$new" ]] || { isolation=FAIL; fail_stage isolation "new alerts in $OTHER_NS during the drill:$new"; }
  isolation=PASS
}

log "Preflight"
curl -fsS -m 10 "$PROM_URL/-/ready" >/dev/null || die "Prometheus is not reachable at $PROM_URL"
curl -fsS -m 10 "$AM_URL/-/ready" >/dev/null || die "Alertmanager is not reachable at $AM_URL"
kc -n monitoring rollout status deployment/alert-sink --timeout=30s >/dev/null || die "alert-sink is not ready"
curl -fsS -m 10 -G "$PROM_URL/api/v1/rules" --data-urlencode 'type=alert' \
  | jq -e --arg a "$ALERT" '[.data.groups[].rules[].name] | index($a)' >/dev/null || die "rule $ALERT is not loaded"
[[ "$(prom_alert_state "$NS")" == none ]] || die "$ALERT is already active in $NS: this would prove nothing"
for ns in "$NS" "$OTHER_NS"; do
  [[ "$(prom_query "probe_success{namespace=\"$ns\",probe=\"api-instance\"}" | jq -r '.data.result[0].value[1] // "none"')" == 1 ]] \
    || die "API probe in $ns is not healthy before the test"
done
original_replicas="$(kc -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.spec.replicas}')"
[[ "$original_replicas" -ge 1 ]] || die "$DEPLOY has $original_replicas replicas before the test"
baseline="$(other_env_alerts)"
ok "preflight passed; $OTHER_NS baseline alerts: ${baseline:-none}"

argo_pause "$APP"

log "Injecting: scaling $NS/$DEPLOY to 0"
T0=$SECONDS
T0_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
injected=yes
kc -n "$NS" scale "deployment/$DEPLOY" --replicas=0 >/dev/null

elapsed=0
while [[ "$t_sink" == null ]]; do
  elapsed=$((SECONDS - T0))
  state="$(prom_alert_state "$NS" || echo none)"
  if [[ "$t_pending" == null && "$state" != none ]]; then t_pending=$elapsed; ok "pending after ${elapsed}s"; fi
  if [[ "$t_firing" == null && "$state" == firing ]]; then t_firing=$elapsed; ok "firing in Prometheus after ${elapsed}s"; fi
  if [[ "$t_alertmanager" == null && "$(am_active_count "$NS" || echo 0)" -ge 1 ]]; then t_alertmanager=$elapsed; ok "active in Alertmanager after ${elapsed}s"; fi
  if sink_has firing "$NS"; then t_sink=$elapsed; ok "firing webhook reached the sink after ${elapsed}s"; break; fi

  [[ "$t_pending" != null || $elapsed -le $PENDING_DEADLINE ]] || fail_stage pending "no pending alert after ${PENDING_DEADLINE}s. Is the probe failing? Check probe_success{namespace=\"$NS\"}"
  [[ "$t_firing" != null || $elapsed -le $FIRING_DEADLINE ]] || fail_stage firing "not firing after ${FIRING_DEADLINE}s. Rule has for: 1m and interval 15s"
  [[ "$t_alertmanager" != null || $elapsed -le $ALERTMANAGER_DEADLINE ]] || fail_stage alertmanager "not in Alertmanager after ${ALERTMANAGER_DEADLINE}s. Check NetworkPolicy prometheus to alertmanager:9093"
  [[ $elapsed -le $SINK_DEADLINE ]] || fail_stage sink "no webhook at the sink after ${SINK_DEADLINE}s. Check NetworkPolicy alertmanager to alert-sink:8080"
  sleep 3
done

log "Checking the other environment stayed quiet"
check_isolation "$baseline"
ok "$OTHER_NS stayed quiet"

log "Recovering: scaling $DEPLOY back to $original_replicas"
kc -n "$NS" scale "deployment/$DEPLOY" --replicas="$original_replicas" >/dev/null
injected=no
T1=$SECONDS
# API boot runs migrations checks, instance registration and collectstatic before gunicorn binds.
while ! sink_has resolved "$NS"; do
  elapsed=$((SECONDS - T1))
  [[ $elapsed -le $RESOLVE_DEADLINE ]] || fail_stage resolved "no resolved webhook within ${RESOLVE_DEADLINE}s of recovery"
  sleep 5
done
t_resolved=$((SECONDS - T1))
ok "resolved webhook reached the sink ${t_resolved}s after recovery"

check_isolation "$baseline"
