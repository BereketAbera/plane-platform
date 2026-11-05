# Resource utilization

CPU, memory, disk and storage for Wayline, a customized Plane Community Edition v1.4.3 deployment on a local kind cluster.

**What is measured so far.** The measured cells come from the platform running on 2026-11-04 and 2026-11-05, on one
laptop with Docker Desktop set to 14 GiB. **No clean install and no load test has run.** Their cells are still `MEASURE`
markers, and every "peak" below means a peak under smoke tests, drills and restarts, not under load. Both Plane
environments ran upstream images for the Plane readings. The branded images reached `plane-dev` at `4f622e3`, after the last of
them, so nothing here measures the branded images.

The tables keep three kinds of number apart:

| Label | What it is | Can it be quoted as usage? |
|---|---|---|
| **Budget** | Requests and limits configured in code. Contract section 10 sets the memory budget for Plane | No. It is a setting |
| **Estimate** | A planning number from research, with its derivation stated | No. It may be wrong |
| **Measured** | Raw output captured in [`docs/evidence/`](evidence/README.md) from a real run | Yes, for this host and that run |

Two kinds of measured memory appear, and they are not the same thing:

- **Quiet** is `kubectl top` in [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt), read at 2026-11-05T00:03:44Z with both environments running and no test started
  for that capture. Other work was still going on in the cluster, the unrelated containers were running, and the time
  since the last sync was not checked, so this is not the strict idle capture defined under
  [How to measure](#how-to-measure). `kubectl top` is one point sample of working set, so its CPU figures in particular can
  swing.
- **Peak** is cgroup `memory.peak`, the highest since that container started. It includes page cache the kernel can
  reclaim, so a peak at a limit does not by itself mean the process needs more. See [what reached a limit](#what-reached-a-limit).

Numbers here describe one laptop running one kind node. They do not predict a server, and Pass 2 needs its own.
Contract section 10 says budgets change only with a measurement, so this page is what later budget changes must cite.

## Minimums used by the scripts

`scripts/prereqs.sh` enforces these. The table explains where each number comes from.

| Check | Hard floor | Recommended | Basis |
|---|---:|---:|---|
| Docker memory, as `docker info` reports it | 13 GiB | 14 GiB setting | The floor is 13 because a 14 GiB setting shows less than 14 inside the VM: 13.63 GiB in `docker stats` and in the node's `/proc/meminfo` (`MemTotal: 14294756 kB`, [infisical-memory-1.txt](evidence/runs/infisical-memory-1.txt)). The highest VM use sampled so far is 10.49 GiB, [below](#against-the-vm), with no load test yet |
| Docker CPUs | 4 | none stated | A floor set in the script. No research or measurement stands behind it. [[VERIFY: platform boots and stays Ready at the CPU count used in the first install]] |
| Free host disk | 25 GiB | 35 GiB | Estimate. The script's message says a first install grows Docker storage by about 20 GiB. See [disk](#disk). [[MEASURE: host disk used by a first install]] |
| `guard_disk` default (`scripts/lib/common.sh`) | 10 GiB | | A guard before expensive steps. `scripts/up.sh` asks for 25 GiB and `scripts/cluster-up.sh` for 15 GiB when no cluster exists, and the default when one does. Some scripts ask for 1 or 2 GiB. `make down`, `make status` and `make logs` do not check, so they work on a full disk |

The research note also recommends 16 GiB of Docker memory if unrelated containers must keep running, because a 14 GiB
setting leaves no margin at the high estimate. That is an estimate too.

## How to measure

**Idle** means: every Application Synced and Healthy, no test or drill running, unrelated containers stopped or
recorded, and at least 10 minutes since the last sync. **Load** means the window of `make test-load ENV=dev`: 5, 10 and 20
virtual users, 3 minutes each, with 1 second of think time unless `THINK=0` is set.

Idle capture has no script, and these commands have not been run under this definition. They write it to
`.local/evidence-raw/`, and row LOAD-3 in [validation.md](validation.md#8-basic-load-and-resource-measurements) tracks it.

```bash
export KUBECONFIG=.local/kubeconfig
OUT=".local/evidence-raw/idle-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
.tools/bin/kubectl top pods -A --containers > "$OUT/top-containers.txt"
docker stats --no-stream > "$OUT/docker-stats.txt"
docker exec plane-platform-control-plane sh -c 'cat /proc/meminfo' > "$OUT/vm-meminfo.txt"
docker exec plane-platform-control-plane sh -c 'du -sh /var/local-path-provisioner/*' > "$OUT/pv-usage.txt"
docker exec plane-platform-control-plane crictl images > "$OUT/node-images.txt"
docker system df > "$OUT/docker-df.txt"
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw > "$OUT/docker-raw.txt"
df -h . > "$OUT/host-df.txt"
du -sh .local/backups/* > "$OUT/backups.txt"
```

For load, this writes `.local/evidence-raw/load-<run>/results.json`, with k6 numbers per step, Prometheus peaks per pod,
and a sample every 15 seconds. `kubectl top` reads metrics-server, so a single reading is a point sample. Use the
Prometheus peaks for "under load".

```bash
make test-e2e ENV=dev    # creates the account the load test signs in with
make test-load ENV=dev
```

`tests/load/run.sh` samples per-container use only in `plane-dev`, and it refuses `prod-sim`. So prod-sim gets no "under
load" figure. Its "during dev load" columns show what a neighbouring environment does in the same cluster. They come from
the same Prometheus, with `namespace="plane-prod-sim"`, and the load script does not capture them for you.

## Plane, per environment

### Where the estimates come from

**Budget** is contract section 10, and the code matches it: requests and limits in the rendered
`gitops/environments/{dev,prod-sim}/manifests.yaml` equal that table for all 11 workloads.

**Idle RSS estimate** is from the research cross-check, section 4. No Plane container had run when it was written. It is
anchored on a third-party Railway template figure for Plane v1.4.2 (about 1.1 GB across eleven services, method not
stated), plus `docker stats` readings of older MinIO and Postgres containers on this host. The rest is judgement.

**The contract budgets no CPU, and no CPU estimate exists.** CPU requests and limits below are from the code. Dev and
prod-sim differ only in CPU requests for api, worker, postgres and rabbitmq: 50m in dev, 100m in prod-sim.

### dev (`plane-dev`)

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Quiet RAM MiB | Quiet CPU m | Highest peak MiB, smoke and drills | Measured load peak RAM | Measured load avg CPU | Measured load peak CPU |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| web | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 15 | [[MEASURE: dev web load peak RAM]] | [[MEASURE: dev web load avg CPU]] | [[MEASURE: dev web load peak CPU]] |
| admin | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 12 | [[MEASURE: dev admin load peak RAM]] | [[MEASURE: dev admin load avg CPU]] | [[MEASURE: dev admin load peak CPU]] |
| space | 96 / 256 | 100-150 | 20 / 250 | 92 | 2 | 111 | [[MEASURE: dev space load peak RAM]] | [[MEASURE: dev space load avg CPU]] | [[MEASURE: dev space load peak CPU]] |
| live | 128 / 384 | 120-200 | 20 / 250 | 163 | 2 | 309 | [[MEASURE: dev live load peak RAM]] | [[MEASURE: dev live load avg CPU]] | [[MEASURE: dev live load peak CPU]] |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 50 / 750 | 176 | 5 | 247 | [[MEASURE: dev api load peak RAM]] | [[MEASURE: dev api load avg CPU]] | [[MEASURE: dev api load peak CPU]] |
| worker (concurrency 2) | 256 / 768 | 300-450 | 50 / 500 | 283 | 37 | 381 | [[MEASURE: dev worker load peak RAM]] | [[MEASURE: dev worker load avg CPU]] | [[MEASURE: dev worker load peak CPU]] |
| beat | 128 / 256 | 160-250 | 10 / 200 | 146 | 4 | 159 | [[MEASURE: dev beat load peak RAM]] | [[MEASURE: dev beat load avg CPU]] | [[MEASURE: dev beat load peak CPU]] |
| postgres | 128 / 512 | 50-120 | 50 / 500 | 66 | 5 | 173 | [[MEASURE: dev postgres load peak RAM]] | [[MEASURE: dev postgres load avg CPU]] | [[MEASURE: dev postgres load peak CPU]] |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 9 | 4 | 19 | [[MEASURE: dev valkey load peak RAM]] | [[MEASURE: dev valkey load avg CPU]] | [[MEASURE: dev valkey load peak CPU]] |
| rabbitmq | 128 / 512 | 140-200 | 50 / 500 | 136 | 5 | 250 | [[MEASURE: dev rabbitmq load peak RAM]] | [[MEASURE: dev rabbitmq load avg CPU]] | [[MEASURE: dev rabbitmq load peak CPU]] |
| silo | 256 / 512 | 150-300 | 20 / 500 | 108 | 2 | 149 | [[MEASURE: dev silo load peak RAM]] | [[MEASURE: dev silo load avg CPU]] | [[MEASURE: dev silo load peak CPU]] |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **300 / 3,750** | **1,187** | **68** | not one moment, see below | [[MEASURE: dev total load peak RAM]] | [[MEASURE: dev total load avg CPU]] | [[MEASURE: dev total load peak CPU]] |

Quiet is [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt). A peak is the highest cgroup `memory.peak` across the readings in
[monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt), [plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt),
[plane-prod-sim-snapshot-after-concurrent-1.txt](evidence/runs/plane-prod-sim-snapshot-after-concurrent-1.txt) and that final snapshot.
Each container peaked at its own time, so the peaks do not add up to a real moment. Summed working set for all 14 pods in
the namespace reached 1,326 MiB in the 5-second samples ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt)), and 1,762 MiB across
Prometheus's whole history, where a rollout's old and new pods can overlap ([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)).
No Plane container restarted or was OOM-killed in those readings. The nearest to a limit was `live` at 309 of 384 MiB, on a pod up 60 minutes
that had taken three smoke runs and the start of the 330-second WebSocket soak.

The namespace also runs pods outside the contract's table: the Infisical operator, `postgres-exporter` and
`redis-exporter`, counted under the platform below, and the migrator hook (128 / 512 MiB) during a sync. Those three steady
pods add 59 MiB in dev, and 66 MiB in prod-sim, to the quiet total.

### prod-sim (`plane-prod-sim`)

The load test refuses this environment, so there is no "under load" column.

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Quiet RAM MiB | Quiet CPU m | Highest peak MiB, smoke and drills | Measured RAM during dev load | Measured CPU during dev load |
|---|---:|---:|---:|---:|---:|---:|---|---|
| web | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 16 | [[MEASURE: prod-sim web RAM during dev load]] | [[MEASURE: prod-sim web CPU during dev load]] |
| admin | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 14 | [[MEASURE: prod-sim admin RAM during dev load]] | [[MEASURE: prod-sim admin CPU during dev load]] |
| space | 96 / 256 | 100-150 | 20 / 250 | 93 | 3 | 107 | [[MEASURE: prod-sim space RAM during dev load]] | [[MEASURE: prod-sim space CPU during dev load]] |
| live | 128 / 384 | 120-200 | 20 / 250 | 154 | 3 | 180 | [[MEASURE: prod-sim live RAM during dev load]] | [[MEASURE: prod-sim live CPU during dev load]] |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 100 / 750 | 174 | 4 | 293 | [[MEASURE: prod-sim api RAM during dev load]] | [[MEASURE: prod-sim api CPU during dev load]] |
| worker (concurrency 2) | 256 / 768 | 300-450 | 100 / 500 | 282 | 2 | 426 | [[MEASURE: prod-sim worker RAM during dev load]] | [[MEASURE: prod-sim worker CPU during dev load]] |
| beat | 128 / 256 | 160-250 | 10 / 200 | 148 | 4 | 163 | [[MEASURE: prod-sim beat RAM during dev load]] | [[MEASURE: prod-sim beat CPU during dev load]] |
| postgres | 128 / 512 | 50-120 | 100 / 500 | 34 | 7 | 202 | [[MEASURE: prod-sim postgres RAM during dev load]] | [[MEASURE: prod-sim postgres CPU during dev load]] |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 3 | 4 | 15 | [[MEASURE: prod-sim valkey RAM during dev load]] | [[MEASURE: prod-sim valkey CPU during dev load]] |
| rabbitmq | 128 / 512 | 140-200 | 100 / 500 | 128 | 6 | 222 | [[MEASURE: prod-sim rabbitmq RAM during dev load]] | [[MEASURE: prod-sim rabbitmq CPU during dev load]] |
| silo | 256 / 512 | 150-300 | 20 / 500 | 84 | 1 | 109 | [[MEASURE: prod-sim silo RAM during dev load]] | [[MEASURE: prod-sim silo CPU during dev load]] |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **500 / 3,750** | **1,108** | **36** | not one moment | [[MEASURE: prod-sim total RAM during dev load]] | [[MEASURE: prod-sim total CPU during dev load]] |

Same sources as the dev table. In both environments quiet memory came in below the estimate's low end: 1,108 and 1,187 MiB
against 1,240 MiB. Averaged over 10 minutes at 2026-11-05T00:49:30Z, the busiest prod-sim containers used 17m (rabbitmq) and 16m
(api) of CPU ([cpu-throttling-1.txt](evidence/runs/cpu-throttling-1.txt)).

### Load results (dev)

From `results.json`. These describe this laptop only.

| Load step | Requests/s | p95 read | p95 write | Error rate | CPU throttling on api | Peak Celery queue |
|---|---|---|---|---|---|---|
| 5 VUs, think 1s | [[MEASURE: requests per second at 5 VUs]] | [[MEASURE: p95 read at 5 VUs]] | [[MEASURE: p95 write at 5 VUs]] | [[MEASURE: error rate at 5 VUs]] | [[MEASURE: api throttled share at 5 VUs]] | [[MEASURE: celery queue peak at 5 VUs]] |
| 10 VUs, think 1s | [[MEASURE: requests per second at 10 VUs]] | [[MEASURE: p95 read at 10 VUs]] | [[MEASURE: p95 write at 10 VUs]] | [[MEASURE: error rate at 10 VUs]] | [[MEASURE: api throttled share at 10 VUs]] | [[MEASURE: celery queue peak at 10 VUs]] |
| 20 VUs, think 1s | [[MEASURE: requests per second at 20 VUs]] | [[MEASURE: p95 read at 20 VUs]] | [[MEASURE: p95 write at 20 VUs]] | [[MEASURE: error rate at 20 VUs]] | [[MEASURE: api throttled share at 20 VUs]] | [[MEASURE: celery queue peak at 20 VUs]] |
| 20 VUs, `THINK=0` | [[MEASURE: requests per second at saturation]] | [[MEASURE: p95 read at saturation]] | [[MEASURE: p95 write at saturation]] | [[MEASURE: error rate at saturation]] | [[MEASURE: api throttled share at saturation]] | [[MEASURE: celery queue peak at saturation]] |

The script's Prometheus queries cover the whole run, so a per-step figure for throttling and queue depth needs a
narrower query window. `results.json` holds per-step k6 figures only.

## Whole platform

**Budget** is summed from `helm/values/`, `infisical/manifests/`, `monitoring/manifests/` and the contract, and checked against the
running workloads on 2026-11-05. The research cross-check, section 4, had budget totals of 5,560 / 14,916 MiB. This table sums to
more, because measurements raised several limits. The **idle RSS estimate** is still that note's. It includes the old in-cluster
Git pod, in the Traefik row, and it has not been updated for the changes since.

| Group, with budget req / limit MiB per component | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | Quiet RAM MiB | Quiet CPU m | Measured peak RAM during dev load | Measured peak CPU during dev load |
|---|---:|---:|---:|---:|---|---|
| Control plane and node agents, not set by this repository: apiserver, etcd, controller-manager, scheduler, kubelet, containerd, kube-proxy, kindnet, CoreDNS x2, local-path | 290 / 340, from the research note | 750-1,300 | 1,543, pods only: kubelet and containerd are in the next row | 92 | [[MEASURE: control plane peak RAM during load]] | [[MEASURE: control plane peak CPU during load]] |
| containerd shims and pause containers, and kubelet and containerd themselves | none | 300-600, at about 5-10 MiB per pod, for the shims and pause only | 1,525, `kubectl top node` (8,331) less the pods (6,806) | 164, the same way | | |
| Traefik 64/192, metrics-server 48/128 | 112 / 320 | 80-150 | 95 | 7 | [[MEASURE: traefik and metrics-server peak RAM during load]] | [[MEASURE: traefik and metrics-server peak CPU during load]] |
| Argo CD: controller 192/1,024, repo-server 96/512, server 48/192, redis 24/64. The applicationset controller has a 32/128 budget and 0 replicas, so it is not counted | 360 / 1,792 | 450-700 | 404 | 13 | [[MEASURE: argocd peak RAM during load]] | [[MEASURE: argocd peak CPU during load]] |
| Monitoring: Prometheus 300/1,024, Alertmanager 48/96, config reloader 16/48 on each, operator 48/128, kube-state-metrics 32/96, node-exporter 24/48, Grafana 128/384, its two sidecars 96/160 each, blackbox 16/48, alert sink 16/48 | 836 / 2,288 | 620-1,040 | 1,182 | 45 | [[MEASURE: monitoring peak RAM during load]] | [[MEASURE: monitoring peak CPU during load]] |
| Loki 192/640, Alloy 96/256 | 288 / 896 | 250-500 | 392 | 13 | [[MEASURE: loki and alloy peak RAM during load]] | [[MEASURE: loki and alloy peak CPU during load]] |
| Exporters, per environment: postgres 16/48, redis 12/32 | 56 / 160 | 50 | 77 | 6 | [[MEASURE: exporters peak RAM during load]] | [[MEASURE: exporters peak CPU during load]] |
| Infisical: server 768/1,024, its Postgres 64/256, its Redis 16/96, operators 64/128 x2 | 976 / 1,632 | 610-990 | 818 | 24 | [[MEASURE: infisical peak RAM during load]] | [[MEASURE: infisical peak CPU during load]] |
| Plane x2, from the tables above | 2,848 / 8,384 | 2,480-4,160 | 2,295 | 104 | [[MEASURE: both Plane environments peak RAM during load]] | [[MEASURE: both Plane environments peak CPU during load]] |
| **Cluster total** | **5,766 / 15,812** | **5,590-9,490** | **8,331, `kubectl top node`. Pods alone: 6,806** | **468, the same reading. Pods alone: 304** | [[MEASURE: cluster total peak RAM during load]] | [[MEASURE: cluster total peak CPU during load]] |
| Local services, outside the cluster, Compose `mem_limit`: registry 512, three caches at 128 each, `plane-git` at 64 | no request / 960 | none | 113 | about 1 (0.12% of one CPU in `docker stats`) | [[MEASURE: local services peak RAM during image pulls]] | |

Quiet figures are [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt). The largest single quiet figure is the API server, at 1,168 MiB, against a research estimate of 350 to 600
MiB. It has read above 1 GiB since before Plane was deployed ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)).

