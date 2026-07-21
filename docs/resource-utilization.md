# Resource utilization

CPU, memory, disk and storage for Wayline, a customized Plane Community Edition v1.4.3 deployment on a local kind cluster.

**What is measured.** Measured cells come from one laptop, on 2026-11-04 and 2026-11-05, with Docker Desktop set to 14 GiB and 12 CPUs. This is a local deployment, and nothing here says it is production-ready.

**The main numbers are three windows on 2026-11-05**, on the final images, restored into a new cluster. See [the load window](#the-load-window).

| Question | Answer, from one run of each |
|---|---|
| Idle, per Plane environment | Dev used 1,109 MiB and 64 m of CPU. Prod-sim used 1,039 MiB and 63 m |
| Idle, the whole platform | All pods used 5,703 MiB and 458 m. The VM used 8.65 GiB, which also holds the owner's other containers |
| 5, 10 and 20 virtual users, with think time | 2.39, 4.52 and 8.63 requests a second, p95 268, 647 and 1,005 ms, 0 failed of 2,800 |
| Where it saturates, with no think time | Requests a second stop rising by 5 virtual users: 8.86, 8.37 and 7.82, p95 1,093, 2,095 and 4,935 ms. Postgres sat at its 500 m CPU limit. The API worker topped out at 460 m of its 750 m limit |

**What these numbers do not prove.** They are one laptop, one run each, in a VM shared with the owner's other containers, so they predict no other host, and Pass 2 needs its own. The cluster was about 37 minutes old when idle began, so Prometheus and Loki held little history. The load test calls only the API, and its own writes grow the table it reads, so the ceiling above belongs to this data and this Postgres limit.

**What is still open.** A cold install with no defect has not been timed or measured end to end. The cold install of 2026-11-05 gives the disk and pull times under [Disk](#disk) and [Boot and start times](#boot-and-start-times), and each says what its umask defect added. `Docker.raw` before and after a delete: `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, started at 13:06Z, is in progress, and the numbers are at the top and the bottom of [its output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt). `Docker.raw` before a first install, and VM memory during one: Not measured in Pass 1.

A cell the clean install does not read, and no later run is set to read, says Not tested in Pass 1. A column headed "Highest peak" means a peak under smoke tests, drills and restarts, on the earlier cluster, when both Plane environments ran upstream images. In the three windows, web, admin, space, api, worker and beat ran `localhost:5001/wayline/` images in both environments, and live, Postgres, Valkey, RabbitMQ and Silo ran upstream images ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)).

The tables keep three kinds of number apart:

| Label | What it is | Can it be quoted as usage? |
|---|---|---|
| **Budget** | Requests and limits configured in code. Contract section 10 sets the memory budget for Plane | No. It is a setting |
| **Estimate** | A planning number from research, with its derivation stated | No. It may be wrong |
| **Measured** | Raw output captured in [`docs/evidence/`](evidence/README.md) from a real run | Yes, for this host and that run |

Three kinds of measured memory appear, and they are not the same thing:

- **Idle** is working set from Prometheus in the idle window, with a 30-second scrape read every 15 seconds. Idle columns stop at 08:56:59Z, and their CPU starts at 08:48:35Z, for the reasons under [the load window](#the-load-window).
- **Load** is the same reading in a load window. A burst shorter than a scrape can be missed. Working set leaves out inactive page cache, so it can read lower than `memory.peak`. A CPU peak there is the highest `rate(...[1m])`, so it is a one-minute average, not an instant.
- **Peak** is cgroup `memory.peak`, the highest since that container started, on the earlier cluster. It includes page cache the kernel can
  reclaim, so a peak at a limit does not by itself mean the process needs more. See [what reached a limit](#what-reached-a-limit).

Numbers here describe one laptop running one kind node. They do not predict a server, and Pass 2 needs its own.
Contract section 10 says budgets change only with a measurement, so this page is what later budget changes must cite.

## Minimums used by the scripts

`scripts/prereqs.sh` enforces these. The table explains where each number comes from.

| Check | Hard floor | Recommended | Basis |
|---|---:|---:|---|
| Docker memory, as `docker info` reports it | 13 GiB | 14 GiB setting | The floor is 13 because a 14 GiB setting shows less than 14 inside the VM: 13.63 GiB in `docker stats` and in the node's `/proc/meminfo` (`MemTotal: 14294756 kB`, [infisical-memory-1.txt](evidence/runs/infisical-memory-1.txt)). The highest VM use sampled so far is 10.93 GiB, on the earlier cluster, and 9.05 GiB on the restored one under the saturation pass, [below](#against-the-vm), with no clean install measured |
| Docker CPUs | 4 | none stated | A floor set in the script. No research or measurement stands behind it. This VM has 12 CPUs, by `docker info` and `nproc` ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)), and at most 2.49 of them were busy in the windows below, so nothing here tests 4. The cold install ran at the same 12 CPUs ([make-setup.txt](evidence/runs/clean-install-20261105T105546Z/make-setup.txt)) and reached all 14 Applications Synced and Healthy with no pod unready ([status](evidence/runs/clean-install-20261105T105546Z/make-status.txt)). The platform at 4 CPUs: Not measured in Pass 1 |
| Free host disk | 25 GiB | 35 GiB | An estimate, which one run has met. The script's message says a first install grows Docker storage by about 20 GiB. The cold install took host free from 31 to 13 GiB, 18 GiB by `df` in whole GiB, with extras [listed under Disk](#host-and-docker-storage) ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt), [disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). Host free at the low point during an image build: Not measured in Pass 1 |
| `guard_disk` default (`scripts/lib/common.sh`) | 10 GiB | | A guard before expensive steps. `scripts/up.sh` asks for 25 GiB and `scripts/cluster-up.sh` for 15 GiB when no cluster exists, and the default when one does. Some scripts ask for 1 or 2 GiB. `make down`, `make status` and `make logs` do not check, so they work on a full disk |

The research note also recommends 16 GiB of Docker memory if unrelated containers must keep running, because a 14 GiB
setting leaves no margin at the high estimate. That is an estimate too.

## How to measure

**Idle** means: every Application Synced and Healthy, no test or drill running, unrelated containers stopped or
recorded, and at least 10 minutes since the last sync. **Load** means the window of `make test-load ENV=dev`: 5, 10 and 20
virtual users, 3 minutes each, with `THINK=1`, which sleeps 1 to 3 seconds between requests, unless `THINK=0` is set.

