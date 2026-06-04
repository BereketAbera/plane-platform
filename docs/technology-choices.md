# Technology choices

Every item in the stack, its pinned version, why it is here, what else was considered, and what the choice costs.

Versions are read from the repository: `tools.lock`, `helm/values/`, `gitops/applications/`, `infrastructure/`, and the contract. Where a tool has a digest, the code pins it. This page leaves digests out, so a version bump changes fewer places.

**Limits of this page.** "Alternatives" lists only what research or the code actually weighed. Where the owner's brief fixed the tool, it says so, and no comparison was made. Size and memory figures are estimates unless a link to evidence is given. Where a run bears on a choice this page links it, and the test status is in [validation.md](validation.md).

## How versions were chosen

- **Exact pins, no floating tags.** Container images by digest, charts by exact version, CLIs by checksum in `tools.lock`, Terraform providers by version plus `.terraform.lock.hcl`, GitHub Actions by commit SHA.
- **Kubernetes sets the ceiling.** v1.36 is the highest minor that Argo CD 3.5 lists as tested (1.33 to 1.36).
- **No uniform soak rule.** Argo CD 3.6 was rejected for being one or two days old at selection, while kube-prometheus-stack 92.18.0 and Infisical v0.167.6 were taken within a day or so of release. The research critique flagged this inconsistency (C28). It is unresolved, and it is a known weakness of these pins.
- **Reading source is not running it.** Most compatibility statements below came from upstream source and chart templates at the pinned tag. Running them on 2026-11-04 corrected several, and [the ADRs](adr/README.md) record those under "What we found when we ran it".

## Application

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Plane Community Edition | v1.4.3, commit `37a15d99` | Fixed by the brief. Open source, self-hostable, and has enough services (three frontends, API, worker, beat, live, four data stores) to exercise a platform | None evaluated | AGPL-3.0 obligations ([agpl-compliance.md](agpl-compliance.md)). Upstream images are not built for restricted pods: the backend image has no `USER`, so the hardening patches must supply UIDs |
| Chart `plane-ce` | 1.8.6, appVersion 1.4.3, vendored byte-identical in `helm/plane/vendor/` | The upstream chart matches this release, and it already supports `existingSecret` for all six Secrets | Hand-written manifests would drift from upstream | Kustomize patches sit on someone else's templates. A `remove` of a path the chart stops rendering fails, which is the intended alarm on upgrade |
| Wayline branding | `apps/wayline/`, built from `ec45e21`, images `localhost:5001/wayline/{web,admin,space,backend}` | A thin patch layer on pinned source for the frontends, and a derived image for the backend, flattened since `5adbc78`. As built, 86 files are patched, +311 -500 lines, and 155 replaced whole, nearly all images. Research's estimate of about 20 files was far too low | Post-build only: can recolour but not restructure. Full fork: carries about 5,000 tracked files for no benefit | Patches must be rebased on each upgrade. `live` stays upstream, so PDF export colours are unbranded |

Branding is delivered to `plane-dev` since promotion `4f622e3` and to `plane-prod-sim` since `0af8956`, both on 2026-11-05, and both run the final build ([running pods](evidence/runs/cluster-readings-2.txt), [digests](evidence/branding/digests.tsv)). The one browser session was earlier, in dev ([live-dev](evidence/branding/live-dev/README.md)).

