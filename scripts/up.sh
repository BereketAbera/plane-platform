#!/usr/bin/env bash
# Create the whole platform, or resume it after make down. Every step is idempotent, so running this
# again is also how to continue after any failure.
#
#   scripts/up.sh
#   UP_STOP_AFTER=<step> scripts/up.sh     stop after one step, for staged debugging
#
# Steps, in order:
#   cluster      kind, local services, kubeconfig
#   publish      check the local image digests, then push main to the bare repo Argo CD reads
#   terraform    namespaces, quotas, CoreDNS rewrite, Argo CD, projects, root Application
#   secret-zero  the secrets Infisical needs before it can start
#   traefik      wait for Traefik, then make a real request through it
#   infisical    wait for Infisical, then first admin, projects, identities, seeded values
# With no UP_STOP_AFTER it goes on to wait for every Application, then prints scripts/status.sh.
#
# Argo CD reads only commits, so this refuses uncommitted changes under the paths Argo CD reads.
#
# Never wait on the root Application alone, and never wait on all Applications before the infisical
# step. Root's operation succeeds right after applying wave 0, without waiting for plane-prod-sim
# (sync_context.go:704 at Argo CD v3.5.7), and plane-dev stays Degraded until the infisical step
# publishes its identity Secret.
#
# UP_WAIT_TRAEFIK_SECONDS, UP_WAIT_ROUTE_SECONDS, UP_WAIT_INFISICAL_SECONDS and UP_WAIT_APPS_SECONDS
# override the waits, for a slow first image pull. Nothing here prints a secret: credentials stay
# in .local/secret-zero and .local/test-accounts.env.
# ALLOW_LOW_DISK="<reason>" goes past the check for a new cluster, and the reason is logged in
# .local/evidence-raw/low-disk-overrides.log. It does not go past the 10 GiB floor every script checks.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/up-checks.sh
source "$(dirname "$0")/lib/up-checks.sh"

STOP_AFTER="${UP_STOP_AFTER:-}"
case "$STOP_AFTER" in
  "" | cluster | publish | terraform | secret-zero | traefik | infisical) ;;
  *) die "UP_STOP_AFTER='$STOP_AFTER' is not a step. Use one of: cluster publish terraform secret-zero traefik infisical" ;;
esac