The idle capture reads its window back from Prometheus's history, then runs these commands for what Prometheus does not hold. They write to
`.local/evidence-raw/`, and row LOAD-3 in [validation.md](validation.md#8-basic-load-and-resource-measurements) tracks it.
The one capture so far made the same reads at 2026-11-05T09:25:47Z, about 4 minutes after the last load, with no load running ([LOAD-3-20261105T092547Z-capture-scripts.txt](evidence/runs/LOAD-3-20261105T092547Z-capture-scripts.txt)). `docker stats` stays on the containers named `plane-*`, so the evidence names none of the owner's other containers.

```bash
export KUBECONFIG=.local/kubeconfig
OUT=".local/evidence-raw/idle-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
.tools/bin/kubectl top pods -A --containers > "$OUT/top-containers.txt"
docker stats --no-stream $(docker ps --format '{{.Names}}' | grep '^plane-') > "$OUT/docker-stats.txt"
docker exec plane-platform-control-plane sh -c 'cat /proc/meminfo' > "$OUT/vm-meminfo.txt"
docker exec plane-platform-control-plane sh -c 'du -sh /var/local-path-provisioner/*' > "$OUT/pv-usage.txt"
docker exec plane-platform-control-plane crictl images > "$OUT/node-images.txt"
docker system df > "$OUT/docker-df.txt"
ls -ls ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw > "$OUT/docker-raw.txt"
du -sk ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw >> "$OUT/docker-raw.txt"
df -h . > "$OUT/host-df.txt"
du -sh .local/backups/* > "$OUT/backups.txt"
```

For load, this writes `.local/evidence-raw/load-<run>/results.json`, with k6 numbers per step, Prometheus peaks per pod,
and a sample every 15 seconds. `kubectl top` reads metrics-server, so a single reading is a point sample. Use the
Prometheus peaks for "under load".

```bash
make test-e2e ENV=dev    # creates the account the load test signs in with
make test-load ENV=dev
THINK=0 make test-load ENV=dev    # the saturation pass. It exits 2 when k6 crosses a threshold, and its numbers still stand
```

`tests/load/run.sh` samples per-container use only in `plane-dev`, and it refuses `prod-sim`. So prod-sim gets no "under
load" figure. Its "during dev load" columns show what a neighbouring environment does in the same cluster. They come from
the same Prometheus, with `namespace="plane-prod-sim"`, and the load script does not capture them for you.

## The load window

Three windows on 2026-11-05, read back from Prometheus at 09:26Z ([LOAD-3-20261105T092547Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json)). They describe one laptop running a local deployment, not a production-ready one.

| Window | When, UTC | What ran | Outcome |
|---|---|---|---|
| Idle | 08:47:35 to 09:02:35 | Nothing was started on the cluster ([note](evidence/runs/LOAD-3-idle-window-20261105T084735Z.txt)) | Every Application Synced and Healthy |
| Load, `THINK=1` | 09:02:59 to 09:12:02, the k6 container | `make test-load ENV=dev` at `97d7900`: 5, 10 and 20 virtual users, 3 minutes each, sleeping 1 to 3 seconds between requests | Exit 0, every k6 threshold passed. 2,800 requests, none failed, none answered 429 ([results.json](evidence/runs/load-20261105T090247Z/results.json)) |
| Load, `THINK=0` | 09:12:18 to 09:21:21, the k6 container | `THINK=0 make test-load ENV=dev`: the same steps, with no sleep | k6 crossed its read latency threshold and `make` exited 2. 4,512 requests, 1 failed, none answered 429 ([results.json](evidence/runs/load-20261105T091213Z/results.json), [LOAD-1b-20261105T090247Z-run.txt](evidence/runs/LOAD-1b-20261105T090247Z-run.txt)) |

**What the three windows share.** `Watchdog` and `InfoInhibitor` were the only alerts firing. No Application left Synced and Healthy, no sync ran, nothing restarted, and no OOM event rose. The last sync operation finished at 08:23:33Z, 24 minutes before idle began ([LOAD-3-20261105T092547Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json), [LOAD-3-20261105T092547Z-window-checks.txt](evidence/runs/LOAD-3-20261105T092547Z-window-checks.txt)). The only pods created were the two k6 pods. Every route but dev's API saw only probes, and prod-sim's API log holds nothing else ([LOAD-3-20261105T092547Z-api-access-summary.txt](evidence/runs/LOAD-3-20261105T092547Z-api-access-summary.txt)). So by [How to measure](#how-to-measure) this is idle for its first 9 minutes 24 seconds, with unrelated containers recorded as a count only.

**What was not silent:**

- **A browser tab on dev.** From 08:56:59Z a signed-in browser polled dev's API on workspace `smoke-f10a5851`: the same three GETs every 6 seconds, 30 requests a minute. Its user agent is a desktop app's embedded Chrome 152, and the same one made 86 requests from 08:36:36Z to 08:38:57Z, so this reads as a tab left open. It sent 171 requests in the idle window and 90 in each `THINK=1` step. It slowed to 3 a minute at 09:13Z and stopped after 09:14Z, so `THINK=0` got 27 of them, all in its first step ([LOAD-3-20261105T092547Z-api-access-summary.txt](evidence/runs/LOAD-3-20261105T092547Z-api-access-summary.txt), [LOAD-3-20261105T092547Z-api-log-browser-tab.txt](evidence/runs/LOAD-3-20261105T092547Z-api-log-browser-tab.txt)). k6's counts leave these out, though its requests shared the API with them, and Traefik's and Prometheus's figures include them. With the tab open, dev's API went from 7 m to 29 m of CPU and its Postgres from 9 m to 23 m. No other row moved by more than its own noise. That is why idle columns stop at 08:56:59Z. The whole window is in [LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt), and the sums are below.
- **Four prod-sim pods were new.** Prod-sim's api, beat and Postgres exporter started at 08:46:21Z and its worker at 08:46:31Z, about a minute before idle, with no Argo CD sync operation ([LOAD-3-20261105T092547Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json), [LOAD-3-20261105T092547Z-window-checks.txt](evidence/runs/LOAD-3-20261105T092547Z-window-checks.txt)). A one-minute rate at the start of the window reaches back over those starts, and read 539 m for prod-sim's 11 workloads at 08:47:35Z. That is why idle CPU starts at 08:48:35Z.
- **The owner's other containers.** Docker counted 22 running at 09:25:49Z, 6 of them this project's, and `docker system df` counted 23 active 3 seconds later ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). The others stayed up in the same VM. This page does not read them one by one.
- **The Mac.** Docs agents and a stubbed harness ran on the Mac during idle, outside the cluster, by the window's note. They share the laptop, not the VM.

| Prometheus, per namespace | Idle RAM MiB, avg / top | `THINK=1` RAM MiB, avg / top | `THINK=0` RAM MiB, avg / top | Idle CPU m, avg / top | `THINK=1` CPU m, avg / top | `THINK=0` CPU m, avg / top |
|---|---:|---:|---:|---:|---:|---:|
| `plane-dev`, with exporters and operator, and k6 under load | 1,155 / 1,206 | 1,173 / 1,195 | 1,233 / 1,312 | 69 / 92 | 514 / 924 | 995 / 1,105 |
| `plane-prod-sim`, with exporters and operator | 1,082 / 1,112 | 1,095 / 1,145 | 1,095 / 1,146 | 68 / 92 | 59 / 77 | 55 / 90 |
| `kube-system` | 1,199 / 1,248 | 1,257 / 1,276 | 1,279 / 1,306 | 162 / 244 | 193 / 274 | 194 / 296 |
| `monitoring` | 1,018 / 1,045 | 1,020 / 1,030 | 1,050 / 1,062 | 70 / 91 | 68 / 80 | 63 / 98 |
| `monitoring-agents` | 18 / 20 | 19 / 21 | 19 / 20 | 2.2 / 5.1 | 1.9 / 3.1 | 1.8 / 3.9 |
| `infisical` | 710 / 714 | 733 / 768 | 732 / 735 | 36 / 69 | 31 / 71 | 27 / 54 |
| `argocd` | 461 / 537 | 478 / 562 | 498 / 562 | 47 / 83 | 39 / 115 | 39 / 79 |
| `traefik` | 51 / 52 | 53 / 54 | 54 / 56 | 3.7 / 5.9 | 11 / 18 | 11 / 21 |
| `local-path-storage` | 10 / 10 | 10 / 10 | 10 / 10 | 0.4 / 0.8 | 0.4 / 0.9 | 0.3 / 1.1 |
| **All pods, summed at each step** | **5,703 / 5,777** | **5,837 / 5,966** | **5,971 / 6,103** | **458 / 576** | **918 / 1,322** | **1,387 / 1,656** |
| VM used, GiB, and busy CPU, m | 8.65 / 8.79 | 8.80 / 8.90 | 8.93 / 9.05 | 1,091 / 1,383 | 1,528 / 1,995 | 1,954 / 2,486 |

Every row is summed at each 15-second step of [LOAD-3-20261105T092547Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-series.json), through [LOAD-3-20261105T092547Z-derive-script.py.txt](evidence/runs/LOAD-3-20261105T092547Z-derive-script.py.txt). Idle RAM is 08:47:35Z to 08:56:59Z, and idle CPU is 08:48:35Z to 08:56:59Z. Over the whole 15 minutes, tab included, `plane-dev` read 1,155 / 1,206 MiB and 78 / 108 m, all pods 5,735 / 5,898 MiB and 432 / 576 m, and the VM 8.67 / 8.81 GiB and 1,010 / 1,383 m. Figures per container for every window are in [LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt).

Under `THINK=1`, `plane-dev` used about 7 times its idle CPU, and under `THINK=0` about 14 times, with about 7% more memory. Prod-sim did not move. The VM's busy CPU sat about 630 m above the pods' sum at idle. That gap is kubelet, containerd and the other containers in the VM, and this page does not split it. The VM never had more than 2.49 of its 12 CPUs busy.

The cluster was young. Its node was 75 minutes old at 09:25:53Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)), and Prometheus's history starts at 08:12:45Z. `monitoring` read 1,018 MiB here, against 1,568 MiB on the earlier cluster after about 9 hours, and `kube-system` 1,199 MiB against 1,590 MiB. So these idle figures are not a steady state for a cluster that has run for days, which no run has measured.

