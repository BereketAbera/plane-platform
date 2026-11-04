# Resource utilization

CPU, memory, disk and storage for Wayline, a customized Plane Community Edition v1.4.3 deployment on a local kind cluster.

**No measurement exists yet.** Plane has not been deployed, so every measured cell below is a `[[MEASURE]]` marker. The
tables keep three kinds of number apart:

| Label | What it is | Can it be quoted as usage? |
|---|---|---|
| **Budget** | Requests and limits configured in code. Contract section 10 sets the memory budget for Plane | No. It is a setting |
| **Estimate** | A planning number from research, with its derivation stated | No. It may be wrong |
| **Measured** | Raw output captured in [`docs/evidence/`](evidence/README.md) from a real run | Yes, for this host and that run |

Numbers here describe one laptop running one kind node. They do not predict a server, and Pass 2 needs its own.
Contract section 10 says budgets change only with a measurement, so this page is what later budget changes must cite.

## Minimums used by the scripts

`scripts/prereqs.sh` enforces these. The table explains where each number comes from.

| Check | Hard floor | Recommended | Basis |
|---|---:|---:|---|
| Docker memory, as `docker info` reports it | 13 GiB | 14 GiB setting | Estimate. Peak on the VM is estimated at 9.9 to 13.7 GiB with unrelated containers running (below). The floor is 13 because a 14 GiB setting shows less than 14 inside the VM. [[VERIFY: docker info MemTotal for a 14 GiB Docker Desktop setting]] |
| Docker CPUs | 4 | none stated | A floor set in the script. No research or measurement stands behind it. [[VERIFY: platform boots and stays Ready at the CPU count used in the first install]] |
| Free host disk | 25 GiB | 35 GiB | Estimate. The script's message says a first install grows Docker storage by about 20 GiB. See [disk](#disk). [[MEASURE: host disk used by a first install]] |
| `guard_disk` default (`scripts/lib/common.sh`) | 10 GiB | | A guard before expensive steps. `cluster-up.sh` asks for 15 GiB, and some scripts ask for 1 or 2 GiB |

The research note also recommends 16 GiB of Docker memory if unrelated containers must keep running, because a 14 GiB
setting leaves no margin at the high estimate. That is an estimate too.

## How to measure

**Idle** means: every Application Synced and Healthy, no test or drill running, unrelated containers stopped or
recorded, and at least 10 minutes since the last sync. **Load** means the window of `make test-load ENV=dev`: 5, 10 and 20
virtual users, 3 minutes each, with 1 second of think time unless `THINK=0` is set.

