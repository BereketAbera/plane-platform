#!/usr/bin/env bash
# Scenarios for tests/drills/clean-restore-harness.sh, which sources this. One for each finding of the second review of
# the clean restore, named R and that finding's number. What they share: a person ends up with less data than they
# had, and the script says it succeeded. Finding 20 is in S34, and each of findings 8 and 9 also changed S1 or S28.

R1() {
  scenario "R1. A marker from an old run, then new data and backups: BACKUP=latest must not mean the old set"
  reset
  take_backups
  local old_i old_d new_i new_d before
  old_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  old_d="$(ls "$H/.local/backups/dev" | tail -1)"
  lose_cluster
  printf '2' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  check "fixture: a run that could not prove everything keeps its marker" test "$RC" -eq 2
  rm -f "$H/state/smoke-rc-verify"
  plane_counts 99
  take_backups
  new_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  new_d="$(ls "$H/.local/backups/dev" | tail -1)"
  check "fixture: a newer complete set" test "$new_i" != "$old_i"
  lose_cluster
  before="$(cat "$H/.local/restore-clean.state")"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the cluster gone, BACKUP=latest: refuses (got $RC)" test "$RC" -eq 1
  show_tail 1
  check "names the set under way" out_has "Infisical backup $old_i"
  check "names the newer one" out_has "a newer complete set exists: $new_i"
  check "says how to resume" out_has "make restore-clean BACKUP=$old_i"
  check "says how to start over" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  check "says it changed nothing" out_has "Nothing was changed"
  check "and it did not" no_log 'kind create|kc apply|kc scale'
  check "does not call it complete" no_clean_complete
  check "the marker is as it was" test "$before" = "$(cat "$H/.local/restore-clean.state")"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan refuses the same (got $RC)" test "$RC" -eq 1
  check "and names the newer one" out_has "a newer complete set exists: $new_i"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean "$old_i"
  check "BACKUP=<the id under way> is asked for by name, and goes on, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "from the beginning, since the cluster is gone" log_has 'kc apply Job plane-restore ns=infisical'
  check "and it restored the old data, as asked" test "$(cluster_value '.users["plane-dev"]')" = 23
  check "and the plan said what that leaves out" out_has "backup dev/$new_d was taken after dev/$old_d"

  reset
  take_backups
  old_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  lose_cluster
  printf '2' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  rm -f "$H/state/smoke-rc-verify"
  plane_counts 99
  take_backups
  new_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the platform is up, with a marker kept and a newer set: refuses too (got $RC)" test "$RC" -eq 1
  check "and it repaired nothing" no_log 'kc delete job|kc scale|kc patch'
  check "and says what the way to start over deletes" out_has "which deletes the cluster that is here"
  check "and how to end the restore and delete nothing" out_has "rm .local/restore-clean.state ends it and deletes nothing"
  lose_cluster
  run env CONFIRM=yes SKIP_BACKUP=yes scripts/destroy.sh
  run scripts/restore.sh clean latest
  check "the way to start over works, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "and latest then means the newest" jq -e --arg i "$new_i" '.infisical_backup == $i' "$(newest_evidence restore-clean)"
  check "with its data" test "$(cluster_value '.users["plane-dev"]')" = 99

  # The set is the newest, and the cluster is gone, so nothing that run finished counts, and it chose older Plane backups.
  reset
  take_backups
  old_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  old_d="$(ls "$H/.local/backups/dev" | tail -1)"
  lose_cluster
  printf '2' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  rm -f "$H/state/smoke-rc-verify"
  plane_counts 99
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  new_d="$(ls "$H/.local/backups/dev" | tail -1)"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the set the same, a newer Plane backup, the cluster gone: refuses (got $RC)" test "$RC" -eq 1
  check "names both" out_has "dev/$old_d against the newer dev/$new_d"
  check "says how to go on with what it chose" out_has "make restore-clean BACKUP=$old_i"
  check "and how to start over" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  check "and nothing ran" no_log 'kind create|kc apply|kc scale'
}

R2() {
  scenario "R2. A resume does not overwrite what an environment holds, unless that is this backup part way through"
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fixture: prod-sim's Job fails, and dev is done" grep -qx 'done dev' "$H/.local/restore-clean.state"
  rm -f "$H/state/fail-jobs.json"
  cluster_holds plane-prod-sim 500 777
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "500 users and 777 objects where the backup has 23 and 1: refuses (got $RC)" test "$RC" -ne 0
  show_tail 1
  check "with both counts" out_has "plane-prod-sim holds 500 users and 777 objects where backup"
  check "and the way past it, for this environment" out_has "ALLOW_RESUME_OVERWRITE=prod-sim"
  check "and how to keep what is there" out_has "make backup ENV=prod-sim ALLOW_BACKUP_DURING_RESTORE=yes"
  check "nothing was stopped" no_log 'kc scale deployment/plane-api-wl --replicas=0 ns=plane-prod-sim'
  check "nothing was replaced" no_log 'kc apply Job plane-restore ns=plane-prod-sim'
  check "it still holds 500" test "$(cluster_value '.users["plane-prod-sim"]')" = 500
  check "the marker stays" test -f "$H/.local/restore-clean.state"
  check "the evidence of that step says it failed" jq -e '.result == "FAIL"' "$(newest_evidence restore-prod-sim)"
  cluster_holds plane-prod-sim 23 777
  run scripts/restore.sh clean latest
  check "the same users and more objects than the backup: refuses (got $RC)" test "$RC" -ne 0
  cluster_holds plane-prod-sim 500 0
  run scripts/restore.sh clean latest
  check "other users and no objects: refuses (got $RC)" test "$RC" -ne 0
  cluster_holds plane-prod-sim 500 777
  : > "$H/state/calls.log"
  run env ALLOW_RESUME_OVERWRITE=prod-sim scripts/restore.sh clean latest
  check "ALLOW_RESUME_OVERWRITE=prod-sim goes on, and it is not a pass, exit 4 (got $RC)" test "$RC" -eq 4
  show_tail 4
  check "and overwrites" log_has 'kc apply Job plane-restore ns=plane-prod-sim'
  check "and the evidence says what it held, and does not read as a pass" jq -e 'any(.steps[]; .step == "overwrite-guard" and .status == "FAIL" and (.detail | test("500 users and 777 objects")))' "$(newest_evidence restore-prod-sim)"
  check "and dev, already done, was left alone" no_log 'kc apply Job plane-restore ns=plane-dev'

  local users objects
  for users in 23 0; do
    for objects in 1 0; do
      [[ "$users/$objects" != 0/0 ]] || continue
      reset
      take_backups
      lose_cluster
      printf '[["plane-restore-2","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
      run scripts/restore.sh clean latest
      rm -f "$H/state/fail-jobs.json"
      cluster_holds plane-prod-sim "$users" "$objects"
      : > "$H/state/calls.log"
      run scripts/restore.sh clean latest
      check "$users users and $objects objects, this backup part way through: resumes, exit 0 (got $RC)" test "$RC" -eq 0
      show_tail
      check "$users users and $objects objects: restored" log_has 'kc apply Job plane-restore ns=plane-prod-sim'
      check "$users users and $objects objects: the guard says what it saw" jq -e 'any(.steps[]; .step == "overwrite-guard" and .status == "PASS" and (.detail | test("part way through")))' "$(newest_evidence restore-prod-sim)"
    done
  done

  # Infisical too: it holds only a few users, so it is a weaker check, and it is the same one.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fixture: Infisical's Job fails" test "$RC" -ne 0
  rm -f "$H/state/fail-jobs.json"
  cluster_holds infisical 7 0
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "Infisical holds 7 users where the backup has 1: refuses (got $RC)" test "$RC" -ne 0
  check "and did not stop the server" no_log 'kc scale deployment/infisical --replicas=0'
  cluster_holds infisical 1 0
  run scripts/restore.sh clean latest
  check "Infisical holds what the backup does: resumes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail

  # A first run has not been asked: in place, CONFIRM=yes means what it says.
  reset
  take_backups
  cluster_holds plane-dev 500 777
  run scripts/restore.sh dev latest CONFIRM=yes
  check "in place, with CONFIRM=yes: overwrites as it always did, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
}

R3() {
  scenario "R3. A failed Infisical set does not pair the newest complete set with older Plane backups"
  reset
  take_backups
  local first_i first_d first_p bad_i second_d second_p second_i
  first_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  first_d="$(ls "$H/.local/backups/dev" | tail -1)"
  plane_counts 99
  stop_api
  ( cd "$H" && scripts/backup.sh all ) > "$H/state/o8.txt" 2>&1
  check "fixture: make backup ENV=all fails on Infisical's set, and goes on to Plane" test "$?" -ne 0
  /bin/sleep 1
  start_api
  rm -f "$H/state/plane-counts.json"
  bad_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  second_d="$(ls "$H/.local/backups/dev" | tail -1)"
  second_p="$(ls "$H/.local/backups/prod-sim" | tail -1)"
  check "fixture: a newer Infisical backup with no complete set" test "$bad_i" != "$first_i"
  check "fixture: a newer dev backup" test "$second_d" != "$first_d"
  lose_cluster
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan goes through (got $RC)" test "$RC" -eq 0
  show_tail
  check "the newest complete set is the first" out_has "Infisical  $first_i"
  check "and the failed set does not end its window: dev is the newer one" out_has "dev        $second_d"
  check "prod-sim too" out_has "prod-sim   $second_p"
  check "with 99 users" out_has "99 users, 16 workspaces"

  # The newest complete set is an older one, by name, so a newer Plane backup is left out. Say so.
  reset
  take_backups
  first_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  first_d="$(ls "$H/.local/backups/dev" | tail -1)"
  first_p="$(ls "$H/.local/backups/prod-sim" | tail -1)"
  plane_counts 99
  take_backups
  rm -f "$H/state/plane-counts.json"
  second_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  second_d="$(ls "$H/.local/backups/dev" | tail -1)"
  second_p="$(ls "$H/.local/backups/prod-sim" | tail -1)"
  run scripts/restore.sh clean "$first_i" PLAN_ONLY=yes
  check "an older set by name still takes the Plane backups of its own run" out_has "dev        $first_d"
  check "and warns about the newer dev backup, by name" out_has "backup dev/$second_d was taken after dev/$first_d"
  check "with what it holds" out_has "it holds 99 users"
  check "and the option that picks it" out_has "BACKUP_DEV=$second_d"
  check "and for prod-sim" out_has "BACKUP_PROD_SIM=$second_p"
  run env "BACKUP_DEV=$second_d" scripts/restore.sh clean "$first_i" PLAN_ONLY=yes
  check "having picked it, no such warning for dev" no_out "backup dev/$second_d was taken after"
  check "and still for prod-sim" out_has "backup prod-sim/$second_p was taken after"
  run scripts/restore.sh clean "$second_i" PLAN_ONLY=yes
  check "the newest of each: no such warning" no_out "was taken after"
  # A newer backup this Infisical cannot decrypt is no alternative.
  jq '.secret_key_fp = "0000000000000000"' "$H/.local/backups/dev/$second_d/manifest.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/backups/dev/$second_d/manifest.json"
  reseal "$H/.local/backups/dev/$second_d" manifest.json
  run scripts/restore.sh clean "$first_i" PLAN_ONLY=yes
  check "a newer dev backup with another SECRET_KEY is not named" no_out "BACKUP_DEV=$second_d"
}

# The stub logs a Job before it records it, so a stop that came on the log line alone could beat the record.
wait_for_running_job() {
  local waited=0
  until jq -e 'any(.[]; .state == "Running")' "$H/state/jobs.json" >/dev/null 2>&1 || [[ "$waited" -gt 900 ]]; do
    /bin/sleep 0.2
    waited=$((waited + 1))
  done
}

