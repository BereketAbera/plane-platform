# Resource utilization

CPU, memory, disk and storage for Wayline, a customized Plane Community Edition v1.4.3 deployment on a local kind cluster.

**What is measured so far.** The measured cells come from the platform running on 2026-11-04 and 2026-11-05, on one
laptop with Docker Desktop set to 14 GiB. This is a local deployment, and nothing here says it is production-ready.
**One load test has run, on a machine that was not quiet**: 5, 10 and 20 virtual users with think time, from
2026-11-05T07:33:48Z to 07:42:51Z. See [the load window](#the-load-window). **No clean install has a recorded result, and the saturation pass is NOT RUN.**
The markers left here wait on different runs: the CPU count and host free disk on the clean-restore drill's evidence, disk used by a first install on a cold install
with the registry and caches gone (TEAR-4), and `Docker.raw` after a destroy on TEAR-5. A cell the clean install does not read, and no later run is set to read, says Not tested in Pass 1. A column headed "Highest peak" means a peak under smoke tests,
drills and restarts. The load columns say so in their heading.

The quiet and "Highest peak" columns are older than the load test, and both Plane environments ran upstream images for them. The last
`plane-dev` reading of that kind came before the branded images reached it at `4f622e3`, on 2026-11-05T00:09Z. The one later reading, the
CPU average at 00:49:30Z, is from prod-sim, which still ran upstream images then. The load columns do measure the branded images: web, admin,
space, api, worker and beat ran `localhost:5001/wayline/` images in both environments, and live, Postgres, Valkey, RabbitMQ and Silo ran upstream
images ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt), and `gitops/environments/dev/manifests.yaml` for dev's backend pods, which were down for a restore at that reading).

The tables keep three kinds of number apart:

| Label | What it is | Can it be quoted as usage? |
|---|---|---|
| **Budget** | Requests and limits configured in code. Contract section 10 sets the memory budget for Plane | No. It is a setting |
| **Estimate** | A planning number from research, with its derivation stated | No. It may be wrong |
| **Measured** | Raw output captured in [`docs/evidence/`](evidence/README.md) from a real run | Yes, for this host and that run |

Three kinds of measured memory appear, and they are not the same thing:

- **Quiet** is `kubectl top` in [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt), read at 2026-11-05T00:03:44Z with both environments running and no test started
  for that capture. Other work was still going on in the cluster, the unrelated containers were running, and the time
  since the last sync was not checked, so this is not the strict idle capture defined under
  [How to measure](#how-to-measure). `kubectl top` is one point sample of working set, so its CPU figures in particular can
  swing.
- **Peak** is cgroup `memory.peak`, the highest since that container started. It includes page cache the kernel can
  reclaim, so a peak at a limit does not by itself mean the process needs more. See [what reached a limit](#what-reached-a-limit).
- **Load** is working set from Prometheus in the load window, with a 30-second scrape read every 15 seconds. A burst shorter than a scrape
  can be missed. Working set leaves out inactive page cache, so it can read lower than `memory.peak`. A CPU peak there is the highest `rate(...[1m])`, so it is a
  one-minute average, not an instant.

Numbers here describe one laptop running one kind node. They do not predict a server, and Pass 2 needs its own.
Contract section 10 says budgets change only with a measurement, so this page is what later budget changes must cite.

## Minimums used by the scripts

`scripts/prereqs.sh` enforces these. The table explains where each number comes from.

| Check | Hard floor | Recommended | Basis |
|---|---:|---:|---|
| Docker memory, as `docker info` reports it | 13 GiB | 14 GiB setting | The floor is 13 because a 14 GiB setting shows less than 14 inside the VM: 13.63 GiB in `docker stats` and in the node's `/proc/meminfo` (`MemTotal: 14294756 kB`, [infisical-memory-1.txt](evidence/runs/infisical-memory-1.txt)). The highest VM use sampled so far is 10.93 GiB, [below](#against-the-vm), with one load test at think time, and no saturation pass or clean install |
| Docker CPUs | 4 | none stated | A floor set in the script. No research or measurement stands behind it. [[VERIFY: platform boots and stays Ready at the CPU count used in the first install]] |
| Free host disk | 25 GiB | 35 GiB | Estimate. The script's message says a first install grows Docker storage by about 20 GiB. See [disk](#disk). [[MEASURE: host disk used by a first install]] |
| `guard_disk` default (`scripts/lib/common.sh`) | 10 GiB | | A guard before expensive steps. `scripts/up.sh` asks for 25 GiB and `scripts/cluster-up.sh` for 15 GiB when no cluster exists, and the default when one does. Some scripts ask for 1 or 2 GiB. `make down`, `make status` and `make logs` do not check, so they work on a full disk |

The research note also recommends 16 GiB of Docker memory if unrelated containers must keep running, because a 14 GiB
setting leaves no margin at the high estimate. That is an estimate too.

## How to measure

**Idle** means: every Application Synced and Healthy, no test or drill running, unrelated containers stopped or
recorded, and at least 10 minutes since the last sync. **Load** means the window of `make test-load ENV=dev`: 5, 10 and 20
virtual users, 3 minutes each, with `THINK=1`, which sleeps 1 to 3 seconds between requests, unless `THINK=0` is set.

Idle capture has no script, and these commands have not been run under this definition. They write it to
`.local/evidence-raw/`, and row LOAD-3 in [validation.md](validation.md#8-basic-load-and-resource-measurements) tracks it.
The nearest reading so far is a [quiet window](#the-load-window) taken from Prometheus's history.

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

## The load window

**Four files this page links are not committed yet.** `LOAD-3-20261105T074543Z-derived.txt`, its `-derive-script.py.txt`, `-docker-images.txt` and `-quiet-window-syncs.json` were written by 2026-11-05T08:01Z and wait for the next `make publish-evidence`. Until that is committed those links break in a clone, and by [the evidence rules](evidence/README.md#rules) what rests on one of them alone has no result: the quiet window's sync count, the build-bases note, and the 0.11 GiB of local service images in the 21.18 GiB sum. The other derived figures come from inputs that are committed: the `prometheus-windows`, `prometheus-series`, `prometheus-steps`, `traefik-buckets` and `timeline` files with that stamp, the host and Docker captures, and `results.json`.

`make test-load ENV=dev` ran at commit `4aa0640` with `THINK=1`, which sleeps 1 to 3 seconds between requests ([LOAD-1-20261105T073240Z-run.txt](evidence/runs/LOAD-1-20261105T073240Z-run.txt)). The Job was created at
2026-11-05T07:32:49Z, and the k6 container ran from 07:33:48Z to 07:42:51Z ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt), and the same window in [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). The load columns on this page use that window. k6's thresholds
passed: 2,883 requests, none failed and none answered 429 ([results.json](evidence/runs/load-20261105T073241Z/results.json)). This describes one laptop running a local deployment, not a production-ready one.

**The machine was not quiet.** These ran in the same minutes:

| Time, 2026-11-05 UTC | What else ran | Evidence |
|---|---|---|
| 07:23:31 to 07:40:19 | The SEC-2 watcher: a signed-in `GET /api/users/me/` on dev about once a second, with 178, 178 and 29 samples in the three steps. Traefik counted 625, 1,104 and 1,658 GET and POST requests on the API route across those steps, against k6's 428, 873 and 1,576, and this watcher is 385 of those 510 extra requests. In the first step it added about 42% to k6's API rate. Probes on that route, at about 24 per 180 s in the quiet window, and the browser tabs below are in the rest | [SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt), [LOAD-3-20261105T074543Z-traefik-buckets.json](evidence/runs/LOAD-3-20261105T074543Z-traefik-buckets.json), [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json) |
| 07:32:08 to 07:41:19 | Two browser tabs editing a page in `plane-dev`, by hand, with no script. At 07:38:02 the dev `live` pod was deleted on purpose | [RT-2b-RT-3-20261105T073208Z.txt](evidence/runs/RT-2b-RT-3-20261105T073208Z.txt) |
| 07:32:40 to 07:38:00 | prod-sim: `make rotate`, a backup, a refused restore at 07:34:28, a real restore at 07:34:38, then e2e. The restored pods started between 07:35:52 and 07:37:09 | [SEC-3-BKP-3-20261105T073240Z.txt](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt), [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json) |
| 07:38:43 to 07:39:45 | prod-sim: a rotation stopped with SIGKILL, then resumed. It replaced pods at 07:38:44. Old and new pods overlapping is why the cluster's memory and CPU sums both top out at 07:39:33 | [SEC-4-20261105T073843Z.txt](evidence/runs/SEC-4-20261105T073843Z.txt), [LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt) |
| Whole window | Docker counted 23 running containers, 6 of them this project's. The others stayed up and were not recorded | [LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt) |

So alerts fired in prod-sim during the window (`PlaneApiDown`, `PlaneApiDatabaseProbeFailing`, `PlaneFrontendDown`), and Argo CD showed `plane-prod-sim`
and `root` as not healthy at some point in it. Beyond `Watchdog` and `InfoInhibitor`, none fired for anything else ([LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). A dev backup at 07:43:22 and a dev restore at
07:43:37 followed the load, so readings from 07:44 on are of a dev environment being restored ([BKP-2-20261105T074322Z.txt](evidence/runs/BKP-2-20261105T074322Z.txt), [restore-dev-20261105T074337Z.json](evidence/runs/restore-dev-20261105T074337Z.json)). That is why the volume table below uses the load script's
own reading from 07:42:58.

**The quiet window is 2026-11-05T03:40:00Z to 04:10:00Z.** It is the longest gap between raw evidence files since Prometheus last started: 03:39:57Z to
04:10:55Z ([LOAD-3-20261105T074543Z-quiet-window.txt](evidence/runs/LOAD-3-20261105T074543Z-quiet-window.txt)). Container CPU was also at its lowest of the night there, at 310, 290 and 325 m in 10-minute buckets ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt), [LOAD-3-20261105T074543Z-timeline.json](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). Prometheus then confirms it:
`Watchdog` was the only alert firing, and the alert sink took one webhook every 5 minutes. Every Application stayed Synced and Healthy, with no sync in the
window or in the 20 minutes before it ([LOAD-3-20261105T074543Z-quiet-window-syncs.json](evidence/runs/LOAD-3-20261105T074543Z-quiet-window-syncs.json)). No pod was created, no Job ran, nothing restarted, no OOM event rose, and Traefik saw the probes at 0.8 requests a second
plus 36 requests to Prometheus itself ([LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json), [LOAD-3-20261105T074543Z-timeline.json](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)).

It is still not the idle capture under [How to measure](#how-to-measure). Unrelated containers ran and were not recorded, and four commits landed at 04:03Z with no sync after them. It also ran
the Wayline build before the final one, which reached dev at 05:29:47Z and prod-sim at 05:34:06Z (`git log gitops/environments/`).

| Prometheus, per namespace | Quiet RAM MiB, avg / top | Load RAM MiB, avg / top | Quiet CPU m, avg / top | Load CPU m, avg / top |
|---|---:|---:|---:|---:|
| `plane-dev`, with k6, exporters and operator | 1,205 / 1,257 | 1,184 / 1,229 | 45 / 71 | 526 / 915 |
| `plane-prod-sim`, with exporters and operator | 1,211 / 1,254 | 1,070 / 1,721 | 46 / 75 | 260 / 823 |
| `kube-system` | 1,590 / 1,613 | 1,682 / 1,710 | 108 / 147 | 273 / 398 |
| `monitoring` | 1,568 / 1,580 | 1,643 / 1,665 | 48 / 65 | 91 / 123 |
| `monitoring-agents` | 20 / 21 | 20 / 22 | 1.5 / 2.9 | 2.3 / 4.4 |
| `infisical` | 733 / 768 | 754 / 778 | 21 / 58 | 50 / 266 |
| `argocd` | 472 / 594 | 525 / 644 | 27 / 81 | 64 / 130 |
| `traefik` | 61 / 63 | 70 / 74 | 2.2 / 3.4 | 16 / 27 |
| `local-path-storage` | 15 / 15 | 15 / 16 | 0.3 / 0.8 | 0.5 / 1.3 |
| **All pods, summed at each step** | **6,876 / 7,004** | **6,979 / 7,599** | **309 / 391** | **1,270 / 2,078** |
| VM used, GiB, and busy CPU, m | 10.04 / 10.64 | 9.77 / 10.33 | 951 / 1,880 | 2,035 / 3,080 |

Namespace rows are from [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json). The last two rows are from [LOAD-3-20261105T074543Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-series.json), at a 60-second step for quiet and a 15-second step for load, through [LOAD-3-20261105T074543Z-derive-script.py.txt](evidence/runs/LOAD-3-20261105T074543Z-derive-script.py.txt). Per-container figures for both windows are in
[LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt).

Under this load `plane-dev` used about 12 times the CPU it used when quiet, and no more memory. The VM read lower under load than in the quiet window. It also counts the unrelated
containers, so this page does not explain that gap. The tops for prod-sim come from its own rotation and restore, not from the load, which ran in dev only.

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

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Quiet RAM MiB | Quiet CPU m | Highest peak MiB, smoke and drills | Measured load peak RAM MiB, 07:33:48Z to 07:42:51Z | Measured load avg CPU m, same window | Measured load peak CPU m, same window |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| web | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 15 | 3 | 0.3 | 0.8 |
| admin | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 12 | 3 | 0.2 | 0.6 |
| space | 96 / 256 | 100-150 | 20 / 250 | 92 | 2 | 111 | 92 | 7.1 | 13 |
| live | 128 / 384 | 120-200 | 20 / 250 | 163 | 2 | 309 | 154 | 11 | 103 |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 50 / 750 | 176 | 5 | 247 | 172 | 190 | 389 |
| worker (concurrency 2) | 256 / 768 | 300-450 | 50 / 500 | 283 | 37 | 381 | 269 | 67 | 116 |
| beat | 128 / 256 | 160-250 | 10 / 200 | 146 | 4 | 159 | 148 | 4.5 | 7.4 |
| postgres | 128 / 512 | 50-120 | 50 / 500 | 66 | 5 | 173 | 63 | 199 | 377 |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 9 | 4 | 19 | 11 | 3.6 | 4.6 |
| rabbitmq | 128 / 512 | 140-200 | 50 / 500 | 136 | 5 | 250 | 158 | 23 | 32 |
| silo | 256 / 512 | 150-300 | 20 / 500 | 108 | 2 | 149 | 136 | 2.1 | 5.7 |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **300 / 3,750** | **1,187** | **68** | not one moment, see below | **1,150** at 07:41:48Z | **503** | **878** at 07:41:03Z |

Quiet is [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt). A peak is the highest cgroup `memory.peak` across the readings in
[monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt), [plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt),
[plane-prod-sim-snapshot-after-concurrent-1.txt](evidence/runs/plane-prod-sim-snapshot-after-concurrent-1.txt) and that final snapshot.
Each container peaked at its own time, so the peaks do not add up to a real moment. Summed working set for all 14 pods in
the namespace reached 1,326 MiB in the 5-second samples ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt)), and 1,762 MiB across
Prometheus's whole history, where a rollout's old and new pods can overlap ([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)).
No Plane container restarted or was OOM-killed in those readings. The nearest to a limit was `live` at 309 of 384 MiB, on a pod up 60 minutes
that had taken three smoke runs and the start of the 330-second WebSocket soak.

Load columns are from [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json), per container. The total row sums the 11 workloads at each 15-second step ([LOAD-3-20261105T074543Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-series.json), through [LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)), so it is one real moment, and the rows do not add up
to it exactly. Memory stayed well under every limit: the highest share was beat, at 148 of 256 MiB. No container had an OOM event, and none restarted by itself. `live`'s CPU peak is its restart
after the deliberate delete at 07:38:02Z. k6 itself reached 22 MiB and 17 m.

The namespace also runs pods outside the contract's table: the Infisical operator, `postgres-exporter` and
`redis-exporter`, counted under the platform below, and the migrator hook (128 / 512 MiB) during a sync. Those three steady
pods add 59 MiB in dev, and 66 MiB in prod-sim, to the quiet total.

### prod-sim (`plane-prod-sim`)

The load test refuses this environment, so there is no "under load" column. The during-load columns show what prod-sim used while dev took the load and
while prod-sim went through its own rotation and restore.

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Quiet RAM MiB | Quiet CPU m | Highest peak MiB, smoke and drills | Measured RAM during dev load MiB, avg / top of one pod, 07:33:48Z to 07:42:51Z | Measured CPU during dev load m, avg / top of one pod, same window |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| web | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 16 | 3 / 3 | 0.1 / 0.2 |
| admin | 16 / 64 | 5-20 | 10 / 100 | 4 | 1 | 14 | 3 / 3 | 0.1 / 0.3 |
| space | 96 / 256 | 100-150 | 20 / 250 | 93 | 3 | 107 | 92 / 92 | 4.4 / 7.7 |
| live | 128 / 384 | 120-200 | 20 / 250 | 154 | 3 | 180 | 149 / 160 | 18 / 129 |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 100 / 750 | 174 | 4 | 293 | 160 / 166 | 108 / 371 |
| worker (concurrency 2) | 256 / 768 | 300-450 | 100 / 500 | 282 | 2 | 426 | 246 / 279 | 46 / 246 |
| beat | 128 / 256 | 160-250 | 10 / 200 | 148 | 4 | 163 | 148 / 149 | 42 / 189 |
| postgres | 128 / 512 | 50-120 | 100 / 500 | 34 | 7 | 202 | 58 / 65 | 19 / 73 |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 3 | 4 | 15 | 6 / 7 | 3.5 / 4.4 |
| rabbitmq | 128 / 512 | 140-200 | 100 / 500 | 128 | 6 | 222 | 130 / 179 | 30 / 98 |
| silo | 256 / 512 | 150-300 | 20 / 500 | 84 | 1 | 109 | 113 / 119 | 3.7 / 13 |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **500 / 3,750** | **1,108** | **36** | not one moment | **1,033 / 1,687** at 07:39:33Z, the rollout's overlap | **254 / 824** at 07:39:33Z |

Same sources as the dev table. In both environments quiet memory came in below the estimate's low end: 1,108 and 1,187 MiB
against 1,240 MiB. Averaged over 10 minutes at 2026-11-05T00:49:30Z, the busiest prod-sim containers used 17m (rabbitmq) and 16m
(api) of CPU ([cpu-throttling-1.txt](evidence/runs/cpu-throttling-1.txt)).

During-load figures are from [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json). An average is over the samples when that container existed, and "top of one pod" is the highest pod, because rollouts ran old and new pods together. Summed across
the overlap, api read 318 MiB, worker 510 and beat 295. The total row is summed at each 15-second step, so it includes that overlap ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)).

### Load results (dev)

k6 figures are from [results.json](evidence/runs/load-20261105T073241Z/results.json), and the rest from per-step queries ([LOAD-3-20261105T074543Z-prometheus-steps.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-steps.json), [LOAD-3-20261105T074543Z-traefik-buckets.json](evidence/runs/LOAD-3-20261105T074543Z-traefik-buckets.json)). These describe this laptop only.

| Load step | Requests/s | p95 all requests ms, k6 | p95 read ms, Traefik GET (its bucket) | p95 write ms, Traefik POST (its bucket) | Error rate | CPU throttling on api | Peak Celery queue |
|---|---|---|---|---|---|---|---|
| 5 VUs, `THINK=1`, 07:33:50Z to 07:36:50Z | 2.38 (428 in 180 s) | 147 | about 227 (100-300) | about 233 (100-300) | 0 of 428 | 2.9% | 0 ready, 0 in all |
| 10 VUs, `THINK=1`, 07:36:50Z to 07:39:50Z | 4.85 (873 in 180 s) | 280 | about 296 (100-300) | about 280 (100-300) | 0 of 873 | 2.1% | 0 ready, 0 in all |
| 20 VUs, `THINK=1`, 07:39:50Z to 07:42:50Z | 8.76 (1,576 in 180 s) | 1,109 | about 1,055 (300-1,200) | about 1,227 (1,200-5,000) | 0 of 1,576 | 10.1% | 0 ready, 1 in all |
| 20 VUs, `THINK=0` | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

k6's summary splits read from write only across the whole run: p95 read 664 ms and p95 write 618 ms. Per step it has all requests together. So the two per-step p95 columns come from
Traefik's histogram on the API route, interpolated inside its default buckets of 0.1, 0.3, 1.2 and 5 seconds, and they include the SEC-2 watcher, the browser test and the probes. Read each as its bucket.

The script's Prometheus queries cover the whole run, so a per-step figure for throttling and queue depth needs a
narrower query window. `results.json` holds per-step k6 figures only. So throttling here is throttled CFS periods over all CFS periods for the api containers in each step, and the queue is the
highest `rabbitmq_detailed_queue_messages_ready` and `rabbitmq_detailed_queue_messages` for `celery`. A queue shorter than a 30-second scrape would not show.

Whole run, from [results.json](evidence/runs/load-20261105T073241Z/results.json): the slowest request took 5,064 ms, the 99th percentile was 2,885 ms, and Traefik counted no 5xx on the API route. The dev database grew by about 730 KB, and the VM's `/var` by 59.8 MiB.

**LOAD-2, where the single API worker saturates: NOT RUN.** `THINK=0` takes about 10 minutes. LOAD-1 finished at about 07:43Z, so about 4 minutes were left before the 07:47Z cut-off, ahead of the cluster's planned deletion at 07:50Z. So
this page has no saturation point. What the think-time run does show is narrower. Requests per second still rose with each step. 8.76 at 20 VUs is what 20 VUs allow with 2 seconds of mean think time and 0.3
seconds per request, so no plateau appeared. The API averaged 92, 169 and 308 m across the steps, with a top of 389 m against its 750 m limit. Postgres averaged 91, 184 and 323 m, with a top of 377 m against its
500 m limit, and it was throttled in 7%, 20% and 50% of its CFS periods, against the API's 3%, 2% and 10% ([LOAD-3-20261105T074543Z-prometheus-steps.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-steps.json)). k6's p95 went from 280 ms to 1,109 ms between 10 and 20 VUs. So Postgres's CPU limit may bind before
the API worker does. That is a reading of one run on a busy machine, and a `THINK=0` pass is what would test it.

## Whole platform

**Budget** is summed from `helm/values/`, `infisical/manifests/`, `monitoring/manifests/` and the contract, and checked against the
running workloads on 2026-11-05. The research cross-check, section 4, had budget totals of 5,560 / 14,916 MiB. This table sums to
more, because measurements raised several limits. The **idle RSS estimate** is still that note's. It includes the old in-cluster
Git pod, in the Traefik row, and it has not been updated for the changes since.

| Group, with budget req / limit MiB per component | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | Quiet RAM MiB | Quiet CPU m | Measured peak RAM MiB during dev load, 07:33:48Z to 07:42:51Z | Measured peak CPU m during dev load, same window |
|---|---:|---:|---:|---:|---|---|
| Control plane and node agents, not set by this repository: apiserver, etcd, controller-manager, scheduler, kubelet, containerd, kube-proxy, kindnet, CoreDNS x2, local-path | 290 / 340, from the research note | 750-1,300 | 1,543, pods only: kubelet and containerd are in the next row | 92 | 1,694 at 07:35:03Z | 389 at 07:35:18Z |
| containerd shims and pause containers, and kubelet and containerd themselves | none | 300-600, at about 5-10 MiB per pod, for the shims and pause only | 1,525, `kubectl top node` (8,331) less the pods (6,806) | 164, the same way | | |
| Traefik 64/192, metrics-server 48/128 | 112 / 320 | 80-150 | 95 | 7 | 110 at 07:38:18Z | 33 at 07:38:33Z |
| Argo CD: controller 192/1,024, repo-server 96/512, server 48/192, redis 24/64. The applicationset controller has a 32/128 budget and 0 replicas, so it is not counted | 360 / 1,792 | 450-700 | 404 | 13 | 644 at 07:35:18Z | 128 at 07:35:33Z |
| Monitoring: Prometheus 300/1,024, Alertmanager 48/96, config reloader 16/48 on each, operator 48/128, kube-state-metrics 32/96, node-exporter 24/48, Grafana 128/384, its two sidecars 96/160 each, blackbox 16/48, alert sink 16/48 | 836 / 2,288 | 620-1,040 | 1,182 | 45 | 1,240 at 07:33:48Z | 97 at 07:39:33Z |
| Loki 192/640, Alloy 96/256 | 288 / 896 | 250-500 | 392 | 13 | 455 at 07:37:18Z | 40 at 07:39:33Z |
| Exporters, per environment: postgres 16/48, redis 12/32 | 56 / 160 | 50 | 77 | 6 | 62 at 07:36:48Z | 7.3 at 07:39:33Z |
| Infisical: server 768/1,024, its Postgres 64/256, its Redis 16/96, operators 64/128 x2 | 976 / 1,632 | 610-990 | 818 | 24 | 831 at 07:34:03Z | 273 at 07:34:33Z |
| Plane x2, from the tables above | 2,848 / 8,384 | 2,480-4,160 | 2,295 | 104 | 2,760 at 07:39:33Z, with prod-sim's rollout overlap | 1,357 at 07:39:33Z |
| **Cluster total** | **5,766 / 15,812** | **5,590-9,490** | **8,331, `kubectl top node`. Pods alone: 6,806** | **468, the same reading. Pods alone: 304** | **9,115, `docker stats` on the node at 07:39:05Z. Pods alone: 7,599 at 07:39:33Z** | **3,022, `docker stats` on the node at 07:38:48Z. Pods alone: 2,078 at 07:39:33Z** |
| Local services, outside the cluster, Compose `mem_limit`: registry 512, three caches at 128 each, `plane-git` at 64 | no request / 960 | none | 113 | about 1 (0.12% of one CPU in `docker stats`) | During image pulls: Not tested in Pass 1 | |

Quiet figures are [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt). The largest single quiet figure is the API server, at 1,168 MiB, against a research estimate of 350 to 600
MiB. It has read above 1 GiB since before Plane was deployed ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)).