The chart runs a config reloader beside both Prometheus and Alertmanager, each with a 48 MiB limit
([monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)).

Limits are deliberately overcommitted. The cluster total of 15.4 GiB exceeds the 13.63 GiB the VM really has, so if every workload
reached its limit at once the VM would run out. Contract section 10 brings the environments up serially for this reason.

### What reached a limit

Highest `memory.peak` readings outside Plane, and what they changed. Evidence: [limits-breakdown-1.txt](evidence/runs/limits-breakdown-1.txt),
[plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt), [monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt) and [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt).

| Container | Highest peak MiB | Limit MiB | What it was |
|---|---:|---:|---|
| kube-apiserver | 1,299 | none | Not limited here |
| Argo CD application controller | 731 | 768, now 1,024 | Working set reached 630 MiB with both environments up, and little of that was cache. An OOM kill there stalls every sync, so the limit went up ([argo-controller-limit-1.txt](evidence/runs/argo-controller-limit-1.txt)) |
| Prometheus | 768 | 768, now 1,024 | Touched the limit with 0 OOM kills. Largest working set 688 MiB and RSS 653 MiB, with head series up to 241,366. That left little room, so the limit went up |
| Loki | 640 | 640 | Touched the limit under a 3.5 MB/s stress test, with anon up to 552 MiB and the rest page cache ([monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt)). Largest RSS since that test: 341 MiB. 0 OOM kills. Its one restart was a deliberate `kill -9` |
| Infisical server | 822 | 1,024 | Real use at boot. It read 646 to 687 MiB when quiet, so the request went from 650 to 768 MiB |
| Infisical Postgres | 256 | 256 | Touched the limit, nearly all page cache: largest RSS 64 MiB. 0 OOM kills |
| Grafana | 345 | 384 | |
| Grafana sidecars, each | 106 | 160, up from 96 | They were OOM-killed at 96 MiB on the first boot, before logging a line. Now they watch ConfigMaps only |
| `plane-registry`, local services | 459 on a scratch registry | 512, up from 128 | Nearly all dirty page cache from a push: anon and swap stayed at or below 32 MiB. [registry-memory-1.txt](evidence/runs/registry-memory-1.txt) has the runs at each limit |

