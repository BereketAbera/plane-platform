# Failed deploy and rollback

A bad image or a bad migration reached an environment through a promotion.

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
| Job `plane-api-migrate-1` failing, Deployments unchanged | Migration failed. Deployments are wave 3 and the hook is wave 2, so they do not move |
| `Running` phase with "Retrying attempt #N" | Argo CD is retrying. See [Argo sync stuck](argo-sync-stuck.md) |
| `Running` phase with "waiting for healthy state of apps/Deployment/..." | The rollout has not finished or failed yet. Deployments are wave 3 of 4, so the sync waits on it |
| New pods crash, `PlanePodCrashLooping` firing | Image is pullable but broken. See [Plane app debugging](plane-app-debugging.md) |

Design intent: with `RollingUpdate`, a bad image on a Deployment leaves old pods serving. [[VERIFY: the failed-deploy drill sees 200 on every sample while the rollout fails]]

**What should fire, and has not been run.** Read from `monitoring/manifests/shared/rules-platform.yaml`: a bad image in a Plane Deployment holds the operation open, so `ArgoAppDegraded` fires 5 minutes after the deadline turns it Degraded, and `ArgoSyncFailed` at 15 minutes, if nobody reverts. The drill reverts at the first Degraded, about 10 minutes in, so both are expected to go pending, with neither firing unless the revert takes more than 5 minutes. No drill has measured this. See [what fires for which failure](argo-sync-stuck.md#what-fires-for-which-failure).

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
and publishes. Git stays the source of truth and auto-sync stays on. Running it again steps back one promotion further. The steps are in
[Argo CD](../argocd.md#rollback). No rollback has run on the real cluster yet, and the logic has run against a stub `kubectl`
([ci-2-20261104T225907Z-make-ci.log](../evidence/ci/ci-2-20261104T225907Z-make-ci.log)).

Argo CD picks this up on its next poll, every three minutes or so. To ask it to look now:

```bash
kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite
```

Child Applications have `retry.refresh: true`, so a revert lands while the bad revision is still retrying. [[VERIFY: a revert published during a retry loop replaces the bad revision without manual termination]]

### If Postgres or plane-dev is what broke

A rollback does not depend on either. For prod-sim it takes one best-effort dump first, limited to `ROLLBACK_DUMP_TIMEOUT` seconds (300 by
default), and a failure there does not stop it. It then publishes with `SKIP_BACKUP=yes` and `SKIP_DEV_CHECK`, so the publish takes no dump and
asks the cluster nothing. The skipped plane-dev check is logged in `.local/evidence-raw/promotion-overrides.log`. `make rollback ENV=prod-sim SKIP_BACKUP=yes CONFIRM=yes`
leaves the dump out.

If the publish itself fails, the revert stays on `main`. Fix the cause and run `make rollback` again: it publishes that revert and reverts nothing
else.

### If a migration ran and rolling back the image is not enough

**An image rollback does not roll back the database.** Migrations run forward only. Old code starts against the newer schema with no
warning, and may then fail on individual requests.

For prod-sim, `make promote` takes a dump first, unless `SKIP_BACKUP=yes` was used. Restore it:

```bash
ls -1 .local/backups/prod-sim/
make restore ENV=prod-sim BACKUP=<id-from-before-the-promotion> CONFIRM=yes
```

Do not use `BACKUP=latest`: the rollback's own dump holds the newer schema, and `latest` may name it. The rollback prints the dump to use.
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

Drill: `make drill-failed-deploy` runs `tests/drills/failed-deploy-rollback.sh`, which pushes a syntactically valid digest that no registry
can serve, through the real promotion path, and reverts it. It runs on dev only and adds two commits to `main`. Stage 4 waits up to the 600s deadline
plus 120s. It has not run.

[[VERIFY: tests/drills/failed-deploy-rollback.sh completes with RESULT PASS]]

[[MEASURE: seconds from publishing a revert to Application Synced and Healthy]]

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
