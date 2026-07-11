#!/usr/bin/env bash
# Make a data service really go away, and read whether its alert fires and reaches the sink.
#
#   tests/drills/alert-rules.sh ENV=dev [ROWS="PlaneRabbitmqDown PlaneMinioDown"]
#
# scripts/test-alert.sh proves the whole path on one alert. This asks a narrower question of the others: is the rule's
# condition really true when the thing it names is gone? It scales a StatefulSet to 0 with auto-sync paused, watches
# Prometheus and the sink up to a deadline, then puts it back and waits for the resolve. One row at a time. A row that
# does not fire is a FAIL, and that is a result about the rule: the data volume is kept, and the pod comes back.
#
# What this is not: a crash, a hung process, a full disk or a network fault. Those can read differently.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=../../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"

accept_assignments "ENV ROWS" "$@"
ENV="${ENV:-dev}"
select_env "$ENV"
guard_disk
need_cluster

ROWS="${ROWS:-PlaneRabbitmqDown PlaneMinioDown}"
FIRE_DEADLINE=270
RESOLVE_DEADLINE=300
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
evidence="$LOCAL_DIR/evidence-raw/alert-rules-$ENV_NAME-$STAMP.txt"
exec > >(tee "$evidence") 2>&1

target_of() {
  case "$1" in
    PlaneRabbitmqDown) echo statefulset/plane-rabbitmq-wl ;;
    PlaneMinioDown) echo statefulset/plane-minio-wl ;;
    *) die "no injection is defined for $1" ;;
  esac
}

alert_state() { # alert. Prints firing, pending or none.
  curl -fsS -m 10 "$PROM_URL/api/v1/alerts" | jq -r --arg a "$1" --arg n "$NS" '
    [.data.alerts[] | select(.labels.alertname == $a and .labels.namespace == $n) | .state] as $s
    | if any($s[]; . == "firing") then "firing" elif ($s | length) > 0 then "pending" else "none" end'
}

sink_has() { # alert status since
  [[ -n "$(kc -n monitoring logs deploy/alert-sink --since-time="$3" 2>/dev/null | jq -Rc --arg a "$1" --arg s "$2" --arg n "$NS" '
    fromjson? | select(.payload.status == $s) | select(any(.payload.alerts[]; .labels.alertname == $a and .labels.namespace == $n))' 2>/dev/null)" ]]
}

injected=""
paused=no
cleanup() {
  local rc=$?
  trap - EXIT
  [[ -z "$injected" ]] || kc -n "$NS" scale "$injected" --replicas=1 >/dev/null || warn "could not scale $injected back to 1"
  [[ "$paused" == no ]] || argo_resume
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $(git -C "$ROOT" rev-parse --short HEAD) tests/drills/alert-rules.sh ENV=$ENV_NAME ROWS=$ROWS"
argo_pause "$APP"
paused=yes
for alert in $ROWS; do
  target="$(target_of "$alert")"
  log "$alert: scaling $NS/$target to 0"
  kc get --raw "/api/v1/namespaces/$NS/pods" >/dev/null
  t0=$SECONDS
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  injected="$target"
  kc -n "$NS" scale "$target" --replicas=0 >/dev/null
  fired=no last=""
  while (( SECONDS - t0 <= FIRE_DEADLINE )); do
    state="$(alert_state "$alert" || echo none)"
    if [[ "$state" != "$last" ]]; then printf '%s +%ss %s state %s\n' "$(date -u +%H:%M:%SZ)" "$((SECONDS - t0))" "$alert" "$state"; last="$state"; fi
    if sink_has "$alert" firing "$since"; then fired=yes; printf '%s +%ss %s firing webhook at the sink\n' "$(date -u +%H:%M:%SZ)" "$((SECONDS - t0))" "$alert"; break; fi
    sleep 5
  done
  if [[ "$fired" == no ]]; then
    echo "--- at the deadline, what Prometheus holds for this target"
    prom_query "up{namespace=\"$NS\",service=~\"plane-rabbitmq-metrics|plane-minio\"}" | jq -c '.data.result[] | {service: .metric.service, path: .metric.metrics_path, value: .value[1]}'
  fi
  log "putting $target back"
  kc -n "$NS" scale "$target" --replicas=1 >/dev/null
  injected=""
  kc -n "$NS" rollout status "$target" --timeout=240s >/dev/null || warn "$target did not come back in 240s"
  if [[ "$fired" == yes ]]; then
    t1=$SECONDS
    resolved=no
    while (( SECONDS - t1 <= RESOLVE_DEADLINE )); do
      if sink_has "$alert" resolved "$since"; then resolved=yes; break; fi
      sleep 5
    done
    if [[ "$resolved" == yes ]]; then
      printf 'PASS  %s fired with %s at 0, and resolved %ss after it came back\n' "$alert" "$target" "$((SECONDS - t1))"
    else
      printf 'FAIL  %s fired, but no resolve reached the sink in %ss\n' "$alert" "$RESOLVE_DEADLINE"
      failures=$((failures + 1))
    fi
  else
    printf 'FAIL  %s did not reach the sink within %ss of %s at 0\n' "$alert" "$FIRE_DEADLINE" "$target"
    failures=$((failures + 1))
  fi
done
argo_resume
paused=no
kc -n argocd annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null || true
echo "RESULT failures=$failures  evidence: $evidence"
[[ "$failures" -eq 0 ]]
