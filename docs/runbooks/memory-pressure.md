# Memory pressure

The Docker VM can run out before any single container reaches its limit.

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
```

## Why this happens

Memory limits are overcommitted on purpose: their sum is larger than the VM's 13.63 GiB. The sums are in [resource utilization](../resource-utilization.md).

How it has run so far, with both environments up, on 2026-11-04 and 2026-11-05. VM used, including about 1 GiB of the owner's unrelated containers and whatever other agents were doing. The first four rows are the first night, 23:17Z to 00:04Z ([plane-prod-sim-memory-1.txt](../evidence/runs/plane-prod-sim-memory-1.txt)):

| Phase | Images | Median | Top |
|---|---|---:|---:|
| Quiet | upstream images | 9.44 GiB | 9.61 GiB |
| Both smokes, soak and matrices | upstream images | 9.48 GiB | 9.87 GiB |
| Drills and broker restarts | upstream images | 9.59 GiB | 9.90 GiB |
| Whole window, just after the Argo CD pods were replaced | upstream images | 9.56 GiB | 10.49 GiB |
| `make test-load ENV=dev`, with prod-sim rotated and restored beside it, read at a 60s step | final images | 9.84 GiB | 10.14 GiB |

On that first night swap reached 0.60 GiB, and memory pressure (PSI) stayed at or under 0.18. Swap read higher later, on 2026-11-05. In a quiet window from 03:40Z to 04:10Z, on images of `ec45e21`, swap topped 0.78 GiB and VM used 10.64 GiB. In the load test's window, from 07:33:48Z to 07:42:51Z, swap topped 0.76 GiB, and VM used 10.33 GiB at a 15s step, beside the table's 10.14 at 60s ([LOAD-3-20261105T074543Z-prometheus-windows.json](../evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). PSI was read once after that, at 07:44:42Z: 0.00 over 10s, 60s and 300s ([LOAD-3-20261105T074440Z-host.txt](../evidence/runs/LOAD-3-20261105T074440Z-host.txt)). One laptop on one night does not predict another machine. The load test passed its thresholds, with 2,883 requests and none failed at 5, 10 and 20 virtual users in about 10 minutes ([results.json](../evidence/runs/load-20261105T073241Z/results.json), [LOAD-3-20261105T074543Z-timeline.json](../evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). That is a small load on dev only, so it does not show where memory runs out. The top in those 60s readings, from 00:35Z to 07:47Z on 2026-11-05, was 10.93 GiB at 01:50Z. [Resource utilization](../resource-utilization.md) has the load figures. On the final images on 2026-11-05, VM used topped 9.97 GiB through the failed-deploy drill, 10.31 GiB through the rollback and promotion ([DEP-2-20261105T064032Z-timeline.txt](../evidence/runs/DEP-2-20261105T064032Z-timeline.txt)) and 9.98 GiB through the failing-migrator drill, and the node's `oom_kill` count stayed at 62 through all three ([DEP-1-20261105T062323Z-timeline.txt](../evidence/runs/DEP-1-20261105T062323Z-timeline.txt), [DEP-3-20261105T064517Z-timeline.txt](../evidence/runs/DEP-3-20261105T064517Z-timeline.txt)). That count is since the node started on 2026-11-04, so it does not say which containers those kills were.

Simultaneous first boots are expected to be the worst case, and have not been measured, so the contract says to bring environments up serially. Root's waves do that: `plane-dev`'s operation closed at 21:46:40Z and `plane-prod-sim`'s first sync began at 21:46:41Z. The measured serial first boots stayed below the later steady use in the table above: VM used topped 8.62 GiB in the first and 9.23 GiB in the second, whose images were already on the node ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt), [plane-prod-sim-memory-history-1.txt](../evidence/runs/plane-prod-sim-memory-history-1.txt)).

| Situation | Requirement, from the build's research notes, which are not in this repository (recommendation, not a measurement) |
|---|---|
| Unrelated containers stopped | At least 14 GiB for Docker |
| Unrelated containers running | 16 GiB |

`scripts/prereqs.sh` refuses below 13 GiB visible.

## Symptoms

| Symptom | Meaning |
|---|---|
| `VmMemoryLow` | `MemAvailable` below 10% of the node for 5 minutes |
| `ContainerMemorySaturation` | One container's working set above 90% of its limit for 5 minutes |
| `PodRestarting`, `lastState.terminated.reason: OOMKilled` | The container hit its cgroup limit, or the kernel chose it. `PodRestarting` needs more than one restart in 15m, so a single restart stays quiet ([podrestarting-live-1.txt](../evidence/runs/podrestarting-live-1.txt)) |
| Many pods restarting at once, slow API server, liveness failures | The VM is under pressure, not one workload |
| First boot takes very long, and pods flap | Migrations and API boots overlap |
| `memory.peak` at the limit, with no OOM kill | Usually page cache. See below |
| API requests hang while work items are being created, with nothing in the logs | RabbitMQ memory alarm has blocked publishers. See below |
| `exceeded quota` on a new pod | Namespace ResourceQuota, not VM memory |

## Diagnosis

```bash
make status
docker stats --no-stream
kubectl top pods -A --sort-by=memory | head -25
kubectl get pods -A -o json | jq -r '.items[] | .metadata as $m | .status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled") | "\($m.namespace)/\($m.name) \(.name) \(.lastState.terminated.finishedAt)"'
kubectl -n plane-dev describe resourcequota
```

Decide which case you have:

| Evidence | Case |
|---|---|
| One container is `OOMKilled` and the VM has room | Its limit is too low for its work |
| Several unrelated pods are killed, and VM memory is near full | The VM ran out. Reduce load |
| Usage at the limit, no OOM kill, and anon well below it | Page cache. Nothing to fix |
| Memory is fine, and pods are `Pending` or rejected | Quota or scheduling |

A peak at a limit says little alone, because it includes page cache. Read anonymous memory, which is what an OOM kill is about:

```bash
curl -s -G http://prometheus.localhost/api/v1/query \
  --data-urlencode 'query=max by (namespace, pod, container) (max_over_time(container_memory_rss{container="loki"}[4h]))' \
  | jq -r '.data.result[] | "\(.metric.namespace)/\(.metric.pod) \(.metric.container) \(.value[1])"'