R4() {
  scenario "R4. The client ends while a restore Job runs: the Job goes first, and nothing starts over it"
  local sig job_count
  for sig in TERM INT HUP; do
    reset
    take_backups
    printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
    : > "$H/state/calls.log"
    start_detached scripts/restore.sh infisical latest CONFIRM=yes
    wait_for_log 'kc apply Job plane-restore ns=infisical'
    wait_for_running_job
    stop_detached "$sig"
    job_count="$(jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json")"
    check "Infisical, SIG$sig: not a pass (got $RC)" test "$RC" -ne 0
    check "Infisical, SIG$sig: no Job is left running" test "$job_count" = 0
    check "Infisical, SIG$sig: the Job goes first, then the flush, then the server, then auto-sync" order 'kc delete job plane-restore ns=infisical' 'kc exec redis FLUSHALL ns=infisical' 'kc scale deployment/infisical --replicas=1 ns=infisical' 'kc patch application infisical resume'
    check "Infisical, SIG$sig: nothing started over a running Job" no_log '^ERROR'
    check "Infisical, SIG$sig: it says what state that leaves" out_has "its Job was stopped before it finished"
    check "Infisical, SIG$sig: and that running it again restores it" out_has "running this again restores it"
    check "Infisical, SIG$sig: the evidence says FAIL" jq -e '.result == "FAIL" and any(.steps[]; .step == "restore-job-stopped")' "$(newest_evidence restore-infisical)"
    check "Infisical, SIG$sig: and the server is back" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$INFISICAL_URL/api/status")" = 200
  done

  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached scripts/restore.sh dev latest CONFIRM=yes
  wait_for_log 'kc apply Job plane-restore ns=plane-dev'
  wait_for_running_job
  stop_detached TERM
  check "dev: not a pass (got $RC)" test "$RC" -ne 0
  check "dev: no Job is left running" test "$(jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json")" = 0
  check "dev: the Job goes first, then auto-sync, root last" order 'kc delete job plane-restore ns=plane-dev' 'kc patch application plane-dev resume' 'kc patch application root resume'
  check "dev: nothing started over a running Job" no_log '^ERROR'

  # The migrator's Job has the labels of the rendered one, and it is this run's too.
  reset
  take_backups
  printf '[["plane-restore-migrate","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached scripts/restore.sh dev latest CONFIRM=yes
  wait_for_log 'kc apply Job plane-restore-migrate ns=plane-dev'
  wait_for_running_job
  stop_detached TERM
  check "the migrator's Job: no Job is left running" test "$(jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json")" = 0
  check "the migrator's Job: removed before auto-sync" order 'kc delete job plane-restore-migrate ns=plane-dev' 'kc patch application plane-dev resume'
  check "the migrator's Job: nothing started over it" no_log '^ERROR'

  # A kubectl error while it polls ends the client as a signal does.
  reset
  take_backups
  printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
  printf 'infisical get job plane-restore-[0-9tz]+ -o json$\n' > "$H/state/kubectl-fail"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "a kubectl error while it polls: not a pass (got $RC)" test "$RC" -ne 0
  show_tail 1
  check "a kubectl error while it polls: the Job goes first" order 'kc delete job plane-restore ns=infisical' 'kc scale deployment/infisical --replicas=1 ns=infisical' 'kc patch application infisical resume'
  check "a kubectl error while it polls: nothing started over it" no_log '^ERROR'

  # It cannot be removed, or it cannot be told. Then nothing comes back, and it says so.
  local failing
  for failing in 'delete job' 'get job .*--ignore-not-found'; do
    reset
    take_backups
    printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
    printf '%s\n' "$failing" > "$H/state/kubectl-fail"
    : > "$H/state/calls.log"
    start_detached scripts/restore.sh infisical latest CONFIRM=yes
    wait_for_log 'kc apply Job plane-restore ns=infisical'
    wait_for_running_job
    stop_detached TERM
    check "kubectl fails on '$failing': not a pass (got $RC)" test "$RC" -ne 0
    check "kubectl fails on '$failing': the server stays down" no_log 'kc scale deployment/infisical --replicas=1'
    check "kubectl fails on '$failing': auto-sync stays paused" no_log 'kc patch application infisical resume'
    check "kubectl fails on '$failing': nothing started over it" no_log '^ERROR'
    check "kubectl fails on '$failing': it says so" out_has "COULD NOT REMOVE these restore Jobs"
    check "kubectl fails on '$failing': and what to run, Job first" out_has "delete job plane-restore-"
    check "kubectl fails on '$failing': the server next" out_has "kubectl -n infisical scale deployment/infisical --replicas=1"
    check "kubectl fails on '$failing': then auto-sync" out_has 'kubectl -n argocd patch application infisical --type json'
    check "kubectl fails on '$failing': and it does not say auto-sync is back" no_out "Auto-sync is back on"
  done

  # In a clean restore, and the resume then finishes it.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached scripts/restore.sh clean latest
  wait_for_log 'kc apply Job plane-restore ns=plane-dev'
  wait_for_running_job
  stop_detached TERM
  rm -f "$H/state/hang-jobs.json"
  check "a clean restore, stopped in dev's Job: not a pass (got $RC)" test "$RC" -ne 0
  check "a clean restore: no Job is left running" test "$(jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json")" = 0
  check "a clean restore: the Job goes first" order 'kc delete job plane-restore ns=plane-dev' 'kc patch application plane-dev resume'
  check "a clean restore: nothing started over it" no_log '^ERROR'
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a clean restore: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail

  # A hard stop runs no trap, and the migrator's Job carries no restore label.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached scripts/restore.sh clean latest
  wait_for_log 'kc apply Job plane-restore-migrate ns=plane-dev'
  wait_for_running_job
  stop_detached KILL
  rm -f "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "SIGKILL in the migrator's Job: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "SIGKILL in the migrator's Job: the resume removes it first" order 'kc delete job plane-restore-migrate ns=plane-dev' 'kc patch application plane-dev resume' 'kc apply Job plane-restore-migrate ns=plane-dev'
  check "SIGKILL in the migrator's Job: nothing started over it" no_log '^ERROR'

  # A repair starts things again, so it must not read a kubectl error as no Job there.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  printf 'plane-dev get jobs\n' > "$H/state/kubectl-fail"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a resume that cannot list the Jobs: stops (got $RC)" test "$RC" -ne 0
  check "a resume that cannot list the Jobs: says so" out_has "so this cannot tell whether a restore Job is still running there"
  check "a resume that cannot list the Jobs: starts nothing" no_log 'kc scale|kc patch application|tf local apply'
  check "a resume that cannot list the Jobs: the marker stays" test -f "$H/.local/restore-clean.state"
}

R5() {
  scenario "R5. What protects a live platform does not fail open on a kubectl error"
  reset
  take_backups
  printf ' get pvc\n' > "$H/state/kubectl-fail"
  printf 'admin/config\n' > "$H/state/curl-fail"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan says a real run would refuse (got $RC)" out_has "a real run would refuse right now"
  check "and why" out_has "cannot tell what it holds"
  run scripts/restore.sh clean latest
  check "a real run refuses (got $RC)" test "$RC" -ne 0
  show_tail 1
  check "and why" out_has "cannot tell what it holds"
  check "says it changed nothing" out_has "Nothing was changed"
  check "no marker" test ! -e "$H/.local/restore-clean.state"
  check "nothing was overwritten" no_log 'kc apply Job plane-restore|kc scale|kc patch'
  check "not complete" no_clean_complete

  # One namespace is enough, and so is Infisical's when it does not answer.
  reset
  take_backups
  printf 'plane-prod-sim get pvc\n' > "$H/state/kubectl-fail"
  printf 'admin/config\n' > "$H/state/curl-fail"
  edit_cluster 'c["plane_pvcs"] = False'
  run scripts/restore.sh clean latest
  check "prod-sim's listing alone fails: refuses (got $RC)" test "$RC" -ne 0
  check "prod-sim's listing alone fails: names it" out_has "volumes in namespace plane-prod-sim"
  reset
  take_backups
  printf 'infisical get pvc data-infisical\n' > "$H/state/kubectl-fail"
  printf 'admin/config\n' > "$H/state/curl-fail"
  edit_cluster 'c["plane_pvcs"] = False'
  run scripts/restore.sh clean latest
  check "Infisical's listing fails, and it does not answer: refuses (got $RC)" test "$RC" -ne 0
  check "Infisical's listing fails: says so" out_has "volumes in namespace infisical"
  reset
  take_backups
  printf 'admin/config\n' > "$H/state/curl-fail"
  edit_cluster 'c["plane_pvcs"] = False'
  run scripts/restore.sh clean latest
  check "Infisical's volume there, and it does not answer: refuses (got $RC)" test "$RC" -ne 0
  check "Infisical's volume there: says it cannot tell" out_has "has an Infisical database, and Infisical does not answer, so this cannot tell what it holds"
  # No such volume is an answer. S28 has the plan for an empty cluster, and this has a run.
  reset
  take_backups
  empty_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "truly no volumes: an empty cluster goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
}

R6() {
  scenario "R6. Retention, on real folders: backups of an empty environment do not push out the last one with users"
  reset
  take_backups
  local real later
  real="$(ls "$H/.local/backups/dev" | tail -1)"
  plane_counts 0
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  run scripts/backup.sh dev
  /bin/sleep 1
  check "the backup says what it holds" out_has "this backup holds 0 users"
  check "three backups of an empty dev, KEEP=3: the one with users is still there" test -d "$H/.local/backups/dev/$real"
  check "and the three" test "$(ls "$H/.local/backups/dev" | wc -l | tr -d ' ')" -eq 4
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "and the plan names it" out_has "dev/$real holds 23 users"
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  check "a fourth: the one with users stays, and the oldest empty one goes" test "$(ls "$H/.local/backups/dev" | wc -l | tr -d ' ')" -eq 4
  check "that one is still there" test -d "$H/.local/backups/dev/$real"
  run env KEEP=1 scripts/backup.sh dev
  /bin/sleep 1
  check "KEEP=1: the newest and the one with users" test "$(ls "$H/.local/backups/dev" | wc -l | tr -d ' ')" -eq 2
  check "KEEP=1: that one is still there" test -d "$H/.local/backups/dev/$real"
  rm -f "$H/state/plane-counts.json"
  run scripts/backup.sh dev
  /bin/sleep 1
  later="$(ls "$H/.local/backups/dev" | tail -1)"
  check "a newer one with users: exit 0 (got $RC)" test "$RC" -eq 0
  run scripts/backup.sh dev KEEP=1
  /bin/sleep 1
  check "once a newer one holds users, the old one goes by count like any other, at KEEP=1" test "$(ls "$H/.local/backups/dev" | wc -l | tr -d ' ')" -eq 1
  check "and it is gone" test ! -e "$H/.local/backups/dev/$real"
  check "fixture: a later backup with users existed" test "$later" != "$real"

  # In place, a 0-user backup over real data says so, with or without CONFIRM.
  reset
  take_backups
  real="$(ls "$H/.local/backups/dev" | tail -1)"
  plane_counts 0
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  rm -f "$H/state/plane-counts.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh dev latest
  check "in place, no CONFIRM: refuses" test "$RC" -ne 0
  check "in place, no CONFIRM: warns" out_has "holds 0 users, so it looks like a backup of an empty platform, and plane-dev holds 23"
  check "in place, no CONFIRM: names the way to the real one" out_has "BACKUP=$real restores that one"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "in place, CONFIRM=yes: warns" out_has "holds 0 users, so it looks like a backup of an empty platform, and plane-dev holds 23"
  check "in place, CONFIRM=yes: the evidence says what it overwrote with" jq -e 'any(.steps[]; .step == "overwrite-guard" and (.detail | test("23 users and 1 objects.*0 users")))' "$(newest_evidence restore-dev)"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "a 0-user backup into what is already empty: nothing to warn about" no_out "looks like a backup of an empty platform"

  # While a restore is under way, an environment it has not finished is not worth a backup.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  check "fixture: a restore half done" grep -qx 'done dev' "$H/.local/restore-clean.state"
  local before_count
  before_count="$(ls "$H/.local/backups/prod-sim" | wc -l | tr -d ' ')"
  : > "$H/state/calls.log"
  run scripts/backup.sh prod-sim
  check "a backup of what it has not finished: refuses (got $RC)" test "$RC" -ne 0
  check "and says why, without claiming to have looked" out_has "This has not looked at what prod-sim holds"
  check "and does not call it empty or partly restored as a fact" no_out "which is empty or partly restored"
  check "and does not send a person to SKIP_BACKUP without saying what it loses" out_has "with SKIP_BACKUP=yes it deletes what is there with no backup"
  check "and the way past it" out_has "ALLOW_BACKUP_DURING_RESTORE=yes"
  check "and no Job ran" no_log 'kc apply Job plane-backup'
  run scripts/backup.sh dev
  check "a backup of what it has finished: goes ahead (got $RC)" test "$RC" -eq 0
  check "and says a restore is under way" out_has "it has finished dev, so this backup goes ahead"
  run scripts/backup.sh all
  check "make backup ENV=all: refuses for the part it cannot do (got $RC)" test "$RC" -ne 0
  check "make backup ENV=all: and prod-sim has no new backup" test "$(ls "$H/.local/backups/prod-sim" | wc -l | tr -d ' ')" -eq "$before_count"
  /bin/sleep 1
  run env ALLOW_BACKUP_DURING_RESTORE=yes scripts/backup.sh prod-sim
  check "the override goes ahead (got $RC)" test "$RC" -eq 0
  check "the override: a new backup" test "$(ls "$H/.local/backups/prod-sim" | wc -l | tr -d ' ')" -gt "$before_count"
}

