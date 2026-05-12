# Known limitations

This page says what the platform is not and what has not been shown. Read it before quoting anything else in these docs.

The platform is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), named Wayline, on a local kind cluster. It is production-inspired. It is not production-ready, and this repository makes no such claim.

Written 2026-11-04, mostly against commit `f733b87`, while integration and validation were still running. `[[VERIFY]]` and `[[MEASURE]]` markers show what a later pass must resolve against `docs/evidence/`.

## Status

[`docs/validation.md`](validation.md) is the record of what ran. It labels results PASS, FAIL, BLOCKED, or NOT RUN, per contract section 12. If a statement here and an evidence file disagree, the evidence file wins.

When this was written, the only runtime results were the day-1 gates and static checks. The gates cover digest pulls, kindnet enforcing a sentinel policy, and `git://` from a pod. [[VERIFY: day-1 gate output has been copied to docs/evidence/ with date and command]]

Plane had not been deployed. [[VERIFY: replace this paragraph with the final deployment result and link to evidence]]

## What Pass 1 does not prove

Even when every local test passes, these stay unproven.

| Not proven | Why a local pass says nothing about it |
|---|---|
| Availability | One node. Every failure of that node, the Docker VM, or the laptop is a total outage |
| Isolation between dev and production | See the next section |
| Behaviour under real TLS | No TLS. HTTPS changes cookies, presigned URLs, and how the API dials itself |
| Behaviour through a CDN or tunnel | Nothing sits in front of Traefik |
| Real user load | [`make test-load`](validation.md) runs on a laptop in the same VM as the system under test. Load generator and target compete for CPU. Numbers do not transfer to servers |
| Performance on server hardware | arm64 Docker Desktop VM. Different architecture, kernel, and disk from any likely server |
| Storage durability | Postgres sits on kind's `local-path` class on a sparse VM disk. No replication, no real block device, no fsync behaviour worth quoting |
| Disaster recovery from losing the machine | Backups live on the same laptop |
| Long-running stability | No soak beyond short test windows. [[VERIFY: state the longest continuous run from evidence]] |
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

What separation does exist:

- Each Plane environment has its own data services, Silo, Infisical project, machine identity, AppProject, and quota.
- NetworkPolicy has no rule from one Plane namespace to the other. [[VERIFY: tests/network-policy-matrix.yaml cross-environment rows are denied at runtime]]
- `api` may reach Traefik for its self-dial, and Traefik routes by Host, so a compromised `api` could request the other environment's public hostname. `gitops/platform/network-policies/plane-dev.yaml` records this gap.
- Cross-project access is meant to fail with 403. [[VERIFY: runtime cross-project denial evidence from Infisical]]

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

- State is local, under `.local/terraform/`, with no locking and no backup other than the machine's.
- Argo CD does not manage itself, so upgrading it is not GitOps.
- `terraform destroy` removes the CoreDNS `Corefile` key. Delete the cluster afterwards instead of reusing it.
- The Infisical root's state shares a lifecycle with the instance. A fresh instance needs fresh state.

## Application: what is customized and what is not

- The application is Plane CE. It keeps Plane's features and limits, including upstream's paid-feature upsell UI unless patched out, and its absent enterprise features.
- `apps/wayline/` is partial and uncommitted when this is written: brand CSS, fonts, and check scripts, with no patches, codemod, Dockerfiles, or `images.txt`. The rendered manifests still reference unmodified `docker.io/makeplane/*` images. [[VERIFY: state which Wayline images are deployed, by digest, from the overlays]]
- Branding is a text and token patch layer. Expected residue: strings in new upstream files, the persisted strings seeded in the database, and empty-state images (`plane-branding.md` risks). [[VERIFY: leak scan result on built images]]
- Upstream v1 generic asset endpoints are broken per `plane-app.md`. `tests/e2e/smoke.py` uses work item attachments instead.
- `LIVE_SERVER_SECRET_KEY` has no consumer in v1.4.3 (`apps/live/src/lib/auth-middleware.ts`), so rotating it demonstrates nothing.
- **`SECRET_KEY` cannot be rotated.** It derives the key for encrypted config rows, and `decrypt_data` silently returns an empty string on failure.
- Email cannot send. No SMTP is configured, and no egress rule exists. Invitations and password resets by email do not work.
- OAuth is not configured. Plane's avatar fetch on OAuth has not run.
- Plane exposes no request metrics or traces. `opentelemetry` is imported only for phone-home gauges (`data-observability.md`). Application health is inferred from probes, Traefik, and logs.
- `api` runs one gunicorn worker, and `worker` uses `CELERY_WORKER_CONCURRENCY=2`, to fit the memory budget. They are not tuned for load.

