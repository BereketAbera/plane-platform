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
# LOSE_CLUSTER=yes   delete the cluster with kind and nothing else, as a disaster would, which leaves
#                    .local/terraform/local behind. The restore then has to move it aside
# ALLOW_LOW_DISK="<reason>"  go on although the check before the delete says up.sh would refuse. Logged
#
# It stops at once if a clean restore is still marked as under way, because a plan would then check that one's backups
# and not the fresh set. Before the delete it checks what scripts/up.sh would stop on, with the same code: uncommitted
# changes, digests the registry cannot serve, which a registry that does not answer cannot say, and disk, as free space
# plus the share of the kind volume a delete brings
# back. So a run that passes here does not stop at up.sh's check for a new cluster. If less comes back than
# measured, the drill says so and passes that to up.sh as a logged reason, since the cluster is gone by then and
# a stop there would protect nothing. Other work must keep off gitops, helm, monitoring and infisical until it ends.
#
# Everything compared across the delete is a truncated hash or an id, so the evidence log holds no secret.
#
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/up-checks.sh
source "$(dirname "$0")/../../scripts/lib/up-checks.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=../../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"
# shellcheck source=../../infisical/lib/recovery.sh
source "$ROOT/infisical/lib/recovery.sh"

BACKUP="${BACKUP:-latest}"
accept_args CONFIRM BACKUP SKIP_BACKUP PLAN_ONLY SKIP_E2E LOSE_CLUSTER ALLOW_LOW_DISK CLEAN_INSTALL_FIRST -- "$@"
if [[ "${CONFIRM:-}" != yes && "${PLAN_ONLY:-}" != yes ]]; then
  die "this deletes the cluster and everything in it, then restores them. Run: make drill-clean-restore CONFIRM=yes. To check everything up to that point: make drill-clean-restore PLAN_ONLY=yes"
fi

low_disk_check_value
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
  # What it says has to reach the evidence with a client that can no longer print, as in on_exit in scripts/restore.sh.
  set +e
  trap '' HUP INT TERM PIPE
  { printf '\n'; } 2>/dev/null || exec >>"$DRILL_EVIDENCE" 2>&1
  { printf '\n' >&3; } 3>&2 2>/dev/null || exec 2>>"$DRILL_EVIDENCE"
  rm -rf "$WORK"
  if [[ "$status" -ne 0 ]]; then
    case "$DELETED" in
      started) printf '\nThe delete did not finish, so the cluster may be partly gone. The backups are intact. If it is gone, continue with: make restore-clean BACKUP=%s\n' "${IID:-latest}" ;;
      yes)
        if cluster_exists; then
          printf '\nThe old cluster is gone, and the restore into a new one did not finish. The backups are intact. Continue with: make restore-clean BACKUP=%s\n' "${IID:-latest}"
        else
          printf '\nThe cluster is gone and the backups are intact. Continue with: make restore-clean BACKUP=%s\n' "${IID:-latest}"
        fi
        ;;
    esac
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

# Not infisical-machine.json: bootstrap rewrites it, and identifiers below compares what it holds. The admin file
# is compared by itself, because a run may replace its token, as long as that is on record.
secret_zero_checksums() {
  local name
  for name in $RECOVERY_ZERO_REQUIRED $RECOVERY_ZERO_OPTIONAL; do
    [[ "$name" != infisical-machine.json && "$name" != infisical-admin.json ]] || continue
    if [[ -f "$SECRET_ZERO_DIR/$name" ]]; then printf '%s %s\n' "$name" "$(recovery_sha256 "$SECRET_ZERO_DIR/$name")"; fi
  done
}

stale_local_states() { find "$LOCAL_DIR/terraform" -maxdepth 1 -name 'local.stale-*' | wc -l | tr -d ' '; }

