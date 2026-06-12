#!/usr/bin/env bash
# Helpers shared by scripts/backup.sh, scripts/restore.sh and scripts/test-alert.sh. Source it after
# scripts/lib/common.sh. Bash 3.2, because macOS ships it: no associative arrays and no mapfile.
# shellcheck shell=bash

# Pinned here so backup and restore cannot drift apart. Postgres is read from the live server
# instead, because pg_dump refuses a server newer than itself and restore must follow it.
export RCLONE_IMAGE="docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5"
# Not a secret: it proves the database and SECRET_KEY still match, because decrypt_data fails
# silently to an empty string on a wrong key. A row of our own, so no Plane feature changes state.
export ENCRYPTED_SENTINEL_KEY="WAYLINE_RESTORE_SENTINEL"
export ENCRYPTED_SENTINEL_VALUE="wayline-restore-sentinel-v1"

# Sets ENV_NAME, NS, APP and, for a Plane environment, PLANE_HOST.
select_env() {
  case "$1" in
    dev | plane-dev) ENV_NAME=dev NS=plane-dev APP=plane-dev PLANE_HOST=plane.dev.localhost ;;
    prod-sim | plane-prod-sim) ENV_NAME=prod-sim NS=plane-prod-sim APP=plane-prod-sim PLANE_HOST=plane.prod-sim.localhost ;;
    infisical) ENV_NAME=infisical NS=infisical APP=infisical PLANE_HOST="" ;;
    *) die "unknown environment '$1': expected dev, prod-sim or infisical" ;;
  esac
  export ENV_NAME NS APP PLANE_HOST
}

# The Make targets pass positional values, and the task interface also allows KEY=VALUE arguments.
# Prints nothing and exports only the names the caller allows.
accept_assignments() { # "ENV BACKUP ...", then the script's arguments
  local allowed="$1" arg key
  shift
  for arg in "$@"; do
    case "$arg" in
      *=*)
        key="${arg%%=*}"
        case " $allowed " in
          *" $key "*) export "${arg?}" ;;
          *) die "unsupported argument: $key" ;;
        esac
        ;;
    esac
  done
}

need_cluster() {
  kc get --raw /readyz >/dev/null 2>&1 || die "cluster is not reachable. Run 'make up' first."
}

# Replaces __KEY__ on stdin for each KEY=VALUE. Fails if a token stays unfilled, so a typo cannot
# reach the API as a literal image name or namespace.
fill() {
  local args=() kv out
  for kv in "$@"; do args+=(-e "s|__${kv%%=*}__|${kv#*=}|g"); done
  out="$(sed "${args[@]}")"
  if grep -E '__[A-Z_]+__' <<<"$out" >/dev/null; then
    die "unfilled template token: $(grep -Eo '__[A-Z_]+__' <<<"$out" | sort -u | tr '\n' ' ')"
  fi
  printf '%s\n' "$out"
}

