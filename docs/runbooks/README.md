# Runbooks

Operating procedures for Wayline, a customized Plane Community Edition v1.4.3 deployment, in its three environments:

| Environment | Where | Plane namespace | How a change reaches it |
|---|---|---|---|
| `dev` | A kind cluster on this Mac, started with `make up` | `plane-dev` | `make promote ENV=dev`, through `make gitops-publish` |
| `prod-sim` | The same kind cluster, as the promotion target that simulates production | `plane-prod-sim` | `make promote ENV=prod-sim CONFIRM=yes` |
| Hosted production, `plane-prod` | One K3s node on a Contabo VPS, at https://wayline.bereket.dev, with https://grafana.bereket.dev and https://infisical.bereket.dev | `plane-prod` | A merge to `main`, which CI releases to branch `deploy/plane-prod` |

The runbooks below were written for the first two. Each of them but [Clean rebuild](clean-rebuild.md), which is for kind alone, ends with a
section **Hosted production** that says what differs there. Three are for hosted production alone: [rollback](hosted-rollback.md),
[restore](hosted-restore.md) and [lockout](hosted-lockout.md).

**Status of hosted production.** It has run since 2026-11-07. Its runs so far are under [Hosted runs](#hosted-runs): two restore tests on
the VPS and a restore of this Mac's copy passed, while no rollback, no real restore and no lockout recovery has run there. Their evidence
is in `docs/evidence`, apart from the scan on GitHub, whose report is the run's artifact, and the recovery bundle, which writes no record,
and the rows say so.

**Status of the local platform.** These runbooks were written from the code, the contract and recorded research, then corrected against what ran on the
cluster on 2026-11-04 and 2026-11-05. A result links its file under [`docs/evidence/runs/`](../evidence/README.md). These repair paths have been followed from start to finish on the final images: the failed-deploy drill, a failing migrator and a rollback in dev, and
a secret rotation, an in-place restore of Plane, the pod restart drill and the alert test in each environment, and a rotation killed part way, both finished and undone, in prod-sim. Infisical's in-place restore ran earlier ([`infisical/README.md`](../../infisical/README.md)). A rollback of prod-sim was not tested in Pass 1. A clean install from a fresh clone, keeping the registry and caches, and a full restore into a new cluster ran
through `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, and `make down`, `make up` and `make test` then passed on the restored platform ([make test](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)). The drill with the cold install restored with every restore step PASS too, its last line failing the same test step ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)), and `LOSE_CLUSTER=yes`, with no such step, read `RESULT PASS` ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)), and `make test` passed again on the cluster it left ([make test](../evidence/runs/MAKE-TEST-20261105T140019Z.txt)). Anything else with no result beside it is design intent. A successful drill, not this page, is what would show a runbook works.

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

On hosted production:

| What you see | Go to |
|---|---|
| A release broke the site, or you need the set before it back | [Rollback on hosted production](hosted-rollback.md) |
| A commit on `main` has not reached the cluster, or `release-plane-prod` is red. Any `Argo*` alert | [Argo sync stuck](argo-sync-stuck.md#hosted-production) |
| Data is wrong or missing. `PlaneBackupFailed`, `BackupTooOld`, `BackupNeverSucceeded`, or `off-VPS backups incomplete` | [Restore on hosted production](hosted-restore.md) |
| Grafana or Infisical refuses you, SSH or the tunnel fails, or 443 is closed. `PublicFirewallNotLoaded` | [Lockout on hosted production](hosted-lockout.md) |
| `NodeDiskLow`, `NodeDiskCritical`, `NodeDiskNotRead` | [Disk pressure](disk-pressure.md#hosted-production) |
| `NodeMemoryLow`, `ContainerMemorySaturation`, `PodRestarting`, `exceeded quota` | [Memory pressure](memory-pressure.md#hosted-production) |
| `Plane*` alerts, or Plane misbehaves at https://wayline.bereket.dev | [Plane app debugging](plane-app-debugging.md#hosted-production) |
| A certificate, a console's route, `InfisicalOpenToClaim`, `NetworkPolicyNotEnforced`, `NodeRebootRequired`, or a script that refuses to start | [Troubleshooting](troubleshooting.md#hosted-production) |
| A password, token or key to change | [Secret rotation](secret-rotation.md#hosted-production) |

[Clean rebuild](clean-rebuild.md) is for kind alone: `make destroy` and `make up` never reach hosted production.

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

### Hosted production

Run hosted commands from the checkout that holds `.local/hosted/plane-prod/`. Each script finds `.local` and `.tools` beside itself, so the
checkout decides which state and kubeconfig it uses. Everything goes through `make remote-<verb> TARGET=plane-prod`, and what changes
something also needs `CONFIRM=plane-prod`. `CONFIRM=yes` does not count there, and no local target reaches it. [`scripts/hosted/README.md`](../../scripts/hosted/README.md)
lists every script.

The cluster's API is reached only through an SSH tunnel, from 127.0.0.1:16443 to the node. Raw commands need it up, and this function:

```bash
make remote-tunnel TARGET=plane-prod VERB=status   # VERB=start if it is down
kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
```

`kc` skips the check that the scripts make first, that the live `kube-system` UID and node name match
[`target.yaml`](../../infrastructure/hosted/plane-prod/target.yaml). `make remote-status TARGET=plane-prod` makes it, and reads everything
else in one go. Never merge that kubeconfig into `~/.kube/config`.

| Name | Value |
|---|---|
| Node | `vmi3733427`, K3s, at 5.253.234.127 |
| Namespaces | `plane-prod`, `infisical`, `monitoring`, `monitoring-agents`, `argocd`, `traefik`, `cert-manager`, and the apps' `rillmark`, `awushi-cloudgarden` and `frameflow`: [hosted-apps.md](../hosted-apps.md) |
| Argo CD Applications | `root`, and seventeen children, `plane-prod` among them. [Argo sync stuck](argo-sync-stuck.md#hosted-production) lists them |
| Plane workloads | The names in the table above, and the Sync hook `plane-prod-predeploy-dump` beside the migrator |
| Consoles | `make remote-ui TARGET=plane-prod UI=argocd`, `grafana`, `prometheus`, `alertmanager` or `infisical`, and Frameflow's `hatchet` or `frameflow-silo`. Only Grafana and Infisical also have a public route |
| Backups on the node | `/srv/wayline/backups/plane-prod`, `/srv/wayline/backups/infisical` and `/srv/wayline/backups/frameflow` |
| State on this Mac | `.local/hosted/plane-prod/`, at mode 0700, and never in Git |

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
   [the evidence README](../evidence/README.md#publishing). For hosted production, `make remote-publish-evidence TARGET=plane-prod` reads its
   Secrets' values first, so the scrub knows them too.
7. **On hosted production the way in is `main`.** Its Argo CD reads only branch `deploy/plane-prod`, which CI's `release-plane-prod` job
   writes after a merge to `main` passes CI, so merging to `main` deploys and `make gitops-publish` reaches nothing there. Self-heal puts back a
   change made with `kc` there as it does here.
8. **Name hosted production twice.** `TARGET=plane-prod` aims a command at it, and `CONFIRM=plane-prod` lets the command change something.
   `CONFIRM=yes` never does.
9. **Never type a production secret on a command line, and never print a Secret's value.** Hosted scripts read secrets from files under
   `.local/hosted/plane-prod/` or from hidden prompts. A real login, such as the smoke's account, is typed by its owner in a terminal.
10. **Hosted production is one node too.** It shares nothing with kind, but every Plane workload runs one replica on it, so a restart is an
    outage, and a node fault stops everything.

## Scripted drills

| Drill | How to run | Evidence file | Result so far |
|---|---|---|---|
| Failed deploy and rollback, dev only | `make drill-failed-deploy`, in the background and alone. It stops before anything moves if a prod-sim change waits on `main`, and records every pending and firing alert | `.local/evidence-raw/drill-failed-deploy-<stamp>.log`, and `-alerts.tsv` beside it | PASS, once, on 2026-11-05 ([drill-failed-deploy-20261105T062343Z.log](../evidence/runs/drill-failed-deploy-20261105T062343Z.log)) |
| Failing migrator, dev only | `tests/drills/failed-migrator.sh`, alone | `.local/evidence-raw/drill-failed-migrator-<stamp>.log`, and `-alerts.tsv` beside it | PASS, once, on 2026-11-05 ([drill-failed-migrator-20261105T064940Z.log](../evidence/runs/drill-failed-migrator-20261105T064940Z.log)) |
| Pod restart persistence | `make drill-pod-restart ENV=dev` or `ENV=prod-sim` | `.local/evidence-raw/drill-pod-restart-<env>-<stamp>.log` | Dev PASS ([2026-11-04](../evidence/runs/drill-pod-restart-dev-20261104T224424Z.log)), and PASS again on the final images on 2026-11-05 ([drill-pod-restart-dev-20261105T070414Z.log](../evidence/runs/drill-pod-restart-dev-20261105T070414Z.log)). Prod-sim FAIL ([first](../evidence/runs/drill-pod-restart-prod-sim-20261104T233500Z.log), the [`cancel_consumer` trap](plane-app-debugging.md#the-cancel_consumer-trap)), then PASS on a clean worker ([second](../evidence/runs/drill-pod-restart-prod-sim-20261104T235402Z.log)), on upstream images, and PASS on the final images on 2026-11-05 ([drill-pod-restart-prod-sim-20261105T072331Z.log](../evidence/runs/drill-pod-restart-prod-sim-20261105T072331Z.log)) |
| Clean restore | `make drill-clean-restore PLAN_ONLY=yes`, or `CONFIRM=yes` for all of it, which deletes the cluster | `.local/evidence-raw/drill-clean-restore-<stamp>.log` | `PLAN_ONLY=yes`, which stops before the delete: PASS ([2026-11-05](../evidence/runs/drill-clean-restore-20261105T000555Z.log)). The full run, with `CONFIRM=yes CLEAN_INSTALL_FIRST=yes`, keeping the registry and caches: its log reads FAIL ([log](../evidence/runs/drill-clean-restore-20261105T074859Z.log)), with one failure, in the test and not the restore: `destroy-refused` inherited `CONFIRM=yes`. `af8b26e` did not fix that, `1374c1e` does, and no drill has run that step since, though its line was [checked against a stub](../evidence/runs/destroy-refused-line-check.txt). One `make up` took 955s ([summary](../evidence/runs/clean-install-20261105T075041Z/summary.txt)), and every step of the restore read PASS ([record](../evidence/runs/restore-clean-20261105T081017Z.json)). With the cold install: the same step failed the same way, and every step of the restore read PASS ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)). With `LOSE_CLUSTER=yes`, which has no such step: `RESULT PASS` ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)) |
| Refusal of `make destroy` | `env -u CONFIRM make destroy`, in a clean environment | `.local/evidence-raw/TEAR-1-<stamp>.txt`, kept by hand | PASS, once, on 2026-11-05: exit 2, and the cluster still Ready ([TEAR-1-20261105T083304Z.txt](../evidence/runs/TEAR-1-20261105T083304Z.txt)) |
| Stop and resume | `make down`, `make up`, then `python3 -B tests/e2e/smoke.py --env <env> --mode verify` in each environment | `.local/evidence-raw/PERS-3-<stamp>.txt`, kept by hand | PASS, once, on 2026-11-05: `make down` 15s, `make up` 82s, and each sentinel row and attachment read back ([PERS-3-20261105T083304Z.txt](../evidence/runs/PERS-3-20261105T083304Z.txt)) |
| Whole platform test | `make test` | `.local/evidence-raw/test-<stamp>.txt`, naming a file per part | PASS on the final images at `f30a7f5`, ended 2026-11-05T14:11:52Z: all 9 parts, with 1 SKIP in each e2e, `branding-fresh-install` ([summary](../evidence/runs/test-20261105T140019Z-56547.txt), [log](../evidence/runs/MAKE-TEST-20261105T140019Z.txt)). The same on the first restored cluster, ended 08:45:53Z ([summary](../evidence/runs/test-20261105T083455Z-37296.txt), [log](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)) |
| Load | `make test-load ENV=dev`, or `THINK=0 make test-load ENV=dev` for where it saturates | `.local/evidence-raw/load-<run>/results.json` | On a quiet cluster on 2026-11-05: exit 0 with think time. With none, exit 2, because k6 crossed its read threshold, and the numbers stand ([run](../evidence/runs/LOAD-1b-20261105T090247Z-run.txt), [figures](../resource-utilization.md#load-results-dev)) |
| Restore in place | `make backup ENV=dev`, then `make restore ENV=dev BACKUP=latest CONFIRM=yes`, or `ENV=prod-sim` for both | `.local/evidence-raw/restore-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05, with `make test-e2e` passing after ([restore-dev-20261105T074337Z.json](../evidence/runs/restore-dev-20261105T074337Z.json), [restore-prod-sim-20261105T073438Z.json](../evidence/runs/restore-prod-sim-20261105T073438Z.json)). With no `CONFIRM` it refused, and that record reads FAIL by design ([restore-prod-sim-20261105T073428Z.json](../evidence/runs/restore-prod-sim-20261105T073428Z.json)) |
| Secret rotation | `make rotate ENV=dev`, or `make rotate ENV=prod-sim CONFIRM=yes` | `.local/evidence-raw/rotate-<env>-<stamp>.log` | PASS in dev and in prod-sim, on 2026-11-05 ([rotate-dev-20261105T072345Z.log](../evidence/runs/rotate-dev-20261105T072345Z.log), [rotate-prod-sim-20261105T073240Z.log](../evidence/runs/rotate-prod-sim-20261105T073240Z.log)). A rotation in prod-sim stopped with SIGKILL 4 seconds in was finished by `RESUME=yes` ([SEC-4-20261105T073843Z.txt](../evidence/runs/SEC-4-20261105T073843Z.txt)), and another, on the restored cluster, undone by `ROLLBACK=yes` ([SEC-4b-20261105T084615Z.txt](../evidence/runs/SEC-4b-20261105T084615Z.txt)). See [Secret rotation](secret-rotation.md) |
| Alert delivery | `make test-alert ENV=dev` or `ENV=prod-sim` | `.local/evidence-raw/alert-test-<env>-<stamp>.json` | PASS, once in each environment, on 2026-11-05 ([alert-test-dev-20261105T055044Z.json](../evidence/runs/alert-test-dev-20261105T055044Z.json), [alert-test-prod-sim-20261105T072541Z.json](../evidence/runs/alert-test-prod-sim-20261105T072541Z.json)) |
| Data service alerts, dev only | `tests/drills/alert-rules.sh ENV=dev`, alone. It pauses auto-sync and takes RabbitMQ and then Silo away | `.local/evidence-raw/alert-rules-dev-<stamp>.txt` | FAIL on both rows on the old rules, which is how the defect was found ([alert-rules-dev-20261105T100605Z.txt](../evidence/runs/alert-rules-dev-20261105T100605Z.txt)), then PASS on both after `63105af` ([alert-rules-dev-20261105T101707Z.txt](../evidence/runs/alert-rules-dev-20261105T101707Z.txt)). A scale to 0 only. See [Monitoring](../monitoring.md#the-data-service-drill) |

## Hosted runs

On hosted production, on 2026-11-07 and early on 2026-11-08. The scripts write to `.local/evidence-raw/`, and
`make remote-publish-evidence TARGET=plane-prod` copied these runs to `docs/evidence/runs/` under the same names at about 00:21Z on 2026-11-08.

| Run | How to run | Evidence file | Result so far |
|---|---|---|---|
| Bootstrap | `make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod` | Kept by hand, `hosted-bootstrap-<stamp>.txt` | Stopped at step 6 for want of the GHCR token, exit 2, at 04:30Z ([first](../evidence/runs/hosted-bootstrap-20261107T042651Z.txt)). Finished, exit 0, at 05:05Z, with alert delivery and the recovery bundle then INCOMPLETE ([second](../evidence/runs/hosted-bootstrap-20261107T050333Z.txt)) |
| Network policy matrix | `make remote-netpol TARGET=plane-prod CONFIRM=plane-prod` | `.local/evidence-raw/netpol-plane-prod-<stamp>.tsv` | Without `CONFIRM`, refused, exit 2 ([record](../evidence/runs/hosted-netpol-first-20261107T043754Z.txt)). At 04:38Z, before any Plane workload: 143 PASS, 0 FAIL, 67 INCONCLUSIVE, exit 2 ([log](../evidence/runs/hosted-netpol-first-20261107T043810Z.txt), [matrix](../evidence/runs/netpol-plane-prod-20261107T043811Z.tsv)). With Plane up: 208 PASS and 2 INCONCLUSIVE at 06:18Z, 212 PASS, 1 FAIL and 1 INCONCLUSIVE at 06:32Z, the FAIL a policy refusing Traefik on its way to Grafana's new route, and 206 PASS, 0 FAIL and 8 INCONCLUSIVE at 07:27Z ([06:18Z](../evidence/runs/netpol-plane-prod-20261107T061822Z.tsv), [06:32Z](../evidence/runs/netpol-plane-prod-20261107T063238Z.tsv), [07:27Z](../evidence/runs/netpol-plane-prod-20261107T072728Z.tsv)). The first clean run at 19:24Z: 219 PASS, 0 FAIL, 0 INCONCLUSIVE ([matrix](../evidence/runs/netpol-plane-prod-20261107T192436Z.tsv)), and the same at 21:43Z inside the whole suite ([matrix](../evidence/runs/netpol-plane-prod-20261107T214332Z.tsv)). See [Troubleshooting](troubleshooting.md#hosted-production) |
| Backups, run now | `make remote-backup TARGET=plane-prod CONFIRM=plane-prod` | `.local/evidence-raw/backup-plane-prod-<stamp>.txt` | FAIL at 06:47Z, then PASS at 07:07Z ([06:47Z](../evidence/runs/backup-plane-prod-20261107064758.txt), [07:07Z](../evidence/runs/backup-plane-prod-20261107070754.txt)). With `ONLY=plane-prod`, after release `75ad7d7` changed the objects step to one listing taken first: PASS from 00:14:30Z to 00:16:26Z on 2026-11-08, 2 objects checked of 2 listed and 0 gone ([run](../evidence/runs/backup-plane-prod-20261108001433.txt)). See [Restore on hosted production](hosted-restore.md) |
| Restore test on the VPS | `make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod` | `.local/evidence-raw/restore-test-plane-prod-<stamp>.json` | PASS, 11 of 11 rows, ended 07:19:11Z ([record](../evidence/runs/restore-test-plane-prod-20261107071414.json)). With `ONLY=plane-prod`, of the backup of 00:14Z: PASS, 9 of 9 rows, from 00:16:26Z to 00:20:14Z on 2026-11-08 ([record](../evidence/runs/restore-test-plane-prod-20261108001626.json)) |
| Off-VPS copy | `make remote-pull-backups TARGET=plane-prod`, then `make remote-backup-dest TARGET=plane-prod VERB=verify` | Kept by hand, `hosted-pull-<stamp>.log` | PASS at 07:13Z: both repositories pulled, restored here and every file matched ([log](../evidence/runs/hosted-pull-20261107T071339Z.log)) |
| Restore test of this Mac's copy, in kind | `make remote-restore-test TARGET=plane-prod RESTORE_ON=kind` | `.local/evidence-raw/restore-test-plane-prod-<stamp>.json` | NOT RUN |
| Alert delivery | `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=alerts` | `.local/evidence-raw/test-hosted-<stamp>.txt` | PASS, every row, at 07:31Z: delivery COMPLETE, to Telegram, with Watchdog to Healthchecks, and a synthetic alert left Alertmanager ([run](../evidence/runs/test-hosted-20261107T073149Z.txt)) |
| Rendered Secrets, after Infisical's new values | `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=secrets` | `.local/evidence-raw/test-hosted-<stamp>.txt` | PASS, every row, at 18:44Z ([run](../evidence/runs/test-hosted-20261107T184239Z.txt)) |
| Infisical's route from outside, its Secrets and its routes | `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY="outside secrets routes"` | `.local/evidence-raw/test-hosted-<stamp>.txt` | FAIL at 19:31Z, 117 PASS and 2 FAIL: the port scan read 8080 open on this Mac's network path, where the node has no listener, and the session limit's row, as it stood before `f3ef5c2`, asked a call v0.167.6 answers 500 ([run](../evidence/runs/test-hosted-20261107T193135Z.txt)). See [Infisical's route](../validation.md#hosted-infisicals-public-route) |
| The whole hosted suite | `make remote-test TARGET=plane-prod CONFIRM=plane-prod` | `.local/evidence-raw/test-hosted-<stamp>.txt` | FAIL from 21:40:54Z to 22:07Z: 355 PASS, 1 FAIL and 1 BLOCKED. The FAIL is the port scan's 8080 again, on this Mac's network path, and the BLOCKED is the smoke, which waits for the owner's login at its prompt ([run](../evidence/runs/test-hosted-20261107T214054Z.txt)) |
| Restart check | `make remote-restart-check TARGET=plane-prod CONFIRM=plane-prod`. The site is down while the API's pod restarts | `.local/evidence-raw/restart-check-<stamp>.txt` | FAIL at 07:52Z: every pod came back, and the public API did not answer 200 from this Mac within 180s, so the check stopped before it compared what Postgres held ([record](../evidence/runs/restart-check-20261107T075237Z.txt)). The next run: PENDING, waiting for the owner |
| Smoke | `make remote-smoke TARGET=plane-prod`, which the owner runs, since it asks for a login at hidden prompts | `.local/evidence-raw/smoke-plane-prod-<stamp>.json` | BLOCKED at 06:41Z, on a refused sign-in, then PASS at 06:45Z, 21 of 21 steps ([06:41Z](../evidence/runs/smoke-plane-prod-20261107T064131Z.json), [06:45Z](../evidence/runs/smoke-plane-prod-20261107T064551Z.json)). The final smoke: PENDING, waiting for the owner |
| Image scan of all 50 hosted images, and 51 once Frameflow's second release lists its backend image, on GitHub | `gh workflow run scan-hosted.yml`, and each Monday at 04:41Z | The run's artifact | PASS from 00:15Z to 00:18Z on 2026-11-08, on `deploy/plane-prod` at `75ad7d7`: 45 of 45 targets, and 7 upstream ones with a CRITICAL that has a fix, reported and not failing ([run 42428875936](https://github.com/BereketAbera/plane-platform/actions/runs/42428875936)). Its report is the artifact `scan-hosted`, kept 30 days, and not in `docs/evidence`. See [Container scanning](../security.md#container-scanning) |
| Recovery bundle | `make remote-bundle TARGET=plane-prod`, after every bootstrap, token change or Terraform apply | None: it prints its lines and writes no record | PASS at 00:15Z on 2026-11-08, with no file here: `wayline-recovery-20261108T001505Z.tar.age`, 24 files, written, decrypted again and matched, and COMPLETE, in place of the bundle of 05:09:50Z, stale since the applies of 18:12Z and 18:13Z |
| Rollback, real restore, lockout recovery | [Rollback](hosted-rollback.md), [restore](hosted-restore.md), [lockout](hosted-lockout.md) | | NOT RUN |
