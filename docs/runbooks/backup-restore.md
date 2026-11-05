# Backup and restore

Take a backup, bring data back, and handle the failures in between. For wider scenarios, such as losing the whole cluster, see
[Disaster recovery](../disaster-recovery.md). For the design, see [Data operations](../data-operations.md).

**Status, 2026-11-05.** Backups of all three have run. Infisical has been restored in place, and dev and prod-sim have each been restored in place into their real database and bucket, with result PASS and `make test-e2e` passing after. A restore into a new cluster is in progress as this is written, with no result recorded here yet. The one marker left here waits on that run.

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
| `has had a sync running for 180s, so terminating it` from `make restore` | The Application was in a retry loop, and the script ended that sync to go on. See below |
| `is still Running after 300s, and terminating its sync did not end it` | The script gave up. See below |

## Back up

```bash
make test-e2e ENV=dev         # once, before the first backup: creates the sentinel a restore reads back
make backup ENV=dev
make backup ENV=prod-sim
make backup ENV=infisical
make backup ENV=all
ls -1 .local/backups/dev/
```

There is no CronJob. Backups run when you run them, and also inside these commands: `make promote ENV=prod-sim`, a `make gitops-publish` that changes a prod-sim image, `make destroy`, `make drill-clean-restore`, and, for Infisical, a `make rotate` that finished.

| Part | Method |
|---|---|
| Postgres | `pg_dump -Fc` with the server's own image, then a restore into a scratch database. Row counts and content hashes come from that scratch copy, so each backup is restored once as it is made |
| Objects | `rclone copy` from Silo, then `rclone check --download`. Plane only |
| Keys | Only a truncated hash of `SECRET_KEY` or `ENCRYPTION_KEY` in the manifest, never the key |
| Excluded rows | `api_activity_logs`, `webhook_logs`, `email_notification_logs`. Schema is kept |
| Retention | Newest 3 for dev, 5 for others. `KEEP=<n>` overrides. Plane also keeps, past that, the newest backup that holds users. Infisical counts only complete recovery sets, and runs its retention from the host once this backup's set is complete |
| Recovery set | Infisical: `recovery/terraform.tfstate`, and `recovery/set.json`, which names secret zero by sha256. Plane: that environment's test accounts and sentinel, and object Content-Types. Written from the host, after the Job |
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
| Permission denied under `/backups` | UID 70 cannot write through VirtioFS. `backup.sh` sets the environment folder to 0777, and with that a Job as UID 70 writes there ([dr-backup-modes-1.txt](../evidence/runs/dr-backup-modes-1.txt)), so this mapping is the first place to look | Check the mode. Do not widen the parent, which must stay 0700 |
| `backup already running in <ns>` | Another Job is active | Wait, or delete it if it is truly stuck |
| `PVC backups is missing` | `backup-storage` has not synced | See [Argo sync stuck](argo-sync-stuck.md) |
| Connection refused or timeout to `plane-pgdb` | Postgres is down, or NetworkPolicy dropped the Job. The Job needs label `app.kubernetes.io/component: backup` | Check the pod and the policy |
| `exceeded quota` | The Job would pass the namespace's pod or memory quota, typically during a rollout | Wait for the rollout to finish |
| `*.partial` folder left behind | Backup died midway. A final name appears only after all checks. Partials older than a day are removed by the next run | Safe to ignore |
| `a clean restore is under way` | That environment is empty or partly restored, and a backup of it could push out the one that holds the data | Finish the restore. `ALLOW_BACKUP_DURING_RESTORE=yes` backs it up anyway |
| `its recovery set is not whole` | Infisical's dump is good, but a file the set names, or the API, was missing. Retention did not run | An in-place restore can use this dump, and `make restore-clean` refuses it. Fix what the warnings name and back up again |

## Restore

**Restore Infisical first if both were lost.** A Plane database restored beside freshly generated Infisical secrets has a `SECRET_KEY` mismatch and breaks silently, so `restore.sh` refuses it.

```bash
make restore ENV=dev BACKUP=latest
make restore ENV=dev BACKUP=20261104T120000Z CONFIRM=yes
make restore ENV=infisical BACKUP=latest CONFIRM=yes
INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh   # after Infisical: refreshes the CA and identity Secrets, writes no value
```

`CONFIRM=yes` is required to overwrite an environment that holds users or objects. Refusals all come before anything changes:

| Refusal | Why |
|---|---|
| Checksums do not match | `SHA256SUMS` is verified on the host |
| Manifest names another environment | Each PVC mounts only its own folder, so a backup restores only into the environment that took it |
| Backup from a newer Plane than is running | Django cannot migrate backwards. Roll the image forward or back first |
| `SECRET_KEY` fingerprint differs | Encrypted rows would decrypt silently to nothing. `ALLOW_SECRET_KEY_MISMATCH=yes` accepts that loss, and the script then exits non-zero even though data is back |
| Target holds data, no `CONFIRM=yes` | Overwrite guard |
| The backup records rows marked uploaded with no object | The restore's GATE2 would refuse it with the data already replaced, and has no override. Choose another backup |
| Infisical: a dump from a newer version than is running | Its migrations go forward only, so that server would refuse to start. `ALLOW_NEWER_INFISICAL_BACKUP=yes` goes past it |
| Infisical: a dump older than the last rotation or manual change | The operators would render a password Plane's Postgres no longer takes. `ALLOW_STALE_PLANE_SECRETS=yes` goes past it |
| Infisical: no token or password here that could log in afterwards | Nothing could prove the restore. `ALLOW_NO_ADMIN_TOKEN=yes` goes past it, as when its Postgres is lost, and it may stop with exit 3 and sign-in steps |

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