### Against the VM

| Layer | Estimate GiB (not measured) | Derivation | Measured, quiet | Highest sampled |
|---|---:|---|---|---|
| Workloads, idle | 5.5-9.3 | The cluster total above | 8.14, from `kubectl top node`. 6.65 of it is pods | |
| VM overhead | 0.4 | Research reading of `/proc/meminfo` less `docker stats`, before this platform existed | 0.15, what is left of VM used after the node, local services and unrelated containers | |
| Unrelated containers on this host | 2.0 | Research sum of `docker stats` across 16 containers, before this platform existed | 1.01: 1,039 MiB across 17 containers, in the final `docker stats` | |
| **Idle on VM** | **7.9-11.7** | Sum of the above | **9.44 median of 30 samples, top 9.61** | |
| Bursts: both migrators, API first boot, repo-server render, a backup or k6 Job | +2 | Judgement, from the Railway first-boot figure of about +0.5 GiB per environment | | [[MEASURE: largest memory burst during first install]] |
| **Peak on VM** | **9.9-13.7** | Sum of the above | | **10.49 at 2026-11-04T23:23:42Z. No load test or clean install has run** |

VM used is `MemTotal` less `MemAvailable`, sampled every 5 seconds from the node, and it includes the unrelated containers and any
other work on the cluster at the time. Tests barely move it ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt), 2026-11-04T23:17Z to 2026-11-05T00:04Z):

