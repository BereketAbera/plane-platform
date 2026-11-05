# Runbooks

Operating procedures for the local Wayline platform, a customized Plane Community Edition v1.4.3 deployment on one
kind node.

**Status.** These runbooks were written from the code, the contract and recorded research, then corrected against what ran on the
cluster on 2026-11-04 and 2026-11-05. A result links its file under [`docs/evidence/runs/`](../evidence/README.md). These repair paths have been followed from start to finish on the final images: the failed-deploy drill, a failing migrator and a rollback in dev, and
a secret rotation, an in-place restore of Plane, the pod restart drill and the alert test in each environment. Infisical's in-place restore ran earlier ([`infisical/README.md`](../../infisical/README.md)). A rollback of prod-sim and the undo of a rotation were not tested in Pass 1. A clean rebuild and a full restore into a new cluster are in progress as this is written,
through `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, and their results are not yet recorded. Anything else with no result beside it is design intent. A successful drill, not this page, is what would show a runbook works.

## Find the right runbook

| What you see | Go to |
|---|---|
| A new image is failing, or `ImagePullBackOff` after a promotion | [Failed deploy and rollback](failed-deploy-rollback.md) |
| Application shows `Running` or "Syncing" for a long time, or "Retrying attempt #N" | [Argo sync stuck](argo-sync-stuck.md) |
| A commit does not reach the cluster | [Argo sync stuck](argo-sync-stuck.md) |
| `ArgoSyncFailed`, `ArgoAppDegraded`, `ArgoAppOutOfSync`, `ArgoAppSyncUnknown`, `ArgoAppStuckProgressing`, `ArgoRootSyncStuck` | [Argo sync stuck](argo-sync-stuck.md) |
| Plane answers 5xx, tasks do not run, uploads or exports fail | [Plane app debugging](plane-app-debugging.md) |
| `PlaneApiDown`, `PlaneApiDatabaseProbeFailing`, `PlaneFrontendDown`, `PlanePodCrashLooping`, `PlanePostgresDown`, `PlaneValkeyDown`, `PlaneRabbitmqDown`, `PlaneMinioDown`, `PlaneWorkerNoConsumer`, `PlaneCeleryQueueMissing`, `PlaneCeleryBacklog` | [Plane app debugging](plane-app-debugging.md) |
| `guard_disk` refuses, "No space left on device", the Mac is nearly full | [Disk pressure](disk-pressure.md) |
| `OOMKilled`, `VmMemoryLow`, `ContainerMemorySaturation`, `PodRestarting`, slow first boot | [Memory pressure](memory-pressure.md) |
| `KindnetSkippedNetworkPolicies`, `KindnetLogsNotRead`, or a policy that does not seem to hold | [Troubleshooting](troubleshooting.md#networkpolicy-seems-not-to-be-enforced) |
| A backup or restore failed, `PlaneBackupFailed`, or you need data back | [Backup and restore](backup-restore.md) |
| You need to change a password, or a rotation stopped partway | [Secret rotation](secret-rotation.md) |
| You want to start over from nothing | [Clean rebuild](clean-rebuild.md) |
| `make up` or a script stops, and nothing above fits | [Troubleshooting](troubleshooting.md) |

For what each alert sees and cannot see, and which have really fired, see [Monitoring](../monitoring.md#alert-rules).

## Conventions

Commands run from the repository root. Scripts set up their own environment, but raw `kubectl` commands need this first:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
```

Your own `~/.kube/config` is never touched, so without this `kubectl` may talk to another cluster.

| Name | Value |
|---|---|
| Node container | `plane-platform-control-plane` |
| Plane namespaces | `plane-dev`, `plane-prod-sim` |
| Argo CD Applications | `root`, plus one per component. `plane-dev` and `plane-prod-sim` match their namespaces |
| Plane Deployments | `plane-api-wl`, `plane-worker-wl`, `plane-beat-worker-wl`, `plane-live-wl`, `plane-web-wl`, `plane-admin-wl`, `plane-space-wl` |
| Plane StatefulSets | `plane-pgdb-wl`, `plane-redis-wl`, `plane-rabbitmq-wl`, `plane-minio-wl` |
| Migrator Job | `plane-api-migrate-1` |

The StatefulSet and Service names keep the chart's `pgdb`, `redis` and `minio`, even though the images are PostgreSQL,
Valkey and Silo (a MinIO-compatible fork). `make logs` takes `SVC=api`, `worker`, `beat`, `web`, `admin`, `space`, `live`, `postgres`,
`valkey`, `rabbitmq`, `silo` or `migrator`, the chart's names (`beat-worker`, `pgdb`, `redis`, `minio`), and the exact name of any live
Deployment, StatefulSet or Job in the namespace, such as `postgres-exporter`. `make logs ENV=dev` with no `SVC` lists them.
`scripts/logs.sh dev api --no-follow` prints the last lines and stops.

## Rules that apply to every runbook

1. **Git is the desired state.** Argo CD self-heals, so `kubectl scale`, `edit` and `set` are reverted in seconds: 3s for the one replica change timed ([GITOPS-4-20261105T073240Z.txt](../evidence/runs/GITOPS-4-20261105T073240Z.txt)). Make
   lasting changes in Git, then run `make gitops-publish`. Argo CD reads only the bare repo that command writes, not your
   working tree and not GitHub.