Load figures are each group summed at every 15-second step, then its top ([LOAD-3-20261105T074543Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-series.json), through [LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)). Each group peaked at its own time, so the rows do not add up to the cluster. The tops for the control plane, Argo CD and
Infisical at 07:34 to 07:35 line up with the prod-sim restore, and those for both Plane environments with its rotation at 07:39:33, so they are not k6's doing. The `docker stats` figures are 15-second samples in [results.json](evidence/runs/load-20261105T073241Z/results.json). `kubectl top node` read
7,800 MiB and 1,035 m at 07:44:40Z, during the dev restore ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)), and Prometheus does not keep the node's root cgroup. Local services read 108 MiB together in `docker stats` at the same moment, not during image pulls, which no run samples.

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
| Loki | 640 | 640 | Touched the limit under a 3.5 MB/s stress test, with anon up to 553 MiB and the rest page cache ([monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt)). Largest RSS since that test: 341 MiB. 0 OOM kills. Its one restart was a deliberate `kill -9` |
| Infisical server | 822 | 1,024 | Real use at boot. It read 646 to 687 MiB when quiet, so the request went from 650 to 768 MiB |
| Infisical Postgres | 256 | 256 | Touched the limit, nearly all page cache: largest RSS 64 MiB. 0 OOM kills |
| Grafana | 345 | 384 | |
| Grafana sidecars, each | 106 | 160, up from 96 | They were OOM-killed at 96 MiB on the first boot, about 35 s after starting ([monitoring-grafana-before-1.txt](evidence/runs/monitoring-grafana-before-1.txt)). Now they watch ConfigMaps only |
| `plane-registry`, local services | 459 on a scratch registry | 512, up from 128 | Nearly all page cache from a push, with dirty pages up to 148 MiB: anon and swap stayed at about 32 MiB or less. [registry-memory-1.txt](evidence/runs/registry-memory-1.txt) has the runs at each limit |

