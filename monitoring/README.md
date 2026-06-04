# Monitoring and data operations

| Path | What it is | Deployed by |
|---|---|---|
| `helm/values/kube-prometheus-stack.yaml` | Prometheus, Alertmanager and its routing, Grafana, kube-state-metrics, node-exporter | Application `kube-prometheus-stack`, wave -7 |
| `helm/values/loki.yaml`, `helm/values/alloy.yaml` | Log store, and log collection through the Kubernetes API | Applications `loki`, `alloy`, wave -6 |
| `monitoring/manifests/shared` | Blackbox, alert sink, routes, rules, dashboards, Traefik and Argo CD ServiceMonitors | Application `monitoring-extras`, wave -5 |
| `monitoring/manifests/environments/<env>` | Exporters, the RabbitMQ metrics Service, ServiceMonitors, Probes, in each Plane namespace | Same Application |
| `monitoring/ops/lib.sh` | Helpers shared by `scripts/backup.sh`, `restore.sh`, `test-alert.sh` | Not deployed |
| `gitops/platform/backup-storage` | A PV and a PVC per environment on `/backups/<env>`, `Retain` | Application `backup-storage`, wave -10 |

## Grafana

`http://grafana.localhost`, user `admin`. The chart generates the password, so it is never in Git:

```bash
KUBECONFIG=.local/kubeconfig kubectl --context kind-plane-platform -n monitoring \
  get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Argo CD renders the chart with no `lookup`, so each manifest regeneration draws a new random password
and a new `checksum/secret` on the pod template. The `kube-prometheus-stack` Application therefore
has to ignore both, with `RespectIgnoreDifferences=true`:

```yaml
ignoreDifferences:
  - { kind: Secret, name: kps-grafana, namespace: monitoring, jsonPointers: [/data/admin-password] }
  - { group: apps, kind: Deployment, name: kps-grafana, namespace: monitoring,
      jsonPointers: ["/spec/template/metadata/annotations/checksum~1secret"] }
