# Known limitations

This page says what the platform is not and what has not been shown. Read it before quoting anything else in these docs.

The platform is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), named Wayline, on a local kind cluster. It is local and production-inspired, and this repository makes no claim that it is ready for production.

Updated 2026-11-05 from evidence published up to 2026-11-05T00:53Z, while validation was still running. `VERIFY` and `MEASURE` markers show what a later pass must resolve against `docs/evidence/`.

## Status

[`docs/validation.md`](validation.md) is the record of what ran. It labels results PASS, FAIL, BLOCKED, or NOT RUN, per contract section 12. If a statement here and an evidence file disagree, the evidence file wins.

Plane runs on one kind cluster on one Mac. plane-dev runs the branded images, and plane-prod-sim runs upstream's, with its promotion still to come. `make test-e2e` passes in each on those images ([dev](evidence/runs/branded-dev-smoke-1.txt), [prod-sim](evidence/runs/plane-prod-sim-smoke-2.txt)).

A clean install, teardown and recreation, a full restoration, secret rotation, the failed-deploy drill, the load test and `make test-alert` have not run. The platform came up stage by stage, with prod-sim's Infisical CRs [applied by hand](evidence/runs/infisical-prod-sim-crs-1.txt), so nothing yet shows that one `make up` works from nothing. The fixes made on the way, the 600s rollout deadline (`4b33f75`) and the 5s `preStop` (`2aefba1`) among them, have not met a cold first boot.

## What real runs found

Origin says where the cause lives. **Upstream** is Plane, its chart or a library, and nothing here fixes it unless the row says so. **Ours** is this platform's code, configuration or a decision made here. **Host** is kind or Docker Desktop on this machine.

