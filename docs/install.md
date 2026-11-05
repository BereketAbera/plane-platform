# Install and operate locally

Wayline is a customized Plane Community Edition v1.4.3 deployment (AGPL-3.0). It is not an original product. This
repository wraps upstream Plane in a local deployment platform on kind. It is local and production-inspired, and it makes no
claim of being ready for production. See [known-limitations.md](known-limitations.md).

**Status of this page.** It describes configuration and script behaviour read from the code, with results from real runs
where they exist, as of 2026-11-05. Two installs from a fresh clone have run: a cold one, with the registry and caches gone, which is the sequence a new machine needs, and one that kept them ([First run](#first-run)). A full restore
into a new cluster has run on the merged recovery code ([After a destroy](#after-a-destroy)). **As this is written, `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, started at 13:06Z,
has deleted the cluster and is rebuilding it, and its result is in progress** ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), published when it ends). Do not read an unmarked command as a tested command. It means only that the claim does not depend on a runtime result.

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
| Node 22 with corepack, `rsync`, `perl` | Warns only | Only the image build needs them: `make images`, or a `make up` that finds images missing from the registry. A new machine's first `make up` is that case, so it needs them |
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
([INST-3-20261105T061554Z.txt](evidence/runs/INST-3-20261105T061554Z.txt)). A clean install there needs space freed first.

### Resource use

Measured on the build laptop, with Docker Desktop set to 14 GiB and 12 CPUs and the owner's other containers running. The main readings are three windows on 2026-11-05, on the final images,
restored into a new cluster, and older rows say so. Each window is one run, and the cluster was young. [resource-utilization.md](resource-utilization.md) has the
conditions and the rest.

| Item | Value | Source |
|---|---|---|
| Docker VM used, idle | 8.65 GiB average, 8.79 top, of 13.63 GiB | 08:47:35Z to 08:56:59Z on 2026-11-05 ([windows](evidence/runs/LOAD-3-20261105T092547Z-prometheus-windows.json)) |
| Docker VM used, load with think time | 8.80 GiB average, 8.90 top | `make test-load ENV=dev` on the final images, 09:03Z to 09:12Z ([results.json](evidence/runs/load-20261105T090247Z/results.json)) |
| Docker VM used, load with no think time | 8.93 GiB average, 9.05 top, with at most 2.49 of 12 CPUs busy | `THINK=0 make test-load ENV=dev`, 09:12Z to 09:21Z ([results.json](evidence/runs/load-20261105T091213Z/results.json)). No memory limit came close. Postgres's 500 m CPU limit is what bound |
| Docker VM used, highest sampled | 10.93 GiB | Earlier cluster, 2026-11-05T01:50:00Z, in 60-second readings from 00:35Z, with its cause not read ([timeline](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)) |
| Swap used, highest read | 0.78 GiB of 2 GiB | Earlier cluster, Prometheus, in the quiet window of 2026-11-05T03:40Z to 04:10Z ([windows](evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)) |
| Host disk growth, cold install | 18 GiB: host free went from 31 GiB to 13 GiB, by `df` in whole GiB | 10:55:46Z to 12:40:48Z ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt), [disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). One run, and not a clean figure. It holds the clone, a copy of `.tools`, both the broken and the fixed images, and the second build's source tree, package store and 2.665 GB of build cache, because the defect under [First run](#first-run) made it build twice. The first build's files had been removed by 11:13:10Z, when host free read 29 GiB. The estimate was 19.5 to 24.8 GiB. A cold install with no defect: Not measured in Pass 1 |
| Host disk growth, registry and caches kept | 12 GiB: host free went from 31 GiB to 19 GiB, by `df` in whole GiB, the clone included | The clean install, with the registry, caches and node image already on disk ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt), [status](evidence/runs/clean-install-20261105T075041Z/make-status.txt)) |
| Disk on the running platform | 18.81 GiB, a sum of sizes | 2026-11-05T09:25:50Z to 09:25:54Z: the node's volume, the local services' volumes and images, the node image, `.tools`, `.local` and `.build` ([derived](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)). Not a before and after of a clean install |

Research recommended 14 GiB of Docker memory with unrelated containers stopped, and 16 GiB if they must keep running. So far, 14 GiB has
held with them running, through both load passes. The ceiling those found was Postgres's CPU limit, not memory, and one run of each does not show a margin.

31 GiB free was enough for the cold install, and 13 GiB was the lowest reading taken. Host free at the low point during an image build: Not measured in Pass 1. `Docker.raw` read 40,060,992 KiB, 38.21 GiB, by `du -sk` after the cold install ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). The same file before it: Not measured in Pass 1.

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

**On a new machine.** This is the sequence the cold install ran on 2026-11-05 at `18af97a`, on a fresh clone with no `.local` and no `.build`, after `make destroy` with `PURGE=yes` had removed the cluster, the registry and the caches ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt)).