### The earlier run, on a busy machine

`make test-load ENV=dev` first ran on the earlier cluster at commit `4aa0640`, with `THINK=1`, from 07:33:48Z to 07:42:51Z. k6's thresholds passed: 2,883 requests, none failed, none answered 429 ([LOAD-1-20261105T073240Z-run.txt](evidence/runs/LOAD-1-20261105T073240Z-run.txt), [results.json](evidence/runs/load-20261105T073241Z/results.json)). The main numbers no longer use it, because the machine was busy. A signed-in watcher sent `GET /api/users/me/` about once a second until 07:40:19Z ([SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt)). Two browser tabs edited a page in dev, and its `live` pod was deleted on purpose at 07:38:02Z ([RT-2b-RT-3-20261105T073208Z.txt](evidence/runs/RT-2b-RT-3-20261105T073208Z.txt)). Prod-sim went through a rotation, a backup and a restore, then a rotation stopped with SIGKILL and resumed ([SEC-3-BKP-3-20261105T073240Z.txt](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt), [SEC-4-20261105T073843Z.txt](evidence/runs/SEC-4-20261105T073843Z.txt)).

| Busy run, `THINK=1` | Requests/s, k6 | p95 ms, k6 | API CPU avg m | Postgres CPU avg m | API throttled | Postgres throttled |
|---|---:|---:|---:|---:|---:|---:|
| 5 VUs | 2.38 | 147 | 92 | 91 | 3% | 7% |
| 10 VUs | 4.85 | 280 | 169 | 184 | 2% | 20% |
| 20 VUs | 8.76 | 1,109 | 308 | 323 | 10% | 50% |

In that window `plane-dev` read 1,184 / 1,229 MiB and 526 / 915 m, all pods 6,979 / 7,599 MiB and 1,270 / 2,078 m, and the VM 9.77 / 10.33 GiB and 2,035 / 3,080 m ([LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json), [LOAD-3-20261105T074543Z-prometheus-steps.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-steps.json), [LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)). The nearest thing to idle on that cluster was a stretch of Prometheus's history, 03:40Z to 04:10Z, on the build before the final one: all pods 6,876 / 7,004 MiB and 309 / 391 m, and the VM 10.04 / 10.64 GiB ([LOAD-3-20261105T074543Z-quiet-window.txt](evidence/runs/LOAD-3-20261105T074543Z-quiet-window.txt)).

**The quiet run was not faster at low load.** Its p95 read 268 ms at 5 VUs against the busy run's 147 ms, 647 ms at 10 VUs against 280 ms, and 1,005 ms at 20 VUs against 1,109 ms. One difference is the data. The busy run started on an empty project, its writes were restored into the new cluster, and the quiet run started on those 293 work items ([LOAD-3-20261105T092547Z-k6-project-rows.txt](evidence/runs/LOAD-3-20261105T092547Z-k6-project-rows.txt)). This page cannot say how much of the gap that explains. Read any single p95 here as a rough figure.

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

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Idle RAM MiB, avg / top | Idle CPU m, avg / top | `THINK=1` RAM MiB, avg / top | `THINK=1` CPU m, avg / top | `THINK=0` RAM MiB, avg / top | `THINK=0` CPU m, avg / top | Highest peak MiB, earlier cluster, smoke and drills |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| web | 16 / 64 | 5-20 | 10 / 100 | 3 / 3 | 0.1 / 0.2 | 3 / 3 | 0.1 / 0.2 | 3 / 3 | 0.2 / 2.0 | 15 |
| admin | 16 / 64 | 5-20 | 10 / 100 | 3 / 3 | 0.2 / 0.4 | 3 / 3 | 0.1 / 0.2 | 3 / 3 | 0.1 / 0.3 | 12 |
| space | 96 / 256 | 100-150 | 20 / 250 | 90 / 91 | 4.4 / 6.9 | 91 / 91 | 2.7 / 6.7 | 91 / 92 | 2.8 / 6.5 | 111 |
| live | 128 / 384 | 120-200 | 20 / 250 | 152 / 153 | 2.9 / 12 | 153 / 154 | 1.8 / 2.9 | 154 / 155 | 1.5 / 4.0 | 309 |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 50 / 750 | 168 / 168 | 6.6 / 8.0 | 164 / 174 | 194 / 356 | 179 / 207 | 381 / 460 | 247 |
| worker (concurrency 2) | 256 / 768 | 300-450 | 50 / 500 | 280 / 295 | 11 / 28 | 281 / 294 | 62 / 108 | 282 / 287 | 85 / 131 | 381 |
| beat | 128 / 256 | 160-250 | 10 / 200 | 148 / 148 | 4.6 / 7.5 | 148 / 148 | 3.6 / 5.7 | 148 / 148 | 3.3 / 4.8 | 159 |
| postgres | 128 / 512 | 50-120 | 50 / 500 | 39 / 39 | 9.2 / 13 | 43 / 58 | 210 / 398 | 79 / 122 | 478 / 500 | 173 |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 10 / 10 | 3.4 / 4.2 | 10 / 10 | 3.4 / 4.2 | 10 / 10 | 3.4 / 6.8 | 19 |
| rabbitmq | 128 / 512 | 140-200 | 50 / 500 | 134 / 190 | 20 / 30 | 132 / 136 | 21 / 31 | 134 / 138 | 24 / 44 | 250 |
| silo | 256 / 512 | 150-300 | 20 / 500 | 82 / 82 | 2.2 / 3.4 | 82 / 82 | 1.9 / 3.3 | 82 / 82 | 1.7 / 2.7 | 149 |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **300 / 3,750** | **1,109 / 1,161** | **64 / 85** | **1,109 / 1,128** | **498 / 905** | **1,165 / 1,239** | **979 / 1,072** | not one moment, see below |

Idle, `THINK=1` and `THINK=0` columns are from [LOAD-3-20261105T092547Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json) and [LOAD-3-20261105T092547Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-series.json), through [LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt). Idle is 08:47:35Z to 08:56:59Z, with CPU from 08:48:35Z. With the tab open, to the end of the window, dev's api read 29 / 38 m and its postgres 23 / 27 m, and the 11 workloads summed to 73 / 104 m across the whole window. The total row sums the 11 workloads at each 15-second step, so it is one real moment, and the rows do not add up to it exactly. Tops of the total fell at 09:10:29Z and 09:11:59Z under `THINK=1`, and at 09:21:18Z and 09:15:03Z under `THINK=0`.

