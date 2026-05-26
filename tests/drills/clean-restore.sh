#!/usr/bin/env bash
# Disaster recovery drill: delete the whole cluster, bring the platform back from what survives on the
# host, and prove the data and the secrets are the ones that were there before.
#
#   make drill-clean-restore PLAN_ONLY=yes    the checks and a fresh backup, deleting nothing
#   make drill-clean-restore CONFIRM=yes      all of it
#
# THIS DELETES THE CLUSTER, with both Plane environments and Infisical, and restores them. It takes about
# as long as a first make up plus the restores, so run it in the background and read its evidence log.
#
# CONFIRM=yes        needed for the part that deletes
# BACKUP=<id>        use this Infisical backup, with SKIP_BACKUP=yes, instead of taking a fresh set
# SKIP_E2E=yes       skip the full smoke test and the Infisical tests at the end
# ALLOW_LOW_DISK=yes delete although the host has under 25 GiB free. make up refuses a new cluster below
#                    25 GiB, so the drill then stops after the delete until the space comes back or is freed
#
# Everything compared across the delete is a truncated hash or an id, so the evidence log holds no secret.
#
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=../../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"
# shellcheck source=../../infisical/lib/recovery.sh
source "$ROOT/infisical/lib/recovery.sh"

BACKUP="${BACKUP:-latest}"
accept_args CONFIRM BACKUP SKIP_BACKUP PLAN_ONLY SKIP_E2E ALLOW_LOW_DISK -- "$@"
if [[ "${CONFIRM:-}" != yes && "${PLAN_ONLY:-}" != yes ]]; then
  die "this deletes the cluster and everything in it, then restores them. Run: make drill-clean-restore CONFIRM=yes. To check everything up to that point: make drill-clean-restore PLAN_ONLY=yes"
fi

umask 077
guard_disk
cd "$ROOT"
drill_start clean-restore

WORK="$(mktemp -d "$LOCAL_DIR/.drill-clean-restore.XXXXXX")"
DELETED=no
IID=""
ENVIRONMENTS="dev prod-sim"
RENDERED_SECRETS="plane-app-env plane-app-keys plane-live-env plane-doc-store plane-pgdb plane-rabbitmq"

finish_trap() {
  local status=$?
  rm -rf "$WORK"
  if [[ "$DELETED" == yes && "$status" -ne 0 ]]; then
    printf '\nThe cluster is gone and the backups are intact. Continue with: make restore-clean BACKUP=%s\n' "${IID:-latest}"
  fi
  drill_result_on_abort
  exit "$status"
}
trap finish_trap EXIT

# A hash of each key of each rendered Secret, so the same comparison can run on both sides of the delete.
rendered_fingerprints() {
  local env secret json key
  for env in $ENVIRONMENTS; do
    for secret in $RENDERED_SECRETS; do
      json="$(kc -n "plane-$env" get secret "$secret" -o json)"
      for key in $(jq -r '.data | keys[]' <<<"$json"); do
        printf 'plane-%s/%s %s %s\n' "$env" "$secret" "$key" "$(jq -je --arg k "$key" '.data[$k] | @base64d' <<<"$json" | recovery_fp)"
      done
    done
  done
}

# Not infisical-machine.json: bootstrap rewrites it, and identifiers below compares what it holds.
secret_zero_checksums() {
  local name
  for name in $RECOVERY_ZERO_REQUIRED $RECOVERY_ZERO_OPTIONAL; do
    [[ "$name" != infisical-machine.json ]] || continue
    if [[ -f "$SECRET_ZERO_DIR/$name" ]]; then printf '%s %s\n' "$name" "$(recovery_sha256 "$SECRET_ZERO_DIR/$name")"; fi
  done
}

identifiers() { jq -S '{organization: .organization.id, project_ids, identity_ids}' "$MACHINE_FILE"; }

cluster_ca_fp() { kc -n infisical get configmap kube-root-ca.crt -o json | jq -je '.data["ca.crt"]' | recovery_fp; }