R7() {
  scenario "R7. The drill: a refusal comes before the delete"
  reset
  take_backups
  local iid
  iid="$(ls "$H/.local/backups/infisical" | tail -1)"
  write_marker infisical
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes LOSE_CLUSTER=yes tests/drills/clean-restore.sh
  check "a marker: the drill stops (got $RC)" test "$RC" -ne 0
  check "a marker: deletes nothing" no_log 'kind delete cluster'
  check "a marker: backs up nothing first" no_log 'kc apply Job plane-backup'
  check "a marker: stage 0 says so" out_has "is still marked as under way"
  check "a marker: names the backup" out_has "Infisical backup $iid"
  check "a marker: how to finish it" out_has "make restore-clean BACKUP=<that id> finishes it"
  check "a marker: how to clear it, deleting nothing" out_has "rm .local/restore-clean.state, which deletes nothing"
  check "a marker: and what the other way costs" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes removes it too, with the cluster"
  check "a marker: says nothing was deleted" out_has "Nothing was deleted"
  check "a marker: no talk of a cluster that is gone" no_out "The cluster is gone"
  run env PLAN_ONLY=yes tests/drills/clean-restore.sh
  check "a marker, PLAN_ONLY=yes: stops too (got $RC)" test "$RC" -ne 0
  check "a marker, PLAN_ONLY=yes: says why" out_has "is still marked as under way"

  reset
  touch "$H/state/registry-down"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "the registry stopped: the drill stops (got $RC)" test "$RC" -ne 0
  check "the registry stopped: deletes nothing" no_log 'kind delete cluster'
  check "the registry stopped: says the registry does not answer" out_has "the local registry does not answer"
  check "the registry stopped: and how to start it" out_has "make up UP_STOP_AFTER=cluster"
  check "the registry stopped: and that nothing was deleted" out_has "nothing was deleted"
  run env CONFIRM=yes SKIP_E2E=yes LOSE_CLUSTER=yes tests/drills/clean-restore.sh
  check "the registry stopped, LOSE_CLUSTER=yes: stops too" test "$RC" -ne 0
  check "the registry stopped, LOSE_CLUSTER=yes: deletes nothing" no_log 'kind delete cluster'
  reset
  take_backups
  touch "$H/state/registry-down"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the registry stopped, a plan on a live cluster: refuses (got $RC)" test "$RC" -ne 0
  check "the registry stopped, a plan on a live cluster: says why" out_has "the local registry does not answer"
  check "the registry stopped, a plan on a live cluster: nothing started" no_log 'docker compose'

  # What else stage 0 stops on, each before any backup or delete.
  reset
  leave_scaled 0 plane-dev/plane-api-wl
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "an Application not Healthy: stage 0 stops (got $RC)" test "$RC" -ne 0
  check "an Application not Healthy: names it" out_has "plane-dev=OutOfSync"
  check "an Application not Healthy: deletes nothing" no_log 'kind delete cluster'
  reset
  rm "$H/.local/test-sentinel-prod-sim.json"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "no sentinel for prod-sim: stage 0 stops (got $RC)" test "$RC" -ne 0
  check "no sentinel for prod-sim: says so" out_has "no sentinel for prod-sim"
  check "no sentinel for prod-sim: deletes nothing" no_log 'kind delete cluster'
  reset
  grep -v '^PLANE_DEV_API_TOKEN=' "$H/.local/test-accounts.env" > "$H/state/t" && cp "$H/state/t" "$H/.local/test-accounts.env"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "no API token for dev: stage 0 stops (got $RC)" test "$RC" -ne 0
  check "no API token for dev: says so" out_has "no API token in .local/test-accounts.env for: dev"
  check "no API token for dev: deletes nothing" no_log 'kind delete cluster'
}

# A whole drill each, so tests/drills/clean-restore-mutants.sh can ask for the one that matters with R8D_ONLY.
drill_wanted() { [[ -z "${R8D_ONLY:-}" || "$1" == *"$R8D_ONLY"* ]]; }

# A drill whose comparison has been given something that differs. A hook runs between the restore that finished and
# the comparison, so only the drill's own look can catch it.
drill_catches() { # what fail-line hook [option...]
  local what="$1" line="$2" hook="$3"
  shift 3
  drill_wanted "$what" || return 0
  reset
  printf '%s\n' "$hook" > "$H/state/post-restore-hook"
  run env CONFIRM=yes SKIP_E2E=yes "$@" tests/drills/clean-restore.sh
  check "$what: the drill fails (got $RC)" test "$RC" -ne 0
  check "$what: on that comparison" fail_line_has "$line"
  check "$what: the restore itself had finished" out_has "PASS  scripts/restore.sh clean"
}

# The same across the delete, with a hook the delete itself runs.
drill_catches_at_delete() { # what fail-line hook [option...]
  local what="$1" line="$2" hook="$3"
  shift 3
  drill_wanted "$what" || return 0
  reset
  printf '%s\n' "$hook" > "$H/state/kind-delete-hook"
  run env CONFIRM=yes SKIP_E2E=yes "$@" tests/drills/clean-restore.sh
  check "$what: the drill fails (got $RC)" test "$RC" -ne 0
  check "$what: on that comparison" fail_line_has "$line"
}

R8() {
  scenario "R8. What the harness did not look at: the guard, a proof that fails, each comparison in verify and in the drill"
  # The guard, in place.
  reset
  take_backups
  : > "$H/state/calls.log"
  run scripts/restore.sh dev latest
  check "the guard: refuses with no CONFIRM (got $RC)" test "$RC" -ne 0
  check "the guard: says what is there" out_has "plane-dev already holds data (23 users, 1 objects)"
  check "the guard: says how" out_has "Re-run with CONFIRM=yes"
  check "the guard: nothing was stopped" no_log 'kc scale'
  check "the guard: nothing was paused" no_log 'kc patch application'
  check "the guard: nothing was replaced" no_log 'kc apply Job plane-restore ns=plane-dev'
  check "the guard: says nothing changed" out_has "refused, as said above. Nothing was changed"
  check "the guard: asked the database and the bucket" order 'kc apply Job plane-restore-guard ns=plane-dev' 'kc apply Job plane-restore-guard-objects ns=plane-dev'
  cluster_holds plane-dev 0 1
  run scripts/restore.sh dev latest
  check "the guard: objects alone count as data" test "$RC" -ne 0
  cluster_holds plane-dev 1 0
  run scripts/restore.sh dev latest
  check "the guard: users alone count as data" test "$RC" -ne 0
  cluster_holds plane-dev 0 0
  run scripts/restore.sh dev latest
  check "the guard: an empty target needs no CONFIRM, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the guard: and the evidence says so" jq -e 'any(.steps[]; .step == "overwrite-guard" and .status == "PASS" and .detail == "target is empty")' "$(newest_evidence restore-dev)"
  reset
  take_backups
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest
  check "the guard, Infisical: refuses with no CONFIRM (got $RC)" test "$RC" -ne 0
  check "the guard, Infisical: says what is there" out_has "infisical already holds data (1 users"
  check "the guard, Infisical: nothing was stopped" no_log 'kc scale'

  # A proof that fails, and an order that is not only a list.
  reset
  take_backups
  printf '@@SENTINEL=wrong\n@@ROWS=1\n@@UNDECRYPTABLE=\n' > "$H/state/proof-decrypt-output"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "the decrypt proof finds the sentinel wrong: fails (got $RC)" test "$RC" -ne 0
  check "the decrypt proof: its step says so" step_status_is "$(newest_evidence restore-dev)" proof-encrypted-sentinel FAIL
  printf '@@SENTINEL=ok\n@@ROWS=7\n@@UNDECRYPTABLE=KEY_A,KEY_B\n' > "$H/state/proof-decrypt-output"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "rows that decrypt to nothing: fails (got $RC)" test "$RC" -ne 0
  check "rows that decrypt to nothing: says which" jq -e 'any(.steps[]; .step == "proof-no-empty-decrypt" and .status == "FAIL" and (.detail | test("KEY_A,KEY_B")))' "$(newest_evidence restore-dev)"
  rm -f "$H/state/proof-decrypt-output"
  printf '1' > "$H/state/smoke-rc-proof"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "the sentinel proof fails: fails (got $RC)" test "$RC" -ne 0
  check "the sentinel proof: its step says so" step_status_is "$(newest_evidence restore-dev)" proof-sentinel FAIL
  rm -f "$H/state/smoke-rc-proof"
  : > "$H/state/calls.log"
  touch "$H/state/rabbitmq-no-queue"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "no queue to purge: fine, exit 0 (got $RC)" test "$RC" -eq 0
  check "no queue to purge: nothing purged" no_log 'kc exec rabbitmq purge'
  rm -f "$H/state/rabbitmq-no-queue"

  # What verify compares, at the end of a clean restore, when something differs by then and did not before.
  reset
  take_backups
  lose_cluster
  # Only verify compares these on a clean restore, so this differs from the start and only verify can see it.
  printf 'plane-dev plane-rabbitmq RABBITMQ_DEFAULT_PASS\n' > "$H/state/rendered-tamper"
  run scripts/restore.sh clean latest
  check "a rendered Secret differs at verify: exit 1 (got $RC)" test "$RC" -eq 1
  check "a rendered Secret differs at verify: says which" jq -e 'any(.steps[]; .step == "verify-rendered-dev" and .status == "FAIL" and (.detail | test("RABBITMQ_DEFAULT_PASS")))' "$(newest_evidence restore-clean)"
  check "a rendered Secret differs at verify: the other environment passes" step_status_is "$(newest_evidence restore-clean)" verify-rendered-prod-sim PASS
  check "a rendered Secret differs at verify: the marker stays" test -f "$H/.local/restore-clean.state"
  check "a rendered Secret differs at verify: not complete" no_clean_complete
  check "a rendered Secret differs at verify: never prints a value" no_out "-differs"
  rm -f "$H/state/rendered-tamper"
  run scripts/restore.sh clean latest
  check "a rendered Secret differs at verify: with that gone, the same command passes (got $RC)" test "$RC" -eq 0
  show_tail

  reset
  take_backups
  lose_cluster
  # Rewrites a value in the running instance once Infisical's restore has passed its own proof, so only verify can see it.
  cat > "$H/state/tamper-values.py" <<'PY'
import json, os
s = os.environ["H_STATE"]
d = json.load(open(f"{s}/api.json"))
d["projects"]["p-prod"]["LIVE_SERVER_SECRET_KEY"]["version"] = 2
json.dump(d, open(f"{s}/api.json", "w"))
PY
  printf 'python3 -I "%s/state/tamper-values.py"\n' "$H" > "$H/state/smoke-proof-hook"
  run scripts/restore.sh clean latest
  check "a value rewritten after the restore: exit 1 (got $RC)" test "$RC" -eq 1
  check "a value rewritten after the restore: verify says which" jq -e 'any(.steps[]; .step == "verify-infisical-values" and .status == "FAIL" and (.detail | test("LIVE_SERVER_SECRET_KEY: rewritten")))' "$(newest_evidence restore-clean)"
  check "a value rewritten after the restore: the marker stays" test -f "$H/.local/restore-clean.state"

  reset
  take_backups
  lose_cluster
  printf '1' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  check "the sentinel fails at verify: exit 1 (got $RC)" test "$RC" -eq 1
  check "the sentinel fails at verify: its step says so" step_status_is "$(newest_evidence restore-clean)" verify-sentinel-dev FAIL
  rm -f "$H/state/smoke-rc-verify"

}

