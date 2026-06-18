#!/usr/bin/env bash
# Failure drill: a backend image whose migrator exits 1 reaches dev through the real promotion path. The
# migrator is the wave 2 Sync hook, so the sync has to stop there: the wave 3 Deployments keep their
# generation, image and pods, and the old pods keep serving. A git revert then restores the environment.
#
#   tests/drills/failed-migrator.sh
#
# Runs only against dev, and always through Git, like failed-deploy-rollback.sh: it adds two commits to main,
# the promotion and its revert. Self-heal stays on, because the bad state is what Git asks for here, and a run
# alone is what this needs, because rollback.sh reverts the newest promotion of dev.
#
# The image is FROM the backend dev runs now with one file replaced, in a repository named throwaway. COPY --link
# and store=false keep it to one small layer and nothing in Docker's image list. Whatever way this ends, the exit
# trap deletes its manifest, which takes the tag with it, and its copy on the node. An empty repository stays in the
# registry's catalog, because the registry has no way to remove one, and its one small blob stays until a garbage collect.
#
# HOLD_SECONDS, 300 by default, is how long the failure stays up once Argo CD reports it, so that alerts with a short
# for: can show. The rules with a for: of 15m cannot fire inside it, so this answers what fires in that time and nothing longer.
#
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

guard_disk 2
cd "$ROOT"

APP=plane-dev
NS=plane-dev
HOST=plane.dev.localhost
JOB=plane-api-migrate-1
DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml
DEV_RENDERED=gitops/environments/dev/manifests.yaml
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
BARE="$LOCAL_DIR/git/plane-platform.git"
THROWAWAY_REPO=localhost:5001/throwaway/backend-failing-migrator
THROWAWAY_TAG=dep3
HOLD_SECONDS="${HOLD_SECONDS:-300}"
PROM_URL="${PROM_URL:-http://prometheus.localhost}"
ALERTS_EVERY="${ALERTS_EVERY:-15}"

drill_start failed-migrator
NEEDS_RESTORE=no
BAD_DIGEST=""
BUILD_DIR=""
RECORDER=""
PROMOTED_AT=""
ALERTS_FROM="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ALERTS_FILE="${DRILL_EVIDENCE%.log}-alerts.tsv"

at() { # A time to read the alerts against
  printf 'AT    %s%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROMOTED_AT:+ +$((SECONDS - PROMOTED_AT))s}" "$*"
}

# What must not move, one line each: a Deployment's generation and image, and each pod of a Deployment.
workload_state() {
  kc -n "$NS" get deployments -o json | jq -r '.items[] | select(.metadata.name | startswith("plane-"))
    | ["deployment", .metadata.name, .metadata.generation, .spec.template.spec.containers[0].image] | @tsv'
  kc -n "$NS" get pods -o json | jq -r '.items[] | select(.metadata.ownerReferences[0].kind == "ReplicaSet" and (.metadata.name | startswith("plane-")))
    | ["pod", .metadata.name, .metadata.uid] | @tsv' | LC_ALL=C sort
}

job_field() { kc -n "$NS" get job "$JOB" -o jsonpath="{$1}" 2>/dev/null || true; }

# ---- What fires. Same form as failed-deploy-rollback.sh, so the two runs read alike.

read_alerts() {
  local answer
  answer="$(curl -fsS -m 10 "$PROM_URL/api/v1/alerts" 2>/dev/null)" || return 1
  jq -r '.data.alerts[] | [.state, .labels.alertname, (.labels.severity // "-"), .activeAt,
    (.labels | del(.alertname, .severity) | to_entries | map("\(.key)=\(.value)") | join(","))] | @tsv' <<<"$answer" 2>/dev/null || return 2
}

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

