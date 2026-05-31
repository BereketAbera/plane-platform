# Platform contract

The single source of truth for names, ownership, and ordering. Every layer of the platform
conforms to this file. If code and this file disagree, one of them is a bug.

Decisions with a "why" live in [`docs/adr/`](adr/). This file only states what is true. It was last reconciled against the
code on 2026-11-05, and [section 14](#14-changes-to-this-contract) lists what that changed. Whether something works is in
[validation.md](validation.md), not here.

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
| Host-only state | `.local/` (gitignored): `kubeconfig`, `kind-cluster.yaml`, `git/`, `backups/`, `secret-zero/`, `terraform/`, `rendered/`, `evidence-raw/`, `evidence-scrub-values`, `restore-clean.state`, `test-accounts.env`, `test-sentinel-<env>.json`, `kubeconform-schemas/`, `trivy-cache/`. Build output goes to `.build/`, also gitignored |

## 2. Namespaces

Terraform creates every namespace below. Argo CD never creates one (`CreateNamespace=false`). Test scripts create throwaway
namespaces, `gate-checks` and `netpol-sentinel-<time>`, and delete them when they finish.

| Namespace | Purpose | PSA enforce | PSA warn/audit |
|---|---|---|---|
| `argocd` | Argo CD | `baseline` | `restricted` |
| `traefik` | Ingress | `baseline` | `restricted` |
| `monitoring` | Prometheus, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics, blackbox exporter, alert sink | `baseline` | `restricted` |
| `monitoring-agents` | node-exporter only (`hostNetwork`, `hostPID`) | `privileged` | `restricted` |
| `infisical` | Infisical server and its dedicated Postgres and Redis | `baseline` | `restricted` |
| `plane-dev` | Dev environment: Plane, its secrets operator, postgres-exporter, redis-exporter | `baseline` | `restricted` |
| `plane-prod-sim` | Production simulation: the same set | `baseline`, tighten only after a per-workload non-root test passes. That test has passed, and the label has not moved. See below | `restricted` |

Every Plane namespace carries label `plane-platform/environment: dev|prod-sim`. All namespaces in
this table carry `plane-platform/managed-by: terraform`.

Exporters run in the Plane namespaces, not `monitoring`, because postgres-exporter reads that environment's `plane-pgdb`
Secret and each sits beside the data it reads. Application `monitoring-extras` deploys them from
`monitoring/manifests/environments/base/exporters.yaml`, and the quota in section 10 counts them.

The non-root condition on `plane-prod-sim` was met on 2026-11-04, on upstream images: each container ran as its configured
UID, and a server-side dry run of `enforce=restricted` gave no warnings
([plane-prod-sim-host-and-identity-1.txt](evidence/runs/plane-prod-sim-host-and-identity-1.txt),
[plane-dev-psa-1.txt](evidence/runs/plane-dev-psa-1.txt)). Moving the label is a Terraform change that nobody has made.

metrics-server is the one platform workload outside this table. It runs in `kube-system`, which kubeadm
creates, so Terraform does not create or label it. That namespace also holds kind's own CoreDNS, kindnet
and kube-proxy, so its NetworkPolicy selects only the metrics-server pod, with no namespace default-deny.

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

**Node network.** Docker assigns the `kind` network a free `/16` that differs per machine (`172.24.0.0/16` on the
machine this was built on), so NetworkPolicies never pin it. They use Docker's default pool, `172.16.0.0/12`, for
node-sourced traffic: API server on 6443, the Git remote on 9418, and NodePort traffic reaching Traefik.
`scripts/cluster-up.sh` fails if the network falls outside that range.

`172.16.0.0/12` is also the measured source of a browser's request. On 2026-11-04 conntrack on the node showed NodePort traffic
arriving from `172.24.0.1`, the kind gateway, and with that block removed a request from the host timed out
([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)). So `192.168.65.0/24`, which `traefik-ingress`
also allowed until then, was removed in `2d77243`.

**Internal UIs.** The five hosts that are not Plane's carry Middleware `node-network-only`: an `ipAllowList` of exactly
`172.16.0.0/12` with no `ipStrategy`, so Traefik reads the socket address and not a header. Traefik refuses a Middleware from
another namespace, so `monitoring`, `argocd` and `infisical` each hold a copy. A pod arrives from `10.244.0.0/16` and gets 403.
`policy/plane.rego` refuses a route to these hosts that does not name the Middleware, or a Middleware of that name that admits
anything else. `tests/routes/internal-routes.sh` runs both sides. This is a source-address check, not a login.

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
| **Argo CD** | Everything else in the cluster: Traefik, metrics-server (in `kube-system`), NetworkPolicies, monitoring, Infisical server, operators, both Plane environments | Namespaces, itself |
| **Helm** | Renders charts. It is a packaging format here, not an owner. Nothing is `helm install`ed by hand | |
| **Infisical** | Secret values and their rotation history | Kubernetes objects (the operator materialises them) |
| **Scripts** via `.local/secret-zero/` | The only secrets that exist before Infisical does. One more after it is live: `scripts/infisical-bootstrap.sh` writes Secret `plane-infisical-identity` in each Plane namespace (section 8) | Any other secret once Infisical is live |

Rule: if `git grep` finds the same resource under two owners, it is a bug. CI checks this.

## 5. Git, images, and delivery

- **Argo CD source:** `git://plane-git/plane-platform.git`, branch `main`. `plane-git` is a read-only
  container on the `kind` Docker network serving the bare repo at `.local/git/plane-platform.git`. The only
  writer is `make gitops-publish`, which pushes from the working repo to that path.
- **GitHub** (`origin`, private `BereketAbera/plane-platform`) runs CI. Argo CD does not read it in Pass 1.
- **Branded images:** `localhost:5001/wayline/{web,admin,space,backend}`, always referenced `@sha256:` by digest.
  `kind load` is forbidden: it cannot work with this host's containerd image store (kind #3795). `plane-dev` has run them
  since promotion `4f622e3` on 2026-11-05. `plane-prod-sim` runs upstream's until it is promoted. `live` stays upstream's in both.
- **Upstream images:** by index digest from `docker.io`, never `artifacts.plane.so`. Pulls go through
  the pull-through caches declared in `infrastructure/kind/containerd-certs.d/`.
- **Plane manifests are rendered and committed.** `helm/plane/` holds the Kustomize overlay over the vendored
  chart. `make render` writes `gitops/environments/{dev,prod-sim}/manifests.yaml`. Argo CD syncs those plain
  manifests with no Helm or Kustomize at sync time. CI fails if rendering produces a diff.
- **Platform charts** (Traefik, monitoring, Infisical): Argo CD Helm sources, exact chart versions, values from
  `helm/values/` via a `$values` ref.
- **Promotion:** `make promote ENV=dev` or `make promote ENV=prod-sim`. Prod-sim accepts only a digest recorded for dev under
  the same image (`scripts/ci/check-promoted-digests.sh`), refuses unless `plane-dev` is Synced and Healthy with that digest in a
  ready container (`scripts/lib/dev-check.sh`), and takes a Postgres dump first. `make gitops-publish` asks the same of a prod-sim
  digest that arrives through a merged pull request. `OVERRIDE_DEV_CHECK="<reason>"` goes past the `plane-dev` check and is logged,
  `SKIP_BACKUP=yes` skips the dump, and with no cluster in reach the check is skipped and the commit message says so.
- **Rollback:** `make rollback ENV=<env>` is a `git revert` and a publish with `SKIP_BACKUP=yes` and `SKIP_DEV_CHECK`, so it needs
  neither a healthy `plane-dev` nor a working backup. Prod-sim gets one best-effort dump first, limited to 300s. Images roll back,
  and schemas do not.

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
| 4 | Ingress routes and their Middlewares |

Root app-of-apps, in order:

| Wave | What |
|---|---|
| -10 | `network-policies`, `backup-storage` |
| -9 | `traefik` |
| -8 | `metrics-server`, and root's second source `gitops/bootstrap/argocd-route`: IngressRoute `argocd-server` and Middleware `node-network-only` |
| -7 | `kube-prometheus-stack` |
| -6 | `loki`, `alloy` |
| -5 | `monitoring-extras` |
| -4 | `infisical`, with waves of its own: ServiceAccount -2, Postgres and Redis -1, server 0, route and Middleware 1 |
| -3 | `infisical-operator-dev`, `infisical-operator-prod-sim` |
| -1 | `plane-dev` |
| 0 | `plane-prod-sim` |

`postgres-exporter` carries `argocd.argoproj.io/ignore-healthcheck`, because `monitoring-extras` syncs at -5 and its Secret
`plane-pgdb` does not appear until -1.

`argocd-cm` carries these health overrides (`resource.customizations.health.*` in `helm/values/argocd.yaml`), and the first is what
makes the root waves gate:

| Kind | Why | What it reads |
|---|---|---|
| `argoproj.io/Application` | Argo CD removed this check in 1.8, and its own aggregation skips hooks and resources not created yet, so a child would read Healthy between its internal waves | Healthy only with health Healthy, no `.operation` in flight, and sync status Synced. A child that stays OutOfSync therefore holds every later wave |
| `monitoring.coreos.com/Prometheus` | The built-in check reads `NoPodReady` as Degraded, which is every Prometheus start, and that failed root's sync on the first boot | Not-ready pods read Progressing, so the wave waits. `Reconciled: False` stays Degraded. The cost is that a Prometheus that can never start also reads Progressing, and root waits on it with no retry |
| `secrets.infisical.com/InfisicalStaticSecret` | `status.error` means something only at the current generation | Healthy or Degraded once `observedGeneration` matches, Progressing before that |
| `secrets.infisical.com/InfisicalAuth`, `InfisicalConnection` | They carry only a condition | Follows `IsReady` at the current generation |

Root and every child retry without limit, with `refresh: true`. A Degraded child fails root's sync and the retry reads the newest
commit. A child in any other state holds root in `Running` with no retry, so a fix to an Application manifest then needs root's
operation terminated (`infrastructure/terraform/README.md`).

The waves order the sync, and nothing more. Root's own operation ends right after it applies wave 0, without
waiting for `plane-prod-sim`, and `plane-dev` stays Degraded until `scripts/infisical-bootstrap.sh` publishes
its identity Secret. So readiness is never read from root: `make up` waits for Traefik, then Infisical, and only
after the bootstrap for all 14 Applications, each Synced and Healthy.

**Rollout settings.** Set in `helm/plane/components/hardening` for both environments:

- `progressDeadlineSeconds: 600` on all seven Deployments. Image pulls count against it and the kubelet pulls one image at a time,
  so on a cold mirror the last pod of wave 3 started 448s in ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)).
  The earlier value, 360, failed web, admin and space on that first boot and held the sync until a retry. That event was read live
  and is not in a saved file. 600 stays above the longest startup budget, 300s.