R8d() {
  scenario "R8d. Every comparison the drill makes, each with a stub that changes what it compares"
  local z="$H/.local/secret-zero" s="$H/state"
  if drill_wanted "the drill, the cluster CA the same"; then
    reset
    touch "$s/ca-constant"
    run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
    check "the drill, the cluster CA the same: fails (got $RC)" test "$RC" -ne 0
    check "the drill, the cluster CA the same: on that comparison" fail_line_has "the cluster CA did not change"
  fi
  drill_catches "the drill, ids in the machine file changed" "organization, project or identity ids changed" \
    "jq '.project_ids.dev = \"p-other\"' '$z/infisical-machine.json' > '$s/t' && cp '$s/t' '$z/infisical-machine.json'"
  drill_catches "the drill, a secret-zero file changed" "secret zero or the admin password changed" \
    "printf more >> '$z/DB_PASSWORD'"
  drill_catches "the drill, the admin file changed with no record" "the admin token file changed, and nothing records it" \
    "jq '.token = \"x.e30.other\"' '$z/infisical-admin.json' > '$s/t' && cp '$s/t' '$z/infisical-admin.json'"
  drill_catches "the drill, a new secret-zero archive" "new secret-zero archives" \
    "mkdir '$z/archive-20260101T000000Z'"
  drill_catches "the drill, a rendered Secret differs" "rendered Secrets differ" \
    "printf 'plane-dev plane-rabbitmq RABBITMQ_DEFAULT_PASS\n' > '$s/rendered-tamper'"
  drill_catches "the drill, the marker still there" "restore-clean.state is still there" \
    "printf 'infisical=x\n' > '$H/.local/restore-clean.state'"
  drill_catches "the drill, a restore's evidence is not all PASS" ".json: postgres FAIL" \
    "f=\"\$(ls '$H'/.local/evidence-raw/restore-dev-*.json | tail -1)\"; jq '(.steps[] | select(.step == \"postgres\") | .status) = \"FAIL\"' \"\$f\" > '$s/t' && cp '$s/t' \"\$f\""
  drill_catches "the drill, an Application not Healthy" "not Synced and Healthy: plane-dev=" \
    "jq '.workloads[\"plane-dev/plane-api-wl\"] = 0' '$s/cluster.json' > '$s/t' && cp '$s/t' '$s/cluster.json'"
  drill_catches "the drill, the state of a lost cluster not moved aside" "no sign that the state of the lost cluster was moved aside" \
    "rm -rf '$H'/.local/terraform/local.stale-*" LOSE_CLUSTER=yes
  drill_catches "the drill, restored mode still has changes" "bootstrap in restored mode still had Terraform changes" \
    "printf update > '$s/tf-scenario'"
  drill_catches "the drill, restored mode fails" "bootstrap in restored mode failed on its second run" \
    "printf fail > '$s/tf-scenario'"
  drill_catches "the drill, a plain bootstrap writes a secret" "plain bootstrap wrote secrets" \
    "jq 'del(.projects[\"p-dev\"].LIVE_SERVER_SECRET_KEY)' '$s/api.json' > '$s/t' && cp '$s/t' '$s/api.json'"

  # And what it compares across the delete.
  if drill_wanted "the drill, the delete leaves the cluster"; then
    reset
    touch "$s/kind-delete-does-nothing"
    run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
    check "the drill, the delete leaves the cluster: fails (got $RC)" test "$RC" -ne 0
    check "the drill, the delete leaves the cluster: on that comparison" fail_line_has "the cluster still exists"
  fi
  if drill_wanted "the drill, the local state survives the delete"; then
    reset
    perl -0pi -e 's/^rm -rf "\$LOCAL_DIR\/terraform\/local"\n//m' "$H/scripts/destroy.sh"
    run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
    check "the drill, the local state survives the delete: fails (got $RC)" test "$RC" -ne 0
    check "the drill, the local state survives the delete: on that comparison" fail_line_has "the local Terraform state survived"
  fi
  drill_catches_at_delete "the drill, secret zero changes in the delete" "secret zero changed in the delete" \
    "printf more >> '$z/DB_PASSWORD'"
  drill_catches_at_delete "the drill, the Infisical state goes in the delete" "Infisical Terraform state was deleted" \
    "rm -f '$H/.local/terraform/infisical/terraform.tfstate'"
  drill_catches_at_delete "the drill, a disaster with no state left behind" "so this did not test a disaster" \
    "rm -rf '$H/.local/terraform/local'" LOSE_CLUSTER=yes
}

R9() {
  scenario "R9. Disk: the plan counts what a new cluster still has to pull, plus the floor later scripts check"
  reset
  take_backups
  lose_cluster
  touch "$H/state/registry-volume-gone"
  set_disk 25
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "no registry or mirror volumes, 25 GiB: the plan refuses (got $RC)" test "$RC" -ne 0
  check "and shows the sum" out_has "a new cluster still has 17.75 GiB to pull"
  check "and what it asks for" out_has "so this asks for 27.75 GiB"
  set_disk 27
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "27 GiB: refuses" test "$RC" -ne 0
  set_disk 28
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "28 GiB: the plan passes (got $RC)" test "$RC" -eq 0
  # A first install takes its measured 17.75 GiB by the end of make up, and the restores after it check the floor.
  printf '%s' "$((1775 * 1048576 / 100))" > "$H/state/up-uses-kib"
  run scripts/restore.sh clean latest
  check "28 GiB: and the run goes through, past the floor, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  reset
  take_backups
  lose_cluster
  touch "$H/state/registry-volume-gone"
  set_disk 26
  printf '%s' "$((1775 * 1048576 / 100))" > "$H/state/up-uses-kib"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "26 GiB: a real run refuses before anything (got $RC)" test "$RC" -ne 0
  check "26 GiB: nothing ran" no_log 'kind create'
  run env "ALLOW_LOW_DISK=no volumes and short on room, and watching" scripts/restore.sh clean latest
  check "26 GiB with a reason: goes on, and stops at the floor, as said" test "$RC" -ne 0
  check "26 GiB with a reason: says so" out_has "need at least 10 GiB"
  check "26 GiB with a reason: logged" grep -F 'no volumes and short on room' "$H/.local/evidence-raw/low-disk-overrides.log"

  # The volumes there, and no cluster: up.sh's own number holds, which S28 has too.
  reset
  take_backups
  lose_cluster
  set_disk 25
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the volumes there, 25 GiB: the plan passes (got $RC)" test "$RC" -eq 0
  check "the volumes there: it asks what up.sh asks" out_has "up.sh asks for 25 GiB"

  # An empty cluster, with no volumes either.
  reset
  take_backups
  empty_cluster
  touch "$H/state/registry-volume-gone"
  set_disk 27
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "an empty cluster, no volumes, 27 GiB: refuses (got $RC)" test "$RC" -ne 0
  check "an empty cluster, no volumes: says what it still has to pull" out_has "this empty cluster still has 17.75 GiB to pull"
  set_disk 28
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "an empty cluster, no volumes, 28 GiB: passes (got $RC)" test "$RC" -eq 0
  # A resume on a cluster that stays has only the floor, which every script checks.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  set_disk 11
  run scripts/restore.sh clean latest
  check "a resume on its own cluster at 11 GiB: goes on, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
}

R10() {
  scenario "R10. The floor can be lowered, and that leaves a line. A reason has to say something"
  reset
  take_backups
  set_disk 7
  run scripts/restore.sh dev latest CONFIRM=yes
  check "7 GiB: stops at the floor (got $RC)" test "$RC" -ne 0
  check "7 GiB: says so" out_has "only 7 GiB free on the host, need at least 10 GiB"
  check "7 GiB: nothing logged, since nothing went past it" test ! -e "$H/.local/evidence-raw/low-disk-overrides.log"
  run env MIN_FREE_DISK_GIB=5 scripts/restore.sh dev latest CONFIRM=yes
  check "MIN_FREE_DISK_GIB=5 lowers it, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "and says so" out_has "MIN_FREE_DISK_GIB=5 lowers the 10 GiB floor"
  check "and logs it, with the script and what was free" grep -E 'restore\.sh: MIN_FREE_DISK_GIB=5 lowers the 10 GiB floor, with 7 GiB free' "$H/.local/evidence-raw/low-disk-overrides.log"
  set_disk 50
  rm -f "$H/.local/evidence-raw/low-disk-overrides.log"
  run env MIN_FREE_DISK_GIB=20 scripts/restore.sh dev latest CONFIRM=yes
  check "above the default: nothing to log" test ! -e "$H/.local/evidence-raw/low-disk-overrides.log"
  run env MIN_FREE_DISK_GIB=lots scripts/restore.sh dev latest CONFIRM=yes
  check "not a number: refuses (got $RC)" test "$RC" -ne 0
  check "not a number: says so" out_has "MIN_FREE_DISK_GIB takes a whole number"
  check "the README no longer says the floor has no override" test -z "$(grep -F 'floor, which has no override' "$SOURCE/infisical/README.md")"
  check "the README says what lowers it" grep -F 'MIN_FREE_DISK_GIB=<n>' "$SOURCE/infisical/README.md"
  check "up.sh's header says what lowers it" grep -F 'MIN_FREE_DISK_GIB=<n> lowers it' "$SOURCE/scripts/up.sh"

  local blank
  for blank in " " "   " $'\t' " one"; do
    reset
    set_disk 14
    : > "$H/state/calls.log"
    run env CONFIRM=yes SKIP_E2E=yes "ALLOW_LOW_DISK=$blank" tests/drills/clean-restore.sh
    check "ALLOW_LOW_DISK='$blank': the drill refuses (got $RC)" test "$RC" -ne 0
    check "ALLOW_LOW_DISK='$blank': before the delete" no_log 'kind delete cluster'
    check "ALLOW_LOW_DISK='$blank': says what it wants" out_has "ALLOW_LOW_DISK takes a reason in words"
  done
  reset
  lose_cluster
  set_disk 12
  run env "ALLOW_LOW_DISK= " scripts/up.sh
  check "ALLOW_LOW_DISK=' ': up.sh refuses too (got $RC)" test "$RC" -ne 0
  check "ALLOW_LOW_DISK=' ': up.sh says what it wants" out_has "ALLOW_LOW_DISK takes a reason in words"
}

