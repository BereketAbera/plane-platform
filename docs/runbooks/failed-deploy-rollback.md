# Failed deploy and rollback

A bad image or a bad migration reached an environment through a promotion.

The drills and the rollback below ran in dev on 2026-11-05, starting from the final images built from `84b63d9`. A rollback of prod-sim was not tested in Pass 1.

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NS=plane-dev APP=plane-dev   # or plane-prod-sim for both
```

## Symptoms

| Symptom | Likely meaning |
|---|---|
| One pod in `ErrImagePull` or `ImagePullBackOff`, old pods still Ready | The digest cannot be pulled. The rollout is stuck, and users are still served by old pods |
| `Application` is `Degraded`, or `ArgoAppDegraded` is firing | The Deployment passed its progress deadline |
| Deployment condition `ProgressDeadlineExceeded` | Same. The hardening patch sets `progressDeadlineSeconds: 600` on all seven Deployments in both environments (`gitops/environments/*/manifests.yaml`), so this takes up to 10 minutes |
| Job `plane-api-migrate-1` failing, Deployments unchanged | Migration failed. Deployments are wave 3 and the hook is wave 2, so they do not move. The Application reads `OutOfSync`, **`Healthy`**, `Running`, so health alone hides this |
| `Running` phase with "Retrying attempt #N" | Argo CD is retrying. See [Argo sync stuck](argo-sync-stuck.md) |
| `Running` phase with "waiting for healthy state of apps/Deployment/..." | The rollout has not finished or failed yet. Deployments are wave 3 of 4, so the sync waits on it |
| New pods crash, `PlanePodCrashLooping` firing | Image is pullable but broken. See [Plane app debugging](plane-app-debugging.md) |

With `RollingUpdate`, a bad image on a Deployment leaves old pods serving. Measured once, on 2026-11-05 in dev, with the `web` image: the drill's 61 samples through Traefik all read 200 while the rollout failed, and the old pod stayed Ready ([drill-failed-deploy-20261105T062343Z.log](../evidence/runs/drill-failed-deploy-20261105T062343Z.log)). A watcher beside it read 913 signed-in `GET /api/users/me/` and 458 cycles of `/`, `/sign-in/`, `/god-mode/` and `/spaces/` over the whole drill, all 200 ([DEP-1-20261105T062323Z-timeline.txt](../evidence/runs/DEP-1-20261105T062323Z-timeline.txt)). That covers one Deployment and an image that cannot be pulled. It says nothing about an image that pulls and then crashes.

**What fired.** In that run only `Watchdog` reached the sink, and everything else stayed pending. The Application first read Degraded 10m24s in and the drill reverted 8s later, so `ArgoAppDegraded` stayed far from its 5 minutes. `ArgoSyncFailed` stayed pending for 13m45s against its 15 minutes, so a revert about 75s later would have let it fire ([drill-failed-deploy-20261105T062343Z-alerts.tsv](../evidence/runs/drill-failed-deploy-20261105T062343Z-alerts.tsv)). If nobody reverts, `monitoring/manifests/shared/rules-platform.yaml` reads as `ArgoAppDegraded` 5 minutes after the first Degraded and `ArgoSyncFailed` at 15 minutes. That half has not been seen on a Plane Deployment. See [what fires for which failure](argo-sync-stuck.md#what-fires-for-which-failure).

## Diagnosis

```bash
kubectl -n argocd get application "$APP" \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{" "}{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'
kubectl -n "$NS" get pods
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -20
kubectl -n "$NS" get jobs
git log --grep='^promote' --format='%h %cI %s' -5
```

Then decide whether a migration ran. That decides whether an image rollback is enough:

```bash
kubectl -n "$NS" logs job/plane-api-migrate-1 --tail=50
git log --grep='^promote' -1 --format='%B'
```

The `Promote-Image` trailers name the images that commit changed. Only the backend image carries migrations, so a change to `web`, `admin`, `space` or
`live` alone cannot have changed the schema.

## Fix

### Roll back the image

```bash
make rollback ENV=dev
make rollback ENV=prod-sim CONFIRM=yes
```

`scripts/rollback.sh` finds the newest promotion of that environment that has not been reverted, runs `git revert`, re-renders,
and publishes. Git stays the source of truth and auto-sync stays on. Running it again steps back one promotion further. A later change beside an image line
makes the revert conflict in the rendered file, which is generated, so rendering replaces it and the rollback goes on. A conflict anywhere else stops it with nothing changed.
The steps are in [Argo CD](../argocd.md#rollback).

`make rollback ENV=dev` ran on the real cluster on 2026-11-05. It reverted `1fc9fbe` as `91ef477`, the six Deployments on those images went back to their earlier digests,
prod-sim's render did not move, and `smoke.py --mode verify --job-probe` passed on the rolled-back images. `make promote ENV=dev` then put the final images back as `29316f2`
([DEP-2-20261105T064032Z-rollback.txt](../evidence/runs/DEP-2-20261105T064032Z-rollback.txt), [DEP-2-20261105T064032Z-verify-on-rolled-back.txt](../evidence/runs/DEP-2-20261105T064032Z-verify-on-rolled-back.txt), [DEP-2-20261105T064032Z-promote-forward.txt](../evidence/runs/DEP-2-20261105T064032Z-promote-forward.txt)). These two image sets differ in no migration, so this did not put old code on a newer schema. A rollback of prod-sim has run only against
a stub `kubectl` ([ci-2-20261105T055459Z-make-ci.log](../evidence/ci/ci-2-20261105T055459Z-make-ci.log)).

Argo CD picks this up at its next look. Looks were measured 120 to 289s apart, median 193s ([alert-text-figures-1.txt](../evidence/runs/alert-text-figures-1.txt)). To ask it to look now:

```bash
kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite
```

Child Applications have `retry.refresh: true`, so a revert lands while the bad revision is still retrying, with no manual termination. Seen twice in dev on 2026-11-05, and the backoff is what you wait for:

| Revert published | What the Application did | From the timeline |
|---|---|---|
| Failed-deploy drill, 8s after the first attempt failed | The next attempt read `Retrying operation with latest revisions. Attempt #1` on the reverted commit, ran the hook again and put the old image back | [DEP-1-20261105T062323Z-timeline.txt](../evidence/runs/DEP-1-20261105T062323Z-timeline.txt) |
| Failing-migrator drill, 16s after the third failure | It read `Synced`, `Healthy`, `Running` for 3m45s, until the next attempt was due, and then closed | [DEP-3-20261105T064517Z-timeline.txt](../evidence/runs/DEP-3-20261105T064517Z-timeline.txt) |

### If Postgres or plane-dev is what broke

A rollback of prod-sim depends on neither. It takes one best-effort dump first, limited to `ROLLBACK_DUMP_TIMEOUT` seconds (300 by
default), and a failure there does not stop it. It then publishes with `SKIP_BACKUP=yes` and `SKIP_DEV_CHECK`, so the publish takes no dump and
asks the cluster nothing. The skipped plane-dev check is logged in `.local/evidence-raw/promotion-overrides.log`. `make rollback ENV=prod-sim SKIP_BACKUP=yes CONFIRM=yes`
leaves the dump out.

Because that publish carries no check, it will not send a refused promotion by accident. If the promotion it would withdraw never reached Argo CD, and `main` holds more that moves prod-sim and has not gone out, it stops and names them. Take them all off with `git revert`, newest first, then run it again, which publishes those reverts.

A rollback of dev needs neither, because a publish that moves no prod-sim image asks the cluster nothing. A publish is all of `main`, though. If `main` holds a prod-sim image change that
Argo CD has not read, `make rollback ENV=dev` stops before reverting and names the commit. Withdraw it first, with `make rollback ENV=prod-sim` if it is a promotion and `git revert` if not.
Or set `OVERRIDE_DEV_CHECK="<reason>"` to send it along, which is logged, and that publish still asks plane-dev and takes the dump.

If the publish itself fails, the revert stays on `main`. Fix the cause and run `make rollback` again: it publishes that revert and reverts nothing
else. A promotion already put back by hand is reported as undone, and `main` is still published.

### If a migration ran and rolling back the image is not enough

**An image rollback does not roll back the database.** Migrations run forward only. Old code starts against the newer schema with no
warning, and may then fail on individual requests.

For prod-sim, `make promote` takes a dump first, unless `SKIP_BACKUP=yes` was used. Restore it:

```bash
ls -1 .local/backups/prod-sim/
make restore ENV=prod-sim BACKUP=<id-from-before-the-promotion> CONFIRM=yes
```

`make restore` has run in place in both environments, on 2026-11-05, with result PASS and `make test-e2e` passing after ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json)). Each used a backup taken minutes before, with no migration between. Going back past a migration, after a rollback, was not tested in Pass 1. See [Backup and restore](backup-restore.md).

Do not use `BACKUP=latest`: the rollback's own dump holds the newer schema, and `latest` may name it. A prod-sim rollback prints what to do, and read it before you restore:

| What it finds about the promotion | What it prints |
|---|---|
| It never reached Argo CD | There is nothing to restore, and no dump is named, because prod-sim's images and schema did not move |
| `.local/publishes.log` records the publish that first sent it | The newest finished dump from before that publish |
| No record of that publish, as for any promotion older than that log | The newest finished dump from before its commit, and the dumps since. A promotion merged on GitHub, or sent by a later run after a refusal, took its dump at the publish, so for one of those use the one from just before it. Real prod-sim promotions so far have no record, and `9c8e098`'s dump, `20261105T053351Z`, comes before its commit |

A re-run that publishes a revert says the same. This has run against stubs only (`scripts/ci/test-promotion-flows.sh`), and no real prod-sim rollback has run.

Roll back the image first, because `scripts/restore.sh` refuses a backup from a newer Plane version than the one running. Dev takes no automatic dump on
promotion, so run `make backup ENV=dev` yourself before a risky one. See [Backup and restore](backup-restore.md).

## Confirm

```bash
kubectl -n argocd get application "$APP" \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{" "}{.status.operationState.phase}{"\n"}'
kubectl -n "$NS" get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image'
make test-e2e ENV=dev
```

You want `Synced Healthy Succeeded`, no pod on the bad digest, and the probes green on the Platform overview dashboard. Check which
digest ran when on the [Deployments and rollbacks](../monitoring.md#deployment-and-rollback-visibility) dashboard.

Right after a rollout `make test-e2e` can exit 2, BLOCKED, while old pods are still going, because `tests/e2e/smoke.py` will not read PASS during a rollout. Wait about 40s and run it again. That is from reading the script, and no real run has hit it.

### Drills

`make drill-failed-deploy` runs `tests/drills/failed-deploy-rollback.sh`, which pushes a syntactically valid digest that no registry
can serve, through the real promotion path, and reverts it. It runs on dev only and adds two commits to `main`. Run it alone and in the background: it took 15 minutes,
and stage 4 alone can wait the 600s deadline plus 120s. Preflight stops before anything moves if a prod-sim change waits on `main` or Prometheus does not answer. It records every pending and firing
alert in `<evidence>-alerts.tsv`, and stage 6 prints them by alert with what the sink received.

`tests/drills/failed-migrator.sh` does the same with a throwaway backend image whose migrator exits 1. It has no `make` target. It holds the failure for `HOLD_SECONDS`, 300 by default, so rules with a 15 minute `for` cannot fire inside it.

Both ran once in dev on 2026-11-05 and ended RESULT PASS:

| Drill | What it showed | Evidence |
|---|---|---|
| `failed-deploy-rollback.sh` | Bad digest asked for 25s in, first Degraded 10m24s in, revert published 8s later, old image back 11m48s in, `Synced` and `Healthy` 11m54s in. 200 on all 61 samples. No pod left on the bad digest, and prod-sim's manifests did not move | [drill-failed-deploy-20261105T062343Z.log](../evidence/runs/drill-failed-deploy-20261105T062343Z.log) |
| `failed-migrator.sh` | The Job failed `BackoffLimitExceeded` 58s in. Deployment generations, images and pods equalled the start on all 67 samples, and 200 on all 67. The recovery replaced no pod. `ArgoAppOutOfSync`, `ArgoSyncFailed` and `KubeJobFailed` went pending, and only `Watchdog` reached the sink | [drill-failed-migrator-20261105T064940Z.log](../evidence/runs/drill-failed-migrator-20261105T064940Z.log) |

The migrator exited 1 and changed nothing. A migration that fails halfway through a schema change has not been tried, so neither run says what state that leaves.

Seconds from publishing a revert to the Application reading `Synced` and `Healthy` with no operation open, in dev, one run each, with a refresh asked for each time ([argocd-refresh-reasons-1.txt](../evidence/runs/argocd-refresh-reasons-1.txt)):

| Reverted | Seconds | Why that long |
|---|---:|---|
| A good promotion of four images, with no retry open (`make rollback ENV=dev`) | 67 | The sync itself. The operation ran from 06:41:03Z to 06:42:04Z |
| A bad `web` image, in a retry loop | 82 | 54s until the next attempt, which ran the hook again |
| A failing migrator, in a retry loop | 251 | 226s of backoff until the next attempt was due |

None of these is from prod-sim, and none waited for Argo CD's own look.

## What not to do

| Do not | Why |
|---|---|
| `kubectl set image` or `kubectl rollout undo` | Self-heal reverts it, and Git still says the bad digest |
| `git reset` and force-push to the bare repo | `gitops-publish` refuses non-fast-forward on purpose. Reverts are the way back |
| Edit `gitops/environments/*/manifests.yaml` by hand | It is generated. CI fails on the diff. `make promote` is the only writer of the overlay `images:` lines |
| Hand-edit the overlay digest to "promote" prod-sim | Prod-sim accepts only digests recorded for dev, which is the promotion control |
| Assume a rollback restored data | It restores images only |
| Pass `SKIP_BACKUP=yes` to a prod-sim promotion you might need to undo | That dump is the only way back past a migration |
| Delete the migrator Job to "unstick" a sync | Argo CD re-creates a hook through `BeforeHookCreation`. Fix the cause or roll back |