| Finding | Origin | What was seen | Evidence |
|---|---|---|---|
| React hydration errors #418 and #423 | Upstream as far as seen. Cause not found | Logged on web and space, on upstream's images in both environments and on the branded images in dev, so branding did not introduce them. They are not request failures, and the app works past them. The HTML served through Traefik is byte-identical to the file in the image. Nobody has traced them further | [dev, upstream](evidence/runs/plane-dev-browser-1.txt), [prod-sim, upstream](evidence/runs/plane-prod-sim-browser-1.txt), [dev, branded](evidence/branding/live-dev/README.md#console) |
| Page version history never records | Upstream, v1.4.3 | `track_page_version` reads `page.description`, and the model has `description_json`, so the task's exception goes to the log and no version is written. `page_versions` held 0 rows with 131 pages. Not patched here | [plane-dev-status-1.txt](evidence/runs/plane-dev-status-1.txt), `apps/api/plane/bgtasks/page_version_task.py` at the pinned commit |
| `POST` project invitations answers 500 | Upstream, v1.4.3 | The view reads `.role` off a queryset, on the base image too. Workspace invitations work. Not patched here | [backend-db.txt](evidence/branding/backend-db.txt) |
| Raw label in the sidebar's accessibility tree | Upstream | `aria_labels.app_sidebar.close_workspace_menu`, which no locale file defines. It is not visible on screen | [live-dev/README.md](evidence/branding/live-dev/README.md#text-seen) |
| A worker can consume nothing and still answer its liveness check | Upstream, Celery 5.5.3. Our smoke control set it off | `cancel_consumer` then `add_consumer` leaves an empty queue selection, so the next broker reconnect attaches no consumer while `inspect ping` still answers pong. That ping is the liveness command, so only `PlaneWorkerNoConsumer` sees it, and it did. `0bba707` replaces the worker after the control. Running those two commands by hand still does this | [plane-prod-sim-worker-broker-restart-1.txt](evidence/runs/plane-prod-sim-worker-broker-restart-1.txt), [harness-celery-selection-source-1.txt](evidence/runs/harness-celery-selection-source-1.txt), [plane-dev-worker-1.txt](evidence/runs/plane-dev-worker-1.txt), MON-7 |
| An edit still in `live`'s debounce can be lost when `live` restarts | Upstream behaviour | An update stored after the 10s debounce survived. One sent just before the pod was deleted was not on the server afterwards, and the client took 21s to reconnect. Whether an open tab sends it again is RT-3, NOT RUN | [plane-dev-live-restart-1.txt](evidence/runs/plane-dev-live-restart-1.txt) |
| Space's one server-side fetch fails | Upstream's empty API base URL, kept here | `ERR_INVALID_URL` before any connection. A public board still loads, because the browser makes those calls, and only the page's metadata is lost. A build that sets that URL would need space added to the api policy | [plane-dev-public-board-1.txt](evidence/runs/plane-dev-public-board-1.txt) |
| Upstream images carry known CVEs | Upstream | Complete scan on 2026-11-04, all targets, before the fixes to images built here: 26 CRITICAL, 600 HIGH, 837 MEDIUM. CRITICAL findings with a fix, reported only: postgres 15.19 and 16.15, rabbitmq 3.13.7, plane-backend, plane-live, plane-space, argocd v3.5.7. Infisical has 5 CRITICAL with no fix. `plane-live` runs unmodified here with proxy-addr 2.0.7. Nobody has checked whether any of these can be reached on this platform | [security/README.md](evidence/security/README.md), [critical.tsv](evidence/security/scan-images-20261104T215437Z/critical.tsv) |
| Valkey has no password | Upstream chart, accepted here | NetworkPolicy is its only control, in both environments. If kindnet fails open, nothing else stands in the way. Real attempts from the other environment time out, which is that policy working and says nothing about the server | [security.md](security.md), `REDIS_URL` as `infisical/tests/rendered-secrets.sh` expects it, [harness-separation-network-1.txt](evidence/runs/harness-separation-network-1.txt) |
| `email.py` stays in the backend image's base layer | Upstream's file, our decision | The v1.4.3 tag's `plane/utils/email.py` carries a commercial header. The derived image copies upstream's later AGPL-3.0-only file over it, pinned by commit, so a running container holds no commercially headed code. The original is still in the `FROM` layer, and anyone who pulls the image and unpacks that layer can read it. So `publish-gate.sh` allows only the local registry and private GHCR, and `images.yml` also requires a private repository. A public image is a point to take advice on. An upstream release with the AGPL header, or an image with no such layer, would end the question, and neither exists here. The agent running this build made this call, and it is for the owner to confirm. D12 in [MODIFICATIONS.md](../apps/wayline/MODIFICATIONS.md) | [email-py.txt](evidence/branding/email-py.txt), [refusals.txt](evidence/branding/refusals.txt) |
| `/source` is dead while the repository is private | Ours | The web image answers 302 to the commit it was built from, and that target answers 404 logged out. Making the repository public is not enough on its own, because `1563cbf` must also be pushed. This must be fixed before anyone else uses an instance. A PASS on the redirect shows only the redirect. BR-3 | [smoke.txt](evidence/branding/smoke.txt), [live-dev/README.md](evidence/branding/live-dev/README.md) |
| A returning browser keeps the old page after a promotion | Upstream's nginx config, carried in our images | No `Cache-Control` on HTML from web and admin, in the images deployed at `4f622e3`. The upstream sign-in page kept showing after promotion, with no error, until the cache entry was refreshed. A rollback should do the same, and has not been tried. AUTH-6 | [live-dev/README.md](evidence/branding/live-dev/README.md#the-stale-page) |
| Workspaces made before the promotion keep upstream's seed text | Ours, from how Plane seeds | Seed text is written once, so an older workspace still says "Welcome to Plane". What a fresh install registers cannot be checked until one runs: `branding-fresh-install` reads SKIP | [live-dev/README.md](evidence/branding/live-dev/README.md#text-seen), [harness-smoke-dev-2.txt](evidence/runs/harness-smoke-dev-2.txt) |
| A dev api pod can reach prod-sim's public URL | Ours. Needed for `copy_object` | `api` may reach Traefik, and Traefik routes by Host header, so it gets what any browser could: `/api/instances/` 200, `/api/users/me/` 401, a bucket listing 403. It reaches no data port. NetworkPolicy cannot see this, and the tests print it as a GAP. The same holds the other way | [routes-after-3.txt](evidence/runs/routes-after-3.txt), [harness-separation-state-1.txt](evidence/runs/harness-separation-state-1.txt) |
| The source-address allow list on internal UIs is not a login | Ours | `node-network-only` admits `172.16.0.0/12` on all five UIs, so a Plane `api` pod gets 403 and any process on the Mac gets through. A scratch pod with free egress read Prometheus through `host.docker.internal:80`, because that leaves through the Mac and comes back as the host. Plane pods time out on that door by NetworkPolicy alone, so a kindnet that fails open would open it | [routes-after-3.txt](evidence/runs/routes-after-3.txt), [h17-doors-free-egress-2.txt](evidence/runs/h17-doors-free-egress-2.txt), [monitoring/README.md](../monitoring/README.md) |
| kindnet's fail-open line is only one signal | kindnet's behaviour, our alert | `KindnetSkippedNetworkPolicies` counts one log line. kindnet discards its controller's error and is configured `FailOpen`, so any other failure says nothing. The alert has fired only on a synthetic pod. The count lives in Alloy's memory, held for 3d by the rule, and it can stick after kindnet's container restarts. `make test-netpol` sends real traffic and is the real check, and only when someone runs it | [h18-synthetic-2.txt](evidence/runs/h18-synthetic-2.txt), [kindnet-hold-1.txt](evidence/runs/kindnet-hold-1.txt), [monitoring/README.md](../monitoring/README.md) |
| Two failures stay quiet for a long time, or for good | Ours | A commit that cannot render reads sync Unknown and never retries, and the cluster stays on the old commit. `ArgoAppSyncUnknown` fires after 15m. A Prometheus that cannot start reads Progressing, so root waits with no retry, nothing evaluates rules, Watchdog stops reaching the sink, and nothing watches for that | [argo-sync-unknown-1.txt](evidence/runs/argo-sync-unknown-1.txt), [h43-repro-after-1.txt](evidence/runs/h43-repro-after-1.txt) |
| Infisical restarts cost a short outage | Upstream behaviour | With Redis down the API does not answer for about 12s. With Postgres down, reads answer 500 for about 6s. Rendered Secrets did not change | [infisical-restart-1.txt](evidence/runs/infisical-restart-1.txt) |
| Alerts go pending on a healthy system | Host | `PrometheusMissingRuleEvaluations` goes pending because the Docker VM steps its wall clock. It has not fired, and stays on. `CPUThrottlingHigh` goes pending on Plane pods during restarts and rollouts | [missing-rule-evaluations-1.txt](evidence/runs/missing-rule-evaluations-1.txt), [cpu-throttling-1.txt](evidence/runs/cpu-throttling-1.txt) |
| Some monitoring reads empty or errors here | Host and chart | `kubelet_volume_stats` has no series on kind, so the Persistent Volumes dashboard is empty. Grafana's health call on the Alertmanager datasource answers 500 "Plugin unavailable", though its proxy call works | [monitoring-dashboards-all-1.txt](evidence/runs/monitoring-dashboards-all-1.txt), [monitoring-grafana-login-1.txt](evidence/runs/monitoring-grafana-login-1.txt) |
| The databases hold test data | Ours | Each full smoke leaves a workspace and a throwaway user, and tests pushed synthetic lines into Loki, which go at 72h. Sizes and timings here do not predict real data | [plane-dev-status-1.txt](evidence/runs/plane-dev-status-1.txt), [monitoring-loki-limit-2.txt](evidence/runs/monitoring-loki-limit-2.txt) |