R11() {
  scenario "R11. The printed way out with the registry empty: on the empty cluster it leads to, it has to work"
  reset
  take_backups
  local one
  one="$(grep -hoE 'localhost:5001/[^[:space:]"@]+@sha256:[a-f0-9]{64}' "$H/gitops/environments/prod-sim/manifests.yaml" | sort -u | head -1)"
  if [[ -z "$one" ]]; then
    fail "fixture: Git names no localhost:5001 digest for prod-sim, so this scenario proves nothing"
    return
  fi
  printf '%s\n' "$one" > "$H/state/registry-missing"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan prints the override in the promotion to prod-sim" out_has 'make promote ENV=prod-sim CONFIRM=yes SKIP_BACKUP=yes OVERRIDE_DEV_CHECK="restoring into an empty cluster"'
  check "the plan says why" out_has "plane-dev cannot have proven a digest"
  run scripts/up.sh
  check "up.sh prints it too" out_has 'make promote ENV=prod-sim CONFIRM=yes SKIP_BACKUP=yes OVERRIDE_DEV_CHECK="restoring into an empty cluster"'
  check "up.sh says when" out_has "On an empty cluster, as make up UP_STOP_AFTER=cluster leaves"
  check "and keeps the backup on a cluster that may hold data" grep -Fx '    make promote ENV=prod-sim CONFIRM=yes' "$OUT"
  # What promote.sh runs, on the empty cluster the printed step leaves, with that option and without it.
  reset
  lose_cluster
  run env UP_STOP_AFTER=cluster scripts/up.sh
  check "fixture: make up UP_STOP_AFTER=cluster leaves an empty cluster in reach (got $RC)" test "$RC" -eq 0
  touch "$H/.local/kubeconfig"
  cat > "$H/state/dev-check.sh" <<'SH'
source scripts/lib/common.sh
source scripts/lib/dev-check.sh
check_dev_proven backend=sha256:aaaa || refuse_unproven_dev "Nothing changed."
SH
  run /bin/bash state/dev-check.sh
  check "without the override, that cluster refuses" test "$RC" -ne 0
  run env 'OVERRIDE_DEV_CHECK=restoring into an empty cluster' /bin/bash state/dev-check.sh
  check "with the override as printed, it goes ahead (got $RC)" test "$RC" -eq 0
  show_tail
}

R12() {
  scenario "R12. A machine file from another instance is rebuilt, and kept"
  reset
  take_backups
  local z="$H/.local/secret-zero"
  jq '.project_ids.dev = "p-another-instance"' "$z/infisical-machine.json" > "$H/state/t" && cp "$H/state/t" "$z/infisical-machine.json"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a clean restore goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the file names the backup's ids" jq -e '.project_ids.dev == "p-dev"' "$z/infisical-machine.json"
  check "the old one is in an archive" grep -l 'p-another-instance' "$z"/archive-pre-restore-*/infisical-machine.json
  check "it does not call a wrong file harmless" no_out "A new one works"
  check "it says what it did" out_has "did not name the ids this backup does"
  check "no proof blamed the dump" jq -e 'any(.steps[]; .step == "proof-values" and .status == "PASS")' "$(newest_evidence restore-infisical)"

  reset
  take_backups
  jq '.identity_ids["prod-sim"] = "i-another-instance"' "$z/infisical-machine.json" > "$H/state/t" && cp "$H/state/t" "$z/infisical-machine.json"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "in place: goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "in place: the file names the backup's ids" jq -e '.identity_ids["prod-sim"] == "i-prod"' "$z/infisical-machine.json"
  check "in place: the old one is in an archive" grep -l 'i-another-instance' "$z"/archive-pre-restore-*/infisical-machine.json

  reset
  take_backups
  local before
  before="$(shasum -a 256 "$z/infisical-machine.json")"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "the right ids: left alone, byte for byte (got $RC)" test "$before" = "$(shasum -a 256 "$z/infisical-machine.json")"
  check "the right ids: no archive" test -z "$(find "$z" -maxdepth 1 -name 'archive-pre-restore-*')"

  # A state that does not agree with its own set is no better than the file it would replace.
  reset
  take_backups
  local id
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  jq '.outputs.project_ids.value.dev = "p-from-the-state"' "$H/.local/backups/infisical/$id/recovery/terraform.tfstate" > "$H/state/t" && cp "$H/state/t" "$H/.local/backups/infisical/$id/recovery/terraform.tfstate"
  reseal "$H/.local/backups/infisical/$id" recovery/terraform.tfstate
  jq '.project_ids.dev = "p-another-instance"' "$z/infisical-machine.json" > "$H/state/t" && cp "$H/state/t" "$z/infisical-machine.json"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "a state with other ids than its set: the file is left as it is" jq -e '.project_ids.dev == "p-another-instance"' "$z/infisical-machine.json"
  check "a state with other ids than its set: and it says so" out_has "does not name the ids its recovery set does"
}

R13() {
  scenario "R13. In place, Terraform's state and the machine file change when the database does, and not before"
  reset
  take_backups
  local state="$H/.local/terraform/infisical/terraform.tfstate" z="$H/.local/secret-zero" machine_before
  jq '.serial = 99' "$state" > "$H/state/t" && cp "$H/state/t" "$state"
  jq '.project_ids.dev = "p-newer"' "$z/infisical-machine.json" > "$H/state/t" && cp "$H/state/t" "$z/infisical-machine.json"
  machine_before="$(shasum -a 256 "$z/infisical-machine.json")"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "the Job fails: not a pass (got $RC)" test "$RC" -ne 0
  check "the Job fails: the state is still what it was" jq -e '.serial == 99' "$state"
  check "the Job fails: the machine file is too" test "$machine_before" = "$(shasum -a 256 "$z/infisical-machine.json")"
  check "the Job fails: it does not say the state matches" no_out "now matches this backup"
  rm -f "$H/state/fail-jobs.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "the Job passes: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the Job passes: the state is the backup's" jq -e '.serial == 12' "$state"
  check "the Job passes: the one it replaced is kept" test -n "$(find "$H/.local/terraform/infisical" -name 'terraform.tfstate.pre-restore-*')"
  check "the Job passes: and the state came after the swap, by the output's order" test "$(grep -n 'swapped in\|postgres: dump restored' "$OUT" | head -1 | cut -d: -f1)" -lt "$(grep -n 'now matches this backup' "$OUT" | head -1 | cut -d: -f1)"
}

R14() {
  scenario "R14. What the drill says when it fails depends on what is there"
  reset
  touch "$H/state/ca-constant"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "stage 6 fails, the platform up: fails (got $RC)" test "$RC" -ne 0
  check "stage 6 fails: RESULT FAIL" out_has "RESULT FAIL"
  check "stage 6 fails: no talk of a cluster that is gone" no_out "cluster is gone"
  check "stage 6 fails: and no advice that would be refused" no_out "Continue with: make restore-clean"
  reset
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "the restore fails on a new cluster: fails (got $RC)" test "$RC" -ne 0
  check "the restore fails on a new cluster: says the old one is gone, and the new one not finished" out_has "The old cluster is gone, and the restore into a new one did not finish"
  check "the restore fails on a new cluster: and how to go on" out_has "Continue with: make restore-clean BACKUP="
  reset
  touch "$H/state/kind-create-fails"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "no new cluster at all: fails (got $RC)" test "$RC" -ne 0
  check "no new cluster at all: says it is gone" out_has "The cluster is gone and the backups are intact"
  reset
  touch "$H/state/kind-delete-does-nothing"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "the delete left it there: fails (got $RC)" test "$RC" -ne 0
  check "the delete left it there: not called gone" no_out "The cluster is gone and the backups are intact"
}

R15() {
  scenario "R15. A marker whose backups have since been removed: a clear refusal, and the way to start over"
  reset
  take_backups
  local id
  id="$(ls "$H/.local/backups/dev" | tail -1)"
  lose_cluster
  write_marker infisical
  rm -rf "$H/.local/backups/dev/$id"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a Plane backup gone: refuses, exit 1 (got $RC)" test "$RC" -eq 1
  check "a Plane backup gone: names it" out_has "dev/$id"
  check "a Plane backup gone: says how to start over" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  check "a Plane backup gone: no raw cd error" no_out "No such file or directory"
  check "a Plane backup gone: no raw jq error" no_out "jq: error"
  check "a Plane backup gone: nothing ran" no_log 'kind create|kc apply|kc scale'
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a Plane backup gone: the plan refuses the same (got $RC)" test "$RC" -eq 1
  check "a Plane backup gone: the plan names it" out_has "dev/$id"
  run env CONFIRM=yes SKIP_BACKUP=yes scripts/destroy.sh
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "having started over, the marker is gone" test ! -e "$H/.local/restore-clean.state"
  check "and a plan speaks of what is here now: that backup was dev's only one" out_has "no backup of dev matches"

  reset
  take_backups
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  lose_cluster
  write_marker
  rm -rf "$H/.local/backups/infisical/$id"
  run scripts/restore.sh clean "$id"
  check "the Infisical set gone: refuses, exit 1 (got $RC)" test "$RC" -eq 1
  check "the Infisical set gone: names it" out_has "infisical/$id"
  check "the Infisical set gone: says how to start over" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  check "the Infisical set gone: no raw error" no_out "No such file or directory"

  reset
  take_backups
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  lose_cluster
  write_marker
  printf 'tampered' >> "$H/.local/backups/infisical/$id/recovery/set.json"
  run scripts/restore.sh clean latest
  check "the Infisical set damaged: refuses, exit 1 (got $RC)" test "$RC" -eq 1
  check "the Infisical set damaged: says so" out_has "no longer checks out"
  check "the Infisical set damaged: says how to start over" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"

  # The real way this happens: five later backups, each complete, and an old marker.
  reset
  take_backups
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  lose_cluster
  printf '2' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  rm -f "$H/state/smoke-rc-verify"
  for _ in 1 2 3 4 5; do
    ( cd "$H" && scripts/backup.sh infisical ) > /dev/null 2>&1
    /bin/sleep 1
  done
  check "fixture: retention took the set the marker names" test ! -e "$H/.local/backups/infisical/$id"
  run scripts/restore.sh clean latest
  check "retention took it: refuses, exit 1 (got $RC)" test "$RC" -eq 1
  check "retention took it: names it" out_has "infisical/$id"
  check "retention took it: and says what removes them" out_has "Retention does not know about a marker"
  check "retention took it: a cluster is here, so what the way over costs" out_has "which deletes the cluster that is here"

  # Nothing in the marker to go on.
  reset
  take_backups
  printf 'done infisical\n' > "$H/.local/restore-clean.state"
  run scripts/restore.sh clean latest
  check "a marker with no ids: refuses, exit 1 (got $RC)" test "$RC" -eq 1
  check "a marker with no ids: says so" out_has "does not say which backups it is restoring"
}

R16() {
  scenario "R16. A resume sees an in-place restore however it was started, and only one of this checkout"
  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached ./scripts/restore.sh dev latest CONFIRM=yes
  wait_for_log 'kc apply Job plane-restore ns=plane-dev'
  write_marker
  : > "$H/state/calls.log"
  run ./scripts/restore.sh clean latest
  check "./scripts/restore.sh running in place: the resume refuses (got $RC)" test "$RC" -ne 0
  check "./scripts/restore.sh running in place: says so" out_has "a restore from an earlier run is still going here"
  check "./scripts/restore.sh running in place: names the pid" out_has "$DETACHED"
  check "./scripts/restore.sh running in place: repairs nothing under it" no_log 'kc delete job|kc patch application|kc scale'
  stop_detached KILL
  rm -f "$H/state/hang-jobs.json"
  rm -f "$H/.local/restore-clean.state"

  # Not a restore of this checkout, and not a restore at all, though each has the words on its command line.
  reset
  take_backups
  local other="$H/state/other-checkout" other_pid wrapper_pid
  mkdir -p "$other/scripts"
  printf '#!/usr/bin/env bash\n/bin/sleep 60\n' > "$other/scripts/restore.sh"
  chmod +x "$other/scripts/restore.sh"
  ( cd "$other" && exec ./scripts/restore.sh dev latest ) > /dev/null 2>&1 &
  other_pid=$!
  /bin/bash -c '/bin/sleep 60 # scripts/restore.sh dev latest' > /dev/null 2>&1 &
  wrapper_pid=$!
  /bin/sleep 0.3
  write_marker
  : > "$H/state/calls.log"
  run ./scripts/restore.sh clean latest
  check "another checkout's restore and a command that names one: the resume goes on, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  kill "$other_pid" "$wrapper_pid" 2>/dev/null
  wait "$other_pid" "$wrapper_pid" 2>/dev/null
}