- `preStop: {sleep: {seconds: 5}}` on web, admin, space, live and api. A pod gets SIGTERM as its endpoint starts to go, and Traefik
  reacts about 2s later. Without the pause a rollout failed 10 of 2,757 samples, and with it 0 of 5,902 across two rollouts
  ([before](evidence/runs/plane-dev-rollout-availability-1.txt), [after](evidence/runs/plane-dev-rollout-availability-2.txt)).

## 7. Argo CD projects

| Project | May deploy to | May create |
|---|---|---|
| `platform` | All namespaces | Cluster-scoped resources, CRDs, operators, every NetworkPolicy, ClusterRoleBindings |
| `plane-dev` | `plane-dev` only | Namespaced workloads and Infisical CRs. No NetworkPolicy, no cluster-scoped resources |
| `plane-prod-sim` | `plane-prod-sim` only | Same as `plane-dev` |

`policy/gitops.rego` refuses a Plane Application under any other project, any Application under project `default` or none, and
rendered manifests of an environment under any project but its own. That check runs in CI, and nothing makes it block a merge on
this GitHub plan.

Both Plane environments sync automatically with self-heal. The prod-sim control point is the Git change,
not the sync button. Drills that inject failure must pause self-heal first or Argo reverts them in seconds.

## 8. Secret contract

