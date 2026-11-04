# Backup and restore

Take a backup, bring data back, and handle the failures in between. For wider scenarios, such as losing the whole cluster, see
[Disaster recovery](../disaster-recovery.md). For the design, see [Data operations](../data-operations.md).

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NS=plane-dev
```

## Symptoms that bring you here

| Symptom | Meaning |
|---|---|
| `PlaneBackupFailed` firing | A `plane-backup-*` Job failed |
| "Last backup" stat is old or empty | Nothing runs on a schedule. Backups happen when a script takes them. The stat also empties when a Job's 7-day TTL expires |
| Data is wrong or missing | Decide whether to restore |
| `the Job finished but ... manifest.json is not on the host` | The kind mount of `.local/backups` is not what the Job wrote to |
| `has had a sync running for 180s` from `make restore` | The Application is in a retry loop. See below |

## Back up

```bash
make test-e2e ENV=dev         # once, before the first backup: creates the sentinel a restore reads back
make backup ENV=dev
make backup ENV=prod-sim
make backup ENV=infisical
make backup ENV=all
ls -1 .local/backups/dev/
```

There is no CronJob. Backups run when you run them, and also inside three commands: `make promote ENV=prod-sim`, a `make gitops-publish` that changes a prod-sim image, and `make destroy`.

| Part | Method |
|---|---|
| Postgres | `pg_dump -Fc` with the server's own image, then a restore into a scratch database. Row counts and content hashes come from that scratch copy, so each backup is restored once as it is made |
| Objects | `rclone copy` from Silo, then `rclone check --download`. Plane only |
| Keys | Only a truncated hash of `SECRET_KEY` or `ENCRYPTION_KEY` in the manifest, never the key |
| Excluded rows | `api_activity_logs`, `webhook_logs`, `email_notification_logs`. Schema is kept |
| Retention | Newest 3 for dev, 5 for others. `KEEP=<n>` overrides |
| Location | `.local/backups/<env>/<id>/`, on the host, so it survives cluster deletion |

Dumps hold password hashes and plaintext API tokens, so `.local/backups` is kept at 0700. It is on one disk on one laptop. No off-host copy exists in Pass 1.

## Diagnosis of a failed backup

```bash
kubectl -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup
JOB="$(kubectl -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup -o name | tail -1)"
kubectl -n "$NS" logs "$JOB" --all-containers --prefix --tail=50
kubectl -n "$NS" get pvc backups
kubectl -n "$NS" describe "$JOB" | tail -15
ls -la .local/backups .local/backups/dev
df -h .
```

| Log or state | Cause | Fix |
|---|---|---|
| Permission denied under `/backups` | UID 70 cannot write through VirtioFS. `backup.sh` sets the environment folder to 0777, and this mapping is the first place to look. [[VERIFY: UID 70 can write .local/backups/<env> from a pod through VirtioFS]] | Check the mode. Do not widen the parent, which must stay 0700 |
| `backup already running in <ns>` | Another Job is active | Wait, or delete it if it is truly stuck |
| `PVC backups is missing` | `backup-storage` has not synced | See [Argo sync stuck](argo-sync-stuck.md) |
| Connection refused or timeout to `plane-pgdb` | Postgres is down, or NetworkPolicy dropped the Job. The Job needs label `app.kubernetes.io/component: backup` | Check the pod and the policy |
| `exceeded quota` | The Job would pass the namespace's pod or memory quota, typically during a rollout | Wait for the rollout to finish |
| `*.partial` folder left behind | Backup died midway. A final name appears only after all checks. Partials older than a day are removed by the next run | Safe to ignore |

## Restore

**Restore Infisical first if both were lost.** A Plane database restored beside freshly generated Infisical secrets has a `SECRET_KEY` mismatch and breaks silently, so `restore.sh` refuses it.

```bash
make restore ENV=dev BACKUP=latest
make restore ENV=dev BACKUP=20261104T120000Z CONFIRM=yes
make restore ENV=infisical BACKUP=latest CONFIRM=yes
```

`CONFIRM=yes` is required to overwrite an environment that holds users or objects. Refusals all come before anything changes:

| Refusal | Why |
|---|---|
| Checksums do not match | `SHA256SUMS` is verified on the host |
| Manifest names another environment | Each PVC mounts only its own folder, so a backup restores only into the environment that took it |
| Backup from a newer Plane than is running | Django cannot migrate backwards. Roll the image forward or back first |
| `SECRET_KEY` fingerprint differs | Encrypted rows would decrypt silently to nothing. `ALLOW_SECRET_KEY_MISMATCH=yes` accepts that loss, and the script then exits non-zero even though data is back |
| Target holds data, no `CONFIRM=yes` | Overwrite guard |

Then, for a Plane environment:

1. Pause auto-sync, root first.
2. Scale API, worker, beat and live to zero.
3. `dropdb`, `createdb`, `pg_restore` in one transaction. Row counts and content hashes must equal the backup exactly.
4. `rclone sync`, so objects absent from the backup are removed, then a downloading check, then a gate that every uploaded asset has an object.
5. Flush Valkey, purge `celery`. Old cache entries and queued tasks describe rows from before the restore.
6. Run the migrator, in a Job copied from the rendered manifest, using the image the API runs now.
7. Start the apps, API first, using replica counts from Git, so a run that died at zero cannot make zero the target.
8. Prove: encrypted sentinel, no empty decrypts, sentinel work item and attachment through `tests/e2e/smoke.py`, a worker running a new job, and green probes.
9. Resume auto-sync, also on failure.

### If it stops with "has had a sync running for 180s"

Every Application has `retry.limit: -1`, so an Application whose sync is failing stays in phase `Running`, and `argo_wait_idle` gives up. That is the exact moment you are likely to want a restore. Terminate the operation first, then re-run:

```bash
kubectl -n argocd patch application plane-dev --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd get application plane-dev -o jsonpath='{.status.operationState.phase}{"\n"}'
```

[[VERIFY: the Terminating patch ends a retrying operation, and make restore then proceeds; or scripts now do this themselves]]

### On a new cluster

Secret zero in `.local/secret-zero/` must survive, or the Infisical dump cannot be read. The order is in [Clean rebuild](clean-rebuild.md). Re-run bootstrap after restoring Infisical, because Kubernetes Auth stores the old cluster's CA.

## Confirm

```bash
jq '{result, failed: [.steps[] | select(.status != "PASS")]}' "$(ls -1t .local/evidence-raw/restore-*.json | head -1)"
make test-e2e ENV=dev
```

Restore evidence has one line per step, labelled PASS, FAIL or NOT RUN. A `NOT RUN` means a proof could not be made, usually because the backup was taken before a sentinel existed. It does not mean the proof passed, so do not report it as a success.

[[VERIFY: make restore ENV=dev brings back the sentinel work item and attachment and result is PASS]]

[[VERIFY: make restore ENV=infisical returns /api/status 200 and Plane Secrets still sync]]

[[VERIFY: restore.sh refuses a backup whose SECRET_KEY fingerprint differs]]

[[MEASURE: backup duration and size per environment]]

[[MEASURE: restore duration per environment, stop of apps to probes green]]

## What not to do

| Do not | Why |
|---|---|
| Delete a data PVC to "test" a restore without a fresh backup | The default `standard` class deletes the volume's data with its PV |
| `pg_restore --clean` into the live database by hand | Tables newer than the dump would survive. The script uses `dropdb` on purpose |
| Copy a backup between environment folders | The script refuses it. Each environment's data and `SECRET_KEY` belong together |
| Restore a Plane dump after reseeding Infisical | `SECRET_KEY` mismatch, silent loss of encrypted rows |
| Report a `NOT RUN` proof as passed | The evidence rule forbids it |
| Treat backups as off-site | They are on the same disk as Docker. Losing the Mac loses both |
| Copy a backup into `docs/evidence/` | It holds hashes and tokens. Copy only the JSON evidence, which holds counts and step results |
| Rely on `.local/backups` while the disk is nearly full | Check `df -h .` first. See [Disk pressure](disk-pressure.md) |