Memory stayed well under every limit in all three windows: the highest share was beat, at 148 of 256 MiB. No container had an OOM event, and none restarted. Postgres's CPU reached its limit under `THINK=0`, see [Load results](#load-results-dev). k6 itself reached 20 MiB and 17 m under `THINK=1`, and 22 MiB and 34 m under `THINK=0`.

A peak is the highest cgroup `memory.peak` across the readings in
[monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt), [plane-dev-memory-1.txt](evidence/runs/plane-dev-memory-1.txt),
[plane-prod-sim-snapshot-after-concurrent-1.txt](evidence/runs/plane-prod-sim-snapshot-after-concurrent-1.txt) and [plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt).
Each container peaked at its own time, so the peaks do not add up to a real moment. Summed working set for all 14 pods in
the namespace reached 1,326 MiB in the 5-second samples ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt)), and 1,762 MiB across
Prometheus's whole history, where a rollout's old and new pods can overlap ([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)).
No Plane container restarted or was OOM-killed in those readings. The nearest to a limit was `live` at 309 of 384 MiB, on a pod up 60 minutes
that had taken three smoke runs and the start of the 330-second WebSocket soak.

The namespace also runs pods outside the contract's table: the Infisical operator, `postgres-exporter` and
`redis-exporter`, counted under the platform below, and the migrator hook (128 / 512 MiB) during a sync. Those three steady
pods add 46 MiB in dev, and 43 MiB in prod-sim, to the idle total.

### prod-sim (`plane-prod-sim`)

The load test refuses this environment, so there is no "under load" column. The during-load columns show what prod-sim used while dev took the `THINK=0` load, with nothing else running in prod-sim.

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Idle RAM MiB, avg / top | Idle CPU m, avg / top | RAM during dev's `THINK=0` MiB, avg / top | CPU during dev's `THINK=0` m, avg / top | Highest peak MiB, earlier cluster, smoke and drills |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| web | 16 / 64 | 5-20 | 10 / 100 | 3 / 3 | 0.1 / 0.2 | 3 / 3 | 0.1 / 0.5 | 16 |
| admin | 16 / 64 | 5-20 | 10 / 100 | 3 / 3 | 0.1 / 0.2 | 3 / 3 | 0.1 / 0.2 | 14 |
| space | 96 / 256 | 100-150 | 20 / 250 | 88 / 91 | 3.6 / 5.0 | 92 / 92 | 2.7 / 5.7 | 107 |
| live | 128 / 384 | 120-200 | 20 / 250 | 152 / 153 | 3.0 / 9.8 | 154 / 155 | 1.8 / 6.1 | 180 |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 100 / 750 | 148 / 148 | 6.8 / 11 | 149 / 149 | 5.1 / 8.3 | 293 |
| worker (concurrency 2) | 256 / 768 | 300-450 | 100 / 500 | 235 / 261 | 11 / 27 | 235 / 235 | 9.4 / 25 | 426 |
| beat | 128 / 256 | 160-250 | 10 / 200 | 147 / 147 | 5.3 / 6.6 | 148 / 148 | 3.5 / 4.9 | 163 |
| postgres | 128 / 512 | 50-120 | 100 / 500 | 37 / 44 | 9.3 / 12 | 37 / 37 | 6.7 / 8.7 | 202 |
| valkey | 16 / 96 | 10-20 | 10 / 100 | 10 / 10 | 3.5 / 4.6 | 10 / 10 | 3.1 / 5.2 | 15 |
| rabbitmq | 128 / 512 | 140-200 | 100 / 500 | 125 / 127 | 18 / 29 | 127 / 180 | 17 / 29 | 222 |
| silo | 256 / 512 | 150-300 | 20 / 500 | 90 / 90 | 1.7 / 3.0 | 90 / 90 | 1.5 / 2.7 | 109 |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **500 / 3,750** | **1,039 / 1,067** | **63 / 86** | **1,048 / 1,100** | **50 / 82** | not one moment |

Same sources as the dev table, on the same stretch of the idle window, so the two compare like for like. Across the whole idle window, with no tab on prod-sim, the 11 workloads read 1,041 / 1,067 MiB and 56 / 86 m. Prod-sim's api and worker read lower than dev's, at 148 and 235 MiB against 168 and 280, and those two prod-sim pods were about a minute old when idle began. In both environments idle memory came in below the estimate's low end: 1,109 and 1,039 MiB against 1,240 MiB.

### Load results (dev)

k6 figures are from [results.json](evidence/runs/load-20261105T090247Z/results.json) for `THINK=1` and [results.json](evidence/runs/load-20261105T091213Z/results.json) for `THINK=0`, and the rest from per-step queries ([LOAD-3-20261105T092547Z-prometheus-steps.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-steps.json), [LOAD-3-20261105T092547Z-traefik-buckets.json](evidence/runs/LOAD-3-20261105T092547Z-traefik-buckets.json)). A step is 3 minutes from about two seconds after the k6 container started, so an edge can be off by a few seconds. These describe this laptop only.

| Load step | Requests/s, k6 (count in 180 s) | p50 ms, k6 | p95 ms, k6 | p99 ms, k6 | Slowest ms, k6 | Failed, k6 | API route requests/s, Traefik | Read p95 bucket ms, Traefik GET | Write p95 bucket ms, Traefik POST |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 VUs, `THINK=1`, 09:03:01Z to 09:06:01Z | 2.39 (430) | 61 | 268 | 580 | 706 | 0 | 3.01 | 300-1,200 | 100-300 |
| 10 VUs, `THINK=1`, 09:06:01Z to 09:09:01Z | 4.52 (813) | 73 | 647 | 1,580 | 4,419 | 0 | 5.13 | 300-1,200 | 300-1,200 |
| 20 VUs, `THINK=1`, 09:09:01Z to 09:12:01Z | 8.63 (1,553) | 168 | 1,005 | 3,341 | 5,552 | 0 | 9.39 | 300-1,200 | 300-1,200 |
| 5 VUs, `THINK=0`, 09:12:20Z to 09:15:20Z | 8.86 (1,595) | 581 | 1,093 | 1,299 | 3,207 | 0 | 9.06 | 300-1,200 | 300-1,200 |
| 10 VUs, `THINK=0`, 09:15:20Z to 09:18:20Z | 8.37 (1,506) | 1,289 | 2,095 | 3,652 | 5,449 | 1 | 8.69 | 1,200-5,000 | 1,200-5,000 |
| 20 VUs, `THINK=0`, 09:18:20Z to 09:21:20Z | 7.82 (1,407) | 2,743 | 4,935 | 5,987 | 7,714 | 0 | 7.82 | above 5,000 | 1,200-5,000 |

k6's summary splits read from write only across the whole run. Under `THINK=1`, p95 read 890 ms and p95 write 832 ms. Under `THINK=0`, p95 read 4,188 ms and p95 write 3,090 ms. So the per-step read and write columns come from Traefik's histogram on the API route, whose default buckets are 0.1, 0.3, 1.2 and 5 seconds. Read each as its bucket. Traefik's columns include the probes, at 0.13 requests a second, and the browser tab, at 0.5 a second under `THINK=1`.