Six Kubernetes Secrets in each Plane namespace, each produced by an `InfisicalStaticSecret`, and a seventh that holds no secret value:

| Secret | Keys |
|---|---|
| `plane-app-env` | `DATABASE_URL`, `REDIS_URL`, `AMQP_URL` |
| `plane-app-keys` | `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY` |
| `plane-live-env` | `REDIS_URL` |
| `plane-doc-store` | `USE_MINIO=1`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME=uploads`, `AWS_S3_ENDPOINT_URL=http://plane-minio:9000`, `FILE_SIZE_LIMIT=5242880` |
| `plane-pgdb` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| `plane-rabbitmq` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` |
| `plane-infisical-identity` | `identityId`. Written by `scripts/infisical-bootstrap.sh`, not the operator, because the id changes on every re-bootstrap and the CRD accepts only a Secret reference. It is not a credential: login also needs a ServiceAccount token |

Hard rules, each learned from reading upstream code:

- The rendered manifests contain **zero `kind: Secret`**. CI enforces it.
- The bucket is `uploads` in both environments. Any other name breaks export links (`export_task.py`). Isolation
  comes from each environment having its own Silo.
- Passwords are hex. The chart does not URL-encode them into connection strings.
- `FILE_SIZE_LIMIT` is bytes. `5MB` crashes Django at import.
- **Never rotate `SECRET_KEY`.** It derives the key for 7 encrypted config rows and `decrypt_data` fails silently to `""`.
- Each environment has its own Infisical project, machine identity (built-in `viewer`), and org role `no-access`.
  Custom roles and folder RBAC are paid features, so per-project isolation is the free-tier boundary.
- Secret zero (Infisical's `ENCRYPTION_KEY`, `AUTH_SECRET`, database and Redis passwords) lives in `.local/secret-zero/`, mode 0600,
  and in the cluster Secrets `scripts/secret-zero.sh` makes from it.

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
- Official MinIO images no longer pull anonymously (repo archived). Silo is the fork upstream Plane itself uses.
  It speaks the same S3 API and uses the same data format. Documentation says "MinIO-compatible (Silo)" and explains this.
- The Silo pin is this repository's, not upstream's. Chart 1.8.6 and upstream's compose pair Plane v1.4.3 with
  `RELEASE.2026-09-16T00-00-00Z`, and the digest above is the newer distroless `RELEASE.2026-10-26T00-00-00Z-distroless`.
  [ADR 0005](adr/0005-minio-compatible-silo.md) has the reasoning and the fallback.
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

Terraform turns this budget into a `ResourceQuota/plane-budget` in each Plane namespace (`modules/foundation/main.tf`). Deployments
count twice, because a rolling update surges one extra pod each and a quota that fits only the steady state fails the rollout:

| Resource | Hard limit | How derived |
|---|---:|---|
| `requests.memory` | 2732Mi | 2 x 896 for Deployments, 528 for StatefulSets, 412 for extras |
| `limits.memory` | 7984Mi | 2 x 2560 for Deployments, 1632 for StatefulSets, 1232 for extras |
| `pods` | 24 | 2 x 7 Deployments, 4 StatefulSets, 6 extras |
| `persistentvolumeclaims` | 6 | 4 StatefulSets, the backup PVC, one spare for restore drills |

Extras, request and limit in MiB: secrets operator 64/128, postgres-exporter 16/48, redis-exporter 12/32, migrator 128/512, backup
Job 128/256, one ad-hoc pod 64/256. There is no CPU line, because the budget has no CPU and a CPU quota would reject any pod that
omits a request. `LimitRange/plane-defaults` sets a default limit of 256Mi, a default request of 64Mi, and a maximum of 1Gi per container.

The quota does not fit every Deployment, exporters included, surging at once with the migrator, a backup and an ad-hoc pod: that
is 26 pods, 2760Mi and 8064Mi ([quota-budget-1.txt](evidence/runs/quota-budget-1.txt)). All seven Plane Deployments surging together
reached 21 of 24 pods with no `FailedCreate` ([plane-dev-rollout-quota-1.txt](evidence/runs/plane-dev-rollout-quota-1.txt)).

## 11. Make interface

`make setup up status test logs backup restore down` plus `destroy`, `render`, `promote`, `rollback`, `rotate`, `restore-clean`,
`ci`, `images`, `gitops-publish`, `gates`, `test-e2e`, `test-netpol`, `test-alert`, `test-load`, `scan-images`, `publish-evidence`,
`drill-failed-deploy`, `drill-pod-restart`, `drill-clean-restore`, `wayline-upgrade-check`, `wayline-upstream-check`.
`make help` lists them. Options are passed as `make <target> NAME=value`.

- `make down` stops the cluster and **keeps all data**. `make up` resumes it.
- `make up` is idempotent, so it is also how to continue after a failure. It refuses uncommitted changes under
  `gitops/`, `helm/`, `monitoring/` and `infisical/`, because Argo CD reads only commits.
  `UP_STOP_AFTER=<cluster|publish|terraform|secret-zero|traefik|infisical>` stops it after that step.
- `make test` keeps going after a failure and labels each test PASS, FAIL or BLOCKED. `scripts/test.sh` exits 0,
  1 or 2 for those, as `tests/e2e/smoke.py` does. `make` itself exits 2 on any failure, and prints which.
- `make destroy` deletes the cluster, refuses without `CONFIRM=yes`, and takes a backup unless `SKIP_BACKUP=yes`. It removes
  `.local/terraform/local` and keeps backups, secret zero and `.local/terraform/infisical`, because a clean restore needs them.
  `PURGE=yes` also removes the local services and their volumes.
- `make restore` refuses to overwrite a non-empty environment without `CONFIRM=yes`. `make restore-clean` brings the whole platform
  back into a clean environment, Infisical first.
- Scripts that write to the cluster, a registry or the disk check free host disk through `guard_disk`, because the Docker VM
  cannot see the real limit. The default is 10 GiB (`MIN_FREE_DISK_GIB`). `up.sh` asks for 25 and `cluster-up.sh` for 15 when
  creating a cluster, `scan-images.sh` for 15, and scripts that write little ask for 1 or 2, such as `promote.sh`, `rollback.sh`
  and `gitops-publish.sh`.
  `down.sh`, `destroy.sh`, `logs.sh`, `status.sh`, `copy-to-local-registry.sh` and the CI checks do not call it, so the first four
  still work on a full disk. `destroy.sh` reaches it through `backup.sh` unless `SKIP_BACKUP=yes`. `prereqs.sh` has its own floor of 25 GiB.

## 12. Evidence rule

A claim in the docs needs evidence in `docs/evidence/`, captured from a real run with its date and command. Results are
labelled **PASS**, **FAIL**, **BLOCKED** or **NOT RUN**. A number with no measurement behind it must say "estimate".
No secrets, tokens or passwords in evidence files. Scripts write raw output to `.local/evidence-raw/`, and
`make publish-evidence` copies it to `docs/evidence/runs/` with secret values scrubbed and fails on any gitleaks finding.

## 13. Repository layout and directory owners

```text
apps/wayline/                  branding: pinned-source patches, overlay, codemod, Dockerfiles
infrastructure/kind/           cluster template, containerd mirror config
infrastructure/local-services/ registry, pull-through caches, git daemon (Compose)
infrastructure/terraform/      modules/{foundation,argocd}, environments/local. environments/{dev,prod} are interface documents
helm/plane/                    vendor/ (byte-identical chart), components/hardening, overlays/{dev,prod-sim}
helm/values/                   values for every platform chart, one file per chart
gitops/bootstrap/              root Application source (applied by Terraform)
gitops/applications/           Application manifests; the root app syncs this directory
gitops/platform/               plain manifests owned by the platform project (network-policies, backup-storage)
gitops/environments/           rendered Plane manifests: {dev,prod-sim}/manifests.yaml. Generated, never hand-edited
infisical/                     Terraform root for Infisical config, plus docs
monitoring/                    dashboards, rules, blackbox config, alert sink (manifests/ is a Kustomize root)
policy/                        conftest rules
tests/                         e2e/ smoke, gates/ day-1, drills/, load/, routes/ internal UIs, separation/ between environments,
                               rules/ promtool unit tests, network-policy-matrix.yaml
