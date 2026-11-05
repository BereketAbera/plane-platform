# Technology choices

Every item in the stack, its pinned version, why it is here, what else was considered, and what the choice costs.

Versions are read from the repository: `tools.lock`, `helm/values/`, `gitops/applications/`, `infrastructure/`, and the contract. Where a tool has a digest, the code pins it. This page leaves digests out, so a version bump changes fewer places.

**Limits of this page.** "Alternatives" lists only what research or the code actually weighed. "Research" means the notes written before the build, with the cross-check `CRITIQUE.md` among them. They stayed in the build's working notes and are not committed, so a reader cannot open them, and a statement resting on them alone has no evidence in `docs/evidence/`. Where the owner's brief fixed the tool, it says so, and no comparison was made. Size and memory figures are estimates unless a link to evidence is given. Where a run bears on a choice this page links it, and the test status is in [validation.md](validation.md).

## How versions were chosen

- **Exact pins, no floating tags.** Container images by digest, charts by exact version, CLIs by checksum in `tools.lock`, Terraform providers by version plus `.terraform.lock.hcl`, GitHub Actions by commit SHA.
- **Kubernetes sets the ceiling.** v1.36 is the highest minor that Argo CD 3.5 lists as tested (1.33 to 1.36).
- **No uniform soak rule.** Argo CD 3.6 was rejected for being one or two days old at selection, while kube-prometheus-stack 92.18.0 and Infisical v0.167.6 were taken within a day or so of release. The research cross-check listed this as item C28, which reads "Inconsistent" and says "Pick one rule". Nobody has picked one, and it is a known weakness of these pins.
- **Reading source is not running it.** Most compatibility statements below came from upstream source and chart templates at the pinned tag. Running them on 2026-11-04 corrected several, and [the ADRs](adr/README.md) record those under "What we found when we ran it".

## Application

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Plane Community Edition | v1.4.3, commit `37a15d99` | Fixed by the brief. Open source, self-hostable, and has enough services (three frontends, API, worker, beat, live, four data stores) to exercise a platform | None evaluated | AGPL-3.0 obligations ([agpl-compliance.md](agpl-compliance.md)). Upstream images are not built for restricted pods: the backend image has no `USER`, so the hardening patches must supply UIDs |
| Chart `plane-ce` | 1.8.6, appVersion 1.4.3, vendored byte-identical in `helm/plane/vendor/` | The upstream chart matches this release, and it already supports `existingSecret` for all six Secrets | Hand-written manifests would drift from upstream | Kustomize patches sit on someone else's templates. A `remove` of a path the chart stops rendering fails, which is the intended alarm on upgrade |
| Wayline branding | `apps/wayline/`, built from `84b63d9`, images `localhost:5001/wayline/{web,admin,space,backend}` | A thin patch layer on pinned source for the frontends, and a derived image for the backend, flattened since `5adbc78`. As built, 86 files are patched, +311 -500 lines, and 155 replaced whole, nearly all images. Research's estimate of about 20 files was far too low | Post-build only: can recolour but not restructure. Full fork: carries about 5,000 tracked files for no benefit | Patches must be rebased on each upgrade. `live` stays upstream, so PDF export colours are unbranded |

Branding is delivered to `plane-dev` since promotion `4f622e3` and to `plane-prod-sim` since `0af8956`, both on 2026-11-05. Both now run the final build, since `1fc9fbe` and `9c8e098`, with the backend flattened and cache headers on the HTML ([digests](evidence/branding/digests.tsv), [FINAL-state-20261105T062807Z.txt](evidence/runs/FINAL-state-20261105T062807Z.txt)). The one full browser session was on an earlier build, in dev ([live-dev](evidence/branding/live-dev/README.md)). On the final images, after a full restore, a real browser signed in on both hosts and opened a published board on dev ([live-final](evidence/branding/live-final/README.md)). On the final images, in dev, real Chromium tabs held one page open for about 5 minutes and came through a restart of `live` ([RT-2b-RT-3](evidence/runs/RT-2b-RT-3-20261105T073208Z.txt)). The source link answers 404 to outsiders while the repository stays private ([BR-3](evidence/runs/BR-3-20261105T054812Z.txt)).

One choice in that build has no person's review behind it. AI agents replaced the backend's `email.py` with upstream's AGPL version and flattened the image. The owner, Bereket Abera, was told and has not reviewed it, and no legal review happened. See [agpl-compliance.md](agpl-compliance.md).