## Data services

| Limit | Detail |
|---|---|
| No HA | One replica each of Postgres, Valkey, RabbitMQ, and Silo in each environment |
| No point-in-time recovery | Logical dumps only. Data since the last dump is lost. [[MEASURE: RPO, as the interval between backups in practice]] |
| No scheduled backup | `make backup` is manual. There is no CronJob. A "backup" exists only if someone ran it |
| Backups are not off-host | `.local/backups` on the same disk as the Docker VM. Survives cluster deletion, not laptop loss |
| Backups are not encrypted | Directory mode 0700. `scripts/backup.sh` notes that dumps hold password hashes and plaintext API tokens |
| Restore time unknown | [[MEASURE: restore duration per environment, as the RTO input]] |
| Valkey and RabbitMQ | Not backed up. `scripts/restore.sh` flushes and purges them, so queued tasks are lost by design |
| RabbitMQ on 3.13 | Community support ended 2024-09-30 per `plane-app.md`. Accepted because 4.3 breaks Celery upstream (chart PR #304) and 4.2.9 is untested with CE |
| Silo | A community fork of archived MinIO, unmodified, not official MinIO. Upstream's chart pins Silo too, but an older release than the `2026-10-26` distroless build in contract section 9. [[VERIFY: upload, avatar, public space page, and export flows on Silo]] |
| Bucket name | Must be `uploads` everywhere, because `export_task.py` hard-codes the path |
| Plane database role | Shared superuser, per `scripts/rotate.sh` |
| Rotation | `scripts/rotate.sh` is a demo for one Postgres password. It has a known error window, and in-flight Jobs keep the old value. Native and scheduled rotation are paid Infisical features. [[MEASURE: error window during rotation]] |

## Security

Pass 1 has no real perimeter other than loopback binding.

| Limit | Detail |
|---|---|
| No TLS | Everything is plain HTTP on `127.0.0.1`. Session cookies are not `Secure` |
| UIs without login | `prometheus.localhost` and `alertmanager.localhost` have no authentication. Any local process can reach them |
| Local attack surface | Any process on the machine can reach these hosts, and a web page open in a local browser can send requests to them |
| Secret zero on the laptop | `.local/secret-zero/` at mode 0600. This moves the problem to the laptop rather than solving it |
| etcd unencrypted | Kubernetes Secrets are base64 in kind's etcd |
| Secrets in Kubernetes | Plane reads them from env vars, so they are visible to anyone who can exec into a pod |
| Infisical free tier | No custom roles, no native rotation, zero audit log retention, read at v0.167.6. Per-project isolation is the boundary |
| `ALLOW_INTERNAL_IP_CONNECTIONS=true` | Relaxes Infisical's SSRF protection globally, needed for token review on kind |
| Pod Security | `enforce` is `baseline`, with `restricted` as warn and audit. `monitoring-agents` is `privileged` |
| Non-root | Workload UIDs are patched in, and untested until Plane runs. [[VERIFY: all Plane workloads run as non-root at runtime]] |
| Writable root | Read-only root filesystem is not set. `KSV-0014` is accepted in `.trivyignore` until 2027-02-01 |
| Argo CD | `server.insecure: true`, admin account, generated password |
| NetworkPolicy gaps | Kindnet fails open silently, and evaluates new connections only. Root sockets in the node's namespace skip evaluation. `172.16.0.0/12` is wider than the actual `kind` network |
| Change control | Private repository on GitHub Free: no enforced review, no protected branches, no environment reviewers, no attestations. `CODEOWNERS` is advisory. A person merging is a process, not a control |
| Supply chain | Images are pinned by digest but not signed or attested here. `.trivyignore` holds accepted findings |
| Scanning | Trivy and gitleaks show known issues only. [[VERIFY: final Trivy finding counts and accepted findings are in docs/evidence/]] |

See [security.md](security.md) for the design and what each control is meant to do.

## Delivery

| Limit | Detail |
|---|---|
| Argo CD does not read GitHub | It reads a local `git://` daemon. A merge changes nothing until someone pulls and runs `make gitops-publish` |
| Workflows do not deploy | No GitHub Actions job reaches the cluster |
| CI on PRs from `GITHUB_TOKEN` | Those PRs do not trigger `on: pull_request`, so the workflows run validation themselves |
| GHCR to local registry | A manual copy with `scripts/ci/copy-to-local-registry.sh` |
| GHCR quota | 500 MB on private Free. One image set is close to that, about 450 MiB compressed, an estimate from `.github/workflows/README.md`. Old versions need pruning |
| arm64 only | Branded images build for `linux/arm64`. x86 hosts are not supported as built |
| Self-heal and drills | Automated sync with self-heal in both environments. Failure injection must pause it first, on the child and root, or Argo reverts it |
| Stuck syncs | With `retry.limit: -1`, a failed sync keeps retrying. `.local/integration-review.md` notes consequences for restore and root operations |

## Observability

| Limit | Detail |
|---|---|
| Nobody gets paged | Alerts go to an in-cluster webhook that prints a line. There is no external receiver |
| Monitoring dies with the cluster | No outside check. Watchdog proves the path to the sink only |
| Short retention | Prometheus 3 days or 1 GiB. Loki 72 hours. Alertmanager 24 hours |
| Disk alerts cannot see the real disk | The VM reports hundreds of GiB free on a sparse disk while the Mac may be nearly full. `NodeFilesystem*` will not fire in time. `guard_disk` in scripts is the only protection |
| Log collection | Alloy through the Kubernetes API. Its load on the API server is unmeasured. [[MEASURE: API server CPU and memory with Alloy running]] |
| Alert accuracy | [[VERIFY: alert rules fire on injected failure and stay quiet on a healthy system]] |

## Host and kind

| Limit | Detail |
|---|---|
| Host requirement | Written for one macOS arm64 machine with Docker Desktop. Linux and x86 are not tested |
| Memory | Minimum 14 GiB in Docker Desktop with unrelated containers stopped, by `scripts/prereqs.sh` and critique estimates. Limits sum above the VM on purpose. [[MEASURE: peak memory across first boot of both environments]] |
| Disk | Minimum 25 GiB free on the host, an estimate from registry layer sizes and PV guesses in critique section 5. [[MEASURE: actual host disk growth after a full install]] |
| Sparse VM disk | `Docker.raw` does not shrink on its own. Whether `kind delete cluster` returns space is unknown. [[MEASURE: Docker.raw size before and after make destroy]] |
| kind disables protection | No image garbage collection and no eviction (`imageGCHighThresholdPercent: 100`, `evictionHard` at 0%). Old images stay until removed, and a full disk means write errors rather than eviction |
| `local-path` ignores PVC size | Stated sizes are labels. `retentionSize` and backup `KEEP` are the only bounds |
| Docker Hub limits | Pulls go through `mirror.gcr.io` and fall back to Hub. A full fresh build can use a noticeable part of the anonymous quota. The window was unresolved in research |
| Network assumption | `scripts/cluster-up.sh` fails if the `kind` network is outside `172.16.0.0/12` |
| Browser | `*.localhost` behaviour in Safari is unconfirmed. [[VERIFY: login works in the browsers listed in docs/install.md]] |
| Do not prune | `docker system prune -a` on this machine would remove cached images for unrelated containers that cannot be re-pulled anonymously |

## Open integration findings

A static review in `.local/integration-review.md` (host-only) listed these. Check each against the final code. They are recorded here so nobody assumes otherwise.

| ID | Finding | Marker |
|---|---|---|
| B1 | `Makefile:18` calls `scripts/up.sh`, absent at this commit | [[VERIFY: scripts/up.sh exists and make up runs]] |
| B2 | `Makefile:35,41` call `scripts/test.sh`, absent at this commit | [[VERIFY: scripts/test.sh exists and make test runs]] |
| M1 | Root waves do not gate children with internal waves, so first boots may overlap | [[VERIFY: root waves hold until the child's sync ends]] |
| M2 | `make restore` cannot run while a sync is failing | [[VERIFY: restore works during a failing sync]] |
| M3 | Argo CD metrics Services off | [[VERIFY: Argo CD ServiceMonitors have targets]] |
| M4 | Silo metrics returned 403 by default | [[VERIFY: PlaneMinioDown is quiet on a healthy Silo]] |
| M5 | `postgres-exporter` keeps the old password after rotation | [[VERIFY: PlanePostgresDown stays quiet after make rotate]] |
| m6 | `drill-*` make targets absent, though contract section 11 names them | [[VERIFY: drill make targets exist]] |

## Documentation limits

- Docs were written while code was changing. A reconciliation pass is expected, and any marker left unresolved means the claim is unproven.
- Memory and disk figures from research are estimates unless linked to evidence in `docs/evidence/`.
- Hetzner and Cloudflare content is a plan and has never run against either service.
- Not legal advice, anywhere in these docs.

Pass 2 scope is in [`PASS2_HANDOFF.md`](../PASS2_HANDOFF.md).