```bash
make setup
git status --short     # Argo CD reads commits on main only, so commit first
make up                # creates the cluster and local services, builds the images, then stops with an error, on purpose
make promote ENV=dev
make promote ENV=prod-sim CONFIRM=yes SKIP_BACKUP=yes OVERRIDE_DEV_CHECK="first install on a new machine: nothing is running yet"
make up                # pulls everything through empty caches
make status
make test-e2e ENV=dev
make test-e2e ENV=prod-sim
```

**Why it stops.** The digests in Git were built on the owner's Mac and exist in no registry here, and a rebuild gives new ones. So the first `make up` builds, finds those digests still missing, publishes nothing, prints these commands and exits non-zero ([log](evidence/runs/clean-install-20261105T105546Z/make-up-stops-on-new-digests.txt)). The override is there because nothing runs yet, so `plane-dev` cannot have proven a digest. `make up` prints it with a different reason. The reason is free text, and it goes to `.local/evidence-raw/promotion-overrides.log` ([log](evidence/runs/clean-install-20261105T105546Z/clone-evidence/promotion-overrides.log)). `SKIP_BACKUP=yes` is there because prod-sim has no data to back up. Each `make promote` commits to `main` and publishes it, and warns that those commits are not on `origin/main`, which is expected here.

| Step | Result on this laptop | Evidence |
|---|---|---|
| `make setup` | Exit 0 in 3 s. It checked `.tools` and did not download it, because the drill copied them. A new machine's tool downloads: Not tested in Pass 1 | [output](evidence/runs/clean-install-20261105T105546Z/make-setup.txt) |
| First `make up` | Created the cluster and local services, built the images and stopped, in 1,008 s | [log](evidence/runs/clean-install-20261105T105546Z/make-up-stops-on-new-digests.txt) |
| `make promote ENV=dev`, then `ENV=prod-sim` | 10 s and 3 s | [dev](evidence/runs/clean-install-20261105T105546Z/make-promote-dev.txt), [prod-sim](evidence/runs/clean-install-20261105T105546Z/make-promote-prod-sim.txt) |
| Second `make up` | Exit 0 in 5,238 s, all 14 Applications Synced and Healthy. **That is not the time of a good install**, see below | [log](evidence/runs/clean-install-20261105T105546Z/make-up.txt), [Applications](evidence/runs/clean-install-20261105T105546Z/apps-after-up.txt), [status](evidence/runs/clean-install-20261105T105546Z/make-status.txt) |
| First `make test-e2e` | Dev 46 PASS in 109 s, prod-sim 45 PASS in 22 s, no SKIP, and `branding-fresh-install` passed in both | [dev](evidence/runs/clean-install-20261105T105546Z/clone-evidence/smoke-dev-20261105T124049Z-24505.json), [prod-sim](evidence/runs/clean-install-20261105T105546Z/clone-evidence/smoke-prod-sim-20261105T124237Z-98783.json) |
| `make test-infisical` | PASS, 15 s | [output](evidence/runs/clean-install-20261105T105546Z/test-infisical.txt) |
| `make up` once more | 16 s, with the same pod uids | [output](evidence/runs/clean-install-20261105T105546Z/make-up-again.txt), [summary](evidence/runs/clean-install-20261105T105546Z/summary.txt) |
| Terraform plan | No changes | [plan](evidence/runs/clean-install-20261105T105546Z/terraform-plan-local.txt) |
| `make restore` with a backup from another install | Refused on `SECRET_KEY`, and changed nothing | [refusal](evidence/runs/clean-install-20261105T105546Z/restore-foreign-key-refused.txt) |

**What the 5,238 s holds.** A real defect. The drill ran under `umask 077`, so every file in the build contexts was 0600, and the images' non-root users could not read their own files. web, admin, space and api crashed at start with Permission denied, while worker, beat and live ran. No build step noticed, and `make up` gave no explanation: it printed `plane-dev=OutOfSync/Degraded` every minute from 865 s to 2,407 s of its last wait ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)). `6f5a426` fixes it, with `chmod -R a+rX` on each context in `scripts/ci/build-images.sh`. Under the same umask `make images` then took 598 s, and that build was promoted into the same cluster ([rebuild](evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt)). The stuck operation was ended with [the runbook's Terminating patch](runbooks/argo-sync-stuck.md#end-an-operation), and `plane-dev` and `plane-prod-sim` came up healthy ([timeline](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)). The pods' crash logs and that patch were read and run by hand, and no file holds them. The rebuild's header, the comment in `6f5a426` and the `make up` log are the record.

**How much that cost.** The Infisical step ended at about 11:51:28Z, 2,298 s into that `make up`. `plane-dev`'s good sync ran from 12:31:17Z to 12:32:35Z, and `plane-prod-sim`'s from 12:37:10Z to 12:40:23Z ([timeline](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)). So at most about 46 minutes went on the defect, 11:51:28Z to 12:37:10Z, less the time a healthy `plane-dev` first boot takes, which this run does not show. **A full cold install with no defect has not been timed end to end.** The defect did not touch those first 2,298 s, which on this laptop's connection hold the slow cold pulls: `kube-prometheus-stack`'s first sync started 17.5 minutes after `metrics-server`'s, and Infisical's ran from 11:45:01Z to 11:50:58Z. The steps this run did time add up to about 59 minutes, counting the build and with no healthy `plane-dev` first boot in that sum, which is arithmetic and not a timed install. The fix has run through `make images` and that promotion, not through a whole cold install from its start.

**With the registry and caches kept**, one `make up` from nothing exited 0 in 955 s on 2026-11-05 at `7d5ff62`, on a fresh clone with new secrets, with all 14 Applications Synced and Healthy ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt), [Applications](evidence/runs/clean-install-20261105T075041Z/apps-after-up.txt)). That is the good figure, and it does not build or pull from the internet. `make test-e2e` then passed with no SKIP, 46 PASS in dev and 45 in prod-sim ([dev](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-dev-20261105T080642Z-65896.json), [prod-sim](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-prod-sim-20261105T080826Z-22080.json)). There one `make up` is all it takes, and `make status` shows the result.