JOB_STATE_JQ='
    (.status.conditions // []) as $c
    | if any($c[]; .type == "Complete" and .status == "True") then "ok"
      elif any($c[]; .type == "Failed" and .status == "True") then "failed"
      else "running" end'

job_state() { # namespace job. Prints ok, failed or running.
  kc -n "$1" get job "$2" -o json | jq -r "$JOB_STATE_JQ"
}

# For a Job that may never have been created: prints nothing if it is not there. Non-zero only if kubectl could
# not say, which is not the same as no such Job.
job_state_if_any() { # namespace job
  kc -n "$1" get job "$2" --ignore-not-found -o json | jq -r "$JOB_STATE_JQ"
}

# run_job <namespace> <job> <timeout-seconds>, with the manifest on stdin. A Job and not kubectl
# exec: it survives a dropped client stream, has limits and a NetworkPolicy label, and binary data
# never crosses the API stream, where one stray -t would corrupt a dump. Prints the Job's logs on
# both outcomes, then returns non-zero on failure.
run_job() {
  local ns="$1" job="$2" timeout="$3" deadline state
  kc apply -f - >/dev/null
  deadline=$((SECONDS + timeout))
  while :; do
    state="$(job_state "$ns" "$job")"
    [[ "$state" == running ]] || break
    if [[ $SECONDS -ge $deadline ]]; then
      warn "job $ns/$job still running after ${timeout}s"
      state=failed
      break
    fi
    sleep 3
  done
  kc -n "$ns" logs "job/$job" --all-containers --prefix --tail=-1 2>/dev/null || true
  if [[ "$state" != ok ]]; then
    kc -n "$ns" get pods -l "job-name=$job" -o wide 2>/dev/null || true
    return 1
  fi
}

# ------ Argo CD auto-sync ----------------------------------------------------------------------
# Self-heal reverts a scale in about 5 seconds, so drills and restores must pause it. argo_pause pauses
# root first and resumes it last. Each app's automated block is saved and put back, without `enabled`,
# so a run that died paused cannot make the pause permanent.
ARGO_ROOT_APP="root"
ARGO_PAUSED_APPS=()
ARGO_PAUSED_SPECS=()
ARGO_TERMINATED_APPS=()

argo_pause_app() {
  local app="$1" spec
  spec="$(kc -n argocd get application "$app" -o json | jq -c '.spec.syncPolicy.automated // empty | del(.enabled)')"
  [[ -n "$spec" ]] || die "Application $app has no automated sync policy, so there is nothing to pause"
  kc -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}' >/dev/null
  ARGO_PAUSED_APPS+=("$app")
  ARGO_PAUSED_SPECS+=("$spec")
}

# A sync already in flight would finish and undo an injection, whatever the policy says now, so wait
# for it. A failing sync never finishes: with retry.limit -1 the controller sets each failed attempt
# back to Running (appcontroller.go:1693-1702 at Argo CD v3.5.7), and disabling automated does not stop
# an operation already recorded. So after 180s, terminate it. The controller then deletes any running
# hook and ends the operation as Failed, with no retry. The patch reaches status because this CRD has
# no status subresource. It repeats because the controller can overwrite it when finishing an attempt.
argo_wait_idle() {
  local app="$1" terminate_at=$((SECONDS + 180)) give_up_at=$((SECONDS + 300)) terminated=no phase
  while :; do
    phase="$(kc -n argocd get application "$app" -o json | jq -r '.status.operationState.phase // "none"')"
    [[ "$phase" == Running || "$phase" == Terminating ]] || return 0
    [[ $SECONDS -lt $give_up_at ]] || die "Application $app is still $phase after 300s, and terminating its sync did not end it"
    if [[ $SECONDS -ge $terminate_at && "$phase" == Running ]]; then
      if [[ "$terminated" == no ]]; then
        warn "Application $app has had a sync running for 180s, so terminating it"
        ARGO_TERMINATED_APPS+=("$app")
        terminated=yes
      fi
      kc -n argocd patch application "$app" --type merge \
        -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null
    fi
    sleep 3
  done
}

# One Application, leaving root alone. For a caller that cannot wait for root: during a clean restore
# root's sync stays Running until plane-dev has its identity Secret, which the restore itself leads to,
# and terminating it would stop Argo CD retrying that revision. Root does not undo this pause. Measured:
# root stayed Synced through a hard refresh with a child paused, and `kubectl apply` of the child's
# manifest, which is what root's retries do, keeps `enabled: false` (evidence-raw/dr-child-pause-1.txt).
argo_pause_child() { # app
  log "Pausing auto-sync: $1"
  argo_pause_app "$1"
  argo_wait_idle "$1"
  # Catch anything still reverting the patch before the caller trusts it.
  sleep 5
  [[ "$(kc -n argocd get application "$1" -o json | jq -r '.spec.syncPolicy.automated.enabled')" == false ]] \
    || die "auto-sync on $1 was switched back on by something else"
}

argo_pause() { # app
  log "Pausing auto-sync: $ARGO_ROOT_APP"
  argo_pause_app "$ARGO_ROOT_APP"
  argo_wait_idle "$ARGO_ROOT_APP"
  argo_pause_child "$1"
}

