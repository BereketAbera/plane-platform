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

**No disk alerts.** The Docker VM reports hundreds of free GiB on a sparse disk while the Mac runs out
first. `guard_disk` in `scripts/lib/common.sh`, run on the host, is the real check.

**Backups stay in their own environment.** Each PVC mounts only that environment's folder, so
`restore.sh` refuses a backup from another environment rather than copying it across.

## Sentinels

A restore proof needs something to read back:

- `tests/e2e/smoke.py` creates the work item and attachment, recorded in `.local/test-sentinel-<env>.json`.
  `backup.sh` copies that record into the manifest. Run `make test-e2e ENV=<env>` once before the first
  backup, or restore reports those proofs as `NOT RUN`.
- `backup.sh` seeds the row `WAYLINE_RESTORE_SENTINEL` in `instance_configurations`, encrypted with
  `SECRET_KEY`. Encrypted rows are empty on a fresh instance, so a decrypt check without one proves nothing.

The dump holds password hashes and plaintext API tokens, so `.local/backups` is kept at 0700.

## Status

Static checks only so far. See the build report; nothing here has run on a cluster.