### Against the VM

| Layer | Estimate GiB (not measured) | Derivation | Measured, quiet | Highest sampled |
|---|---:|---|---|---|
| Workloads, idle | 5.5-9.3 | The cluster total above | 8.14, from `kubectl top node`. 6.65 of it is pods | |
| VM overhead | 0.4 | Research reading of `/proc/meminfo` less `docker stats`, before this platform existed | 0.15, what is left of VM used after the node, local services and unrelated containers | |
| Unrelated containers on this host | 2.0 | Research sum of `docker stats` across 16 containers, before this platform existed | 1.01: 1,039 MiB across 17 containers, in the final `docker stats` | |
| **Idle on VM** | **7.9-11.7** | Sum of the above | **9.44 median of 30 samples, top 9.61** | |
| Bursts: both migrators, API first boot, repo-server render, a backup or k6 Job | +2 | Judgement, from the Railway first-boot figure of about +0.5 GiB per environment | | During a first install: Not tested in Pass 1, because the clean install does not sample VM memory |
| **Peak on VM** | **9.9-13.7** | Sum of the above | | **10.93 at 2026-11-05T01:50:00Z, in 60-second readings from 00:35Z ([LOAD-3-20261105T074543Z-timeline.json](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). The 5-second samples topped out at 10.49 at 2026-11-04T23:23:42Z. The load window topped out at 10.33 at 07:39:33Z ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)). No clean install has been measured** |

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
was at 9.11 GiB, then at 10.32 GiB again at 23:24:22 while monitoring pods were replaced. Swap reached 0.60 GiB and stayed there in these samples, and Prometheus later read 0.78 GiB in the quiet window and 0.76 GiB in the load window ([LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). The
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

Staged, on 2026-11-04, on this laptop, with fixes landing between steps. A single `make up` from nothing has no recorded result, so these do not
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

The VM cannot see the host's real limit. At 2026-11-05T07:44:42Z `/dev/vda1` in the node reported 408,458,512 KiB available, 389.5 GiB, and at 07:44:45Z the
host reported 18,529,668 KiB, 17.67 GiB ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)). Pods read that same filesystem ([LOAD-3-20261105T074543Z-pvc-df.txt](evidence/runs/LOAD-3-20261105T074543Z-pvc-df.txt)). So
`NodeFilesystem*` alerts should not be trusted to warn before the Mac runs out, and that is why every expensive script calls `guard_disk`. That is a reading of those numbers, because no run has filled the disk.
node-exporter also excludes the `/backups` mount of the Mac, because its `statfs` gave a wrong size and the percentage rules went
critical (`helm/values/kube-prometheus-stack.yaml`).