## Cluster and local services

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| kind | v0.33.0 | Fixed by the brief. Real upstream Kubernetes in one Docker container | None evaluated | One node. kind sets `imageGCHighThresholdPercent: 100` and eviction thresholds of `0%`, so there is no disk protection. A full disk means write errors, not evictions |
| Kubernetes | v1.36.4 | Highest minor covered by Argo CD 3.5 and the other components | v1.37.0, kind's default, is outside Argo CD 3.5's tested range | Not the newest |
| Who creates the cluster | kind CLI through `scripts/cluster-up.sh` | First-party, no state for a throwaway cluster, and a stopped node does not break `terraform plan` | Community Terraform provider `tehcyx/kind` in a separate root | Terraform does not own the whole lifecycle. A config change means delete and recreate |
| kindnet | Bundled with kind v0.33.0 | Enforces NetworkPolicy through `kube-network-policies`, with no extra pods | Calico, at more memory, if the gate failed | **Fails open with only a log line**, which an alert now watches. Evaluates new connections only. Root sockets on the node skip it. Tests must use new connections and assert deny by timeout |
| Storage | kind's `standard` class on the Docker VM volume | Keeps Postgres off VirtioFS, and data-loss drills lose data for real | Host-mounted `local-retain` class: survives cluster deletion, but a new PVC reattaches the old directory, which makes drills meaningless | PVs die with the cluster. Backups go to `/backups`, which is host-mounted. The provisioner ignores PVC size |
| Registry and pull-through caches | `distribution` 3.1.2 from GHCR | Must outlive the cluster. Taken from GHCR so setup does not spend Docker Hub quota. The Docker cache fronts `mirror.gcr.io` | `kind load`: reported to fail on this host's containerd image store (kind #3795), and not reproduced here, because nothing calls it. Authenticated Docker Hub mirror | Extra containers and disk. `mirror.gcr.io` does not hold every blob, so `hosts.toml` falls through to Docker Hub. `plane-registry` was OOM-killed at 128m by the page cache of a push, so its limit is 512m ([registry-memory-1.txt](evidence/runs/registry-memory-1.txt)) |
| Git remote for Argo CD | `git daemon` on Alpine 3.22, in Compose | Offline, no credentials, no state to reseed, read-only by construction | Soft Serve: archived and sunset. Gitea: stateful and heavier. GitHub directly: fails offline. A pod with a host path: PSA `baseline` forbids it | No web UI or webhooks, so Argo CD polls. `make gitops-publish` is a manual step |
| Hostnames | `*.localhost` | Resolves to loopback offline, no sudo, supports wildcards | `*.localtest.me`, `*.nip.io`: need public DNS. `/etc/hosts`: needs sudo and has no wildcards | The API dials its own public host, so CoreDNS needs a rewrite. Bare-loopback names are unusual for non-browser tools |

Safari's handling of `*.localhost` was not settled by research. Chromium signed in on `plane.dev.localhost` on 2026-11-05 ([live-dev](evidence/branding/live-dev/README.md)), and cookies carry no `Domain`, so a dev session gets 401 on the prod-sim host ([plane-dev-cookies-1.txt](evidence/runs/plane-dev-cookies-1.txt)). Safari, Firefox, and both hosts open at once have not been tried. [[VERIFY: log in to both Plane hosts at once in Safari, Chrome, and Firefox; cookies stay separate]]

## Provisioning and packaging

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Terraform | 1.17.1 | Fixed by the brief. BUSL-1.1 does not restrict this private use | OpenTofu: its one concrete attraction is state encryption | Non-open-source licence. State is local and unencrypted, under gitignored `.local/terraform/` |
| Provider `hashicorp/kubernetes` | 3.4.0 | Namespaces, quotas, LimitRanges, the CoreDNS key | `kubernetes_manifest` for the root Application: needs the CRD at plan time, which fails on an empty cluster | Deleting `kubernetes_config_map_v1_data` removes the whole `Corefile` key. Delete the cluster after a `terraform destroy` |
| Provider `hashicorp/helm` | 3.3.0 | Installs Argo CD and the bootstrap chart | Argo CD chart's `extraObjects`: fails with "no matches for kind", because the chart ships CRDs as ordinary templates | Research found it still built on the Helm 3 SDK, which leaves security support on 2026-11-11. Accepted, for installing two charts |
| Provider `infisical/infisical` | 0.20.10 | Projects, identities, Kubernetes Auth as code | Scripts against the API | Separate root and state, because the provider needs a running Infisical. Secret values stay out of state: scripts or `*_wo` attributes only |
| Helm CLI | v4.3.1 | Renders the Plane chart and lints. Helm 3 security support ends 2026-11-11 | Helm 3 | Argo CD v3.5.7 bundles Helm 4.2.1, so CI and Argo CD render platform charts with different versions |
| Kustomize | v5.8.3 | Patches a vendored chart without forking it. Components run after generators, so patches see the chart's output | Argo CD running `kustomize --enable-helm` at sync: exposed to open regression argo-cd#30215, which appears only at manifest regeneration | Generated YAML is committed, so diffs are large. CI must catch drift. A patch target matching nothing does not fail, so `render.sh` asserts key rules itself |