`make up` is the idempotent create-or-resume entry point, in `scripts/up.sh`. It refuses uncommitted changes under `gitops/`, `helm/`,
`monitoring/` and `infisical/`, because Argo CD reads only commits. `UP_STOP_AFTER=<step>` stops after one step, and any step can be
run again. Before those runs it ran in stages with `UP_STOP_AFTER` on 2026-11-04 ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt)), with some steps by hand, among them prod-sim's ServiceAccounts and Infisical CRs ahead of root's wave 0
([infisical-prod-sim-crs-1.txt](evidence/runs/infisical-prod-sim-crs-1.txt)). [Registry lost](disaster-recovery.md#scenario-registry-lost) has the way to keep a digest by copying it.

The sequence:

| # | Step | Script or owner | What it needs and what it leaves |
|---|---|---|---|
| 1 | Create the cluster and start local services (`cluster`) | `scripts/cluster-up.sh` | Creates one node on Kubernetes v1.36.4, then starts the registry, three pull-through caches and the `git://` remote through Compose |
| 2 | Publish `main` (`publish`) | `scripts/gitops-publish.sh` | Checks that the local registry can serve every digest the rendered manifests name, and rebuilds if not. If the rebuild gives other digests, which it does on a new machine, `make up` stops here and names what to run. Creates `.local/git/plane-platform.git` if absent and pushes `main`. It runs before Terraform so the root Application's first compare has a repository. On a first run prod-sim has no database, so this logs that and goes on. Once prod-sim has a database, it stops here if `main` brings prod-sim a digest that `plane-dev` is not running |
| 3 | Apply the foundation (`terraform`) | Terraform, `infrastructure/terraform/environments/local` | Namespaces, quotas, LimitRanges, CoreDNS rewrite, Argo CD, AppProjects, root Application. See [terraform.md](terraform.md) |
| 4 | Create secret zero (`secret-zero`) | `scripts/secret-zero.sh` | Generates files in `.local/secret-zero/` and applies three Secrets to `infisical`. It needs the namespace from step 3 |
| 5 | Wait for Traefik (`traefik`) | Argo CD | Waves -10 to -9, then a real request to `http://argocd.localhost/`, which fails fast on NodePort and NetworkPolicy trouble |
| 6 | Bootstrap Infisical (`infisical`) | `scripts/infisical-bootstrap.sh` | Waits up to 2400 s for `http://infisical.localhost`, which is behind the monitoring waves. Creates the first admin, applies `infisical/terraform`, seeds values, publishes identity ids |
| 7 | Wait for every Application | Argo CD | All 14 Synced and Healthy, after asking each to refresh. Plane dev is at wave -1, prod-sim at wave 0. See [argocd.md](argocd.md). All 14 Synced and Healthy says nothing about Plane itself, so run `make test` next |

`UP_WAIT_TRAEFIK_SECONDS`, `UP_WAIT_ROUTE_SECONDS`, `UP_WAIT_INFISICAL_SECONDS` and `UP_WAIT_APPS_SECONDS` override the waits. Staged times are
in [resource-utilization.md](resource-utilization.md#boot-and-start-times).

- One `make up` from nothing: 955 s, with the registry and caches on disk ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt)). With them gone, the steps and what is not timed are above.
- `make up` when resuming after `make down`: 82 s, and `make down` took 15 s ([PERS-3](evidence/runs/PERS-3-20261105T083304Z.txt)).

### What looks broken but is expected

Seen on the staged first boot on 2026-11-04, unless the row says otherwise.