For Infisical it pauses auto-sync on `infisical` only, stops the server, restores into a second database and checks its row counts, swaps it in with two renames in one transaction, installs the Terraform state and machine file that go with it, flushes Redis, starts the server, makes sure something here can log in, and proves it. In place it took 51 s to 71 s, five times, and no Plane workload moved ([dr-inplace-restore-3.txt](../evidence/runs/dr-inplace-restore-3.txt)).

If the client ends while a restore Job runs, by Ctrl-C, a closed terminal or a kubectl error, it removes that Job first. If it cannot, the server or apps stay down and auto-sync stays paused, and it prints what to run. That has run only on stubs ([dr-stop-sweep-1.txt](../evidence/runs/dr-stop-sweep-1.txt)).

### If it says "has had a sync running for 180s"

Every Application has `retry.limit: -1`, so an Application whose sync is failing stays in phase `Running`. That is the exact moment you are likely to want a restore. So `argo_wait_idle` in `monitoring/ops/lib.sh` terminates the operation at 180 s and goes on, and gives up at 300 s if that did not end it. The script's path has run only on a stub ([test_lib-stub-1.txt](../evidence/runs/test_lib-stub-1.txt)). On real throwaway Applications, Terminating ended a running hook and a retry backoff, and neither restarted by itself 40 s later. A newer commit then synced ([argocd-terminate-2.txt](../evidence/runs/argocd-terminate-2.txt)). So after this, Argo CD will not retry that revision until something changes.

If it gives up, look at the phase. The same patch by hand:

```bash
kubectl -n argocd patch application plane-dev --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd get application plane-dev -o jsonpath='{.status.operationState.phase}{"\n"}'
```

### On a new cluster

Use `make restore-clean BACKUP=latest`, not `make restore`. Secret zero in `.local/secret-zero/` must survive, or the Infisical dump cannot be read. The order is in [Disaster recovery](../disaster-recovery.md#full-restoration-into-a-clean-environment), and [Clean rebuild](clean-rebuild.md) has the commands. Its first real run is in progress as this is written, inside `make drill-clean-restore`, with no result recorded here yet. Before that it had run only as far as its plan, and against stubs.

## Confirm

```bash
jq '{result, failed: [.steps[] | select(.status != "PASS")]}' "$(ls -1t .local/evidence-raw/restore-*.json | head -1)"
make test-e2e ENV=dev
```

Restore evidence has one line per step, labelled PASS, FAIL or NOT RUN. A `NOT RUN` means a proof could not be made, usually because the backup was taken before a sentinel existed. It does not mean the proof passed, so do not report it as a success. `scripts/restore.sh` exits 2 for one, except `proof-probes`. It exits 1 on a failure, and `restore.sh infisical` exits 3 when Infisical is back and a person has to sign in. Through `make`, any of these is make's own exit 2, and make prints which.

`make restore` with `CONFIRM=yes` has run once in each Plane environment. Each brought back the sentinel work item and attachment, a worker ran a new job, `result` reads PASS, `not_run` is empty, and `make test-e2e` then passed ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [BKP-2-20261105T074322Z.txt](../evidence/runs/BKP-2-20261105T074322Z.txt), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json), [SEC-3-BKP-3-20261105T073240Z.txt](../evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt)). With no `CONFIRM`, prod-sim refused: 31 users and 66 objects already there, "Nothing was changed", make exit 2 ([restore-prod-sim-20261105T073428Z.json](../evidence/runs/restore-prod-sim-20261105T073428Z.json)). Dev was not asked that.

**What this does not prove.** Each restore used the backup taken moments before, over the same rows, so no real loss was repaired. The database was dropped and recreated from the dump. The bucket already held the objects, and Content-Type was put back on 0 of them, so copying objects back ran for real only in the [rehearsal](../evidence/runs/dr-plane-restore-rehearsal-1.txt).

`make restore ENV=infisical` returned `/api/status` 200 in all five runs, with `proof-values` PASS. Afterwards `make test-infisical` exited 0 with 118 PASS lines, including each rendered Secret, and all 14 Applications read Synced and Healthy ([dr-inplace-restore-3.txt](../evidence/runs/dr-inplace-restore-3.txt), [dr-after-restores-1.txt](../evidence/runs/dr-after-restores-1.txt)). The operators kept syncing on the same database contents, so this does not show a change of value reaching a Secret after a restore.

[[VERIFY: restore.sh refuses a backup whose SECRET_KEY fingerprint differs, from the restore-foreign-key-refused step of the clean install in progress]]

Backup duration and size: dev 15 s and 78 MiB, prod-sim 11 s with no objects, about 17 s with 66, and 51 MiB with 61, Infisical 22 s and 6.0 MiB. See [Data operations](../data-operations.md#retention) for what each rests on.

Restore duration: Infisical 51 s to 71 s in place. Plane in place, from the start stamp to the evidence file's last write ([MANIFEST.tsv](../evidence/runs/MANIFEST.tsv)): dev 178 s with 97 objects, prod-sim 183 s with 66. That covers the checks and all the proofs. The time from stopping the apps to green probes was not timed on its own, and a larger dataset will take longer.

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
