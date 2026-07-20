#!/usr/bin/env bash
# Clean local installation from a fresh clone: repository commands alone, with no local state at all.
#
#   tests/drills/clean-install.sh     needs the cluster to be gone already, and refuses otherwise
#
# It clones this checkout's HEAD beside it, runs make setup and make up there, tests what came up, runs make up again
# to show it changes nothing, reads Terraform for drift, then deletes that cluster and the clone. All of its secrets
# are new, and its databases start empty. tests/drills/clean-restore.sh runs this between its delete and its restore,
# with CLEAN_INSTALL_FIRST=yes, so one delete proves the install and the restoration.
#
# What this is not. .tools is copied from this checkout, because GitHub downloads run at about 170 KB/s here, so make setup
# only checks it. Plain: it keeps the local registry and the pull-through caches, so nothing is rebuilt and nothing is
# pulled from the internet.
#
# COLD_INSTALL=yes is the closest this gets to a new machine: the local services and their volumes are gone already, as
# make destroy PURGE=yes leaves them. So make up builds the images and stops because the digests in Git do not exist here,
# then this promotes what was built, as a new machine would have to, and make up pulls everything through empty caches.
# At the end it puts back .local/registry-snapshot.tar, if one exists, because the checkout it came from names those digests.
#
# The clone's evidence goes to .local/evidence-raw/clean-install-<UTC time>/ in this checkout.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

COLD_INSTALL="${COLD_INSTALL:-no}"
# A drill runs this with its own options in the environment. make obeys those, so nothing inherited may reach the clone.
unset CONFIRM PURGE SKIP_BACKUP BACKUP PLAN_ONLY SKIP_E2E LOSE_CLUSTER CLEAN_INSTALL_FIRST

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CLONE="$(dirname "$ROOT")/plane-platform-clean-install"
EVIDENCE="$ROOT/.local/evidence-raw/clean-install-$STAMP"
SUMMARY="$EVIDENCE/summary.txt"
mkdir -p "$EVIDENCE"

cluster_exists && die "cluster $CLUSTER_NAME exists. A clean install needs it gone: make destroy CONFIRM=yes first"
[[ ! -e "$CLONE" ]] || die "$CLONE already exists. Remove it first, because this script will not reuse a clone"

failures=0
say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$SUMMARY"; }
step() {
  # step <name> <command...>: run in the clone, keep all output, record the exit status and the time.
  local name="$1" started=$SECONDS status=0
  shift
  (cd "$CLONE" && "$@") >"$EVIDENCE/$name.txt" 2>&1 || status=$?
  say "$name: exit $status in $((SECONDS - started))s: $*"
  [[ "$status" -eq 0 ]] || failures=$((failures + 1))
  return "$status"
}

say "clean install of $(git -C "$ROOT" rev-parse --short HEAD) into $CLONE. Host disk: $(free_disk_gib) GiB free"
git clone --quiet --no-hardlinks "$ROOT" "$CLONE" || die "git clone failed"
git -C "$CLONE" config user.name "$(git -C "$ROOT" config user.name)"
git -C "$CLONE" config user.email "$(git -C "$ROOT" config user.email)"
cp -Rc "$ROOT/.tools" "$CLONE/.tools" 2>/dev/null || cp -R "$ROOT/.tools" "$CLONE/.tools"
say "the clone holds no .local and no .build. .tools was copied, so make setup checks it and does not download it"

cleanup_clone() {
  mkdir -p "$EVIDENCE/clone-evidence"
  [[ -d "$CLONE/.local/evidence-raw" ]] && cp -R "$CLONE/.local/evidence-raw/." "$EVIDENCE/clone-evidence/" 2>/dev/null
  say "clone evidence copied to $EVIDENCE/clone-evidence"
}
trap cleanup_clone EXIT

step make-setup make setup || die "make setup failed. The clone is left at $CLONE"
up_started=$SECONDS
if [[ "$COLD_INSTALL" == yes ]]; then
  # No registry, so the digests Git names exist nowhere. make up must build and then stop, saying what to do.
  step make-up-stops-on-new-digests bash -c '! make up' || die "make up should have stopped after building, and did not"
  say "make up created the cluster and local services, built the images, and stopped in $((SECONDS - up_started))s"
  [[ -s "$CLONE/.build/digests.tsv" ]] || die "make up stopped with no .build/digests.tsv"
  step make-promote-dev make promote ENV=dev || die "make promote ENV=dev failed"
  # Nothing runs yet, so plane-dev cannot have proven these digests. The check names this override for that reason.
  step make-promote-prod-sim env OVERRIDE_DEV_CHECK="first install on a new machine: nothing is running yet" CONFIRM=yes SKIP_BACKUP=yes make promote ENV=prod-sim \
    || die "make promote ENV=prod-sim failed"
  # The build's own files are not part of the platform, and this host is short of disk.
  rm -rf "$CLONE/.build/plane-src" "$CLONE/.build/pnpm-store" "$CLONE/.build/home"
  docker builder prune -af >"$EVIDENCE/builder-prune.txt" 2>&1 || true
  say "removed the build's source tree, package store and Docker's build cache. Host disk: $(free_disk_gib) GiB free"