kind also disables image garbage collection and disk-based eviction. On 2026-11-05 the running kubelet reported
`imageGCHighThresholdPercent` 100 and `evictionHard` of 0% on `imagefs.available`, `nodefs.available` and `nodefs.inodesFree`
([node-kubelet-config-1.txt](evidence/runs/node-kubelet-config-1.txt)). So old images stay until removed, and a full disk means
write errors rather than evictions, which has not been tried.

Do not run `docker system prune -a` to free disk on this host. Research found unrelated containers using a cached MinIO
image that can no longer be pulled anonymously.

### Host and Docker storage

Each estimate below is derived as stated. The "registry layer sizes" figures came from reading image layer sizes from
registries during research. They were not read from a running node, and the image set has changed since.

| Item | Estimate GiB (not measured) | Derivation | Measured |
|---|---:|---|---|
| Images on the kind node, unpacked | 8.56 | Registry layer sizes, 33 images, deduplicated | 11.01: `crictl imagefsinfo` at 2026-11-05T07:44:44Z, on a node with 63 image IDs, 16 of them Wayline builds ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) |
| `kindest/node` in Docker's store | 1.18 | Registry layer sizes, compressed plus unpacked | 1.19: 1.28 GB in Docker's decimal units, at 2026-11-05T07:46:46Z ([LOAD-3-20261105T074543Z-docker-project.txt](evidence/runs/LOAD-3-20261105T074543Z-docker-project.txt)) |
| Node `/var` volume seed | 0.6 | Judgement | Not tested in Pass 1 |
| Pull-through caches: Docker Hub, quay.io, `registry.k8s.io` | up to 2.76 | Compressed total of all 33 images, as an upper bound. The research note priced only an optional Hub cache at 2.28 GiB, but the code always runs all three, so the note's totals leave this out | 2.80: Docker Hub 2.35, quay.io 0.42, `registry.k8s.io` 0.04, at 2026-11-05T07:46:46Z ([LOAD-3-20261105T074543Z-docker-project.txt](evidence/runs/LOAD-3-20261105T074543Z-docker-project.txt)) |
| Local registry, Wayline blobs | 0.5 | Judgement, from before the images existed | 0.69: 705 MiB and 111 blobs on 2026-11-04T23:05Z, holding several Wayline builds ([registry-memory-1.txt](evidence/runs/registry-memory-1.txt)). 1.08 on 2026-11-05T07:46:46Z ([LOAD-3-20261105T074543Z-docker-project.txt](evidence/runs/LOAD-3-20261105T074543Z-docker-project.txt)) |
| Build bases for Wayline images | 1.63 | Registry layer sizes, nginx by judgement | Not tested in Pass 1 |
| PVs, all environments | 1.5-4 | Judgement, see [storage](#persistent-storage) | 1.23 on 2026-11-04T22:19Z, of which 0.86 is Loki, most of it from stress tests ([monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)). 2.02 at 2026-11-05T07:42:58Z, of which 0.87 is Loki and 0.64 Prometheus ([pv-after.txt](evidence/runs/load-20261105T073241Z/pv-after.txt)) |
| Container logs | 0.3-1 | Judgement. Cap about 3.2 GiB, at 10 MiB x 5 files x about 65 containers | 0.05: `/var/log/pods` at 2026-11-05T07:44:43Z ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) |
| Native Wayline build outputs | 1.3 | Judgement from research on branding | 0.22: `.build` at 2026-11-05T07:44:48Z ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) |
| CLI tools, scanner cache, Terraform providers, backups | 1.1-3.2 | Part read from tool sizes, part judgement | 2.96: `.tools` 0.92 and `.local` 2.05, with backups 0.39 of that, at 2026-11-05T07:44:48Z ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) |
| **Total host growth** | **19.5-24.8** | The research note's 16.7-22, plus the caches | 21.18 on the running platform, read at 2026-11-05T07:44Z to 07:57Z. A sum of the node volume 12.82, registry 1.08, caches 2.80, `kindest/node` 1.19, local service images 0.11, `.tools` and `.local` 2.96 and `.build` 0.22 ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)). It is not the growth of a first install |