apps_all_ok() {
  kc -n argocd get applications -o json | jq -e --argjson want "$(($(cat "$ROOT"/gitops/applications/*.yaml | grep -c '^kind: Application$') + 1))" '
    (.items | length) == $want and all(.items[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")' >/dev/null
}

apps_summary() {
  kc -n argocd get applications -o json | jq -r '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
    | "\(.metadata.name)=\(.status.sync.status // "?")/\(.status.health.status // "?")"] as $w
    | "\(.items | length) Applications, not Synced and Healthy: \(if ($w | length) == 0 then "none" else ($w | join(" ")) end)"'
}

# Every step of a restore's evidence file must be PASS. NOT RUN counts as a failure here, because it
# means a proof this drill exists to make did not happen. The exception is the Prometheus probe, which
# a restore itself treats as a warning: it says something about monitoring, not about the data.
restore_evidence_clean() { # file
  jq -e '.result == "PASS" and all(.steps[]; .status == "PASS" or .step == "proof-probes")' "$1" >/dev/null
}

stage "0. Preflight"
kc get --raw /readyz >/dev/null || abort "cluster is not reachable"
apps_all_ok || abort "a drill needs a working baseline, and it needs exactly the Applications in Git: $(apps_summary)"
pass "every Application is Synced and Healthy"
for env in $ENVIRONMENTS; do
  [[ -f "$LOCAL_DIR/test-sentinel-$env.json" ]] || abort "no sentinel for $env: run make test-e2e ENV=$env first, or the drill cannot prove its data came back"
done
prefix_missing=""
for env in $ENVIRONMENTS; do
  grep "^$(env_prefix "$env")API_TOKEN=" "$LOCAL_DIR/test-accounts.env" >/dev/null 2>&1 || prefix_missing="$prefix_missing $env"
done
[[ -z "$prefix_missing" ]] || abort "no API token in .local/test-accounts.env for:$prefix_missing. Run make test-e2e for each."
pass "sentinels and test accounts exist for: $ENVIRONMENTS"
if [[ "${CONFIRM:-}" == yes && "$(free_disk_gib)" -lt 25 && "${ALLOW_LOW_DISK:-}" != yes ]]; then
  abort "only $(free_disk_gib) GiB free on the host. scripts/up.sh refuses to create a cluster below 25 GiB, so the drill would stop right after the delete. Deleting returns some of it only if Docker trims its disk, which is unmeasured here. Free space, or pass ALLOW_LOW_DISK=yes to accept that risk."
fi
printf 'host disk: %s GiB free\n' "$(free_disk_gib)"

stage "1. Baseline"
rendered_fingerprints > "$WORK/rendered.before"
secret_zero_checksums > "$WORK/zero.before"
identifiers > "$WORK/identifiers.before"
BEFORE_CA="$(cluster_ca_fp)"
ARCHIVES_BEFORE="$(find "$SECRET_ZERO_DIR" -maxdepth 1 -name 'archive-*' | wc -l | tr -d ' ')"
pass "$(wc -l < "$WORK/rendered.before" | tr -d ' ') rendered Secret keys hashed, cluster CA $BEFORE_CA, $ARCHIVES_BEFORE secret-zero archives"

stage "2. Backups"
if [[ "${SKIP_BACKUP:-}" == yes ]]; then
  pass "SKIP_BACKUP=yes: using what is on disk, BACKUP=$BACKUP"
else
  [[ "$BACKUP" == latest ]] || abort "BACKUP=$BACKUP needs SKIP_BACKUP=yes, because a fresh backup would not be the one named"
  "$ROOT/scripts/backup.sh" all || abort "backup failed"
  pass "scripts/backup.sh all"
fi

stage "3. Plan"
"$ROOT/scripts/restore.sh" clean "$BACKUP" PLAN_ONLY=yes || abort "the recovery set does not check out, so nothing was deleted"
pass "the recovery set checks out"
if [[ "$BACKUP" == latest ]]; then IID="$(recovery_latest_infisical)"; else IID="$BACKUP"; fi
if [[ "${PLAN_ONLY:-}" == yes ]]; then
  pass "PLAN_ONLY=yes: stopping before the delete"
  drill_finish
  exit $?
fi

stage "4. Delete the cluster"
DELETED=yes
STARTED=$SECONDS
CONFIRM=yes SKIP_BACKUP=yes "$ROOT/scripts/destroy.sh" || abort "scripts/destroy.sh failed"
if cluster_exists; then fail "the cluster still exists"; else pass "cluster gone"; fi
if [[ -f "$LOCAL_DIR/terraform/local/terraform.tfstate" ]]; then fail "the local Terraform state survived, and it describes a cluster that is gone"; else pass "local Terraform state removed"; fi
if [[ -s "$RECOVERY_TF_STATE" ]]; then pass "Infisical Terraform state kept"; else fail "Infisical Terraform state was deleted"; fi
secret_zero_checksums > "$WORK/zero.deleted"
if cmp -s "$WORK/zero.before" "$WORK/zero.deleted"; then pass "secret zero unchanged"; else fail "secret zero changed in the delete"; fi

# Docker Desktop may or may not trim its disk. Measured here because up.sh depends on the answer.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [[ "$(free_disk_gib)" -lt 25 ]] || break
  sleep 15
done
printf 'host disk after the delete: %s GiB free\n' "$(free_disk_gib)"

stage "5. Restore into the clean environment"
RESTORE_LOG_MARK="$(date -u +%Y%m%dT%H%M%SZ)"
"$ROOT/scripts/restore.sh" clean "$IID" || abort "the clean restore failed"
pass "scripts/restore.sh clean $IID finished in $((SECONDS - STARTED))s, counting from the delete"

stage "6. Same data and secrets, new cluster"
AFTER_CA="$(cluster_ca_fp)"
if [[ "$AFTER_CA" != "$BEFORE_CA" ]]; then pass "the cluster CA is new ($AFTER_CA), so this really is another cluster"; else fail "the cluster CA did not change, so the cluster was not replaced"; fi
identifiers > "$WORK/identifiers.after"
if cmp -s "$WORK/identifiers.before" "$WORK/identifiers.after"; then pass "organization, project and identity ids are the old ones"; else fail "organization, project or identity ids changed"; fi
secret_zero_checksums > "$WORK/zero.after"
if cmp -s "$WORK/zero.before" "$WORK/zero.after"; then pass "secret zero and the admin credentials are the old ones"; else fail "secret zero or the admin credentials changed"; fi
ARCHIVES_AFTER="$(find "$SECRET_ZERO_DIR" -maxdepth 1 -name 'archive-*' | wc -l | tr -d ' ')"
if [[ "$ARCHIVES_AFTER" == "$ARCHIVES_BEFORE" ]]; then pass "nothing was archived, so bootstrap never treated this as a fresh instance"; else fail "$((ARCHIVES_AFTER - ARCHIVES_BEFORE)) new secret-zero archives"; fi
rendered_fingerprints > "$WORK/rendered.after"
if cmp -s "$WORK/rendered.before" "$WORK/rendered.after"; then
  pass "all $(wc -l < "$WORK/rendered.after" | tr -d ' ') rendered Secret keys hold the old values"
else
  fail "rendered Secrets differ, in: $(diff "$WORK/rendered.before" "$WORK/rendered.after" | awk '/^[<>]/ { print $2 "/" $3 }' | sort -u | tr '\n' ' ')"
fi
if [[ -e "$RESTORE_CLEAN_MARKER" ]]; then fail "$RESTORE_CLEAN_MARKER is still there"; else pass "the restore is no longer marked as under way"; fi

for evidence in "$LOCAL_DIR"/evidence-raw/restore-clean-[0-9]*.json "$LOCAL_DIR"/evidence-raw/restore-infisical-[0-9]*.json "$LOCAL_DIR"/evidence-raw/restore-dev-[0-9]*.json "$LOCAL_DIR"/evidence-raw/restore-prod-sim-[0-9]*.json; do
  [[ -f "$evidence" ]] || continue
  stamp="${evidence##*-}"
  stamp="${stamp%.json}"
  [[ ! "$stamp" < "$RESTORE_LOG_MARK" ]] || continue
  if restore_evidence_clean "$evidence"; then
    pass "${evidence##*/}: every step PASS"
  else
    fail "${evidence##*/}: $(jq -r '[.steps[] | select(.status != "PASS") | "\(.step) \(.status)"] | join(", ")' "$evidence")"
  fi
done

if apps_all_ok; then pass "every Application is Synced and Healthy"; else fail "$(apps_summary)"; fi

stage "7. A second run changes nothing"
BOOTSTRAP_LOG="$WORK/bootstrap.log"
if INFISICAL_RESTORED=yes "$ROOT/scripts/infisical-bootstrap.sh" > "$BOOTSTRAP_LOG" 2>&1; then
  if grep -F 'Terraform has nothing to change' "$BOOTSTRAP_LOG" >/dev/null; then pass "bootstrap in restored mode: Terraform has nothing to change"; else fail "bootstrap in restored mode still had Terraform changes"; fi
else
  fail "bootstrap in restored mode failed on its second run"
  cat "$BOOTSTRAP_LOG"
fi
if "$ROOT/scripts/infisical-bootstrap.sh" > "$BOOTSTRAP_LOG" 2>&1; then
  if grep -F 'all secrets already exist, nothing written' "$BOOTSTRAP_LOG" >/dev/null; then pass "plain bootstrap, as make up runs it: nothing written"; else fail "plain bootstrap wrote secrets"; fi
else
  fail "plain bootstrap failed after the restore"
  cat "$BOOTSTRAP_LOG"
fi

stage "8. The tests a platform has to pass anyway"
if [[ "${SKIP_E2E:-}" == yes ]]; then
  printf 'NOT RUN  SKIP_E2E=yes: Infisical isolation, rendered Secrets, full smoke test\n'
else
  rc=0
  "$ROOT/scripts/test.sh" infisical || rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "Infisical isolation and rendered Secrets, so Kubernetes Auth works with the new CA"; else fail "scripts/test.sh infisical exited $rc"; fi
  for env in $ENVIRONMENTS; do
    rc=0
    "$ROOT/scripts/test.sh" e2e "$env" || rc=$?
    if [[ "$rc" -eq 0 ]]; then pass "full smoke test in $env, signing in with the restored accounts"; else fail "scripts/test.sh e2e $env exited $rc"; fi
  done
fi

drill_finish