```

Prometheus, Loki and Infisical Postgres all touched their limits on 2026-11-04 with 0 OOM kills ([limits-breakdown-1.txt](../evidence/runs/limits-breakdown-1.txt)). They were three different cases, so read each one, as `monitoring/README.md` does:

- **Prometheus's was anon,** and its limit moved. See the table below.
- **Loki's was anon too, under a stress test:** 553 MiB, with file down to 13 MiB at the tightest. Real anon has stayed at 53% of the limit or under, so its limit stayed ([alert-text-figures-1.txt](../evidence/runs/alert-text-figures-1.txt)).
- **Infisical Postgres's was mostly file,** with anon under 65 MiB. Its `file` includes 41.7 MiB of shmem, and reclaim cannot drop that here, because the container's `memory.swap.max` is 0. So read shmem beside anon for Postgres ([limits-pod-cgroup-1.txt](../evidence/runs/limits-pod-cgroup-1.txt)).

Read `memory.events` at the pod cgroup as well, when one container carries the pod's whole limit: Loki's pod read `max` 58931 and Infisical Postgres's 4227 and then 5066, with 0 at each container. Those count reclaim. An OOM kill is a separate counter, and it read 0 for the whole of each pod.

Grafana's Platform overview shows "VM memory used" and "Memory by namespace". `kubectl top` needs metrics-server, which is synced at wave -8.

RabbitMQ memory alarm:

```bash
kubectl -n plane-dev exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmq-diagnostics alarms
kubectl -n plane-dev exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmq-diagnostics memory_breakdown
```

RabbitMQ runs with `vm_memory_high_watermark.absolute = 256Mi` under a 512 MiB limit. The default of 0.4 is unsafe here: if RabbitMQ detects the limit, 0.4 of it sits close to idle use and blocks publishers, which hangs `.delay()`. If it does not detect the limit, 0.4 of the VM's memory ends in an OOM kill. The smoke step `broker-memory` reads the running broker in both environments. On the final images on 2026-11-05 it read `watermark {absolute,"256Mi"} = 268435456 bytes, no alarms` ([smoke-dev-20261105T053137Z-52811.json](../evidence/runs/smoke-dev-20261105T053137Z-52811.json), [smoke-prod-sim-20261105T053533Z-8468.json](../evidence/runs/smoke-prod-sim-20261105T053533Z-8468.json)).

## Fix

**The VM ran out.** In order of cost:

1. Stop unrelated containers, by name, and only ones you own and can restart. They came to 1,039 MiB on this host on 2026-11-05 ([plane-prod-sim-snapshot-final-1.txt](../evidence/runs/plane-prod-sim-snapshot-final-1.txt)).

   ```bash
   docker ps --format '{{.Names}}\t{{.Status}}'
   docker stop <name>
   ```

2. Give Docker more memory: Docker Desktop, Settings, Resources, Memory. Leave enough for macOS.
3. A branded image build is mostly not VM memory. Its native part, `apps/wayline/scripts/build.sh`, runs on the Mac, so it takes the Mac's memory and not the VM's. From a cold turbo cache under the settings CI uses, its largest process reached 1,556 MiB and the sampled sum of its processes 1,640 MiB ([build-ci-settings.txt](../evidence/branding/build-ci-settings.txt)). An earlier cold run of three apps summed to 2,126 MiB ([wayline-build-1.txt](../evidence/runs/wayline-build-1.txt)), and the `1563cbf` build, reusing the cache, to 619 MiB (`git show c5eb3ad:docs/evidence/branding/build.txt`). Docker's part runs in the VM, and its own memory has not been measured. That same build, with most layers cached, on 2026-11-04 with both environments up, left VM used between 9,586 and 9,691 MiB from 23:53:51Z to 23:54:40Z, with a drill starting beside it (`git show c5eb3ad:docs/evidence/branding/images-build.txt`, [plane-prod-sim-memory-samples-2.tsv](../evidence/runs/plane-prod-sim-memory-samples-2.tsv)). [build.txt](../evidence/branding/build.txt) and [images-build.txt](../evidence/branding/images-build.txt) now hold a later build, from `84b63d9`, with a largest process of 319 MiB and no sampled sum. A cold run of Docker's part has not been measured, so hold it back while the VM is short.
4. Take prod-sim's app tier down through Git, if you do not need it right now. There is no lean overlay in the repo today. It would have to be a Git overlay and not `kubectl scale`, as the build's research notes, which are not in this repository, say: self-heal put back a `kubectl scale` in 3s ([GITOPS-4-20261105T073240Z.txt](../evidence/runs/GITOPS-4-20261105T073240Z.txt)).

**One container is too small.** Limits come from contract section 10, which says to change them only with a measurement. Record the measurement, then edit Git:

| Workload | Where |
|---|---|
| Plane | `helm/plane/components/hardening/patches/<workload>.yaml`, then `make render` |
| Platform charts | `helm/values/<chart>.yaml`. Argo CD's own values need `terraform apply`, not a publish |
| Exporters, blackbox, sink | `monitoring/manifests/` |
| Registry, caches, Git remote | `infrastructure/local-services/compose.yaml` |

Raising a Plane limit can pass the namespace ResourceQuota, which Terraform computes from its own table. Update `infrastructure/terraform/modules/foundation/main.tf` too, or the rollout fails with `exceeded quota` while old pods keep running. Then commit, `make gitops-publish`, and `terraform apply` for the quota.

What has really happened to limits on this platform:

| Workload | Limit now | What was measured |
|---|---|---|
| Grafana sidecars | 160 MiB | At 96 MiB they were OOM-killed about 35s after every start, before logging a line, with 20 container restarts by then and 26 kill lines in `dmesg`, where each PID shown is logged twice. So Grafana had no dashboard and no Ready pod, and `kube-prometheus-stack` flapped ([monitoring-grafana-before-1.txt](../evidence/runs/monitoring-grafana-before-1.txt)). They peak at 106 MiB now, and watch ConfigMaps only ([monitoring-memory-1.txt](../evidence/runs/monitoring-memory-1.txt)) |
| Grafana | 384 MiB | Its own container was not killed. Peak 333 MiB, and 277 MiB of anon under six parallel runs of all 26 dashboards ([monitoring-grafana-load-1.txt](../evidence/runs/monitoring-grafana-load-1.txt)). Each bundled datasource with a backend is its own process, so 15 are disabled |
| Prometheus | 1 GiB, was 768 MiB | Anon reached 652 MiB at a head compaction, with 241k head series ([limits-breakdown-1.txt](../evidence/runs/limits-breakdown-1.txt)). No OOM kill |
| Argo CD controller | 1 GiB, was 768 MiB | `memory.peak` 731 MiB with Plane running ([plane-dev-memory-1.txt](../evidence/runs/plane-dev-memory-1.txt), [argo-controller-limit-1.txt](../evidence/runs/argo-controller-limit-1.txt)). No OOM kill. One would stall every sync |
| Argo CD repo-server | 512 MiB | Peak 247 MiB in the test with all 8 chart Applications hard-refreshed at once ([argocd-render-load-1.txt](../evidence/runs/argocd-render-load-1.txt)). The highest read on that pod was 269 MiB ([plane-dev-memory-1.txt](../evidence/runs/plane-dev-memory-1.txt), [monitoring-memory-1.txt](../evidence/runs/monitoring-memory-1.txt)) |
| Loki | 640 MiB | Below the chart's example of 2 to 4 GiB, and it held: 553 MiB of anon at its worst under 3.5 MB/s of pushes, with no OOM kill ([monitoring-loki-limit-2.txt](../evidence/runs/monitoring-loki-limit-2.txt)). Real anon peaked at 341 MiB ([alert-text-figures-1.txt](../evidence/runs/alert-text-figures-1.txt)). Raise this first if that changes |
| `plane-registry` | 512 MiB, was 128 MiB | A push fills the limit with dirty page cache, and the kernel then killed a registry with almost no memory of its own ([registry-memory-1.txt](../evidence/runs/registry-memory-1.txt)) |
| Plane workloads | Contract section 10 | On 2026-11-04, on upstream images, through smoke, soak and matrices in both environments, no container passed 66% of its limit by `memory.peak`, and 0 were OOM-killed ([plane-prod-sim-memory-1.txt](../evidence/runs/plane-prod-sim-memory-1.txt)). `live` reached 309 of 384 MiB on an earlier pod, after three smoke runs and the start of a soak ([plane-dev-memory-1.txt](../evidence/runs/plane-dev-memory-1.txt)) |

**First boot.** Wait for it to converge. Retries are unlimited. Infisical's first boot ran 602 migrations in about 11s under its 1 GiB limit, with a peak of 807 MiB and 0 OOM kills ([infisical-firstboot-1.txt](../evidence/runs/infisical-firstboot-1.txt)). If it is killed there on another machine, a temporary raise in Git is the fallback.

## Confirm

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl top pods -A --sort-by=memory | head -10
docker stats --no-stream
```