| What you see | Why | Ends when |
|---|---|---|
| `argocd.localhost` does not answer | The route needs Traefik's CRD and syncs at wave -8 | Traefik is Healthy. Until then use `kubectl -n argocd port-forward svc/argocd-server 8080:80`. That path before Traefik exists: Not tested in Pass 1 |
| Infisical Postgres and Redis in `CreateContainerConfigError` | They wait for Secrets from `scripts/secret-zero.sh`. Expected from reading, and not seen in the staged run, where secret zero ran well before wave -4 | Step 4 finishes. That recovery: Not tested in Pass 1 |
| `plane-dev` Degraded, `InfisicalAuth` not ready | `plane-infisical-identity` does not exist until step 6 | Step 6 publishes it, and the next retry moves on with no help, up to 5 minutes later: published at 21:25:44, retried at 21:28:54 ([infisical-unready-sync-1.txt](evidence/runs/infisical-unready-sync-1.txt)) |
| `kube-prometheus-stack` Degraded for about 9 minutes, with root failing and retrying | Its images pull through the mirror one at a time, and Argo CD's built-in check read a Prometheus with no ready pod as Degraded | It took 591 s on the staged boot ([bootstrap-1.txt](evidence/runs/bootstrap-1.txt), [timeline](evidence/runs/bootstrap-timeline-1.txt)). Root reached the next wave on its fourth retry, 3 minutes later. An override since reads that state as Progressing, with root waiting and no retry. That has been shown on a restart ([h43-repro-after-1.txt](evidence/runs/h43-repro-after-1.txt)) and on the cold install's first boot, where it read Progressing and not Degraded from 1,090 s to 1,393 s of the wait for Infisical ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)) |
| `metrics-server` and root Degraded for about 6 minutes, on a cold install | Seen in the cold install, from 605 s to 968 s of the wait for Infisical. Its first sync started at 11:18:33Z, and `kube-prometheus-stack`'s, the next wave, at 11:36:01Z. Which pull it waited on was not read | It ended with no help, Healthy by 1,029 s ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt), [timeline](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)) |
| `plane-dev` Progressing for minutes in wave 3 | The kubelet pulls one image at a time. The last of four was ready after 448 s ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)) | `progressDeadlineSeconds` is now 600 s, because the old 360 s was shorter than those 448 s. That the deadline failed that boot and a retry recovered it is unrecorded: no saved file holds it, only the comment in `helm/plane/components/hardening/kustomization.yaml` |
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
([plane-prod-sim-status-1.txt](evidence/runs/plane-prod-sim-status-1.txt)), and the same after a stop and resume on 2026-11-05 ([PERS-3](evidence/runs/PERS-3-20261105T083304Z.txt)).

Prometheus and Alertmanager have no login. All five internal UIs carry a `node-network-only` allow list on `172.16.0.0/12`, because a Plane
`api` pod can reach Traefik: the host arrives as the kind gateway and gets through, and a pod gets 403
([routes-after-2.txt](evidence/runs/routes-after-2.txt)). That is a source-address check, not a login, and [monitoring/README.md](../monitoring/README.md) lists what
it does not stop.

Session cookies are host-only, so a dev session gets 401 on the prod-sim host ([plane-dev-cookies-1.txt](evidence/runs/plane-dev-cookies-1.txt)).
A real browser session has run in Chromium ([record](evidence/branding/live-dev/README.md)). On 2026-11-05 one
Chromium profile signed in on dev got 401 on the prod-sim host ([AUTH-4-20261105T062750Z.txt](evidence/runs/AUTH-4-20261105T062750Z.txt)). After the restore, that browser held a session on both hosts at once, with `GET /api/users/me/` answering 200 in each tab ([record](evidence/branding/live-final/README.md)).