| Load step | API CPU m, avg / top, limit 750 | API throttled | Postgres CPU m, avg / top, limit 500 | Postgres throttled | Worker CPU m, avg | Celery ready, top | Postgres connections, top | Rows Postgres returned per API request |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 VUs, `THINK=1` | 102 / 112 | 1.7% | 114 / 124 | 12.5% | 39 | 0 | 5 | 59,627 |
| 10 VUs, `THINK=1` | 199 / 233 | 7.9% | 203 / 220 | 24.8% | 66 | 0 | 5 | 86,729 |
| 20 VUs, `THINK=1` | 336 / 356 | 8.2% | 378 / 398 | 61.4% | 99 | 0 | 6 | 116,227 |
| 5 VUs, `THINK=0` | 401 / 407 | 9.6% | 497 / 500 | 98.1% | 118 | 0 | 10 | 169,566 |
| 10 VUs, `THINK=0` | 389 / 426 | 11.0% | 493 / 500 | 99.2% | 88 | 172 | 14 | 202,973 |
| 20 VUs, `THINK=0` | 412 / 460 | 16.7% | 500 / 500 | 100.0% | 45 | 747 | 23 | 242,431 |

A CPU average here is the counter's increase over the 180 seconds of the step, and a top is the highest `rate(...[1m])`. Throttled is throttled CFS periods over all CFS periods in the step: the share of the kernel's 100 ms slices in which the container used up its limit and had to wait. Celery is the highest `rabbitmq_detailed_queue_messages_ready` for `celery`, and a queue shorter than a 30-second scrape would not show. The last column is `pg_stat_database_tup_returned` for the Plane database divided by the API route's requests, so it also counts the worker's queries.

**LOAD-2, where the single API worker saturates: it did not reach its own limit, because Postgres reached its limit first.** This is one run on one laptop.

- **Requests stopped rising.** With think time they rose with the virtual users: 2.39, 4.52 and 8.63 a second. With no think time they were already at 8.86 at 5 VUs, then fell to 8.37 and 7.82. Latency took the rest: p50 went from 581 to 1,289 to 2,743 ms. The route's rate times its mean duration comes to 5.1, 10.2 and 20.0 requests in flight, so every virtual user was waiting on the API all the time. The 20 VU step with think time, at 9.39 a second on the route, already reached about that rate, on a smaller table, with Postgres at 378 m.
- **What was at its limit.** Postgres ran at 497, 493 and 500 m against its 500 m limit, throttled in 98% to 100% of CFS periods. Under `THINK=1` at 20 VUs it was already throttled in 61%. The API worker ran at 389 to 412 m and topped out at 460 m, 61% of its 750 m limit. It was throttled in 10% to 17% of periods, so its bursts reached the limit and its average did not. The VM had at most 2.49 of its 12 CPUs busy, so this ceiling comes from a setting in this repository, not from the laptop's CPU.
- **Which threshold crossed.** Read p95 was 4,188 ms across the run, against `p(95)<3000`, so k6 reported the threshold crossed and `make` exited 2 ([LOAD-1b-20261105T090247Z-run.txt](evidence/runs/LOAD-1b-20261105T090247Z-run.txt)). By step, all requests together read 2,095 ms at 10 VUs and 4,935 ms at 20 VUs, and Traefik's GET p95 sits in its 1.2 to 5 second bucket at 10 VUs and above 5 seconds at 20 VUs. So the 3-second read limit falls in the 20 VU step, at 7.82 requests a second. Everything else held: write p95 against 5,000 ms, each step's p95 against 5,000 ms, with 20 VUs only 65 ms inside it, errors at 1 of 4,512 against 5%, and no 429. k6's summary does not say which request failed, and Traefik counted no 5xx on the route.
- **Background work fell behind first.** The Celery queue went from 0 to 172 to 747 ready, while the worker's CPU fell from 118 to 88 to 45 m. So the worker reads as short of Postgres, not of CPU. The queue peaked at 755 messages at 09:21:03Z and was empty by 09:22:03Z, within a minute of k6 stopping at 09:21:21Z ([LOAD-3-20261105T092547Z-after-saturation.json](evidence/runs/LOAD-3-20261105T092547Z-after-saturation.json)). The dev RabbitMQ volume held 11 MiB at the end of the run, and 324 KiB at 09:25:50Z.
- **The data moved under the test.** Its writes grow the table its reads list. The project held 293 work items when `THINK=1` began, 591 when `THINK=0` began and 1,067 at the end, all in one project ([LOAD-3-20261105T092547Z-k6-project-rows.txt](evidence/runs/LOAD-3-20261105T092547Z-k6-project-rows.txt)). Rows returned per API request rose about fourfold with them, and Postgres's CPU per API request rose from 38 to 64 ms. So the fall from 8.86 to 7.82 requests a second may owe as much to the table as to the extra virtual users, and one run cannot split them. A project with more work items may have a lower ceiling.

What this leaves unmeasured: the API worker's own ceiling, because it was never the limit that bound, and what a higher Postgres limit would give, because no run has tried one. k6 calls only `/api/users/me/`, the project list, the work item list and work item creation, so it says nothing about the web, space or `live` paths.

Whole runs, from [results.json](evidence/runs/load-20261105T090247Z/results.json) and [results.json](evidence/runs/load-20261105T091213Z/results.json): the slowest request took 5,552 ms under `THINK=1` and 7,714 ms under `THINK=0`, and Traefik counted no 5xx on the API route in either. The dev database grew by about 600 KB and then about 1.0 MiB, and the VM's `/var` by 86.0 MiB and then 30.8 MiB.

## Whole platform

**Budget** is summed from `helm/values/`, `infisical/manifests/`, `monitoring/manifests/` and the contract, and checked against the
running workloads on 2026-11-05. The research cross-check, section 4, had budget totals of 5,560 / 14,916 MiB. This table sums to
more, because measurements raised several limits. The **idle RSS estimate** is still that note's. It includes the old in-cluster
Git pod, in the Traefik row, and it has not been updated for the changes since.