# Archives bootstrap or secret-zero.sh made, which mean a fresh start. Not archive-token-*, which a replaced token
# leaves, or archive-pre-restore-*, which a restore leaves.
fresh_start_archives() {
  find "$SECRET_ZERO_DIR" -maxdepth 1 -name 'archive-[0-9]*' | wc -l | tr -d ' '
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
# A plan under a marker checks the set it names, and not the fresh one this drill restores, so a plan that passes
# here would be followed by a delete and then by a refusal of that fresh set.
if [[ -e "$RESTORE_CLEAN_MARKER" ]]; then
  abort "a clean restore of Infisical backup $(sed -n 's/^infisical=//p' "$RESTORE_CLEAN_MARKER") is still marked as under way (${RESTORE_CLEAN_MARKER#"$ROOT"/}), so a plan here would check that backup and not the fresh one this drill restores. Nothing was deleted. To clear it: make restore-clean BACKUP=<that id> finishes it, and removes the file once every proof passes. If the platform here is what you want to keep and that restore is over, rm ${RESTORE_CLEAN_MARKER#"$ROOT"/}, which deletes nothing. make destroy CONFIRM=yes SKIP_BACKUP=yes removes it too, with the cluster."
fi
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
DIRTY="$(up_uncommitted)"
[[ -z "$DIRTY" ]] || abort "scripts/up.sh refuses uncommitted changes under the paths Argo CD reads, so the drill would stop right after the delete. Commit or stash these, and keep those paths still until the drill ends:
$DIRTY"
pass "no uncommitted changes under the paths Argo CD reads"
printf 'host disk: %s\n' "$(up_disk_report)"
DISK_PROBLEM="$(up_disk_problem)"
AFTER_DELETE_GIB="$(kib_as_gib "$(disk_after_delete_kib)")"
if [[ -z "$DISK_PROBLEM" ]]; then
  pass "disk: about $AFTER_DELETE_GIB GiB free after the delete clears the $UP_NEW_CLUSTER_GIB GiB that up.sh asks for"
elif [[ -n "${ALLOW_LOW_DISK:-}" ]]; then
  if [[ "${CONFIRM:-}" == yes ]]; then low_disk_log clean-restore-drill "$DISK_PROBLEM"; else warn "$DISK_PROBLEM"; fi
  pass "disk: below the check, going on with the reason given in ALLOW_LOW_DISK"
else
  abort "$DISK_PROBLEM, so the drill would stop right after the delete. Free space, or say why to go on with ALLOW_LOW_DISK=\"<reason>\", which is logged."
fi

stage "1. Baseline"
rendered_fingerprints > "$WORK/rendered.before"
secret_zero_checksums > "$WORK/zero.before"
identifiers > "$WORK/identifiers.before"
ADMIN_BEFORE="$(recovery_sha256 "$ADMIN_FILE")"
BEFORE_CA="$(cluster_ca_fp)"
ARCHIVES_BEFORE="$(fresh_start_archives)"
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
"$ROOT/scripts/restore.sh" clean "$BACKUP" PLAN_ONLY=yes || abort "the plan refused, as it says above, so nothing was deleted"
pass "the plan passed: the recovery set checks out, and nothing up.sh would stop on was found"
if [[ "$BACKUP" == latest ]]; then IID="$(recovery_latest_infisical)"; else IID="$BACKUP"; fi
if [[ "${PLAN_ONLY:-}" == yes ]]; then
  pass "PLAN_ONLY=yes: stopping before the delete"
  drill_finish
  exit $?
fi

stage "4. Delete the cluster"
DELETED=started
STARTED=$SECONDS
FREE_BEFORE_DELETE="$(free_disk_kib)"
STALE_BEFORE="$(stale_local_states)"
if [[ "${LOSE_CLUSTER:-}" == yes ]]; then
  kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" || abort "kind delete cluster failed"
else
  CONFIRM=yes SKIP_BACKUP=yes "$ROOT/scripts/destroy.sh" || abort "scripts/destroy.sh failed"
fi
DELETED=yes
if cluster_exists; then fail "the cluster still exists"; else pass "cluster gone"; fi
if [[ "${LOSE_CLUSTER:-}" == yes ]]; then
  if [[ -f "$LOCAL_DIR/terraform/local/terraform.tfstate" ]]; then pass "the local Terraform state was left behind, as a disaster leaves it"; else fail "the local Terraform state is gone, so this did not test a disaster"; fi
else
  if [[ -f "$LOCAL_DIR/terraform/local/terraform.tfstate" ]]; then fail "the local Terraform state survived, and it describes a cluster that is gone"; else pass "local Terraform state removed"; fi
fi
if [[ -s "$RECOVERY_TF_STATE" ]]; then pass "Infisical Terraform state kept"; else fail "Infisical Terraform state was deleted"; fi
secret_zero_checksums > "$WORK/zero.deleted"
if cmp -s "$WORK/zero.before" "$WORK/zero.deleted"; then pass "secret zero unchanged"; else fail "secret zero changed in the delete"; fi

# What the host got back, against what the check before the delete counted on. This run's own measurement of the
# reclaim on a real kind volume.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [[ "$(free_disk_kib)" -lt $((UP_NEW_CLUSTER_GIB * 1048576)) ]] || break
  sleep 15
done
printf 'host disk after the delete: %s GiB free, %s GiB came back, the check counted on about %s GiB free\n' \
  "$(kib_as_gib "$(free_disk_kib)")" "$(kib_as_gib "$(($(free_disk_kib) - FREE_BEFORE_DELETE))")" "$AFTER_DELETE_GIB"
# A run that passed the check must not stop at the same check for lack of a few hundred MB. Nothing is protected by
# stopping now: the cluster is gone, and the node's freed space that has not reached the host is space it will reuse.
if [[ "$(free_disk_gib)" -lt "$UP_NEW_CLUSTER_GIB" && -z "${ALLOW_LOW_DISK:-}" ]]; then
  ALLOW_LOW_DISK="the drill's check counted on about $AFTER_DELETE_GIB GiB after the delete, and $(kib_as_gib "$(free_disk_kib)") GiB is free now"
  export ALLOW_LOW_DISK
  warn "$ALLOW_LOW_DISK. Passing that to scripts/up.sh as the reason to go on."
fi

# CLEAN_INSTALL_FIRST=yes runs a clean install from a fresh clone in this gap and deletes it again, so one delete
# proves the install and the restoration. Its secrets and databases are new, and nothing here depends on them.
if [[ "${CLEAN_INSTALL_FIRST:-}" == yes ]]; then
  stage "4b. Clean install from a fresh clone, then delete it"
  INSTALL_STARTED=$SECONDS
  if "$ROOT/tests/drills/clean-install.sh"; then
    pass "clean install from a fresh clone, tested and deleted, in $((SECONDS - INSTALL_STARTED))s"
  else
    fail "the clean install reported a failure, after $((SECONDS - INSTALL_STARTED))s. See .local/evidence-raw/clean-install-*/summary.txt"
  fi
  if cluster_exists; then abort "the clean install left a cluster behind, so the restore cannot start"; fi
fi

stage "5. Restore into the clean environment"
RESTORE_LOG_MARK="$(date -u +%Y%m%dT%H%M%SZ)"
"$ROOT/scripts/restore.sh" clean "$IID" || abort "the clean restore failed or could not finish, with exit status $?"
pass "scripts/restore.sh clean $IID finished in $((SECONDS - STARTED))s, counting from the delete"
# The platform is back from here on, so what the exit trap says about a cluster that is gone no longer holds, and
# following it would be refused, with advice that deletes what was just restored.
DELETED=no

stage "6. Same data and secrets, new cluster"
AFTER_CA="$(cluster_ca_fp)"
if [[ "$AFTER_CA" != "$BEFORE_CA" ]]; then pass "the cluster CA is new ($AFTER_CA), so this really is another cluster"; else fail "the cluster CA did not change, so the cluster was not replaced"; fi
identifiers > "$WORK/identifiers.after"
if cmp -s "$WORK/identifiers.before" "$WORK/identifiers.after"; then pass "organization, project and identity ids are the old ones"; else fail "organization, project or identity ids changed"; fi
secret_zero_checksums > "$WORK/zero.after"
if cmp -s "$WORK/zero.before" "$WORK/zero.after"; then pass "secret zero and the admin password are the old ones"; else fail "secret zero or the admin password changed"; fi
ADMIN_AFTER="$(recovery_sha256 "$ADMIN_FILE")"
if [[ "$ADMIN_AFTER" == "$ADMIN_BEFORE" ]]; then
  pass "the admin token file is the old one"
elif recovery_admin_descends "$ADMIN_BEFORE" "$ADMIN_AFTER"; then
  pass "the admin token was replaced, and ${ADMIN_TOKEN_LEDGER##*/} records that"
else
  fail "the admin token file changed, and nothing records it"
fi
ARCHIVES_AFTER="$(fresh_start_archives)"
if [[ "$ARCHIVES_AFTER" == "$ARCHIVES_BEFORE" ]]; then pass "nothing was archived, so bootstrap never treated this as a fresh instance"; else fail "$((ARCHIVES_AFTER - ARCHIVES_BEFORE)) new secret-zero archives"; fi
if [[ "${LOSE_CLUSTER:-}" == yes ]]; then
  if [[ "$(stale_local_states)" -gt "$STALE_BEFORE" ]]; then
    pass "the state of the lost cluster was moved aside, not applied over"
  else
    fail "no sign that the state of the lost cluster was moved aside"
  fi
fi
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
  # One line for each environment, so that the one that has them all does not speak for the other.
  WROTE=""
  for env in dev prod-sim; do
    grep -F "$env: all secrets already exist, nothing written" "$BOOTSTRAP_LOG" >/dev/null || WROTE="$WROTE $env"
  done
  if [[ -z "$WROTE" ]]; then pass "plain bootstrap, as make up runs it: nothing written"; else fail "plain bootstrap wrote secrets in:$WROTE"; fi
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
