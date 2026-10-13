# Restore on hosted production

Take a backup on hosted production, prove that one restores, and bring data back. There, backups are nightly CronJobs in `plane-prod` and
`infisical`, sealed with restic into repositories on the node, and this Mac pulls an encrypted copy when someone runs the pull. The local
platform's `make backup` and `make restore` take `dev`, `prod-sim` and `infisical` on kind only. [Backup and restore](backup-restore.md)
covers those.

**Status, 2026-11-07.**

| What | Result | Evidence |
|---|---|---|
| `make remote-backup TARGET=plane-prod CONFIRM=plane-prod`, first try, 06:47Z | FAIL. Infisical's Job was refused by its Postgres, and Plane's read the refusal as Plane not being deployed and sealed only the predeploy dump. `backup.sh` no longer counts that line as a pass once Application `plane-prod` exists, and the Jobs now wait up to a minute for Postgres | `backup-plane-prod-20261107064758.txt`, not published yet |
| The same, 07:07Z | PASS. Infisical sealed, 785 tables counted from a scratch restore. Plane sealed, 110 tables, and its 2 objects checked by download | `backup-plane-prod-20261107070754.txt`, not published yet |
| A nightly on its own schedule | NOT RUN yet. Argo CD first ran on the node at about 04:30Z on 2026-11-07 ([bootstrap](../evidence/runs/hosted-bootstrap-20261107T042651Z.txt)), after that day's schedules, so the first nights are 01:47Z and 02:17Z on 2026-11-08 | |
| `make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod`, on the VPS | PASS, 11 of 11 rows, ended 07:19:11Z. Both restored and proved, each with its key, no route from the test namespace to any of five live addresses, and live data unchanged | `restore-test-plane-prod-20261107071414.json` and `hosted-restore-test-vps-20261107T071414Z.log`, not published yet |
| `make remote-pull-backups TARGET=plane-prod`, then `make remote-backup-dest TARGET=plane-prod VERB=verify` | PASS. Both repositories copied here, each newest snapshot restored into a folder here, and all 5 and 16 files matched their hashes. Status read complete, with no S3 destination | `hosted-pull-20261107T071339Z.log`, not published yet |
| `make remote-restore-test TARGET=plane-prod RESTORE_ON=kind`, this Mac's copy in the local cluster | NOT RUN | |
| A restore into live `plane-prod` or `infisical` | NOT RUN | |

Preamble for raw commands, from the checkout that holds `.local/hosted/plane-prod/`:

```bash
kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
make remote-tunnel TARGET=plane-prod VERB=status   # VERB=start if it is down
```

## The copies

| Copy | Where | What it holds | Kept |
|---|---|---|---|
| Nightly, on the node | A restic repository per namespace, `/srv/wayline/backups/plane-prod/restic` and `/srv/wayline/backups/infisical/restic`, tag `wayline`. Infisical at 01:47Z, Plane at 02:17Z | Postgres's dump, with the row counts and content hashes a restore checks itself against, and for Plane every object in Silo | 7 daily, 4 weekly and 3 monthly, with `restic check` of 5% of the data each night and a quarter each Sunday |
| Before each migration | `/srv/wayline/backups/plane-prod/predeploy/<time>-<backend digest>/`, plain and owner-only, until that night seals it into Plane's repository under tag `predeploy` and empties the folder | Postgres's dump alone, from just before that backend's migrator ran | The newest five folders, and sealed dumps for 90 days |
| On this Mac | `.local/hosted/plane-prod/offsite-restic/plane-prod` and `.../infisical`, copied with `restic copy` over the read-only SFTP user `wayline-pull`, still encrypted | Tag `wayline` only, so no predeploy dump | 90 days, by time alone |
| S3 | Only once `.local/hosted/plane-prod/offsite-s3-*` exist, which `scripts/hosted/owner-inputs.sh offsite` writes. None exist | The same as this Mac's | 90 days |

Every copy is encrypted with one restic password, `.local/hosted/plane-prod/restic-password`. Bootstrap made it once, gave the cluster a
copy as Secret `restic-password` in each of the two namespaces, for the nightly, and the recovery bundle holds another. Without it no copy
can be read.

The VPS holds no credential for any copy off it: the pull key and any S3 key stay on this Mac, which reads the node. So a compromised VPS can
neither reach the copy here nor delete it. The cost is that nothing leaves the VPS while this Mac is off, and nothing runs the pull on a
schedule. This Mac's copy is the only one off the VPS today.

## Symptoms that bring you here