fi
pull_started=$SECONDS
step make-up make up || die "make up failed after $((SECONDS - pull_started))s. The cluster and the clone are left as they are, for reading"
say "make up took $((SECONDS - pull_started))s. From the start of the first make up: $((SECONDS - up_started))s"

step make-status make status || true
# What the first boot did: when each Application's first operation ran, how much the caches took in, and what it cost the host.
step app-timeline bash -c '"$0" --kubeconfig "$1" --context "kind-$2" -n argocd get applications -o json | python3 -I -c "
import json,sys
rows=[]
for a in json.load(sys.stdin)[\"items\"]:
    s=a.get(\"status\",{}); h=s.get(\"history\") or [{}]; op=s.get(\"operationState\") or {}
    rows.append((h[0].get(\"deployStartedAt\",\"-\"),h[0].get(\"deployedAt\",\"-\"),a[\"metadata\"][\"name\"],a[\"metadata\"].get(\"annotations\",{}).get(\"argocd.argoproj.io/sync-wave\",\"-\"),op.get(\"phase\",\"-\")))
for r in sorted(rows): print(*r)
"' "$ROOT/.tools/bin/kubectl" "$CLONE/.local/kubeconfig" "$CLUSTER_NAME" || true
step disk-after-install bash -c 'df -h /; du -sk "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"; docker system df; for v in $(docker volume ls -q | grep plane-platform-local); do printf "%s " "$v"; docker system df -v 2>/dev/null | grep -F "$v" | head -1; done' || true
step apps-after-up "$ROOT/.tools/bin/kubectl" --kubeconfig "$CLONE/.local/kubeconfig" --context "kind-$CLUSTER_NAME" -n argocd get applications || true

# The first smoke on a clean database is the only one that can read what the images registered.
step e2e-dev-first make test-e2e ENV=dev || true
step e2e-prod-sim-first make test-e2e ENV=prod-sim || true
for run in e2e-dev-first e2e-prod-sim-first; do
  grep -E '^(PASS|FAIL|SKIP|BLOCKED) +branding-fresh-install|^RESULT' "$EVIDENCE/$run.txt" | tee -a "$SUMMARY" || true
done
step test-infisical make test-infisical || true

# INST-2: a second make up changes nothing.
before="$("$ROOT/.tools/bin/kubectl" --kubeconfig "$CLONE/.local/kubeconfig" --context "kind-$CLUSTER_NAME" get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort | shasum | cut -c1-16)"
second_started=$SECONDS
step make-up-again make up || true
after="$("$ROOT/.tools/bin/kubectl" --kubeconfig "$CLONE/.local/kubeconfig" --context "kind-$CLUSTER_NAME" get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort | shasum | cut -c1-16)"
say "second make up took $((SECONDS - second_started))s. Pod uid hash before $before, after $after"
if [[ "$before" != "$after" ]]; then say "the set of pods changed across the second make up, which short-lived test pods can also cause"; fi

# INST-4: Terraform's state matches what it owns.
tf_dir="infrastructure/terraform/environments/local"
step terraform-plan-local env KUBECONFIG="$CLONE/.local/kubeconfig" "$ROOT/.tools/bin/terraform" -chdir="$CLONE/$tf_dir" plan -lock=false -detailed-exitcode -input=false || true

# BKP-5: a backup from the other install holds another SECRET_KEY, so a restore must refuse it. If it did not refuse,
# only this throwaway install would lose anything.
foreign=""
for candidate in "$ROOT"/.local/backups/dev/[0-9]*Z; do
  [[ -d "$candidate" ]] && foreign="$(basename "$candidate")"
done
if [[ -n "$foreign" ]]; then
  mkdir -p "$CLONE/.local/backups/dev"
  cp -R "$ROOT/.local/backups/dev/$foreign" "$CLONE/.local/backups/dev/"
  step restore-foreign-key-refused bash -c "! make restore ENV=dev BACKUP=$foreign CONFIRM=yes" || true
  rm -rf "${CLONE:?}/.local/backups/dev/$foreign"
fi

# TEAR-1: refused with no confirmation, and nothing changes.
# The drill that calls this is run by make with CONFIRM=yes on its command line. make passes that down in MAKEFLAGS, past
# the unset above, and make destroy obeys it. Two drills deleted their install this way before this was understood.
step destroy-refused env -u CONFIRM -u MAKEFLAGS -u MFLAGS -u MAKELEVEL bash -c '! make destroy' || true
step destroy make destroy CONFIRM=yes SKIP_BACKUP=yes
cleanup_clone
trap - EXIT
rm -rf "$CLONE"
snapshot="$ROOT/.local/registry-snapshot.tar"
if [[ "$COLD_INSTALL" == yes && -f "$snapshot" ]]; then
  docker exec -i plane-registry tar -C /var/lib/registry -xf - <"$snapshot" || die "putting the registry snapshot back failed"
  docker restart plane-registry >/dev/null || die "restarting plane-registry failed"
  say "registry snapshot put back, so this checkout's digests are served again"
  rm -f "$snapshot"
fi
say "clone removed. Host disk: $(free_disk_gib) GiB free. Steps that failed: $failures"
[[ "$failures" -eq 0 ]]
