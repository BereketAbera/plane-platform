#!/usr/bin/env bash
# Negative controls for tests/drills/clean-restore-harness.sh. Each mutant takes one line the platform depends on out of a
# copy of the scripts, and runs the scenarios that ought to notice. So this says which lines the harness looks at, and,
# for those it does not, says so. It proves nothing about the platform, for the reasons that harness gives.
#
#   tests/drills/clean-restore-mutants.sh                    all of them, in the background. 22 minutes at JOBS=4
#   MUTANTS="no-migrator no-valkey-flush" tests/drills/clean-restore-mutants.sh
#   JOBS=4 tests/drills/clean-restore-mutants.sh             how many at once, 3 if not set
#   tests/drills/clean-restore-mutants.sh --list
#
# A mutant is run against the scenarios beside it, and not all of them, so SURVIVED means those scenarios did not notice.
# Exit status: 0 if every mutant applied and was caught, 1 if any survived, 2 if any did not apply.
#
# The first block is the 22 the second review of the clean restore tried, in its words as far as they name a line.
# Touches no cluster. Each copy is a few hundred KB under $TMPDIR, gone when its run ends.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS="${JOBS:-3}"
SELF="$REPO/tests/drills/clean-restore-mutants.sh"

# name, TAB, file, TAB, scenarios, with @x for R8D_ONLY=x, TAB, perl substitution over the whole file.
mutant_table() {
  cat <<'TABLE'
no-migrator	scripts/restore.sh	S1	s/^  run_migrator\n  record migrator PASS "completed"\n//m
no-valkey-flush	scripts/restore.sh	S1	s/^  kc -n "\$NS" exec plane-redis-wl-0 -c plane-redis -- valkey-cli FLUSHALL >\/dev\/null\n//m
no-rabbitmq-purge	scripts/restore.sh	S1	s/^    kc -n "\$NS" exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q purge_queue celery >\/dev\/null\n//m
no-compare-rendered-in-verify	scripts/restore.sh	R8	s/if problems="\$\(recovery_compare_rendered "\$set_file" "\$env"\)"; then/if true; then/
no-wait-for-fresh-server	scripts/restore.sh	S1	s/^    clean_wait_infisical\n(    "\$restore_script" infisical)/$1/m
no-decrypt-proof	scripts/restore.sh	S1 R8	s/^  prove_decrypt \|\| failed=1\n//m
no-compare-values-in-verify	scripts/restore.sh	R8	s/if problems="\$\(recovery_compare_values "\$set_file"\)"; then\n    clean_record verify-infisical-values/if true; then\n    clean_record verify-infisical-values/
no-overwrite-guard-plane	scripts/restore.sh	R8	s/^  refuse_if_not_empty "\$users" "\$objects"\n//m
drill-identifiers-not-compared	tests/drills/clean-restore.sh	R8d@ids in the machine file	s/if cmp -s "\$WORK\/identifiers.before" "\$WORK\/identifiers.after"; then/if true; then/
drill-rendered-not-compared	tests/drills/clean-restore.sh	R8d@a rendered Secret differs	s/if cmp -s "\$WORK\/rendered.before" "\$WORK\/rendered.after"; then/if true; then/
drill-evidence-not-checked	tests/drills/clean-restore.sh	R8d@evidence is not all PASS	s/if restore_evidence_clean "\$evidence"; then/if true; then/
prune-before-the-set-is-complete	scripts/backup.sh	S32	s/^(\[\[ "\$recovery_failed" == no \]\] \|\|)/if [[ "\$ENV_NAME" == infisical ]]; then recovery_prune_infisical "\$KEEP"; fi\n$1/m
secret-zero-not-reinstated	scripts/restore.sh	S7	s/^  recovery_reinstate_zero "\$set_file"\n//m
test-files-not-put-back	scripts/restore.sh	S19	s/^  recovery_reinstate_test_files "\$backup_dir" "\$ENV_NAME"\n//m
no-sentinel-proof	scripts/restore.sh	S1 R8	s/^  prove_sentinel \|\| failed=1\n//m
environment-not-marked-done	scripts/restore.sh	S33	s/^      clean_mark "\$env"\n//m
no-in-place-compare	scripts/restore.sh	S14	s/^  if \[\[ -n "\$set_file" && "\$RESTORE_MODE" != clean \]\]; then refuse_stale_plane_secrets "\$set_file"; fi\n//m
no-prepare-admin	scripts/backup.sh	S25	s/^  recovery_prepare_admin\n//m
no-version-check	scripts/restore.sh	S35	s/if recovery_version_newer "\$backup_version" "\$live_version"; then/if false; then/
repair-leaves-the-job	scripts/restore.sh	S31	s/^      kc -n "\$ns" delete job "\$job" --cascade=foreground --timeout=180s >\/dev\/null \|\| die [^\n]*\n//m
restored-mode-applies-anything	scripts/infisical-bootstrap.sh	S1 S10	s/^  apply_restored$/  tf apply -lock-timeout=10m -input=false -auto-approve/m
stale-done-lines-kept	scripts/restore.sh	S15	s/^    if recovery_marker_cluster_gone && grep -qE '\^\(done\|data-back\) ' "\$RESTORE_CLEAN_MARKER"; then/    if false; then/m
no-overwrite-guard-infisical	scripts/restore.sh	R8	s/^  refuse_if_not_empty "\$users" 0\n//m
marker-not-compared-with-latest	scripts/restore.sh	R1	s/^    if \[\[ "\$requested" == latest \]\]; then clean_refuse_stale_marker; fi\n//m
marker-plane-choice-stands	scripts/restore.sh	R1	s/^  if ! recovery_marker_cluster_gone; then return 0; fi\n  for env in \$CLEAN_ENVS; do\n    id="\$\(clean_marker_value "\$env"\)"\n    fresh=/  return 0\n  for env in \$CLEAN_ENVS; do\n    id="\$(clean_marker_value "\$env")"\n    fresh=/m
resume-not-told-to-child	scripts/restore.sh	R2	s/ "RESTORE_RESUME=\$under_way" \|\| rc=\$\?/ || rc=\$?/g
resume-refuses-a-partial-restore	scripts/restore.sh	R2	s/\("\$users" -eq 0 \|\| "\$users" == "\$want_users"\) && "\$objects" -le "\$want_objects"/"\$users" == "\$want_users" && "\$objects" == "\$want_objects"/
next-from-every-infisical-id	infisical/lib/recovery.sh	R3	s/if \[\[ "\$id" > "\$iid" \]\] && recovery_set_complete "\$LOCAL_DIR\/backups\/infisical\/\$id"; then/if [[ "\$id" > "\$iid" ]]; then/
no-warning-of-newer-plane	scripts/restore.sh	R3	s/^    clean_warn_newer_plane "\$env" "\$id" "\$set_file"\n//m
exit-leaves-the-job-running	scripts/restore.sh	R4	s/^  stop_this_runs_jobs\n//m
exit-starts-with-job-left	scripts/restore.sh	R4	s/if \[\[ -n "\$JOBS_LEFT_RUNNING" \]\]; then\n    warn "COULD NOT REMOVE/if false; then\n    warn "COULD NOT REMOVE/
exit-does-not-flush-redis	scripts/restore.sh	R4	s/if \[\[ "\$INFISICAL_REDIS_STALE" == yes \]\]; then/if false; then/
repair-only-by-label	scripts/restore.sh	R4	s/jobs_json="\$\(kc -n "\$ns" get jobs -o json 2>\/dev\/null\)"/jobs_json="\$(kc -n "\$ns" get jobs -l app.kubernetes.io\/name=plane-restore -o json 2>\/dev\/null)"/
repair-reads-an-error-as-no-jobs	scripts/restore.sh	R4	s/(jobs_json="\$\(kc -n "\$ns" get jobs -o json 2>\/dev\/null\)") \|\| die [^\n]*\n/$1 || jobs_json='{"items":[]}'\n/
pvc-error-reads-as-none	scripts/restore.sh	R5	s/if ! listed="\$\(kc -n "\$ns" get pvc -o name --ignore-not-found 2>\/dev\/null\)"; then/if ! listed="\$(kc -n "\$ns" get pvc -o name --ignore-not-found 2>\/dev\/null || true)"; then/
infisical-pvc-error-reads-as-none	scripts/restore.sh	R5	s/if ! database="\$\(kc -n infisical get pvc data-infisical-postgres-0 -o name --ignore-not-found 2>\/dev\/null\)"; then/if ! database="\$(kc -n infisical get pvc data-infisical-postgres-0 -o name --ignore-not-found 2>\/dev\/null || true)"; then/
retention-counts-empty-backups	scripts/backup.sh	R6	s/if \[ "\$old" = "\$HOLDS_USERS" \]; then/if false; then/
backup-ignores-the-marker	scripts/backup.sh	R6	s/^if \[\[ -f "\$RESTORE_CLEAN_MARKER" \]\]; then\n  if grep -qx/if false; then\n  if grep -qx/m
no-empty-backup-warning-in-place	scripts/restore.sh	R6	s/^  warn_empty_backup_over_data "\$users"\n//m
drill-ignores-the-marker	tests/drills/clean-restore.sh	R7	s/^if \[\[ -e "\$RESTORE_CLEAN_MARKER" \]\]; then\n  abort/if false; then\n  abort/m
registry-down-is-a-note	scripts/restore.sh	R7	s/^      if cluster_exists; then\n        clean_add_problem "the local registry does not answer/      if false; then\n        clean_add_problem "the local registry does not answer/m
drill-ca-not-compared	tests/drills/clean-restore.sh	R8d@cluster CA	s/if \[\[ "\$AFTER_CA" != "\$BEFORE_CA" \]\]; then/if true; then/
drill-zero-not-compared	tests/drills/clean-restore.sh	R8d@a secret-zero file	s/if cmp -s "\$WORK\/zero.before" "\$WORK\/zero.after"; then/if true; then/
drill-admin-file-not-compared	tests/drills/clean-restore.sh	R8d@the admin file	s/if \[\[ "\$ADMIN_AFTER" == "\$ADMIN_BEFORE" \]\]; then/if true; then/
drill-archives-not-compared	tests/drills/clean-restore.sh	R8d@archive	s/if \[\[ "\$ARCHIVES_AFTER" == "\$ARCHIVES_BEFORE" \]\]; then/if true; then/
drill-marker-not-checked	tests/drills/clean-restore.sh	R8d@the marker	s/if \[\[ -e "\$RESTORE_CLEAN_MARKER" \]\]; then fail/if false; then fail/
drill-apps-not-checked	tests/drills/clean-restore.sh	R8d@an Application	s/^if apps_all_ok; then pass/if true; then pass/m
drill-stale-state-not-checked	tests/drills/clean-restore.sh	R8d@lost cluster	s/if \[\[ "\$\(stale_local_states\)" -gt "\$STALE_BEFORE" \]\]; then/if true; then/
drill-restored-plan-not-checked	tests/drills/clean-restore.sh	R8d@still has changes	s/if grep -F 'Terraform has nothing to change' "\$BOOTSTRAP_LOG" >\/dev\/null; then/if true; then/
drill-plain-bootstrap-not-checked	tests/drills/clean-restore.sh	R8d@plain bootstrap	s/if \[\[ -z "\$WROTE" \]\]; then pass/if true; then pass/
drill-delete-not-checked	tests/drills/clean-restore.sh	R8d@leaves the cluster	s/^if cluster_exists; then fail "the cluster still exists"/if false; then fail "the cluster still exists"/m
first-install-not-counted	scripts/lib/up-checks.sh	R9	s/^  if up_local_volumes_present; then\n    printf '%s' "\$UP_NEW_CLUSTER_GIB"/  if true; then\n    printf '%s' "\$UP_NEW_CLUSTER_GIB"/m
empty-cluster-creates-nothing	scripts/restore.sh	S28	s/^    disk="\$\(up_disk_problem_empty_cluster\)"\n/    disk=""\n/m
floor-lowered-with-no-log	scripts/lib/common.sh	R10	s/"\$FLOOR_LOWERED_LOGGED" == no \]\]; then/"\$FLOOR_LOWERED_LOGGED" == never ]]; then/
blank-reason-passes	scripts/lib/up-checks.sh	R10	s/\[\[ "\$\{#words\[@\]\}" -lt 2 \]\] \|\| return 0/[[ "\$ALLOW_LOW_DISK" != *" "* ]] || return 0/
way-out-has-no-override	scripts/restore.sh	R11	s/ OVERRIDE_DEV_CHECK=\\"restoring into an empty cluster\\"//
machine-file-kept-if-not-empty	infisical/lib/recovery.sh	R12	s/^  if recovery_machine_ids_match "\$dir"; then return 0; fi\n/  [[ ! -s "\$MACHINE_FILE" ]] || return 0\n/m
state-installed-before-the-job	scripts/restore.sh	R13	s/^  ANYTHING_CHANGED=yes\n\n  # This one Application/  ANYTHING_CHANGED=yes\n  recovery_install_tf_state "\$backup_dir"\n\n  # This one Application/m
drill-says-gone-after-stage-5	tests/drills/clean-restore.sh	R14	s/^# following it would be refused, with advice that deletes what was just restored\.\nDELETED=no\n/# following it would be refused.\n/m
marker-ids-not-checked	scripts/restore.sh	R15	s/^    clean_refuse_marker_gone\n//m
another-run-by-absolute-path-only	scripts/restore.sh	R16	s/if clean_process_runs_this_restore "\$pid" "\$cmd"; then others="\$others \$pid"; fi/case "\$cmd" in *"\$ROOT\/scripts\/restore.sh"*) others="\$others \$pid" ;; esac/
another-run-by-any-mention	scripts/restore.sh	R16	s/if clean_process_runs_this_restore "\$pid" "\$cmd"; then others="\$others \$pid"; fi/case "\$cmd" in *scripts\/restore.sh*) others="\$others \$pid" ;; esac/
options-ignored-under-a-marker	scripts/restore.sh	R17	s/^    clean_refuse_other_options\n//m
any-password-counts	infisical/lib/recovery.sh	R18	s/^    RECOVERY_ADMIN_MODE=unknown-password/    RECOVERY_ADMIN_MODE=mint/m
newline-makes-another-password	infisical/lib/recovery.sh	R18	s/^    if \[\[ -n "\$sha" \]\] && recovery_password_named "\$ADMIN_PASSWORD_FILE" "\$sha"; then password_named=yes; fi\n//m
no-set-not-checked	scripts/restore.sh	R18	s/^  recovery_admin_plan "\$admin_set"\n/  recovery_admin_plan "\$admin_set"\n  if [[ -z "\$set_file" ]]; then RECOVERY_ADMIN_MODE=token; fi\n/m
kind-error-discarded	scripts/cluster-up.sh	R19	s/^  printf '%s\\n' "\$kind_export_error" >&2\n//m
plan-advice-without-skip-backup	scripts/restore.sh	S34	s/warn "a real run would refuse right now: \$problem\. \$\(clean_replace_advice\)"/warn "a real run would refuse right now: \$problem. Run make destroy first."/
plan-ignores-a-dangling-row	scripts/restore.sh	R22	s/^    if \[\[ "\$missing" != unknown && "\$missing" != 0 \]\]; then\n      clean_add_problem/    if false; then\n      clean_add_problem/m
in-place-ignores-a-dangling-row	scripts/restore.sh	R22	s/^  if \[\[ "\$missing" != unknown && "\$missing" != 0 \]\]; then\n    die "backup \$BACKUP_ID/  if false; then\n    die "backup \$BACKUP_ID/m
manifest-does-not-record-it	scripts/backup.sh	R22	s/^ *"uploaded_objects": \$UPLOADED,\n//m
comparison-failure-costs-the-backup	scripts/backup.sh	R22	s/^( *)echo "objects: could not compare[^\n]*\n/$1exit 1\n/m
comparison-the-wrong-way-round	scripts/backup.sh	R22	s/LC_ALL=C comm -23 "\$D\/postgres\/uploaded-keys.txt"/LC_ALL=C comm -13 "\$D\/postgres\/uploaded-keys.txt"/
stop-dies-on-a-dead-client	scripts/restore.sh	V1	s/^  set \+e\n  trap '' HUP INT TERM PIPE\n(  \{ printf '\\n'; \} 2>\/dev\/null \|\| exec >>"\$evidence\.log" 2>&1\n)/  trap '' HUP INT TERM\n$1/m
stop-says-nothing-on-a-dead-client	scripts/restore.sh	V1	s/^  \{ printf '\\n'; \} 2>\/dev\/null \|\| exec >>"\$evidence\.log" 2>&1\n//m
clean-stop-dies-on-a-dead-client	scripts/restore.sh	V1	s/^  set \+e\n  trap '' HUP INT TERM PIPE\n(  \{ printf '\\n'; \} 2>\/dev\/null \|\| exec >>"\$CLEAN_EVIDENCE\.log" 2>&1\n)/$1/m
drill-stop-dies-on-a-dead-client	tests/drills/clean-restore.sh	V1	s/^  set \+e\n  trap '' HUP INT TERM PIPE\n//m
destroy-stopped-by-the-marker	scripts/destroy.sh	V2	s/ALLOW_BACKUP_DURING_RESTORE=yes "\$ROOT/"\$ROOT/
bare-yes-accepted	scripts/restore.sh	V3	s/\(infisical\|dev\|prod-sim\)\( \+\|\$\)/(yes|infisical|dev|prod-sim)( +|\$)/
override-reaches-every-environment	scripts/restore.sh	V3	s/^resume_overwrite_names_this\(\) \{[^\n]*\n/resume_overwrite_names_this() { [[ -n "\$\{ALLOW_RESUME_OVERWRITE:-\}" ]]; }\n/m
override-reads-as-a-pass	scripts/restore.sh	V3	s/^      OVERWROTE=yes\n      if[^\n]*\n//m
data-back-not-written	scripts/restore.sh	V4	s/^ +data_back_mark\n//mg
data-back-not-read	scripts/restore.sh	V4	s/^  elif data_back_on_resume && ! resume_overwrite_names_this; then/  elif false; then/m
data-back-beats-the-override	scripts/restore.sh	V4	s/^  elif data_back_on_resume && ! resume_overwrite_names_this; then/  elif data_back_on_resume; then/m
finished-job-not-read	scripts/restore.sh	V4b	s/^    clean_note_finished_data_job "\$\{ns#plane-\}" "\$jobs_json"\n//m
finished-job-by-any-name	scripts/restore.sh	V4b	s/any\(\.items\[\]; \.metadata\.name == \$job and any\(\.status\.conditions\[\]\?; \.type == "Complete" and \.status == "True"\)\)/any(.items[]; (.metadata.name | test("^plane-restore-[0-9]{8}t[0-9]{6}z\$")) and any(.status.conditions[]?; .type == "Complete" and .status == "True"))/
failed-job-reads-as-finished	scripts/restore.sh	V4b	s/any\(\.items\[\]; \.metadata\.name == \$job and any\(\.status\.conditions\[\]\?; \.type == "Complete" and \.status == "True"\)\)/any(.items[]; .metadata.name == \$job)/
data-job-not-named	scripts/restore.sh	V4b	s/^  printf 'data-job %s plane-restore-%s\\n' "\$ENV_NAME" "\$JOB_SUFFIX" >> "\$RESTORE_CLEAN_MARKER\.tmp"\n//m
earlier-line-outlives-a-new-data-job	scripts/restore.sh	V4b	s/ -e "\/\^data-back \$ENV_NAME\\\$\/d"//
refusal-says-nothing-changed	scripts/restore.sh	M1	s/\$NS was not changed\. What this resume did before it could look stands: its repair, and make up as far as this step\./Nothing was changed./
child-speaks-for-the-whole-run	scripts/restore.sh	M1	s/if \[\[ "\$ANYTHING_CHANGED" == no && "\$RESTORE_MODE" == clean \]\]; then/if false; then/
state-walked-back-on-a-resume	scripts/restore.sh	M1	s/^  if clean_done infisical \|\| grep -qx 'data-back infisical' "\$RESTORE_CLEAN_MARKER"; then\n    \[\[ ! -f "\$RECOVERY_TF_STATE" \]\] \|\| return 0\n  fi\n//m
state-never-installed-on-a-resume	scripts/restore.sh	M1	s/^    \[\[ ! -f "\$RECOVERY_TF_STATE" \]\] \|\| return 0\n/    return 0\n/m
child-walks-the-state-back	scripts/restore.sh	M1	s/^(    if \[\[ -n "\$set_file" \]\]; then recovery_rebuild_machine_file "\$backup_dir"; fi\n  fi\n)/$1  recovery_install_tf_state "\$backup_dir"\n/m
new-cluster-keeps-the-lines	infisical/lib/recovery.sh	M2	s/^  \[\[ -n "\$now" && "\$now" != "\$was" \]\]\n/  false\n/m
cluster-not-noted	scripts/restore.sh	M2	s/^  clean_note_cluster\n//m
docker-silence-reads-as-new	infisical/lib/recovery.sh	M2	s/\[\[ -n "\$now" && "\$now" != "\$was" \]\]/[[ "\$now" != "\$was" ]]/
stale-choice-on-a-new-cluster	scripts/restore.sh	M2	s/^  if ! recovery_marker_cluster_gone; then return 0; fi\n/  if cluster_exists; then return 0; fi\n/m
backup-trusts-lines-of-another-cluster	scripts/backup.sh	M2	s/ && ! recovery_marker_cluster_gone; then/; then/g
plan-promises-on-a-new-cluster	scripts/restore.sh	M2	s/ && ! clean_done "\$env" && ! recovery_marker_cluster_gone; then/ && ! clean_done "\$env"; then/
job-check-after-the-last-plane-job	scripts/restore.sh	M3	s/^  JOB_MAY_RUN=no\n//m
job-check-after-the-last-infisical-job	scripts/restore.sh	M3	s/^  JOB_MAY_RUN=no # Every Job[^\n]*\n//m
job-check-ends-before-the-migrator	scripts/restore.sh	M3	s/^(  run_migrator\n)/  JOB_MAY_RUN=no\n$1/m
finished-backup-still-fatal	scripts/restore.sh	M4	s/ \|\| clean_done_stands "\$env"; then continue; fi/; then continue; fi/
finished-backup-still-read	scripts/restore.sh	M4	s/^    if \[\[ ! -f "\$LOCAL_DIR\/backups\/\$env\/\$id\/manifest\.json" \]\]; then continue; fi\n//m
plan-reads-a-finished-backup	scripts/restore.sh	M4	s/^    if \[\[ ! -f "\$LOCAL_DIR\/backups\/\$env\/\$id\/manifest\.json" \]\]; then\n      printf[^\n]*\n      continue\n    fi\n//m
verify-reads-a-finished-backup	scripts/restore.sh	M4	s/^      slug="\$\(jq -r '\.slug \/\/ ""' "\$sentinel" 2>\/dev\/null \|\| true\)"\n/      slug=""\n/m
line-of-a-lost-cluster-spares-a-backup	scripts/restore.sh	M4	s/^clean_done_stands\(\) \{[^\n]*\n/clean_done_stands() { clean_done "\$1"; }\n/m
plan-rounds-up-to-the-limit	scripts/lib/up-checks.sh	M5	s/^kib_as_gib_down\(\) \{[^\n]*\n/kib_as_gib_down() { kib_as_gib "\$1"; }\n/m
plan-rounds-to-two-decimals-only	scripts/lib/up-checks.sh	M5	s/int\(k \* 100 \/ 1048576\) \/ 100/k \/ 1048576/
probe-outlives-the-script	scripts/rotate.sh	H66	s/while kill -0 "\$\$" 2>\/dev\/null; do/while :; do/
probe-stops-at-once	scripts/rotate.sh	H66	s/while kill -0 "\$\$" 2>\/dev\/null; do/while false; do/
TABLE
}

run_one() { # name
  local name="$1" line file scenarios expr copy only="" rc out failed
  line="$(mutant_table | awk -F '\t' -v n="$name" '$1 == n')"
  [[ -n "$line" ]] || { printf 'NOT APPLIED  %s: no such mutant\n' "$name"; return 2; }
  file="$(printf '%s' "$line" | cut -f2)"
  scenarios="$(printf '%s' "$line" | cut -f3)"
  expr="$(printf '%s' "$line" | cut -f4-)"
  case "$scenarios" in *@*) only="${scenarios#*@}"; scenarios="${scenarios%%@*}" ;; esac
  copy="$(mktemp -d "${TMPDIR:-/tmp}/clean-restore-mutant.XXXXXX")"
  out="$copy/out.txt"
  mkdir -p "$copy/src/monitoring/ops" "$copy/src/infisical" "$copy/src/tests/drills"
  cp -R "$REPO/scripts" "$copy/src/"
  cp "$REPO/Makefile" "$copy/src/"
  cp "$REPO/monitoring/ops/lib.sh" "$copy/src/monitoring/ops/"
  cp -R "$REPO/infisical/lib" "$REPO/infisical/manifests" "$REPO/infisical/README.md" "$copy/src/infisical/"
  cp "$REPO"/tests/drills/clean-restore.sh "$REPO"/tests/drills/lib.sh "$copy/src/tests/drills/"
  cp "$copy/src/$file" "$copy/before"
  perl -0pi -e "$expr" "$copy/src/$file"
  if cmp -s "$copy/before" "$copy/src/$file"; then
    printf 'NOT APPLIED  %s\n' "$name"
    rm -rf "$copy"
    return 2
  fi
  HARNESS_SOURCE="$copy/src" ONLY="$scenarios" R8D_ONLY="$only" /bin/bash "$REPO/tests/drills/clean-restore-harness.sh" > "$out" 2>&1
  rc=$?
  failed="$(grep -c '^FAIL' "$out" || true)"
  if [[ "$rc" -eq 0 ]]; then
    printf 'SURVIVED     %s [%s]\n' "$name" "$scenarios"
    rm -rf "$copy"
    return 1
  fi
  printf 'CAUGHT       %s [%s] %s failed, first: %s\n' "$name" "$scenarios" "$failed" "$(grep -m1 '^FAIL' "$out" | cut -c7-100)"
  rm -rf "$copy"
  return 0
}

case "${1:-}" in
  --list) mutant_table | cut -f1,3; exit 0 ;;
  --one) run_one "$2"; exit $? ;;
esac

names="${MUTANTS:-$(mutant_table | cut -f1 | tr '\n' ' ')}"
results="$(mktemp "${TMPDIR:-/tmp}/clean-restore-mutants.XXXXXX")"
# shellcheck disable=SC2086 # One word per name, on purpose.
printf '%s\n' $names | xargs -P "$JOBS" -I{} /bin/bash -c '"$0" --one "$1" | tee -a "$2"' "$SELF" {} "$results"
applied_not="$(grep -c '^NOT APPLIED' "$results" || true)"
survived="$(grep -c '^SURVIVED' "$results" || true)"
caught="$(grep -c '^CAUGHT' "$results" || true)"
rm -f "$results"
printf '\nRESULT %s caught, %s survived, %s did not apply\n' "$caught" "$survived" "$applied_not"
if [[ "$applied_not" -ne 0 ]]; then exit 2; fi
if [[ "$survived" -ne 0 ]]; then exit 1; fi
exit 0