alerts_report() {
  local logs received
  stop_recording
  [[ -s "$ALERTS_FILE" ]] || { printf 'NOT RECORDED  no alert was read during this run\n'; return 0; }
  printf 'Prometheus %s/api/v1/alerts, every %ss since %s. Raw: %s\n' "$PROM_URL" "$ALERTS_EVERY" "$ALERTS_FROM" "$ALERTS_FILE"
  awk -F'\t' '$2 == "no-reading" { print "GAP   " $1 }' "$ALERTS_FILE"
  awk -F'\t' '
    $2 == "application" || $2 == "none" || $2 == "no-reading" { next }
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

remove_image() {
  local status
  [[ -n "$BAD_DIGEST" ]] || return 0
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE "http://localhost:5001/v2/${THROWAWAY_REPO#localhost:5001/}/manifests/$BAD_DIGEST" || true)"
  printf 'registry DELETE of the throwaway manifest: HTTP %s\n' "$status"
  printf 'tags left in %s: %s\n' "$THROWAWAY_REPO" "$(curl -s --max-time 10 "http://localhost:5001/v2/${THROWAWAY_REPO#localhost:5001/}/tags/list" || true)"
  docker exec "$NODE_CONTAINER" crictl rmi "$THROWAWAY_REPO@$BAD_DIGEST" >/dev/null 2>&1 || true
  if docker exec "$NODE_CONTAINER" crictl images --digests 2>/dev/null | grep -qF "${BAD_DIGEST#sha256:}"; then
    fail "the throwaway image is still on the node"
  else
    pass "the throwaway image is not on the node"
  fi
  BAD_DIGEST=""
}

bad_digest_in_git() {
  [[ -n "$BAD_DIGEST" ]] || return 1
  git grep -qF "$BAD_DIGEST" HEAD -- "$DEV_OVERLAY" ||
    git --git-dir="$BARE" grep -qF "$BAD_DIGEST" refs/heads/main -- "$DEV_OVERLAY" 2>/dev/null
}

restore() {
  local status=$?
  if [[ "$NEEDS_RESTORE" == yes ]] && bad_digest_in_git; then
    stage "Restore (exit trap)"
    if "$ROOT/scripts/rollback.sh" dev; then
      refresh_app "$APP" || true
      pass "the promotion was reverted by the trap. This did not wait for $APP to recover"
    else
      fail "automatic restore failed. Run scripts/rollback.sh dev and check Application $APP"
      status=1
    fi
  fi
  stop_recording
  remove_image || true
  if [[ -n "$BUILD_DIR" ]]; then rm -rf "$BUILD_DIR"; fi
  drill_result_on_abort
  exit "$status"
}
trap restore EXIT