R17() {
  scenario "R17. An option a resume cannot honour is refused, and not ignored"
  reset
  take_backups
  local first_d first_p second_d
  first_d="$(ls "$H/.local/backups/dev" | tail -1)"
  first_p="$(ls "$H/.local/backups/prod-sim" | tail -1)"
  take_backups
  second_d="$(ls "$H/.local/backups/dev" | tail -1)"
  lose_cluster
  write_marker
  : > "$H/state/calls.log"
  run env "BACKUP_DEV=$first_d" scripts/restore.sh clean latest PLAN_ONLY=yes
  check "BACKUP_DEV differs from the marker's, in a plan: refuses (got $RC)" test "$RC" -ne 0
  check "says which it asked for" out_has "BACKUP_DEV=$first_d was given"
  check "and which it uses" out_has "uses $second_d"
  check "and how to use it" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  run env "BACKUP_DEV=$first_d" scripts/restore.sh clean latest
  check "BACKUP_DEV differs, a real run: refuses (got $RC)" test "$RC" -ne 0
  check "BACKUP_DEV differs, a real run: nothing ran" no_log 'kind create|kc apply|kc scale'
  run env "BACKUP_PROD_SIM=$first_p" scripts/restore.sh clean latest PLAN_ONLY=yes
  check "BACKUP_PROD_SIM differs: refuses (got $RC)" test "$RC" -ne 0
  check "BACKUP_PROD_SIM differs: says so" out_has "BACKUP_PROD_SIM=$first_p was given"
  run env ENVS=dev scripts/restore.sh clean latest PLAN_ONLY=yes
  check "ENVS differs: refuses (got $RC)" test "$RC" -ne 0
  check "ENVS differs: says so" out_has "ENVS=dev was given"
  run env "BACKUP_DEV=$second_d" scripts/restore.sh clean latest PLAN_ONLY=yes
  check "BACKUP_DEV the same as the marker's: goes through (got $RC)" test "$RC" -eq 0
  show_tail
}