### Owner decisions still open

Only the owner can settle these, and none is recorded as settled. [The handoff](../PASS2_HANDOFF.md#owner-decisions-still-open) has the detail.

| Decision | Where it stands |
|---|---|
| D12, the `email.py` header | The replacement above stands unreviewed |
| D16, the licence for platform code | The root `LICENSE` is upstream's AGPL-3.0 text, new files under `apps/wayline/` carry `AGPL-3.0-only`, and nearly all the scripts and manifests carry no header |
| D17, two GitHub Apps with access to the repository | `netlify` and `builder-io-integration`, inferred from their check suites on pushed commits. What each installation covers could not be read |
| Whether to rename Wayline | No trademark search has run on the name ([agpl-compliance.md](agpl-compliance.md)) |
| D10, a public repository for `/source` | It needs one before anyone else uses an instance. Its target answers 404 to outsiders today |

## Cluster and local services

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| kind | v0.33.0 | Fixed by the brief. Real upstream Kubernetes in one Docker container | None evaluated | One node. kind sets `imageGCHighThresholdPercent: 100` and eviction thresholds of `0%`, so there is no disk protection. A full disk means write errors, not evictions |
| Kubernetes | v1.36.4 | Highest minor covered by Argo CD 3.5 and the other components | v1.37.0, kind's default, is outside Argo CD 3.5's tested range | Not the newest |
| Who creates the cluster | kind CLI through `scripts/cluster-up.sh` | First-party, no state for a throwaway cluster, and no Terraform kind resource whose `Read` errors on a stopped node. Root `local`'s plan still needs a running cluster | Community Terraform provider `tehcyx/kind` in a separate root | Terraform does not own the whole lifecycle. A config change means delete and recreate |
| kindnet | Bundled with kind v0.33.0 | Enforces NetworkPolicy through `kube-network-policies`, with no extra pods | Calico, at more memory, if the gate failed | **Fails open with only a log line**, which an alert now watches. Evaluates new connections only. Root sockets on the node skip it. Tests must use new connections and assert deny by timeout |
| Storage | kind's `standard` class on the Docker VM volume | Keeps Postgres off VirtioFS, and data-loss drills lose data for real | Host-mounted `local-retain` class: survives cluster deletion, but a new PVC reattaches the old directory, which makes drills meaningless | PVs die with the cluster. Backups go to `/backups`, which is host-mounted. The provisioner ignores PVC size |
| Registry and pull-through caches | `distribution` 3.1.2 from GHCR | Must outlive the cluster. Taken from GHCR so setup does not spend Docker Hub quota. The Docker cache fronts `mirror.gcr.io` | `kind load`: reported to fail on this host's containerd image store (kind #3795), and not reproduced here, because nothing calls it. Authenticated Docker Hub mirror | Extra containers and disk. `mirror.gcr.io` does not hold every blob, so `hosts.toml` falls through to Docker Hub. `plane-registry` was OOM-killed at 128m by the page cache of a push, so its limit is 512m ([registry-memory-1.txt](evidence/runs/registry-memory-1.txt)) |
| Git remote for Argo CD | `git daemon` on Alpine 3.22, in Compose | Offline, no credentials, no state to reseed, read-only by construction | Soft Serve: archived and sunset. Gitea: stateful and heavier. GitHub directly: fails offline. A pod with a host path: PSA `baseline` forbids it | No web UI or webhooks, so Argo CD polls. `make gitops-publish` is a manual step |
| Hostnames | `*.localhost` | Resolves to loopback offline, no sudo, supports wildcards | `*.localtest.me`, `*.nip.io`: need public DNS. `/etc/hosts`: needs sudo and has no wildcards | The API dials its own public host, so CoreDNS needs a rewrite. Bare-loopback names are unusual for non-browser tools |

Safari's handling of `*.localhost` was not settled by research. Chromium signed in on `plane.dev.localhost` on 2026-11-05 ([live-dev](evidence/branding/live-dev/README.md)), and cookies carry no `Domain`, so a dev session gets 401 on the prod-sim host ([plane-dev-cookies-1.txt](evidence/runs/plane-dev-cookies-1.txt)). One Chromium profile with a tab on each host showed the same on 2026-11-05 ([AUTH-4-20261105T062750Z.txt](evidence/runs/AUTH-4-20261105T062750Z.txt)). After the restore, one browser signed in on both hosts, and each tab's `GET /api/users/me/` answered 200 at 08:38:18 UTC ([live-final](evidence/branding/live-final/README.md)). Safari and Firefox: not tested in Pass 1.

## Provisioning and packaging

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Terraform | 1.17.1 | Fixed by the brief. BUSL-1.1 does not restrict this private use | OpenTofu: its one concrete attraction is state encryption | Non-open-source licence. State is local and unencrypted, under gitignored `.local/terraform/` |
| Provider `hashicorp/kubernetes` | 3.4.0 | Namespaces, quotas, LimitRanges, the CoreDNS key | `kubernetes_manifest` for the root Application: needs the CRD at plan time, which fails on an empty cluster | Deleting `kubernetes_config_map_v1_data` removes the whole `Corefile` key. Delete the cluster after a `terraform destroy` |
| Provider `hashicorp/helm` | 3.3.0 | Installs Argo CD and the bootstrap chart | Argo CD chart's `extraObjects`: fails with "no matches for kind", because the chart ships CRDs as ordinary templates | Research read `helm.sh/helm/v3 v3.20.2` in its `go.mod`. That is the Helm 3 SDK, which leaves security support on 2026-11-11 ([Helm](https://helm.sh/blog/helm-4-released/)). Nobody is recorded as accepting that. It stays because this provider installs only two charts |
| Provider `infisical/infisical` | 0.20.10 | Projects, identities, Kubernetes Auth as code | Scripts against the API | Separate root and state, because the provider needs a running Infisical. Secret values stay out of state: scripts or `*_wo` attributes only |
| Helm CLI | v4.3.1 | Renders the Plane chart and lints. Helm 3 security support ends 2026-11-11 | Helm 3 | Argo CD v3.5.7 bundles Helm 4.2.1, so CI and Argo CD render platform charts with different versions |
| Kustomize | v5.8.3 | Patches a vendored chart without forking it. Components run after generators, so patches see the chart's output | Argo CD running `kustomize --enable-helm` at sync: exposed to open regression argo-cd#30215, which appears only at manifest regeneration | Generated YAML is committed, so diffs are large. CI must catch drift. A patch target matching nothing does not fail, so `render.sh` asserts key rules itself |

## GitOps and delivery

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| Argo CD | v3.5.7, chart `argo-cd` 10.11.7 | Fixed by the brief. Lean install: one replica each, no Dex, notifications, or ApplicationSet | v3.6.1: too new at selection. Self-managed Argo CD: a bad sync can remove the controller applying the fix | Upgrades go through Terraform, not GitOps. `server.insecure: true`, since nothing terminates TLS. Single controller for both environments, whose peak of 731 MiB moved its limit to 1024Mi ([argo-controller-limit-1.txt](evidence/runs/argo-controller-limit-1.txt)) |
| Rendered manifests for Plane | `scripts/render.sh` | Reviewable YAML, no Helm in the Plane sync path | Argo CD Helm source for Plane | Two delivery styles in one repo: rendered for Plane, Helm source for platform charts |
| Promotion | Scripts plus pull requests: `scripts/promote.sh`, `promote-prod-sim.yml` | No memory cost, works the same locally and in CI, and the digest and approval are visible in Git history | Argo CD Image Updater: its digest strategy follows a mutable tag. Kargo: needs cert-manager, and its default config is documented as for trying it locally. Argo Rollouts: not worth it on one node | No canary or progressive delivery. Gate strength depends on the person. See [environments.md](environments.md#the-promotion-model) |
| GitHub Actions | Pinned by SHA in `.github/workflows/` | Fixed by the brief. Thin wrappers over the same scripts `make` runs, so there is one implementation | | GitHub Free on a private repo: no required reviewers, no protected branches, no code owners, no attestations. `ubuntu-24.04-arm` built all four images here on 2026-11-05, billed against included compute ([ci evidence](evidence/ci/README.md)) |
| GHCR | | Where CI can push. The cluster pulls from `localhost:5001`, so digests are copied, not rebuilt | | The quota is documented, not measured: GitHub's billing page lists 500 MB for Packages on Free, and also says container image storage and bandwidth are currently free. `images.yml` published four private packages on 2026-11-05, holding 401.8 MiB at the first build with each distinct layer counted once, and November's usage summary showed no packages row after that. Run 42044273310 added a second build, whose total no file here reads ([ci evidence](evidence/ci/README.md)). Nothing has met the limit. Their digests are not the ones the cluster runs, since the cluster runs the local build. Pruning stays as a precaution, and the prune job has listed versions and deleted none |

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
| PostgreSQL | `postgres:15.19-alpine` | Chart's major version, with the patch bumped | CloudNativePG 1.30.1: backups and failover that one node cannot use, plus an operator | Single instance, no replicas, no PITR. Backups are `pg_dump`. Its 500 m CPU limit, set here, is what bound in `make test-load` with no think time ([resource-utilization.md](resource-utilization.md#load-results-dev)) |
| Valkey | `valkey/valkey:7.2.15-alpine` | What the chart deploys | | No password (chart issue 113). NetworkPolicy is the only access control |
| RabbitMQ | `rabbitmq:3.13.7-management-alpine` | Stays on 3.13 because Celery attaches 0 consumers on 4.3 (upstream chart PR #304). Absolute watermark of 256Mi in `conf.d`, because the default relative one can misjudge a cgroup limit | 4.2.9: a candidate for dev, untested with CE. 4.3.x: rejected | **3.13 is an end-of-life series, in force for Pass 1 with no owner decision recorded ([ADR 0016](adr/0016-datastore-versions.md)).** Management image is larger than the lean one. Management port stays closed |
| MinIO-compatible store (Silo) | `pgsty/silo:RELEASE.2026-10-26T00-00-00Z-distroless` | Official MinIO images no longer pull anonymously and the repo is archived. Silo is the fork upstream Plane itself pins. Same S3 API, same data format, and `MINIO_*` variables retained | Bitnami legacy image: frozen and older. Building MinIO from source: own pipeline for frozen code. AIStor Free: unclear terms. Garage, SeaweedFS: not evaluated, kept as an exit | Effectively one lead maintainer. Upstream's own pin is `RELEASE.2026-09-16`, so the code runs a newer release than upstream's pair. Distroless image defaults to UID 0, so the hardening patch sets UID 1000 |
| Bucket name | `uploads`, in both environments | `export_task.py` hardcodes the path, so any other name breaks export links | `plane-dev-uploads`: rejected by reading the code | Isolation depends on separate Silo instances, not bucket names |

The patch-level bumps of Postgres, Valkey, and RabbitMQ over the chart's defaults run with Plane v1.4.3: 164 migrations applied on the first boot ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)), and `make test-e2e` drives api and worker on 15.19, 7.2.15, and 3.13.7 in both environments ([dev](evidence/runs/smoke-dev-20261105T001213Z.json), [prod-sim](evidence/runs/smoke-prod-sim-20261104T235926Z.json)), and again on the final images ([smoke-dev-20261105T070735Z-94252.json](evidence/runs/smoke-dev-20261105T070735Z-94252.json), [smoke-prod-sim-20261105T053533Z-8468.json](evidence/runs/smoke-prod-sim-20261105T053533Z-8468.json)), and after a full restore ([dev](evidence/runs/smoke-dev-20261105T083455Z-37296.json), [prod-sim](evidence/runs/smoke-prod-sim-20261105T083455Z-37296.json)). That shows the paths the smoke walks, not every feature.

Uploads, avatars, and exports work on the distroless Silo release with no bucket Job. Steps `attachment-upload`, `object-in-silo`, `avatar` and `export` pass in the same runs.

## Observability

| Item | Version | Why | Alternatives | Tradeoff |
|---|---|---|---|---|
| kube-prometheus-stack | Chart 92.18.0 | One chart for Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, and the operator | | Large. Most control-plane scrapes are off to save series |
| Prometheus | v3.15.1-distroless | 30s scrape, `retention: 3d`, `retentionSize: 1GiB` | | The provisioner ignores PVC size, so `retentionSize` is the only real cap. Shared by both environments |
| Alertmanager | v0.34.2 | Needed to prove alert delivery end to end | Off, to save memory | A local sink is the only receiver. No page reaches a person |
| Grafana | 13.3.0-distroless | Dashboards from Git through the sidecar, no persistence | | The chart regenerates the admin password on every render, because Argo CD renders with no `lookup`. See the ignore rule in `kube-prometheus-stack.yaml` |
| prometheus-operator, config reloader | v0.94.2 | Part of the stack. Admission webhooks off, so no cert Job and no certgen image | Webhooks on: rejects bad rules at admission, at the cost of a Job and an image | A bad rule is not rejected at admission. CI runs `promtool` over the rules and their unit tests instead, in `scripts/ci/validate-manifests.sh`, which has run on real runners since `9c8e098` ([ci evidence](evidence/ci/README.md)) |
| kube-state-metrics | v2.20.0 | Pod and restart state for alerts | | |
| node-exporter | v1.12.1 | Node metrics. Confined to `monitoring-agents`, so `monitoring` can stay at `baseline` | In `monitoring`, which would force the whole namespace to `privileged` | A privileged namespace exists on the shared node |
| metrics-server | v0.9.1, chart 3.14.0 | `kubectl top` and `make status`. `--kubelet-insecure-tls` because kind's kubelet certificates are self-signed | | Insecure kubelet TLS, acceptable only on a local node |
| Loki | 3.7.9, chart 20.4.1 from `grafana-community` | Monolithic mode on the filesystem. 72h retention | `grafana.github.io` chart: that index has been the Enterprise chart since 2026-03-16. Promtail: end of life | 640Mi limit is well below the chart's own example. It held under a stress test of 3.5 MB/s of synthetic pushes, 624 times the mean ingest and 40 times the busiest 5 minutes ([alert-text-figures-1.txt](evidence/runs/alert-text-figures-1.txt)), with peak anon at 553 MiB, no OOM kill and the median query up to about 19s ([monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt)). That multiple is not a margin on anon memory, which does not follow ingest. Raise it first on an OOM kill |
| Alloy | v1.21.3-distroless, chart 1.15.0 | Deployment reading logs through the Kubernetes API: no root, no host path, no privileged namespace | DaemonSet tailing `/var/log/pods`: the fallback, in `monitoring-agents` | More load on the API server and kubelet. Positions in an `emptyDir`, so a new pod re-reads each log. Over one replacement no line was lost or duplicated ([monitoring-alloy-restart-1.txt](evidence/runs/monitoring-alloy-restart-1.txt)), while an in-place restart loses Alloy's counters |
| blackbox-exporter | v0.29.1 | Probes go through Traefik, so a failed probe matches a failed user request | Only pod-level health | Probes consume Plane's anonymous rate limit, so intervals are bounded |
| postgres_exporter | v0.20.1 | Reads the existing `plane-pgdb` Secret, so no new Infisical path or permission | A `pg_monitor` role: needs a bootstrap step and a rotation path nobody owns yet | Connects as a superuser. Pass 2 improvement |
| redis_exporter | v1.96.0 | Holds no credentials, since Valkey has no password | v1.97: too new at selection | |
| Alert sink | `python:3.13.18-alpine` running `monitoring/manifests/shared/sink.py` | Can show delivery with no third party | Slack or email: would add an external dependency | Not a notification system |

On 2026-11-04 a second Alloy on the same 53 log streams added 6 to 40 MiB to API server RSS and about 20 MiB to the kubelet's, with CPU inside the noise from other work ([monitoring-alloy-apiserver-cost-1.txt](evidence/runs/monitoring-alloy-apiserver-cost-1.txt)). That is one more Alloy, not one against none. Staying on the API path is a judgment from that. Alloy's share of API server and kubelet load at full pod count, and a comparison with the fallback: not tested in Pass 1. For scale, `kubectl top` read the API server at 1,221 MiB at 07:44 UTC on 2026-11-05, with Alloy running ([LOAD-3 host](evidence/runs/LOAD-3-20261105T074440Z-host.txt)).

## CI, policy, and test tooling

| Item | Version | Why | Tradeoff |
|---|---|---|---|
| conftest | v0.71.1 | Contract rules as Rego in `policy/`: digest pins on Plane and on platform charts, no Secrets, no `PreSync`, bucket name, Silo route, a Plane Application's project, route hosts, the allow list on internal routes, no Bitnami, no document that wraps others | Checks what it can see in files. It has no view of runtime or of objects applied by hand |
| promtool | v3.15.1 | Checks the alert rules and runs their unit tests in `tests/rules/` | Unit tests feed made-up series, so they do not prove a rule fires on the real one. `PlaneRabbitmqDown` and `PlaneMinioDown` were such a case: with the pod gone neither fired, because `up` has no series then, which only a drill showed ([before](evidence/runs/alert-rules-dev-20261105T100605Z.txt), [after](evidence/runs/alert-rules-dev-20261105T101707Z.txt)). `tests/rules/data-services-down.test.yaml` now holds what Prometheus really held |
| kubeconform | v0.8.0 | Schema validation of rendered manifests, including CRDs from a catalog | Static only |
| gitleaks | v8.30.1 | Secret scanning in CI | `.gitleaks.toml` allowlists image tags that look like secrets |
| trivy | v0.76.1 | Config and filesystem scan in `make ci`, and image scan in `make scan-images` ([results](evidence/security/README.md)) | Exceptions live in `.trivyignore`, and each is a decision to review. The image scan reads no ignore file, and fails only on a fixable CRITICAL in an image built here, or on an image it could not scan |
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

All of this has to fit in one Docker VM. Research produced an estimate of 5.5 to 9.3 GiB of workload memory idle for two environments. It was derived from a few host measurements, a third-party figure for Plane v1.4.2, and per-workload guesses, and it is not a measurement of this deployment. [Resource utilization](resource-utilization.md#whole-platform) carries the estimates behind that total.

Measured on 2026-11-05 on a quiet cluster, on the final images restored into a new cluster, from Prometheus, in MiB, the idle average and then the top under `make test-load ENV=dev` with no think time: `plane-dev` 1,155 and 1,312; `plane-prod-sim` 1,082 and 1,146; `kube-system` 1,199 and 1,306; `monitoring` 1,018 and 1,062; `infisical` 710 and 735; `argocd` 461 and 562; `traefik` 51 and 56. All pods averaged 5,703 MiB idle and topped out at 6,103. The VM read 8.65 GiB of 13.63 idle and peaked at 9.05 GiB, and that holds the owner's other containers ([windows](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json), [derived](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)).

The limit that bound under that load was CPU, not memory: Postgres's 500 m, with requests flat by 5 virtual users at about 8.9 a second, while the VM never had more than 2.49 of its 12 CPUs busy. That cluster was young, so Prometheus and Loki held little history. On the earlier cluster, with other work on it, the VM peaked at 10.93 GiB at 01:50 UTC ([timeline](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). This is one laptop with both environments on one node, and it says nothing about a server. [Resource utilization](resource-utilization.md#the-load-window) has the rest, and the earlier run on a busy machine.

Disk was read on the running platform on 2026-11-05 at 02:01 UTC. The kind node's volume held 12.94 GiB by `du`, the four local-service volumes 3.62 GiB, and the node image 1.19 GiB, which makes 17.75 GiB for a first install ([dr-disk-1.txt](evidence/runs/dr-disk-1.txt)). That is a sum of sizes while other agents were building, not a before and after of a clean install. The clean install of 2026-11-05 took host free disk from 31 GiB to 19 GiB by `df`, in whole GiB, with the registry, caches and node image already on disk ([summary.txt](evidence/runs/clean-install-20261105T075041Z/summary.txt), [make-status.txt](evidence/runs/clean-install-20261105T075041Z/make-status.txt)). The cold install, with the registry and caches removed first, took it from 31 GiB to 13 GiB, about 18 GiB, and left `Docker.raw` at 40060992 KiB, 38.21 GiB ([summary.txt](evidence/runs/clean-install-20261105T105546Z/summary.txt), [disk-after-install.txt](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). That run built its images twice, because of the umask defect below, and the second build's leftovers were still on disk, so an install with no defect: Not measured in Pass 1. `Docker.raw` around a delete: 38,276,744 KiB and 38,301,404 KiB, at the top and bottom of [the last drill's output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), and they bracket the whole drill, delete and restore, so a delete alone was not read.

The cold install found a gap in how images are built here: nothing checks that an image's own user can read its files. Under umask 077 every file in a build context was 0600, the build kept those modes, and every build step passed. Then web, admin, space and api crashed at start, with Permission denied in the logs of web, admin and api. `b4f6cc9` runs `chmod -R a+rX` on each context ([rebuild](evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt), [what it looked like](runbooks/clean-rebuild.md#the-umask-defect)). The gates walk an image for brand, leaks and scan findings, and none of them starts it as its own user, so only pods starting showed this.