```

## Decisions

**Exporter credentials.** `postgres-exporter` reads the `plane-pgdb` Secret the Infisical operator
already syncs into the namespace. It adds no `InfisicalStaticSecret`, no Infisical path and no
permission, so Plane's machine identity is exactly as wide as before. The cost: the exporter connects
as `POSTGRES_USER`, a superuser. A `pg_monitor` role would need a bootstrap step and a rotation path
that nothing owns today, so that is a pass 2 improvement. `redis-exporter` holds no credentials,
because Valkey has no password here.

**Exporter health and sync waves.** `monitoring-extras` syncs at -5, but `plane-pgdb` appears at -1 or
later, and the root gates each wave on health. `postgres-exporter` carries
`argocd.argoproj.io/ignore-healthcheck: "true"` (read in `controller/health.go` at v3.5.7) so the
wave does not wait forever on a pod that cannot start yet.

**Apiserver scrape off.** Series cost on a small cluster. `KubeAPIDown` is disabled with it, because
its rule file is not guarded by `kubeApiServer.enabled` and it would fire forever.

**No disk rule of our own.** The Docker VM reports hundreds of free GiB on a sparse disk while the Mac
runs out first. `guard_disk` in `scripts/lib/common.sh`, run on the host, is the real check. The chart's
`NodeFilesystem*` rules stay, and watch only the VM disk: `/backups` is excluded from node-exporter,
because Docker Desktop's mount of the Mac reports the wrong block size (measured: 4397 GiB available on
a Mac with 17 GiB free) and its percentage is the whole Mac, so the rules went critical on a healthy
cluster.

**`NodeClockNotSynchronising` off.** The VM runs no NTP client, so it fires on every machine, always
(measured: `node_timex_sync_status` 0, `node_timex_maxerror_seconds` 16).

**No CPU limit on small bursty containers.** Sidecars, config reloaders and node-exporter average under
10m but burst, and `CPUThrottlingHigh` counts any throttled period. A quota only produced false alerts. Plane's containers
keep their limits: each reads over 25% for about 5 minutes after it starts, while its boot is inside the rule's window. That
goes pending and has not reached the 15m `for:` on any Plane container, so those limits are not wrong.

**Grafana plugins.** Each bundled datasource with a backend runs as its own process in the Grafana
container, 22 to 35 MiB apiece. All but Prometheus and Loki are disabled, along with anything that
calls grafana.com, because no pod here has a route out.

**Backups stay in their own environment.** Each PVC mounts only that environment's folder, so
`restore.sh` refuses a backup from another environment rather than copying it across.

**Internal UIs admit only the node network.** Each Plane `api` must reach Traefik for the CoreDNS self-dial, and
Traefik routes by Host header, so without this a compromised `api` could read every metric and silence alerts. Each of
Prometheus, Alertmanager, Grafana, Argo CD and Infisical has a `node-network-only` Middleware with `ipAllowList` on
`172.16.0.0/12`: the host arrives as the kind gateway (measured `172.24.0.1`) and pods from `10.244.0.0/16`, on the
Service and on the NodePort alike. `tests/routes/internal-routes.sh` proves both sides. A pod gets 403, X-Forwarded-For
changes nothing, and PSA baseline refuses the `hostNetwork` pod that would get past it. This is the door check, not a
login: it trusts the node network, and it does not stop a dev `api` reaching `plane.prod-sim.localhost` as any browser
could. One more door depends on NetworkPolicy. On Docker Desktop, a pod that may dial `host.docker.internal:80`
(`192.168.65.254`) leaves through the Mac and comes back as the host, so the list admits it: a scratch pod with no egress
policy read Prometheus that way. By policy no Plane pod has that egress. The test checks it from the `api` pods only, and a
kindnet that fails open would open it. `policy/plane.rego` requires the middleware on every IngressRoute in `argocd`,
`monitoring` or `infisical`, on a route from anywhere to any of the five Services, and on a route that names any of the five
hosts, because the same Service under another host is the same UI. It refuses TCP and UDP routes there, which could not carry
this middleware, and a middleware of that name that admits anything else. So dropping either fails CI before it fails at runtime.

**Argo CD sync alerts.** Under `retry.limit: -1` a failing sync never completes: each failed attempt goes back to phase
Running, `argocd_app_sync_total` does not move, and no condition is set. So `ArgoSyncFailed` also watches for an
operation still open after 15m, from `argocd_app_info{operation="sync"}`. It cannot tell a retry loop from a wave
waiting on something that never gets healthy, and neither is healthy at 15m. Root's operation walks every wave, so
`ArgoRootSyncStuck` covers it at 60m. What each failure reads as, and what that reaches:

| Failure | What Argo CD reads | What fires |
|---|---|---|
| A commit that cannot render, or a Git that cannot be read | Sync Unknown, health unchanged, no operation, condition `ComparisonError`. Auto-sync runs only from OutOfSync, so nothing retries and the cluster stays on the old commit | `ArgoAppSyncUnknown` at 15m, and nothing else |
| A bad image in a Plane Deployment | Deployments are wave 3 of 4, so the operation stays open, fails at the 600s deadline, and retries | `ArgoAppDegraded` once Degraded for 5m, `ArgoSyncFailed` at 15m, if nobody reverts |
| A bad image in a single-wave chart Application | The sync succeeds on apply, which closes the operation, then Degraded at the rollout's deadline | `ArgoAppDegraded`, and `ArgoSyncFailed` never |
| A chart child with no deadline to miss, such as a stuck StatefulSet | Operation closed, Synced and Progressing, while root waits on it with no retry | The chart's `Kube*` rules at 15m, `ArgoAppStuckProgressing` at 30m, `ArgoRootSyncStuck` at 60m |
| A child that is Healthy but not Synced | The override in `helm/values/argocd.yaml` reads it as Progressing, so root waits on it with no retry, while the child's own series still says Healthy | `ArgoAppSyncUnknown` or `ArgoAppOutOfSync` at 15m, by its sync status, `ArgoRootSyncStuck` at 60m, and `ArgoAppStuckProgressing` never |
| A Prometheus that cannot start | Progressing, by the override in `helm/values/argocd.yaml` | Nothing, because nothing evaluates rules. Watchdog stops reaching the sink, and nothing watches for that |

On an Application that was rendering, a real commit took longer to read Unknown. The controller looks every 120 to 180s
(`--app-resync` 120s, `--app-resync-jitter` 60s), and from the first look that fails it ignores the failure for 180s
(`--repo-error-grace-period-seconds`). One real commit read Unknown after 5m57s, which is one sample, and that run stopped at
pending. With the rule's 15m it makes about 21m from commit to alert. By reading `controller/state.go`, the slowest case is up to
180s to the first look and up to 360s to a look past the grace: about 9m to Unknown, so up to about 24m. Health stayed as it was,
no operation opened and nothing was pruned. A file Argo CD cannot parse counts only if its text holds `apiVersion:`, `kind:` and
`metadata:`. Anything else it ignores, and it reads Synced at that commit.

`tests/drills/failed-deploy-rollback.sh` is the second row cut short: it reverts at the first Degraded, about 10m in. So
`ArgoSyncFailed` should stay pending throughout, `ArgoAppStuckProgressing` should be pending beside it on the same series for
those first 10m, and `ArgoAppDegraded` should then go pending in its place, with none firing unless the revert takes more than
5m. That is expected from reading the drill and from a unit test of those series, and not yet measured. The 15m in
`ArgoSyncFailed` has margin against a commit that pulls no new image (under 2m measured, 58s on promotion `4f622e3` whose layers
were already on the node) and against 448s for wave 3 pulling four images on a first boot. No measured promotion has pulled new
layers.

The 30m in `ArgoAppStuckProgressing` has margin against a chart pulling its images: kube-prometheus-stack took about 10m to its
first Healthy on the first boot measured. It would have fired later on that same boot, and rightly. Grafana's sidecars were being
OOM-killed, each Healthy lasted 19 to 40s, inside the rule's 2m window, and the expression read true for all 25m that have metrics,
about 42m in the timeline.

**A Prometheus with no ready pod reads Progressing, not Degraded.** The built-in check reads NoPodReady as Degraded, which
is every Prometheus start, and on a first boot that failed the root sync and sent it into backoff while the image pulled.
The cost: root used to retry and re-read the newest commit, and now it waits with no retry. So a fix to
`gitops/applications/kube-prometheus-stack.yaml` needs root's operation terminated by hand, as
`infrastructure/terraform/README.md` says under "After a stuck first sync". With Prometheus down, `ArgoRootSyncStuck`
cannot fire either.

**kindnet's fail-open line.** Alloy tails kindnet's container and counts "skipping network policies", which
`KindnetSkippedNetworkPolicies` fires on. Its other lines, a heartbeat every 10s, are counted and then dropped, so
`KindnetLogsNotRead` can say the tail is alive and Loki's volume stays as it was. Its limits:

- It sees that one line and nothing else: the controller's `Run` error is discarded, and it is configured `FailOpen`, so
  `make test-netpol`, which sends real traffic, remains the real check.
- The count lives in Alloy's memory, and its read positions on an emptyDir that survives a container restart. So any
  in-place Alloy restart, such as an OOM kill or a liveness failure, loses the count and never reads the line again, rotated or
  not. The rule therefore holds the highest count of the last 3d. Past that a forgotten line resolves the alert while kindnet may
  still be failing open. `retentionSize: 1GiB` can end the hold sooner: the blocks so far came to 90 MiB for about 3h under heavy
  churn, which would put it near 30h. That is an estimate.
- It can stick the other way. A count stands for a pod name, not a container, so if kindnet's container restarts in the same pod
  and comes up healthy, the alert keeps firing while Alloy holds the count, and for 3d after. Once `make test-netpol` passes, run
  `kubectl -n kube-system delete pod -l app=kindnet`: a count stops applying once its pod has been gone for 5m, and the resolve
  reached the sink 5m21s after the delete.

**`PrometheusMissingRuleEvaluations` goes pending on a healthy Prometheus, and this is left alone.** No rule group has taken
more than 1.3s of its 15s or 30s, and the longest gap between two evaluation starts in any group is 30.08s, so nothing is late. The
Docker VM steps its wall clock, measured on the node against the monotonic clock: forward a few hundred microseconds every 30s,
and by several milliseconds, up to 15, in either direction every 16 minutes. Prometheus ticks on the monotonic clock and works
out each slot from the wall clock. So a step back makes a group evaluate one slot twice, which logs "different value but same timestamp", and a later step
forward makes it skip one, which counts as missed. Seen live: back 12 ms at 00:34 with those log lines, then forward 25 ms at
00:50 and exactly one miss in each of the 31 groups within two minutes. The alert goes pending for 5m after each burst. It would
need a miss every 5m for 15m to fire, and it has not fired once in about 4h. It stays on, because a really slow group would miss
far more often than that.

**Reading a memory peak.** `memory.peak` includes page cache, so a peak at the limit says little alone. Read `anon` in
`memory.stat`, and read `memory.events` at the pod cgroup when one container carries the pod's whole limit. There the pod and the
container have the same `memory.max`, the pod also charges the pause container, so the pod nearly always gets there first and the
container's own `max` says little. Loki's pod counts 58271 at its own limit against 660 at its containers', and 0 for the one
running now. The pod's count also keeps what a container that has gone saw. Prometheus has a second limited container, so its own
limit comes first. Measured on 2026-11-05 (`limits-pod-cgroup-1.txt` in the evidence):

| Pod | `memory.max` in MiB, pod and container | `max` at the pod, and at the container | OOM kills | Highest anon | Limit |
|---|---|---|---:|---|---|
| Prometheus, before 00:34Z | 816, 768 | that pod is gone, 688 | 0 | 652 MiB (85%), at a head compaction with 241k head series | Raised to 1024Mi |
| Prometheus, since | 1072, 1024 | 0, 0 | 0 | 566 MiB (55%), at the WAL replay after that restart | |
| Loki | 640, 640 | 58931, 0 | 0 | 553 MiB (86%) in a stress test, then 480 in its WAL replay, and 341 (53%) since | Kept at 640Mi |
| Infisical Postgres | 256, 256 | 4227 and later 5066, 0 | 0 | 64 MiB (25%) | Kept at 256Mi |

Prometheus's limit moved because it came that close with nothing stressing it on purpose. Loki came as close, and that was not file cache:
anon reached 553 MiB, with file down to 13 MiB at the tightest. It stays for other reasons. That test pushed 3.5 MB/s with 8
concurrent queries, about 490 times the mean rate since (7.2 KB/s) and 40 times the busiest 5 minutes (87 KB/s), which took anon to
244 MiB. `GOMEMLIMIT` 560MiB held, and there was no OOM kill and no failed push or query, although queries slowed to 19s at the
median. The 553 is from the container the test then ended with `kill -9`, and the container's `max` of 0 is from the one after it.

Each count went with about 63 pages of direct reclaim in both pods, so it counts reclaim, and an OOM kill is a separate counter,
which reads 0 for the whole of each pod. cAdvisor's `container_memory_failcnt` reads 0 here, so the count has no history. Usage
bounds it: Loki's pod was last over 560 MiB at 21:59:25Z and last over 450 MiB at 22:25:55Z, and the count stood still from 01:36Z
on, so as far as 30s samples can say, its 58931 belong to that test and its replay. Raise Loki if the count moves again with no test
running, or if real load takes anon near `GOMEMLIMIT`. Postgres's count does move in ordinary use, 839 in five minutes while its
cache filled, with anon under 65 MiB. That is file cache being reclaimed, so nothing needs changing.

## Sentinels

A restore proof needs something to read back:

- `tests/e2e/smoke.py` creates the work item and attachment, recorded in `.local/test-sentinel-<env>.json`.
  `backup.sh` copies that record into the manifest. Run `make test-e2e ENV=<env>` once before the first
  backup, or restore reports those proofs as `NOT RUN`.
- `backup.sh` seeds the row `WAYLINE_RESTORE_SENTINEL` in `instance_configurations`, encrypted with
  `SECRET_KEY`. Encrypted rows are empty on a fresh instance, so a decrypt check without one proves nothing.

The dump holds password hashes and plaintext API tokens, so `.local/backups` is kept at 0700.

## Status

Run on the real kind cluster, proved by queries rather than pod status: Prometheus targets and rules,
Grafana login, datasources and every dashboard query, LogQL through Alloy and Loki, and an alert from
rule to sink. `ArgoSyncFailed` was proved against a real retry loop, and `KindnetSkippedNetworkPolicies` with a
synthetic line from a scratch pod, each from the source to the sink. `scripts/test-alert.sh`, the drill that scales the
API to zero, is a separate step.

These were proved from the source to the sink on 2026-11-05 as well. The throwaway Applications and scratch pods are gone:

- `ArgoAppSyncUnknown`, on an Application with a path that does not exist: at the sink 15m31s after it was created, through a
  controller restart at its 1m26s, and resolved 1m51s after it was deleted.
- `ArgoAppStuckProgressing`, on an Application reading `tests/rules/fixtures/stuck-progressing`, a LoadBalancer Service kind can
  never give an address (project `platform`, destination `monitoring`, automated sync, Argo CD's resources finalizer): at the sink
  30m33s after it was created, through a new commit that synced at its 11m22s without starting `for:` again, and resolved 2m8s
  after it was deleted. The other Argo rules stayed quiet for it. A commit that could not render was then measured on it, as far
  as `ArgoAppSyncUnknown` going pending: the paragraph under the table above.
- `PodRestarting`, on in-place Alloy restarts, under the expression it had then: quiet on one (`increase` read 1.03) and firing on
  two (2.07). That expression could still fire on one restart, on a series with only two samples, so the rule now takes the highest
  sample less the lowest. Run over the same history, that is true for the same spans, 00:45:30Z to 00:59:30Z for Alloy, and for
  nothing else. It has not yet fired live from the rule itself.
- `KindnetSkippedNetworkPolicies`, on a synthetic line followed by heartbeats as kindnet logs them, in a scratch pod: an in-place
  Alloy restart took the count out of Prometheus, the old expression went empty, and the alert stayed firing until the pod had
  been gone for 5m. No real kindnet failure has been seen. If the line is the pod's last when Alloy restarts, it is read again.