| Phase | Samples | VM used, median GiB | VM used, top GiB | Plane working set, top of the sum, MiB (dev + prod-sim) |
|---|---:|---:|---:|---|
| Quiet, no test started for this capture | 30 | 9.44 | 9.61 | 1,258 + 1,239 = 2,497 |
| Both smoke tests together, the soak and two NetworkPolicy matrices | 101 | 9.48 | 9.87 | 1,282 + 1,385 = 2,667 |
| Drills and broker restarts in prod-sim | 282 | 9.59 | 9.90 | 1,251 + 1,356 = 2,607 |
| Separation runs, at low load | 85 | 9.76 | 10.49 | 1,326 + 1,309 = 2,635 |
| All sampled time | 562 | 9.56 | 10.49 | 2,667 |

The 10.49 GiB reading came 5 seconds after a change replaced the Argo CD pods, so old and new copies overlapped. By 23:24:02 the VM
was at 9.11 GiB, then at 10.32 GiB again at 23:24:22 while monitoring pods were replaced. Swap reached 0.60 GiB and stayed there. The
12.5 GiB line the deploy work had set as its stop was never reached, and memory pressure stall (`some avg10`) peaked at 0.18.

**First boots, from node-exporter at a 15-second step** ([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)). These
were staged, not a clean install, with fixes landing between steps and image builds running beside them. The foundation alone reached
6.82 GiB, up from 3.39 GiB before the first apply ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)).

