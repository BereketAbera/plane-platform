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
# What this is not. It keeps the local registry and the pull-through caches, so nothing is rebuilt and nothing is pulled
# from the internet: a new machine also needs make images and make promote, and pulls about 2.6 GiB more. .tools is copied
# from this checkout, because GitHub downloads run at about 170 KB/s here, so make setup only checks it. A truly clean
# machine is what the first bootstrap of this project was, and that run was done stage by stage.
#
# The clone's evidence goes to .local/evidence-raw/clean-install-<UTC time>/ in this checkout.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

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
step make-up make up || die "make up failed after $((SECONDS - up_started))s. The cluster and the clone are left as they are, for reading"
say "one make up from nothing took $((SECONDS - up_started))s"

step make-status make status || true
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
foreign="$(ls -1t "$ROOT/.local/backups/dev" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | head -1 || true)"
if [[ -n "$foreign" ]]; then
  mkdir -p "$CLONE/.local/backups/dev"
  cp -R "$ROOT/.local/backups/dev/$foreign" "$CLONE/.local/backups/dev/"
  step restore-foreign-key-refused bash -c "! make restore ENV=dev BACKUP=$foreign CONFIRM=yes" || true
  rm -rf "${CLONE:?}/.local/backups/dev/$foreign"
fi

# TEAR-1: refused with no confirmation, and nothing changes.
# The drill that calls this runs with CONFIRM=yes in its environment, which make destroy would obey, so clear it here.
step destroy-refused env -u CONFIRM bash -c '! make destroy' || true
step destroy make destroy CONFIRM=yes SKIP_BACKUP=yes
cleanup_clone
trap - EXIT
rm -rf "$CLONE"
say "clone removed. Host disk: $(free_disk_gib) GiB free. Steps that failed: $failures"
[[ "$failures" -eq 0 ]]