The high end of that estimate nearly reaches the 25 GiB hard floor in `scripts/prereqs.sh`, so treat 35 GiB as the
working figure until the install is measured. A cache only holds what is actually pulled, so the real number may be lower.

| Reading | Before first install | After first install | After load test | After `make destroy` |
|---|---|---|---|---|
| Host free disk | [[MEASURE: host free before install]] | [[MEASURE: host free after install]] | 17.67 GiB at 2026-11-05T07:44:45Z ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) | [[MEASURE: host free after destroy]] |
| `Docker.raw` allocated | Not tested in Pass 1 | Not tested in Pass 1 | 39.59 GiB at 2026-11-05T07:44:45Z, with a logical size of 460.4 GiB ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) | [[MEASURE: Docker.raw after destroy]] |
| `docker system df` total | Not tested in Pass 1 | Not tested in Pass 1 | 38.6 GB at 2026-11-05T07:44:45Z: images 17.91, volumes 20.69, containers 0.006, build cache 0. This counts unrelated work too ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)) | Not tested in Pass 1 |

The after-load column is the running platform, about 13 hours after its cluster was created, not a clean install. It was read with a dev restore under way. During the load run itself, the whole-number free reading stayed at 17 GiB ([results.json](evidence/runs/load-20261105T073241Z/results.json)). At 17.67 GiB the host sat under the 25 GiB floor in `scripts/prereqs.sh`.

