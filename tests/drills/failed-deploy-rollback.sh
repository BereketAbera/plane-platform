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
# A publish is all of main, so a prod-sim change waiting on main would leave with this drill's promotion,
# with no time to prove itself on a dev about to break, and rollback.sh refuses to carry one. So preflight
# stops on one before anything moves. rollback.sh reverts the newest promotion of dev, so run this alone:
# a promotion of dev made during it is what would be reverted, and stage 5 would say so.
#
# What to expect, by reading. These times are estimates until this has run with the current rules. The
# sync applies wave 3 after the migrator hook and waits on the rollout, which misses its 600s deadline, so
# the Application first reads Degraded about 10 to 11m in, and this reverts then. That sync attempt has failed,
# and the operation stays open: the next attempt starts 30s later, then 60s after that one fails
# (gitops/applications/plane-dev.yaml), reads the newest commit, runs the hook again, and only then puts
# the old image back. ArgoSyncFailed fires if the operation is still open about 13m in, so it may well fire.
#
# So what fires is not assumed here. From before the promotion until the alerts that appeared have gone,
# this keeps every pending and firing alert, as Prometheus itself reports them, and the Application's state,
# in <evidence>-alerts.tsv. Stage 6 prints them by alert, with what the alert sink received, and that is the
# answer to what really fires. No alert changes this drill's result, but Prometheus not answering does.
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
DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml
DEV_RENDERED=gitops/environments/dev/manifests.yaml
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
BARE="$LOCAL_DIR/git/plane-platform.git"
# Syntactically valid, so every static check passes it, and no registry can serve it.
BAD_DIGEST="sha256:$(printf '0%.0s' {1..64})"
# As monitoring/ops/lib.sh has it: through Traefik, the same way a person reaches it.
PROM_URL="${PROM_URL:-http://prometheus.localhost}"
# The rule groups evaluate every 15s and 30s.
ALERTS_EVERY="${ALERTS_EVERY:-15}"
# ArgoSyncFailed reads a 2m window, so it outlives its operation by that, then a 30s evaluation.
ALERTS_SETTLE="${ALERTS_SETTLE:-300}"

drill_start failed-deploy
NEEDS_RESTORE=no
ALERTS_FROM="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ALERTS_FILE="${DRILL_EVIDENCE%.log}-alerts.tsv"
ALERTS_RECORDING=no
ALERTS_REPORTED=no
RECORDER=""
PROMOTED_AT=""

# A hard refresh, because a normal one can still read the old main from the repo server's cache of refs, for up
# to 120s, and then nothing looks again until the next resync, measured 120s to 289s apart. That and the hook
# could use up stage 2's 300s, and would shift every time this drill is meant to show.
refresh_hard() { kc -n argocd annotate application "$1" argocd.argoproj.io/refresh=hard --overwrite >/dev/null; }

at() { # A time to read the alerts against
  printf 'AT    %s%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROMOTED_AT:+ +$((SECONDS - PROMOTED_AT))s}" "$*"
}

# ---- What fires

# One line per pending or firing alert: state, name, severity, when it went active, and its other labels.
# Returns 1 if Prometheus did not answer, and 2 if what answered is not its alerts API.
read_alerts() {
  local answer
  answer="$(curl -fsS -m 10 "$PROM_URL/api/v1/alerts" 2>/dev/null)" || return 1
  jq -r '.data.alerts[] | [.state, .labels.alertname, (.labels.severity // "-"), .activeAt,
    (.labels | del(.alertname, .severity) | to_entries | map("\(.key)=\(.value)") | join(","))] | @tsv' <<<"$answer" 2>/dev/null || return 2
}

# In the background, until stopped or until the drill is gone. An empty reading and one with no answer each
# get a line, so a quiet moment and a gap stay two different things.
record_alerts() {
  local now lines status line
  set +e
  while kill -0 "$$" 2>/dev/null; do
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    lines="$(read_alerts)"
    status=$?
    if [[ "$status" -ne 0 ]]; then
      printf '%s\tno-reading\n' "$now"
    elif [[ -z "$lines" ]]; then
      printf '%s\tnone\n' "$now"
    else
      while IFS= read -r line; do printf '%s\t%s\n' "$now" "$line"; done <<<"$lines"
    fi
    printf '%s\tapplication\t%s\n' "$now" "$(kc -n argocd get application "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}' 2>/dev/null)"
    sleep "$ALERTS_EVERY"
  done >>"$ALERTS_FILE" 2>/dev/null
}