# Safe to call twice, and never fails the script: it runs from traps, and a second error there
# would hide the first. If a patch cannot be put back it says exactly what to run by hand.
argo_resume() {
  local i app spec
  i=$((${#ARGO_PAUSED_APPS[@]} - 1))
  while [[ $i -ge 0 ]]; do
    app="${ARGO_PAUSED_APPS[$i]}"
    spec="${ARGO_PAUSED_SPECS[$i]}"
    if kc -n argocd patch application "$app" --type json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/syncPolicy/automated\",\"value\":$spec}]" >/dev/null; then
      ok "auto-sync restored on $app"
    else
      warn "COULD NOT RESTORE auto-sync on $app. Run: kubectl -n argocd patch application $app --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/syncPolicy/automated\",\"value\":$spec}]'"
    fi
    i=$((i - 1))
  done
  ARGO_PAUSED_APPS=()
  ARGO_PAUSED_SPECS=()
  # Automated sync does not retry a revision whose last attempt failed (autoSync, "will not retry"),
  # and self-heal does not run after a failed attempt either. So auto-sync being back is not enough.
  i=$((${#ARGO_TERMINATED_APPS[@]} - 1))
  while [[ $i -ge 0 ]]; do
    warn "The sync of ${ARGO_TERMINATED_APPS[$i]} was terminated, and Argo CD will not retry that revision by itself. The next commit starts a new sync: make rollback, or commit and make gitops-publish."
    i=$((i - 1))
  done
  ARGO_TERMINATED_APPS=()
}

# For a caller that has to leave auto-sync paused: what to run later, root last, in the same shape as argo_resume.
argo_print_resume_steps() {
  local i
  i=$((${#ARGO_PAUSED_APPS[@]} - 1))
  while [[ $i -ge 0 ]]; do
    printf "    kubectl -n argocd patch application %s --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/syncPolicy/automated\",\"value\":%s}]'\n" "${ARGO_PAUSED_APPS[$i]}" "${ARGO_PAUSED_SPECS[$i]}" >&2
    i=$((i - 1))
  done
}

# For a run that follows a hard stop. SIGKILL or a power cut runs no trap, so an automated block can still hold
# enabled:false, and only this run knows to look. Puts back every one it finds, root last, in the same shape as
# argo_resume: the block without `enabled`. Prints each name. Never fails the script.
argo_unpause_all() {
  local json name spec
  json="$(kc -n argocd get applications -o json 2>/dev/null)" || return 0
  for name in $(jq -r --arg root "$ARGO_ROOT_APP" '
      [.items[] | select(.spec.syncPolicy.automated.enabled == false) | .metadata.name]
      | map(select(. != $root)) + map(select(. == $root)) | .[]' <<<"$json"); do
    spec="$(jq -c --arg n "$name" '.items[] | select(.metadata.name == $n) | .spec.syncPolicy.automated | del(.enabled)' <<<"$json")"
    if kc -n argocd patch application "$name" --type json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/syncPolicy/automated\",\"value\":$spec}]" >/dev/null; then
      printf '%s\n' "$name"
    else
      warn "COULD NOT RESTORE auto-sync on $name. Run: kubectl -n argocd patch application $name --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/syncPolicy/automated\",\"value\":$spec}]'"
    fi
  done
}

# ------ Plane shell -----------------------------------------------------------------------------
# Runs Python in the API pod and returns only the lines this code marks, because Django logging
# shares stdout. The code is passed as an argument, so it must never carry a secret.
plane_python() { # code. Marked lines start with @@.
  kc -n "$NS" exec deploy/plane-api-wl -c plane-api -- python manage.py shell -c "$1" 2>/dev/null \
    | sed -n 's/^@@//p'
}

# ------ Prometheus and Alertmanager -------------------------------------------------------------
# Through Traefik, the same way a person reaches them, so no port-forward has to be managed.
export PROM_URL="http://prometheus.localhost"
export AM_URL="http://alertmanager.localhost"

prom_query() { # promql. Prints the raw JSON.
  curl -fsS -m 10 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1"
}
