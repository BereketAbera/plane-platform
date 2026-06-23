# Install and operate locally

Wayline is a customized Plane Community Edition v1.4.3 deployment (AGPL-3.0). It is not an original product. This
repository wraps upstream Plane in a local deployment platform on kind. It is local and production-inspired, and it makes no
claim of being ready for production. See [known-limitations.md](known-limitations.md).

**Status of this page.** It describes configuration and script behaviour read from the code, with results from real runs
where they exist, as of 2026-11-05. The platform has run in stages on the laptop it was built on. **A clean install has not
run**, so anything that depends on one carries a `VERIFY` or `MEASURE` marker until [validation.md](validation.md) and
[`docs/evidence/`](evidence/README.md) hold the result. Do not read an unmarked command as a tested command. It means
only that the claim does not depend on a runtime result.

Names and ordering come from the binding [platform contract](platform-contract.md).

## Prerequisites

`make setup` checks most of this through `scripts/prereqs.sh`. The thresholds below are what that script enforces.

| Requirement | Enforced value | Why |
|---|---|---|
| Docker Desktop or Docker Engine, running | Daemon must answer | kind nodes and the local services are containers |
| Docker memory | Fails below 13 GiB visible. Set 14 GiB in Docker Desktop, because 14 GiB shows as about 13.6 GiB | The platform is two full Plane environments plus monitoring and Infisical on one node |
| Docker CPUs | Fails below 4 | Bursts during first boot: migrators, API boots, chart renders |
| Free host disk | Fails below 25 GiB, warns below 35 GiB | The Docker VM reports hundreds of free GiB on its sparse disk, so nothing inside the cluster can see the real limit. Scripts that cost disk call `guard_disk` for that reason. `scripts/up.sh` also asks for 25 GiB when no cluster exists, unless `ALLOW_LOW_DISK="<reason>"` overrides it, which is logged |
| Host ports 80, 443, 5001 | Fails if held by anything except Docker | kind maps Traefik to `127.0.0.1:80` and `:443`. The registry is on `127.0.0.1:5001` |
| `docker` with `compose` and `buildx`, `git`, `make`, `curl`, `jq`, `python3`, `openssl`, `lsof`, `tar`, `unzip`, `shasum`, and the base utilities such as `awk` and `sed` | Fails if missing | Scripts call them directly |
| Node 22 with corepack, `rsync`, `perl` | Warns only | Only `make images` needs them |
| `*.localhost` resolving to loopback | Warns only | Hostnames need no `/etc/hosts` entry where the resolver supports this |
| `kind` Docker network inside `172.16.0.0/12` | `scripts/cluster-up.sh` fails otherwise | NetworkPolicies allow node-sourced traffic from Docker's default pool. A custom daemon pool would silently break them |
| Host platform | `darwin_arm64`, `linux_amd64`, `linux_arm64`, or `scripts/install-tools.sh` exits | `tools.lock` has checksums for those three only. Intel Macs are not covered |

`make setup` runs `scripts/install-tools.sh` first, so a missing `curl`, `tar` or `unzip` fails there, before the friendlier
message in `prereqs.sh`. A Git identity is needed too, because `make promote` and `make rollback` commit.

The platform was built on `darwin_arm64`.
Other platforms have install paths, and no run of `make setup` or `make up` is recorded on them. Only parts have run on Linux:
the CI scripts and `scripts/install-tools.sh` for a few tools, on GitHub's `ubuntu-24.04-arm` and `ubuntu-24.04` runners
([log](evidence/ci/ci-4-20261105T053955Z-run-41975430939.log)). Treat a full install on Linux as untested.

On 2026-11-05T06:15Z `scripts/prereqs.sh` failed on the build laptop for disk alone, with 13 GiB free against the 25 GiB minimum
(`.local/evidence-raw/INST-3-20261105T061554Z.txt`, unpublished). A clean install there needs space freed first.

### Resource use

Measured on the build laptop, with Docker Desktop set to 14 GiB, both environments on upstream images, and about 1 GiB of unrelated
containers running. These are not from a clean install, a load test or the final images. [resource-utilization.md](resource-utilization.md) has the
conditions and the rest.