| Group, with budget req / limit MiB per component | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | Idle RAM MiB, avg / top | Idle CPU m, avg / top | Top RAM MiB, `THINK=1` | Top CPU m, `THINK=1` | Top RAM MiB, `THINK=0` | Top CPU m, `THINK=0` |
|---|---:|---:|---:|---:|---|---|---|---|
| Control plane and node agents, not set by this repository: apiserver, etcd, controller-manager, scheduler, kubelet, containerd, kube-proxy, kindnet, CoreDNS x2, local-path | 290 / 340, from the research note | 750-1,300 | 1,181 / 1,229, pods only: kubelet and containerd are in the next row | 157 / 240 | 1,257 at 09:11:44Z | 269 at 09:04:14Z | 1,287 at 09:20:03Z | 293 at 09:13:48Z |
| containerd shims and pause containers, and kubelet and containerd themselves | none | 300-600, at about 5-10 MiB per pod, for the shims and pause only | 981, `kubectl top node` (6,930) less the pods (5,949), at 09:25:47Z | 290, the same way | | | | |
| Traefik 64/192, metrics-server 48/128 | 112 / 320 | 80-150 | 79 / 80 | 8.7 / 15 | 83 at 09:11:59Z | 22 at 09:11:44Z | 86 at 09:20:18Z | 25 at 09:12:18Z |
| Argo CD: controller 192/1,024, repo-server 96/512, server 48/192, redis 24/64. The applicationset controller has a 32/128 budget and 0 replicas, so it is not counted | 360 / 1,792 | 450-700 | 461 / 537 | 47 / 83 | 562 at 09:07:29Z | 115 at 09:04:29Z | 562 at 09:16:33Z | 79 at 09:14:33Z |
| Monitoring: Prometheus 300/1,024, Alertmanager 48/96, config reloader 16/48 on each, operator 48/128, kube-state-metrics 32/96, node-exporter 24/48, Grafana 128/384, its two sidecars 96/160 each, blackbox 16/48, alert sink 16/48 | 836 / 2,288 | 620-1,040 | 859 / 880 | 55 / 72 | 867 at 09:11:59Z | 59 at 09:10:14Z | 882 at 09:15:33Z | 72 at 09:13:18Z |
| Loki 192/640, Alloy 96/256 | 288 / 896 | 250-500 | 176 / 185 | 17 / 21 | 190 at 09:04:59Z | 23 at 09:08:44Z | 203 at 09:18:03Z | 29 at 09:13:33Z |
| Exporters, per environment: postgres 16/48, redis 12/32 | 56 / 160 | 50 | 47 / 52 | 4.8 / 7.0 | 52 at 09:09:59Z | 5.3 at 09:10:14Z | 58 at 09:20:03Z | 6.4 at 09:12:48Z |
| Infisical: server 768/1,024, its Postgres 64/256, its Redis 16/96, operators 64/128 x2 | 976 / 1,632 | 610-990 | 753 / 756 | 42 / 76 | 811 at 09:04:59Z | 79 at 09:09:14Z | 779 at 09:20:48Z | 58 at 09:13:48Z |
| Plane x2, from the tables above | 2,848 / 8,384 | 2,480-4,160 | 2,147 / 2,194 | 127 / 170 | 2,211 at 09:11:44Z | 951 at 09:11:59Z | 2,286 at 09:21:18Z | 1,146 at 09:13:18Z |
| **Cluster total** | **5,766 / 15,812** | **5,590-9,490** | **5,703 / 5,777, pods only. Node 6,930, `kubectl top node` at 09:25:47Z, with the pods at 5,949** | **458 / 576, pods only. Node 649, the same reading, with the pods at 359** | **5,966 at 09:07:44Z, pods only. Node 6,938, `docker stats` at 09:10:33Z** | **1,322 at 09:10:29Z, pods only. Node 2,947, `docker stats` at 09:11:05Z** | **6,103 at 09:19:33Z, pods only. Node 7,187, `docker stats` at 09:19:38Z** | **1,656 at 09:13:48Z, pods only. Node 3,962, `docker stats` at 09:13:39Z** |
| Local services, outside the cluster, Compose `mem_limit`: registry 512, three caches at 128 each, `plane-git` at 64 | no request / 960 | none | 117, `docker stats` at 09:25:47Z | 0, the same reading | During image pulls: Not tested in Pass 1 | | | |

Idle is 08:47:35Z to 08:56:59Z, with CPU from 08:48:35Z. Each group is summed at every 15-second step ([LOAD-3-20261105T092547Z-prometheus-series.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-series.json), through [LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)), so a group's top is a real moment, and each group peaked at its own time, so the rows do not add up to the cluster. k6 is in the cluster's pods and in no other row. The `docker stats` figures under load are 15-second samples in [results.json](evidence/runs/load-20261105T090247Z/results.json) and [results.json](evidence/runs/load-20261105T091213Z/results.json). Prometheus does not keep the node's root cgroup, so the node has no idle average, only the one reading ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)), about 4 minutes after the last load, with no load running. The local services' reading comes from the same moment, not during image pulls, which no run samples.

The largest single idle figure is the API server, at 813 MiB on average, against a research estimate of 350 to 600 MiB. It read above 1 GiB on the earlier cluster, from before Plane was deployed ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)). Next come the Infisical server at 670 MiB and Prometheus at 350 MiB.

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

That table is memory, on the earlier cluster. In the three windows on this page no memory limit came close, and the one limit reached was a CPU limit: Postgres's 500 m in dev, under `THINK=0`. See [Load results](#load-results-dev).

### Against the VM

| Layer | Estimate GiB (not measured) | Derivation | Measured, idle | Highest sampled |
|---|---:|---|---|---|
| Workloads, idle | 5.5-9.3 | The cluster total above | 6.77, from `kubectl top node` at 2026-11-05T09:25:47Z, with no load running. 5.81 of it was pods then, and the pods averaged 5.57 in the idle window | |
| VM overhead | 0.4 | Research reading of `/proc/meminfo` less `docker stats`, before this platform existed | Not split from the next row | |
| Unrelated containers on this host | 2.0 | Research sum of `docker stats` across 16 containers, before this platform existed | Not read one by one. With VM overhead, 1.98 at 09:25:50Z: VM used 8.94, less the node 6.85 and local services 0.11 ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt), [LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)). On the earlier cluster they read 1.01 and 0.15 apart, at 2026-11-05T00:03Z | |
| **Idle on VM** | **7.9-11.7** | Sum of the above | **8.65 average, top 8.79**, from Prometheus, 08:47:35Z to 08:56:59Z. Whole window 8.67 / 8.81 | |
| Bursts: both migrators, API first boot, repo-server render, a backup or k6 Job | +2 | Judgement, from the Railway first-boot figure of about +0.5 GiB per environment | | During a first install: Not tested in Pass 1, because the clean install does not sample VM memory |
| **Peak on VM** | **9.9-13.7** | Sum of the above | | **9.05 at 09:20:18Z under `THINK=0`, and 8.90 at 09:10:44Z under `THINK=1`. On the earlier cluster, with other work on it: 10.93 at 2026-11-05T01:50:00Z, in 60-second readings from 00:35Z ([LOAD-3-20261105T074543Z-timeline.json](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)), 10.49 in the 5-second samples at 2026-11-04T23:23:42Z, and 10.33 in the busy load run at 07:39:33Z ([LOAD-3-20261105T074543Z-derived.txt](evidence/runs/LOAD-3-20261105T074543Z-derived.txt)). No clean install has been measured** |

VM used is `MemTotal` less `MemAvailable`, and it includes the unrelated containers and any
other work on the cluster at the time. On the restored cluster it moved little: 8.65 GiB idle, 8.80 under `THINK=1` and 8.93 under `THINK=0`. On the earlier cluster, sampled every 5 seconds from the node, tests barely moved it either ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt), 2026-11-04T23:17Z to 2026-11-05T00:04Z):

| Phase | Samples | VM used, median GiB | VM used, top GiB | Plane working set, top of the sum, MiB (dev + prod-sim) |
|---|---:|---:|---:|---|
| No test started for this capture | 30 | 9.44 | 9.61 | 1,258 + 1,239 = 2,497 |
| Both smoke tests together, the soak and two NetworkPolicy matrices | 101 | 9.48 | 9.87 | 1,282 + 1,385 = 2,667 |
| Drills and broker restarts in prod-sim | 282 | 9.59 | 9.90 | 1,251 + 1,356 = 2,607 |
| Separation runs, at low load | 85 | 9.76 | 10.49 | 1,326 + 1,309 = 2,635 |
| All sampled time | 562 | 9.56 | 10.49 | 2,667 |