| Window | VM used, GiB | Plane working set, MiB |
|---|---|---|
| `plane-dev` first boot, 21:29 to 21:46 | 6.73 to 8.62 | dev 1,167 |
| `plane-prod-sim` first boot, 21:46:41 to 21:49:24 | 8.59 to 9.23 | dev 1,112, prod-sim 884 |
| Both running, 21:50 to 22:30 | 9.45 to 10.07 | dev 1,350, prod-sim 1,152 |

Stopping unrelated containers would take about 1 GiB from these figures.

### Boot and start times

Staged, on 2026-11-04, on this laptop, with fixes landing between steps. A single `make up` from nothing has not run, so these do not
predict one. Cold image pulls through the mirror dominate the first-boot figures.

| What | Measured | Evidence |
|---|---|---|
| `UP_STOP_AFTER=terraform scripts/up.sh`, first apply | 323 s, 320 s of it the Terraform step, which installs Argo CD | [bootstrap-1.txt](evidence/runs/bootstrap-1.txt) |
| First Synced and Healthy per child, from its creation | network-policies 2 s, backup-storage 0 s, Traefik 48 s, metrics-server 65 s, kube-prometheus-stack 591 s, Loki 189 s, Alloy 137 s, monitoring-extras 44 s, Infisical 400 s, each operator 31 s | [bootstrap-1.txt](evidence/runs/bootstrap-1.txt) |
| Infisical first boot | Image pull about 4 m 50 s, then 602 migrations in about 11 s | [infisical-firstboot-1.txt](evidence/runs/infisical-firstboot-1.txt) |
| Infisical second boot | No migration ran again, created to Ready 15 s | [infisical-second-boot-1.txt](evidence/runs/infisical-second-boot-1.txt) |
| `plane-dev` first boot, images pulled | Migrator pull 69 s, then 164 migrations in 83 s. Wave 3 took 448 s, because the kubelet pulls one image at a time | [plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt), [plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt) |
| `plane-prod-sim` first boot, images already on the node | Sync 163 s. Data tier 1 to 20 s to Ready, app tier 2 to 36 s | [plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt) |
| Pod delete to Ready, image on the node, seconds | web and admin 2, space 11, live 21, api 31 to 32, worker 10 to 11, beat 26 | [plane-dev-startup-1.txt](evidence/runs/plane-dev-startup-1.txt) |

