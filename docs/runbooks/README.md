# Runbooks

Operating procedures for the local Wayline platform, a customized Plane Community Edition v1.4.3 deployment on one
kind node.

**Status.** These runbooks were written from the code, the contract and recorded research, then corrected against what ran on the
cluster on 2026-11-04 and 2026-11-05. A result links its file under [`docs/evidence/runs/`](../evidence/README.md). These repair paths have been followed from start to finish on the final images: the failed-deploy drill, a failing migrator and a rollback in dev, and
a secret rotation, an in-place restore of Plane, the pod restart drill and the alert test in each environment, and a rotation killed part way, both finished and undone, in prod-sim. Infisical's in-place restore ran earlier ([`infisical/README.md`](../../infisical/README.md)). A rollback of prod-sim was not tested in Pass 1. A clean install from a fresh clone, keeping the registry and caches, and a full restore into a new cluster ran
through `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, and `make down`, `make up` and `make test` then passed on the restored platform ([make test](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)). The drill with the cold install restored with every restore step PASS too, its last line failing the same test step ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)), and `LOSE_CLUSTER=yes`, with no such step, read `RESULT PASS` ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)). Anything else with no result beside it is design intent. A successful drill, not this page, is what would show a runbook works.

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
| Requests slow down and Celery's queue climbs, with memory fine | [Memory pressure](memory-pressure.md#symptoms) |
| `KindnetSkippedNetworkPolicies`, `KindnetLogsNotRead`, or a policy that does not seem to hold | [Troubleshooting](troubleshooting.md#networkpolicy-seems-not-to-be-enforced) |
| A backup or restore failed, `PlaneBackupFailed`, or you need data back | [Backup and restore](backup-restore.md) |
| You need to change a password, or a rotation stopped partway | [Secret rotation](secret-rotation.md) |
| You want to start over from nothing | [Clean rebuild](clean-rebuild.md) |
| `make up` or `make backup` refuses because a clean restore is under way, or a resume refuses | [Troubleshooting](troubleshooting.md#a-clean-restore-is-marked-as-under-way) |
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
| Clean restore | `make drill-clean-restore PLAN_ONLY=yes`, or `CONFIRM=yes` for all of it, which deletes the cluster | `.local/evidence-raw/drill-clean-restore-<stamp>.log` | `PLAN_ONLY=yes`, which stops before the delete: PASS ([2026-11-05](../evidence/runs/drill-clean-restore-20261105T000555Z.log)). The full run, with `CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, keeping the registry and caches: its log reads FAIL ([log](../evidence/runs/drill-clean-restore-20261105T074859Z.log)), with one failure, in the test and not the restore: `destroy-refused` inherited `CONFIRM=yes`. `00126ea` did not fix that, `36d3011` does, and no drill has run that step since. One `make up` took 955s ([summary](../evidence/runs/clean-install-20261105T075041Z/summary.txt)), and every step of the restore read PASS ([record](../evidence/runs/restore-clean-20261105T081017Z.json)). With the cold install: the same step failed the same way, and every step of the restore read PASS ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)). With `LOSE_CLUSTER=yes`, which has no such step: `RESULT PASS` ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)) |
| Refusal of `make destroy` | `env -u CONFIRM make destroy`, in a clean environment | `.local/evidence-raw/TEAR-1-<stamp>.txt`, kept by hand | PASS, once, on 2026-11-05: exit 2, and the cluster still Ready ([TEAR-1-20261105T083304Z.txt](../evidence/runs/TEAR-1-20261105T083304Z.txt)) |
| Stop and resume | `make down`, `make up`, then `python3 -B tests/e2e/smoke.py --env <env> --mode verify` in each environment | `.local/evidence-raw/PERS-3-<stamp>.txt`, kept by hand | PASS, once, on 2026-11-05: `make down` 15s, `make up` 82s, and each sentinel row and attachment read back ([PERS-3-20261105T083304Z.txt](../evidence/runs/PERS-3-20261105T083304Z.txt)) |
| Whole platform test | `make test` | `.local/evidence-raw/test-<stamp>.txt`, naming a file per part | PASS on the final images on the restored platform, ended 2026-11-05T08:45:53Z: all 9 parts, with 1 SKIP in each e2e, `branding-fresh-install` ([summary](../evidence/runs/test-20261105T083455Z-37296.txt), [log](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)) |
| Load | `make test-load ENV=dev`, or `THINK=0 make test-load ENV=dev` for where it saturates | `.local/evidence-raw/load-<run>/results.json` | On a quiet cluster on 2026-11-05: exit 0 with think time. With none, exit 2, because k6 crossed its read threshold, and the numbers stand ([run](../evidence/runs/LOAD-1b-20261105T090247Z-run.txt), [figures](../resource-utilization.md#load-results-dev)) |
| Restore in place | `make backup ENV=dev`, then `make restore ENV=dev BACKUP=latest CONFIRM=yes`, or `ENV=prod-sim` for both | `.local/evidence-raw/restore-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05, with `make test-e2e` passing after ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json)). With no `CONFIRM` it refused, and that record reads FAIL by design ([restore-prod-sim-20261105T073428Z.json](../evidence/runs/restore-prod-sim-20261105T073428Z.json)) |
| Secret rotation | `make rotate ENV=dev`, or `make rotate ENV=prod-sim CONFIRM=yes` | `.local/evidence-raw/rotate-<env>-<stamp>.log` | PASS in dev and in prod-sim, on 2026-11-05 ([rotate-dev-20261105T072345Z.log](../evidence/runs/rotate-dev-20261105T072345Z.log), [rotate-prod-sim-20261105T073240Z.log](../evidence/runs/rotate-prod-sim-20261105T073240Z.log)). A rotation in prod-sim stopped with SIGKILL 4 seconds in was finished by `RESUME=yes` ([SEC-4-20261105T073843Z.txt](../evidence/runs/SEC-4-20261105T073843Z.txt)), and another, on the restored cluster, undone by `ROLLBACK=yes` ([SEC-4b-20261105T084615Z.txt](../evidence/runs/SEC-4b-20261105T084615Z.txt)). See [Secret rotation](secret-rotation.md) |
| Alert delivery | `make test-alert ENV=dev` or `ENV=prod-sim` | `.local/evidence-raw/alert-test-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05 ([alert-test-dev-20261105T055044Z.json](../evidence/runs/alert-test-dev-20261105T055044Z.json), [alert-test-prod-sim-20261105T072541Z.json](../evidence/runs/alert-test-prod-sim-20261105T072541Z.json)) |
| Data service alerts, dev only | `tests/drills/alert-rules.sh ENV=dev`, alone. It pauses auto-sync and takes RabbitMQ and then Silo away | `.local/evidence-raw/alert-rules-dev-<stamp>.txt` | FAIL on both rows on the old rules, which is how the defect was found ([alert-rules-dev-20261105T100605Z.txt](../evidence/runs/alert-rules-dev-20261105T100605Z.txt)), then PASS on both after `2f42ddb` ([alert-rules-dev-20261105T101707Z.txt](../evidence/runs/alert-rules-dev-20261105T101707Z.txt)). A scale to 0 only. See [Monitoring](../monitoring.md#the-data-service-drill) |