The 10.49 GiB reading came 5 seconds after a change replaced the Argo CD pods, so old and new copies overlapped. By 23:24:02 the VM
was at 9.11 GiB, then at 10.32 GiB again at 23:24:22 while monitoring pods were replaced. Swap reached 0.60 GiB and stayed there in these samples, and Prometheus later read 0.78 GiB in the quiet stretch and 0.76 GiB in the busy load run ([LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). On the restored cluster it held at 0.68 GiB in all three windows ([LOAD-3-20261105T092547Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json)). The
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

**From nothing.** One `make up` with the registry and caches kept took 955 s, on 2026-11-05 at `7d5ff62` ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt)). That is the good figure. **The cold install, at `18af97a`, is not a good figure**: its first `make up` built and stopped in 1,008 s, the promotions took 10 s and 3 s, and its second `make up` took 5,238 s, 6,277 s from the start of the first ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt)). That 5,238 s includes a real defect: images built under `umask 077`, whose non-root users could not read their own files, so `plane-dev` could not start until a rebuild of 598 s and a new promotion ([install](install.md#first-run), [rebuild](evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt)). A full cold install with no defect has not been timed end to end.

| Step of `make up`, seconds | Registry and caches kept, 955 s in all ([log](evidence/runs/clean-install-20261105T075041Z/make-up.txt)) | Cold, 5,238 s in all ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)) |
|---:|---:|---:|
| `cluster` | 173 | 95, with the first `make up` having created the cluster in 33 s |
| `publish` | 3 | 1 |
| `terraform` | 54 | 179 |
| `secret-zero` | 2 | 3 |
| `traefik` | 151 | 46 |
| `infisical` | 245 | 1,974 |
| All 14 Applications | 324 | 2,935, which holds the defect |

Cold pulls, from [app-timeline.txt](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt), which gives each Application's first recorded sync. A wave waits for the wave before it to read Healthy, so the gap between two starts is mostly that wait. Argo CD records only a sync that succeeded, so `plane-dev`'s row is its good sync, after the rebuild.

| Application, wave | First sync started | Gap to the next wave's start |
|---|---:|---:|
| `metrics-server`, -8 | 11:18:33Z | 17 m 28 s, the 17.5 minutes to `kube-prometheus-stack`. It read Degraded for about 6 minutes of that and recovered with no help, and which pull it waited on was not read ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)) |
| `kube-prometheus-stack`, -7 | 11:36:01Z | 6 m 2 s |
| `alloy` and `loki`, -6 | 11:42:03Z | 2 m 17 s |
| `monitoring-extras`, -5 | 11:44:20Z | 41 s |
| `infisical`, -4 | 11:45:01Z, finished 11:50:58Z | 5 m 58 s |
| Both Infisical operators, -3 | 11:50:59Z and 11:51:00Z | Not a measure of cold pulls: the defect starts here |
| `plane-dev`, -1 | 12:31:17Z, finished 12:32:35Z | 4 m 35 s from its finish to prod-sim's start, for root's next attempt |
| `plane-prod-sim`, 0 | 12:37:10Z, finished 12:40:23Z | |

The defect's cost is bounded by those times. The Infisical step ended at about 11:51:28Z, 2,298 s into that `make up`, and `plane-prod-sim` started at 12:37:10Z. So it cost at most 2,742 s, about 46 minutes, less the time a healthy `plane-dev` first boot takes on these pulls, which this run does not show.

**In stages.** The rest of this section is staged, on 2026-11-04, on this laptop, with fixes landing between steps, so these do not predict a run from nothing.

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

The VM cannot see the host's real limit. At 2026-11-05T09:25:50Z `/dev/vda1` in the node reported 411,183,296 KiB available, 392.1 GiB, and at 09:25:52Z the
host reported 18,526,996 KiB, 17.67 GiB ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). Pods read that same filesystem ([LOAD-3-20261105T092547Z-pvc-df.txt](evidence/runs/LOAD-3-20261105T092547Z-pvc-df.txt)). So
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
| Images on the kind node, unpacked | 8.56 | Registry layer sizes, 33 images, deduplicated | 10.07: `crictl imagefsinfo` at 2026-11-05T09:25:51Z, on a node with 48 image IDs, 4 of them Wayline builds ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). The earlier cluster read 11.01 with 63 image IDs, 16 of them Wayline builds |
| `kindest/node` in Docker's store | 1.18 | Registry layer sizes, compressed plus unpacked | 1.19: 1.28 GB in Docker's decimal units, at 09:25:54Z ([LOAD-3-20261105T092547Z-docker-project.txt](evidence/runs/LOAD-3-20261105T092547Z-docker-project.txt)) |
| Node `/var` volume seed | 0.6 | Judgement | Not tested in Pass 1 |
| Pull-through caches: Docker Hub, quay.io, `registry.k8s.io` | up to 2.76 | Compressed total of all 33 images, as an upper bound. The research note priced only an optional Hub cache at 2.28 GiB, but the code always runs all three, so the note's totals leave this out | 2.80: Docker Hub 2.35, quay.io 0.42, `registry.k8s.io` 0.04, at 09:25:54Z ([LOAD-3-20261105T092547Z-docker-project.txt](evidence/runs/LOAD-3-20261105T092547Z-docker-project.txt)). They kept their size across the new cluster, so that says nothing about what a first install pulls. The cold install, which started them empty, does: 2.48 GB in Docker's decimal units, Docker Hub 1.992, quay.io 0.448 and `registry.k8s.io` 0.038, at 12:40:48Z ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) |
| Local registry, Wayline blobs | 0.5 | Judgement, from before the images existed | 1.08 at 09:25:54Z, holding several Wayline builds ([LOAD-3-20261105T092547Z-docker-project.txt](evidence/runs/LOAD-3-20261105T092547Z-docker-project.txt)). 552.7 MB after the cold install, holding its broken and fixed builds ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) |
| Build bases for Wayline images | 1.63 | Registry layer sizes, nginx by judgement | Not tested in Pass 1 |
| PVs, all environments | 1.5-4 | Judgement, see [storage](#persistent-storage) | 0.59 at 09:25:50Z, on a cluster 75 minutes old ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). The earlier cluster read 2.02 after about 13 hours, of which 0.87 was Loki and 0.64 Prometheus ([pv-after.txt](evidence/runs/load-20261105T073241Z/pv-after.txt)) |
| Container logs | 0.3-1 | Judgement. Cap about 3.2 GiB, at 10 MiB x 5 files x about 65 containers | 0.02: `/var/log/pods` at 09:25:50Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) |
| Native Wayline build outputs | 1.3 | Judgement from research on branding | 0.22: `.build` at 09:25:53Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) |
| CLI tools, scanner cache, Terraform providers, backups | 1.1-3.2 | Part read from tool sizes, part judgement | 3.06: `.tools` 0.92 and `.local` 2.15, with backups 0.48 of that, at 09:25:53Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) |
| **Total host growth** | **19.5-24.8** | The research note's 16.7-22, plus the caches | 18.81 on the running platform, read at 09:25:50Z to 09:25:54Z. A sum of the node volume 10.35, registry 1.08, caches 2.80, `kindest/node` 1.19, local service images 0.11, `.tools` and `.local` 3.06 and `.build` 0.22 ([LOAD-3-20261105T092547Z-derived.txt](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)). The earlier cluster's sum was 21.18. Neither is the growth of a first install. The cold install's is 18 by `df` in whole GiB, below |

The high end of that estimate nearly reaches the 25 GiB hard floor in `scripts/prereqs.sh`. The cold install measured less, with the extras listed below the next table, and one run does not move the 35 GiB recommendation.