| Symptom | Meaning |
|---|---|
| `PlaneBackupFailed`, for `plane-prod` or `infisical` | A backup Job failed. It stays until the Job's TTL, or until `make remote-backup` succeeds and removes the failed Jobs |
| `BackupTooOld` | That namespace's last success is over 26 hours old |
| `BackupNeverSucceeded` | No success at all in 26 hours, or the CronJob is gone |
| `make remote-status` reads `off-VPS backups incomplete` | A namespace has had no restore from an off-VPS copy in the last 35 days |
| Data is wrong or missing | Decide whether to restore: [Bring data back](#bring-data-back) |

## Diagnosis of a failed backup

```bash
make remote-status TARGET=plane-prod          # section Backups: last success and last start of each CronJob
NS=plane-prod                                 # or infisical
kc -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup
JOB="$(kc -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup -o name | tail -1)"
kc -n "$NS" logs "$JOB" --all-containers --prefix --tail=50
kc -n "$NS" describe "$JOB" | tail -15
kc -n "$NS" describe resourcequota
```

| Log or state | Cause | Fix |
|---|---|---|
| `Connection refused` to Postgres | kube-router refuses a new pod's connections for a second or two after it starts, so the Jobs wait up to a minute. A refusal after that is Postgres down | Look at the Postgres pod |
| `Plane is not answering here, and a repository says it was` | Postgres did not answer, and a repository exists, so this is not a new install | Fix Postgres, then back up |
| No pod, or `exceeded quota`, in `infisical` | The namespace's quota fits one of the server's rollout, the backup and a certificate's solver at a time | Wait for the other. [`scripts/hosted/README.md`](../../scripts/hosted/README.md), section The first certificate, covers a solver that waits |
| `DeadlineExceeded` | Infisical's Job has 2 hours and Plane's 4 | Read the last container's log |
| Evicted | Plane's scratch space is an `emptyDir` of 30Gi, which holds a full copy of Silo's objects each night | Raise its limit in Git, in [`plane-prod.yaml`](../../gitops/clusters/plane-prod/platform/backup/plane-prod.yaml) |
| `cannot read the repository` | restic cannot open the repository under `/srv/wayline/backups` | Read the node's disk and the folder's owner: [Disk pressure](disk-pressure.md#hosted-production) |

## Back up now

```bash
make remote-backup TARGET=plane-prod CONFIRM=plane-prod                  # Infisical, then Plane
make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod
```

It makes a Job from each CronJob as the cluster holds it, so it proves what the night will do, and prints the Job's logs, which hold counts
and no value. Exit 0 sealed, 1 failed. Evidence: `.local/evidence-raw/backup-plane-prod-<stamp>.txt`.

## Prove a backup restores

On the VPS, from the node's own repositories:

```bash
make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod
make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod KEEP=yes   # one, and keep the namespace to look at
```

It restores the newest nightly into a new namespace, `restore-test-<14 digits>`, with default deny, a quota and no route, and proves there:
every file against the hashes sealed with it, the dump into an empty Postgres on a socket with no TCP, the row counts and Plane's content
hashes as the backup recorded them, every row marked uploaded with its object, and each backup's key fingerprint against the key it must
pair with: Plane's live `SECRET_KEY`, and the `ENCRYPTION_KEY` in this Mac's secret zero for Infisical. It also shows a pod there cannot
reach either live Postgres, Silo, the API server or DNS, and that live workloads, volumes, Secrets and databases read the same after as
before. Then it deletes the namespace. kube-router refuses what a policy denies, so a refusal from inside counts as no route only while the
node connects to that port. Exit 0 proved, 1 not, 2 could not run. Evidence: `.local/evidence-raw/restore-test-plane-prod-<stamp>.json`.
With `KEEP=yes` the namespace holds plaintext data until you delete it.

From this Mac's copy:

```bash
make remote-pull-backups TARGET=plane-prod
make remote-backup-dest TARGET=plane-prod VERB=verify
make remote-backup-dest TARGET=plane-prod VERB=status
make remote-restore-test TARGET=plane-prod RESTORE_ON=kind               # needs the local cluster up, and touches no VPS
```

`verify` checks a tenth of each repository's data, restores its newest snapshot into a folder under `.local/hosted/plane-prod/`, checks
every file against its `SHA256SUMS`, and removes the folder, which is plaintext. `RESTORE_ON=kind` streams the same copy into an isolated
namespace of the local cluster and proves it as on the VPS. Either one records the restore, and `status` reads complete only while each
namespace has one from the last 35 days. A pull alone does not count. The pull's SFTP user is made once, by
`make remote-pull-setup TARGET=plane-prod CONFIRM=plane-prod`, and bootstrap made it at its step 4
([bootstrap](../evidence/runs/hosted-bootstrap-20261107T042651Z.txt)).

## Bring data back

**Back up first, and roll back first.** `make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod` keeps what is there now.
If a release did the damage, roll its images back before restoring, as [Rollback on hosted production](hosted-rollback.md) says, or its
migrator runs again on what you restore.

**Plane's database, from the dump before a migration.** [`scripts/hosted/README.md`](../../scripts/hosted/README.md), section After a
rollback: the database does not go back, has the steps and the Job. The Job reads the plain folder if it is still there, and the sealed
snapshot if not. NOT RUN on a cluster.

**Plane's database, from a nightly.** The same steps, with the Job's `unseal` step reading the newest nightly in place of a predeploy dump.
Its three lines, which read the predeploy folder or its snapshot, become:

```sh
restic --no-lock restore latest --tag wayline --host plane-prod --target /work/restored --verify
cp /work/restored/work/backup/postgres/plane.dump /work/plane.dump
```

A nightly is restored under the path it was taken from, `/work/backup`. For an older night, name its snapshot in place of `latest`: list the
node's snapshots through the pull user, the way `copy_from_node` in [`lib-restic.sh`](../../scripts/hosted/lib-restic.sh) reaches the node.
Snapshot ids on this Mac's copy differ from the node's, because `restic copy` writes new ones. NOT RUN.

**Silo's objects.** A nightly holds them under `work/backup/objects`. Nothing here copies them back into the live Silo. A restore of
Postgres alone leaves Silo as it is, so restored rows still find their objects while Silo's volume lasts, and objects uploaded since are left
over and harmless. Putting objects back after Silo's volume is lost has no written procedure: NOT RUN.

**Infisical.** No script restores Infisical on hosted production, in place or on a new node. The restore test proves its nightly restores and
pairs with this Mac's `ENCRYPTION_KEY`. NOT RUN.

**Files out of a copy, on this Mac.** A restore into a folder needs no cluster:

```bash
R=.local/hosted/plane-prod/offsite-restic/plane-prod
.tools/bin/restic -r "$R" --password-file .local/hosted/plane-prod/restic-password snapshots --host plane-prod --tag wayline
mkdir -m 700 .local/hosted/plane-prod/restored
.tools/bin/restic -r "$R" --password-file .local/hosted/plane-prod/restic-password restore <snapshot> \
  --target .local/hosted/plane-prod/restored --verify
```

The dump holds password hashes and API tokens, so keep it under `.local/hosted/plane-prod/`, which is mode 0700, and delete it when done.
`backup-dest.sh verify` runs that restore into a folder it removes, and passed as above. By hand: NOT RUN.

**The VPS is lost.** This Mac's copy and the recovery bundle are what remain. A new node comes up through `provision-node.sh`,
`kubeconfig.sh`, `owner-inputs.sh` and `bootstrap.sh`, and nothing restores Infisical's and Plane's data into it from this Mac's copy: no
script, NOT RUN. [Disaster recovery](../disaster-recovery.md#hosted-production) has the order of a rebuild, and what it does not bring back.

## Confirm

```bash
make remote-status TARGET=plane-prod
make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=backups
```

`ONLY=backups` reads a success in the last 26 hours for each CronJob, the off-VPS status, and whether a recovery bundle exists here. After
a restore into `plane-prod`, add `ONLY=argo` and `make remote-smoke TARGET=plane-prod`.

## What not to do

| Do not | Why |
|---|---|
| Use `make backup` or `make restore` for hosted production | They take `dev`, `prod-sim` and `infisical` on kind only |
| Restore over live data with no `make remote-backup` first | The restore drops the database, and what was written since the dump is gone |
| Put the pull key or an S3 key on the VPS | The VPS holds no credential for the copies off it, so a compromised VPS cannot delete them |
| Remove files under `/srv/wayline/backups` by hand | The repositories are restic's to prune, and a predeploy folder's name is how the hook knows a backend has its dump |
| Leave a `KEEP=yes` namespace, or a folder restored by hand | Each holds plaintext data |
| Count a pull as an off-VPS backup | Only a restore from it counts, and `status` says so |
| Copy a restored dump into `docs/evidence/` | It holds password hashes and API tokens. The evidence JSON holds counts and verdicts only |
