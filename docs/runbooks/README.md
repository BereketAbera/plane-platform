# Runbooks

Operating procedures for the local Wayline platform, a customized Plane Community Edition v1.4.3 deployment on one
kind node.

**Status.** These runbooks were written from the code, the contract and recorded research. None has been followed from
start to finish on a running platform yet, and [`docs/evidence/`](../evidence/) holds no result for them. Each
`VERIFY` marks a step or behaviour that a real run must confirm. Treat the rest as design intent until then. A
successful drill, not this page, is what would show a runbook works.

## Find the right runbook

| What you see | Go to |
|---|---|
| A new image is failing, or `ImagePullBackOff` after a promotion | [Failed deploy and rollback](failed-deploy-rollback.md) |
| Application shows `Running` or "Syncing" for a long time, or "Retrying attempt #N" | [Argo sync stuck](argo-sync-stuck.md) |
| A commit does not reach the cluster | [Argo sync stuck](argo-sync-stuck.md) |
| Plane answers 5xx, tasks do not run, uploads or exports fail | [Plane app debugging](plane-app-debugging.md) |
| `PlaneApiDown`, `PlaneWorkerNoConsumer`, `PlaneCeleryQueueMissing` and similar | [Plane app debugging](plane-app-debugging.md) |
| `guard_disk` refuses, "No space left on device", the Mac is nearly full | [Disk pressure](disk-pressure.md) |
| `OOMKilled`, `VmMemoryLow`, `ContainerMemorySaturation`, slow first boot | [Memory pressure](memory-pressure.md) |
| A backup or restore failed, or you need data back | [Backup and restore](backup-restore.md) |
| You need to change a password, or a rotation stopped partway | [Secret rotation](secret-rotation.md) |
| You want to start over from nothing | [Clean rebuild](clean-rebuild.md) |
| `make up` or a script stops, and nothing above fits | [Troubleshooting](troubleshooting.md) |

For what each alert means, see [Monitoring](../monitoring.md).

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
Valkey and Silo (a MinIO-compatible fork). `make logs` takes the chart's short name: `SVC=api`, `worker`, `beat-worker`,
`live`, `web`, `admin`, `space`, `pgdb`, `redis`, `rabbitmq`, `minio`.

## Rules that apply to every runbook

1. **Git is the desired state.** Argo CD self-heals, so `kubectl scale`, `edit` and `set` are reverted in seconds. Make
   lasting changes in Git, then run `make gitops-publish`. Argo CD reads only the bare repo that command writes, not your
   working tree and not GitHub.
2. **Pause self-heal only for drills and restores, and put it back.** Pause the root first, because the root reverts a
   pause on a child. `monitoring/ops/lib.sh` does this for scripts.
3. **Never run `docker system prune -a`.** It can remove cached images on this host that can no longer be pulled
   anonymously, and a prune of stopped containers would remove a stopped kind node.
4. **Never rotate `SECRET_KEY`.** Encrypted rows would decrypt silently to an empty string.
5. **`dev` and `prod-sim` are namespaces on one node, not independent clusters.** Node, disk, kernel, API server,
   Prometheus and Traefik are shared. A node-level fault hits both. Nothing here shows the isolation that separate
   production clusters would give.
6. **Record results honestly.** Copy evidence from `.local/evidence-raw/` to `docs/evidence/`, labelled PASS, FAIL,
   BLOCKED or NOT RUN, with date and command, and no secrets (contract section 12).

## Scripted drills

| Drill | How to run | Evidence file |
|---|---|---|
| Failed deploy and rollback, dev only | `tests/drills/failed-deploy-rollback.sh` | `.local/evidence-raw/drill-failed-deploy-<stamp>.log` |
| Pod restart persistence | `tests/drills/pod-restart-persistence.sh dev` | `.local/evidence-raw/drill-pod-restart-<env>-<stamp>.log` |
| Alert delivery | `make test-alert ENV=dev` | `.local/evidence-raw/alert-test-<env>-<stamp>.json` |

Contract section 11 names `drill-*` make targets. [[VERIFY: the Makefile has drill-* targets; at commit f733b87 it had none, so the drills are shown by script path]]