`*.localhost` resolution and cookie separation in Safari and Firefox: Not tested in Pass 1.

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
| `publishes.log` | Which publish first sent each promotion. `make rollback` reads it to say what to restore | Rollback falls back to the commit time |
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
| `make test` | Gates, the NetworkPolicy matrix, Infisical isolation, internal routes, smoke tests in both environments, and the separation checks, in that order, carrying on after a failure. Calls `scripts/test.sh`. Read PASS in full on the restored platform on 2026-11-05, ending 08:45Z ([output](evidence/runs/MAKE-TEST-20261105T083455Z.txt)). [validation.md](validation.md) says what has run | |
| `make gates` | Runs `tests/gates/day1.sh`, the cheap runtime checks for assumptions source reading cannot settle | |
| `make test-e2e` | End-to-end smoke test through `scripts/test.sh e2e` | `ENV=dev` |
| `make test-netpol` | Runs the allow and deny matrix in `tests/network-policy-matrix.yaml` | `FROM_NS=plane-dev` limits it to one source namespace |
| `make test-infisical` | Each environment's identity is refused the other's project, and the rendered Secrets match the contract | |
| `make test-routes` | Who can reach the internal UIs through Traefik: the host can, a Plane `api` pod cannot | |
| `make test-separation` | Real attempts between dev and prod-sim, and what each holds. Needs `make test-e2e` to have run in both | |
| `make test-alert` | Exercises alert delivery end to end. Pauses auto-sync while it injects a failure. Read PASS in dev and prod-sim on 2026-11-05, each with the other quiet ([dev](evidence/runs/alert-test-dev-20261105T055044Z.json), [prod-sim](evidence/runs/alert-test-prod-sim-20261105T072541Z.json)). The sink prints lines, and nothing pages a person | `ENV=dev` |
| `make test-load` | Runs the k6 load test and captures resource use. Needs one earlier `make test-e2e`. On a quiet cluster on 2026-11-05, on dev: with `THINK=1`, which sleeps 1 to 3 s between requests, it read PASS on its thresholds ([results.json](evidence/runs/load-20261105T090247Z/results.json)). `THINK=0` found the ceiling, about 8.9 requests a second, with Postgres at its 500 m CPU limit. It exits 2 when k6 crosses a threshold, and its numbers still stand ([results.json](evidence/runs/load-20261105T091213Z/results.json)) | `ENV=dev`, `THINK=0` |
| `make scan-images` | Scans every image the platform runs and reports it all. Fails on a fixable CRITICAL in an image built here, or a missed image | `SCAN_MIN_FREE_GIB`, `SCAN_FLOOR_GIB` |
| `make publish-evidence` | Copies `.local/evidence-raw/` to `docs/evidence/runs/` with secrets scrubbed. Fails on any gitleaks finding. See [the evidence index](evidence/README.md#publishing) | |

### Data

| Target | What it does | Parameters |
|---|---|---|
| `make backup` | Backs up to `.local/backups/<env>/<id>/` through a Job | `ENV=dev`, `prod-sim`, `infisical` or `all`, `KEEP=<count>`, `ALLOW_BACKUP_DURING_RESTORE=yes` |
| `make restore` | Restores a backup into the environment that took it. Refuses to overwrite a non-empty environment without `CONFIRM=yes`. Read PASS in place in dev and prod-sim on 2026-11-05 ([dev](evidence/runs/restore-dev-20261105T074337Z.json), [prod-sim](evidence/runs/restore-prod-sim-20261105T073438Z.json)), and it refused with no `CONFIRM` ([refusal](evidence/runs/restore-prod-sim-20261105T073428Z.json)) | `ENV`, `BACKUP=<backup-id or latest>`, `CONFIRM=yes` |
| `make restore-clean` | Brings the whole platform back into a clean environment, Infisical first. The script exits 2 if a proof could not run or a person must sign in, 4 if it overwrote what `ALLOW_RESUME_OVERWRITE` named, and `make` exits 2 on any failure. Two real runs read PASS on every step on 2026-11-05 ([first](evidence/runs/restore-clean-20261105T081017Z.json), [on the merged recovery code](evidence/runs/restore-clean-20261105T124518Z.json)). See [After a destroy](#after-a-destroy) | `BACKUP=<infisical-backup-id or latest>`, `PLAN_ONLY=yes`, `ENVS=dev`, `ALLOW_LOW_DISK="<reason>"`, `ALLOW_NO_SENTINEL=yes`, `ALLOW_NEWER_INFISICAL_BACKUP=yes`, `ALLOW_RESUME_OVERWRITE="dev prod-sim"` |
| `make rotate` | Rotates the Postgres credential through Infisical. Read PASS in dev and prod-sim on 2026-11-05, and `RESUME=yes` finished a run killed with SIGKILL ([dev](evidence/runs/SEC-2-20261105T072331Z.txt), [prod-sim](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt), [killed](evidence/runs/SEC-4-20261105T073843Z.txt)). A signed-in request answered 500 for about 38 s in dev ([watch](evidence/runs/SEC-2-20261105T072331Z-watch.txt)). `ROLLBACK=yes` undid a run killed with SIGKILL in prod-sim, with 12 of the script's 61 probes failing, a 36 s window ([SEC-4b](evidence/runs/SEC-4b-20261105T084615Z.txt)) | `ENV=dev`, `RESUME=yes` or `ROLLBACK=yes`. Prod-sim also needs `CONFIRM=yes` |

Details are in [data-operations.md](data-operations.md).

### Delivery

| Target | What it does | Parameters |
|---|---|---|
| `make render` | Re-renders Plane into `gitops/environments/`. See [kubernetes-helm.md](kubernetes-helm.md#render-flow) | |
| `make images` | Builds the four Wayline images from `apps/wayline/images.txt`, pushes them to `localhost:5001/wayline`, and writes their digests to `.build/digests.tsv` | |
| `make promote` | Moves image digests into an environment, re-renders, commits, publishes. Prod-sim also needs `plane-dev` Synced and Healthy with that digest in a ready container. With nothing to change it still publishes `main`. A publish that fails or is refused exits non-zero and leaves the commit on `main`, where it goes out with the next publish of any kind. It refuses a merge, cherry-pick or revert already under way. See [argocd.md](argocd.md#promotion) | `ENV`, `IMAGE`, `DIGEST`, `REPO`, `CONFIRM=yes`, `SKIP_BACKUP=yes`, `COMMIT=no`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make rollback` | `git revert` of the last promotion, then publish. `ENV=dev` stops before reverting if `main` holds a change to a prod-sim digest that Argo CD has not read, and names it. `make rollback ENV=prod-sim` withdraws that, and `OVERRIDE_DEV_CHECK` goes on and is logged. A real dev rollback ran on 2026-11-05 ([DEP-2-20261105T064032Z-rollback.txt](evidence/runs/DEP-2-20261105T064032Z-rollback.txt)) | `ENV`, `CONFIRM=yes`, `SKIP_BACKUP=yes`, `ROLLBACK_DUMP_TIMEOUT=<seconds>`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make gitops-publish` | Pushes `main` to the bare repo Argo CD reads. This is the only writer of that path | `SKIP_BACKUP=yes`, `OVERRIDE_DEV_CHECK="<reason>"` |
| `make ci` | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `security.sh`: the same scripts GitHub Actions runs | |
| `make wayline-upgrade-check`, `make wayline-upstream-check` | Check the branding against another upstream ref. See [apps/wayline/README.md](../apps/wayline/README.md) | `REF=<ref>` on the second |

### Drills

| Target | What it does | State on 2026-11-05 |
|---|---|---|
| `make drill-pod-restart ENV=dev` | Restarts each StatefulSet pod and proves the data survives | Read PASS on the final images: dev, 07:04Z ([log](evidence/runs/drill-pod-restart-dev-20261105T070414Z.log)), and prod-sim, 07:23Z ([log](evidence/runs/drill-pod-restart-prod-sim-20261105T072331Z.log)). During dev's Postgres round, 7 of 180 signed-in samples answered 500, from 07:04:26Z to 07:04:32Z ([timeline](evidence/runs/PERS-1-20261105T070358Z-timeline.txt)). See [validation.md](validation.md) |
| `make drill-failed-deploy` | A bad image reaches dev through Git, the rollout refuses it, and a revert restores it. Dev only | Read PASS on the final images, 06:23Z ([log](evidence/runs/drill-failed-deploy-20261105T062343Z.log)). The old pod kept serving, and no alert fired: `ArgoSyncFailed` stayed pending for 13m45s against its 15m, because the revert ended it first |
| `tests/drills/failed-migrator.sh` | A backend image whose migrator exits 1 reaches dev through Git, the sync stops at wave 2, wave 3 does not move, and a revert restores it. Dev only. No make target | Read PASS on the final images, 06:49Z ([log](evidence/runs/drill-failed-migrator-20261105T064940Z.log)) |
| `tests/drills/alert-rules.sh ENV=dev` | Scales a data StatefulSet to 0 with auto-sync paused, reads whether its alert fires and reaches the sink, then puts it back. Rows `PlaneRabbitmqDown` and `PlaneMinioDown`. No make target | Read FAIL for both at 10:06Z, a real defect: neither fired in 270 s ([before](evidence/runs/alert-rules-dev-20261105T100605Z.txt)). Read PASS at 10:17Z after the fix: they reached the sink at 157 s and 148 s, and resolved there ([after](evidence/runs/alert-rules-dev-20261105T101707Z.txt)). Dev only. Crashes and hung processes were not tested |
| `make drill-clean-restore CONFIRM=yes` | Takes a backup, **deletes the cluster**, restores everything and proves it. `PLAN_ONLY=yes` stops before the delete. `CLEAN_INSTALL_FIRST=yes` also runs `tests/drills/clean-install.sh` between the delete and the restore: a clean install from a fresh clone, tested and then deleted. `COLD_INSTALL=yes` makes that a cold install, with the local services and their volumes removed. `LOSE_CLUSTER=yes` deletes with kind alone, as a disaster would, leaving the local Terraform state behind | With `CLEAN_INSTALL_FIRST=yes`, 07:48Z ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log)), and with `COLD_INSTALL=yes` too, 10:53Z ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)): every restore step read PASS, and each log reads `RESULT FAIL`, 1 failure, only for the test's own `destroy-refused` step, fixed in `36d3011`. With `LOSE_CLUSTER=yes`, 13:06Z: in progress ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt)). `PLAN_ONLY=yes` has run ([dr-drill-planonly-1.txt](evidence/runs/dr-drill-planonly-1.txt)) |
| `make drill-clean-restore-harness` | The order and refusals of a clean restore, with `kubectl`, `kind`, `docker`, Terraform and the API stubbed. Touches no cluster and proves no platform | Ran on stubs ([dr-harness-stubbed-4.txt](evidence/runs/dr-harness-stubbed-4.txt)) |