| Item | Value | Source |
|---|---|---|
| Docker VM used, quiet | 9.44 GiB median, of 13.63 GiB | 30 samples on 2026-11-05 ([plane-prod-sim-memory-1.txt](evidence/runs/plane-prod-sim-memory-1.txt)) |
| Docker VM used, highest sampled | 10.49 GiB | The same file, 2026-11-04T23:23:42Z, right after a change replaced the Argo CD pods. The smoke tests topped at 9.87 GiB and the drills at 9.90 GiB |
| Swap used, highest | 0.60 GiB of 2 GiB | The same file |
| Host disk growth | 19.5 to 24.8 GiB, estimate | Image sizes summed from registry layer metadata (8.56 GiB unpacked), plus estimates for volumes, logs, build bases, caches and tools |
| Disk on the running platform | 17.75 GiB, a sum of sizes | 2026-11-05T02:01Z: the node's `/var`, the local services' volumes and the node image (`.local/evidence-raw/dr-disk-1.txt`, unpublished). Read while other work was building, not a before and after of a clean install |

Research recommended 14 GiB of Docker memory with unrelated containers stopped, and 16 GiB if they must keep running. So far, 14 GiB has
held with them running. That has not been tried under load.

- [[MEASURE: Docker.raw growth and host free disk after a first make up]]

Do not run `docker system prune -a` to free space. It removes cached images, and some of them may no longer be
anonymously pullable. Official MinIO images are one example.

### Pinned tools

`make setup` installs these into `.tools/bin` and verifies every SHA-256 against `tools.lock`. Nothing is installed globally.

| Tool | Version | | Tool | Version |
|---|---|---|---|---|
| terraform | 1.17.1 | | conftest | v0.71.1 |
| kind | v0.33.0 | | kubeconform | v0.8.0 |
| kubectl | v1.36.6 | | tflint | v0.65.0 |
| helm | v4.3.1 | | shellcheck | v0.11.0 |
| kustomize | v5.8.3 | | actionlint | v1.7.12 |
| yq | v4.53.2 | | zizmor | v1.32.0 |
| k6 | v2.3.0 | | hadolint | v2.15.1 |
| gitleaks | v8.30.1 | | trivy | v0.76.1 |
| promtool | v3.15.1 | | | |

The `argocd` CLI is not in `tools.lock`, so `make setup` does not install it. [argocd.md](argocd.md) shows the
`kubectl` equivalent wherever one exists.

## Shell setup

Scripts set `KUBECONFIG` and `PATH` for themselves. Your own shell does not get them. `kubectl --context
kind-plane-platform` alone fails, because `~/.kube/config` is never touched. Run this from the repository root before
using `kubectl`, `terraform` or `kind` by hand:

```bash
export PATH="$PWD/.tools/bin:$PATH"
export KUBECONFIG="$PWD/.local/kubeconfig"
```

The commands on this page assume that shell.

## First run

```bash
make setup
git status --short          # Argo CD reads commits on main only, so commit first
make up
make status
```

`make up` is the idempotent create-or-resume entry point, in `scripts/up.sh`. It refuses uncommitted changes under `gitops/`, `helm/`,
`monitoring/` and `infisical/`, because Argo CD reads only commits. `UP_STOP_AFTER=<step>` stops after one step, and any step can be
run again.

It ran in stages with `UP_STOP_AFTER` on 2026-11-04 ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)), and it has not yet run from nothing in one go.
The sequence:

| # | Step | Script or owner | What it needs and what it leaves |
|---|---|---|---|
| 1 | Create the cluster and start local services (`cluster`) | `scripts/cluster-up.sh` | Creates one node on Kubernetes v1.36.4, then starts the registry, three pull-through caches and the `git://` remote through Compose |
| 2 | Publish `main` (`publish`) | `scripts/gitops-publish.sh` | Checks that the local registry can serve every digest the rendered manifests name, and rebuilds if not. Creates `.local/git/plane-platform.git` if absent and pushes `main`. It runs before Terraform so the root Application's first compare has a repository. If `main` brings prod-sim a digest that `plane-dev` is not running, it stops here |
| 3 | Apply the foundation (`terraform`) | Terraform, `infrastructure/terraform/environments/local` | Namespaces, quotas, LimitRanges, CoreDNS rewrite, Argo CD, AppProjects, root Application. See [terraform.md](terraform.md) |
| 4 | Create secret zero (`secret-zero`) | `scripts/secret-zero.sh` | Generates files in `.local/secret-zero/` and applies three Secrets to `infisical`. It needs the namespace from step 3 |
| 5 | Wait for Traefik (`traefik`) | Argo CD | Waves -10 to -9, then a real request to `http://argocd.localhost/`, which fails fast on NodePort and NetworkPolicy trouble |
| 6 | Bootstrap Infisical (`infisical`) | `scripts/infisical-bootstrap.sh` | Waits up to 2400 s for `http://infisical.localhost`, which is behind the monitoring waves. Creates the first admin, applies `infisical/terraform`, seeds values, publishes identity ids |
| 7 | Wait for every Application | Argo CD | All 14 Synced and Healthy, after asking each to refresh. Plane dev is at wave -1, prod-sim at wave 0. See [argocd.md](argocd.md). All 14 Synced and Healthy says nothing about Plane itself, so run `make test` next |

`UP_WAIT_TRAEFIK_SECONDS`, `UP_WAIT_ROUTE_SECONDS`, `UP_WAIT_INFISICAL_SECONDS` and `UP_WAIT_APPS_SECONDS` override the waits. Staged times are
in [resource-utilization.md](resource-utilization.md#boot-and-start-times).

- [[MEASURE: wall-clock time of a first make up, per step]]
- [[MEASURE: wall-clock time of make up when resuming after make down]]

### What looks broken but is expected

Seen on the staged first boot on 2026-11-04, unless the row says otherwise.

| What you see | Why | Ends when |
|---|---|---|
| `argocd.localhost` does not answer | The route needs Traefik's CRD and syncs at wave -8 | Traefik is Healthy. Until then use `kubectl -n argocd port-forward svc/argocd-server 8080:80`. [[VERIFY: port-forward path works before Traefik exists]] |
| Infisical Postgres and Redis in `CreateContainerConfigError` | They wait for Secrets from `scripts/secret-zero.sh`. Expected from reading, and not seen in the staged run, where secret zero ran well before wave -4 | Step 4 finishes. [[VERIFY: pods recover without intervention after secret zero]] |
| `plane-dev` Degraded, `InfisicalAuth` not ready | `plane-infisical-identity` does not exist until step 6 | Step 6 publishes it, and the next retry moves on with no help, up to 5 minutes later: published at 21:25:44, retried at 21:28:54 ([infisical-unready-sync-1.txt](evidence/runs/infisical-unready-sync-1.txt)) |
| `kube-prometheus-stack` Degraded for about 9 minutes, with root failing and retrying | Its images pull through the mirror one at a time, and Argo CD's built-in check read a Prometheus with no ready pod as Degraded | It took 591 s on the staged boot ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt), [timeline](evidence/runs/bootstrap-timeline-1.txt)). Root reached the next wave on its fourth retry, 3 minutes later. An override since reads that state as Progressing, with root waiting and no retry. That has been shown on a restart ([h43-repro-after-1.txt](evidence/runs/h43-repro-after-1.txt)) and not on a first boot |
| `plane-dev` Progressing for minutes in wave 3 | The kubelet pulls one image at a time. The last of four was ready after 448 s ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)) | `progressDeadlineSeconds` is now 600 s, because 360 s failed that boot once before a retry recovered it. That failure was read live and is not in a saved file |
| Application phase `Running` for a long time, with a retry message | Retries have no limit, so a failing sync reads as `Running`. See [argocd.md](argocd.md#retry-behaviour) | The cause is fixed, or the operation is terminated. `ArgoSyncFailed` fires on an operation still open after 15 minutes |

The prod-sim operator was expected to crash-loop until `infisical-operator-dev` had installed the CRDs. It did not: at 21:22:31Z, about 11 minutes after the operators came up, Grafana was the only pod in the
cluster with a restart ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)).