2. **Pause self-heal only for drills and restores, and put it back.** `monitoring/ops/lib.sh` does this for scripts. Root does not undo
   `automated.enabled: false` on a child ([dr-child-pause-1.txt](../evidence/runs/dr-child-pause-1.txt)), so a paused child stays paused
   until someone restores it. See [Argo sync stuck](argo-sync-stuck.md#auto-sync-was-left-paused).
3. **Never run `docker system prune -a`.** It can remove cached images on this host that can no longer be pulled
   anonymously, and a prune of stopped containers would remove a stopped kind node.
4. **Never rotate `SECRET_KEY`.** Encrypted rows would decrypt silently to an empty string.
5. **`dev` and `prod-sim` are namespaces on one node, not independent clusters.** Node, disk, kernel, API server,
   Prometheus and Traefik are shared. A node-level fault hits both. Nothing here shows the isolation that separate
   production clusters would give.
6. **Record results honestly.** `make publish-evidence` copies `.local/evidence-raw/` to `docs/evidence/runs/` with secrets scrubbed. A
   result is labelled PASS, FAIL, BLOCKED or NOT RUN, with date and command (contract section 12). See
   [the evidence README](../evidence/README.md#publishing).

## Scripted drills

| Drill | How to run | Evidence file | Result so far |
|---|---|---|---|
| Failed deploy and rollback, dev only | `make drill-failed-deploy`, in the background and alone. It stops before anything moves if a prod-sim change waits on `main`, and records every pending and firing alert | `.local/evidence-raw/drill-failed-deploy-<stamp>.log`, and `-alerts.tsv` beside it | PASS, once, on 2026-11-05 ([drill-failed-deploy-20261105T062343Z.log](../evidence/runs/drill-failed-deploy-20261105T062343Z.log)) |
| Failing migrator, dev only | `tests/drills/failed-migrator.sh`, alone | `.local/evidence-raw/drill-failed-migrator-<stamp>.log`, and `-alerts.tsv` beside it | PASS, once, on 2026-11-05 ([drill-failed-migrator-20261105T064940Z.log](../evidence/runs/drill-failed-migrator-20261105T064940Z.log)) |
| Pod restart persistence | `make drill-pod-restart ENV=dev` or `ENV=prod-sim` | `.local/evidence-raw/drill-pod-restart-<env>-<stamp>.log` | Dev PASS ([2026-11-04](../evidence/runs/drill-pod-restart-dev-20261104T224424Z.log)), and PASS again on the final images on 2026-11-05 ([drill-pod-restart-dev-20261105T070414Z.log](../evidence/runs/drill-pod-restart-dev-20261105T070414Z.log)). Prod-sim FAIL ([first](../evidence/runs/drill-pod-restart-prod-sim-20261104T233500Z.log), the [`cancel_consumer` trap](plane-app-debugging.md#the-cancel_consumer-trap)), then PASS on a clean worker ([second](../evidence/runs/drill-pod-restart-prod-sim-20261104T235402Z.log)), on upstream images, and PASS on the final images on 2026-11-05 ([drill-pod-restart-prod-sim-20261105T072331Z.log](../evidence/runs/drill-pod-restart-prod-sim-20261105T072331Z.log)) |
| Clean restore | `make drill-clean-restore PLAN_ONLY=yes`, or `CONFIRM=yes` for all of it, which deletes the cluster | `.local/evidence-raw/drill-clean-restore-<stamp>.log` | `PLAN_ONLY=yes`, which stops before the delete ([2026-11-05](../evidence/runs/drill-clean-restore-20261105T000555Z.log)). The full run, with `CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, is in progress as this is written, and its result is not yet recorded |
| Restore in place | `make backup ENV=dev`, then `make restore ENV=dev BACKUP=latest CONFIRM=yes`, or `ENV=prod-sim` for both | `.local/evidence-raw/restore-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05, with `make test-e2e` passing after ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json)). With no `CONFIRM` it refused, and that record reads FAIL by design ([restore-prod-sim-20261105T073428Z.json](../evidence/runs/restore-prod-sim-20261105T073428Z.json)) |
| Secret rotation | `make rotate ENV=dev`, or `make rotate ENV=prod-sim CONFIRM=yes` | `.local/evidence-raw/rotate-<env>-<stamp>.log` | PASS in dev and in prod-sim, on 2026-11-05 ([rotate-dev-20261105T072345Z.log](../evidence/runs/rotate-dev-20261105T072345Z.log), [rotate-prod-sim-20261105T073240Z.log](../evidence/runs/rotate-prod-sim-20261105T073240Z.log)). A rotation in prod-sim stopped with SIGKILL 4 seconds in was finished by `RESUME=yes` ([SEC-4-20261105T073843Z.txt](../evidence/runs/SEC-4-20261105T073843Z.txt)). See [Secret rotation](secret-rotation.md) |
| Alert delivery | `make test-alert ENV=dev` or `ENV=prod-sim` | `.local/evidence-raw/alert-test-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05 ([alert-test-dev-20261105T055044Z.json](../evidence/runs/alert-test-dev-20261105T055044Z.json), [alert-test-prod-sim-20261105T072541Z.json](../evidence/runs/alert-test-prod-sim-20261105T072541Z.json)) |