R18() {
  scenario "R18. A password this backup does not name is not one to count on"
  reset
  take_backups
  local z="$H/.local/secret-zero"
  expire_named_token
  printf 'another-password' > "$z/infisical-admin-password"
  jq '.password = "another-password"' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "in place: refuses before anything stops (got $RC)" test "$RC" -ne 0
  show_tail 1
  check "in place: nothing stopped" no_log 'kc scale|kc patch application infisical'
  check "in place: nothing replaced" no_log 'kc apply Job plane-restore ns=infisical'
  check "in place: says why" out_has "is not the one this backup names by checksum"
  check "in place: and the way past it" out_has "ALLOW_NO_ADMIN_TOKEN=yes"
  check "in place: and says nothing changed" out_has "Nothing was changed"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_NO_ADMIN_TOKEN=yes
  check "in place, the override: restores, tries it, and stops with the steps, exit 3 (got $RC)" test "$RC" -eq 3
  check "in place, the override: it tried" log_has 'api POST login'
  check "in place, the override: and printed them" out_has "sign in as admin@wayline.localhost"
  check "in place, the override: the file is what it was" test "$(cat "$z/infisical-admin-password")" = another-password

  # The README's last resort: a new hash in the restored database, and the new password in the file. It is right, and
  # the checksum differs, so the override goes on and the server has the last word.
  reset
  take_backups
  expire_named_token
  printf 'another-password' > "$z/infisical-admin-password"
  # Every dump holds that hash now, as a dump taken after the procedure would.
  local dir
  for dir in "$H"/.local/backups/infisical/*; do
    jq '.password = "another-password"' "$dir/fake-api-dump.json" > "$H/state/t" && cp "$H/state/t" "$dir/fake-api-dump.json"
  done
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_NO_ADMIN_TOKEN=yes
  check "the password is right after all: signs in and goes on, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the password is right after all: minted" jq -e 'select(.method == "password")' "$z/infisical-admin-replaced.log"

  # A trailing newline, as echo leaves, is the same password, because the login route trims it.
  reset
  take_backups
  expire_named_token
  printf 'uipw\n' > "$z/infisical-admin-password"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "a trailing newline is the same password: goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail

  # Clean: nothing is live to protect, so it warns and goes on, and stops for a sign-in if the server refuses.
  reset
  take_backups
  expire_named_token
  printf 'another-password' > "$z/infisical-admin-password"
  lose_cluster
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "clean: the plan goes through (got $RC)" test "$RC" -eq 0
  check "clean: and warns" out_has "is not the password this backup names by checksum"
  check "clean: and says what happens" out_has "if the server refuses it, this stops with sign-in steps"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "clean: stops for a sign-in, exit 2 (got $RC)" test "$RC" -eq 2
  check "clean: having tried" log_has 'api POST login'
  check "clean: with the steps" out_has "sign in as admin@wayline.localhost"
  check "clean: and the marker stays" test -f "$H/.local/restore-clean.state"

  # No complete set, in place: the token and the password are looked at the same way, before the stop.
  reset
  take_backups
  set_token_exp $(($(date +%s) - 86400))
  rm "$z/infisical-admin-password"
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o9.txt" 2>&1
  check "fixture: the token ended and no password, so this backup's set is not whole" test "$?" -ne 0
  /bin/sleep 1
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "no complete set, nothing can log in: refuses (got $RC)" test "$RC" -ne 0
  check "no complete set, nothing can log in: nothing stopped" no_log 'kc scale|kc patch application infisical'
  check "no complete set, nothing can log in: says why" out_has "no password is on this machine, so nothing could log in after this restore"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_NO_ADMIN_TOKEN=yes
  check "no complete set, the override: stops with the steps, exit 3 (got $RC)" test "$RC" -eq 3
  check "no complete set, the override: it restored" log_has 'kc apply Job plane-restore ns=infisical'
  check "no complete set, the override: the steps" out_has "sign in as admin@wayline.localhost"

  # A backup with no set at all, and a good token in place: it may work, so it goes on, and the server says.
  reset
  take_backups
  local id
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  rm -rf "$H/.local/backups/infisical/$id/recovery"
  (cd "$H/.local/backups/infisical/$id" && grep -v ' ./recovery/' SHA256SUMS > S.t; mv S.t SHA256SUMS)
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "no set at all, a good token: restores, and no proof could run, exit 2 (got $RC)" test "$RC" -eq 2
  show_tail 2
  check "no set at all, a good token: the server accepted it" jq -e 'any(.steps[]; .step == "admin-token" and .status == "PASS")' "$(newest_evidence restore-infisical)"
  check "no set at all, a good token: says why no proof ran" out_has "this backup has no complete recovery set, so this is not a pass"
  check "no set at all, a good token: and does not talk of sentinels" no_out "ALLOW_NO_SENTINEL"
  # And a token that has ended with no password, which the same check refuses.
  reset
  take_backups
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  rm -rf "$H/.local/backups/infisical/$id/recovery"
  (cd "$H/.local/backups/infisical/$id" && grep -v ' ./recovery/' SHA256SUMS > S.t; mv S.t SHA256SUMS)
  set_token_exp $(($(date +%s) - 86400))
  rm "$z/infisical-admin-password"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "no set at all, nothing can log in: refuses (got $RC)" test "$RC" -ne 0
  check "no set at all, nothing can log in: nothing stopped" no_log 'kc scale|kc patch application infisical'
}

R19() {
  scenario "R19. A stop during kind create: the resume says what is wrong, and what to do"
  reset
  take_backups
  write_marker
  edit_cluster 'c["stopped"] = True'
  touch "$H/state/kind-export-fails"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the resume stops (got $RC)" test "$RC" -ne 0
  check "with kind's own error" out_has "could not locate any control plane nodes"
  check "and what that means" out_has "the node never finished"
  check "and how to go on" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes, then run this again"
  check "and what that costs if the cluster ever ran" out_has "If this cluster ever ran and holds data, read docker logs plane-platform-control-plane first"
  reset
  lose_cluster
  : > "$H/state/calls.log"
  touch "$H/state/kind-export-fails"
  run scripts/cluster-up.sh
  check "cluster-up.sh alone says the same (got $RC)" test "$RC" -ne 0
  check "cluster-up.sh alone: the cause" out_has "could not locate any control plane nodes"
  rm -f "$H/state/kind-export-fails"
  edit_cluster 'c["stopped"] = False'
  run scripts/cluster-up.sh
  check "when it works, kind's noise stays out of it (got $RC)" test "$RC" -eq 0
}

R21() {
  scenario "R21. The exit numbers are the script's, and make says 2 for any of them"
  reset
  take_backups
  cp "$SOURCE/Makefile" "$H/Makefile"
  run make restore-clean BACKUP=20200101T000000Z PLAN_ONLY=yes
  check "through make, a refusal: make exits 2 (got $RC)" test "$RC" -eq 2
  check "through make, a refusal: and prints the script's" out_has "Error 1"
  run scripts/restore.sh clean 20200101T000000Z PLAN_ONLY=yes
  check "the script itself: 1 (got $RC)" test "$RC" -eq 1
  check "the README says so" grep -F 'the numbers are the script'"'"'s' "$SOURCE/infisical/README.md"
  check "the README says what make does" grep -F 'make itself exits 2 on any of them, and prints which' "$SOURCE/infisical/README.md"
  check "the README says what to read" grep -F "jq '.result, .not_run'" "$SOURCE/infisical/README.md"
  check "make help does not say make exits 2 only for a proof" test -z "$(grep -F 'Exits 2 if a proof could not run' "$SOURCE/Makefile")"
}

R22() {
  scenario "R22. A row marked uploaded with no object: the backup says so, and a plan refuses before a delete"
  reset
  printf 'a/b.txt\nc/no-such-object.png\n' > "$H/state/uploaded-keys"
  ( cd "$H" && scripts/backup.sh all ) > "$H/state/o10.txt" 2>&1
  check "the backup still succeeds, since it holds everything else" test "$?" -eq 0
  /bin/sleep 1
  grep -F 'rows marked uploaded with no object' "$H/state/o10.txt" >/dev/null
  check "and says so" test "$?" -eq 0
  local bad good d
  bad="$(ls "$H/.local/backups/dev" | tail -1)"
  d="$H/.local/backups/dev/$bad"
  check "the manifest records it" jq -e '.uploaded_objects == {rows: 2, missing: 1}' "$d/manifest.json"
  check "and the backup lists which" grep -Fx 'c/no-such-object.png' "$d/postgres/uploaded-missing.txt"
  check "the Job's working files are gone" test -z "$(find "$d" -name '.objects*' -o -name '*.unsorted')"
  check "and the checksums cover the list" grep -F './postgres/uploaded-missing.txt' "$d/SHA256SUMS"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a plan refuses (got $RC)" test "$RC" -ne 0
  check "and says why" out_has "backup dev/$bad has 1 rows marked uploaded with no object"
  check "and what to do" out_has "BACKUP_DEV=<id>"
  run env CONFIRM=yes SKIP_E2E=yes SKIP_BACKUP=yes tests/drills/clean-restore.sh
  check "the drill refuses (got $RC)" test "$RC" -ne 0
  check "before the delete" no_log 'kind delete cluster'
  run scripts/restore.sh dev latest CONFIRM=yes
  check "in place: refuses (got $RC)" test "$RC" -ne 0
  check "in place: says why" out_has "has 1 rows marked uploaded with no object"
  check "in place: before anything stops, or the guard Jobs" no_log 'kc scale|plane-restore-guard'
  check "in place: says nothing was changed" out_has "Nothing was changed"
  check "in place: and what to do" out_has "Choose another with BACKUP=<id>"

  # A good one beside it is still a way out.
  reset
  ( cd "$H" && scripts/backup.sh all ) > /dev/null 2>&1
  /bin/sleep 1
  good="$(ls "$H/.local/backups/dev" | tail -1)"
  check "with every object there: the manifest says none is missing" jq -e '.uploaded_objects == {rows: 1, missing: 0}' "$H/.local/backups/dev/$good/manifest.json"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "with every object there: a plan passes (got $RC)" test "$RC" -eq 0
  show_tail
  check "with every object there: and shows it" out_has "uploaded rows with no object: 0"
  printf 'a/b.txt\nc/no-such-object.png\n' > "$H/state/uploaded-keys"
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  rm -f "$H/state/uploaded-keys"
  bad="$(ls "$H/.local/backups/dev" | tail -1)"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the newest fails it: the plan refuses (got $RC)" test "$RC" -ne 0
  run env "BACKUP_DEV=$good" scripts/restore.sh clean latest PLAN_ONLY=yes
  check "and BACKUP_DEV=<another> goes through (got $RC)" test "$RC" -eq 0
  # A backup from before this records nothing, and that is not a reason to refuse it.
  d="$H/.local/backups/dev/$good"
  jq 'del(.uploaded_objects)' "$d/manifest.json" > "$H/state/t" && cp "$H/state/t" "$d/manifest.json"
  reseal "$d" manifest.json
  run env "BACKUP_DEV=$good" scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a backup from before this: goes through (got $RC)" test "$RC" -eq 0
  check "a backup from before this: and says it is not recorded" out_has "uploaded rows with no object: not recorded"

  # The comparison itself failing must not cost the backup, which is worth more than the record.
  reset
  touch "$H/state/rclone-fail"
  ( cd "$H" && scripts/backup.sh all ) > "$H/state/o10.txt" 2>&1
  check "the comparison cannot run: the backup still succeeds" test "$?" -eq 0
  rm -f "$H/state/rclone-fail"
  /bin/sleep 1
  d="$H/.local/backups/dev/$(ls "$H/.local/backups/dev" | tail -1)"
  check "the comparison cannot run: the manifest records no result" jq -e '.uploaded_objects == null' "$d/manifest.json"
  check "the comparison cannot run: nothing half-written is left" test -z "$(find "$d" -name '.objects*' -o -name 'uploaded-missing.txt')"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the comparison cannot run: a plan goes on (got $RC)" test "$RC" -eq 0
  show_tail
  check "the comparison cannot run: and says it is not recorded" out_has "uploaded rows with no object: not recorded"
}

# ----- The review of those fixes. V and a number is its MAJOR problem of that number. -----

# On a real terminal, which closes once the pattern shows in that file. Sets RC and OUT.
run_on_terminal() { # file pattern command...
  local file="$1" pattern="$2"
  shift 2
  OUT="$H/state/terminal.txt"
  ( cd "$H" && exec python3 -I "$STUBS/close-terminal.py" "$file" "$pattern" "$RUN_LIMIT_SECONDS" "$@" ) > "$OUT" 2>&1
  RC=$?
}
paused_now() { jq -r '[(.paused // {}) | to_entries[] | select(.value) | .key] | join(" ")' "$H/state/cluster.json"; }
jobs_running_now() { jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json"; }

# What a stop in dev's data Job has to leave, whatever became of the client's output.
dead_output_in_a_job() { # label
  check "$1: not a pass (got $RC)" test "$RC" -ne 0
  check "$1: no Job is left running" test "$(jobs_running_now)" = 0
  check "$1: the Job goes first, then auto-sync, root last" order 'kc delete job plane-restore ns=plane-dev' 'kc patch application plane-dev resume' 'kc patch application root resume'
  check "$1: nothing stays paused" test -z "$(paused_now)"
  check "$1: nothing started over a running Job" no_log '^ERROR'
  check "$1: the evidence says FAIL" jq -e '.result == "FAIL" and any(.steps[]; .step == "restore-job-stopped")' "$(newest_evidence restore-dev)"
}
# And a stop before any data Job, with the pause already done.
dead_output_before_a_job() { # label
  check "$1: not a pass (got $RC)" test "$RC" -ne 0
  check "$1: no data Job ran" no_log 'kc apply Job plane-restore ns='
  check "$1: auto-sync comes back, root last" order 'kc patch application plane-dev resume' 'kc patch application root resume'
  check "$1: nothing stays paused" test -z "$(paused_now)"
  check "$1: the evidence says FAIL" jq -e '.result == "FAIL"' "$(newest_evidence restore-dev)"
}

V1() {
  scenario "V1. The client's output is dead, by a closed terminal or a tee that took the same Ctrl-C: the stop still does all of its work"
  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  run_on_terminal "$H/state/jobs.json" '"state": "Running"' scripts/restore.sh dev latest CONFIRM=yes
  dead_output_in_a_job "a terminal that closes in dev's Job"
  check "a terminal that closes in dev's Job: what it had to say is in a file beside the evidence" grep -F "its Job was stopped before it finished" "$(newest_evidence restore-dev).log"

  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached bash -c 'scripts/restore.sh dev latest CONFIRM=yes 2>&1 | tee "$H_STATE/tee.txt"'
  wait_for_running_job
  stop_detached INT
  dead_output_in_a_job "a tee and Ctrl-C in dev's Job"

  # Only stderr is dead, with stdout in a file: warn's messages still have to land somewhere.
  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached bash -c 'scripts/restore.sh dev latest CONFIRM=yes 2>&1 >"$H_STATE/stdout.txt" | tee "$H_STATE/tee.txt"'
  wait_for_running_job
  stop_detached INT
  dead_output_in_a_job "stderr alone through a tee, Ctrl-C"
  check "stderr alone through a tee, Ctrl-C: what it warned is beside the evidence" grep -F "its Job was stopped before it finished" "$(newest_evidence restore-dev).log"

  # So a person who saw the warning about a 0-user backup and pressed Ctrl-C, through a pipe, keeps the data.
  reset
  plane_counts 0
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  cluster_holds plane-dev 500 777
  : > "$H/state/calls.log"
  start_detached bash -c 'scripts/restore.sh dev latest CONFIRM=yes 2>&1 | tee "$H_STATE/tee.txt"'
  wait_for_running_job
  stop_detached INT
  check "the warning about a 0-user backup got through the tee" grep -F "holds 0 users" "$H/state/tee.txt"
  check "and Ctrl-C after it removes the Job" test "$(jobs_running_now)" = 0
  check "and the data stays" test "$(cluster_value '.users["plane-dev"]')" = 500

  reset
  take_backups
  printf 'plane-dev scale deployment/plane-api-wl --replicas=0' > "$H/state/kubectl-hang"
  : > "$H/state/calls.log"
  run_on_terminal "$H/state/calls.log" 'kc hung' scripts/restore.sh dev latest CONFIRM=yes
  dead_output_before_a_job "a terminal that closes before any Job"

  reset
  take_backups
  printf 'plane-dev scale deployment/plane-api-wl --replicas=0' > "$H/state/kubectl-hang"
  : > "$H/state/calls.log"
  start_detached bash -c 'scripts/restore.sh dev latest CONFIRM=yes 2>&1 | tee "$H_STATE/tee.txt"'
  wait_for_log 'kc hung'
  stop_detached INT
  dead_output_before_a_job "a tee and Ctrl-C before any Job"

  # Infisical's server has to come back too, in the same order as with a client that can print.
  reset
  take_backups
  printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  run_on_terminal "$H/state/jobs.json" '"state": "Running"' scripts/restore.sh infisical latest CONFIRM=yes
  check "a terminal that closes in Infisical's Job: no Job is left running" test "$(jobs_running_now)" = 0
  check "a terminal that closes in Infisical's Job: the Job, the flush, the server, auto-sync" order 'kc delete job plane-restore ns=infisical' 'kc exec redis FLUSHALL ns=infisical' 'kc scale deployment/infisical --replicas=1 ns=infisical' 'kc patch application infisical resume'

  # The parent of a clean restore: its own trap has evidence to write and a token file to remove, and the resume finishes.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached bash -c 'scripts/restore.sh clean latest 2>&1 | tee "$H_STATE/tee.txt"'
  wait_for_log 'kc apply Job plane-restore ns=plane-dev'
  wait_for_running_job
  stop_detached INT
  rm -f "$H/state/hang-jobs.json"
  check "a clean restore through a tee, Ctrl-C: no Job is left running" test "$(jobs_running_now)" = 0
  check "a clean restore through a tee, Ctrl-C: nothing stays paused" test -z "$(paused_now)"
  check "a clean restore through a tee, Ctrl-C: its evidence is written, and says FAIL" jq -e '.result == "FAIL"' "$(newest_evidence restore-clean)"
  check "a clean restore through a tee, Ctrl-C: what it had to say is beside that" grep -F "stopped. Fix the cause" "$(newest_evidence restore-clean).log"
  check "a clean restore through a tee, Ctrl-C: no steps file is left" test -z "$(ls -a "$H/.local" | grep -F .restore-clean-steps. || true)"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "and the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail

  # The drill has its own tee, which takes the same Ctrl-C, and its RESULT line has to reach the evidence.
  reset
  take_backups
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached env CONFIRM=yes SKIP_E2E=yes bash -c 'tests/drills/clean-restore.sh 2>&1 | tee "$H_STATE/tee.txt"'
  wait_for_log 'kc apply Job plane-restore ns=plane-dev'
  wait_for_running_job
  stop_detached INT
  check "the drill through a tee, Ctrl-C: no Job is left running" test "$(jobs_running_now)" = 0
  check "the drill through a tee, Ctrl-C: its evidence has the RESULT line" grep -F "RESULT FAIL" "$(ls -t "$H"/.local/evidence-raw/drill-clean-restore-*.log | head -1)"
  check "the drill through a tee, Ctrl-C: and how to go on" grep -F "make restore-clean BACKUP=" "$(ls -t "$H"/.local/evidence-raw/drill-clean-restore-*.log | head -1)"
}

V2() {
  scenario "V2. make destroy under a kept marker backs up first, and a person is not sent past that backup"
  reset
  take_backups
  lose_cluster
  # prod-sim's Job fails, so the marker has no line about its data, and then something writes there.
  printf '[["plane-restore-2","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  check "fixture: prod-sim is not finished" test -z "$(grep -x 'done prod-sim' "$H/.local/restore-clean.state" || true)"
  cluster_holds plane-prod-sim 500 777
  local before
  before="$(ls "$H/.local/backups/prod-sim" | wc -l | tr -d ' ')"
  /bin/sleep 1
  : > "$H/state/calls.log"
  run env CONFIRM=yes scripts/destroy.sh
  check "make destroy, with prod-sim holding 500 users: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "it says it goes past the refusal" out_has "Backing it up anyway, because ALLOW_BACKUP_DURING_RESTORE=yes"
  check "a backup of prod-sim comes first" order 'kc apply Job plane-backup ns=plane-prod-sim' 'kind delete cluster'
  check "and there is one more backup of it" test "$(ls "$H/.local/backups/prod-sim" | wc -l | tr -d ' ')" -gt "$before"
  check "and of everything else" order 'kc apply Job plane-backup ns=infisical' 'kc apply Job plane-backup ns=plane-dev' 'kind delete cluster'

  # A backup that fails still stops the delete, and now says what going past it loses.
  reset
  take_backups
  write_marker infisical
  printf '[["plane-backup","plane-dev"]]' > "$H/state/fail-jobs.json"
  : > "$H/state/calls.log"
  run env CONFIRM=yes scripts/destroy.sh
  check "a backup that fails: refuses (got $RC)" test "$RC" -ne 0
  check "a backup that fails: deletes nothing" no_log 'kind delete cluster'
  check "a backup that fails: says what SKIP_BACKUP=yes loses" out_has "SKIP_BACKUP=yes deletes it with no backup, and what it holds since the last backup is then gone"

  # A plain backup of what it has not finished is still refused, and goes ahead once the data has come back.
  reset
  take_backups
  write_marker infisical
  : > "$H/state/calls.log"
  run scripts/backup.sh prod-sim
  check "a plain backup under a marker: refuses (got $RC)" test "$RC" -ne 0
  check "a plain backup under a marker: no Job" no_log 'kc apply Job plane-backup'
  printf 'data-back prod-sim\n' >> "$H/.local/restore-clean.state"
  run scripts/backup.sh prod-sim
  check "with its data back: goes ahead (got $RC)" test "$RC" -eq 0
  check "with its data back: says so" out_has "the data of prod-sim has come back, so this backup goes ahead"
}

V3() {
  scenario "V3. ALLOW_RESUME_OVERWRITE reaches only what it names, and a run that used it does not read PASS"
  local bad
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fixture: dev's Job fails" test "$RC" -ne 0
  rm -f "$H/state/fail-jobs.json"
  cluster_holds plane-dev 500 777
  cluster_holds plane-prod-sim 600 888

  for bad in yes "dev,prod-sim" "dev yes" all; do
    : > "$H/state/calls.log"
    run env "ALLOW_RESUME_OVERWRITE=$bad" scripts/restore.sh clean latest
    check "ALLOW_RESUME_OVERWRITE='$bad': refused (got $RC)" test "$RC" -ne 0
    check "ALLOW_RESUME_OVERWRITE='$bad': says what it takes" out_has "ALLOW_RESUME_OVERWRITE names the environments to overwrite"
    check "ALLOW_RESUME_OVERWRITE='$bad': touches nothing" test ! -s "$H/state/calls.log"
  done

  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "no override: refuses, naming dev (got $RC)" out_has "plane-dev holds 500 users and 777 objects"
  check "no override: prints the override that reaches dev alone" out_has "ALLOW_RESUME_OVERWRITE=dev,"

  # What the refusal printed, followed: prod-sim, which no refusal has named, stays.
  : > "$H/state/calls.log"
  run env ALLOW_RESUME_OVERWRITE=dev scripts/restore.sh clean latest
  check "naming dev: stops at prod-sim (got $RC)" test "$RC" -eq 1
  show_tail 1
  check "naming dev: dev is overwritten" test "$(cluster_value '.users["plane-dev"]')" = 23
  check "naming dev: its own evidence does not read PASS" jq -e '.result == "OVERWROTE"' "$(newest_evidence restore-dev)"
  check "naming dev: and says what it held" jq -e 'any(.steps[]; .step == "overwrite-guard" and .status == "FAIL" and (.detail | test("500 users and 777 objects")))' "$(newest_evidence restore-dev)"
  check "naming dev: prod-sim still holds 600 users" test "$(cluster_value '.users["plane-prod-sim"]')" = 600
  check "naming dev: and 888 objects" test "$(cluster_value '.objects["plane-prod-sim"]')" = 888
  check "naming dev: prod-sim was not replaced" no_log 'kc apply Job plane-restore ns=plane-prod-sim'
  check "naming dev: the refusal now names prod-sim" out_has "plane-prod-sim holds 600 users and 888 objects"
  check "naming dev: and the override that reaches it" out_has "ALLOW_RESUME_OVERWRITE=prod-sim,"
  check "naming dev: the marker stays" test -f "$H/.local/restore-clean.state"

  # The next run names only prod-sim, and the overall result remembers dev too.
  : > "$H/state/calls.log"
  run env ALLOW_RESUME_OVERWRITE=prod-sim scripts/restore.sh clean latest
  check "then naming prod-sim: exit 4 (got $RC)" test "$RC" -eq 4
  show_tail 4
  check "then naming prod-sim: dev, already done, was left alone" no_log 'kc apply Job plane-restore ns=plane-dev'
  check "then naming prod-sim: it does not say complete" no_clean_complete
  check "then naming prod-sim: it says so" out_has "this is not a pass: it overwrote what these held, because ALLOW_RESUME_OVERWRITE named them: dev prod-sim"
  check "then naming prod-sim: its evidence does not read PASS" jq -e '.result == "OVERWROTE"' "$(newest_evidence restore-prod-sim)"
  check "then naming prod-sim: the clean restore's does not either" jq -e '.result == "OVERWROTE"' "$(newest_evidence restore-clean)"
  check "then naming prod-sim: and lists both" jq -e '[.steps[] | select(.status == "FAIL") | .step] == ["overwrite-dev", "overwrite-prod-sim"]' "$(newest_evidence restore-clean)"
  check "then naming prod-sim: nothing is left to resume" test ! -e "$H/.local/restore-clean.state"

  # Both at once, the way make passes it.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  cluster_holds plane-dev 500 777
  cluster_holds plane-prod-sim 600 888
  run scripts/restore.sh clean latest "ALLOW_RESUME_OVERWRITE=dev prod-sim"
  check "naming both, as an argument: exit 4 (got $RC)" test "$RC" -eq 4
  show_tail 4
  check "naming both: dev back to the backup" test "$(cluster_value '.users["plane-dev"]')" = 23
  check "naming both: prod-sim too" test "$(cluster_value '.users["plane-prod-sim"]')" = 23

  # Named and not needed: nothing was overwritten, so a pass is a pass.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  run env ALLOW_RESUME_OVERWRITE=dev scripts/restore.sh clean latest
  check "named, and the target is only this backup part way through: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "named, and not used: reads PASS" jq -e '.result == "PASS"' "$(newest_evidence restore-clean)"

  # Infisical can be named, as a resume can refuse it too.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  cluster_holds infisical 7 0
  run env ALLOW_RESUME_OVERWRITE=dev scripts/restore.sh clean latest
  check "Infisical holds 7 users, and only dev is named: refuses (got $RC)" test "$RC" -ne 0
  check "and names the override for it" out_has "ALLOW_RESUME_OVERWRITE=infisical,"
  run env ALLOW_RESUME_OVERWRITE=infisical scripts/restore.sh clean latest
  check "naming Infisical: exit 4 (got $RC)" test "$RC" -eq 4
  show_tail 4
  check "naming Infisical: its evidence does not read PASS" jq -e '.result == "OVERWROTE"' "$(newest_evidence restore-infisical)"
}

V4() {
  scenario "V4. A resume does not replace data that came back, and goes on from the migrator"
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fixture: prod-sim's migrator fails (got $RC)" test "$RC" -ne 0
  rm -f "$H/state/fail-jobs.json"
  check "the marker says its data is back" grep -qx 'data-back prod-sim' "$H/.local/restore-clean.state"
  check "and that it has not finished it" test -z "$(grep -x 'done prod-sim' "$H/.local/restore-clean.state" || true)"
  check "dev's data came back too" grep -qx 'data-back dev' "$H/.local/restore-clean.state"

  # The same counts, and the platform used since: new work items change neither, which is why this does not compare.
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a plan says what a resume will do" out_has "its data came back on an earlier run, so a resume keeps what is there"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the same counts: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the same counts: the data is not replaced" no_log 'kc apply Job plane-restore ns=plane-prod-sim'
  check "the same counts: it stops the apps, runs the migrator, starts the apps" order 'kc scale deployment/plane-api-wl --replicas=0 ns=plane-prod-sim' 'kc apply Job plane-restore-migrate ns=plane-prod-sim' 'kc scale deployment/plane-api-wl --replicas=1 ns=plane-prod-sim'
  check "the same counts: the proofs run" log_has 'kc exec proof-decrypt ns=plane-prod-sim'
  check "the same counts: nothing started over anything" no_log '^ERROR'
  check "the same counts: the evidence says so" jq -e 'any(.steps[]; .step == "data-back" and .status == "PASS") and all(.steps[]; .step != "postgres") and any(.steps[]; .step == "migrator" and .status == "PASS")' "$(newest_evidence restore-prod-sim)"
  check "the same counts: nothing was overwritten, so a pass is a pass" jq -e '.result == "PASS"' "$(newest_evidence restore-clean)"
  check "the same counts: finished" test ! -e "$H/.local/restore-clean.state"

  # Written to since, in the counts as well. Without the line this is the refusal, and there is nothing to refuse now.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  cluster_holds plane-prod-sim 500 777
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "500 users since: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "500 users since: they stay" test "$(cluster_value '.users["plane-prod-sim"]')" = 500
  check "500 users since: and the objects" test "$(cluster_value '.objects["plane-prod-sim"]')" = 777
  check "500 users since: not replaced" no_log 'kc apply Job plane-restore ns=plane-prod-sim'
  check "500 users since: the evidence says what it held" jq -e 'any(.steps[]; .step == "data-back" and (.detail | test("500 users and 777 objects")))' "$(newest_evidence restore-prod-sim)"

  # The override replaces it, and that is not a pass, even with counts that look like this backup.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  : > "$H/state/calls.log"
  run env ALLOW_RESUME_OVERWRITE=prod-sim scripts/restore.sh clean latest
  check "the override, and the same counts: exit 4 (got $RC)" test "$RC" -eq 4
  show_tail 4
  check "the override: replaced" log_has 'kc apply Job plane-restore ns=plane-prod-sim'
  check "the override: recorded as a FAIL" jq -e 'any(.steps[]; .step == "overwrite-guard" and .status == "FAIL") and .result == "OVERWROTE"' "$(newest_evidence restore-prod-sim)"
  check "the override on prod-sim: dev stays as it was" no_log 'kc apply Job plane-restore ns=plane-dev'

  # The line outlived what it was about, as with a new empty cluster. An empty target has nothing to lose.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  cluster_holds plane-prod-sim 0 0
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the line, and an empty target: restores it, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the line, and an empty target: the data Job runs" log_has 'kc apply Job plane-restore ns=plane-prod-sim'
  check "the line, and an empty target: no override was needed, so it reads PASS" jq -e '.result == "PASS"' "$(newest_evidence restore-clean)"

  # The cluster is lost: nothing on that cluster counts any more, with no done line to say so.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  check "fixture: only a data-back line, for dev" test "$(grep -c '^done dev' "$H/.local/restore-clean.state")" = 0
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the cluster lost: starts again, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the cluster lost: says so" out_has "so it starts again from the beginning"
  check "the cluster lost: dev's data comes back" log_has 'kc apply Job plane-restore ns=plane-dev'

  # A stop in the migrator's Job, with the same result.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  start_detached scripts/restore.sh clean latest
  wait_for_log 'kc apply Job plane-restore-migrate ns=plane-prod-sim'
  wait_for_running_job
  stop_detached TERM
  rm -f "$H/state/hang-jobs.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "SIGTERM in the migrator's Job: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "SIGTERM in the migrator's Job: the data is not replaced" no_log 'kc apply Job plane-restore ns=plane-prod-sim'
  check "SIGTERM in the migrator's Job: the migrator runs" log_has 'kc apply Job plane-restore-migrate ns=plane-prod-sim'

  # A proof that fails on what was kept says what there is to do.
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-migrate","plane-prod-sim"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  printf '1' > "$H/state/smoke-rc-verify"
  run scripts/restore.sh clean latest
  rm -f "$H/state/smoke-rc-verify"
  check "a proof fails on what it kept: not a pass (got $RC)" test "$RC" -ne 0
  check "a proof fails on what it kept: says it kept it, and the way on" out_has "this resume kept what plane-prod-sim holds, and at least one proof failed on it"
  check "a proof fails on what it kept: names the override" out_has "ALLOW_RESUME_OVERWRITE=prod-sim replaces it"

  # Infisical: a failure after the swap keeps the database too, which now holds whatever it was given since.
  reset
  take_backups
  lose_cluster
  printf 'once:infisical exec infisical-redis-0\n' > "$H/state/kubectl-fail"
  run scripts/restore.sh clean latest
  check "fixture: Infisical's flush fails after the swap (got $RC)" test "$RC" -ne 0
  check "Infisical: the marker says its data is back" grep -qx 'data-back infisical' "$H/.local/restore-clean.state"
  cluster_holds infisical 7 0
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "Infisical: the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "Infisical: its database is not replaced" no_log 'kc apply Job plane-restore ns=infisical'
  check "Infisical: the server comes back" log_has 'kc scale deployment/infisical --replicas=1 ns=infisical'
  check "Infisical: nothing started over anything" no_log '^ERROR'

  # In place, under a marker, it is another backup or a person's choice, so it says nothing about the restore under way.
  reset
  take_backups
  write_marker infisical
  run scripts/restore.sh dev latest CONFIRM=yes
  check "in place under a marker: goes on as asked (got $RC)" test "$RC" -eq 0
  show_tail
  check "in place under a marker: writes no line" test -z "$(grep '^data-back ' "$H/.local/restore-clean.state" || true)"
}
