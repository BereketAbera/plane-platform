#!/usr/bin/env bash
# Run tonight's backups now, from the CronJobs as they are in the cluster, so this proves what the night will do.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/backup.sh                 Infisical, then Plane, then Frameflow once it can run
#   TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod scripts/hosted/backup.sh one of them
#
# Prints each Job's logs, which hold table counts and file counts and no value. Exit 0 sealed, 1 failed.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this runs a backup Job"

NAMESPACES="${ONLY:-infisical plane-prod frameflow}"
STAMP="$(date -u +%Y%m%d%H%M%S)"
EVIDENCE="$HOSTED_EVIDENCE_DIR/backup-plane-prod-$STAMP.txt"
failed=""
sealed=""
left_out=""

for namespace in $NAMESPACES; do
  case "$namespace" in
    infisical | plane-prod | frameflow) ;;
    *) die "ONLY takes infisical, plane-prod or frameflow, and got '$namespace'" ;;
  esac
  # Frameflow's CronJob comes with the backup Application, and the volume its pod mounts, the API's, with Frameflow's second release.
  # Until both are here its pod cannot start, so a run of every namespace says so and leaves it out, and ONLY=frameflow stops here
  # rather than wait two hours on a pod that never starts.
  if [[ "$namespace" == frameflow ]]; then
    missing=""
    kc -n frameflow get cronjob plane-backup >/dev/null 2>&1 || missing="CronJob frameflow/plane-backup"
    kc -n frameflow get persistentvolumeclaim frameflow-data >/dev/null 2>&1 || missing="${missing:+$missing and }PersistentVolumeClaim frameflow/frameflow-data"
    if [[ -n "$missing" ]]; then
      [[ -z "${ONLY:-}" ]] || die "$missing does not exist yet. The backup Application brings the CronJob, and Frameflow's second release the API's volume"
      warn "frameflow left out: $missing does not exist yet, so its backup cannot run"
      left_out=" frameflow"
      continue
    fi
  fi
  job="plane-backup-manual-$STAMP"
  log "Backing up $namespace: Job $job"
  kc -n "$namespace" get cronjob plane-backup >/dev/null 2>&1 || die "CronJob $namespace/plane-backup does not exist. Is the backup Application synced?"
  active="$(kc -n "$namespace" get jobs -l app.kubernetes.io/name=plane-backup -o json | jq -r '[.items[] | select((.status.active // 0) > 0) | .metadata.name] | join(" ")')"
  [[ -z "$active" ]] || die "a backup is already running in $namespace: $active"
  kc -n "$namespace" create job --from=cronjob/plane-backup "$job" >/dev/null
  state="$(hosted_wait_job "$namespace" "$job" 7200)"
  {
    printf '== %s %s: %s\n' "$namespace" "$job" "$state"
    kc -n "$namespace" logs "job/$job" --all-containers --prefix --tail=-1 2>/dev/null || true
  } | tee -a "$EVIDENCE"
  # The Job says so and succeeds while Plane is not here, before the first promotion. Once its Application exists that same line is a
  # backup that held nothing, which the first real run here did, on a refusal it read as Plane being absent. So that does not pass.
  if [[ "$state" == ok && "$namespace" == plane-prod ]] &&
    kc -n "$namespace" logs "job/$job" -c postgres --tail=-1 2>/dev/null | grep -q 'there is nothing to back up' &&
    kc -n argocd get application plane-prod >/dev/null 2>&1; then
    state="empty, though Application plane-prod exists"
  fi
  # The night's own run succeeds with nothing to back up until the API has made its database, so that BackupNeverSucceeded waits for
  # first use. With the API's Deployment here, that line is a backup that held nothing, so it does not pass here.
  if [[ "$state" == ok && "$namespace" == frameflow ]] &&
    kc -n "$namespace" logs "job/$job" -c sqlite --tail=-1 2>/dev/null | grep -q 'nothing to back up yet' &&
    kc -n frameflow get deployment frameflow-api >/dev/null 2>&1; then
    state="empty, though Deployment frameflow/frameflow-api exists"
  fi
  if [[ "$state" == ok ]]; then
    ok "$namespace sealed"
    sealed="$sealed $namespace"
    # A later success clears the failure PlaneBackupFailed would otherwise report until the Job's TTL.
    kc -n "$namespace" get jobs -l app.kubernetes.io/name=plane-backup -o json |
      jq -r '.items[] | select((.status.failed // 0) > 0) | .metadata.name' |
      while read -r old; do kc -n "$namespace" delete job "$old" >/dev/null; done
  else
    warn "$namespace did not seal: Job $job is $state"
    kc -n "$namespace" get pods -l "job-name=$job" -o wide 2>/dev/null || true
    failed="$failed $namespace"
  fi
done

log "Evidence: ${EVIDENCE#"$ROOT"/}"
[[ -z "$failed" ]] || die "backup failed for:$failed"
ok "backed up:$sealed${left_out:+, and not$left_out, which cannot run yet}"