stop_recording() {
  if [[ -n "$RECORDER" ]]; then
    kill "$RECORDER" 2>/dev/null || true
    wait "$RECORDER" 2>/dev/null || true
    RECORDER=""
  fi
}

nothing_new_is_active() { # True once nothing is pending or firing that was not at the first reading
  local now new
  now="$(read_alerts)" || return 1
  new="$(ALERTS_AT_START="$ALERTS_AT_START" awk -F'\t' '
    BEGIN {
      rows = split(ENVIRON["ALERTS_AT_START"], row, "\n")
      for (i = 1; i <= rows; i++) { split(row[i], field, "\t"); known[field[2] FS field[5]] = 1 }
    }
    NF && !(($2 FS $5) in known)' <<<"$now")"
  [[ -z "$new" ]]
}

# Prints the readings by alert, then the Application's changes, then what reached the sink. Once only, because
# the normal end and the exit trap both come here, and an aborted drill's record is still evidence.
alerts_report() {
  local readings gaps logs received
  [[ "$ALERTS_REPORTED" == no ]] || return 0
  ALERTS_REPORTED=yes
  if [[ "$ALERTS_RECORDING" == no ]]; then
    printf 'NOT RECORDED  no alert was read during this run, so it says nothing about what fires\n'
    return 0
  fi
  stop_recording
  readings="$(awk -F'\t' '!/^#/ && $2 != "application" && $2 != "no-reading" && !($1 in seen) { seen[$1] = 1; n++ } END { print n + 0 }' "$ALERTS_FILE")"
  gaps="$(awk -F'\t' '$2 == "no-reading" { n++ } END { print n + 0 }' "$ALERTS_FILE")"
  printf 'Prometheus %s/api/v1/alerts, every %ss since %s: %s readings, %s with no answer. Raw: %s\n' "$PROM_URL" "$ALERTS_EVERY" "$ALERTS_FROM" "$readings" "$gaps" "$ALERTS_FILE"
  [[ "$gaps" -eq 0 ]] || awk -F'\t' '$2 == "no-reading" { print "GAP   " $1 }' "$ALERTS_FILE"
  [[ "$readings" -gt 0 ]] || fail "no reading of Prometheus, so this run says nothing about what fires"
  # FIRED reached firing here. AT START was already there at the first reading. PENDING ONLY went pending and never fired.
  awk -F'\t' '
    /^#/ || $2 == "application" || $2 == "none" || $2 == "no-reading" { next }
    {
      if (start == "") start = $1
      key = $3 FS $6
      if (!(key in first)) { order[++count] = key; first[key] = $1; severity[key] = $4 }
      if ($2 == "pending" && !(key in pending)) pending[key] = $1
      if ($2 == "firing" && !(key in firing)) firing[key] = $1
      last[key] = $1
    }
    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        split(key, part, FS)
        class = (key in firing && firing[key] != start) ? "FIRED" : (first[key] == start ? "AT START" : "PENDING ONLY")
        printf "%-13s%s severity=%s first_pending=%s first_firing=%s last_seen=%s %s\n", class, part[1], severity[key],
          (key in pending ? pending[key] : "-"), (key in firing ? firing[key] : "-"), last[key], part[2]
      }
    }' "$ALERTS_FILE"
  awk -F'\t' '$2 == "application" && $3 != previous { print "APP   " $1 "  " $3; previous = $3 }' "$ALERTS_FILE"
  if logs="$(kc -n monitoring logs deploy/alert-sink --since-time="$ALERTS_FROM" 2>/dev/null)"; then
    received="$(jq -Rr 'fromjson? | .received_at as $at | .payload.alerts[]? | select(.labels.alertname != "Watchdog")
      | "SINK  \($at)  \(.status)  \(.labels.alertname)  \(.labels | del(.alertname) | to_entries | map("\(.key)=\(.value)") | join(","))"' <<<"$logs" 2>/dev/null || true)"
    printf '%s\n' "${received:-SINK  nothing but Watchdog since $ALERTS_FROM}"
  else
    printf 'NOT RECORDED  the alert sink log could not be read, so what reached it is not known\n'
  fi
}