One more upstream security finding, on the invitation flow, is left off this page. It is item H51 in `.local/hardening-backlog.md`, has no file in `docs/evidence/` yet, and may need reporting to Plane privately first. That is the owner's call.

## What Pass 1 does not prove

Even when every local test passes, these stay unproven.

| Not proven | Why a local pass says nothing about it |
|---|---|
| Availability | One node. Every failure of that node, the Docker VM, or the laptop is a total outage |
| Isolation between dev and production | See the next section |
| Behaviour under real TLS | No TLS. HTTPS changes cookies, presigned URLs, and how the API dials itself |
| Behaviour through a CDN or tunnel | Nothing sits in front of Traefik |
| Real user load | [`make test-load`](validation.md) has not run. It runs on a laptop in the same VM as the system under test. Load generator and target compete for CPU. Numbers do not transfer to servers |
| Performance on server hardware | arm64 Docker Desktop VM. Different architecture, kernel, and disk from any likely server |
| Storage durability | Postgres sits on kind's `local-path` class on a sparse VM disk. No replication, no real block device, no fsync behaviour worth quoting |
| Disaster recovery from losing the machine | Backups live on the same laptop. There is no off-machine copy |
| Long-running stability | The longest continuous run on record is about 5.3 hours: the control plane started at 2026-11-04T18:44Z and had 0 restarts at 2026-11-05T00:03Z ([snapshot](evidence/runs/plane-prod-sim-snapshot-final-1.txt)). Plane pods were replaced many times inside that by tests and rollouts. The longest single soak is 330s of idle WebSocket ([dev](evidence/runs/plane-dev-smoke-soak-1.txt)) |
| NetworkPolicy under a production CNI | Kindnet has its own evaluation point and fail-open behaviour. Results do not transfer to Cilium or Calico |
| Upgrades | v1.4.3 only. No upgrade from any earlier Plane version, or of Kubernetes, has been exercised |
| Email, OAuth, and other external integrations | Not configured. There is no route for them |
| Security against an attacker | Scanners and policy checks show configuration, not resistance to attack. No penetration test has been done |
| Multi-user behaviour at scale | Tests use a small number of accounts |
| Legal compliance | [AGPL analysis](agpl-compliance.md) is engineering analysis, not legal advice |