The build-bases cell above has no reading because Docker's store did not hold them: at 2026-11-05T07:57:09Z, of the three, only the nginx base was there, at 94.1 MB, and the Plane backend and space bases were gone ([LOAD-3-20261105T074543Z-docker-images.txt](evidence/runs/LOAD-3-20261105T074543Z-docker-images.txt)). The clean install does not read them either.

### Persistent storage

Declared sizes are settings. kind's local-path provisioner ignores PVC capacity, so a declared size does not cap the
volume. For Prometheus and Loki, retention is the only bound. Plane and Infisical volumes have no bound, except the host.

Measured with `du -sh` under `/var/local-path-provisioner` on the node, at 2026-11-04T22:19Z
([monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)), before most test data. `plane-dev` read 76 MiB for Postgres and 19 MiB for Silo at
23:04Z, after more smoke runs ([plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt)).

| Environment | Volume | Declared | Bound by | Estimate GiB (not measured) | Measured, 22:19Z | Measured at 2026-11-05T07:42:58Z, at the end of the load run (at its start, 07:32:41Z) |
|---|---|---:|---|---:|---|---|
| dev | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 75 MiB | 80 MiB (79) |
| dev | `plane-minio` | 1Gi | nothing | "small" in research | 304 KiB | 83 MiB (83) |
| dev | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 284 KiB | 784 KiB (784) |
| dev | `plane-redis` | 100Mi | nothing | none | 8 KiB | 20 KiB (8) |
| prod-sim | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 73 MiB | 76 MiB (77) |
| prod-sim | `plane-minio` | 1Gi | nothing | "small" in research | 232 KiB | 60 MiB (56) |
| prod-sim | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 272 KiB | 732 KiB (700) |
| prod-sim | `plane-redis` | 100Mi | nothing | none | 8 KiB | 8 KiB (12) |
| infisical | Postgres | 1Gi | nothing | 0.15-0.3 | 157 MiB | 170 MiB (170) |
| infisical | Redis | 256Mi | nothing | none | 7 MiB | 59 MiB (58) |
| monitoring | Prometheus | 2Gi | `retention: 3d`, `retentionSize: 1GiB` | up to 1 | 66 MiB. No block had been compacted yet, so this is the WAL | 653 MiB (643) |
| monitoring | Loki | 2Gi | `retention_period: 72h` | 0.5-2 | 882 MiB. Most of it is chunks from stress tests that pushed about 2.1 GB of synthetic lines ([monitoring-loki-limit-1.txt](evidence/runs/monitoring-loki-limit-1.txt), [-2](evidence/runs/monitoring-loki-limit-2.txt)), which stay until retention removes them | 890 MiB (886) |

