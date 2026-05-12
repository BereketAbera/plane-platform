# Install and operate locally

Wayline is a customized Plane Community Edition v1.4.3 deployment (AGPL-3.0). It is not an original product. This
repository wraps upstream Plane in a local deployment platform on kind. It is production-inspired and it is not
production-ready. See [known-limitations.md](known-limitations.md).

**Status of this page.** It describes configuration and script behaviour read from the code. Anything that depends on
a real run carries a `[[VERIFY]]` or `[[MEASURE]]` marker until [validation.md](validation.md) and
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
| Free host disk | Fails below 25 GiB, warns below 35 GiB | The Docker VM reports hundreds of free GiB on its sparse disk, so nothing inside the cluster can see the real limit. Every script calls `guard_disk` for that reason |
| Host ports 80, 443, 5001 | Fails if held by anything except Docker | kind maps Traefik to `127.0.0.1:80` and `:443`. The registry is on `127.0.0.1:5001` |
| `docker`, `git`, `make`, `curl`, `jq`, `python3` on `PATH` | Fails if missing | Scripts call them directly |
| `*.localhost` resolving to loopback | Warns only | Hostnames need no `/etc/hosts` entry where the resolver supports this |
| `kind` Docker network inside `172.16.0.0/12` | `scripts/cluster-up.sh` fails otherwise | NetworkPolicies allow node-sourced traffic from Docker's default pool. A custom daemon pool would silently break them |
| Host platform | `darwin_arm64`, `linux_amd64`, `linux_arm64`, or `scripts/install-tools.sh` exits | `tools.lock` has checksums for those three only. Intel Macs are not covered |

Also used but not checked by `prereqs.sh`: `openssl` (`scripts/secret-zero.sh` checks it when it runs), `lsof`, `tar`,
`unzip`, and `shasum` or `sha256sum`. A Git identity is needed too, because `make promote` and `make rollback` commit.

The platform was built on `darwin_arm64`.
Other platforms have install paths and no recorded run. [[VERIFY: make setup and make up on linux_amd64 and linux_arm64]]

### Resource estimates

These are planning numbers. No full platform has been measured yet.

| Item | Value | How derived |
|---|---|---|
| Workload memory at idle, both environments | 5.5 to 9.3 GiB, estimate | Research critique section 4: a third-party idle figure for Plane v1.4.2, plus measurements of similar containers on the build host. Plane itself was not run for this number |
| Peak on the Docker VM, including 2 GiB of unrelated containers | 9.9 to 13.7 GiB, estimate | The idle estimate plus 0.4 GiB of VM overhead, 2 GiB of unrelated containers, and an estimated 2 GiB of bursts |
| Host disk growth | 16.7 to 22 GiB, estimate | Image sizes summed from registry layer metadata (8.56 GiB unpacked), plus estimates for volumes, logs, build bases and tools |

The critique's recommendation follows from those estimates: 14 GiB of Docker memory with unrelated containers stopped,
16 GiB if they must keep running.

- [[MEASURE: idle and peak memory of the Docker VM with both environments up]]
- [[MEASURE: Docker.raw growth and host free disk after a first make up]]

The results belong in [resource-utilization.md](resource-utilization.md).

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

`make up` is the idempotent create-or-resume entry point.
[[VERIFY: scripts/up.sh exists and runs the sequence below; the file was absent at commit 2faaed5, so make up failed with exit 127 at that point]]

The intended sequence is below. It comes from the contract's ownership table and the integration review.

| # | Step | Script or owner | What it needs and what it leaves |
|---|---|---|---|
| 1 | Create the cluster and start local services | `scripts/cluster-up.sh` | Creates one node on Kubernetes v1.36.4, then starts the registry, three pull-through caches and the `git://` remote through Compose |
| 2 | Publish `main` | `scripts/gitops-publish.sh` | Creates `.local/git/plane-platform.git` if absent and pushes `main`. It runs before Terraform so the root Application's first compare has a repository |
| 3 | Apply the foundation | Terraform, `infrastructure/terraform/environments/local` | Namespaces, quotas, LimitRanges, CoreDNS rewrite, Argo CD, AppProjects, root Application. See [terraform.md](terraform.md) |
| 4 | Create secret zero | `scripts/secret-zero.sh` | Generates files in `.local/secret-zero/` and applies three Secrets to `infisical`. It needs the namespace from step 3 |
| 5 | Wait for Traefik | Argo CD | Waves -10 to -9. Nothing has a route before this |
| 6 | Bootstrap Infisical | `scripts/infisical-bootstrap.sh` | Needs `http://infisical.localhost`. Creates the first admin, applies `infisical/terraform`, seeds values, publishes identity ids |
| 7 | Wait for every Application | Argo CD | Plane dev at wave -1, prod-sim at wave 0. See [argocd.md](argocd.md) |