## GitOps and delivery

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Argo CD | v3.5.7, chart `argo-cd` 10.11.7 | Fixed by the brief. Lean install: one replica each, no Dex, notifications, or ApplicationSet | v3.6.1: too new at selection. Self-managed Argo CD: a bad sync can remove the controller applying the fix | Upgrades go through Terraform, not GitOps. `server.insecure: true`, since nothing terminates TLS. Single controller for both environments, whose peak of 731 MiB moved its limit to 1024Mi ([argo-controller-limit-1.txt](evidence/runs/argo-controller-limit-1.txt)) |
| Rendered manifests for Plane | `scripts/render.sh` | Reviewable YAML, no Helm in the Plane sync path | Argo CD Helm source for Plane | Two delivery styles in one repo: rendered for Plane, Helm source for platform charts |
| Promotion | Scripts plus pull requests: `scripts/promote.sh`, `promote-prod-sim.yml` | No memory cost, works the same locally and in CI, and the digest and approval are visible in Git history | Argo CD Image Updater: its digest strategy follows a mutable tag. Kargo: needs cert-manager, and its default config is documented as for trying it locally. Argo Rollouts: not worth it on one node | No canary or progressive delivery. Gate strength depends on the person. See [environments.md](environments.md#the-promotion-model) |
| GitHub Actions | Pinned by SHA in `.github/workflows/` | Fixed by the brief. Thin wrappers over the same scripts `make` runs, so there is one implementation | | GitHub Free on a private repo: no required reviewers, no protected branches, no code owners, no attestations. `ubuntu-24.04-arm` does run here, billed against included compute ([ci evidence](evidence/ci/README.md)) |
| GHCR | | Where CI can push. The cluster pulls from `localhost:5001`, so digests are copied, not rebuilt | | The quota is documented, not measured: GitHub's billing page lists 500 MB for Packages on Free, and also says container image storage and bandwidth are currently free. Nothing has been pushed. The four Wayline images sum to 432 MiB compressed in the local registry, so shared layers count twice ([sizes.txt](evidence/branding/sizes.txt)). Pruning stays as a precaution |

## Secrets

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Infisical | v0.167.6, chart `infisical-standalone` 1.12.0 | Fixed by the brief. Runs in the cluster, so NetworkPolicy, RBAC, and limits apply to it, and it shares a lifecycle with the data it protects | Compose beside the cluster: survives teardown but has no NetworkPolicy and a second lifecycle. No Infisical: the emergency path, since the `existingSecret` interface does not change | A heavy pod for one user: 1Gi limit, 822 MiB peak ([infisical-second-boot-1.txt](evidence/runs/infisical-second-boot-1.txt)). Free tier has no custom roles, no native rotation, no dynamic secrets, and no audit log retention. `ALLOW_INTERNAL_IP_CONNECTIONS=true` relaxes SSRF protection globally |
| Secrets operator | 0.11.16, CRDs `InfisicalStaticSecret`, `InfisicalAuth`, `InfisicalConnection` `v1beta1` | The `v1beta1` CRDs split connection, auth, and secret, and health can be gated per object | `InfisicalSecret` `v1alpha1`: deprecated. One cluster-wide operator: can mint a token for any ServiceAccount and read every Secret | Two releases cost memory. CRDs are cluster-scoped, and one release must own them: `infisical-operator-dev`. See [environments.md](environments.md#what-is-shared) |
| Machine auth | Kubernetes Auth, client JWT as reviewer | No long-lived credential anywhere | Universal Auth: fallback, needs a stored client secret | `plane-infisical-auth` holds `system:auth-delegator`, a cluster-scoped grant. The token audience is unrestricted |
| Infisical Postgres | `postgres:16.15-alpine` | Dedicated, so Plane data and secret data have separate lifecycles | Chart's bundled Bitnami subcharts: frozen legacy images with default passwords | One more database to back up. Must be restored as a matched set with `ENCRYPTION_KEY` |
| Infisical Redis | `redis:7.2.17-alpine` | The documented path | Valkey, with an image saving under 20 MB | Plane uses Valkey and Infisical uses Redis, so two images do the same job |

The free tier's role model isolates the two projects at runtime. On 2026-11-04 each machine identity got 403 on the other project, in both directions, on list, single read and slug lookup ([infisical-isolation-3.txt](evidence/runs/infisical-isolation-3.txt)).

## Ingress

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Traefik | v3.7.17, chart 42.3.0 | The Plane chart's default and native path: renders `IngressRoute` and a body-limit Middleware. Also has a design for external TLS termination in Pass 2 | ingress-nginx: archived. Traefik with plain `Ingress`: drops the body limit. Gateway API: chart has no `HTTPRoute`, so 8 hand-maintained routes | `IngressRoute` is Traefik-specific. One pod serves both environments and every UI |

## Data services (per environment)

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| PostgreSQL | `postgres:15.19-alpine` | Chart's major version, with the patch bumped | CloudNativePG 1.30.1: backups and failover that one node cannot use, plus an operator | Single instance, no replicas, no PITR. Backups are `pg_dump` |
| Valkey | `valkey/valkey:7.2.15-alpine` | What the chart deploys | | No password (chart issue 113). NetworkPolicy is the only access control |
| RabbitMQ | `rabbitmq:3.13.7-management-alpine` | Stays on 3.13 because Celery attaches 0 consumers on 4.3 (upstream chart PR #304). Absolute watermark of 256Mi in `conf.d`, because the default relative one can misjudge a cgroup limit | 4.2.9: a candidate for dev, untested with CE. 4.3.x: rejected | **3.13 is an end-of-life series, accepted as a risk.** Management image is larger than the lean one. Management port stays closed |
| MinIO-compatible store (Silo) | `pgsty/silo:RELEASE.2026-10-26T00-00-00Z-distroless` | Official MinIO images no longer pull anonymously and the repo is archived. Silo is the fork upstream Plane itself pins. Same S3 API, same data format, and `MINIO_*` variables retained | Bitnami legacy image: frozen and older. Building MinIO from source: own pipeline for frozen code. AIStor Free: unclear terms. Garage, SeaweedFS: not evaluated, kept as an exit | Effectively one lead maintainer. Upstream's own pin is `RELEASE.2026-09-16`, so the code runs a newer release than upstream's pair. Distroless image defaults to UID 0, so the hardening patch sets UID 1000 |
| Bucket name | `uploads`, in both environments | `export_task.py` hardcodes the path, so any other name breaks export links | `plane-dev-uploads`: rejected by reading the code | Isolation depends on separate Silo instances, not bucket names |

The patch-level bumps of Postgres, Valkey, and RabbitMQ over the chart's defaults run with Plane v1.4.3: 164 migrations applied on the first boot ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)), and `make test-e2e` drives api and worker on 15.19, 7.2.15, and 3.13.7 in both environments ([dev](evidence/runs/smoke-dev-20261105T001213Z.json), [prod-sim](evidence/runs/smoke-prod-sim-20261104T235926Z.json)). That shows the paths the smoke walks, not every feature.

Uploads, avatars, and exports work on the distroless Silo release with no bucket Job. Steps `attachment-upload`, `object-in-silo`, `avatar` and `export` pass in the same runs.

## Observability

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| kube-prometheus-stack | Chart 92.18.0 | One chart for Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, and the operator | | Large. Most control-plane scrapes are off to save series |
| Prometheus | v3.15.1-distroless | 30s scrape, `retention: 3d`, `retentionSize: 1GiB` | | The provisioner ignores PVC size, so `retentionSize` is the only real cap. Shared by both environments |
| Alertmanager | v0.34.2 | Needed to prove alert delivery end to end | Off, to save memory | A local sink is the only receiver. No page reaches a person |
| Grafana | 13.3.0-distroless | Dashboards from Git through the sidecar, no persistence | | The chart regenerates the admin password on every render, because Argo CD renders with no `lookup`. See the ignore rule in `kube-prometheus-stack.yaml` |
| prometheus-operator, config reloader | v0.94.2 | Part of the stack. Admission webhooks off, so no cert Job and no certgen image | Webhooks on: rejects bad rules at admission, at the cost of a Job and an image | A bad rule is not rejected at admission. CI runs `promtool` over the rules and their unit tests instead, in `scripts/ci/validate-manifests.sh`, which has run only on this Mac so far |
| kube-state-metrics | v2.20.0 | Pod and restart state for alerts | | |
| node-exporter | v1.12.1 | Node metrics. Confined to `monitoring-agents`, so `monitoring` can stay at `baseline` | In `monitoring`, which would force the whole namespace to `privileged` | A privileged namespace exists on the shared node |
| metrics-server | v0.9.1, chart 3.14.0 | `kubectl top` and `make status`. `--kubelet-insecure-tls` because kind's kubelet certificates are self-signed | | Insecure kubelet TLS, acceptable only on a local node |
| Loki | 3.7.9, chart 20.4.1 from `grafana-community` | Monolithic mode on the filesystem. 72h retention | `grafana.github.io` chart: that index has been the Enterprise chart since 2026-03-16. Promtail: end of life | 640Mi limit is well below the chart's own example. It held under a stress test at about 700 times the idle rate, with peak anon at 553 MiB and no OOM kill ([monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt)). Raise it first on an OOM kill |
| Alloy | v1.21.3-distroless, chart 1.15.0 | Deployment reading logs through the Kubernetes API: no root, no host path, no privileged namespace | DaemonSet tailing `/var/log/pods`: the fallback, in `monitoring-agents` | More load on the API server and kubelet. Positions in an `emptyDir`, so a new pod re-reads each log. Over one replacement no line was lost or duplicated ([monitoring-alloy-restart-1.txt](evidence/runs/monitoring-alloy-restart-1.txt)), while an in-place restart loses Alloy's counters |
| blackbox-exporter | v0.29.1 | Probes go through Traefik, so a failed probe matches a failed user request | Only pod-level health | Probes consume Plane's anonymous rate limit, so intervals are bounded |
| postgres_exporter | v0.20.1 | Reads the existing `plane-pgdb` Secret, so no new Infisical path or permission | A `pg_monitor` role: needs a bootstrap step and a rotation path nobody owns yet | Connects as a superuser. Pass 2 improvement |
| redis_exporter | v1.96.0 | Holds no credentials, since Valkey has no password | v1.97: too new at selection | |
| Alert sink | `python:3.13.18-alpine` running `monitoring/manifests/shared/sink.py` | Can show delivery with no third party | Slack or email: would add an external dependency | Not a notification system |

On 2026-11-04 a second Alloy on the same 53 log streams added 6 to 40 MiB to API server RSS and about 20 MiB to the kubelet's, with CPU inside the noise from other work ([monitoring-alloy-apiserver-cost-1.txt](evidence/runs/monitoring-alloy-apiserver-cost-1.txt)). That is one more Alloy, not one against none. Staying on the API path is a judgment from that, and no run has compared it with the fallback. [[MEASURE: API server and kubelet load from loki.source.kubernetes at full pod count]]

## CI, policy, and test tooling

| Item | Version | Why | Tradeoff |
|---|---|---|---|
| conftest | v0.71.1 | Contract rules as Rego in `policy/`: digest pins on Plane and on platform charts, no Secrets, no `PreSync`, bucket name, Silo route, a Plane Application's project, route hosts, the allow list on internal routes, no Bitnami | Checks what it can see in files. It has no view of runtime or of objects applied by hand |
| promtool | v3.15.1 | Checks the alert rules and runs their unit tests in `tests/rules/` | Unit tests feed made-up series, so they do not prove a rule fires on the real one |
| kubeconform | v0.8.0 | Schema validation of rendered manifests, including CRDs from a catalog | Static only |
| gitleaks | v8.30.1 | Secret scanning in CI | `.gitleaks.toml` allowlists image tags that look like secrets |
| trivy | v0.76.1 | Config and filesystem scan in `make ci`, and image scan in `make scan-images` ([results](evidence/security/README.md)) | Exceptions live in `.trivyignore`, and each is a decision to review. The image scan reads no ignore file, and fails only on a fixable CRITICAL in an image built here |
| actionlint, zizmor | v1.7.12, v1.32.0 | Workflow correctness and security | |
| shellcheck, hadolint, tflint | v0.11.0, v2.15.1, v0.65.0 | Lint scripts, Dockerfiles, Terraform | |
| yq | v4.53.2 | Reads and edits YAML in scripts | |
| k6 | v2.3.0 | Load test as a Job, with session auth to measure what the web app actually sends | Runs inside the cluster, so it skips Docker Desktop's port mapping. Not a test of a browser's path |
| curl, busybox | `curlimages/curl:8.17.0`, `busybox:1.37.0` | Short-lived probe pods for the NetworkPolicy matrix | |
| rclone | `rclone/rclone:1.75.2` | Copies Silo data in the backup Job | |
| Plain `git` plus scripts | | Rollback by `git revert`, so Git stays the source of truth | Slower than a button, on purpose |

The Argo CD CLI is not in `tools.lock`, and `infrastructure/terraform/README.md` uses `kubectl` instead. Install a matching v3.5.7 by hand if you want it.

## Deliberately not used in Pass 1

| Item | Why not | When it might return |
|---|---|---|
| cert-manager | Nothing terminates TLS locally | Optional in Pass 2, since Cloudflare terminates at the edge |
| CloudNativePG | Failover and backup features with one node to run on | Pass 2 candidate for prod |
| Gateway API | The Plane chart has no `HTTPRoute` | When upstream ships it |
| Bitnami charts and images | Current chart defaults point at tags that no longer exist | Not planned |
| ingress-nginx | Archived | Not planned |
| Argo Rollouts, Image Updater, Kargo | Cost more than they return with two stages on one node | Reconsider with three or more stages |

## Footprint

All of this has to fit in one Docker VM. Research produced an estimate of 5.5 to 9.3 GiB of workload memory idle for two environments. It was derived from a few host measurements, a third-party figure for Plane v1.4.2, and per-workload guesses, and it is not a measurement of this deployment.

Measured on 2026-11-05 at 00:03 UTC, with both environments running on upstream images and nothing under test, by `kubectl top`, in MiB: node 8,331; `kube-system` 1,563; `monitoring` 1,555; `plane-dev` 1,246; `plane-prod-sim` 1,174; `infisical` 770; `argocd` 404; `traefik` 60 ([snapshot](evidence/runs/plane-prod-sim-snapshot-final-1.txt)). VM use was 9.43 GiB of 13.63, of which about 1 GiB was the owner's unrelated containers. Its peak was 10.49 GiB during test runs ([memory](evidence/runs/plane-prod-sim-memory-1.txt)). No load test has run, so this is not a peak under load, and peaks have been read for the VM and per container, not per namespace. [Resource utilization](resource-utilization.md) has the rest. [[MEASURE: idle and peak memory by namespace, recorded in docs/resource-utilization.md]]

[[MEASURE: disk growth on the VM and the host after a full make up]]