stage "0. Preflight"
for tool in curl jq docker; do command -v "$tool" >/dev/null || abort "$tool is required"; done
[[ -z "$(git status --porcelain -- helm/plane/overlays/dev gitops/environments/dev)" ]] || abort "dev overlay has uncommitted changes"
[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || abort "run from main"
kc get --raw /readyz >/dev/null || abort "cluster is not reachable"
app_is "$APP" Synced Healthy || abort "$APP must start Synced and Healthy, it is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status)"
[[ "$(http_status "$HOST")" == 200 ]] || abort "$HOST does not answer 200 before the drill"
STARTED_FROM="$(git rev-parse HEAD)"
published="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"
if [[ -n "$published" ]] && git cat-file -e "$published" 2>/dev/null; then
  git diff --quiet "$published" HEAD -- "$PROD_SIM_RENDERED" ||
    abort "main holds a change to prod-sim's manifests that Argo CD has not read, and a publish is all of main, so this drill would send it to prod-sim. Publish or withdraw it first."
fi
BASE_IMAGE="$(kc -n "$NS" get deployment plane-api-wl -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$BASE_IMAGE" == localhost:5001/*@sha256:* ]] || abort "the api does not run a digest from the local registry: $BASE_IMAGE"
OLD_JOB_IMAGE="$(job_field '.spec.template.spec.containers[0].image')"
BEFORE="$(workload_state)"
[[ -n "$BEFORE" ]] || abort "could not read the Deployments"
pass "$APP is Synced and Healthy, its backend is $BASE_IMAGE"
printf '%s\n' "$BEFORE" | sed 's/^/BEFORE  /'
printf '# %s tests/drills/failed-migrator.sh. utc, state, alert, severity, active since, labels. Also: utc, none or no-reading, and utc, application, sync/health/operation phase.\n' "$ALERTS_FROM" >"$ALERTS_FILE"
record_alerts </dev/null >/dev/null 2>&1 &
RECORDER=$!

stage "1. Build a backend whose migrator exits 1"
BUILD_DIR="$(mktemp -d)"
cat >"$BUILD_DIR/docker-entrypoint-migrator.sh" <<'EOF'
#!/bin/sh
echo "tests/drills/failed-migrator.sh: this migrator exits 1 on purpose, and changed nothing" >&2
exit 1
EOF
cat >"$BUILD_DIR/Dockerfile" <<EOF
FROM $BASE_IMAGE
COPY --link --chmod=755 docker-entrypoint-migrator.sh /code/bin/docker-entrypoint-migrator.sh
EOF
# shellcheck disable=SC2054  # the commas are the exporter's options
docker buildx build --quiet --platform linux/arm64 --provenance=false --sbom=false \
  --metadata-file "$BUILD_DIR/metadata.json" --output type=image,push=true,store=false \
  -t "$THROWAWAY_REPO:$THROWAWAY_TAG" "$BUILD_DIR"
BAD_DIGEST="$(jq -r '."containerimage.digest" // ""' "$BUILD_DIR/metadata.json")"
[[ "$BAD_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || abort "no digest recorded for the throwaway image"
docker buildx imagetools inspect "$THROWAWAY_REPO@$BAD_DIGEST" >/dev/null || abort "the registry does not serve $BAD_DIGEST"
pass "pushed $THROWAWAY_REPO:$THROWAWAY_TAG, $BAD_DIGEST"

stage "2. Promote it through the real path"
NEEDS_RESTORE=yes
"$ROOT/scripts/promote.sh" dev IMAGE=backend DIGEST="$BAD_DIGEST" REPO="$THROWAWAY_REPO"
BAD_COMMIT="$(git log -1 --format=%H -S"$BAD_DIGEST" -- "$DEV_OVERLAY")"
PROMOTED_AT=$SECONDS
at "promotion published"
pass "promotion committed and published as ${BAD_COMMIT:0:12}"

stage "3. Argo CD runs the hook with the bad image"
job_has_bad_image() { [[ "$(job_field '.spec.template.spec.containers[0].image')" == *"$BAD_DIGEST"* ]]; }
refresh_app "$APP"
if poll 300 job_has_bad_image; then
  at "the migrator Job names the bad digest"
  pass "the migrator Job runs the bad digest"
else
  abort "Argo CD did not create the Job within 300s. Sync status: $(app_field "$APP" .status.operationState.message)"
fi

stage "4. The hook fails, and nothing in wave 3 moves"
samples=0
bad_samples=0
moved=0
job_failed_seen=""
report_seen=""
log_seen=""
compare_state() {
  local now
  now="$(workload_state)"
  if [[ -n "$now" && "$now" != "$BEFORE" ]]; then
    moved=$((moved + 1))
    if [[ "$moved" -eq 1 ]]; then
      printf 'MOVED %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$now") | sed 's/^/MOVED /' || true
    fi
  fi
}
app_reports_failure() {
  local phase message
  phase="$(app_field "$APP" .status.operationState.phase)"
  message="$(app_field "$APP" .status.operationState.message)"
  [[ "$phase" == Failed || "$phase" == Error || "$message" == *"Retrying attempt"* || "$message" == *unsuccessfully* ]]
}
# Up to the Job's own limit and a retry, then HOLD_SECONDS more.
deadline=$((SECONDS + 600))
while [[ $SECONDS -lt $deadline ]]; do
  samples=$((samples + 1))
  [[ "$(http_status "$HOST")" == 200 ]] || bad_samples=$((bad_samples + 1))
  compare_state
  if [[ -z "$log_seen" ]]; then
    migrator_log="$(kc -n "$NS" logs "job/$JOB" --tail=3 2>/dev/null || true)"
    if [[ -n "$migrator_log" ]]; then
      log_seen=yes
      printf '%s\n' "$migrator_log" | sed 's/^/MIGRATOR LOG  /'
    fi
  fi
  if [[ -z "$job_failed_seen" && "$(job_field '.status.conditions[?(@.type=="Failed")].status')" == True ]]; then
    job_failed_seen=yes
    at "the Job failed: $(job_field '.status.conditions[?(@.type=="Failed")].reason'), $(job_field '.status.conditions[?(@.type=="Failed")].message')"
  fi
  if [[ -z "$report_seen" ]] && app_reports_failure; then
    report_seen=yes
    at "the Application reports it: $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status)/$(app_field "$APP" .status.operationState.phase): $(app_field "$APP" .status.operationState.message)"
    deadline=$((SECONDS + HOLD_SECONDS))
  fi
  sleep 5
done
at "stopped holding: $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status)/$(app_field "$APP" .status.operationState.phase): $(app_field "$APP" .status.operationState.message)"
kc -n "$NS" get job "$JOB" -o json | jq -c '{status: (.status | {active, failed, succeeded, conditions: [.conditions[]? | {type, reason}]}), image: .spec.template.spec.containers[0].image}' || true
if [[ -n "$job_failed_seen" ]]; then pass "the migrator Job failed"; else fail "the migrator Job did not read Failed"; fi
if [[ -n "$report_seen" ]]; then pass "the Application reports the failure"; else fail "the Application did not report a failure within 600s"; fi
if [[ "$moved" -eq 0 ]]; then
  pass "wave 3 did not move: Deployment generations, images and pods equal the start on all $samples samples"
else
  fail "wave 3 moved on $moved of $samples samples"
fi
if [[ "$bad_samples" -eq 0 ]]; then
  pass "$HOST answered 200 on all $samples samples"
else
  fail "$HOST failed $bad_samples of $samples samples"
fi

stage "5. git revert restores"
"$ROOT/scripts/rollback.sh" dev
NEEDS_RESTORE=no
at "revert published"
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
app_recovered() { app_is "$APP" Synced Healthy && [[ -z "$(app_field "$APP" .operation)" ]]; }
refresh_app "$APP"
if poll 600 app_recovered; then
  at "$APP is Synced and Healthy with no operation open"
  pass "$APP is Synced and Healthy again"
else
  fail "$APP is $(app_field "$APP" .status.sync.status)/$(app_field "$APP" .status.health.status) after 600s: $(app_field "$APP" .status.operationState.message)"
fi
job_image="$(job_field '.spec.template.spec.containers[0].image')"
if [[ "$job_image" == "$OLD_JOB_IMAGE" && "$(job_field '.status.succeeded')" == 1 ]]; then
  pass "the migrator Job ran again on the old image and succeeded"
else
  fail "the migrator Job reads image $job_image, succeeded '$(job_field '.status.succeeded')'"
fi
AFTER="$(workload_state)"
if [[ "$AFTER" == "$BEFORE" ]]; then
  pass "the failure and the recovery changed no Deployment and replaced no pod"
else
  fail "the state changed between the start and the end"
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed 's/^/MOVED /' || true
fi
status="$(http_status "$HOST")"
if [[ "$status" == 200 ]]; then pass "$HOST answers 200"; else fail "$HOST answers $status"; fi
if [[ -z "$(git diff --name-only "$STARTED_FROM" HEAD -- "$PROD_SIM_RENDERED")" ]]; then
  pass "prod-sim's manifests did not move"
else
  fail "prod-sim's manifests moved during this drill. Look at: $(git log -n 3 --format='%h %s' "$STARTED_FROM..HEAD" -- "$PROD_SIM_RENDERED" | tr '\n' ';')"
fi

stage "6. What fired, as Prometheus itself reported it"
# A resolved notice waits for its group's next interval, 30s, and the rules hold for up to 2m after the last open sample.
sleep 180
alerts_report

stage "7. Remove the throwaway image"
remove_image

drill_finish