# ---- The way back

# In what this drill can have left behind. On main alone the check would miss a revert committed and never published,
# with Argo CD still on the bad digest. If neither names it, the newest promotion on main belongs to someone else,
# and rolling back would revert that instead.
bad_digest_in_git() {
  git grep -qF "$BAD_DIGEST" HEAD -- "$DEV_OVERLAY" ||
    git --git-dir="$BARE" grep -qF "$BAD_DIGEST" refs/heads/main -- "$DEV_OVERLAY" 2>/dev/null
}

restore() {
  local status=$?
  if [[ "$NEEDS_RESTORE" == yes ]] && ! bad_digest_in_git; then
    stage "Restore (exit trap)"
    pass "the bad digest never reached main, so there is nothing to revert"
  elif [[ "$NEEDS_RESTORE" == yes ]]; then
    stage "Restore (exit trap)"
    # It also publishes a revert an earlier attempt committed and could not publish, and reverts nothing else.
    if "$ROOT/scripts/rollback.sh" dev; then
      refresh_hard "$APP" || true
      pass "bad promotion reverted by the trap. This did not wait for $APP to recover"
    else
      fail "automatic restore failed. Run scripts/rollback.sh dev and check Application $APP"
      status=1
    fi
  fi
  alerts_report || true
  stop_recording
  drill_result_on_abort
  exit "$status"
}
trap restore EXIT

stage "0. Preflight"
for tool in curl jq; do command -v "$tool" >/dev/null || abort "$tool is required"; done
[[ -z "$(git status --porcelain -- helm/plane/overlays/dev gitops/environments/dev)" ]] || abort "dev overlay has uncommitted changes"
[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || abort "run from main"
kc get --raw /readyz >/dev/null || abort "cluster is not reachable"
app_is "$APP" Synced Healthy || abort "$APP must start Synced and Healthy, it is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status)"
[[ "$(http_status "$HOST")" == 200 ]] || abort "$HOST does not answer 200 before the drill"
OLD_IMAGE="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')"
OLD_PODS="$(kc -n "$NS" get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[*].metadata.uid}')"
[[ -n "$OLD_PODS" ]] || abort "no web pods found"
DEADLINE="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.progressDeadlineSeconds}')"
STARTED_FROM="$(git rev-parse HEAD)"
published="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"
if [[ -n "$published" ]] && git cat-file -e "$published" 2>/dev/null; then
  git diff --quiet "$published" HEAD -- "$PROD_SIM_RENDERED" ||
    abort "main holds a change to prod-sim's manifests that Argo CD has not read, and a publish is all of main, so this drill would send it to prod-sim. Publish or withdraw it first: $(git log -n 3 --format='%h %s' "$published..HEAD" -- "$PROD_SIM_RENDERED" | tr '\n' ';')"
  git diff --quiet "$published" HEAD -- "$DEV_RENDERED" ||
    warn "main holds a change to dev's manifests that Argo CD has not read. It leaves with this drill's promotion, and stays after the revert."
fi
pass "$APP is Synced and Healthy, serving $OLD_IMAGE"

# From here, so that what was already pending or firing reads as that and not as this drill's doing.
reading_status=0
ALERTS_AT_START="$(read_alerts)" || reading_status=$?
case "$reading_status" in
  0)
    printf '# %s tests/drills/failed-deploy-rollback.sh. utc, state, alert, severity, active since, labels. Also: utc, none or no-reading, and utc, application, sync/health/operation phase.\n' "$ALERTS_FROM" >"$ALERTS_FILE"
    record_alerts </dev/null >/dev/null 2>&1 &
    RECORDER=$!
    ALERTS_RECORDING=yes
    pass "recording every pending and firing alert in $ALERTS_FILE"
    ;;
  1) abort "Prometheus does not answer at $PROM_URL, so this drill could not say what fires" ;;
  *) printf 'NOT RECORDED  what answers at %s is not its alerts API, so this run will say nothing about what fires\n' "$PROM_URL" ;;
esac