## Teardown

Choose by what you need to keep.

| Command | Cluster and its volumes | Registry, caches | `.local/git`, `backups`, `secret-zero` | Consequence |
|---|---|---|---|---|
| `make down` | Stopped, kept | Stopped, kept | Kept | **No data loss** by design, and `make up` resumes. Read PASS on 2026-11-05: the sentinel row and attachment read back in both environments after `make down` in 15 s and `make up` in 82 s ([PERS-3](evidence/runs/PERS-3-20261105T083304Z.txt)) |
| `make destroy CONFIRM=yes` | **Deleted** | Kept | Kept | Takes `backup.sh all` first, for Infisical, dev and prod-sim. If that fails, nothing is deleted. The local Terraform state and any clean-restore marker are removed, and the Infisical state is kept. With no `CONFIRM=yes` it refuses and changes nothing ([TEAR-1](evidence/runs/TEAR-1-20261105T083304Z.txt)) |
| `make destroy CONFIRM=yes SKIP_BACKUP=yes` | **Deleted** | Kept | Kept | **Data since your last backup is gone** |
| `make destroy CONFIRM=yes PURGE=yes` | **Deleted** | **Deleted**, with their volumes | Kept | Branded images must be rebuilt, because the local registry holds the only copy of what the Mac built, and a rebuild gives new digests. Caches refill from upstream |