The load run's readings are `du -sh` on the node ([pv-after.txt](evidence/runs/load-20261105T073241Z/pv-after.txt), [pv-before.txt](evidence/runs/load-20261105T073241Z/pv-before.txt)), so the prod-sim rows are from before and after its restore and rotation, not from the load, which ran in dev only. A `du -sk` at 07:44:42Z, with the dev restore running, read dev Postgres at 72 MiB ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)).
`df` inside the pods cannot split this, because every volume sits on one VM filesystem. It worked in 8 of 12 mounts and read that same filesystem each time. Loki, Prometheus and both Silo containers have no `df` binary ([LOAD-3-20261105T074543Z-pvc-df.txt](evidence/runs/LOAD-3-20261105T074543Z-pvc-df.txt)).

Backups go to `.local/backups/` on the host, not to a kind volume.

| Backup | Measured size | Measured duration |
|---|---|---|
| dev | Postgres dump 811,511 B and 34 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 30.6 s on 2026-11-04T22:58Z, with 17 objects ([dr-backup-dev-1.txt](evidence/runs/dr-backup-dev-1.txt)) |
| prod-sim | Postgres dump 714,880 B and 23 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 11.0 s on 2026-11-04T22:59Z, with no objects yet ([dr-backup-prod-sim-1.txt](evidence/runs/dr-backup-prod-sim-1.txt)) |
| infisical | Postgres dump 4,407,319 B, 785 tables, at 2026-11-05T00:04Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 21.9 s on 2026-11-04T22:58Z ([dr-backup-3.txt](evidence/runs/dr-backup-3.txt)) |

`make backup ENV=all` took 42.3 s for all three on 2026-11-04T23:13Z ([dr-backup-4.txt](evidence/runs/dr-backup-4.txt)). These hold test data, so they say
little about a real database. The size of each object store copy is not in these files.
