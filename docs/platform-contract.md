# Platform contract

The single source of truth for names, ownership, and ordering. Every layer of the platform
conforms to this file. If code and this file disagree, one of them is a bug.

Decisions with a "why" live in [`docs/adr/`](adr/). This file only states what is true.

## 1. Fixed names

| Thing | Value |
|---|---|
| kind cluster | `plane-platform` (one node, `plane-platform-control-plane`) |
| kube context | `kind-plane-platform` |
| kubeconfig | `.local/kubeconfig` (scripts export `KUBECONFIG`; the user's `~/.kube/config` is never touched) |
| Kubernetes | v1.36.4 |
| Plane release | v1.4.3, source commit `37a15d99231042b3ff5a4401fed479fdbec9effe` |
| Plane chart | `plane-ce` 1.8.6, `https://helm.plane.so/`, tgz sha256 `c70244eefa7dfa94e8636048fe4032640999c7d4e265b1fec68d13060cf70e4f` |
| Helm release name | `plane` in both environments, so object names match and one patch set fits both |
| Distinct product name | **Wayline**, a customized Plane Community Edition deployment. Never present it as an original product |
| Host-only state | `.local/` (gitignored): `kubeconfig`, `git/`, `backups/`, `secret-zero/`, `terraform/`, `evidence-raw/` |

## 2. Namespaces

Terraform creates every namespace. Argo CD never does (`CreateNamespace=false`).

| Namespace | Purpose | PSA enforce | PSA warn/audit |
|---|---|---|---|
| `argocd` | Argo CD | `baseline` | `restricted` |
| `traefik` | Ingress | `baseline` | `restricted` |
| `monitoring` | Prometheus, Grafana, Loki, Alloy, exporters, alert sink | `baseline` | `restricted` |
| `monitoring-agents` | node-exporter only (`hostNetwork`, `hostPID`) | `privileged` | `restricted` |
| `infisical` | Infisical server and its dedicated Postgres and Redis | `baseline` | `restricted` |
| `plane-dev` | Dev environment | `baseline` | `restricted` |
| `plane-prod-sim` | Production simulation | `baseline`, tighten only after a per-workload non-root test passes | `restricted` |

Every Plane namespace carries label `plane-platform/environment: dev|prod-sim`. All namespaces
carry `plane-platform/managed-by: terraform`.

## 3. Hostnames and exposure

All hosts resolve to loopback without `/etc/hosts`. Traefik is a NodePort (30080, 30443), mapped by
kind to `127.0.0.1:80` and `127.0.0.1:443` only. No TLS locally; Pass 2 terminates at Cloudflare and the origin.

| Host | Backend |
|---|---|
| `plane.dev.localhost` | Plane dev |
| `plane.prod-sim.localhost` | Plane prod-sim |
| `argocd.localhost` | Argo CD UI |
| `grafana.localhost` | Grafana |
| `prometheus.localhost` | Prometheus |
| `alertmanager.localhost` | Alertmanager |
| `infisical.localhost` | Infisical |

CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to
`traefik.traefik.svc.cluster.local`, because the Plane API dials its own public host for
`copy_object` and OAuth avatars. Terraform owns that rewrite.

## 4. Ownership: exactly one owner per resource

| Owner | Owns | Never touches |
|---|---|---|
| **kind CLI** via `scripts/cluster-up.sh` | The cluster and node, CNI (kindnet), port and volume mounts | Anything inside namespaces |
| **Docker Compose** via `infrastructure/local-services/` | Registry, pull-through caches, `git://` remote. These outlive the cluster | Cluster resources |
| **Terraform** via `infrastructure/terraform/environments/local` | Namespaces and labels, ResourceQuota, LimitRange, CoreDNS rewrite, the Argo CD Helm release, AppProjects, the root Application | Anything Argo CD deploys |
| **Terraform** via `infisical/terraform` (separate root and state) | Infisical projects, environments, machine identities, memberships, Kubernetes Auth config | Secret values (`*_wo` or scripts only, never in state) |
| **Argo CD** | Everything else in the cluster: Traefik, metrics-server, NetworkPolicies, monitoring, Infisical server, operators, both Plane environments | Namespaces, itself |
| **Helm** | Renders charts. It is a packaging format here, not an owner. Nothing is `helm install`ed by hand | |
| **Infisical** | Secret values and their rotation history | Kubernetes objects (the operator materialises them) |
| **Scripts** via `.local/secret-zero/` | The only secrets that exist before Infisical does | Anything once Infisical is live |

Rule: if `git grep` finds the same resource under two owners, it is a bug. CI checks this.

## 5. Git, images, and delivery

- **Argo CD source:** `git://plane-git/plane-platform.git`, branch `main`. `plane-git` is a read-only
  container on the `kind` Docker network serving the bare repo at `.local/git/plane-platform.git`. The only
  writer is `make gitops-publish`, which pushes from the working repo to that path.
- **GitHub** (`origin`, private `BereketAbera/plane-platform`) runs CI. Argo CD does not read it in Pass 1.
- **Branded images:** `localhost:5001/wayline/{web,admin,space,backend}`, always referenced `@sha256:` by digest.
  `kind load` is forbidden: it cannot work with this host's containerd image store (kind #3795).
- **Upstream images:** by index digest from `docker.io`, never `artifacts.plane.so`. Pulls go through
  the pull-through caches declared in `infrastructure/kind/containerd-certs.d/`.
- **Plane manifests are rendered and committed.** `helm/plane/` holds the Kustomize overlay over the vendored
  chart. `make render` writes `gitops/environments/{dev,prod-sim}/manifests.yaml`. Argo CD syncs those plain
  manifests with no Helm or Kustomize at sync time. CI fails if rendering produces a diff.
- **Platform charts** (Traefik, monitoring, Infisical): Argo CD Helm sources, exact chart versions, values from
  `helm/values/` via a `$values` ref.
- **Promotion:** `make promote ENV=dev` or `make promote ENV=prod-sim`. Prod-sim accepts only a digest already
  recorded for dev, and takes a Postgres dump first.

## 6. Sync waves

Inside each Plane Application, in order:

| Wave | Resources |
|---|---|
| -3 | ServiceAccounts, `InfisicalConnection` |
| -2 | `InfisicalAuth` |
| -1 | `InfisicalStaticSecret` (health-gated with custom Lua) |
| 0 | ConfigMaps, Services |
| 1 | StatefulSets: postgres, redis, rabbitmq, silo |
| 2 | Migrator Job, as an Argo `Sync` hook. Never `PreSync`: it deadlocks a fresh install |
| 3 | Deployments: api, worker, beat, web, admin, space, live |
| 4 | Ingress routes |

Root app-of-apps, in order: `network-policies` (-10), `traefik` (-9), `metrics-server` (-8),
`kube-prometheus-stack` (-7), `loki` and `alloy` (-6), `monitoring-extras` (-5), `infisical` (-4),
`infisical-operator-dev` and `infisical-operator-prod-sim` (-3), `plane-dev` (-1), `plane-prod-sim` (0).
`argocd-cm` carries a custom health check for `argoproj.io/Application` so these waves actually gate.

## 7. Argo CD projects

| Project | May deploy to | May create |
|---|---|---|
| `platform` | All namespaces | Cluster-scoped resources, CRDs, operators, every NetworkPolicy, ClusterRoleBindings |
| `plane-dev` | `plane-dev` only | Namespaced workloads and Infisical CRs. No NetworkPolicy, no cluster-scoped resources |
| `plane-prod-sim` | `plane-prod-sim` only | Same as `plane-dev` |

Both Plane environments sync automatically with self-heal. The prod-sim control point is the Git change,
not the sync button. Drills that inject failure must pause self-heal first or Argo reverts them in seconds.

## 8. Secret contract

Six Kubernetes Secrets in each Plane namespace, each produced by an `InfisicalStaticSecret`:

| Secret | Keys |
|---|---|
| `plane-app-env` | `DATABASE_URL`, `REDIS_URL`, `AMQP_URL` |
| `plane-app-keys` | `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY` |
| `plane-live-env` | `REDIS_URL` |
| `plane-doc-store` | `USE_MINIO=1`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME=uploads`, `AWS_S3_ENDPOINT_URL=http://plane-minio:9000`, `FILE_SIZE_LIMIT=5242880` |
| `plane-pgdb` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| `plane-rabbitmq` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` |

Hard rules, each learned from reading upstream code:

- The rendered manifests contain **zero `kind: Secret`**. CI enforces it.
- The bucket is `uploads` in both environments. Any other name breaks export links (`export_task.py`). Isolation
  comes from each environment having its own Silo.
- Passwords are hex. The chart does not URL-encode them into connection strings.
- `FILE_SIZE_LIMIT` is bytes. `5MB` crashes Django at import.
- **Never rotate `SECRET_KEY`.** It derives the key for 7 encrypted config rows and `decrypt_data` fails silently to `""`.
- Each environment has its own Infisical project, machine identity (built-in `viewer`), and org role `no-access`.
  Custom roles and folder RBAC are paid features, so per-project isolation is the free-tier boundary.
- Secret zero (Infisical's `ENCRYPTION_KEY`, `AUTH_SECRET`, DB password) lives only in `.local/secret-zero/`, mode 0600.

## 9. Data services

Per environment, from chart 1.8.6 with digests overridden:

| Service | Image | Digest |
|---|---|---|
| PostgreSQL | `postgres:15.19-alpine` | `sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984` |
| Valkey | `valkey/valkey:7.2.15-alpine` | `sha256:f8c1a646f4b31ae4dc3980ff06723a20b533ea1123b9796d450d78ed53ad6d3e` |
| RabbitMQ | `rabbitmq:3.13.7-management-alpine` | `sha256:606d8c0d6b3c18d1da9afc53bc7cdb2a8d5486df91b5a9830e9e07626c9ae281` |
| Silo (MinIO fork) | `pgsty/silo:RELEASE.2026-10-26T00-00-00Z-distroless` | `sha256:e6544a902f426f2b4e775b89f3c1cd78310dbffc262d1ed82e9800c1cb1b5885` |

- RabbitMQ must stay on 3.13 or 4.2. On 4.3 Celery attaches 0 consumers (upstream chart PR #304). It needs
  `vm_memory_high_watermark.absolute = 256Mi` in `conf.d`.
- Official MinIO images no longer pull anonymously (repo archived). Silo is the fork upstream Plane itself pins.
  It speaks the same S3 API and uses the same data format. Documentation says "MinIO-compatible (Silo)" and explains this.
- PVs use kind's default `standard` class on the Docker VM volume, not VirtioFS. Backups go to `/backups`, which is host-mounted.

## 10. Memory budget per workload

Requests and limits in MiB. Change these only with a measurement.

| Workload | Req | Limit | | Workload | Req | Limit |
|---|---:|---:|---|---|---:|---:|
| web | 16 | 64 | | worker (`CELERY_WORKER_CONCURRENCY=2`) | 256 | 768 |
| admin | 16 | 64 | | beat | 128 | 256 |
| space | 96 | 256 | | postgres | 128 | 512 |
| live | 128 | 384 | | valkey | 16 | 96 |
| api (1 gunicorn worker) | 256 | 768 | | rabbitmq | 128 | 512 |
| silo | 256 | 512 | | | | |

Bring the two environments up serially. Simultaneous first boots are the worst case for memory.

## 11. Make interface

`make setup up status test logs backup restore down` plus `destroy`, `render`, `promote`, `rollback`, `rotate`,
`ci`, `images`, `gitops-publish`, `drill-*`. `make help` lists them.

- `make down` stops the cluster and **keeps all data**. `make up` resumes it.
- `make destroy` deletes the cluster, refuses without `CONFIRM=yes`, and takes a backup unless `SKIP_BACKUP=yes`.
- `make restore` refuses to overwrite a non-empty environment without `CONFIRM=yes`.
- Every script checks free host disk through `guard_disk`, because the Docker VM cannot see the real limit.

## 12. Evidence rule

A claim in the docs needs evidence in `docs/evidence/`, captured from a real run with its date and command. Results are
labelled **PASS**, **FAIL**, **BLOCKED** or **NOT RUN**. A number with no measurement behind it must say "estimate".
No secrets, tokens or passwords in evidence files.

## 13. Repository layout and directory owners

```text
apps/wayline/                  branding: pinned-source patches, overlay, codemod, Dockerfiles
infrastructure/kind/           cluster template, containerd mirror config
infrastructure/local-services/ registry, pull-through caches, git daemon (Compose)
infrastructure/terraform/      modules/{foundation,argocd}, environments/{local,dev,prod}
helm/plane/                    vendor/ (byte-identical chart), components/hardening, overlays/{dev,prod-sim}
helm/values/                   values for every platform chart, one file per chart
gitops/bootstrap/              root Application source (applied by Terraform)
gitops/applications/           Application manifests; the root app syncs this directory
gitops/platform/               plain manifests owned by the platform project (network-policies, backup-storage)
gitops/environments/           rendered Plane manifests: {dev,prod-sim}/manifests.yaml. Generated, never hand-edited
infisical/                     Terraform root for Infisical config, plus docs
monitoring/                    dashboards, rules, blackbox config, alert sink (manifests/ is a Kustomize root)
policy/                        conftest rules
tests/                         e2e smoke, drills, load test
scripts/                       entry points behind make targets; scripts/lib/common.sh is sourced by all
docs/                          adr/, runbooks/, evidence/
.github/workflows/             thin workflows that call the same scripts as make targets
```

Image digests for a Plane environment live in `helm/plane/overlays/<env>/kustomization.yaml` under `images:`.
`make promote` edits them and re-renders; nothing else writes those lines.

The root app also includes `backup-storage` (wave -10), pointing at `gitops/platform/backup-storage`: a static hostPath PV
per environment on `/backups`, `Retain`, plus a PVC in each Plane namespace, so backup pods mount only a PVC and stay
PSA-compatible.