TF_DIR="$ROOT/infrastructure/terraform/environments/local"
LOCAL_REGISTRY_PREFIX=localhost:5001/wayline
# Root's own Application, plus one for each manifest root syncs from gitops/applications.
EXPECTED_APPS=$(($(cat "$ROOT"/gitops/applications/*.yaml | grep -c '^kind: Application$') + 1))

# ------ Refusals, before anything is touched ----------------------------------------------------

for tool in docker git curl jq kind kubectl terraform yq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Run: make setup"
done
docker info >/dev/null 2>&1 || die "Docker is not running"
low_disk_check_value

# With changes under the paths Argo CD reads, it would deploy something other than this working tree, and
# nothing would say so. Stopping after the cluster step publishes nothing, so a dirty tree cannot mislead
# that run. scripts/restore.sh and the clean-restore drill ask the same before they delete anything.
refuse_uncommitted() {
  local dirty line
  dirty="$(up_uncommitted)"
  [[ -n "$dirty" ]] || return 0
  while IFS= read -r line; do printf '    %s\n' "$line" >&2; done <<<"$dirty"
  die "uncommitted changes above, under paths Argo CD reads. It reads only commits, so it would never see them. Commit or stash them, then run this again."
}
if [[ "$STOP_AFTER" != cluster ]]; then refuse_uncommitted; fi

# Resuming grows nothing, so only a new cluster is asked for this. scripts/lib/up-checks.sh says why 25 GiB.
if ! cluster_exists; then
  guard_new_cluster "$UP_NEW_CLUSTER_GIB" up.sh
  up_move_stale_local_state
fi
guard_disk

# ------ Helpers ---------------------------------------------------------------------------------

STEP_STARTED=$SECONDS
step() { # step <what is about to happen>
  STEP_STARTED=$SECONDS
  log "$*"
}

step_done() { # step_done <step name>
  ok "$1 step finished in $((SECONDS - STEP_STARTED))s"
  if [[ "$STOP_AFTER" == "$1" ]]; then
    ok "Stopped after $1, as UP_STOP_AFTER asked. Run 'make up' to go on: finished steps are safe to repeat."
    exit 0
  fi
}

app_ok() { # app_ok <application>: Synced and Healthy
  [[ "$(kc -n argocd get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}')" == Synced/Healthy ]]
}

# All of them exist and none differs. An annotation still in place means the controller has not yet
# compared that Application since up.sh asked, so its status may describe an older commit.
all_apps_ok() {
  local json
  json="$(kc -n argocd get applications -o json)" || return 1
  jq -e --argjson want "$EXPECTED_APPS" '
    (.items | length) == $want and all(.items[];
      .status.sync.status == "Synced" and .status.health.status == "Healthy"
      and ((.metadata.annotations // {}) | has("argocd.argoproj.io/refresh") | not))' \
    <<<"$json" >/dev/null
}

apps_summary() { # Prints one line: how many exist, and each one not yet Synced and Healthy.
  local json
  json="$(kc -n argocd get applications -o json 2>/dev/null)" || { echo "Argo CD is not answering"; return 0; }
  jq -r --argjson want "$EXPECTED_APPS" '
    [.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
      | "\(.metadata.name)=\(.status.sync.status // "?")/\(.status.health.status // "?")"] as $waiting
    | "\(.items | length) of \($want) exist, waiting on: \(if ($waiting | length) == 0 then "none" else ($waiting | join(" ")) end)"' \
    <<<"$json"
}

# wait_for from common.sh, plus a line each minute and the failing Applications at the end. These
# waits can last most of an hour, so a stuck child should be visible while it is stuck.
wait_until() { # wait_until <seconds> <what> <what to check on timeout> <command...>
  local timeout="$1" what="$2" hint="$3" started=$SECONDS reported=$SECONDS
  shift 3
  log "Waiting for $what (up to ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    if [[ $((SECONDS - started)) -ge $timeout ]]; then
      warn "Applications: $(apps_summary)"
      die "timed out after ${timeout}s waiting for $what. $hint"
    fi
    if [[ $((SECONDS - reported)) -ge 60 ]]; then
      reported=$SECONDS
      printf '    %ss. Applications: %s\n' "$((SECONDS - started))" "$(apps_summary)"
    fi
    sleep 3
  done
  ok "$what, after $((SECONDS - started))s"
}

# Since promotion the overlays name digests only the local registry holds, and no backup does. So a new
# machine, or make destroy PURGE=yes, reaches this. See "What a clean restore cannot bring back" in
# infisical/README.md.
ensure_local_images() {
  local missing
  missing="$(up_missing_local_images)"
  [[ -n "$missing" ]] || return 0
  warn "The local registry cannot serve these images, which the overlays reference:"
  printf '%s\n' "$missing" >&2
  log "Rebuilding the images, in case the build reproduces those digests"
  "$ROOT/scripts/ci/build-images.sh" "$LOCAL_REGISTRY_PREFIX"
  missing="$(up_missing_local_images)"
  if [[ -z "$missing" ]]; then
    ok "the local registry now serves every referenced image"
    return 0
  fi
  cat >&2 <<MSG
These digests are still missing, because the rebuild produced different ones:
$missing
Nothing was published. Either promote what was just built (.build/digests.tsv), which commits the new
digests to main. The second line is only needed if prod-sim references them, and takes SKIP_BACKUP=yes
if prod-sim holds no data yet:
    make promote ENV=dev
    make promote ENV=prod-sim CONFIRM=yes
    make up
Or keep the exact digests, by copying them from the registry that has them:
    scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev
    scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline prod-sim
    make up
If make restore-clean brought you here, run that again instead of the last make up. Neither way touches data.
MSG
  exit 1
}

# ------ Steps -----------------------------------------------------------------------------------

step "Cluster: kind, local services, kubeconfig"
"$ROOT/scripts/cluster-up.sh"
step_done cluster

# Before Terraform, so root's first compare already has a repo to read.
step "Publish: local image digests, then main to the bare repo Argo CD reads"
ensure_local_images
"$ROOT/scripts/gitops-publish.sh"
step_done publish

step "Terraform: namespaces, quotas, CoreDNS, Argo CD, projects, root Application"
TF_IN_AUTOMATION=1 terraform -chdir="$TF_DIR" init -input=false -lockfile=readonly
TF_IN_AUTOMATION=1 terraform -chdir="$TF_DIR" apply -input=false -auto-approve -lock-timeout=10m
step_done terraform

# Needs the namespaces. Infisical waits for these at wave -4.
step "Secret zero"
"$ROOT/scripts/secret-zero.sh"
step_done secret-zero

# Fails fast on NodePort plus NetworkPolicy, the first thing every UI and the bootstrap depend on.
# Without this the next step would wait a long time and name the wrong cause.
step "Traefik: the Application, then a real request through it"
wait_until "${UP_WAIT_TRAEFIK_SECONDS:-900}" "Application traefik Synced and Healthy" \
  "Check: kubectl -n argocd describe application traefik; kubectl -n traefik get pods" \
  app_ok traefik
wait_until "${UP_WAIT_ROUTE_SECONDS:-300}" "Traefik answering at http://argocd.localhost/" \
  "If curl times out, the NodePort source may be outside policy traefik-ingress, in gitops/platform/network-policies/traefik.yaml. If it answers 404, check the route in gitops/bootstrap/argocd-route." \
  curl -fsS -o /dev/null --max-time 5 http://argocd.localhost/
step_done traefik

# The monitoring waves and about 600 Infisical migrations come first, so this can be the longest wait
# of a first boot. A failure in a monitoring wave holds Infisical back, and the progress lines show it.
step "Infisical: wait for it, then first admin, projects, identities, seeded values"
wait_until "${UP_WAIT_INFISICAL_SECONDS:-2400}" "Infisical answering at http://infisical.localhost/api/status" \
  "Check: kubectl -n argocd describe application infisical; kubectl -n infisical get pods" \
  curl -fsS -o /dev/null --max-time 5 http://infisical.localhost/api/status
"$ROOT/scripts/infisical-bootstrap.sh"
step_done infisical

# A publish reaches Argo CD only at its next poll, so Synced can describe the commit before this
# one, and after make down it can describe the time before the stop. The controller takes this
# annotation off once it has compared, which all_apps_ok waits for. Normal and not hard: a hard
# refresh would re-render every chart at once on the repo server.
step "Applications: all $EXPECTED_APPS Synced and Healthy"
kc -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite >/dev/null ||
  warn "could not ask Argo CD to refresh, so the wait below may read a status from before this run"
log "A child in backoff after the Infisical step can take up to 5 minutes to retry. That is normal."
wait_until "${UP_WAIT_APPS_SECONDS:-3000}" "all $EXPECTED_APPS Applications Synced and Healthy" \
  "Check the Applications named above: kubectl -n argocd describe application <name>" \
  all_apps_ok

"$ROOT/scripts/status.sh" || warn "scripts/status.sh failed, though the Applications are up"
ok "All $EXPECTED_APPS Applications are Synced and Healthy. That does not prove Plane works: run make test."