stage "1. Promote a digest that cannot be pulled"
NEEDS_RESTORE=yes
SKIP_REGISTRY_CHECK=yes "$ROOT/scripts/promote.sh" dev IMAGE=web DIGEST="$BAD_DIGEST"
BAD_COMMIT="$(git log -1 --format=%H -S"$BAD_DIGEST" -- "$DEV_OVERLAY")"
PROMOTED_AT=$SECONDS
at "promotion published"
pass "promotion committed and published as ${BAD_COMMIT:0:12}"

stage "2. Argo CD applies it"
deployment_has_bad_image() {
  local image
  image="$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')" || return 1
  [[ "$image" == *"$BAD_DIGEST"* ]]
}
refresh_hard "$APP"
if poll 300 deployment_has_bad_image; then
  at "Deployment asks for the bad digest"
  pass "Deployment now asks for the bad digest"
else
  abort "Argo CD did not apply the commit within 300s. Sync status: $(app_field "$APP" .status.operationState.message)"
fi

stage "3. The new pod cannot start"
bad_pod_is_stuck() {
  local reasons
  reasons="$(kc -n "$NS" get pods -l app.kubernetes.io/component=web \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}')" || return 1
  grep -qE '^(ErrImagePull|ImagePullBackOff)$' <<<"$reasons"
}
if poll 180 bad_pod_is_stuck; then
  at "new pod cannot pull"
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
at "stopped waiting, Application health is $(app_field "$APP" .status.health.status)"
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
ready_pods="$(kc -n "$NS" get pods -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.uid}{"\n"}{end}' || true)"
for uid in $OLD_PODS; do
  if grep -qx "$uid" <<<"$ready_pods"; then
    pass "old pod $uid is still Ready"
  else
    fail "old pod $uid is gone or not Ready"
  fi
done

stage "5. git revert restores"
"$ROOT/scripts/rollback.sh" dev
NEEDS_RESTORE=no
at "revert published"
# Not only HEAD, because other commits can land in this checkout.
if grep -qF "This reverts commit $BAD_COMMIT" <<<"$(git log --format=%B "$BAD_COMMIT..HEAD")"; then
  pass "main reverts ${BAD_COMMIT:0:12}"
else
  fail "main has no revert of the bad promotion"
fi
if grep -qF "$BAD_DIGEST" "$DEV_RENDERED"; then
  fail "rendered dev manifests still name the bad digest"
else
  pass "rendered dev manifests no longer name the bad digest"
fi

deployment_has_old_image() { [[ "$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$OLD_IMAGE" ]]; }
app_recovered() { app_is "$APP" Synced Healthy; }
refresh_hard "$APP"
if poll 300 deployment_has_old_image; then
  at "Deployment is back on the old image"
  pass "Deployment is back on $OLD_IMAGE"
else
  fail "Deployment did not return to the old image within 300s"
fi
if poll 300 app_recovered; then
  at "$APP is Synced and Healthy"
  pass "$APP is Synced and Healthy again"
else
  fail "$APP is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status) after 300s"
fi
if ! pod_images="$(kc -n "$NS" get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}')"; then
  fail "could not read the pods in $NS, so nothing shows the bad digest is gone"
elif grep -qF "$BAD_DIGEST" <<<"$pod_images"; then
  fail "a pod still references the bad digest"
else
  pass "no pod references the bad digest"
fi
status="$(http_status "$HOST")"
if [[ "$status" == 200 ]]; then pass "$HOST answers 200"; else fail "$HOST answers $status"; fi
if [[ -z "$(git diff --name-only "$STARTED_FROM" HEAD -- "$PROD_SIM_RENDERED")" ]]; then
  pass "prod-sim's manifests did not move"
else
  fail "prod-sim's manifests moved during this drill. Look at: $(git log -n 3 --format='%h %s' "$STARTED_FROM..HEAD" -- "$PROD_SIM_RENDERED" | tr '\n' ';')"
fi

stage "6. What fired, as Prometheus itself reported it"
if [[ "$ALERTS_RECORDING" == yes ]]; then
  if poll "$ALERTS_SETTLE" nothing_new_is_active; then
    at "nothing is pending or firing that was not at the start"
    # A resolved notice waits for the group's next interval, 30s, before it reaches the sink.
    sleep 45
  else
    at "still pending or firing after ${ALERTS_SETTLE}s, beyond what was there at the start"
  fi
fi
alerts_report

drill_finish