## Namespace separation is not independent clusters

`plane-dev` and `plane-prod-sim` are namespaces in one cluster. **Namespace separation is not equivalent to independent production clusters.** "prod-sim" means production simulation, and the name is deliberate.

| Shared by both environments | Consequence |
|---|---|
| Node, kernel, Docker VM, laptop | Any of them failing takes down both |
| API server and etcd | A control plane failure or corrupted etcd hits both |
| CoreDNS | A bad Corefile hits both. `terraform destroy` removes the `Corefile` key, which breaks both at the next restart |
| Traefik | A bad route or crash hits both |
| Argo CD, root Application | A bad sync or stuck operation can affect both. The root Application's waves order them, so a failure can hold prod-sim back |
| Infisical server | One instance, with a project per environment. Its failure stops both from refreshing secrets, and its `ENCRYPTION_KEY` protects both |
| Monitoring and logging | One Prometheus, Loki, and Alertmanager |
| Memory and disk | One environment can starve the other within quota. ResourceQuota covers memory and object counts, not CPU, and not disk |
| Kernel attack surface | A container escape reaches both |

What separation does exist, measured on 2026-11-05 inside this one cluster:

- Each Plane environment has its own data services, Silo, Infisical project, machine identity, AppProject, and quota. Their Postgres system identifiers, Valkey run ids, buckets and volumes all differ ([SEP-2](validation.md#separation-between-the-environments)).
- NetworkPolicy has no rule from one Plane namespace to the other, and real attempts confirm it: 120 rows each way all time out, with the real clients and their own credentials timing out too ([SEP-1](evidence/runs/harness-separation-network-1.txt)).
- `api` may reach Traefik for its self-dial, and Traefik routes by Host, so a compromised `api` can request the other environment's public hostname, and gets what a browser would ([what real runs found](#what-real-runs-found)). `gitops/platform/network-policies/plane-dev.yaml` records this gap.
- Cross-project access fails with 403 in both directions, on list, single read and slug lookup ([isolation](evidence/runs/infisical-isolation-20261104T232524Z.txt)).

Promoting from dev to prod-sim exercises process and tooling. It does not exercise an independent environment. Pass 2 is where independence is built, and it is untested.

## What Terraform does and does not do

Terraform provisions no infrastructure in Pass 1.

| Created by | Resources |
|---|---|
| **kind CLI**, through `scripts/cluster-up.sh` | Cluster, node, CNI, port and volume mounts |
| **Docker Compose**, through `infrastructure/local-services/` | Registry, pull-through caches, Git daemon |
| **Terraform**, `environments/local` | Namespaces and labels, ResourceQuota, LimitRange, CoreDNS rewrite, Argo CD release, AppProjects, root Application |
| **Terraform**, `infisical/terraform` | Infisical projects, environments, identities, memberships, Kubernetes Auth config |
| **Argo CD** | Everything else in the cluster |
| **Scripts** | Secret zero, Infisical bootstrap and seed |

`environments/dev` and `environments/prod` contain no Terraform. They are [interface documents](future-hetzner.md). Other limits:

- State is local, under `.local/terraform/`, with a local file lock only. Each Infisical backup copies the Infisical root's state, on the same machine.
- Argo CD does not manage itself, so upgrading it is not GitOps.
- `terraform destroy` removes the CoreDNS `Corefile` key. Delete the cluster afterwards instead of reusing it.
- The Infisical root's state shares a lifecycle with the instance. `make destroy` keeps it for a clean restore, and `scripts/infisical-bootstrap.sh` moves it aside on a truly fresh instance. That path has not run for real.

## Application: what is customized and what is not

- The application is Plane CE. It keeps Plane's features and limits, including upstream's paid-feature upsell UI unless patched out, and its absent enterprise features.
- plane-dev runs Wayline's derived web, admin, space and backend images, built from `1563cbf` and promoted at `4f622e3`, by digest in `helm/plane/overlays/dev/kustomization.yaml`: web `73a48d643f87`, admin `279dfd7f06cc`, space `a8c49151ee94`, backend `4add277ce63e` ([digests.tsv](evidence/branding/digests.tsv)). `plane-live` stays upstream's. plane-prod-sim runs upstream's images. A rebuild is under way, so the overlay is the final word on what runs today.
- Branding is a patch, codemod and token layer. The leak scan of the build output reads 0 leaks among 350 matches, every match on an allowlist with a stated reason ([leak-scan.txt](evidence/branding/leak-scan.txt)). Known residue: strings already seeded in a database, images identical to upstream's ([upstream-images-kept.txt](evidence/branding/upstream-images-kept.txt)), and the upstream docs links the allowlist keeps.
- Upstream v1 generic asset endpoints are broken per `plane-app.md`. `tests/e2e/smoke.py` uses work item attachments instead.
- `LIVE_SERVER_SECRET_KEY` has no consumer in v1.4.3 (`apps/live/src/lib/auth-middleware.ts`), so rotating it demonstrates nothing.
- **`SECRET_KEY` cannot be rotated.** It derives the key for encrypted config rows, and `decrypt_data` silently returns an empty string on failure.
- Email cannot send. No SMTP is configured, and no egress rule exists. Invitations and password resets by email do not work. One mail was read back from a scratch Mailpit outside the platform ([backend-db.txt](evidence/branding/backend-db.txt)).
- OAuth is not configured. Plane's avatar fetch on OAuth has not run.
- Plane exposes no request metrics or traces. `opentelemetry` is imported only for phone-home gauges (`data-observability.md`). Application health is inferred from probes, Traefik, and logs.
- `api` runs one gunicorn worker, and `worker` uses `CELERY_WORKER_CONCURRENCY=2`, to fit the memory budget. They are not tuned for load.

## Data services

| Limit | Detail |
|---|---|
| No HA | One replica each of Postgres, Valkey, RabbitMQ, and Silo in each environment |
| No point-in-time recovery | Logical dumps only. Data since the last dump is lost. [[MEASURE: RPO, as the interval between backups in practice]] |
| No scheduled backup | `make backup` is manual. There is no CronJob. A "backup" exists only if someone ran it. `PlaneBackupFailed` watches failed Jobs, and nothing alerts on a backup's age |
| Backups are not off-host | `.local/backups` on the same disk as the Docker VM. Survives cluster deletion, not laptop loss |
| Backups are not encrypted | Directory mode 0700. `scripts/backup.sh` notes that dumps hold password hashes and plaintext API tokens |
| Restore time unknown for Plane | Infisical restored in place in [44s](evidence/runs/dr-inplace-restore-2.txt). No real Plane environment has been restored. [[MEASURE: restore duration per environment, as the RTO input]] |
| Valkey and RabbitMQ | Not backed up. `scripts/restore.sh` flushes and purges them, so queued tasks are lost by design |
| RabbitMQ on 3.13 | Community support ended 2024-09-30 per `plane-app.md`. Accepted because 4.3 breaks Celery upstream (chart PR #304) and 4.2.9 is untested with CE. The complete scan lists a CRITICAL with a fix in 3.13.7 |
| Silo | A community fork of archived MinIO, unmodified, not official MinIO. Upstream's chart pins Silo too, but an older release than the `2026-10-26` distroless build in contract section 9. Upload, `copy_object`, avatar, public board and export all work on it in both environments (UP-1, UP-3, UP-4) |
| Object metadata in a restore | The backup mount keeps no xattrs ([dr-backup-dev-1.txt](evidence/runs/dr-backup-dev-1.txt)), so the restore Job puts `Content-Type` back itself. It did so on 14 of 22 objects in the [rehearsal](evidence/runs/dr-plane-restore-rehearsal-1.txt) |
| Bucket name | Must be `uploads` everywhere, because `export_task.py` hard-codes the path |
| Plane database role | Shared superuser, per `scripts/rotate.sh` |
| Rotation | `scripts/rotate.sh` is a demo for one Postgres password, and has not run. It has a known error window, and in-flight Jobs keep the old value. Native and scheduled rotation are paid Infisical features. [[MEASURE: error window during rotation]] |

## Security

Pass 1 has no real perimeter other than loopback binding.

| Limit | Detail |
|---|---|
| No TLS | Everything is plain HTTP on `127.0.0.1`. Session cookies are not `Secure` ([attributes](evidence/runs/plane-dev-cookies-1.txt)) |
| UIs without login | `prometheus.localhost` and `alertmanager.localhost` have no authentication. Any process on the Mac can reach them. A Plane `api` pod gets 403 from the allow list, which is [not a login](#what-real-runs-found) |
| Local attack surface | Any process on the machine can reach these hosts, and a web page open in a local browser can send requests to them |
| Secret zero on the laptop | `.local/secret-zero/` at mode 0600. This moves the problem to the laptop rather than solving it |
| etcd unencrypted | Kubernetes Secrets are base64 in kind's etcd |
| Secrets in Kubernetes | Plane reads them from env vars, so they are visible to anyone who can exec into a pod |
| Infisical free tier | No custom roles, no native rotation, zero audit log retention, read at v0.167.6. Per-project isolation is the boundary |
| `ALLOW_INTERNAL_IP_CONNECTIONS=true` | Relaxes Infisical's SSRF protection globally, needed for token review on kind |
| Pod Security | `enforce` is `baseline`, with `restricted` as warn and audit. `monitoring-agents` is `privileged` |
| Non-root | All Plane workloads run as non-root in both environments, read from each running process on upstream images ([dev](evidence/runs/plane-dev-psa-1.txt), [prod-sim](evidence/runs/plane-prod-sim-host-and-identity-1.txt)). A dry run of `restricted` gives no warning. The label has not been tightened, and the branded images have been read this way only outside the cluster ([smoke.txt](evidence/branding/smoke.txt)) |
| Writable root | Read-only root filesystem is not set, and has not been tried. `KSV-0014` is accepted in `.trivyignore` until 2027-02-01 |
| Argo CD | `server.insecure: true`, admin account, generated password |
| NetworkPolicy gaps | Kindnet fails open, and [one log line](#what-real-runs-found) is all that watches for it. It evaluates new connections only. Root sockets in the node's namespace skip evaluation. `172.16.0.0/12` is wider than the actual `kind` network |
| Change control | Private repository on GitHub Free: no enforced review, no protected branches, no environment reviewers, no attestations ([plan facts](evidence/ci/plan-facts-20261104T204023Z.txt)). GitHub's docs say code owners are not available on this plan, so `CODEOWNERS` does nothing here. A person merging is a process, not a control |
| Supply chain | Images are pinned by digest but not signed or attested here. `.trivyignore` holds accepted findings |
| Scanning | Trivy and gitleaks show known issues only. Last complete scan: [26 CRITICAL, 600 HIGH, 837 MEDIUM, 392 LOW](evidence/security/README.md), failing its policy. After the fixes the [images built here](evidence/security/scan-images-20261104T235800Z/run.log) pass: backend 4 HIGH and 11 MEDIUM, space 30 HIGH and 22 MEDIUM, each with a fix not taken. The old package versions remain as bytes in the `FROM` layers. Not scanned: the local registry, `plane-git` and the kind node |

See [security.md](security.md) for the design and what each control is meant to do.

## Delivery

| Limit | Detail |
|---|---|
| Argo CD does not read GitHub | It reads a local `git://` daemon. A merge changes nothing until someone pulls and runs `make gitops-publish`, which warns about commits not on `origin/main` and publishes them anyway |
| GitHub has seen little of this | `origin/main` is at `da7a4c9`, with pushes on hold. Everything from `b19fe26` on has run only on this Mac ([ci/README.md](evidence/ci/README.md#what-github-has-not-seen)) |
| Images have never been built on GitHub | `images.yml` has never run with `apps/wayline`, so the GHCR push, the scan of what was pushed, the prune and the gate step were only linted (CI-4) |
| Workflows do not deploy | No GitHub Actions job reaches the cluster |
| CI on PRs from `GITHUB_TOKEN` | Those PRs do not trigger `on: pull_request`, so the workflows run validation themselves. GitHub refuses the PR altogether while the repository setting is off (CI-6b). `ci.yml` has not run on `on: pull_request` |
| GHCR to local registry | A manual copy with `scripts/ci/copy-to-local-registry.sh`, which has not run. It needs `read:packages` on the local token |
| GHCR quota | Unconfirmed. GitHub's billing page lists 500 MB for private packages on Free, and also says container registry storage and bandwidth are free for now. Nothing has been stored. One image set is about 415 MiB compressed, an estimate from `apps/wayline/README.md`. Pruning stays as a precaution, and has not run |
| Promotion overrides | `OVERRIDE_DEV_CHECK` and `SKIP_DEV_CHECK` go past the plane-dev check for anyone who sets them. They are logged, not restricted. A rollback publishes all of `main`, including an unpublished prod-sim promotion. All of this has run against stubs only |
| arm64 only | Branded images build for `linux/arm64`. x86 hosts are not supported as built |
| Self-heal and drills | Automated sync with self-heal in both environments. Failure injection must pause it first, on the child and root, or Argo reverts it |
| Stuck syncs | With `retry.limit: -1`, a failed sync keeps retrying. `monitoring/ops/lib.sh` ends a failing operation before a restore, as measured on [scratch Applications](evidence/runs/argocd-terminate-1.txt) and [root](evidence/runs/argocd-root-terminate-1.txt). The same revision then does not restart, so root needs a newer commit that leaves it OutOfSync |

## Observability

| Limit | Detail |
|---|---|
| Nobody gets paged | Alerts go to an in-cluster webhook that prints a line. There is no external receiver |
| Monitoring dies with the cluster | No outside check. Watchdog proves the path to the sink only |
| Short retention | Prometheus 3 days or 1 GiB. Loki 72 hours. Alertmanager 24 hours |
| Disk alerts cannot see the real disk | The VM reports hundreds of GiB free on a sparse disk while the Mac may be nearly full. `NodeFilesystem*` watches the VM disk only, and `/backups` is excluded because it [reported 4397 GiB available](../monitoring/README.md) on a Mac with 17 GiB free. `guard_disk` in scripts is the only protection |
| VM clock | `NodeClockNotSynchronising` is off, because the VM runs no NTP client and it would always fire |
| Log collection | Alloy through the Kubernetes API. A second Alloy on 53 streams added at most 40 MiB of apiserver RSS and about 20 MiB of kubelet RSS, with CPU inside the noise, over one 180s window ([cost](evidence/runs/monitoring-alloy-apiserver-cost-1.txt)). Traefik writes no access log ([copy-object](evidence/runs/plane-dev-copy-object-path-1.txt)) |
| 5xx panels | No real 5xx has happened on an API panel. The log parser has been shown on generated 404s only ([logql](evidence/runs/monitoring-logql-1.txt)) |
| Alert accuracy | Seven rules have fired on real conditions, listed in [MON-6](validation.md#9-monitoring-and-alert-verification), one of them on a synthetic line. Sixteen have not, including `PlaneApiDown`, and `make test-alert` has not run. Only Watchdog was active on a healthy system at [2026-11-04T22:19Z](evidence/runs/monitoring-alertmanager-1.txt), one reading. [[VERIFY: alert rules fire on injected failure and stay quiet on a healthy system]] |

## Host and kind

| Limit | Detail |
|---|---|
| Host requirement | Written for one macOS arm64 machine with Docker Desktop. Linux and x86 are not tested |
| Memory | Minimum 14 GiB in Docker Desktop with unrelated containers stopped, by `scripts/prereqs.sh` and critique estimates. Limits sum above the VM on purpose. Measured on 2026-11-04: the VM reached 9.23 GiB of 13.63 across the two first boots, dev's first and then prod-sim's with images cached ([history](evidence/runs/plane-prod-sim-memory-history-1.txt)), and 10.49 GiB at its highest sample with both running ([samples](evidence/runs/plane-prod-sim-memory-1.txt)). Both include about 1 GiB of the owner's unrelated containers. Not from a clean install, and before any load test |
| Disk | Minimum 25 GiB free on the host, an estimate from registry layer sizes and PV guesses in critique section 5. [[MEASURE: actual host disk growth after a full install]] |
| Sparse VM disk | `Docker.raw` does not shrink on its own. Whether `kind delete cluster` returns space is unknown. [[MEASURE: Docker.raw size before and after make destroy]] |
| kind disables protection | No image garbage collection and no eviction (`imageGCHighThresholdPercent: 100`, `evictionHard` at 0%). Old images stay until removed, and a full disk means write errors rather than eviction |
| `local-path` ignores PVC size | Stated sizes are labels. `retentionSize` and backup `KEEP` are the only bounds |
| Docker Hub limits | Pulls go through a local cache fronting `mirror.gcr.io` and fall back to Hub. A full fresh build can use a noticeable part of the anonymous quota. The window was unresolved in research, and the fallback has not been exercised |
| Network assumption | `scripts/cluster-up.sh` fails if the `kind` network is outside `172.16.0.0/12`. The allow list on the internal routes uses the same range, so a node network outside it makes those UIs answer 403 |
| Browser | One Chromium session has signed in on dev ([AUTH-5](evidence/branding/live-dev/README.md)). Safari and Firefox have not been tried, and no browser has held both hosts at once. [[VERIFY: login works in the browsers listed in docs/install.md]] |
| Do not prune | `docker system prune -a` on this machine would remove cached images for unrelated containers that cannot be re-pulled anonymously |

## Open integration findings

A static review in `.local/integration-review.md` (host-only) listed these. Each was checked against the code and the evidence on 2026-11-05. They stay here so nobody assumes otherwise.

| ID | Finding | State |
|---|---|---|
| B1 | `Makefile:18` called `scripts/up.sh`, absent at that commit | Exists since `e25468e`, and has run by stages. A whole `make up` has not. [[VERIFY: scripts/up.sh exists and make up runs]] |
| B2 | `Makefile:35,41` called `scripts/test.sh`, absent at that commit | Exists since `ec9201f`, and `make test-e2e` runs through it. The full `make test` has no captured run. [[VERIFY: scripts/test.sh exists and make test runs]] |
| M1 | Root waves did not gate children with internal waves, so first boots could overlap | Fixed in `615e97c`. Measured on scratch Applications: root holds until the child's sync ends ([argocd-wave-gating-1.txt](evidence/runs/argocd-wave-gating-1.txt)) |
| M2 | `make restore` could not run while a sync was failing | `6f0c334` ends a failing operation first, which works ([argocd-terminate-1.txt](evidence/runs/argocd-terminate-1.txt)). A restore during a failing sync has not run. [[VERIFY: restore works during a failing sync]] |
| M3 | Argo CD metrics Services off | Fixed in `615e97c`. The one Argo CD ServiceMonitor, on the application controller, has a target that is up ([monitoring-targets-1.txt](evidence/runs/monitoring-targets-1.txt)) |
| M4 | Silo metrics returned 403 by default | Fixed in `2faaed5`. Both metric paths up in both environments ([monitoring-silo-metrics-1.txt](evidence/runs/monitoring-silo-metrics-1.txt)), with only Watchdog active at that time ([monitoring-alertmanager-1.txt](evidence/runs/monitoring-alertmanager-1.txt)) |
| M5 | `postgres-exporter` keeps the old password after rotation | `1ebc2e1` restarts it when the password rotates. No rotation has run. [[VERIFY: PlanePostgresDown stays quiet after make rotate]] |
| m6 | `drill-*` make targets absent, though contract section 11 names them | Fixed in `f7c0f78`. `make drill-pod-restart ENV=prod-sim` has run ([plane-prod-sim-drill-pod-restart-2.txt](evidence/runs/plane-prod-sim-drill-pod-restart-2.txt)) |

## Documentation limits

- Docs were written while code was changing. Any marker left unresolved means the claim is unproven, and a later pass handles it.
- Memory and disk figures from research are estimates unless linked to evidence in `docs/evidence/`.
- Hetzner and Cloudflare content is a plan and has never run against either service.
- Not legal advice, anywhere in these docs.

Pass 2 scope is in [`PASS2_HANDOFF.md`](../PASS2_HANDOFF.md).
