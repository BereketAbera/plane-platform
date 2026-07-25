# Monitoring

Wayline is a customized Plane Community Edition v1.4.3 deployment. This page covers how that
deployment and the platform around it are observed: what is scraped, why Plane needs blackbox probes,
which alerts exist, what each can and cannot see, where they go, and how the path is tested.

**Status.** The stack ran on a local kind cluster on 2026-11-04 and 2026-11-05, and from about 08:12Z on 2026-11-05 on a new one restored from backup. A reading with no later date comes from the first. Targets, rules, dashboards, log search and
several alerts were proved by queries, not by pod status, and each result links its file under
[`docs/evidence/runs/`](evidence/README.md).
`make test-alert` passed once in each environment, and `tests/drills/alert-rules.sh` found [a real defect](#the-data-service-drill) in two rules, fixed and read again in dev. What Pass 1 did not test says so where it comes up. This stack is sized for a laptop and has no redundancy: one Prometheus, one Alertmanager, one
Loki, no paging. It is local and production-inspired, and it makes no claim of production readiness.

## Stack

All versions are pinned in `helm/values/` and `monitoring/manifests/`.

| Component | Version | Namespace | Argo CD Application, wave | Retention or cap |
|---|---|---|---|---|
| Prometheus | v3.15.1 distroless, chart `kube-prometheus-stack` 92.18.0 | `monitoring` | `kube-prometheus-stack`, -7 | 3 days or 1 GiB, whichever comes first |
| Alertmanager | v0.34.2 | `monitoring` | same | 24 hours |
| Grafana | 13.3.0 distroless | `monitoring` | same | No volume. Dashboards come from Git |
| kube-state-metrics | v2.20.0 | `monitoring` | same | Collectors reduced, no Secrets |
| node-exporter | v1.12.1 distroless | `monitoring-agents` | same | PSA `privileged`, because of `hostNetwork` and `hostPID` |
| Loki | 3.7.9, chart 20.4.1, monolithic, filesystem | `monitoring` | `loki`, -6 | 72 hours |
| Alloy | v1.21.3 distroless, chart 1.15.0 | `monitoring` | `alloy`, -6 | Tail positions on an `emptyDir` |
| blackbox-exporter | v0.29.1 | `monitoring` | `monitoring-extras`, -5 | |
| alert sink | Python 3.13 stdlib, `monitoring/manifests/shared/sink.py` | `monitoring` | same | Pod stdout, then Loki |
| postgres-exporter | v0.20.1 | each Plane namespace | same | |
| redis_exporter | v1.96.0 | each Plane namespace | same | |

`retentionSize` is the real cap on Prometheus, because kind's local-path provisioner ignores PVC
capacity. The same is true of Loki: its `2Gi` is a label, and only retention bounds the volume.

```mermaid
flowchart LR
  subgraph plane["plane-dev and plane-prod-sim, one set each"]
    pg["postgres-exporter"]
    rx["redis_exporter"]
    rmq["RabbitMQ :15692"]
    silo["Silo :9000"]
    app["api, web, admin, space, live"]
  end
  subgraph ingress["traefik"]
    tr["Traefik"]
  end
  subgraph mon["monitoring"]
    bb["blackbox-exporter"]
    prom["Prometheus"]
    am["Alertmanager"]
    sink["alert-sink"]
    alloy["Alloy"]
    loki["Loki"]
    graf["Grafana"]
  end
  prom -->|"scrape"| pg
  prom -->|"scrape"| rx
  prom -->|"scrape"| rmq
  prom -->|"scrape"| silo
  prom -->|"scrape"| tr
  prom -->|"probe request"| bb
  bb -->|"HTTP with public Host"| tr
  tr --> app
  prom -->|"firing alerts"| am
  am -->|"webhook"| sink
  alloy -->|"tail through the Kubernetes API"| app
  alloy -->|"tail through the Kubernetes API"| sink
  alloy -->|"push"| loki
  graf --> prom
  graf --> loki
```

## Why Plane has no `/metrics`, and what replaces it

No Plane service exports Prometheus metrics. A repo-wide search of Plane v1.4.3 for `prometheus`,
`django_prometheus` and `prom-client` finds nothing (read from upstream source, `git grep -i` at `37a15d9`, the commit `apps/wayline/UPSTREAM` pins).
Patching them in would widen the fork, so the signal is built from outside:

| Question | Signal |
|---|---|
| Can a client reach the API, web, admin, space and live? | Blackbox probes through Traefik |
| Is the API able to use Postgres? | Blackbox probe on a route that needs the database |
| Is a worker attached? | RabbitMQ consumer count on queue `celery` |
| Is work piling up? | RabbitMQ ready messages on queue `celery` |
| Is a data service up? | postgres-exporter, redis_exporter, RabbitMQ plugin, Silo endpoint, and kube-state-metrics' ready replicas for RabbitMQ and Silo |
| Is a pod restarting or near its limit? | kube-state-metrics and cAdvisor |
| What rate and error ratio does the edge see? | Traefik metrics |

Workers and beat expose nothing. A consumer on `celery` proves a connection, not a working task loop. Task-level
proof comes from runs, not metrics ([JOB rows](validation.md#background-jobs)). The smoke's `background-job` step
waits for the activity of the work item it just created (JOB-1). `tests/e2e/smoke.py --job-probe` creates a new
work item and waits the same way, so old rows do not count after a restart (JOB-2). Neither shows beat sending a
task. For that there is one reading by hand of `total_run_count` in Postgres, with the worker's task counts, in dev
on 2026-11-04 on upstream images (JOB-3). A real case of a live worker with nothing to read is in
[Plane app debugging](runbooks/plane-app-debugging.md#the-cancel_consumer-trap).

## Blackbox probes

Each Plane namespace has four `Probe` objects (`monitoring/manifests/environments/base/probes.yaml`),
scraped every 15 seconds. The target is Traefik's in-cluster Service. The public host is passed as
`?hostname=`, so a probe exercises the same routes as a browser and does not depend on DNS for
`*.localhost`. The Prometheus Operator sets the `namespace` label from where the `Probe` lives, which is
what splits alerts by environment. All 12 `probe_success` series read 1 on 2026-11-04 at 22:19Z
([monitoring-probes-1.txt](evidence/runs/monitoring-probes-1.txt)).

| `probe` label | Path | Module | Passes when | Proves | Does not prove |
|---|---|---|---|---|---|
| `api-instance` | `/api/instances/` | `http_plane_instance` | 200, and the JSON has `config` and `instance` | Traefik and the API process and Valkey answer | **Postgres** |
| `api-db` | `/api/public/anchor/__probe__/settings/` | `http_plane_db` | **404**, and the body has `does not exist` | The API ran a database query | Any write path |
| `live` | `/live/health` | `http_live` | 200, and JSON `status` is `OK` | The live process answers | WebSocket auth |
| `frontend` | `/`, `/god-mode/`, `/spaces/` | `http_html` | 200, and the body has a doctype | The static or SSR page is served | That the page works in a browser |

### Traps these probes are built around

**`/api/instances/` is cached for two hours.** `InstanceEndpoint` carries
`@cache_response(60 * 60 * 2, user=False)`, so this route stays 200 from Valkey through a full Postgres outage
(read from upstream source, `apps/api/plane/license/api/views/instance.py` at `37a15d9`). It looks like the obvious health check and is
not one. On 2026-11-04, on upstream images, each Postgres round of the pod restart drill took Postgres away for under a minute. `api-db`
answered 500 with `probe_success` 0 for one sample each, in plane-dev at 22:44:45Z and in plane-prod-sim at 23:35:30Z and 23:54:25Z, while
`api-instance` stayed 200 and 1 ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). A longer outage, or one
that outlasts the cache entry, has not been tried.

**The healthy `api-db` answer is a 404.** The route runs `DeployBoard.objects.get` for an anchor that does
not exist. A 404 with that message needs a database round trip, and a failed connection gives 500.
Do not "fix" `valid_status_codes` to 200. It read 404 with `probe_success` 1 in both environments
([monitoring-probes-1.txt](evidence/runs/monitoring-probes-1.txt)).

**Status alone is not enough.** With no API endpoints, Traefik can fall through to the catch-all web route,
which answers 200 with HTML. Every module therefore asserts on the body. That fall-through has not been seen. With the only API pod deleted
on 2026-11-04 at about 22:41:45Z and 22:42:45Z in plane-dev, both API routes answered 503 and both probes failed on the status code
([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). Scaling to zero behaved the same in `make test-alert ENV=dev` on 2026-11-05: `api-instance` read 503 on
all eight samples from 05:50:50Z to 05:52:35Z, so the probe failed on the status code, with no fall-through to web, and the body check was not what caught it
([MON-1-20261105T055029Z-probes.txt](evidence/runs/MON-1-20261105T055029Z-probes.txt)). So the body check has not yet been seen doing this job.

**Probes spend the anonymous rate limit.** The two API probes make 8 requests a minute per environment
from one IP, against Plane's anonymous limit of 30 a minute. Do not raise the frequency much: a 429 fails the
probe and looks like an outage. None has been seen at the configured 15s interval: of the 4,740 samples of those two probes that Prometheus
held from 2026-11-04T21:04Z to 2026-11-05T02:01Z, none read 429
([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). That window held smoke runs and drills, and no load test. A client at about 5 requests a second does reach the limit: of 36 requests to the `api-db` route, 30 answered 404 and the next 6 answered 429
([SEC-2-throttle-precheck-20261105T061924Z.txt](evidence/runs/SEC-2-throttle-precheck-20261105T061924Z.txt)). One a second shows the same shape: `scripts/rotate.sh` probes that route at that rate, and a probe left running read 30 `ok` then about 28 `fail` in each minute from 07:40Z ([rotate-prod-sim-20261105T073843Z.probe](evidence/runs/rotate-prod-sim-20261105T073843Z.probe)). The script's error window reads high, which fits that, though the probe keeps no status code ([Secret rotation](runbooks/secret-rotation.md)).

**A wiped database shows up late on `api-instance`.** With no `Instance` row the route returns
`{"is_activated":false,"is_setup_done":false}`, which fails the check, but only once the cache is gone.
API start clears the cache. That is read from the source. An API restart on an empty database was not tested in Pass 1.

**Do not set a `Host` header in `blackbox.yml`.** The exporter refuses a module that has one when `?hostname=`
is also passed.

## What is scraped

Prometheus selects every ServiceMonitor, Probe and PrometheusRule in every namespace, because the
`*SelectorNilUsesHelmValues` values are false. Default scrape interval is 30 seconds. On 2026-11-04 at 22:19Z, 40 of 40 active
targets were up ([monitoring-targets-1.txt](evidence/runs/monitoring-targets-1.txt)).

| Target | Source object | Interval | Notes |
|---|---|---|---|
| Plane probes, 4 per environment | `Probe` | 15s | Above |
| postgres-exporter | ServiceMonitor, per environment | 30s | Connects as `POSTGRES_USER`, a superuser, from the `plane-pgdb` Secret. A `pg_monitor` role has no owner today |
| redis_exporter | ServiceMonitor, per environment | 30s | Valkey has no password here, so it holds no credentials |
| RabbitMQ `/metrics` | ServiceMonitor `plane-rabbitmq` | 30s | Aggregated, no `queue` label. Reached through the added `plane-rabbitmq-metrics` Service, because the chart's Service omits 15692 |
| RabbitMQ `/metrics/detailed` | same | 30s | Families `queue_coarse_metrics` and `queue_consumer_count`, vhost `/`. It returns nothing unless families are named |
| Silo `/minio/v2/metrics/cluster` and `/bucket` | ServiceMonitor `plane-minio` | 60s | `helm/plane/components/hardening/patches/silo.yaml` sets `MINIO_PROMETHEUS_AUTH_TYPE=public`, and both scrapes read `up` 1 in both environments ([monitoring-silo-metrics-1.txt](evidence/runs/monitoring-silo-metrics-1.txt)) |
| Traefik | ServiceMonitor `traefik` | 30s | `honorLabels: true`, so Traefik's own `service` label survives |
| Argo CD application controller | ServiceMonitor `argocd-application-controller` | 30s | `helm/values/argocd.yaml` enables the metrics Service. `argocd_app_info` is what the sync alerts read ([h16-metrics-inventory-1.txt](evidence/runs/h16-metrics-inventory-1.txt)) |
| kubelet and cAdvisor | chart `kps-kubelet` | kubelet 30s, cAdvisor 10s | `prober_*` series are off |
| kube-state-metrics, node-exporter, CoreDNS, Prometheus, Alertmanager, Grafana, operator | chart | 30s | |
| Loki, Alloy | their charts' ServiceMonitors | Chart values | Alloy's also carries the two kindnet counters, with kindnet's namespace and pod as labels |

**Not scraped, on purpose:**

| Component | Why |
|---|---|
| etcd, controller-manager, scheduler, kube-proxy | kind binds them to loopback, so a pod cannot reach them. Their rules are off too, or they would fire `*Down` forever |
| API server | It is reachable, but off to save series. `KubeAPIDown` is disabled with it, because its rule file is not guarded by `kubeApiServer.enabled` and carries `absent(up{job="apiserver"})` |
| Infisical operators | The ServiceMonitor stays off: it needs a binding to the metrics-reader role (`infisical/README.md`) |
| Infisical server | No target is configured. Its failure shows as a degraded Application or a stale Secret |

`pg_up` keeps a failing database visible as 0 on a Ready exporter, because the exporter's probes use its landing
page and not `/metrics`. On 2026-11-04 `pg_up` read 0 while the exporter's `up` read 1 and its container read Ready, on both first boots
before Postgres was ready (plane-dev 21:29:30Z to 21:32:45Z, plane-prod-sim 21:30:00Z to 21:47:15Z), and for one 30s scrape in each Postgres
round of the pod restart drill ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)).

`postgres-exporter` carries `argocd.argoproj.io/ignore-healthcheck: "true"`. It syncs at wave -5, and its Secret
appears at wave -1 or later, so without the annotation it would hold the root's waves forever. On the first boot it sat in
`CreateContainerConfigError` from 21:05 to 21:29 while `monitoring-extras` stayed Healthy
([monitoring-ignore-healthcheck-1.txt](evidence/runs/monitoring-ignore-healthcheck-1.txt)).

## Dashboards

Grafana is at `http://grafana.localhost`, user `admin`. The chart generates the password, so it is never in Git.

```bash
KUBECONFIG=.local/kubeconfig .tools/bin/kubectl -n monitoring get secret kps-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Dashboards live in `monitoring/manifests/shared/dashboards/`. The Grafana sidecar loads them from labelled
ConfigMaps, and `allowUiUpdates` is false, so a change in the UI is not kept. Edit the JSON, commit, and publish.

| Dashboard | UID | Folder | Answers |
|---|---|---|---|
| Platform overview | `wayline-platform-overview` | Platform | Are both environments up? Firing alerts, VM memory, edge request rate and 5xx ratio, CPU, memory and restarts by namespace |
| Plane data services | `wayline-data-services` | Plane | Postgres, Valkey, RabbitMQ and Silo status, Celery consumers and depth, database and bucket size, last backup age |
| Deployments and rollbacks | `wayline-deployments` | Plane | Application state, sync history, syncs still open, which digest ran when, unavailable replicas |
| Logs | `wayline-logs` | Plane | Search by namespace and container, API 5xx lines, alert deliveries to the sink |

All four load, and no query errors. On 2026-11-04 at 22:19Z through Grafana's API, with namespace `plane-dev`, 41 targets returned
data and 3 were empty. With `plane-prod-sim`, 25 returned data and 2 were empty. The empties were true at the time: no backup had run
(`Last backup`), and no 5xx had happened (`5xx ratio by environment`, `API requests with a 5xx`)
([monitoring-dashboards-wayline-1.txt](evidence/runs/monitoring-dashboards-wayline-1.txt)). They also rendered in the real Grafana UI
(`monitoring-ui-*.jpg` in [`evidence/runs/`](evidence/runs/)). The "Syncs still open" panel came later, in `e64f023`, and no evidence file
records it loading, through the API or in a browser. Its expression, run directly on Prometheus, does return the open operations, such as the
throwaway's 22:56Z to 23:28Z ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)).

The chart's default Kubernetes dashboards are also present. All 26 dashboards loaded through the API on 2026-11-04 at 22:19Z with 0 errors:
431 targets returned data and 44 were empty ([monitoring-dashboards-all-1.txt](evidence/runs/monitoring-dashboards-all-1.txt)). Three chart
dashboards were empty throughout. "Persistent Volumes", 0 of 6, because `kubelet_volume_stats_*` has no series here. "Grafana Overview", 0 of
7, and "Prometheus / Overview", 0 of 15, because the test set `instance` to the first value of its query, which was a pod IP that had gone:
at that moment `grafana_build_info` and `prometheus_build_info` had a series on another IP and none on those
([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). Neither has been run with the right IP.

Panels that group Traefik by `service` read labels of the form `<namespace>-<route>-<first 20 hex of sha256(match)>@kubernetescrd`,
which the `plane-(dev|prod-sim)-.*` regex in `platform-overview.json` matches, checked on the live labels
([monitoring-traefik-labels-1.txt](evidence/runs/monitoring-traefik-labels-1.txt)).

## Alert rules

Project rules are in `monitoring/manifests/shared/rules-plane.yaml` and `rules-platform.yaml`: 24 rules under 23 names,
because `ArgoSyncFailed` has two forms. `tests/rules/*.test.yaml` hold promtool unit tests for 15 of those names, 12 in `rules.test.yaml`, `PodRestarting` in `pod-restarting.test.yaml`, and `PlaneRabbitmqDown` and `PlaneMinioDown` in `data-services-down.test.yaml`. The "Seen" column
says what the evidence records on the cluster. Where it gives no other file, it comes from a read of `ALERTS` over all that Prometheus held on
2026-11-05, from 2026-11-04T20:30Z to 2026-11-05T02:01Z ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)).

### Plane

Runbook: [Plane debugging](runbooks/plane-app-debugging.md), and [Backup and restore](runbooks/backup-restore.md) for
`PlaneBackupFailed`.

| Alert | Fires on | `for` | Severity | Cannot see | Seen |
|---|---|---|---|---|---|
| `PlaneApiDown` | `probe_success{probe="api-instance"} == 0` | 1m | critical | Postgres, because the route is cached | Fired in `make test-alert` in each environment on 2026-11-05, through to the sink and resolved. See [How alerts are tested](#how-alerts-are-tested). Also fired on the first boot, with Plane absent, and in prod-sim's in-place restore. See below |
| `PlaneApiDatabaseProbeFailing` | `probe_success{probe="api-db"} == 0` | 1m | critical | Any write path | Fired beside `PlaneApiDown` in that test in dev, through to the sink and resolved, because the API was gone and not Postgres ([MON-1-20261105T055029Z-sink-final.txt](evidence/runs/MON-1-20261105T055029Z-sink-final.txt)). Also fired on the first boot, with Plane absent, and in prod-sim's in-place restore. See below. Pending for one sample in each Postgres round of the pod restart drill |
| `PlaneFrontendDown` | `probe` is `frontend` or `live`, and it fails | 2m | warning | A page that loads and does not work, an old page a browser kept in its cache ([live-dev](evidence/branding/live-dev/README.md)), WebSocket auth | Fired on the first boot, with Plane absent, and for its `live` probe in prod-sim's in-place restore. See below |
| `PlanePodCrashLooping` | A Plane container waiting in `CrashLoopBackOff` | 1m | critical | `ImagePullBackOff`, or a single restart | None in evidence |
| `PlanePostgresDown` | `pg_up == 0` | 1m | critical | A slow or full database that still answers. A stopped exporter leaves no series | Fired on the first boot, before Postgres was ready. See below. Pending in each Postgres round of the pod restart drill |
| `PlaneValkeyDown` | `redis_up == 0` | 1m | critical | The same for Valkey | Fired on the first boot, before Valkey was ready. See below |
| `PlaneRabbitmqDown` | `up` of the RabbitMQ `/metrics` scrape is 0, or `plane-rabbitmq-wl` has 0 ready replicas | 2m | critical | A broker that answers and has blocked publishers. A crash or a hung process was not tested. With kube-state-metrics gone as well, a missing pod leaves no series again | Fired on this form with the StatefulSet at 0 in dev on 2026-11-05: at the sink 157s after the scale, resolved 40s after it came back ([after](evidence/runs/alert-rules-dev-20261105T101707Z.txt)). The earlier form, on `up` alone, stayed silent for 270s on the same fault ([before](evidence/runs/alert-rules-dev-20261105T100605Z.txt)), and only went pending for seconds around broker restarts. See [the drill](#the-data-service-drill) |
| `PlaneMinioDown` | `up` of the Silo cluster scrape is 0, or `plane-minio-wl` has 0 ready replicas | 2m | critical | Failing uploads on a Silo that still answers metrics. A crash or a hung process was not tested. With kube-state-metrics gone as well, a missing pod leaves no series again | Fired on this form with the StatefulSet at 0 in dev on 2026-11-05: at the sink 148s after the scale, resolved 26s after it came back ([after](evidence/runs/alert-rules-dev-20261105T101707Z.txt)). The earlier form, on `up` alone, stayed silent for 270s on the same fault ([before](evidence/runs/alert-rules-dev-20261105T100605Z.txt)). See [the drill](#the-data-service-drill) |
| `PlaneWorkerNoConsumer` | `rabbitmq_detailed_queue_consumers{queue="celery"} == 0` | 2m | critical | A worker attached and not finishing tasks. A broker with no `celery` queue | Fired for real in prod-sim on 2026-11-04: pending 23:36:20, in Alertmanager 23:38:20, cleared after the repair ([plane-prod-sim-worker-no-consumer-alert-1.txt](evidence/runs/plane-prod-sim-worker-no-consumer-alert-1.txt)) |
| `PlaneCeleryQueueMissing` | RabbitMQ is up and has no `celery` queue | 10m | critical | A queue with no consumer, which is the rule above | Pending only, and no firing: on both first boots, with the broker up before any worker, for 5m45s in plane-dev and 1m15s in plane-prod-sim, and for seconds after a broker restart, one of them also read at 23:54:50Z ([plane-prod-sim-worker-no-consumer-alert-1.txt](evidence/runs/plane-prod-sim-worker-no-consumer-alert-1.txt)) |
| `PlaneCeleryBacklog` | More than 500 ready messages on `celery` | 5m | warning | A backlog under 500. One shorter than 5m | No firing. Under `THINK=0` on dev on 2026-11-05 the queue stood above 500 from 09:20:03Z, reached 747 ready, and was empty by 09:22:03Z, about 2 minutes ([queue](evidence/runs/LOAD-3-20261105T092547Z-after-saturation.json), [what fired](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json)) |
| `PlaneBackupFailed` | `kube_job_status_failed` on a `plane-backup-*` Job, in a Plane namespace or `infisical` | none | warning | A backup that never ran. The "Last backup" stat shows that | Fired for real in `infisical` on 2026-11-04, from 22:57:30Z, on two backups that failed ([dr-backup-1.txt](evidence/runs/dr-backup-1.txt), [dr-backup-2.txt](evidence/runs/dr-backup-2.txt)). It cleared by 22:59Z, when the next backup succeeded and deleted those Jobs ([dr-backup-3.txt](evidence/runs/dr-backup-3.txt)) |

**A first boot fires these.** `monitoring-extras` syncs at wave -5 and Plane at -1 and 0, so the probes and rules are in place before Plane
answers. The read of `ALERTS` shows them firing on 2026-11-04, in UTC ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)):

| Alert | plane-dev | plane-prod-sim |
|---|---|---|
| `PlaneApiDown`, `PlaneApiDatabaseProbeFailing` | 21:06:00 to 21:46:45 | 21:06:00 to 21:49:30 |
| `PlaneFrontendDown`, first to last of its four probes | 21:06:45 to 21:47:00 | 21:06:45 to 21:49:30 |
| `PlaneValkeyDown` | 21:06:30 to 21:32:45 | 21:06:30 to 21:47:45 |
| `PlanePostgresDown` | 21:31:00 to 21:33:15 | 21:31:30 to 21:47:45 |

The API and frontend alerts cleared when each environment came up. The two data alerts cleared earlier, when the data pods came up. `PlanePostgresDown`
started later because `pg_up` has no series until the exporter runs, and the exporter sat in `CreateContainerConfigError` until 21:29. This shows
the rules can fire on a missing environment, not that each fires on the fault it names. With the API alone gone, `make test-alert` later made `PlaneApiDown` and `PlaneApiDatabaseProbeFailing` fire. `PlanePostgresDown` and `PlaneValkeyDown` have not fired on a Plane that was up. A first boot
also fires Argo CD rules: see `ArgoAppDegraded` and `ArgoSyncFailed` below. Since `2f42ddb`, `PlaneRabbitmqDown` and `PlaneMinioDown` read ready replicas too, so a StatefulSet that takes over 2m to turn ready on a first boot can fire them now. That is read from the rule. The clean install and the first restore ran before it. The cold install and the two later restores ran after it, and no file here reads whether these rules fired during them.

**An in-place restore fires them too,** because it stops api, worker, beat and live on purpose. In prod-sim's restore on 2026-11-05, Alertmanager read `PlaneApiDown` and `PlaneApiDatabaseProbeFailing` active from 07:36:26Z to 07:36:51Z, and `PlaneFrontendDown` on the `live` probe from 07:37:26Z to 07:37:57Z, the only time it has fired with the rest of Plane in place. Those readings come from a side watcher, and nobody read the sink for them ([SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt), [LOAD-3-20261105T074543Z-prometheus-windows.json](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)). Dev's restore has no such reading.

`PlaneCeleryQueueMissing` exists because of how RabbitMQ 4.3 fails with Celery. The broker is up, and the worker
never attaches and never creates a queue, so `PlaneWorkerNoConsumer` has no series to read. Contract section 9
keeps RabbitMQ on 3.13 or 4.2 for this reason.

`PlaneBackupFailed` clears when a later `scripts/backup.sh` run succeeds, because that script deletes earlier
failed backup Jobs. Otherwise the Job and its alert remain until the 7-day `ttlSecondsAfterFinished`.

### Platform

Runbooks: [Memory pressure](runbooks/memory-pressure.md) for workloads and the VM,
[Troubleshooting](runbooks/troubleshooting.md#networkpolicy-seems-not-to-be-enforced) for kindnet, and
[Argo sync stuck](runbooks/argo-sync-stuck.md) for Argo CD, which also has
[what fires for which failure](runbooks/argo-sync-stuck.md#what-fires-for-which-failure).

| Alert | Fires on | `for` | Severity | Cannot see | Seen |
|---|---|---|---|---|---|
| `PodRestarting` | The highest sample of a container's restart count less the lowest is 2 or more in 15m, in a Plane, `monitoring`, `monitoring-agents`, `argocd`, `traefik` or `infisical` namespace | none | warning | One restart, on purpose. `kube-system` | On this form, on 2026-11-05 from 02:28Z: quiet on a scratch pod that restarted once, and firing on one that restarted twice, to the sink and resolved ([podrestarting-live-1.txt](evidence/runs/podrestarting-live-1.txt)). Before it the rule read `increase`. Above 1.5, until `ba72573` at 02:26Z: quiet on one in-place Alloy restart, firing on the second ([kindnet-hold-1.txt](evidence/runs/kindnet-hold-1.txt)). Above 1, until `01fa6e3` at 00:32Z: firing on Grafana's sidecars from 21:05:00 to 21:41:45 on 2026-11-04, while they were being OOM-killed ([Memory pressure](runbooks/memory-pressure.md)), on Loki from 21:51:00 to 22:12:45, beside two `kill -9` tests ([monitoring-loki-replay-1.txt](evidence/runs/monitoring-loki-replay-1.txt)), and on Alloy from 23:54:00 to 00:08:15, after one restart ([plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt)) |
| `ContainerMemorySaturation` | Working set above 90% of the limit | 5m | warning | A `memory.peak` at the limit that is page cache. `kube-system` | Pending only, and no firing: Loki between 21:46Z and 21:58Z on 2026-11-04, and Prometheus for seconds on 2026-11-05 |
| `VmMemoryLow` | `MemAvailable` below 10% of the node's total | 5m | warning | The Mac's memory | None in evidence. VM used has to pass about 12.27 GiB of 13.63 for this. Its top was 10.49 GiB through the first night ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt)), and 10.93 GiB in the 60s readings from 00:35Z to 07:47Z on 2026-11-05, at 01:50Z ([LOAD-3-20261105T074543Z-timeline.json](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). On the restored cluster it topped 9.05 GiB, under `THINK=0` ([against the VM](resource-utilization.md#against-the-vm)) |
| `KindnetSkippedNetworkPolicies` | The count of kindnet's `skipping network policies` line, held for 3d | none | critical | Any other way enforcement can fail. A line Alloy forgot more than 3d ago. It also sticks after kindnet's container restarts healthy in the same pod | A synthetic line from a scratch pod, firing to resolved ([h18-synthetic-2.txt](evidence/runs/h18-synthetic-2.txt)). With heartbeats after the line, as real kindnet logs, an in-place Alloy restart took the count out of Alloy at 00:55:04Z, the 3d hold kept it at 1, and the alert held until 5m after the pod's delete ([kindnet-hold-2.txt](evidence/runs/kindnet-hold-2.txt)). In [kindnet-hold-1.txt](evidence/runs/kindnet-hold-1.txt) the count stayed at 1 through two such restarts only because the pod's sole line was the fail-open line, which was read again, as the note at its top says. No real kindnet failure |
| `KindnetLogsNotRead` | No kindnet line counted, by `absent()` | 10m | warning | A tail that reads and counts wrongly | Pending after an Alloy restart, and no firing recorded ([kindnet-hold-1.txt](evidence/runs/kindnet-hold-1.txt)) |
| `ArgoAppOutOfSync` | `sync_status="OutOfSync"` | 15m | warning | Sync status Unknown, which is the next rule | Fired on a throwaway ([h16-fire-1.txt](evidence/runs/h16-fire-1.txt)) |
| `ArgoAppSyncUnknown` | `sync_status="Unknown"`: a commit that cannot render, or a Git that cannot be read. On an Application that was rendering, the controller ignores the failure for 180s and its looks are 120 to 289s apart, so `rules-platform.yaml` estimates about 21m after the commit, and up to about 26m | 15m of reading Unknown | warning | Nothing else fires for this. The cluster silently stays on the old commit | A throwaway with a path that never existed: to the sink at 15m, resolved 2 minutes after its delete ([argo-sync-unknown-1.txt](evidence/runs/argo-sync-unknown-1.txt)). That proves the path, not the timing from a real commit, which has not fired: one read Unknown 5m57s after it and reached pending before it was taken out ([argo-sync-unknown-2.txt](evidence/runs/argo-sync-unknown-2.txt)) |
| `ArgoAppDegraded` | `health_status` is `Degraded` or `Missing` | 5m | critical | A retry loop whose health stays Healthy. Anything that stays Progressing | Fired on a throwaway ([h16-throwaway-1.txt](evidence/runs/h16-throwaway-1.txt)). Also on `plane-dev` and `root` on the first boot, up to 21:26Z, while they waited for the identity Secret. Pending only in the failed-deploy drill, on both `plane-dev` and `root`, for about 2 minutes before the revert cleared it |
| `ArgoSyncFailed`, open operation | `argocd_app_info{operation="sync"}` held on any child except root | 15m | critical | It cannot tell a retry loop from a wave waiting on something that never gets healthy. A single-wave chart Application closes its operation on apply, so this never sees it | Fired on a throwaway at 15m, through 2 Prometheus and 1 controller restarts, resolved after its delete ([h16-fire-1.txt](evidence/runs/h16-fire-1.txt)). This form went live after the first boot, at 23:06:02Z. Pending only in the two drills of 2026-11-05, from its `activeAt` to the last reading: 13m45s in the failed-deploy drill and 11m57s in the failing-migrator drill, because each revert closed the operation first |
| `ArgoSyncFailed`, completed | `argocd_app_sync_total{phase=~"Error\|Failed"}` increases, or first appears, in 15m | none | critical | A retry loop, which never completes | Fired with `phase="Failed"` on operations ended by the Terminating patch, on 2026-11-04: scratch Applications `term-a` and `term-b` from 21:05:15Z, and `root` from 21:15:45Z to 21:19:00Z ([argocd-terminate-1.txt](evidence/runs/argocd-terminate-1.txt), [argocd-root-terminate-1.txt](evidence/runs/argocd-root-terminate-1.txt)) |
| `ArgoAppStuckProgressing` | `health_status="Progressing"` on any child except root | 30m | warning | The first 30m. Root itself | Fired on a throwaway at 30m on 2026-11-05, from 01:08:15Z to 01:18:30Z, reading `tests/rules/fixtures/stuck-progressing`. The run's own file is [argo-stuck-progressing-1.txt](evidence/runs/argo-stuck-progressing-1.txt) |
| `ArgoRootSyncStuck` | `argocd_app_info{operation="sync",name="root"}` held | 60m | warning | A Prometheus that cannot start, since nothing then evaluates rules | Pending for under 4 minutes on 2026-11-04 from 23:22:45Z, and no firing |

`ArgoAppOutOfSync` has a 15-minute `for` so that scripts holding self-heal off, such as `scripts/test-alert.sh`
and `scripts/restore.sh`, do not trigger it during a normal run.

**`ArgoSyncFailed` used to stay silent during a retry loop.** Every Application sets `retry.limit: -1`, so a failing sync never
completes. Measured over 30 minutes of a retry loop on a real controller: phase `Running`, `retryCount` up to 8, no series in
`argocd_app_sync_total`, `status.conditions` empty, and only `argocd_app_info{operation="sync"}` held
([h16-throwaway-1.txt](evidence/runs/h16-throwaway-1.txt), [h16-metrics-inventory-1.txt](evidence/runs/h16-metrics-inventory-1.txt),
[h16-fire-1.txt](evidence/runs/h16-fire-1.txt), which has the 8 and the 30 minutes).
So the rule now also reads the open operation. Its 15m has margin against a first boot's wave 3 at 448s
([plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt)). It has none against the whole of `plane-dev`'s first boot: that operation stayed open about 35 minutes, from 21:11:33Z to 21:46:40Z, about 14 of them
waiting on `scripts/infisical-bootstrap.sh` and the rest waves 1 to 3 and the hook ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt), [infisical-bootstrap-1.txt](evidence/runs/infisical-bootstrap-1.txt)).
So `rules-platform.yaml` expects this rule to fire on `plane-dev` on a first boot held on bootstrap like that stage-by-stage one. This form was not live on it, so that is expected
and not measured. The clean install of 2026-11-05 did not wait like that. In its one `make up`, on warm mirrors, `plane-dev`'s operation cannot have opened before 182s into the Infisical wait, in a step of 245s, and had closed by 185s into the last wait, when root had moved on to `plane-prod-sim`. So it lasted at most about 248s, about 4 minutes ([log](evidence/runs/clean-install-20261105T075041Z/make-up.txt)). Nobody read `ALERTS` in it, so whether this rule stayed quiet is not recorded. In the restore into a new cluster, `plane-dev`'s operation ran from 08:16:18Z to 08:20:56Z, and `plane-prod-sim`'s from 08:20:57Z to 08:23:33Z ([window checks](evidence/runs/LOAD-3-20261105T092547Z-window-checks.txt)). The promotions of 2026-11-05 closed in about a minute ([Argo CD](argocd.md#after-a-promotion)), and none was timed through a cold mirror.

**What the failed-deploy drill measured,** on 2026-11-05 in dev. It reverted 8s after the first Degraded, at 10m24s, so `ArgoAppDegraded` stayed pending. The rule above reads a 2m window, so it holds true for 2m after the last open sample, and the operation closed at 11m51s. So `ArgoSyncFailed` stayed pending for 13m45s, against its 15m, and a revert about 75s
later would have let it fire. `ArgoAppOutOfSync`, `ArgoAppStuckProgressing` and the chart's `KubePodNotReady`, `KubeContainerWaiting` and `KubeDeploymentRolloutStuck` went pending too, and only `Watchdog` reached the sink ([drill-failed-deploy-20261105T062343Z-alerts.tsv](evidence/runs/drill-failed-deploy-20261105T062343Z-alerts.tsv)). The failing-migrator drill held for 6 minutes, too short for a 15m rule, and shows `ArgoAppDegraded` never went pending, because health stayed `Healthy`
([drill-failed-migrator-20261105T064940Z.log](evidence/runs/drill-failed-migrator-20261105T064940Z.log)). So neither drill shows these rules firing on a Plane Application. That rests on the throwaway above.

### Chart defaults that stay on

`kube-prometheus-stack` adds its default rules: 146 alerting rules were loaded on 2026-11-04, 18 of them project rules then, with 0 not
ok, so 128 are the chart's ([monitoring-rules-1.txt](evidence/runs/monitoring-rules-1.txt)). Those worth knowing:

| Alert | Comment |
|---|---|
| `Watchdog` | Always firing, by design. See routing below |
| `NodeFilesystem*`, `KubePersistentVolumeFillingUp` | **Do not trust these for disk.** They watch the VM disk only, which reports hundreds of free GiB on a sparse disk while the Mac runs out first. `/backups` is excluded from node-exporter, because Docker Desktop's mount of the Mac reported 4397 GiB available with 17 GiB free, and the percentage rules went critical on a healthy cluster. Local-path volumes emit no `kubelet_volume_stats_*`. See [Disk pressure](runbooks/disk-pressure.md) |
| `KubeNodePressure`, `KubeNodeEviction` | kind sets eviction thresholds to 0%, so these are not expected to warn about disk |
| `CPUThrottlingHigh` | Fired on node-exporter from 21:19 to 21:38 on 2026-11-04, on a 100m quota. Sidecars, config reloaders, node-exporter and postgres-exporter now have no CPU limit. It still goes pending on pods that just started, which is not a fault ([cpu-throttling-1.txt](evidence/runs/cpu-throttling-1.txt)). Under `THINK=0` on 2026-11-05 dev's Postgres was throttled in 98% to 100% of CFS periods for 9 minutes, and this did not read firing, so no alert here says the limit that binds under load is binding ([load results](resource-utilization.md#load-results-dev), [what fired](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json)) |
| `PrometheusMissingRuleEvaluations` | Goes pending on a healthy Prometheus, because the Docker VM steps its wall clock. Left on, because it has not fired and a really slow group would miss far more often ([missing-rule-evaluations-1.txt](evidence/runs/missing-rule-evaluations-1.txt), `monitoring/README.md`) |
| `KubeMemoryOvercommit`, `KubeCPUOvercommit`, `KubeQuota*`, `NodeMemoryHighUtilization` | Memory limits are overcommitted on purpose. These were quiet in the reading below |

Off in Git, because they could only ever fire: `NodeClockNotSynchronising`, since the VM runs no NTP client, and `KubeAPIDown`, since the
API server is not scraped.

On an idle platform on 2026-11-04 at 22:19Z, only `Watchdog` was firing, and nothing was pending
([monitoring-rules-1.txt](evidence/runs/monitoring-rules-1.txt)).

There is deliberately no project disk rule. `guard_disk` in `scripts/lib/common.sh` runs on the host and is the real
check, and `make status` prints host free space.

## Routing to the sink

Alertmanager has one real receiver. There is no email, chat or paging integration in Pass 1, so **an alert reaching
the sink notifies no human.** Someone has to look at Grafana or the sink's log.

```mermaid
flowchart LR
  rule["PrometheusRule"] --> prom["Prometheus"]
  prom --> am["Alertmanager"]
  am -->|"Watchdog: every 5m"| sink["alert-sink :8080/alerts"]
  am -->|"everything else"| sink
  am -->|"InfoInhibitor"| discard["null receiver"]
  sink -->|"one JSON line per delivery"| stdout["pod stdout"]
  stdout --> alloy["Alloy"]
  alloy --> loki["Loki, 72h"]
```

| Setting | Value | Why |
|---|---|---|
| `group_by` | `alertname`, `namespace` | The two environments are grouped apart |
| `group_wait` | 10s | Lets `scripts/test-alert.sh` meet its 180s deadline. Default is 30s |
| `group_interval` | 30s | Same reason. Default is 5m |
| `repeat_interval` | 1h, and 5m for `Watchdog` | |
| `send_resolved` | true | The test requires a resolved delivery |
| `max_alerts` | 20 | Keeps a sink line bounded |

`Watchdog` gives a continuous proof: a new sink line about every 5 minutes means rule evaluation, Alertmanager and the
webhook all still work. Measured: a line every 5 to 6 minutes ([monitoring-alertmanager-1.txt](evidence/runs/monitoring-alertmanager-1.txt)).
If those lines stop, the alert path is broken even when no other alert is firing. Nothing alerts on their absence, because the
sink is the only receiver.

Read deliveries in two ways:

```bash
KUBECONFIG=.local/kubeconfig .tools/bin/kubectl -n monitoring logs deploy/alert-sink --tail=20
```

In Grafana, use the "Alert deliveries to the sink" panel on the Logs dashboard. Prometheus and Alertmanager have no
login of their own. They are at `http://prometheus.localhost` and `http://alertmanager.localhost`, on loopback only, and a
`node-network-only` Middleware on all five internal UIs admits only `172.16.0.0/12`. The host gets 200, and a pod gets 403 from Traefik, spoofed
headers included ([routes-after-2.txt](evidence/runs/routes-after-2.txt)). This is a door check and not a login: a pod free to leave
through `host.docker.internal` came back as the host and read Prometheus, and only NetworkPolicy keeps Plane pods from that door
([h17-doors-free-egress-2.txt](evidence/runs/h17-doors-free-egress-2.txt)). Pass 2 must put them behind auth before exposing them.

## Loki and Alloy

Alloy runs as one Deployment and reads logs through the Kubernetes API with `loki.source.kubernetes`, not as a
DaemonSet tailing `/var/log/pods`. It therefore needs no root, no `hostPath` and no privileged namespace. It pays
for that with more kubelet and API server traffic, and that cost is small. Measured on 2026-11-04 over 180-second windows, with Alloy on
53 log streams: API server 58 to 106m CPU and 996 to 1,030 MiB RSS, kubelet 79 to 101m and 160 to 162 MiB. A second Alloy added 6 to
40 MiB to the API server and about 20 MiB to the kubelet, with CPU inside the noise from other work
([monitoring-alloy-apiserver-cost-1.txt](evidence/runs/monitoring-alloy-apiserver-cost-1.txt)). So the documented fallback, a DaemonSet in
`monitoring-agents`, is not needed at this size.

| Setting | Value | Consequence |
|---|---|---|
| Namespaces kept | `plane-dev`, `plane-prod-sim`, `infisical`, `argocd`, `traefik`, `monitoring` | `monitoring-agents` and CoreDNS are not shipped. Read them with `kubectl logs`. `traefik` had no lines in a 5-minute window, since Traefik writes no access log here ([monitoring-logql-1.txt](evidence/runs/monitoring-logql-1.txt)) |
| kindnet | `kube-system`, container `kindnet-cni` only | Counted for `KindnetSkippedNetworkPolicies` and `KindnetLogsNotRead`, then dropped, except the `skipping network policies` line. Read the rest with `kubectl logs` |
| Labels | `namespace`, `pod`, `container` | Query with these only |
| Finished pods | Pods in `Succeeded` or `Failed` are dropped | A short Job, such as the migrator or a backup, may have partial logs in Loki. Read it with `kubectl logs` while the Job exists |
| Probe noise | Lines containing `Blackbox-Exporter` are dropped | The string matches `prober/http.go:292` at v0.29.1. Plane's web and API logs do carry it, and the stage drops them: for `plane-web`, 24 lines in the pod and 16 in Loki, the same 16 without that string ([monitoring-alloy-restart-1.txt](evidence/runs/monitoring-alloy-restart-1.txt)) |
| Positions | `emptyDir`, 256 MiB | Over a pod replacement no line was lost or duplicated in the containers checked, and Loki refused 2,577 re-read lines as too far behind, stored the first time ([monitoring-alloy-restart-1.txt](evidence/runs/monitoring-alloy-restart-1.txt)). An in-place container restart keeps positions and loses counters |
| Loki limits | Ingestion 4 MB/s, burst 8 MB, querier concurrency 2 | Heavy log search on a laptop will be slow |
| Loki memory | 640 MiB limit | Below the chart's example of 2 to 4 GiB. Raise this first on an OOM kill. See below |

Loki at idle read 329 MiB in `kubectl top` on 2026-11-05 at 00:03Z ([plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt)). Under a stress
test on 2026-11-04, 3.5 MB/s of pushes for 270 seconds with 8 query threads for the last 120, anon memory peaked at 553 MiB. There were no OOM kills and no failed
push or query, and the median query rose to about 19 seconds ([monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt)). After `kill -9` with a 2.2 GB WAL, all
3,932,060 pushed lines were readable ([monitoring-loki-replay-1.txt](evidence/runs/monitoring-loki-replay-1.txt)). Those lines are synthetic. Queries over 72 hours of real logs have
not been tried. Real anon peaked at 341 MiB, 53% of the limit, at 22:26Z on 2026-11-04, minutes after the highest query rate and with ingest at 2.5 KB/s. Inside the busiest 5 minutes of ingest, 87 KB/s, it was 127 to 158 MiB. So it does not follow ingest, and the test's multiple on ingest is not a margin on anon ([alert-text-figures-1.txt](evidence/runs/alert-text-figures-1.txt)).

The `grafana/loki` chart on `grafana.github.io` has been the Enterprise chart since 2026-03-16, so this repo uses
the same 20.4.1 from `grafana-community`. Do not swap the source because the other index looks current.

Filesystem storage is not supported for production by Loki itself. It fits a local Pass 1 only.

The "API requests with a 5xx" panel parses `container="plane-api"` lines as JSON. The parser works: `status_code >= 400` returned 8 lines
and `>= 500` returned none, at that read on 2026-11-04 ([monitoring-logql-1.txt](evidence/runs/monitoring-logql-1.txt)). No read has caught that panel showing a 5xx, though the `api-db` probe has since read 500 in Postgres rounds, as above.

## Deployment and rollback visibility

A deployment here is a Git change, so the record has three parts.

| Question | Where to look |
|---|---|
| What was promoted, and when? | `git log --grep='^promote' --format='%h %cI %s'`. Commits also carry `Promote-Env` and `Promote-Image` trailers |
| What was rolled back? | `git log --grep='^Revert "promote' --format='%h %cI %s'` |
| Is that commit published to Argo CD? | `git --git-dir=.local/git/plane-platform.git log -1 --format='%h %s' main` |
| What did Argo CD do? | "Application state", "Sync history in range" and "Syncs still open" panels |
| Which digest was running at a given time? | "Which digest ran when" panel, from `kube_pod_container_info` `image_id` |
| Did the rollout hurt anything? | "Unavailable replicas" panel, plus "Probe history" on Platform overview |

Limits to keep in mind:

- History is bound by Prometheus retention, at most 3 days or 1 GiB. Git is the durable record.
- No dashboard has deploy annotations. Line up times by hand with the timeline panels.
- "Sync history" counts completed operations only, so a sync in a retry loop does not appear there. "Syncs still open" shows it.
- A backup taken before a prod-sim promotion appears in `.local/backups/prod-sim/` and in the "Last backup" stat.
  That stat reads Job completion time, so it goes empty once the Job's 7-day TTL expires.

## How alerts are tested

`make test-alert ENV=dev` (or `ENV=prod-sim`) runs `scripts/test-alert.sh`. It proves one complete path for one alert,
`PlaneApiDown`, including the other environment staying quiet. **It passed once in each environment, on 2026-11-05.**

| Stage | What the script does | Deadline after injection | Dev, 05:50Z | Prod-sim, 07:25Z |
|---|---|---:|---:|---:|
| Preflight | Prometheus, Alertmanager and sink are reachable, the rule is loaded, the alert is not already active, and both environments' API probes are healthy | | Passed | Passed |
| Pause | Pauses auto-sync on the root, then the target app, because self-heal would undo the scale in seconds: 3s in the one timed run ([GITOPS-4-20261105T073240Z.txt](evidence/runs/GITOPS-4-20261105T073240Z.txt)) | | Done | Done |
| Inject | Scales `plane-api-wl` to 0 | 0 | 0 | 0 |
| Pending | Alert visible in Prometheus | 60s | 7s | 24s |
| Firing | Alert `firing` in Prometheus | 150s | 68s | 83s |
| Alertmanager | Alert active in Alertmanager | 165s | 68s | 83s |
| Sink | A `firing` webhook for this namespace in the sink's log | 180s | 78s | 83s |
| Isolation | `PlaneApiDown` not active in the other namespace, no firing webhook for it, and no new `PlaneApiDown`, `PlaneApiDatabaseProbeFailing` or `PlaneFrontendDown` there. Other alerts there are unrelated and do not count ([test-alert-isolation-stub-1.txt](evidence/runs/test-alert-isolation-stub-1.txt), a stub) | | PASS | PASS |
| Recover | Scales back to the original replica count | | Done | Done |
| Resolved | A `resolved` webhook reaches the sink | 300s after recovery | 91s after recovery | 61s after recovery |
| Isolation again | Same check | | PASS | PASS |

A trap puts the replicas and auto-sync back on any exit, including Ctrl-C. It cannot run after `kill -9` or a power
loss. If that happens, see [Argo sync stuck](runbooks/argo-sync-stuck.md#auto-sync-was-left-paused).

Evidence goes to `.local/evidence-raw/alert-test-<env>-<stamp>.json`, with `PASS` or `FAIL`, the stage that failed, and
seconds per stage. `make publish-evidence` copies it to `docs/evidence/runs/` for it to count.

From configuration, the worst case to the sink is the 5s `preStop` sleep, a 15s probe, 15s evaluation, 1m `for` and 10s `group_wait`. Those
add up to 105 seconds, as the script's header says. The comment in `rules-plane.yaml` says about 2 minutes. Those are calculations. Measured on 2026-11-05, one run each, from injection to the firing webhook at the sink: 78 seconds in dev and 83 seconds in prod-sim
([alert-test-dev-20261105T055044Z.json](evidence/runs/alert-test-dev-20261105T055044Z.json), [alert-test-prod-sim-20261105T072541Z.json](evidence/runs/alert-test-prod-sim-20261105T072541Z.json)). Earlier, a temporary `vector(1)` rule with `for: 1m` took 70 seconds from pending to the sink, and the resolved line arrived 330 seconds
after the rule was deleted ([monitoring-alert-path-1.txt](evidence/runs/monitoring-alert-path-1.txt)).

`make test-alert ENV=dev` delivered firing and resolved webhooks, and read result PASS and isolation PASS at `9c8e098`: `plane-prod-sim` stayed quiet, and auto-sync came back on `plane-dev` and `root`
([MON-1-20261105T055029Z.txt](evidence/runs/MON-1-20261105T055029Z.txt)). The sink received `PlaneApiDown` and `PlaneApiDatabaseProbeFailing`, firing at 05:52:05Z and resolved at 05:53:35Z, and only `Watchdog` otherwise ([MON-1-20261105T055029Z-sink-final.txt](evidence/runs/MON-1-20261105T055029Z-sink-final.txt)). `make test-e2e ENV=dev` passed afterwards, 45 PASS and 1 SKIP ([smoke-dev-20261105T055933Z-16552.json](evidence/runs/smoke-dev-20261105T055933Z-16552.json)).

`make test-alert ENV=prod-sim` read the same at `3227c91`: result PASS and isolation PASS, `plane-dev` quiet, and auto-sync back on `plane-prod-sim` and `root` ([MON-2-20261105T072541Z-run.txt](evidence/runs/MON-2-20261105T072541Z-run.txt)). A first attempt at 06:08Z was refused by the session's permission system before anything ran, and the owner then approved the run ([MON-2-20261105T060633Z.txt](evidence/runs/MON-2-20261105T060633Z.txt)).

That is one alert on one fault, once in each environment, and the sink is the end of the path, so no person was told.

The preflight requires both environments' API probes to be healthy, so this test cannot run with prod-sim down.

### The data service drill

`make test-alert` proves the whole path for one alert. `tests/drills/alert-rules.sh ENV=dev` asks a narrower question of others: with the thing a rule names really gone, does the rule fire? It pauses auto-sync on root and the Application, scales a StatefulSet to 0, watches Prometheus and the sink for up to 270s, puts it back, and waits up to 300s for the resolved webhook. One row at a time, and a row that does not fire is a FAIL. It has no `make` target, and defines two rows, `PlaneRabbitmqDown` and `PlaneMinioDown`.

Its first run found a real defect.

| Run | Rule read | RabbitMQ at 0 | Silo at 0 |
|---|---|---|---|
| [10:06Z](evidence/runs/alert-rules-dev-20261105T100605Z.txt), at `613c2a0` | `up` alone | No pending and no firing in 270s. FAIL | The same. FAIL |
| [10:17Z](evidence/runs/alert-rules-dev-20261105T101707Z.txt), at `2f42ddb` | `up`, or ready replicas | Pending at +26s, firing at +147s, at the sink at +157s, resolved 40s after it came back. PASS | Pending at +21s, firing at +138s, at the sink at +148s, resolved 26s after it came back. PASS |

`up` has no series once the endpoint leaves the Service, so `== 0` has nothing to read: at each deadline Prometheus held `up` for the other service and none for this one. `kube_statefulset_status_replicas_ready` still reads 0 with no pod, so the fix adds it beside `up`, which still covers a ready pod whose scrape fails. `tests/rules/data-services-down.test.yaml` holds what Prometheus really held: the pod gone, the pod ready with its scrape failing, and all well or only the other environment down.

That is one run each, in dev, on a scale to 0. Crashes and hung processes were not tested, and can read differently, as the script's header says. `PlanePostgresDown` and `PlaneValkeyDown` read through exporters that stay up, and this drill has no row for them.

### What this does not test

| Not tested by `make test-alert` | How it could be checked |
|---|---|
| Any other project rule firing | Only `tests/drills/alert-rules.sh`, for `PlaneRabbitmqDown` and `PlaneMinioDown`, and only on a scale to 0. The rest are not automated. The "Seen" columns above say which have fired, and how |
| A crash or a hung process behind a data service rule | Not tested. Only a clean scale to 0 has run |
| The `PlanePostgresDown` and `PlaneApiDatabaseProbeFailing` pair | By hand, with self-heal paused, following the pattern in `scripts/test-alert.sh` |
| `PlaneWorkerNoConsumer` | Same, scaling `plane-worker-wl` to 0. It has already fired once for a real reason |
| `PlaneCeleryQueueMissing` | It needs a broker up with no `celery` queue for 10m: a fresh broker whose worker never starts, or a broker the contract forbids, on a throwaway dev run. A restart of a broker whose worker did not reattach keeps the queue, and read `PlaneWorkerNoConsumer` instead ([plane-prod-sim-worker-broker-restart-1.txt](evidence/runs/plane-prod-sim-worker-broker-restart-1.txt)). It has only gone pending so far |
| A real notification to a person | Not possible in Pass 1: the sink is the end of the path |

Whether a rule reads anything was checked on 2026-11-05 at 02:01Z, with both environments Synced and Healthy, by asking for the selector under each
rule with its threshold left off ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). 16 of the 24 returned series. The other 8 name a
state nothing was in at that moment. The 7 Argo CD rules among them have each gone pending or firing in `ALERTS`, so those selectors do return series when the state
exists. `PlanePodCrashLooping` is the exception: its metric held other waiting reasons in Plane namespaces, and `CrashLoopBackOff` only outside them, so its selector has
returned nothing in what Prometheus holds. This shows what each rule reads, not that it fires on its fault.

A bad rule has two gates before it runs. The Prometheus Operator's admission webhook is off, so `scripts/ci/validate-manifests.sh` runs
`promtool check rules` over the rule files and `promtool test rules` over `tests/rules/*.test.yaml`. Each published run covers the rules as they stood. At
2026-11-04T22:19Z both passed on 18 rules, 12 and 6 ([monitoring-rules-1.txt](evidence/runs/monitoring-rules-1.txt)). At 23:04Z both passed on 20, 12 and 8, and the
rules from before that change failed the new tests, exit 1 ([h16-promtool-1.txt](evidence/runs/h16-promtool-1.txt)). At 2026-11-05T01:11Z both passed on 24, and the rules
from before that work failed, exit 1, in [rules-unit-1.txt](evidence/runs/rules-unit-1.txt). The 24 as they stood then, with `PodRestarting`'s later expression and the later tests, passed at 06:16Z on a clean clone at `0dde813` ([ci-2-20261105T061644Z-make-ci.log](evidence/ci/ci-2-20261105T061644Z-make-ci.log)). The fix for the two data service rules, with its new test file, passed both at about 10:16Z, in `scripts/ci/validate-manifests.sh` here and not in a clean clone ([alert-rules-validate-1.txt](evidence/runs/alert-rules-validate-1.txt)). `scripts/ci/negative-controls.sh` plants a broken expression and a rule that
fires late, and requires each to go red. GitHub's runners have run promtool on Linux too, as [evidence/ci/README.md](evidence/ci/README.md) says. A
broken expression that gets past these shows up only at evaluation, through `PrometheusRuleFailures`.

## Costs

Research estimated 620 to 1,040 MiB of idle RSS for Prometheus, Alertmanager, operator, kube-state-metrics, node-exporter, Grafana, blackbox
and sink, and 250 to 500 MiB for Loki and Alloy, before any monitoring pod had run. Measured on 2026-11-05 at 00:03Z in `kubectl top`, with both
environments running and no test in progress: `monitoring` 1,555 MiB and `monitoring-agents` 19 MiB, a little above the top of that range
([plane-prod-sim-snapshot-final-1.txt](evidence/runs/plane-prod-sim-snapshot-final-1.txt)). Per-container peaks are in
[monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt), and the platform's figures in
[resource utilization](resource-utilization.md). On the restored cluster, idle from 08:47:35Z to 08:56:59Z, `monitoring` averaged 1,018 MiB and 70 m and `monitoring-agents` 18 MiB and 2.2 m. That cluster was about 37 minutes old when idle began, so Prometheus and Loki held little history, and those are not a steady state ([the load window](resource-utilization.md#the-load-window)). A peak at a limit is often page cache: `monitoring/README.md` says how to read one.

Volume growth per day on an idle platform was not tested in Pass 1, because the platform never sat idle for a day. The one comparable reading: on 2026-11-05 at 07:44Z, about 10 hours after those volumes were made and with drills and a load test behind them, `du` read 654 MiB on Prometheus's volume and 891 MiB on Loki's ([LOAD-3-20261105T074440Z-host.txt](evidence/runs/LOAD-3-20261105T074440Z-host.txt)). That is not a daily rate. On the restored cluster, with its node 75 minutes old, `du` read 62 MiB and 9 MiB at 09:25:50Z ([LOAD-3-20261105T092547Z-host.txt](evidence/runs/LOAD-3-20261105T092547Z-host.txt)). Prometheus's 1 GiB cap and Loki's 72 hours are what bound them.

## Related

- [Runbooks](runbooks/README.md)
- [`monitoring/README.md`](../monitoring/README.md), for the decisions behind this stack and the limits of the kindnet alert
- [Security](security.md), for why `monitoring-agents` is `privileged`, and for postgres-exporter's superuser among what Pass 1 leaves
- [Known limitations](known-limitations.md)
- [Platform contract](platform-contract.md)
