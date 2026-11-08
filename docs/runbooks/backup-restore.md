# Backup and restore

Take a backup, bring data back, and handle the failures in between. For wider scenarios, such as losing the whole cluster, see
[Disaster recovery](../disaster-recovery.md). For the design, see [Data operations](../data-operations.md).

**Status, 2026-11-05.** Backups of all three have run. Infisical has been restored in place, and dev and prod-sim have each been restored in place into their real database and bucket, with result PASS and `make test-e2e` passing after. A restore into a new cluster ran on 2026-11-05 inside `make drill-clean-restore`, with every restore step PASS, and `make test` then passed on the restored platform ([restore-clean-20261105T081017Z.json](../evidence/runs/restore-clean-20261105T081017Z.json), [MAKE-TEST-20261105T083455Z.txt](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)). Two later drills restored into new clusters too, every restore step PASS: one with the registry and caches removed as well, and `LOSE_CLUSTER=yes`, whose log reads `RESULT PASS` ([second](../evidence/runs/restore-clean-20261105T124518Z.json), [third](../evidence/runs/restore-clean-20261105T130828Z.json), [log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)), and `make test` passed again on the cluster the third left ([output](../evidence/runs/MAKE-TEST-20261105T140019Z.txt)).

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
| `this clean restore is resuming, and <ns> holds ...` | A resume found other users or objects than its backup holds, and left that environment as it was. See [On a new cluster](#on-a-new-cluster) |

## Back up

```bash
make test-e2e ENV=dev         # once, before the first backup: creates the sentinel a restore reads back
make backup ENV=dev
make backup ENV=prod-sim
make backup ENV=infisical
make backup ENV=all
ls -1 .local/backups/dev/
```

There is no CronJob. Backups run when you run them, and also inside these commands: `make promote ENV=prod-sim`, a `make gitops-publish` that changes a prod-sim image, `make rollback ENV=prod-sim`, `make destroy`, `make drill-clean-restore`, and, for Infisical, a `make rotate` that finished. `SKIP_BACKUP=yes` skips any of these. In a rollback the dump is a best effort, and a failure does not stop the rollback.

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
| `a clean restore is under way` | The restore has not finished that environment, and nothing has looked at what it holds. A backup of an empty or partly restored one would become the newest, and it may also be real data. An environment whose data has come back is not refused | Finish the restore. `ALLOW_BACKUP_DURING_RESTORE=yes` backs it up anyway, and `make destroy` does that by itself |
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

For Infisical it pauses auto-sync on `infisical` only, stops the server, restores into a second database and checks its row counts, swaps it in with two renames in one transaction, installs the Terraform state and machine file that go with it, flushes Redis, starts the server, makes sure something here can log in, and proves it. In place it has run seven times, in 44 s to 71 s: six read PASS, and one, the 71 s, read BLOCKED, because that run removed the token and the password on purpose. In the six that compared Plane before and after, every Plane pod uid and restart count, workload generation and Secret resourceVersion stayed the same, apart from probe pods of another test and one worker another test replaced ([dr-inplace-restore-3.txt](../evidence/runs/dr-inplace-restore-3.txt), [dr-inplace-no-token-no-password-2.txt](../evidence/runs/dr-inplace-no-token-no-password-2.txt), [dr-inplace-no-token-no-password-3.txt](../evidence/runs/dr-inplace-no-token-no-password-3.txt)).

If the client ends while a restore Job runs, by Ctrl-C, a closed terminal or a kubectl error, it removes that Job first. If it cannot, the server or apps stay down and auto-sync stays paused, and it prints what to run. That holds with a client that can no longer print, as after a terminal that closed or a `tee` that took the same Ctrl-C. Since `233b21f` no error stops it then, and what it has to say goes to `restore-<env>-<time>.json.log` beside the evidence. That has run only on stubs and on a real pty beside them ([dr-stop-sweep-1.txt](../evidence/runs/dr-stop-sweep-1.txt), from before that fix).

### If it says "has had a sync running for 180s"

Every Application has `retry.limit: -1`, so an Application whose sync is failing stays in phase `Running`. That is the exact moment you are likely to want a restore. So `argo_wait_idle` in `monitoring/ops/lib.sh` terminates the operation at 180 s and goes on, and gives up at 300 s if that did not end it. The script's path has run only on a stub ([test_lib-stub-1.txt](../evidence/runs/test_lib-stub-1.txt)). On real throwaway Applications, Terminating ended a running hook and a retry backoff, and neither restarted by itself 40 s later. A newer commit then synced ([argocd-terminate-2.txt](../evidence/runs/argocd-terminate-2.txt)). So after this, Argo CD will not retry that revision until something changes.

If it gives up, look at the phase. The same patch by hand:

```bash
kubectl -n argocd patch application plane-dev --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd get application plane-dev -o jsonpath='{.status.operationState.phase}{"\n"}'
```

### On a new cluster

Use `make restore-clean BACKUP=latest`, not `make restore`. Secret zero in `.local/secret-zero/` must survive, or the Infisical dump cannot be read. The order is in [Disaster recovery](../disaster-recovery.md#full-restoration-into-a-clean-environment), and [Clean rebuild](clean-rebuild.md) has the commands. Its first real run was inside `make drill-clean-restore` on 2026-11-05 at `af8b26e`, and every step read PASS with `not_run` empty, in 1,201 s from the start stamp to the evidence file's last write ([restore-clean-20261105T081017Z.json](../evidence/runs/restore-clean-20261105T081017Z.json), [MANIFEST.tsv](../evidence/runs/MANIFEST.tsv)). Before that it had run only as far as its plan, and against stubs.

If it stops, run the same command again. Since that run a resume treats what it finds more carefully, and all of this has run only on stubs:

- An environment it has not finished that holds other users or objects than its backup is refused, and left as it was. `make backup ENV=<env> ALLOW_BACKUP_DURING_RESTORE=yes` keeps a copy. `ALLOW_RESUME_OVERWRITE=<env>` overwrites what it names and nothing else, `yes` is refused, and that run exits 4 and reads `OVERWROTE`, which is not a pass.
- An environment whose data Job finished has a `data-back <env>` line in `.local/restore-clean.state`. A resume keeps what is there, whatever it holds, and goes on from the migrator, unless `ALLOW_RESUME_OVERWRITE` names it.

[Disaster recovery](../disaster-recovery.md#off-the-normal-path) says what each of these closed.

## Confirm

```bash
jq '{result, failed: [.steps[] | select(.status != "PASS")]}' "$(ls -1t .local/evidence-raw/restore-*.json | head -1)"
make test-e2e ENV=dev
```

Restore evidence has one line per step, labelled PASS, FAIL or NOT RUN. A `NOT RUN` means a proof could not be made, usually because the backup was taken before a sentinel existed. It does not mean the proof passed, so do not report it as a success. `scripts/restore.sh` exits 2 for one, except `proof-probes`. It exits 1 on a failure, `restore.sh infisical` exits 3 when Infisical is back and a person has to sign in, and it exits 4 when everything is proven and it overwrote what `ALLOW_RESUME_OVERWRITE` named, which is not a pass. Through `make`, any of these is make's own exit 2, and make prints which.

`make restore` with `CONFIRM=yes` has run once in each Plane environment. Each brought back the sentinel work item and attachment, a worker ran a new job, `result` reads PASS, `not_run` is empty, and `make test-e2e` then passed ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [BKP-2-20261105T074322Z.txt](../evidence/runs/BKP-2-20261105T074322Z.txt), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json), [SEC-3-BKP-3-20261105T073240Z.txt](../evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt)). With no `CONFIRM`, prod-sim refused: 31 users and 66 objects already there, "Nothing was changed", make exit 2 ([restore-prod-sim-20261105T073428Z.json](../evidence/runs/restore-prod-sim-20261105T073428Z.json)). Dev was not asked that.

**What this does not prove.** Each restore used the backup taken moments before, over the same rows, so no real loss was repaired. The database was dropped and recreated from the dump. The bucket already held the objects, and Content-Type was put back on 0 of them, so these runs did not copy objects back. The [rehearsal](../evidence/runs/dr-plane-restore-rehearsal-1.txt) did, into a scratch bucket, and so did the restore into a new cluster, over an empty target: 102 objects in dev and 71 in prod-sim synced and checked by download, Content-Type back on 64 and 45 of them, and every uploaded asset with its object, 65 and 46 ([drill log](../evidence/runs/drill-clean-restore-20261105T074859Z.log), [restore-dev-20261105T082337Z.json](../evidence/runs/restore-dev-20261105T082337Z.json), [restore-prod-sim-20261105T082657Z.json](../evidence/runs/restore-prod-sim-20261105T082657Z.json)). That backup too was moments old.

`make restore ENV=infisical` returned `/api/status` 200 in all seven runs. `proof-values` read PASS in six. In the other it read NOT RUN and the result BLOCKED, because that run removed the token and the password on purpose ([dr-inplace-no-token-no-password-2.txt](../evidence/runs/dr-inplace-no-token-no-password-2.txt)). Afterwards `make test-infisical` exited 0 with 118 PASS lines, including each rendered Secret, and all 14 Applications read Synced and Healthy ([dr-inplace-restore-3.txt](../evidence/runs/dr-inplace-restore-3.txt), [dr-inplace-no-token-no-password-3.txt](../evidence/runs/dr-inplace-no-token-no-password-3.txt), [dr-after-restores-1.txt](../evidence/runs/dr-after-restores-1.txt)). The operators kept syncing on the same database contents, so this does not show a change of value reaching a Secret after a restore.

`restore.sh` refusing a backup whose `SECRET_KEY` fingerprint differs ran on a real install at 2026-11-05T08:09:20Z, on the clean install, which has new secrets. `make restore ENV=dev BACKUP=20261105T074932Z CONFIRM=yes`, with a backup of the install before it, stopped at the fingerprint and said "Nothing was changed" ([restore-foreign-key-refused.txt](../evidence/runs/clean-install-20261105T075041Z/restore-foreign-key-refused.txt)). It and the other refusals have also run on stubs ([dr-harness-stubbed-4.txt](../evidence/runs/dr-harness-stubbed-4.txt)).

Backup duration and size: dev 15 s with 92 objects, and 78 MiB for that backup, `20261105T062141Z`. Prod-sim 11 s with no objects, about 17 s with 66, and 51 MiB for `20261105T053351Z` with 61. Infisical 22 s and 6.0 MiB. Backups grow with the smoke runs: on 2026-11-05 at 08:37Z the newest read 87 MiB in dev and 60 MiB in prod-sim. See [Data operations](../data-operations.md#retention) for what each rests on.

Restore duration: Infisical 44 s to 71 s in place, over seven runs, and the 71 s is the BLOCKED one ([dr-inplace-no-token-no-password-2.txt](../evidence/runs/dr-inplace-no-token-no-password-2.txt), [dr-inplace-no-token-no-password-3.txt](../evidence/runs/dr-inplace-no-token-no-password-3.txt)). Plane in place, from the start stamp to the evidence file's last write ([MANIFEST.tsv](../evidence/runs/MANIFEST.tsv)): dev 178 s with 97 objects, prod-sim 183 s with 66. Into the new cluster, the same way: Infisical 43 s, with the server not answering for 34 s, dev 200 s with 102 objects, prod-sim 199 s with 71 ([MANIFEST.tsv](../evidence/runs/MANIFEST.tsv), [restore-infisical-20261105T081608Z.json](../evidence/runs/restore-infisical-20261105T081608Z.json)). That covers the checks and all the proofs. The time from stopping the apps to green probes was not timed on its own, and a larger dataset will take longer.

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

## Hosted production

None of this page reaches hosted production. `make backup` and `make restore` take `dev`, `prod-sim` and `infisical` on kind only.
[Restore on hosted production](hosted-restore.md) covers its backups, the restore tests and the ways back. What differs:

| | Here | Hosted production |
|---|---|---|
| When backups run | When a script takes them | Nightly CronJobs, Infisical at 01:47Z and Plane at 02:17Z, and `make remote-backup TARGET=plane-prod CONFIRM=plane-prod` |
| Where they go | `.local/backups/<env>/<id>/` on this Mac, a folder at 0700 | restic repositories on the node under `/srv/wayline/backups`, encrypted, and a copy on this Mac when someone runs `make remote-pull-backups TARGET=plane-prod` |
| Before a migration | `make promote ENV=prod-sim` takes a dump | The Sync hook `plane-prod-predeploy-dump` takes one per backend image |
| Kept | The newest 3 or 5 | 7 daily, 4 weekly and 3 monthly. Predeploy dumps 90 days, and the copy on this Mac 90 days |
| Proof | `make restore`, in place, with its sentinel | `make remote-restore-test`, into an isolated namespace. PASS on the VPS on 2026-11-07 ([record](../evidence/runs/restore-test-plane-prod-20261107071414.json)), and again on 2026-11-08 for Plane's backup with the objects step from one listing ([record](../evidence/runs/restore-test-plane-prod-20261108001626.json)) |
| Restore in place | `make restore`, PASS in each environment | No script. The steps for Plane's database are in [`scripts/hosted/README.md`](../../scripts/hosted/README.md), section After a rollback: the database does not go back. NOT RUN |
| Off the machine | No copy | This Mac's pull, the only one. S3 once its files exist |
