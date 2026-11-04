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
10m but burst, and `CPUThrottlingHigh` counts any throttled period. A quota only produced false alerts.

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
policy read Prometheus that way. No Plane pod has that egress, and the test checks it, but a kindnet that fails open
would open it.

**Argo CD sync alerts.** Under `retry.limit: -1` a failing sync never completes: each failed attempt goes back to phase
Running, `argocd_app_sync_total` does not move, and no condition is set. So `ArgoSyncFailed` also watches for an
operation still open after 15m, from `argocd_app_info{operation="sync"}`. It cannot tell a retry loop from a wave
waiting on something that never gets healthy, and neither is healthy at 15m. Root's operation walks every wave, so
`ArgoRootSyncStuck` covers it at 60m. A bad image in the last wave does not trip either: that sync succeeds on apply,
and `ArgoAppDegraded` reports it once the rollout misses its deadline.

**kindnet's fail-open line.** Alloy tails kindnet's container and counts "skipping network policies", which
`KindnetSkippedNetworkPolicies` fires on. Its other lines, a heartbeat every 10s, are counted and then dropped, so
`KindnetLogsNotRead` can say the tail is alive and Loki's volume stays as it was. Two limits. This sees that one line and
nothing else: the controller's `Run` error is discarded, and it is configured `FailOpen`, so `make test-netpol`, which
sends real traffic, remains the real check. And if Alloy restarts after the kubelet has rotated that line away, the
count starts again without it.

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