`VmMemoryLow` and `ContainerMemorySaturation` should resolve, and restart counts should stop climbing on the Platform overview's "Most restarted containers" table. Record real numbers in [resource utilization](../resource-utilization.md).

## What not to do

| Do not | Why |
|---|---|
| `kubectl scale` or `kubectl set resources` to relieve pressure | Self-heal reverts them in seconds |
| Remove limits | The VM would run out sooner, and the kernel would pick the victim |
| Raise limits with no measurement | Contract section 10. Limits already exceed the VM |
| Raise a limit because `memory.peak` touched it | Read anon first, and shmem beside it for Postgres. Infisical Postgres's peak was mostly file, and Loki's real anon stayed at 53% of its limit |
| Raise `vm_memory_high_watermark` to or above the container limit | RabbitMQ then gets OOM killed instead of applying back-pressure |
| Raise `CELERY_WORKER_CONCURRENCY` to clear a backlog on a tight VM | Each fork costs memory. With no setting Celery forks once per CPU the node reports, 12 on this host, and the hardening patch caps it at 2 |
| Start both environments' first boots at the same time | It is expected to be the worst case. It has not been measured |
| Stop containers that you do not recognise | Other projects on this host share Docker |
| Conclude "the apps leak" from a working-set graph alone | Working set includes page cache. Check for actual OOM kills |