- [[MEASURE: wall-clock time of a first make up, per step]]
- [[MEASURE: wall-clock time of make up when resuming after make down]]

### What looks broken but is expected

These come from reading the code and upstream sources. Each one needs confirming on a real first boot.

| What you see | Why | Ends when |
|---|---|---|
| `argocd.localhost` does not answer | The route needs Traefik's CRD and syncs at wave -8 | Traefik is Healthy. Until then use `kubectl -n argocd port-forward svc/argocd-server 8080:80`. [[VERIFY: port-forward path works before Traefik exists]] |
| Infisical Postgres and Redis in `CreateContainerConfigError` | They wait for Secrets from `scripts/secret-zero.sh` | Step 4 finishes. [[VERIFY: pods recover without intervention after secret zero]] |
| `plane-dev` Degraded, `InfisicalAuth` not ready | `plane-infisical-identity` does not exist until step 6 | Step 6 publishes it. [[VERIFY: plane-dev leaves Degraded on its own after bootstrap]] |
| Prod-sim operator crash-looping | Only `infisical-operator-dev` installs the CRDs, and both sit in wave -3 | The dev release has installed them. [[VERIFY: prod-sim operator recovers after CRDs exist]] |
| Application phase `Running` for a long time, with a retry message | Retries have no limit, so a failing sync reads as `Running`. See [argocd.md](argocd.md#retry-behaviour) | The cause is fixed, or the operation is terminated |

## Local URLs

Everything is on loopback over plain HTTP. kind binds only `127.0.0.1`. TLS is out of scope in Pass 1.

| URL | Service | Sign-in | Where the credential comes from |
|---|---|---|---|
| `http://plane.dev.localhost` | Plane dev | Workspace user | See [Plane accounts](#plane-accounts) |
| `http://plane.prod-sim.localhost` | Plane prod-sim | Workspace user | See [Plane accounts](#plane-accounts) |
| `http://plane.dev.localhost/god-mode/` | Plane instance admin | Instance admin | See [Plane accounts](#plane-accounts) |
| `http://argocd.localhost` | Argo CD | `admin` | Secret `argocd/argocd-initial-admin-secret`, generated by Argo CD at first start |
| `http://grafana.localhost` | Grafana | `admin` | Secret `monitoring/kps-grafana`, key `admin-password`, generated by the chart |
| `http://prometheus.localhost` | Prometheus | None | The route has no auth middleware |
| `http://alertmanager.localhost` | Alertmanager | None | The route has no auth middleware |
| `http://infisical.localhost` | Infisical | `admin@wayline.localhost` | `.local/secret-zero/infisical-admin-password` |

Prometheus and Alertmanager rely on the loopback binding alone. Nothing in the repository authenticates them.

[[VERIFY: all seven hosts answer through Traefik with the status make status prints]]
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
`PLANE_DEV_ADMIN_PASSWORD` and `PLANE_PROD_SIM_ADMIN_PASSWORD`.

```bash
make test-e2e ENV=dev

cut -d= -f1 .local/test-accounts.env                      # names only
grep '^PLANE_DEV_ADMIN_EMAIL=' .local/test-accounts.env | cut -d= -f2- | tr -d '\n' | pbcopy
grep '^PLANE_DEV_ADMIN_PASSWORD=' .local/test-accounts.env | cut -d= -f2- | tr -d '\n' | pbcopy
```

**Admin sign-up is one-shot per instance.** Whoever reaches `/god-mode/` first becomes the instance admin. If you
create the admin by hand, `smoke.py` has no credentials for that instance and stops with an error
(`tests/e2e/smoke.py:519`), and `make test-load` depends on the same account. Run `make test-e2e` first unless you want
to supply those credentials yourself.

[[VERIFY: make test-e2e creates the admin and writes .local/test-accounts.env in both environments]]

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
| `evidence-raw/` | Unedited run logs | Evidence for runs that have not been curated yet |
| `test-accounts.env` | Generated test credentials | The account becomes unusable. See above |

## Make targets

`make help` lists these from the Makefile. Pass parameters as `make target KEY=value`. Make exports them to the script.

### Lifecycle

| Target | What it does | Parameters |
|---|---|---|
| `make help` | Lists targets. The default goal | |
| `make setup` | Runs `scripts/install-tools.sh`, then `scripts/prereqs.sh` | |
| `make up` | Creates or resumes the whole platform. Calls `scripts/up.sh` | [[VERIFY: scripts/up.sh exists]] |
| `make down` | Stops the node and the local services. Keeps all data | |
| `make destroy` | Deletes the cluster and its data. See [Teardown](#teardown) | `CONFIRM=yes` (required), `SKIP_BACKUP=yes`, `PURGE=yes` |
| `make status` | Read-only summary: node, Applications, unready pods, endpoints, resources, host disk | |
| `make logs` | Tails one Plane workload, or lists workloads when `SVC` is empty | `ENV=dev`, `SVC=api` |

### Verification

| Target | What it does | Parameters |
|---|---|---|
| `make test` | Gates, the NetworkPolicy matrix, and smoke tests in both environments. Calls `scripts/test.sh` | [[VERIFY: scripts/test.sh exists; it was absent at commit 2faaed5]] |
| `make gates` | Runs `tests/gates/day1.sh`, the cheap runtime checks for assumptions source reading cannot settle | |
| `make test-e2e` | End-to-end smoke test through `scripts/test.sh e2e` | `ENV=dev` |
| `make test-netpol` | Runs the allow and deny matrix in `tests/network-policy-matrix.yaml` | |
| `make test-alert` | Proves alert delivery end to end. Pauses auto-sync while it injects a failure | `ENV=dev` |
| `make test-load` | Runs the k6 load test and captures resource use. Needs one earlier `make test-e2e` | `ENV=dev` |

### Data

| Target | What it does | Parameters |
|---|---|---|
| `make backup` | Backs up to `.local/backups/<env>/<id>/` through a Job | `ENV=dev`, `prod-sim`, `infisical` or `all` |
| `make restore` | Restores a backup into the environment that took it. Refuses to overwrite a non-empty environment without `CONFIRM=yes` | `ENV`, `BACKUP=<backup-id or latest>`, `CONFIRM=yes` |
| `make rotate` | Rotates the Postgres credential through Infisical | `ENV=dev`. Prod-sim also needs `CONFIRM=yes` |

The Makefile's help text says `BACKUP=<dir>`. `scripts/restore.sh` takes a backup id or `latest`. Details are in
[data-operations.md](data-operations.md).

### Delivery

| Target | What it does | Parameters |
|---|---|---|
| `make render` | Re-renders Plane into `gitops/environments/`. See [kubernetes-helm.md](kubernetes-helm.md#render-flow) | |
| `make images` | Builds Wayline images and pushes to `localhost:5001/wayline`. Exits with a warning and builds nothing when `apps/wayline/images.txt` is absent | [[VERIFY: apps/wayline/images.txt exists; it was absent when this was written]] |
| `make promote` | Moves image digests into an environment, re-renders, commits, publishes. See [argocd.md](argocd.md#promotion) | `ENV`, `IMAGE`, `DIGEST`, `REPO`, `CONFIRM=yes`, `SKIP_BACKUP=yes`, `COMMIT=no` |
| `make rollback` | `git revert` of the last promotion, then publish | `ENV`, `CONFIRM=yes`, `SKIP_BACKUP=yes` |
| `make gitops-publish` | Pushes `main` to the bare repo Argo CD reads. This is the only writer of that path | `SKIP_BACKUP=yes` |
| `make ci` | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `security.sh`: the same scripts GitHub Actions runs | |

### Drills

Contract section 11 names `drill-*` targets. The Makefile has none at commit 2faaed5, so run the scripts directly.
[[VERIFY: make drill-* targets exist, or the contract is corrected]]

```bash
tests/drills/failed-deploy-rollback.sh
tests/drills/pod-restart-persistence.sh dev
```

## Teardown

Choose by what you need to keep.

| Command | Cluster and its volumes | Registry, caches | `.local/git`, `backups`, `secret-zero` | Consequence |
|---|---|---|---|---|
| `make down` | Stopped, kept | Stopped, kept | Kept | **No data loss.** `make up` resumes. [[VERIFY: all PVC data survives make down and make up]] |
| `make destroy CONFIRM=yes` | **Deleted** | Kept | Kept | Takes `backup.sh all` first, for Infisical, dev and prod-sim. If that fails, nothing is deleted. Terraform state is removed |
| `make destroy CONFIRM=yes SKIP_BACKUP=yes` | **Deleted** | Kept | Kept | **Data since your last backup is gone** |
| `make destroy CONFIRM=yes PURGE=yes` | **Deleted** | **Deleted**, with their volumes | Kept | Branded images must be rebuilt and caches refill from upstream |

Four details that catch people:

- **`make destroy` after `make down`.** The pre-delete backup needs a reachable cluster. `backup.sh` exits and nothing is deleted. Run `make up` first, or pass `SKIP_BACKUP=yes` and accept the loss.
- **`.local/` is never deleted by a make target.** Removing it by hand removes the backups and `ENCRYPTION_KEY`. Do that only if you mean to lose them.
- **`kind delete cluster` by hand leaves stale Terraform state.** The next apply plans against resources that no longer exist. `make destroy` removes `.local/terraform/local` and `.local/terraform/infisical` for this reason. After a manual delete, remove those two directories yourself.
- **Disk may not come back.** Docker Desktop's docs say space inside the VM disk is not freed automatically. See the [Docker Desktop FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/). [[MEASURE: Docker.raw size before and after make destroy]]

### After a destroy

`make up` gives an empty platform, and Infisical seeds **new** Plane secrets. A Plane database is bound to the
`SECRET_KEY` it was written with, and `make restore` compares fingerprints and refuses a mismatch. So Infisical and Plane
restore as a matched set, Infisical first. See [data-operations.md](data-operations.md) and
[disaster-recovery.md](disaster-recovery.md). [[VERIFY: restore order after make destroy recovers Plane data and decrypts encrypted rows]]

## Common first-run failures

Rows quoting a script message come from the code. Others are expected from source reading.

| Symptom | Cause | Fix |
|---|---|---|
| `make up` exits 127 | `scripts/up.sh` is missing | See the marker under [First run](#first-run) |
| `fail Docker has N GiB` | Docker memory below the 13 GiB check | Docker Desktop, Settings, Resources, Memory |
| `fail port 80 is in use by X` | Another listener | Stop it. kind binds exact ports |
| `only N GiB free on the host` | `guard_disk` refused | Free host space. Do not use `docker system prune -a` |
| `kind network is X, outside 172.16.0.0/12` | Custom Docker address pool | Change the daemon's pool, or see [troubleshooting](runbooks/troubleshooting.md) |
| Image pull 429 or `ImagePullBackOff` | Docker Hub anonymous quota. Pulls go through `plane-mirror-docker`, which fronts `mirror.gcr.io`, then fall back to Docker Hub | Wait for the quota window, or check the mirror with `docker logs plane-mirror-docker`. `docker login` on the host does not help pods. [[VERIFY: all pinned images pull through the mirror path]] |
| `kubectl` says the context does not exist | Your shell has no `KUBECONFIG` | See [Shell setup](#shell-setup) |
| Terraform: cannot reach the cluster | The providers read the kubeconfig during plan, and the node is stopped or absent | `scripts/cluster-up.sh` first, or `make up` |
| Terraform: namespace already exists | State was lost while the cluster lives | [terraform.md](terraform.md#state) |
| `Infisical is initialized but ... is missing` | `infisical-admin.json` lost. Bootstrap works only once | `infisical/README.md`, section Recovery |
| A committed fix does not reach the cluster | `make gitops-publish` not run, or the fix is uncommitted | Commit, publish, then see [argocd.md](argocd.md#retry-behaviour) |
| A change to `helm/values/argocd.yaml` does nothing | Terraform owns that release, not Argo CD | `terraform apply`. See [terraform.md](terraform.md#what-reaches-the-cluster-how) |
| Every UI times out while pods are Ready | NetworkPolicy on NodePort traffic at Traefik | `make test-netpol`, then [security.md](security.md). [[VERIFY: NodePort traffic is admitted by the traefik-ingress policy]] |
| Pods restart with `OOMKilled` during first boot | Both environments booting together is the worst case for memory | Check `make status`. Stop unrelated containers. Change limits only with a measurement. [[VERIFY: first boot of both environments stays inside memory limits]] |