## Disk

The VM cannot see the host's real limit. Research reads its filesystem as reporting far more free space than the Mac
has, so `NodeFilesystem*` alerts should not be trusted to warn before the Mac runs out. That is why every expensive
script calls `guard_disk`. [[VERIFY: VM filesystem free space reported against host free space on this machine]]
node-exporter also excludes the `/backups` mount of the Mac, because its `statfs` gave a wrong size and the percentage rules went
critical (`helm/values/kube-prometheus-stack.yaml`).

kind also disables image garbage collection and disk-based eviction, per the research reading of kind's kubeadm config.
So old images stay until removed, and a full disk means write errors rather than evictions.
[[VERIFY: kubelet config on the node shows imageGCHighThresholdPercent 100 and eviction thresholds at 0%]]

Do not run `docker system prune -a` to free disk on this host. Research found unrelated containers using a cached MinIO
image that can no longer be pulled anonymously.

### Host and Docker storage

Each estimate below is derived as stated. The "registry layer sizes" figures came from reading image layer sizes from
registries during research. They were not read from a running node, and the image set has changed since.

| Item | Estimate GiB (not measured) | Derivation | Measured |
|---|---:|---|---|
| Images on the kind node, unpacked | 8.56 | Registry layer sizes, 33 images, deduplicated | [[MEASURE: images on the node, GiB]] |
| `kindest/node` in Docker's store | 1.18 | Registry layer sizes, compressed plus unpacked | [[MEASURE: kindest/node size in Docker, GiB]] |
| Node `/var` volume seed | 0.6 | Judgement | [[MEASURE: node volume size before workloads, GiB]] |
| Pull-through caches: Docker Hub, quay.io, `registry.k8s.io` | up to 2.76 | Compressed total of all 33 images, as an upper bound. The research note priced only an optional Hub cache at 2.28 GiB, but the code always runs all three, so the note's totals leave this out | [[MEASURE: pull-through cache volumes, GiB]] |
| Local registry, Wayline blobs | 0.5 | Judgement, from before the images existed | 0.69: 705 MiB and 111 blobs on 2026-11-04T23:05Z, holding several Wayline builds ([registry-memory-1.txt](evidence/runs/registry-memory-1.txt)) |
| Build bases for Wayline images | 1.63 | Registry layer sizes, nginx by judgement | [[MEASURE: build bases in Docker's store, GiB]] |
| PVs, all environments | 1.5-4 | Judgement, see [storage](#persistent-storage) | 1.23 on 2026-11-04T22:19Z, of which 0.86 is Loki, most of it from stress tests ([monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)) |
| Container logs | 0.3-1 | Judgement. Cap about 3.2 GiB, at 10 MiB x 5 files x about 65 containers | [[MEASURE: container logs, GiB]] |
| Native Wayline build outputs | 1.3 | Judgement from research on branding | [[MEASURE: native build outputs, GiB]] |
| CLI tools, scanner cache, Terraform providers, backups | 1.1-3.2 | Part read from tool sizes, part judgement | [[MEASURE: .tools and .local, GiB]] |
| **Total host growth** | **19.5-24.8** | The research note's 16.7-22, plus the caches | [[MEASURE: total host disk used by the platform, GiB]] |

The high end of that estimate nearly reaches the 25 GiB hard floor in `scripts/prereqs.sh`, so treat 35 GiB as the
working figure until the install is measured. A cache only holds what is actually pulled, so the real number may be lower.

| Reading | Before first install | After first install | After load test | After `make destroy` |
|---|---|---|---|---|
| Host free disk | [[MEASURE: host free before install]] | [[MEASURE: host free after install]] | [[MEASURE: host free after load test]] | [[MEASURE: host free after destroy]] |
| `Docker.raw` allocated | [[MEASURE: Docker.raw before install]] | [[MEASURE: Docker.raw after install]] | [[MEASURE: Docker.raw after load test]] | [[MEASURE: Docker.raw after destroy]] |
| `docker system df` total | [[MEASURE: docker df before install]] | [[MEASURE: docker df after install]] | [[MEASURE: docker df after load test]] | [[MEASURE: docker df after destroy]] |

### Persistent storage

Declared sizes are settings. kind's local-path provisioner ignores PVC capacity, so a declared size does not cap the
volume. For Prometheus and Loki, retention is the only bound. Plane and Infisical volumes have no bound, except the host.

Measured with `du -sh` under `/var/local-path-provisioner` on the node, at 2026-11-04T22:19Z
([monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)), before most test data. `plane-dev` read 76 MiB for Postgres and 19 MiB for Silo at
23:04Z, after more smoke runs ([plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt)).

| Environment | Volume | Declared | Bound by | Estimate GiB (not measured) | Measured, 22:19Z | Measured after load |
|---|---|---:|---|---:|---|---|
| dev | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 75 MiB | [[MEASURE: dev postgres PV after load]] |
| dev | `plane-minio` | 1Gi | nothing | "small" in research | 304 KiB | [[MEASURE: dev silo PV after load]] |
| dev | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 284 KiB | [[MEASURE: dev rabbitmq PV after load]] |
| dev | `plane-redis` | 100Mi | nothing | none | 8 KiB | [[MEASURE: dev valkey PV after load]] |
| prod-sim | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 73 MiB | [[MEASURE: prod-sim postgres PV during dev load]] |
| prod-sim | `plane-minio` | 1Gi | nothing | "small" in research | 232 KiB | [[MEASURE: prod-sim silo PV during dev load]] |
| prod-sim | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 272 KiB | [[MEASURE: prod-sim rabbitmq PV during dev load]] |
| prod-sim | `plane-redis` | 100Mi | nothing | none | 8 KiB | [[MEASURE: prod-sim valkey PV during dev load]] |
| infisical | Postgres | 1Gi | nothing | 0.15-0.3 | 157 MiB | [[MEASURE: infisical postgres PV after load]] |
| infisical | Redis | 256Mi | nothing | none | 7 MiB | [[MEASURE: infisical redis PV after load]] |
| monitoring | Prometheus | 2Gi | `retention: 3d`, `retentionSize: 1GiB` | up to 1 | 66 MiB. No block had been compacted yet, so this is the WAL | [[MEASURE: prometheus PV after load]] |
| monitoring | Loki | 2Gi | `retention_period: 72h` | 0.5-2 | 882 MiB. Most of it is chunks from stress tests that pushed about 2.1 GB of synthetic lines ([monitoring-loki-limit-1.txt](evidence/runs/monitoring-loki-limit-1.txt), [-2](evidence/runs/monitoring-loki-limit-2.txt)), which stay until retention removes them | [[MEASURE: loki PV after load]] |

Backups go to `.local/backups/` on the host, not to a kind volume.

| Backup | Measured size | Measured duration |
|---|---|---|
| dev | Postgres dump 811,511 B and 34 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 30.6 s on 2026-11-04T22:58Z, with 17 objects ([dr-backup-dev-1.txt](evidence/runs/dr-backup-dev-1.txt)) |
| prod-sim | Postgres dump 714,880 B and 23 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 11.0 s on 2026-11-04T22:59Z, with no objects yet ([dr-backup-prod-sim-1.txt](evidence/runs/dr-backup-prod-sim-1.txt)) |
| infisical | Postgres dump 4,407,319 B, 785 tables, at 2026-11-05T00:04Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 21.9 s on 2026-11-04T22:58Z ([dr-backup-3.txt](evidence/runs/dr-backup-3.txt)) |

`make backup ENV=all` took 42.3 s for all three on 2026-11-04T23:13Z ([dr-backup-4.txt](evidence/runs/dr-backup-4.txt)). These hold test data, so they say
little about a real database. The size of each object store copy is not in these files.
