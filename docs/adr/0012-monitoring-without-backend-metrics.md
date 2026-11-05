# 0012. Monitoring a backend with no `/metrics` endpoint

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Plane CE v1.4.3 exports no application metrics (research, 2026-11-04, reading the source):

- No `/metrics` route. No `prometheus` or `django_prometheus` in `apps/api/requirements/` or settings. No `prom-client` in `apps/live/src`.
- `opentelemetry-*` is installed, but its only importer is `plane/license/bgtasks/telemetry_metrics.py`, which pushes instance counts to `https://telemetry.plane.so`. It provides no traces and no request metrics.
- Celery workers export nothing.

Status-only health checks are not good enough here. With no endpoints, Traefik can fall through to the catch-all web route, which answers 200 with HTML. So a status check can pass while the API is gone.

The obvious API health route has its own trap. `/api/instances/` is cached in Valkey for two hours and answers 200 with Postgres down. [[VERIFY: /api/instances/ stays 200 with Postgres stopped]]

## Decision

Observe Plane from outside, and observe its dependencies directly.

| Signal | Source | What it shows | What it does not show |
|---|---|---|---|
| API reachable | Blackbox probe of `/api/instances/`, with a CEL check on the JSON body | Traefik and api answer | Anything about Postgres |
| Database path | Blackbox probe of `/api/public/anchor/__probe__/settings/`. A 404 with "does not exist" is the healthy result | api opened a connection and ran a query | Write path, migrations |
| Frontends, live | Blackbox probes with body checks | Routes serve expected content | Client-side errors |
| Worker alive | `rabbitmq_detailed_queue_consumers{queue="celery"}` | A consumer holds a connection | That tasks succeed |
| Queue backlog | `rabbitmq_detailed_queue_messages_ready` | Work is piling up | Which tasks fail |
| Datastores | postgres-exporter, redis-exporter, RabbitMQ's built-in plugin on 15692, Silo's `/minio/v2/metrics/*` | Service health and saturation | Application meaning |
| Edge traffic | Traefik metrics | Request rate, latency and status per service | Per-view detail |
| Pods | kube-state-metrics, cAdvisor | Restarts, memory, CPU | Application state |
| Logs | Loki, through Alloy | Errors in text | Rates, unless queried |

Each probe goes to Traefik's in-cluster Service with the public host in `?hostname=`, so it exercises the same route as a browser. Rules are in `monitoring/manifests/shared/rules-plane.yaml`, including `PlaneApiDatabaseProbeFailing`, `PlaneWorkerNoConsumer` and `PlaneCeleryQueueMissing`. The last exists because a worker that never attached leaves no queue, so the consumer rule has no series to read. That is how RabbitMQ 4.3 fails ([0016](0016-datastore-versions.md)).

Probe rate is bounded. Two API probes every 15s are 8 requests a minute from one IP, under Plane's anonymous limit of 30 a minute.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Add `django-prometheus` through a patch to the backend image | The most useful signal, and a change to the application's runtime and middleware, carried across upgrades. Larger than Pass 1's branding-only patch scope. It is the natural next step |
| Point `OTLP_ENDPOINT` at Alloy | Yields business gauges available from SQL, for one more pipeline. It gives no request metrics |
| Status-code-only probes | False passes through the catch-all route |
| Celery exporter or Flower | One more component with broker access. The consumer count covers "is a worker attached" for now. Task failure visibility stays open |

## Consequences

- **There are no application-level request metrics.** Latency and errors per view are not available. Traefik gives them per service.
- **Failed Celery tasks are not visible as a metric.** A worker can hold a connection and fail every task, with only logs to show it.
- Consumer count is a proxy. The rule's own comment says so.
- Dashboards and alerts can be green while a specific feature is broken. The end-to-end smoke test in `tests/e2e/smoke.py` covers what probes cannot.
- Every probe depends on Traefik, so a Traefik outage fires every Plane probe at once.
- Silo's metrics endpoint defaults to JWT auth and answers 403, so `patches/silo.yaml` sets `MINIO_PROMETHEUS_AUTH_TYPE=public`. That opens the metrics path to anything that can reach port 9000. The ingress routes only `/uploads` to Silo, and NetworkPolicy limits who reaches the port. On 2026-11-04 Silo's metrics were scraped in both environments, and they moved with real data ([monitoring-silo-metrics-1.txt](../evidence/runs/monitoring-silo-metrics-1.txt)), and only `Watchdog` was firing ([monitoring-alertmanager-1.txt](../evidence/runs/monitoring-alertmanager-1.txt)).
- `postgres-exporter` connects as the shared superuser from `plane-pgdb`, which adds no Infisical path. A `pg_monitor` role is a Pass 2 improvement.
- No disk alert sees the host. The chart's `NodeFilesystem*` rules watch only the Docker VM, which reports hundreds of free GiB on a sparse disk while the Mac runs out first. `guard_disk` on the host is the check, and it only runs when a script does.
- The API server scrape is off to save series, with `KubeAPIDown` disabled alongside it.
- The rule comment gives about 2 minutes from failure to the alert sink, summed from the probe interval, evaluation interval, `for` and `group_wait`. That is an estimate. A temporary rule took 70s from pending to the sink on 2026-11-04 ([monitoring-alert-path-1.txt](../evidence/runs/monitoring-alert-path-1.txt)), which leaves out the probe and evaluation. `make test-alert` has not run. [[MEASURE: time from breaking the api to the alert reaching the sink, from make test-alert]]
- [[VERIFY: the api-db probe fails when Postgres is down while the api-instance probe still passes]]
- `PlaneWorkerNoConsumer` fired on a real loss of consumers in prod-sim on 2026-11-04, pending at 23:36:20 UTC and active at 23:38:20, and it cleared after the repair ([plane-prod-sim-worker-no-consumer-alert-1.txt](../evidence/runs/plane-prod-sim-worker-no-consumer-alert-1.txt)). The worker was not scaled to zero: it stayed running with no consumer, which is the case below.
- All 12 probes read success at the one moment they were captured ([monitoring-probes-1.txt](../evidence/runs/monitoring-probes-1.txt)). Nobody has read them for 429 over a sustained run. [[VERIFY: probes do not trip Plane's anonymous rate limit over a sustained run]]

## What we found when we ran it

Added 2026-11-05.

- **Consumer count is a better signal than the worker's own health.** In prod-sim a worker kept answering `celery inspect ping` while consuming nothing, with 210 messages parked and 0 consumers ([plane-prod-sim-worker-broker-restart-1.txt](../evidence/runs/plane-prod-sim-worker-broker-restart-1.txt)). Its liveness probe stayed happy, and only `PlaneWorkerNoConsumer` said so. The cause was the smoke test's own control: in Celery 5.5.3, `cancel_consumer` and then `add_consumer` leave the queue selection empty, so the next broker reconnect attaches no consumer. `0bba707` replaces the worker after that control.
- **Argo CD's own alerts needed real failures to get right.** Under `retry.limit: -1` a failing sync never completes, so the first `ArgoSyncFailed` could not fire. It now watches the open operation, and fired on a real refused sync, held through restarts, and resolved ([h16-fire-1.txt](../evidence/runs/h16-fire-1.txt)). [Monitoring](../monitoring.md) has the rules.
- **A health route on `/api/instances/` still has not been shown to mislead.** The trap this record is built around, 200 with Postgres stopped, comes from reading the code. No run has stopped Postgres and read both probes, so its two markers stay.