| Reading | Before first install, the cold install | After first install, the cold install | After load test | After a delete |
|---|---|---|---|---|
| Host free disk | 31 GiB at 10:55:46Z ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt)), and 31.7 GiB by the drill's reading just before it ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)) | 13 GiB at 12:40:48Z ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) | 17.67 GiB at 2026-11-05T09:25:52Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) | 31.7 GiB right after a delete with `PURGE=yes`, with 15.6 GiB back where the drill's check counted on about 27.0 GiB free ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)). 26 GiB at 12:45:17Z, after the install's own delete, which kept the registry and caches, with its clone removed and the registry snapshot back ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt)). 17.7 to 31.6 GiB on the earlier drill's delete, 14.1 GiB back ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log)) |
| `Docker.raw` allocated | Not measured in Pass 1 | 40,060,992 KiB, 38.21 GiB, by `du -sk`, at 12:40:48Z ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) | 37.04 GiB at 09:25:52Z, by `du -sk`, with a logical size of 460.4 GiB ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) | In progress: `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, started at 13:06Z, deletes with kind alone, and reads it at the top and bottom of [its output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), so the numbers are in that file |
| `docker system df` total | Not tested in Pass 1 | 37.30 GB at 12:40:48Z: images 17.91, volumes 16.72, containers 0.006, build cache 2.665. This counts unrelated work too ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) | 35.99 GB at 09:25:52Z: images 17.91, volumes 18.05, containers 0.006, build cache 0.026. This counts unrelated work too ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)) | Not tested in Pass 1 |

**What the cold install's 18 GiB holds.** Those are whole-GiB readings from `df`, on a Mac with other work on it. Host free read 31 GiB at the start, 29 GiB at 11:13:10Z, once the drill had removed the first build's source tree, package store and Docker's build cache ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt), [prune](evidence/runs/clean-install-20261105T105546Z/builder-prune.txt)), and 13 GiB at the end. The 18 GiB holds the clone, a copy of `.tools`, the broken and the fixed images in the registry and on the node, and the second build's source tree, package store and build cache, because the defect made it build twice. A new machine with no defect would not hold the broken images, and would keep one build's files unless it removed them. That figure: Not measured in Pass 1. It does sit under the estimate's low end of 19.5 GiB, and the host held 13 GiB free with the platform up, under the 25 GiB floor, as it does in the after-load column.

The after-load column is the running platform, 75 minutes after its cluster was created and after both load runs, not a clean install. During the two runs the whole-number free reading went from 19 to 18 GiB and from 18 to 17 GiB ([results.json](evidence/runs/load-20261105T090247Z/results.json), [results.json](evidence/runs/load-20261105T091213Z/results.json)), with other work on the Mac in the same minutes. At 17.67 GiB the host sat under the 25 GiB floor in `scripts/prereqs.sh`. On the earlier cluster, at 07:44:45Z, the same three read 17.67 GiB free, `Docker.raw` 39.59 GiB and `docker system df` 38.6 GB ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)).

The build-bases cell above has no reading because Docker's store did not hold them: at 2026-11-05T07:57:09Z, of the three, only the nginx base was there, at 94.1 MB, and the Plane backend and space bases were gone ([LOAD-3-20261105T074543Z-docker-images.txt](evidence/runs/LOAD-3-20261105T074543Z-docker-images.txt)). The clean install does not read them either.

### Persistent storage

Declared sizes are settings. kind's local-path provisioner ignores PVC capacity, so a declared size does not cap the
volume. For Prometheus and Loki, retention is the only bound. Plane and Infisical volumes have no bound, except the host.

Measured with `du` on the node. The first three columns are the load script's `du -sh` ([before](evidence/runs/load-20261105T090247Z/pv-before.txt) and [after `THINK=1`](evidence/runs/load-20261105T090247Z/pv-after.txt), [after `THINK=0`](evidence/runs/load-20261105T091213Z/pv-after.txt)), so 09:02:47Z is 12 seconds after the idle window ended. The next is `du -sk` at 09:25:50Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). The last is the earlier cluster after about 13 hours.

| Environment | Volume | Declared | Bound by | Estimate GiB (not measured) | Idle, 09:02:47Z | After `THINK=1`, 09:12Z | After `THINK=0`, 09:21Z | 09:25:50Z | Earlier cluster, 2026-11-05T07:42:58Z |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| dev | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 78 MiB | 79 MiB | 80 MiB | 79 MiB | 80 MiB |
| dev | `plane-minio` | 1Gi | nothing | "small" in research | 96 MiB | 96 MiB | 96 MiB | 96 MiB | 83 MiB |
| dev | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 404 KiB | 4.5 MiB | 11 MiB | 324 KiB | 784 KiB |
| dev | `plane-redis` | 100Mi | nothing | none | 12 KiB | 32 KiB | 44 KiB | 48 KiB | 20 KiB |
| prod-sim | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | 76 MiB | 76 MiB | 76 MiB | 76 MiB | 76 MiB |
| prod-sim | `plane-minio` | 1Gi | nothing | "small" in research | 69 MiB | 69 MiB | 69 MiB | 69 MiB | 60 MiB |
| prod-sim | `plane-rabbitmq` | 100Mi | nothing | "small" in research | 328 KiB | 332 KiB | 332 KiB | 328 KiB | 732 KiB |
| prod-sim | `plane-redis` | 100Mi | nothing | none | 8 KiB | 8 KiB | 8 KiB | 8 KiB | 8 KiB |
| infisical | Postgres | 1Gi | nothing | 0.15-0.3 | 202 MiB | 202 MiB | 202 MiB | 201 MiB | 170 MiB |
| infisical | Redis | 256Mi | nothing | none | 4.6 MiB | 5.4 MiB | 6.3 MiB | 6.6 MiB | 59 MiB |
| monitoring | Prometheus | 2Gi | `retention: 3d`, `retentionSize: 1GiB` | up to 1 | 41 MiB | 48 MiB | 59 MiB | 62 MiB | 653 MiB |
| monitoring | Loki | 2Gi | `retention_period: 72h` | 0.5-2 | 9.0 MiB | 8.4 MiB | 14 MiB | 9.2 MiB | 890 MiB |

Prometheus and Loki are small here because the cluster was young, so the earlier column says more about how far they grow. On that cluster, at 2026-11-04T22:19Z, Prometheus read 66 MiB, with no block compacted yet, so that was the WAL, and Loki read 882 MiB. Most of Loki's figure is chunks from stress tests that pushed about 2.1 GB of synthetic lines ([monitoring-loki-limit-1.txt](evidence/runs/monitoring-loki-limit-1.txt), [-2](evidence/runs/monitoring-loki-limit-2.txt)), which stay until retention removes them. Those readings are in [monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt).

`df` inside the pods cannot split this, because every volume sits on one VM filesystem. It worked in 8 of 12 mounts and read that same filesystem each time. Loki, Prometheus and both Silo containers have no `df` binary, and no `du` either. Where `du -sk` ran in the pod, it agreed with the node's reading to within 40 KiB ([LOAD-3-20261105T092547Z-pvc-df.txt](evidence/runs/LOAD-3-20261105T092547Z-pvc-df.txt)).

Backups go to `.local/backups/` on the host, not to a kind volume.

| Backup | Measured size | Measured duration |
|---|---|---|
| dev | Postgres dump 811,511 B and 34 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 30.6 s on 2026-11-04T22:58Z, with 17 objects ([dr-backup-dev-1.txt](evidence/runs/dr-backup-dev-1.txt)) |
| prod-sim | Postgres dump 714,880 B and 23 objects, at 2026-11-05T00:05Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 11.0 s on 2026-11-04T22:59Z, with no objects yet ([dr-backup-prod-sim-1.txt](evidence/runs/dr-backup-prod-sim-1.txt)) |
| infisical | Postgres dump 4,407,319 B, 785 tables, at 2026-11-05T00:04Z ([dr-backup-retention-1.txt](evidence/runs/dr-backup-retention-1.txt)) | 21.9 s on 2026-11-04T22:58Z ([dr-backup-3.txt](evidence/runs/dr-backup-3.txt)) |

`make backup ENV=all` took 42.3 s for all three on 2026-11-04T23:13Z ([dr-backup-4.txt](evidence/runs/dr-backup-4.txt)). These hold test data, so they say
little about a real database. The size of each object store copy is not in these files.