scripts/                       entry points behind make targets; scripts/lib/common.sh is sourced by nearly all, scripts/ci/ holds CI's
docs/                          adr/, runbooks/, evidence/{runs,ci,security,branding}
.github/workflows/             thin workflows that call the same scripts as make targets
```

Image digests for a Plane environment live in `helm/plane/overlays/<env>/kustomization.yaml` under `images:`.
`make promote` edits them and re-renders; nothing else writes those lines.

The root app also includes `backup-storage` (wave -10), pointing at `gitops/platform/backup-storage`: a static hostPath PV
on `/backups/<name>`, `Retain`, for each of `dev`, `prod-sim` and `infisical` (`backups-dev`, `backups-prod-sim`,
`backups-infisical`), plus a PVC named `backups` in each of those three namespaces, so backup pods mount only a PVC and
stay PSA-compatible.

## 14. Changes to this contract

Each line settles a place where the code and this file disagreed, by changing this file to match the code. Times in commits are
+0300, so the UTC dates below can read a day earlier than `git log`.

| Date of the change in code | Section | Now true | Where |
|---|---|---|---|
| 2026-11-04 | 2 | Exporters run in the Plane namespaces, and metrics-server in `kube-system`. The code always did this | `monitoring/manifests/environments/base/exporters.yaml`, `gitops/applications/metrics-server.yaml` |
| 2026-11-04 | 3 | `172.16.0.0/12` is the measured NodePort source, and `192.168.65.0/24` is gone | `2d77243`, [traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt) |
| 2026-11-04 | 3 | `node-network-only` on the five internal UIs | `fee3947`, [routes-after-3.txt](evidence/runs/routes-after-3.txt) |
| 2026-11-04 | 4, 8 | A seventh Secret, `plane-infisical-identity`, written by a script. The code always did this | `scripts/infisical-bootstrap.sh`, [infisical-rendered-secrets-2.txt](evidence/runs/infisical-rendered-secrets-2.txt) |
| 2026-11-04 | 5 | Prod-sim also needs `plane-dev` to have proven the digest, recorded under the same image | `3a67ba0`, `scripts/lib/dev-check.sh`, `scripts/ci/check-promoted-digests.sh` |
| 2026-11-04 | 6 | The whole root wave list, including root's second source | `gitops/applications/*.yaml`, `gitops/bootstrap/argocd-route/ingressroute.yaml` |
| 2026-11-04 | 6 | Application health needs no `.operation` and Synced, and root retries with `refresh: true` | `615e97c`, [argocd-wave-gating-1.txt](evidence/runs/argocd-wave-gating-1.txt) |
| 2026-11-04 | 6 | A Prometheus with no ready pod reads Progressing | `40403db`, [h43-lua-runtime-1.txt](evidence/runs/h43-lua-runtime-1.txt) |
| 2026-11-04 | 6 | `progressDeadlineSeconds: 600`, was 360 | `4b33f75` |
| 2026-11-04 | 6 | `preStop` sleep of 5s on the five Deployments behind a Service | `2aefba1` |
| 2026-11-04 | 7 | A policy rule holds each Plane Application to its own project | `b19fe26`, `policy/gitops.rego` |
| 2026-11-04 | 9 | The Silo pin is newer than upstream's. The code always did this | `helm/plane/overlays/*/kustomization.yaml`, [ADR 0005](adr/0005-minio-compatible-silo.md) |
| 2026-11-04 | 10 | Quota 2732Mi, 7984Mi, 24 pods, with the exporters budgeted. It was 2704Mi, 7904Mi, 22 pods | `bc8bb91`, [quota-budget-1.txt](evidence/runs/quota-budget-1.txt) |
| 2026-11-05 | 11 | `guard_disk` is not in every script, on purpose, and the target list is complete | `scripts/`, `Makefile` |