## Local URLs

Everything is on loopback over plain HTTP. kind binds only `127.0.0.1`. TLS is out of scope in Pass 1.

| URL | Service | Sign-in | Where the credential comes from |
|---|---|---|---|
| `http://plane.dev.localhost` | Plane dev | Workspace user | See [Plane accounts](#plane-accounts) |
| `http://plane.prod-sim.localhost` | Plane prod-sim | Workspace user | See [Plane accounts](#plane-accounts) |
| `http://plane.dev.localhost/god-mode/` | Plane instance admin | Instance admin | See [Plane accounts](#plane-accounts) |
| `http://argocd.localhost` | Argo CD | `admin` | Secret `argocd/argocd-initial-admin-secret`, generated by Argo CD at first start |
| `http://grafana.localhost` | Grafana | `admin` | Secret `monitoring/kps-grafana`, key `admin-password`, generated by the chart |
| `http://prometheus.localhost` | Prometheus | None | No login. The route admits only the node network |
| `http://alertmanager.localhost` | Alertmanager | None | No login. The route admits only the node network |
| `http://infisical.localhost` | Infisical | `admin@wayline.localhost` | `.local/secret-zero/infisical-admin-password` |

All seven hosts answered through Traefik in `make status` on 2026-11-04, with 200, or 302 from Grafana and Prometheus
([plane-prod-sim-status-1.txt](evidence/runs/plane-prod-sim-status-1.txt)).

Prometheus and Alertmanager have no login. All five internal UIs carry a `node-network-only` allow list on `172.16.0.0/12`, because a Plane
`api` pod can reach Traefik: the host arrives as the kind gateway and gets through, and a pod gets 403
([routes-after-2.txt](evidence/runs/routes-after-2.txt)). That is a source-address check, not a login, and [monitoring/README.md](../monitoring/README.md) lists what
it does not stop.

Session cookies are host-only, so a dev session gets 401 on the prod-sim host ([plane-dev-cookies-1.txt](evidence/runs/plane-dev-cookies-1.txt)).
A real browser session has run in Chromium ([record](evidence/branding/live-dev/README.md)), and Safari has not. On 2026-11-05 one
Chromium profile signed in on dev got 401 on the prod-sim host (`.local/evidence-raw/AUTH-4-20261105T062750Z.txt`, unpublished).

[[VERIFY: *.localhost resolves in Safari and cookies stay separate between the two Plane hosts]]

## Getting credentials without printing them

`.local/` is gitignored. It holds real secrets, so treat it like a password manager export.

- Send a value to the clipboard rather than the terminal. Scrollback, tmux logs, screen shares and session recordings all keep what you print.
- Do not run these with `set -x`, and do not paste output into a ticket, a chat, or `docs/evidence/`.
- List names before values. To see what exists, read the key names only.
- Use `pbcopy` on macOS. On Linux, replace it with your clipboard tool, such as `xclip -selection clipboard`.

```bash
# Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d | pbcopy

# Grafana admin password
kubectl -n monitoring get secret kps-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d | pbcopy

# Infisical first admin (user admin@wayline.localhost)
tr -d '\n' < .local/secret-zero/infisical-admin-password | pbcopy
```

### Plane accounts

`make test-e2e` creates the instance admin through `tests/e2e/smoke.py`. It writes generated credentials to
`.local/test-accounts.env`, mode 0600, and never prints them. Keys are prefixed per environment, such as
`PLANE_DEV_ADMIN_PASSWORD` and `PLANE_PROD_SIM_ADMIN_PASSWORD`. It did this in both environments, with telemetry off
([dev](evidence/runs/smoke-dev-20261104T221730Z.json), [prod-sim](evidence/runs/smoke-prod-sim-20261104T231359Z.json)).
If a sign-up gets no clear answer, the password it sent waits under `PLANE_DEV_ADMIN_PASSWORD_PENDING`, because a sign-up
cannot be repeated. The next run tries that password, then stores it as the admin's or drops it.

```bash
make test-e2e ENV=dev

cut -d= -f1 .local/test-accounts.env                      # names only
grep '^PLANE_DEV_ADMIN_EMAIL=' .local/test-accounts.env | cut -d= -f2- | tr -d '\n' | pbcopy
grep '^PLANE_DEV_ADMIN_PASSWORD=' .local/test-accounts.env | cut -d= -f2- | tr -d '\n' | pbcopy
```

**Admin sign-up is one-shot per instance.** Whoever reaches `/god-mode/` first becomes the instance admin. If you
create the admin by hand, `smoke.py` has no credentials for that instance and the step reads BLOCKED (`step_instance_setup`
in `tests/e2e/smoke.py`), and `make test-load` depends on the same account. Run `make test-e2e` first unless you want
to supply those credentials yourself.

### Other files under `.local/`

| Path | Contents | If lost |
|---|---|---|
| `kubeconfig` | Admin credentials for the kind cluster | `kind export kubeconfig` recreates it. `make up` does this |
| `secret-zero/ENCRYPTION_KEY` | Encrypts every secret in the Infisical database | **Unrecoverable once the cluster Secret is gone too.** Keep a copy off this machine |
| `secret-zero/AUTH_SECRET`, `DB_PASSWORD`, `REDIS_PASSWORD` | Infisical's own secrets | Recoverable from the cluster while it exists |
| `secret-zero/infisical-admin.json` | Admin token and organization id | See `infisical/README.md`, section Recovery |
| `backups/<env>/<id>/` | Dumps and object copies. These hold password hashes and plaintext API tokens | Only recoverable from another copy |
| `git/plane-platform.git` | The bare repo Argo CD reads | Rebuilt by `make gitops-publish` |
| `terraform/` | State for both Terraform roots | See [terraform.md](terraform.md#state) |
| `evidence-raw/` | Raw run output. `make publish-evidence` copies it to `docs/evidence/runs/`, scrubbed | Whatever had not been published |
| `evidence-scrub-values` | Every value the scrub has seen, base64-encoded. Never copy it | The next publish could put a value back into a copy |
| `test-accounts.env` | Generated test credentials | The account becomes unusable. See above |
| `test-sentinel-<env>.json` | What the sentinel data should read back as | `make test-e2e` writes a new sentinel, and backups from before it report those proofs as NOT RUN. The first smoke on a new database replaces a kept record by itself, unless the namespace is older than the record, which fails as lost data |

## Make targets

`make help` lists these from the Makefile. Pass parameters as `make target KEY=value`. Make exports them to the script.

### Lifecycle

| Target | What it does | Parameters |
|---|---|---|
| `make help` | Lists targets. The default goal | |
| `make setup` | Runs `scripts/install-tools.sh`, then `scripts/prereqs.sh` | |
| `make up` | Creates or resumes the whole platform. Calls `scripts/up.sh` | `UP_STOP_AFTER=<cluster, publish, terraform, secret-zero, traefik or infisical>`, `ALLOW_LOW_DISK="<reason>"`, which is logged |
| `make down` | Stops the node and the local services. Keeps all data | |
| `make destroy` | Deletes the cluster and its data. See [Teardown](#teardown) | `CONFIRM=yes` (required), `SKIP_BACKUP=yes`, `PURGE=yes` |
| `make status` | Read-only summary: node, Applications, unready pods, endpoints, resources, host disk | |
| `make logs` | Tails one workload in a Plane namespace, or lists what can be tailed when `SVC` is empty. `SVC` is a name from the table, such as `beat` or `silo`, or any live Deployment, StatefulSet or Job, such as `redis-exporter`. `scripts/logs.sh dev api --no-follow` prints the last lines and stops | `ENV=dev`, `SVC=api` |

### Verification

| Target | What it does | Parameters |
|---|---|---|
| `make test` | Gates, the NetworkPolicy matrix, Infisical isolation, internal routes, smoke tests in both environments, and the separation checks, in that order, carrying on after a failure. Calls `scripts/test.sh`. [validation.md](validation.md) says what has run | |
| `make gates` | Runs `tests/gates/day1.sh`, the cheap runtime checks for assumptions source reading cannot settle | |
| `make test-e2e` | End-to-end smoke test through `scripts/test.sh e2e` | `ENV=dev` |
| `make test-netpol` | Runs the allow and deny matrix in `tests/network-policy-matrix.yaml` | `FROM_NS=plane-dev` limits it to one source namespace |
| `make test-infisical` | Each environment's identity is refused the other's project, and the rendered Secrets match the contract | |
| `make test-routes` | Who can reach the internal UIs through Traefik: the host can, a Plane `api` pod cannot | |
| `make test-separation` | Real attempts between dev and prod-sim, and what each holds. Needs `make test-e2e` to have run in both | |
| `make test-alert` | Exercises alert delivery end to end. Pauses auto-sync while it injects a failure. Dev read PASS on 2026-11-05 (`.local/evidence-raw/alert-test-dev-20261105T055044Z.json`, unpublished), and prod-sim is NOT RUN | `ENV=dev` |
| `make test-load` | Runs the k6 load test and captures resource use. Needs one earlier `make test-e2e`. NOT RUN | `ENV=dev`, `THINK=0` |
| `make scan-images` | Scans every image the platform runs and reports it all. Fails on a fixable CRITICAL in an image built here, or a missed image | `SCAN_MIN_FREE_GIB`, `SCAN_FLOOR_GIB` |
| `make publish-evidence` | Copies `.local/evidence-raw/` to `docs/evidence/runs/` with secrets scrubbed. Fails on any gitleaks finding. See [the evidence index](evidence/README.md#publishing) | |

### Data

| Target | What it does | Parameters |
|---|---|---|
| `make backup` | Backs up to `.local/backups/<env>/<id>/` through a Job | `ENV=dev`, `prod-sim`, `infisical` or `all`, `KEEP=<count>`, `ALLOW_BACKUP_DURING_RESTORE=yes` |
| `make restore` | Restores a backup into the environment that took it. Refuses to overwrite a non-empty environment without `CONFIRM=yes` | `ENV`, `BACKUP=<backup-id or latest>`, `CONFIRM=yes` |
| `make restore-clean` | Brings the whole platform back into a clean environment, Infisical first. The script exits 2 if a proof could not run or a person must sign in, and `make` exits 2 on any failure. NOT RUN end to end | `BACKUP=<infisical-backup-id or latest>`, `PLAN_ONLY=yes`, `ENVS=dev`, `ALLOW_LOW_DISK="<reason>"`, `ALLOW_NO_SENTINEL=yes`, `ALLOW_NEWER_INFISICAL_BACKUP=yes`, `ALLOW_RESUME_OVERWRITE=yes` |
| `make rotate` | Rotates the Postgres credential through Infisical. NOT RUN | `ENV=dev`, `RESUME=yes` or `ROLLBACK=yes`. Prod-sim also needs `CONFIRM=yes` |

Details are in [data-operations.md](data-operations.md).

### Delivery

| Target | What it does | Parameters |
|---|---|---|
| `make render` | Re-renders Plane into `gitops/environments/`. See [kubernetes-helm.md](kubernetes-helm.md#render-flow) | |
| `make images` | Builds the four Wayline images from `apps/wayline/images.txt`, pushes them to `localhost:5001/wayline`, and writes their digests to `.build/digests.tsv` | |
| `make promote` | Moves image digests into an environment, re-renders, commits, publishes. Prod-sim also needs `plane-dev` Synced and Healthy with that digest in a ready container. With nothing to change it still publishes `main`. A publish that fails or is refused exits non-zero and leaves the commit on `main`, where it goes out with the next publish of any kind. It refuses a merge, cherry-pick or revert already under way. See [argocd.md](argocd.md#promotion) | `ENV`, `IMAGE`, `DIGEST`, `REPO`, `CONFIRM=yes`, `SKIP_BACKUP=yes`, `COMMIT=no`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make rollback` | `git revert` of the last promotion, then publish. `ENV=dev` stops before reverting if `main` holds a change to a prod-sim digest that Argo CD has not read, and names it. `make rollback ENV=prod-sim` withdraws that, and `OVERRIDE_DEV_CHECK` goes on and is logged. A real dev rollback ran on 2026-11-05 (`.local/evidence-raw/DEP-2-20261105T064032Z-rollback.txt`, unpublished) | `ENV`, `CONFIRM=yes`, `SKIP_BACKUP=yes`, `ROLLBACK_DUMP_TIMEOUT=<seconds>`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make gitops-publish` | Pushes `main` to the bare repo Argo CD reads. This is the only writer of that path | `SKIP_BACKUP=yes`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make ci` | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `security.sh`: the same scripts GitHub Actions runs | |
| `make wayline-upgrade-check`, `make wayline-upstream-check` | Check the branding against another upstream ref. See [apps/wayline/README.md](../apps/wayline/README.md) | `REF=<ref>` on the second |

### Drills

| Target | What it does | State on 2026-11-05 |
|---|---|---|
| `make drill-pod-restart ENV=dev` | Restarts each StatefulSet pod and proves the data survives | Dev read PASS on the final images, 07:04Z (`.local/evidence-raw/drill-pod-restart-dev-20261105T070414Z.log`, unpublished). Published: PASS in dev and in prod-sim, on upstream images, 2026-11-04. Not run on prod-sim on the final images. See [validation.md](validation.md) |
| `make drill-failed-deploy` | A bad image reaches dev through Git, the rollout refuses it, and a revert restores it. Dev only | Read PASS on the final images, 06:23Z (`.local/evidence-raw/drill-failed-deploy-20261105T062343Z.log`, unpublished). The old pod kept serving, and no alert fired: `ArgoSyncFailed` stayed pending for 13m45s against its 15m, because the revert ended it first |
| `tests/drills/failed-migrator.sh` | A backend image whose migrator exits 1 reaches dev through Git, the sync stops at wave 2, wave 3 does not move, and a revert restores it. Dev only. No make target | Read PASS on the final images, 06:49Z (`.local/evidence-raw/drill-failed-migrator-20261105T064940Z.log`, unpublished) |
| `make drill-clean-restore CONFIRM=yes` | Takes a backup, **deletes the cluster**, restores everything and proves it. `PLAN_ONLY=yes` stops before the delete | NOT RUN for the delete and restore. `PLAN_ONLY=yes` has run ([dr-drill-planonly-1.txt](evidence/runs/dr-drill-planonly-1.txt)) |
| `make drill-clean-restore-harness` | The order and refusals of a clean restore, with `kubectl`, `kind`, `docker`, Terraform and the API stubbed. Touches no cluster and proves no platform | Ran on stubs ([dr-harness-stubbed-1.txt](evidence/runs/dr-harness-stubbed-1.txt)). Later runs are in `.local/evidence-raw/`, unpublished |

## Teardown

Choose by what you need to keep.

| Command | Cluster and its volumes | Registry, caches | `.local/git`, `backups`, `secret-zero` | Consequence |
|---|---|---|---|---|
| `make down` | Stopped, kept | Stopped, kept | Kept | **No data loss.** `make up` resumes. [[VERIFY: all PVC data survives make down and make up]] |
| `make destroy CONFIRM=yes` | **Deleted** | Kept | Kept | Takes `backup.sh all` first, for Infisical, dev and prod-sim. If that fails, nothing is deleted. The local Terraform state is removed, and the Infisical one is kept |
| `make destroy CONFIRM=yes SKIP_BACKUP=yes` | **Deleted** | Kept | Kept | **Data since your last backup is gone** |
| `make destroy CONFIRM=yes PURGE=yes` | **Deleted** | **Deleted**, with their volumes | Kept | Branded images must be rebuilt and caches refill from upstream |

Four details that catch people:

- **`make destroy` after `make down`.** The pre-delete backup needs a reachable cluster. `backup.sh` exits and nothing is deleted. Run `make up` first, or pass `SKIP_BACKUP=yes` and accept the loss.
- **`.local/` is never deleted by a make target.** Removing it by hand removes the backups and `ENCRYPTION_KEY`. Do that only if you mean to lose them.
- **`kind delete cluster` by hand leaves stale Terraform state.** It describes resources that no longer exist. `make destroy` removes `.local/terraform/local` for this reason. It keeps `.local/terraform/infisical`, because that describes what is in the Infisical database, which a backup can bring back. After a manual delete, `make up` finds no cluster and moves the old state aside to `.local/terraform/local.stale-<time>`, so Terraform starts empty.
- **Disk may not come back.** Docker Desktop's docs say space inside the VM disk is not freed automatically. See the [Docker Desktop FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/). [[MEASURE: Docker.raw size before and after make destroy]]

### After a destroy

`make up` gives an empty platform, and Infisical seeds **new** Plane secrets. A Plane database is bound to the
`SECRET_KEY` it was written with, and `make restore` compares fingerprints and refuses a mismatch. So Infisical and Plane
restore as a matched set, Infisical first, which is what `make restore-clean BACKUP=latest` does. So far only its plan step and
rehearsals in throwaway places have run. See [data-operations.md](data-operations.md) and
[disaster-recovery.md](disaster-recovery.md). [[VERIFY: restore order after make destroy recovers Plane data and decrypts encrypted rows]]

## Common first-run failures

Rows quoting a script message come from the code. Others are expected from source reading.

| Symptom | Cause | Fix |
|---|---|---|
| `plane-dev has not proven these digests` | `main` brings prod-sim a digest that no ready container in `plane-dev` runs | Fix dev, or set `OVERRIDE_DEV_CHECK="<reason>"`, which is logged |
| `fail Docker has N GiB` | Docker memory below the 13 GiB check | Docker Desktop, Settings, Resources, Memory |
| `fail port 80 is in use by X` | Another listener | Stop it. kind binds exact ports |
| `only N GiB free on the host` | `guard_disk` refused | Free host space. Do not use `docker system prune -a` |
| `kind network is X, outside 172.16.0.0/12` | Custom Docker address pool | Change the daemon's pool, or see [troubleshooting](runbooks/troubleshooting.md) |
| Image pull 429 or `ImagePullBackOff` | Docker Hub anonymous quota. Pulls go through `plane-mirror-docker`, which fronts `mirror.gcr.io`, then fall back to Docker Hub | Wait for the quota window, or check the mirror with `docker logs plane-mirror-docker`. `docker login` on the host does not help pods. [[VERIFY: all pinned images pull through the mirror path]] |
| `kubectl` says the context does not exist | Your shell has no `KUBECONFIG` | See [Shell setup](#shell-setup) |
| Terraform: cannot reach the cluster | The providers read the kubeconfig during plan, and the node is stopped or absent | `scripts/cluster-up.sh` first, or `make up` |
| Terraform: namespace already exists | State was lost while the cluster lives | [terraform.md](terraform.md#state) |
| `Infisical is initialized, bootstrap works only once, and nothing here could replace the admin token` | `infisical-admin.json` is lost or ended, and a sign-in with `infisical-admin-password` could not mint another | Follow the steps it prints, and `infisical/README.md`, section Recovery |
| A committed fix does not reach the cluster | `make gitops-publish` not run, or the fix is uncommitted | Commit, publish, then see [argocd.md](argocd.md#retry-behaviour) |
| A change to `helm/values/argocd.yaml` does nothing | Terraform owns that release, not Argo CD | `terraform apply`. See [terraform.md](terraform.md#what-reaches-the-cluster-how) |
| Every UI times out while pods are Ready | NetworkPolicy on NodePort traffic at Traefik. The source is the kind gateway (`172.24.0.1` here), which `traefik-ingress` admits through `172.16.0.0/12`. Removing that block made a host request time out ([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)) | `make test-netpol`, then [security.md](security.md) |
| An internal UI answers 403 from the host | The kind network is outside the `node-network-only` allow list | Check the Docker network, as for the `kind network` row above |
| Pods restart with `OOMKilled` during first boot | Both environments booting together is the worst case for memory. On the staged boot, with dev then prod-sim, no Plane container restarted or was OOM-killed ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt), [monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)). The kills there were Grafana's sidecars at 96 MiB and `plane-registry` at 128 MiB, both since raised | Check `make status`. Stop unrelated containers. Change limits only with a measurement |