Four details that catch people:

- **`make destroy` after `make down`.** The pre-delete backup needs a reachable cluster. `backup.sh` exits and nothing is deleted. Run `make up` first, or pass `SKIP_BACKUP=yes` and accept the loss.
- **`.local/` is never deleted by a make target.** Removing it by hand removes the backups and `ENCRYPTION_KEY`. Do that only if you mean to lose them.
- **`kind delete cluster` by hand leaves stale Terraform state.** It describes resources that no longer exist. `make destroy` removes `.local/terraform/local` for this reason. It keeps `.local/terraform/infisical`, because that describes what is in the Infisical database, which a backup can bring back. After a manual delete, `make up` finds no cluster and moves the old state aside to `.local/terraform/local.stale-<time>`, so Terraform starts empty.
- **Disk may not come back.** Docker Desktop's docs say space inside the VM disk is not freed automatically. See the [Docker Desktop FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/). In the drills of 2026-11-05, host free went from 17.7 to 31.6 GiB on one delete, 14.1 GiB back ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log)). A delete with `PURGE=yes` left 31.7 GiB free, 15.6 GiB back, where the drill's check counted on about 27.0 GiB ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)). Neither read `Docker.raw`. The run in progress, `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, reads it at the top and the bottom of [its output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), so the before and after numbers are in that file.

### After a destroy

`make up` gives an empty platform, and Infisical seeds **new** Plane secrets. A Plane database is bound to the
`SECRET_KEY` it was written with, and `make restore` compares fingerprints and refuses a mismatch ([refusal](evidence/runs/clean-install-20261105T075041Z/restore-foreign-key-refused.txt)). So Infisical and Plane
restore as a matched set, Infisical first, which is what `make restore-clean BACKUP=latest` does.

That has run for real twice on 2026-11-05, each from backups taken just before the delete, into a new cluster with a new CA.

The second run is the one to read, at `18af97a`, on the code with the recovery fixes merged. Every step read PASS, and each `not_run` is empty ([result](evidence/runs/restore-clean-20261105T124518Z.json), [Infisical](evidence/runs/restore-infisical-20261105T124950Z.json), [dev](evidence/runs/restore-dev-20261105T125720Z.json), [prod-sim](evidence/runs/restore-prod-sim-20261105T130009Z.json)). The organization, project and identity ids, secret zero and the admin token are the old ones, all 38 rendered Secret keys hold the old values, and a second bootstrap changed nothing ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)). The full smoke test passed with the restored accounts, 45 PASS and 1 SKIP in dev, 44 and 1 in prod-sim, the skip being `branding-fresh-install`, which needs a clean database ([dev](evidence/runs/smoke-dev-20261105T130318Z-97151.json), [prod-sim](evidence/runs/smoke-prod-sim-20261105T130503Z-95847.json)). The Infisical tests passed ([isolation](evidence/runs/infisical-isolation-20261105T130310Z-90699.txt), [rendered](evidence/runs/infisical-rendered-secrets-20261105T130310Z-90699.txt)). It took about 1,092 s: the drill counts 7,663 s from the delete, less the clean install's 6,571 s between them. The dumps were 4.40, 1.33 and 0.86 MB of test data on this laptop, and the host's `.local/` stayed, so this is a lost cluster and not a lost machine.

The first run, on the script from before those fixes, read the same in about 1,226 s ([result](evidence/runs/restore-clean-20261105T081017Z.json), [log](evidence/runs/drill-clean-restore-20261105T074859Z.log)). Both logs read `RESULT FAIL`, 1 failure, only because the clean install's own `destroy-refused` step failed, at stage 4b. `make` passed `CONFIRM=yes` down through `MAKEFLAGS`, past the script's `unset`, so `make destroy` obeyed ([step](evidence/runs/clean-install-20261105T105546Z/destroy-refused.txt)). `00126ea` had cleared only the environment, and `36d3011` clears `MAKEFLAGS` too, which no drill has run yet. TEAR-1 has its own clean run, which refused ([TEAR-1](evidence/runs/TEAR-1-20261105T083304Z.txt)). See [data-operations.md](data-operations.md) and [disaster-recovery.md](disaster-recovery.md).

A clean restore that stops is run again with the same command. These four cases of losing data off the path that ran are fixed and merged at `18af97a`, as `scripts/restore.sh`, `scripts/destroy.sh` and [infisical/README.md](../infisical/README.md) read now. The second real restore ran on that code and did not stop, so these four paths themselves have run on stubs only:

- **A client that can no longer print.** With a closed terminal or dead output, the exit trap keeps going and writes what it has to say to a file beside the evidence, so it still removes the Job it started. Before, its first print could end it, with the Job running and auto-sync paused.
- **`make destroy` with a clean-restore marker kept.** It takes its backup anyway, through `ALLOW_BACKUP_DURING_RESTORE=yes`, where it used to stop on `backup.sh`'s refusal and advise `SKIP_BACKUP=yes`. Then it removes the marker.
- **`ALLOW_RESUME_OVERWRITE` names environments.** `ALLOW_RESUME_OVERWRITE=dev` or `"dev prod-sim"` reaches only those, and `yes` is refused. The step records a FAIL with what was there, and the run exits 4 and reads `OVERWROTE`, not PASS.
- **The `data-back <env>` line.** Once an environment's data Job has finished, a resume keeps what is there and goes on from the migrator, because counts cannot tell the backup from the backup plus new work. Only `ALLOW_RESUME_OVERWRITE` naming that environment replaces it. A target found empty is restored again.

## Common first-run failures

Rows quoting a script message come from the code. Others are expected from source reading.

| Symptom | Cause | Fix |
|---|---|---|
| `fail Docker has N GiB` | Docker memory below the 13 GiB check | Docker Desktop, Settings, Resources, Memory |
| `fail port 80 is in use by X` | Another listener | Stop it. kind binds exact ports |
| `only N GiB free on the host` | `guard_disk` refused | Free host space. Do not use `docker system prune -a` |
| `kind network is X, outside 172.16.0.0/12` | Custom Docker address pool | Change the daemon's pool, or see [troubleshooting](runbooks/troubleshooting.md) |
| Image pull 429 or `ImagePullBackOff` | Docker Hub anonymous quota. Pulls go through `plane-mirror-docker`, which fronts `mirror.gcr.io`, then fall back to Docker Hub | Wait for the quota window, or check the mirror with `docker logs plane-mirror-docker`. `docker login` on the host does not help pods. Two small images are shown taking that path ([gate run](evidence/day1-gates-20261104T231136Z.txt)). The fallback to Docker Hub: Not tested in Pass 1 |
| `kubectl` says the context does not exist | Your shell has no `KUBECONFIG` | See [Shell setup](#shell-setup) |
| Terraform: cannot reach the cluster | The providers read the kubeconfig during plan, and the node is stopped or absent | `scripts/cluster-up.sh` first, or `make up` |
| Terraform: namespace already exists | State was lost while the cluster lives | [terraform.md](terraform.md#state) |
| `Infisical is initialized, bootstrap works only once, and nothing here could replace the admin token` | `infisical-admin.json` is lost or ended, and a sign-in with `infisical-admin-password` could not mint another | Follow the steps it prints, and `infisical/README.md`, section Recovery |
| A committed fix does not reach the cluster | `make gitops-publish` not run, or the fix is uncommitted | Commit, publish, then see [argocd.md](argocd.md#retry-behaviour) |
| A change to `helm/values/argocd.yaml` does nothing | Terraform owns that release, not Argo CD | `terraform apply`. See [terraform.md](terraform.md#what-reaches-the-cluster-how) |
| Every UI times out while pods are Ready | NetworkPolicy on NodePort traffic at Traefik. The source is the kind gateway (`172.24.0.1` here), which `traefik-ingress` admits through `172.16.0.0/12`. Removing that block made a host request time out ([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)) | `make test-netpol`, then [security.md](security.md) |
| An internal UI answers 403 from the host | The kind network is outside the `node-network-only` allow list | Check the Docker network, as for the `kind network` row above |
| `make up` waits on `plane-dev=OutOfSync/Degraded`, and web, admin, space or api crash with Permission denied | Images built before `6f5a426` under a restrictive umask, so their non-root users cannot read their own files. `make up` waits up to 3,000 s and does not say why. Seen once, on the cold install ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)) | Read a pod's log with `make logs ENV=dev SVC=api`. Build again at `6f5a426` or later with `make images`, promote both environments again, and end the stuck operation with [the runbook's patch](runbooks/argo-sync-stuck.md#end-an-operation) |
| Pods restart with `OOMKilled` during first boot | Both environments booting together is the worst case for memory. On the staged boot, with dev then prod-sim, no Plane container restarted or was OOM-killed ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt), [monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)). The kills there were Grafana's sidecars at 96 MiB and `plane-registry` at 128 MiB, both since raised | Check `make status`. Stop unrelated containers. Change limits only with a measurement |

One refusal comes only after the first run, once prod-sim has a database. `plane-dev has not proven these digests` means `main` brings prod-sim a digest that no ready container in `plane-dev` runs. Fix dev, or set `OVERRIDE_DEV_CHECK="<reason>"`, which is logged.