Idle capture has no script. These commands write it to `.local/evidence-raw/`, and row LOAD-3 in
[validation.md](validation.md#8-basic-load-and-resource-measurements) tracks it.

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

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Measured idle RAM | Measured idle CPU | Measured load peak RAM | Measured load avg CPU | Measured load peak CPU |
|---|---:|---:|---:|---|---|---|---|---|
| web | 16 / 64 | 5-20 | 10 / 100 | [[MEASURE: dev web idle RAM]] | [[MEASURE: dev web idle CPU]] | [[MEASURE: dev web load peak RAM]] | [[MEASURE: dev web load avg CPU]] | [[MEASURE: dev web load peak CPU]] |
| admin | 16 / 64 | 5-20 | 10 / 100 | [[MEASURE: dev admin idle RAM]] | [[MEASURE: dev admin idle CPU]] | [[MEASURE: dev admin load peak RAM]] | [[MEASURE: dev admin load avg CPU]] | [[MEASURE: dev admin load peak CPU]] |
| space | 96 / 256 | 100-150 | 20 / 250 | [[MEASURE: dev space idle RAM]] | [[MEASURE: dev space idle CPU]] | [[MEASURE: dev space load peak RAM]] | [[MEASURE: dev space load avg CPU]] | [[MEASURE: dev space load peak CPU]] |
| live | 128 / 384 | 120-200 | 20 / 250 | [[MEASURE: dev live idle RAM]] | [[MEASURE: dev live idle CPU]] | [[MEASURE: dev live load peak RAM]] | [[MEASURE: dev live load avg CPU]] | [[MEASURE: dev live load peak CPU]] |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 50 / 750 | [[MEASURE: dev api idle RAM]] | [[MEASURE: dev api idle CPU]] | [[MEASURE: dev api load peak RAM]] | [[MEASURE: dev api load avg CPU]] | [[MEASURE: dev api load peak CPU]] |
| worker (concurrency 2) | 256 / 768 | 300-450 | 50 / 500 | [[MEASURE: dev worker idle RAM]] | [[MEASURE: dev worker idle CPU]] | [[MEASURE: dev worker load peak RAM]] | [[MEASURE: dev worker load avg CPU]] | [[MEASURE: dev worker load peak CPU]] |
| beat | 128 / 256 | 160-250 | 10 / 200 | [[MEASURE: dev beat idle RAM]] | [[MEASURE: dev beat idle CPU]] | [[MEASURE: dev beat load peak RAM]] | [[MEASURE: dev beat load avg CPU]] | [[MEASURE: dev beat load peak CPU]] |
| postgres | 128 / 512 | 50-120 | 50 / 500 | [[MEASURE: dev postgres idle RAM]] | [[MEASURE: dev postgres idle CPU]] | [[MEASURE: dev postgres load peak RAM]] | [[MEASURE: dev postgres load avg CPU]] | [[MEASURE: dev postgres load peak CPU]] |
| valkey | 16 / 96 | 10-20 | 10 / 100 | [[MEASURE: dev valkey idle RAM]] | [[MEASURE: dev valkey idle CPU]] | [[MEASURE: dev valkey load peak RAM]] | [[MEASURE: dev valkey load avg CPU]] | [[MEASURE: dev valkey load peak CPU]] |
| rabbitmq | 128 / 512 | 140-200 | 50 / 500 | [[MEASURE: dev rabbitmq idle RAM]] | [[MEASURE: dev rabbitmq idle CPU]] | [[MEASURE: dev rabbitmq load peak RAM]] | [[MEASURE: dev rabbitmq load avg CPU]] | [[MEASURE: dev rabbitmq load peak CPU]] |
| silo | 256 / 512 | 150-300 | 20 / 500 | [[MEASURE: dev silo idle RAM]] | [[MEASURE: dev silo idle CPU]] | [[MEASURE: dev silo load peak RAM]] | [[MEASURE: dev silo load avg CPU]] | [[MEASURE: dev silo load peak CPU]] |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **300 / 3,250** | [[MEASURE: dev total idle RAM]] | [[MEASURE: dev total idle CPU]] | [[MEASURE: dev total load peak RAM]] | [[MEASURE: dev total load avg CPU]] | [[MEASURE: dev total load peak CPU]] |

The namespace also runs pods outside the contract's table: the Infisical operator, `postgres-exporter` and
`redis-exporter`, counted under the platform below, and the migrator hook (128 / 512 MiB) during a sync.

### prod-sim (`plane-prod-sim`)

The load test refuses this environment, so there is no "under load" column.

| Workload | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | CPU req / limit m (setting) | Measured idle RAM | Measured idle CPU | Measured RAM during dev load | Measured CPU during dev load |
|---|---:|---:|---:|---|---|---|---|
| web | 16 / 64 | 5-20 | 10 / 100 | [[MEASURE: prod-sim web idle RAM]] | [[MEASURE: prod-sim web idle CPU]] | [[MEASURE: prod-sim web RAM during dev load]] | [[MEASURE: prod-sim web CPU during dev load]] |
| admin | 16 / 64 | 5-20 | 10 / 100 | [[MEASURE: prod-sim admin idle RAM]] | [[MEASURE: prod-sim admin idle CPU]] | [[MEASURE: prod-sim admin RAM during dev load]] | [[MEASURE: prod-sim admin CPU during dev load]] |
| space | 96 / 256 | 100-150 | 20 / 250 | [[MEASURE: prod-sim space idle RAM]] | [[MEASURE: prod-sim space idle CPU]] | [[MEASURE: prod-sim space RAM during dev load]] | [[MEASURE: prod-sim space CPU during dev load]] |
| live | 128 / 384 | 120-200 | 20 / 250 | [[MEASURE: prod-sim live idle RAM]] | [[MEASURE: prod-sim live idle CPU]] | [[MEASURE: prod-sim live RAM during dev load]] | [[MEASURE: prod-sim live CPU during dev load]] |
| api (1 gunicorn worker) | 256 / 768 | 200-350 | 100 / 750 | [[MEASURE: prod-sim api idle RAM]] | [[MEASURE: prod-sim api idle CPU]] | [[MEASURE: prod-sim api RAM during dev load]] | [[MEASURE: prod-sim api CPU during dev load]] |
| worker (concurrency 2) | 256 / 768 | 300-450 | 100 / 500 | [[MEASURE: prod-sim worker idle RAM]] | [[MEASURE: prod-sim worker idle CPU]] | [[MEASURE: prod-sim worker RAM during dev load]] | [[MEASURE: prod-sim worker CPU during dev load]] |
| beat | 128 / 256 | 160-250 | 10 / 200 | [[MEASURE: prod-sim beat idle RAM]] | [[MEASURE: prod-sim beat idle CPU]] | [[MEASURE: prod-sim beat RAM during dev load]] | [[MEASURE: prod-sim beat CPU during dev load]] |
| postgres | 128 / 512 | 50-120 | 100 / 500 | [[MEASURE: prod-sim postgres idle RAM]] | [[MEASURE: prod-sim postgres idle CPU]] | [[MEASURE: prod-sim postgres RAM during dev load]] | [[MEASURE: prod-sim postgres CPU during dev load]] |
| valkey | 16 / 96 | 10-20 | 10 / 100 | [[MEASURE: prod-sim valkey idle RAM]] | [[MEASURE: prod-sim valkey idle CPU]] | [[MEASURE: prod-sim valkey RAM during dev load]] | [[MEASURE: prod-sim valkey CPU during dev load]] |
| rabbitmq | 128 / 512 | 140-200 | 100 / 500 | [[MEASURE: prod-sim rabbitmq idle RAM]] | [[MEASURE: prod-sim rabbitmq idle CPU]] | [[MEASURE: prod-sim rabbitmq RAM during dev load]] | [[MEASURE: prod-sim rabbitmq CPU during dev load]] |
| silo | 256 / 512 | 150-300 | 20 / 500 | [[MEASURE: prod-sim silo idle RAM]] | [[MEASURE: prod-sim silo idle CPU]] | [[MEASURE: prod-sim silo RAM during dev load]] | [[MEASURE: prod-sim silo CPU during dev load]] |
| **Total, 11 workloads** | **1,424 / 4,192** | **1,240-2,080** | **500 / 3,250** | [[MEASURE: prod-sim total idle RAM]] | [[MEASURE: prod-sim total idle CPU]] | [[MEASURE: prod-sim total RAM during dev load]] | [[MEASURE: prod-sim total CPU during dev load]] |

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

**Budget** is summed from `helm/values/`, `infisical/manifests/`, `monitoring/manifests/` and the contract. The **idle
RSS estimate** is from the research cross-check, section 4. That note's budget totals were 5,560 / 14,916 MiB, and this
table sums to less because the code differs: the Git remote moved out of the cluster, and monitoring's settings changed.
Its estimate still includes the old in-cluster Git pod, in the Traefik row.

| Group, with budget req / limit MiB per component | Budget req / limit MiB (setting) | Idle RSS estimate MiB (not measured) | Measured idle RAM | Measured idle CPU | Measured peak RAM during dev load | Measured peak CPU during dev load |
|---|---:|---:|---|---|---|---|
| Control plane and node agents, not set by this repository: apiserver, etcd, controller-manager, scheduler, kubelet, containerd, kube-proxy, kindnet, CoreDNS x2, local-path | 290 / 340, from the research note | 750-1,300 | [[MEASURE: control plane idle RAM]] | [[MEASURE: control plane idle CPU]] | [[MEASURE: control plane peak RAM during load]] | [[MEASURE: control plane peak CPU during load]] |
| containerd shims and pause containers | none | 300-600, at about 5-10 MiB per pod | [[MEASURE: VM memory not attributed to any container]] | | | |
| Traefik 64/192, metrics-server 48/128 | 112 / 320 | 80-150 | [[MEASURE: traefik and metrics-server idle RAM]] | [[MEASURE: traefik and metrics-server idle CPU]] | [[MEASURE: traefik and metrics-server peak RAM during load]] | [[MEASURE: traefik and metrics-server peak CPU during load]] |
| Argo CD: controller 192/640, repo-server 96/384, server 48/192, redis 24/64 | 360 / 1,280 | 450-700 | [[MEASURE: argocd idle RAM]] | [[MEASURE: argocd idle CPU]] | [[MEASURE: argocd peak RAM during load]] | [[MEASURE: argocd peak CPU during load]] |
| Monitoring: Prometheus 300/768, Alertmanager 48/96, config reloader 16/48 on each, operator 48/128, kube-state-metrics 32/96, node-exporter 24/48, Grafana 128/384, its sidecar 48/96, blackbox 16/48, alert sink 16/48 | 692 / 1,808 | 620-1,040 | [[MEASURE: monitoring idle RAM]] | [[MEASURE: monitoring idle CPU]] | [[MEASURE: monitoring peak RAM during load]] | [[MEASURE: monitoring peak CPU during load]] |
| Loki 192/640, Alloy 96/256 | 288 / 896 | 250-500 | [[MEASURE: loki and alloy idle RAM]] | [[MEASURE: loki and alloy idle CPU]] | [[MEASURE: loki and alloy peak RAM during load]] | [[MEASURE: loki and alloy peak CPU during load]] |
| Exporters, per environment: postgres 16/48, redis 12/32 | 56 / 160 | 50 | [[MEASURE: exporters idle RAM]] | [[MEASURE: exporters idle CPU]] | [[MEASURE: exporters peak RAM during load]] | [[MEASURE: exporters peak CPU during load]] |
| Infisical: server 650/1,024, its Postgres 64/256, its Redis 16/96, operators 64/128 x2 | 858 / 1,632 | 610-990 | [[MEASURE: infisical idle RAM]] | [[MEASURE: infisical idle CPU]] | [[MEASURE: infisical peak RAM during load]] | [[MEASURE: infisical peak CPU during load]] |
| Plane x2, from the tables above | 2,848 / 8,384 | 2,480-4,160 | [[MEASURE: both Plane environments idle RAM]] | [[MEASURE: both Plane environments idle CPU]] | [[MEASURE: both Plane environments peak RAM during load]] | [[MEASURE: both Plane environments peak CPU during load]] |
| **Cluster total** | **5,504 / 14,820** | **5,590-9,490** | [[MEASURE: cluster total idle RAM]] | [[MEASURE: cluster total idle CPU]] | [[MEASURE: cluster total peak RAM during load]] | [[MEASURE: cluster total peak CPU during load]] |
| Local services, outside the cluster, Compose `mem_limit`: registry, three caches at 128 each, `plane-git` at 64 | no request / 576 | none | [[MEASURE: local services idle RAM]] | [[MEASURE: local services idle CPU]] | [[MEASURE: local services peak RAM during image pulls]] | |

The monitoring row assumes the chart applies one config reloader setting to both Prometheus and Alertmanager.
[[VERIFY: the chart runs a config reloader beside Alertmanager with the same resources]]

Limits are deliberately overcommitted. The cluster total of 14.5 GiB exceeds a 14 GiB Docker setting, so if every workload
reached its limit at once the VM would run out. Contract section 10 brings the environments up serially for this reason.

### Against the VM

| Layer | Estimate GiB (not measured) | Derivation | Measured idle | Measured peak |
|---|---:|---|---|---|
| Workloads, idle | 5.5-9.3 | The cluster total above | [[MEASURE: workloads idle GiB]] | |
| VM overhead | 0.4 | Research reading of `/proc/meminfo` less `docker stats`, before this platform existed | [[MEASURE: VM overhead GiB]] | |
| Unrelated containers on this host | 2.0 | Research sum of `docker stats` across 16 containers, before this platform existed | [[MEASURE: unrelated containers GiB]] | |
| **Idle on VM** | **7.9-11.7** | Sum of the above | [[MEASURE: VM used memory idle GiB]] | |
| Bursts: both migrators, API first boot, repo-server render, a backup or k6 Job | +2 | Judgement, from the Railway first-boot figure of about +0.5 GiB per environment | | [[MEASURE: largest memory burst during first install]] |
| **Peak on VM** | **9.9-13.7** | Sum of the above | | [[MEASURE: VM used memory peak GiB]] |

Stopping unrelated containers removes about 2 GiB from those estimates.

## Disk

The VM cannot see the host's real limit. Research reads its filesystem as reporting far more free space than the Mac
has, so `NodeFilesystem*` alerts should not be trusted to warn before the Mac runs out. That is why every expensive
script calls `guard_disk`. [[VERIFY: VM filesystem free space reported against host free space on this machine]]

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
| Local registry, Wayline blobs | 0.5 | Judgement. `apps/wayline/` is not in the repository yet, so nothing is stored there for it | [[MEASURE: local registry volume, GiB]] |
| Build bases for Wayline images | 1.63 | Registry layer sizes, nginx by judgement | [[MEASURE: build bases in Docker's store, GiB]] |
| PVs, all environments | 1.5-4 | Judgement, see [storage](#persistent-storage) | [[MEASURE: all PVs, GiB]] |
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

| Environment | Volume | Declared | Bound by | Estimate GiB (not measured) | Measured idle | Measured after load |
|---|---|---:|---|---:|---|---|
| dev | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | [[MEASURE: dev postgres PV idle]] | [[MEASURE: dev postgres PV after load]] |
| dev | `plane-minio` | 1Gi | nothing | "small" in research | [[MEASURE: dev silo PV idle]] | [[MEASURE: dev silo PV after load]] |
| dev | `plane-rabbitmq` | 100Mi | nothing | "small" in research | [[MEASURE: dev rabbitmq PV idle]] | [[MEASURE: dev rabbitmq PV after load]] |
| dev | `plane-redis` | 100Mi | nothing | none | [[MEASURE: dev valkey PV idle]] | [[MEASURE: dev valkey PV after load]] |
| prod-sim | `plane-pgdb` | 1Gi | nothing | 0.15-0.3 | [[MEASURE: prod-sim postgres PV idle]] | [[MEASURE: prod-sim postgres PV during dev load]] |
| prod-sim | `plane-minio` | 1Gi | nothing | "small" in research | [[MEASURE: prod-sim silo PV idle]] | [[MEASURE: prod-sim silo PV during dev load]] |
| prod-sim | `plane-rabbitmq` | 100Mi | nothing | "small" in research | [[MEASURE: prod-sim rabbitmq PV idle]] | [[MEASURE: prod-sim rabbitmq PV during dev load]] |
| prod-sim | `plane-redis` | 100Mi | nothing | none | [[MEASURE: prod-sim valkey PV idle]] | [[MEASURE: prod-sim valkey PV during dev load]] |
| infisical | Postgres | 1Gi | nothing | 0.15-0.3 | [[MEASURE: infisical postgres PV idle]] | [[MEASURE: infisical postgres PV after load]] |
| infisical | Redis | 256Mi | nothing | none | [[MEASURE: infisical redis PV idle]] | [[MEASURE: infisical redis PV after load]] |
| monitoring | Prometheus | 2Gi | `retention: 3d`, `retentionSize: 1GiB` | up to 1 | [[MEASURE: prometheus PV idle]] | [[MEASURE: prometheus PV after load]] |
| monitoring | Loki | 2Gi | `retention_period: 72h` | 0.5-2 | [[MEASURE: loki PV idle]] | [[MEASURE: loki PV after load]] |

Backups go to `.local/backups/` on the host, not to a kind volume.

| Backup | Measured size | Measured duration |
|---|---|---|
| dev | [[MEASURE: dev backup size]] | [[MEASURE: dev backup duration]] |
| prod-sim | [[MEASURE: prod-sim backup size]] | [[MEASURE: prod-sim backup duration]] |
| infisical | [[MEASURE: infisical backup size]] | [[MEASURE: infisical backup duration]] |
