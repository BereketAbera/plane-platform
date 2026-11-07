# Install and operate

Wayline is a customized Plane Community Edition v1.4.3 deployment (AGPL-3.0). It is not an original product. This
repository wraps upstream Plane in a deployment platform with three environments, and this page installs and runs each:

| Environment | Where it runs | How it starts | Address |
|---|---|---|---|
| dev, namespace `plane-dev` | The local kind cluster on this Mac | `make up` | `http://plane.dev.localhost` |
| prod-sim, namespace `plane-prod-sim` | The same kind cluster. It is the promotion target that simulates production | `make up` | `http://plane.prod-sim.localhost` |
| Hosted production, namespace `plane-prod` | One K3s node on the owner's Contabo VPS | The scripts in `scripts/hosted/`, then `make remote-<verb> TARGET=plane-prod` | `https://wayline.bereket.dev` |

Every section from [Prerequisites](#prerequisites) to [Common first-run failures](#common-first-run-failures) is about the kind
cluster, which is local and production-inspired and makes no claim of being ready for production. [Hosted production](#hosted-production)
is about the VPS, which serves the public from one node and so has no high availability. See [known-limitations.md](known-limitations.md).

**Status of this page.** It describes configuration and script behaviour read from the code, with results from real runs
where they exist. The local sections are as of 2026-11-05, and the hosted ones as of 2026-11-07, where
[What has run on hosted production](#what-has-run-on-hosted-production) gives each run its result and its evidence. Two installs from a fresh clone have run: a cold one, with the registry and caches gone, which is the sequence a new machine needs, and one that kept them ([First run](#first-run)). A full restore
into a new cluster has run on the merged recovery code ([After a destroy](#after-a-destroy)). `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, from 13:06Z to 13:35Z,
deleted the cluster with kind alone, restored it, and read `RESULT PASS` ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), [log](evidence/runs/drill-clean-restore-20261105T130633Z.log)). Do not read an unmarked command as a tested command. It means only that the claim does not depend on a runtime result.

Names and ordering on the kind cluster come from the binding [platform contract](platform-contract.md).

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
| Docker VM used, idle | 8.65 GiB average, 8.79 top, of 13.63 GiB | 08:47:35Z to 08:56:59Z on 2026-11-05 ([derived](evidence/runs/LOAD-3-20261105T092547Z-derived.txt)) |
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
| promtool | v3.15.1 | | cntb | v1.7 |
| age | v1.3.2 | | age-keygen | v1.3.2 |

`cntb` reads the VPS from Contabo, and `age` encrypts hosted production's recovery bundle. restic 0.19.1 is pinned apart, in
`scripts/hosted/restic.lock`, and a hosted script fetches and checks it when it needs it.

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

**On a new machine.** This is the sequence the cold install ran on 2026-11-05 at `e602dad`, on a fresh clone with no `.local` and no `.build`, after `make destroy` with `PURGE=yes` had removed the cluster, the registry and the caches ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt)).

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

**What the 5,238 s holds.** A real defect. The drill ran under `umask 077`, so every file in the build contexts was 0600, and the images' non-root users could not read their own files. web, admin, space and api crashed at start, with Permission denied in the logs of web, admin and api, while worker, beat and live ran. No build step noticed, and `make up` gave no explanation: it printed `plane-dev=OutOfSync/Degraded` every minute from 865 s to 2,407 s of its last wait ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)). `b4f6cc9`, which was `8770097` in that clone, fixes it, with `chmod -R a+rX` on each context in `scripts/ci/build-images.sh`. Under the same umask `make images` then took 598 s, and that build was promoted into the same cluster ([rebuild](evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt)). The stuck operation was ended with [the runbook's Terminating patch](runbooks/argo-sync-stuck.md#end-an-operation), and `plane-dev` and `plane-prod-sim` came up healthy ([timeline](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)). The pods' crash logs and that patch were read and run by hand, and [a record copied from that session's `kubectl` output](evidence/runs/INST-1b-crash-logs-20261105T121917Z.txt) holds them. The rebuild's header, the comment in `b4f6cc9` and the `make up` log are the record. The clone, its digests and its promotions were deleted at the end and the registry snapshot put back, so this checkout still names the images built from `84b63d9`.

**How much that cost.** The Infisical step ended at about 11:51:28Z, 2,298 s into that `make up`. `plane-dev`'s good sync ran from 12:31:17Z to 12:32:35Z, and `plane-prod-sim`'s from 12:37:10Z to 12:40:23Z ([timeline](evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)). So at most about 46 minutes went on the defect, 11:51:28Z to 12:37:10Z, less the time a healthy `plane-dev` first boot takes, which this run does not show. **A full cold install with no defect has not been timed end to end.** The defect did not touch those first 2,298 s, which on this laptop's connection hold the slow cold pulls: `kube-prometheus-stack`'s first sync started 17.5 minutes after `metrics-server`'s, and Infisical's ran from 11:45:01Z to 11:50:58Z. The steps this run did time add up to about 59 minutes, counting the build and with no healthy `plane-dev` first boot in that sum, which is arithmetic and not a timed install. The fix has run through `make images` and that promotion, not through a whole cold install from its start.

**With the registry and caches kept**, one `make up` from a fresh clone, with new secrets, exited 0 in 955 s on 2026-11-05 at `94a54e2`, with all 14 Applications Synced and Healthy ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt), [Applications](evidence/runs/clean-install-20261105T075041Z/apps-after-up.txt)). That is the good figure, and it does not build or pull from the internet. `make test-e2e` then passed with no SKIP, 46 PASS in dev and 45 in prod-sim ([dev](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-dev-20261105T080642Z-65896.json), [prod-sim](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-prod-sim-20261105T080826Z-22080.json)). There one `make up` is all it takes, and `make status` shows the result.

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

- One `make up` from a fresh clone: 955 s, with the registry and caches on disk ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt)). With them gone, the steps and what is not timed are above.
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

Everything is on loopback over plain HTTP. kind binds only `127.0.0.1`, and nothing terminates TLS on the kind cluster.
Hosted production's addresses are in [Hosted URLs](#hosted-urls).

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
The `remote-*` targets reach hosted production and nothing else, and are in [Hosted make targets](#hosted-make-targets). None of
the targets below can reach it.

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
| `make test` | Gates, the NetworkPolicy matrix, Infisical isolation, internal routes, smoke tests in both environments, and the separation checks, in that order, carrying on after a failure. Calls `scripts/test.sh`. Read PASS in full on 2026-11-05 on the cluster the last drill left, at `f30a7f5`, ending 14:11Z ([output](evidence/runs/MAKE-TEST-20261105T140019Z.txt)), and on the first restored cluster, ending 08:45Z ([output](evidence/runs/MAKE-TEST-20261105T083455Z.txt)). [validation.md](validation.md) says what has run | |
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
| `make restore-clean` | Brings the whole platform back into a clean environment, Infisical first. The script exits 2 if a proof could not run or a person must sign in, 4 if it overwrote what `ALLOW_RESUME_OVERWRITE` named, and `make` exits 2 on any failure. Three real runs read PASS on every step on 2026-11-05 ([first](evidence/runs/restore-clean-20261105T081017Z.json), [on the merged recovery code](evidence/runs/restore-clean-20261105T124518Z.json), [on a cluster lost with kind alone](evidence/runs/restore-clean-20261105T130828Z.json)). See [After a destroy](#after-a-destroy) | `BACKUP=<infisical-backup-id or latest>`, `PLAN_ONLY=yes`, `ENVS=dev`, `ALLOW_LOW_DISK="<reason>"`, `ALLOW_NO_SENTINEL=yes`, `ALLOW_NEWER_INFISICAL_BACKUP=yes`, `ALLOW_RESUME_OVERWRITE="dev prod-sim"` |
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
| `make drill-clean-restore CONFIRM=yes` | Takes a backup, **deletes the cluster**, restores everything and proves it. `PLAN_ONLY=yes` stops before the delete. `CLEAN_INSTALL_FIRST=yes` also runs `tests/drills/clean-install.sh` between the delete and the restore: a clean install from a fresh clone, tested and then deleted. `COLD_INSTALL=yes` makes that a cold install, with the local services and their volumes removed. `LOSE_CLUSTER=yes` deletes with kind alone, as a disaster would, leaving the local Terraform state behind | With `CLEAN_INSTALL_FIRST=yes`, 07:48Z ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log)), and with `COLD_INSTALL=yes` too, 10:53Z ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)): every restore step read PASS, and each log reads `RESULT FAIL`, 1 failure, only for the test's own `destroy-refused` step, fixed in `1374c1e`. With `LOSE_CLUSTER=yes`, 13:06Z: every restore step read PASS and the log reads `RESULT PASS`, `make` exit 0, in about 28 minutes ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), [log](evidence/runs/drill-clean-restore-20261105T130633Z.log)). `PLAN_ONLY=yes` has run ([dr-drill-planonly-1.txt](evidence/runs/dr-drill-planonly-1.txt)) |
| `make drill-clean-restore-harness` | The order and refusals of a clean restore, with `kubectl`, `kind`, `docker`, Terraform and the API stubbed. Touches no cluster and proves no platform | Ran on stubs, whole at `f30a7f5`: 1340 passed, 0 failed ([total](evidence/runs/final-harness-f30a7f5/total.txt)). Earlier, 905 at `0bd3e2d` ([dr-harness-stubbed-4.txt](evidence/runs/dr-harness-stubbed-4.txt)) |

## Teardown

Choose by what you need to keep.

| Command | Cluster and its volumes | Registry, caches | `.local/git`, `backups`, `secret-zero` | Consequence |
|---|---|---|---|---|
| `make down` | Stopped, kept | Stopped, kept | Kept | **No data loss** by design, and `make up` resumes. Read PASS on 2026-11-05: the sentinel row and attachment read back in both environments after `make down` in 15 s and `make up` in 82 s ([PERS-3](evidence/runs/PERS-3-20261105T083304Z.txt)) |
| `make destroy CONFIRM=yes` | **Deleted** | Kept | Kept | Takes `backup.sh all` first, for Infisical, dev and prod-sim. If that fails, nothing is deleted. The local Terraform state and any clean-restore marker are removed, and the Infisical state is kept. With no `CONFIRM=yes` it refuses and changes nothing ([TEAR-1](evidence/runs/TEAR-1-20261105T083304Z.txt)) |
| `make destroy CONFIRM=yes SKIP_BACKUP=yes` | **Deleted** | Kept | Kept | **Data since your last backup is gone** |
| `make destroy CONFIRM=yes PURGE=yes` | **Deleted** | **Deleted**, with their volumes | Kept | Branded images must be rebuilt, because the local registry holds the only copy of what the Mac built, and a rebuild gives new digests. Caches refill from upstream. The cold install started from this, and [First run](#first-run) is the way back |

Four details that catch people:

- **`make destroy` after `make down`.** The pre-delete backup needs a reachable cluster. `backup.sh` exits and nothing is deleted. Run `make up` first, or pass `SKIP_BACKUP=yes` and accept the loss.
- **`.local/` is never deleted by a make target.** Removing it by hand removes the backups and `ENCRYPTION_KEY`. Do that only if you mean to lose them.
- **`kind delete cluster` by hand leaves stale Terraform state.** It describes resources that no longer exist. `make destroy` removes `.local/terraform/local` for this reason. It keeps `.local/terraform/infisical`, because that describes what is in the Infisical database, which a backup can bring back. After a manual delete, `make up` finds no cluster and moves the old state aside to `.local/terraform/local.stale-<time>`, so Terraform starts empty.
- **Disk may not come back.** Docker Desktop's docs say space inside the VM disk is not freed automatically. See the [Docker Desktop FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/). In the drills of 2026-11-05, host free went from 17.5 to 31.6 GiB on one delete, 14.1 GiB back ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log)). A delete with `PURGE=yes` left 31.7 GiB free, 15.6 GiB back, where the drill's check counted on about 27.0 GiB ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)). Neither read `Docker.raw`. `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, which deleted with kind alone, left 28.3 GiB free, 11.2 GiB back, and read it at the top and the bottom of [its output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt): 38,276,744 KiB before the delete and 38,301,404 KiB after the restore, with a cluster back on the disk, so what a delete alone does to that file was not read.

### After a destroy

`make up` gives an empty platform, and Infisical seeds **new** Plane secrets. A Plane database is bound to the
`SECRET_KEY` it was written with, and `make restore` compares fingerprints and refuses a mismatch ([refusal](evidence/runs/clean-install-20261105T075041Z/restore-foreign-key-refused.txt)). So Infisical and Plane
restore as a matched set, Infisical first, which is what `make restore-clean BACKUP=latest` does.

That has run for real three times on 2026-11-05, each from backups taken just before the delete, into a new cluster with a new CA. The third, at `06b8be7`, followed a delete with kind alone, with nothing in the gap: every step PASS, 1,474 s from the delete, and its log reads `RESULT PASS` ([result](evidence/runs/restore-clean-20261105T130828Z.json), [log](evidence/runs/drill-clean-restore-20261105T130633Z.log)).

The second run is the one with the cold install before it, at `e602dad`, on the code with the recovery fixes merged. Every step read PASS, and each `not_run` is empty ([result](evidence/runs/restore-clean-20261105T124518Z.json), [Infisical](evidence/runs/restore-infisical-20261105T124950Z.json), [dev](evidence/runs/restore-dev-20261105T125720Z.json), [prod-sim](evidence/runs/restore-prod-sim-20261105T130009Z.json)). The organization, project and identity ids, secret zero and the admin token are the old ones, all 38 rendered Secret keys hold the old values, and a second bootstrap changed nothing ([log](evidence/runs/drill-clean-restore-20261105T105347Z.log)). The full smoke test passed with the restored accounts, 45 PASS and 1 SKIP in dev, 44 and 1 in prod-sim, the skip being `branding-fresh-install`, which needs a clean database ([dev](evidence/runs/smoke-dev-20261105T130318Z-97151.json), [prod-sim](evidence/runs/smoke-prod-sim-20261105T130503Z-95847.json)). The Infisical tests passed ([isolation](evidence/runs/infisical-isolation-20261105T130310Z-90699.txt), [rendered](evidence/runs/infisical-rendered-secrets-20261105T130310Z-90699.txt)). It took about 1,092 s: the drill counts 7,663 s from the delete, less the clean install's 6,571 s between them. The dumps were 4.40, 1.33 and 0.86 MB of test data on this laptop, and the host's `.local/` stayed, so this is a lost cluster and not a lost machine.

The first run, on the script from before those fixes, read the same in about 1,226 s ([result](evidence/runs/restore-clean-20261105T081017Z.json), [log](evidence/runs/drill-clean-restore-20261105T074859Z.log)). Those two logs read `RESULT FAIL`, 1 failure, only because the clean install's own `destroy-refused` step failed, at stage 4b. `make` passed `CONFIRM=yes` down through `MAKEFLAGS`, past the script's `unset`, so `make destroy` obeyed ([step](evidence/runs/clean-install-20261105T105546Z/destroy-refused.txt)). `af8b26e` had cleared only the environment, and `1374c1e` clears `MAKEFLAGS` too, which no drill has run yet, though its line was [checked against a stub](evidence/runs/destroy-refused-line-check.txt). TEAR-1 has its own clean run, which refused ([TEAR-1](evidence/runs/TEAR-1-20261105T083304Z.txt)). See [data-operations.md](data-operations.md) and [disaster-recovery.md](disaster-recovery.md).

A clean restore that stops is run again with the same command. These four cases of losing data off the path that ran are fixed and merged at `e602dad`, as `scripts/restore.sh`, `scripts/destroy.sh` and [infisical/README.md](../infisical/README.md) read now. The second real restore ran on that code and did not stop, so these four paths themselves have run on stubs only:

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
| `make up` waits on `plane-dev=OutOfSync/Degraded`, and web, admin, space or api crash, most with Permission denied | Images built before `b4f6cc9` under a restrictive umask, so their non-root users cannot read their own files. `make up` waits up to 3,000 s and does not say why. Seen once, on the cold install ([log](evidence/runs/clean-install-20261105T105546Z/make-up.txt)) | Read a pod's log with `make logs ENV=dev SVC=api`. Build again at `b4f6cc9` or later with `make images`, promote both environments again, prod-sim with the override again, and end the stuck operation with [the runbook's patch](runbooks/argo-sync-stuck.md#end-an-operation) |
| Pods restart with `OOMKilled` during first boot | Both environments booting together is the worst case for memory. On the staged boot, with dev then prod-sim, no Plane container restarted or was OOM-killed ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt), [monitoring-memory-1.txt](evidence/runs/monitoring-memory-1.txt)). The kills there were Grafana's sidecars at 96 MiB and `plane-registry` at 128 MiB, both since raised | Check `make status`. Stop unrelated containers. Change limits only with a measurement |

One refusal comes only after the first run, once prod-sim has a database. `plane-dev has not proven these digests` means `main` brings prod-sim a digest that no ready container in `plane-dev` runs. Fix dev, or set `OVERRIDE_DEV_CHECK="<reason>"`, which is logged.

## Hosted production

Hosted production, `plane-prod`, is the same Wayline on a cluster of its own: one K3s node on a Contabo Cloud VPS 12, instance
203733427, at `5.253.234.127`, serving `https://wayline.bereket.dev`. It shares nothing with the kind cluster, and no local `make`
target can reach it. [scripts/hosted/README.md](../scripts/hosted/README.md) lists every script, and holds the procedures this
section points to: the first certificate, Infisical's two-factor, the lockouts, and the way back after a rollback.

### What differs from local

| | Kind cluster: dev and prod-sim | Hosted production |
|---|---|---|
| Cluster | kind v0.33.0, one node in Docker Desktop, Kubernetes v1.36.4 | K3s v1.36.6+k3s1 on Ubuntu 24.04.5, with 12 vCPU, 47 GiB and one 400 GB disk |
| How a command reaches it | `.local/kubeconfig`, context `kind-plane-platform` | `.local/hosted/plane-prod/kubeconfig`, one context `plane-prod`, on `https://127.0.0.1:16443` through an SSH tunnel. The API server has no public port |
| Saying yes | `CONFIRM=yes` | `TARGET=plane-prod` always, and `CONFIRM=plane-prod` for anything that changes something. `CONFIRM=yes` does not count, so a habit cannot reach production |
| Local state | `.local/` | `.local/hosted/plane-prod/`, mode 0700, only in the checkout that ran the bootstrap |
| What Argo CD reads | `git://plane-git/plane-platform.git`, branch `main`, written by `make gitops-publish` | GitHub over SSH with a read-only deploy key, branch `deploy/plane-prod`, written only by CI. See [argocd.md](argocd.md#hosted-production) |
| Images | `localhost:5001/wayline/*` | `ghcr.io/bereketabera/wayline/*`, plain linux/amd64 manifests, pulled with Secret `ghcr-pull` |
| Promotion | `make promote` | A signed record that dev ran the exact digests, then a pull request that a person merges. See [argocd.md](argocd.md#exact-digest-image-sets) |
| The way in | `127.0.0.1:80` on this Mac, plain HTTP | Traefik's hostPorts 80 and 443 behind the host firewall's stages, with HTTPS from Let's Encrypt certificates that cert-manager gets by HTTP-01 |
| Names | `*.localhost` | A records on Vercel, owned by Terraform. See [terraform.md](terraform.md#hosted-production) |
| Secrets | One Infisical in the kind cluster, a project per environment | An Infisical of its own on the VPS, project `plane-prod`. Secret zero, the deploy key, the restic password and the alert credentials stay in `.local/hosted/plane-prod/`, never in Infisical, so nothing is circular |
| Backups and alerts | `make backup` to `.local/backups`, and a sink that prints lines | Nightly CronJobs sealed with restic on the VPS, pulled to this Mac with `make remote-pull-backups`. Alerts go to the owner's Telegram, and the Watchdog to Healthchecks.io, once the owner's files exist |

### Before you start

On this Mac, in the checkout that will hold hosted production's state:

- `make setup`, for the pinned tools above.
- `gh`, signed in to an account that administers `BereketAbera/plane-platform`, because the bootstrap adds a deploy key with it.
- The SSH key that [`target.yaml`](../infrastructure/hosted/plane-prod/target.yaml) names, `~/.ssh/wayline_contabo_ed25519`, which root on a new
  VPS must accept. The first stage logs in as root with it, and no script types a password.
- The host's key in `.local/hosted/known_hosts`. Every script that logs in checks it strictly, and refuses without it. Record it with
  `ssh-keyscan`, as `provision-node.sh` asks.
- `target.yaml` describing the VPS: its addresses, its Contabo instance id, the node's name, the three hostnames, and
  `kube_system_uid: pending` for a cluster not made yet. It is not a secret. Every hosted script and both hosted Terraform roots read it.
- For DNS only: Contabo's API login in `~/.cntb.yaml`, which `scripts/hosted/contabo-login.sh` writes, and the Vercel CLI signed in with
  `vercel login`.

Run every hosted command from that checkout. Each script finds `.local` and `.tools` beside itself, so the checkout decides which
kubeconfig, secrets and Terraform state are used, and another clone or worktree holds none of them.

### From nothing, in order

This is the order the scripts ask for on a new VPS. Each step can run again, and changes only what differs.

```bash
# 1. The node: an admin user and key-only SSH, then the OS with the firewall at stage closed, then K3s
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh access
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh os
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/provision-node.sh k3s
make remote-kubeconfig TARGET=plane-prod     # prints kube_system_uid: record it in target.yaml, and commit

# 2. DNS, before anything asks for a certificate
TARGET=plane-prod scripts/hosted/host-terraform.sh plan
TARGET=plane-prod CONFIRM=plane-prod EXPECT='<the changes plan printed>' scripts/hosted/host-terraform.sh apply

# 3. What only the owner can make, typed at hidden prompts
scripts/hosted/owner-inputs.sh
scripts/hosted/bundle.sh init                # once per owner; it says so if the recipient is already in Git

# 4. The platform. It leaves the firewall at stage http
make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod

# 5. Infisical's two-factor, through the tunnel, while 443 is still closed
make remote-ui TARGET=plane-prod UI=infisical          # runs until Ctrl-C, so the next line goes in another tab
make remote-infisical-admin TARGET=plane-prod VERB=login

# 6. The first promotion, with 443 open to the owner alone until Plane's first admin exists
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh owner <your public ipv4>
#    merge the promotion pull request, then make the admin at https://wayline.bereket.dev/god-mode/
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh open
scripts/hosted/edge.sh scan

# 7. Prove it, and keep the recovery bundle
make remote-status TARGET=plane-prod
make remote-test TARGET=plane-prod CONFIRM=plane-prod
make remote-smoke TARGET=plane-prod
make remote-bundle TARGET=plane-prod
```

| Step | What it does, and why it comes here |
|---|---|
| `provision-node.sh access` | Makes `wayline-admin` with the key and passwordless sudo, then allows SSH by key only, for that user and the backup pull user, with no root login and local forwarding only. A timer on the server undoes the SSH change after 10 minutes, and the script stops it only once a new login works and the server offers publickey alone. If you are locked out anyway, the root password still works on Contabo's VNC console |
| `provision-node.sh os` | Installs ipset, nftables, conntrack, curl and jq. kube-router needs ipset: without it K3s only warns, and enforces no NetworkPolicy. It checks that automatic security updates are on, with no automatic reboot, sets the resolvers and sysctls, writes a reboot-required metric every 5 minutes, and installs `wayline-edge.service`, which loads the firewall before K3s at every boot. The firewall goes to stage `closed`, unless it has a stage already |
| `provision-node.sh k3s` | Writes K3s's config, registry mirror, resolver, audit policy and kubelet settings before K3s first starts, because its address ranges cannot change afterwards. Then it installs v1.36.6+k3s1 with the installer from that release's tag, and waits up to 200 s for the node. [kubernetes-helm.md](kubernetes-helm.md#k3ss-own-components) has the settings |
| `make remote-kubeconfig` | Fetches K3s's kubeconfig over SSH, rewrites it for the tunnel, starts the tunnel, and prints the `kube-system` UID. Until `target.yaml` records it, every script that reaches the cluster refuses, and so does Terraform root `environments/prod`, because that UID is how they tell this cluster from any other |
| `host-terraform.sh` | Root `environments/prod-host`: checks the VPS's address at Contabo against `target.yaml`, and owns the A records of `wayline`, `grafana` and `infisical`. `apply` applies only a plan whose changes are exactly `EXPECT`. It comes before the bootstrap because the zone's wildcard answers Vercel's address for any name with no record of its own, and a certificate ordered before its record is live fails, and is tried again an hour or more later |
| `owner-inputs.sh` | The owner's five inputs, in the next table. The GHCR token is the one the bootstrap cannot go without |
| `bundle.sh init` | Makes `~/.wayline/recovery-identity.txt` and writes its public half to `scripts/hosted/recovery-recipient.txt`, for Git. With no recipient, the bootstrap's last step reads INCOMPLETE, and this Mac holds the only copy of secret zero |
| `make remote-bootstrap` | Eight steps, each safe to run again: a read-only deploy key on GitHub; the namespaces through Terraform, then the repository Secret and Grafana's admin login, ahead of Argo CD; port 80, then the rest of Terraform, which installs Argo CD and the root Application, so Argo CD starts deploying and asks for the certificates; the backup folders, the read-only pull user and a restic password made once; secret zero; Infisical's first admin, project, identity and seeded values, through a port-forward; alert delivery; the recovery bundle. It waits up to 2,400 s for Infisical. Before step 3 it stops if 443 is open to everyone while Infisical is not claimed and closed to sign-up |
| Two-factor | Infisical has a public route, so its admin turns on an authenticator app through the tunnel before 443 opens to everyone. There is no SMTP, so email codes are not an option. The steps are in `scripts/hosted/README.md`, section Two-factor for Infisical's admin, and [infisical.md](infisical.md) says what the route allows |
| The first promotion | Dev runs the exact digests and signs a record of it, `promote-plane-prod.yml` opens a pull request, and merging it is the approval. [argocd.md](argocd.md#exact-digest-image-sets) has the steps. Until it merges, root holds no Plane Application, and the platform comes up alone |
| `edge.sh owner`, then `open` | Plane's first admin sign-up is open to whoever posts first, so 443 opens to the owner's address alone until the owner has made that admin at `/god-mode/`. `open` refuses while Plane's instance or Infisical is unclaimed, or while Infisical is open to sign-up or does not answer, and then reminds you of the two-factor. `scan`, from this Mac, is the check that counts |
| Prove it | `make remote-test` runs the hosted suite, and `make remote-smoke` signs in with the owner's account. Run `make remote-bundle` again after every bootstrap, token change or Terraform apply, and copy `.local/hosted/plane-prod/recovery-bundle/` off this Mac |

### What the owner types, and where

Nothing secret reaches a command line, the shell's history or Git. Each value goes in at a prompt, most of them hidden, and what this
repository keeps lands in a file of mode 0600.

| When | Where | What | Kept in |
|---|---|---|---|
| Before DNS | `scripts/hosted/contabo-login.sh` | Contabo's API client id, client secret, API user and API password, from the Control Panel's API page. The secret and the password at hidden prompts. It lists the account's instances to prove them | `~/.cntb.yaml` |
| Before DNS | `vercel login` | The owner's Vercel sign-in | The Vercel CLI's own login |
| `owner-inputs.sh`, 1 of 5, required | The browser page `gh` opens | A one-time code, which lets this Mac read the private images | `gh`'s login |
| 2 of 5, required | Hidden prompt | A classic GitHub token with `read:packages` alone, which GHCR must accept before it is kept. The server pulls with it | `.local/hosted/plane-prod/ghcr-pull-token` |
| 3 of 5, recommended | Hidden prompt, then Telegram | A bot token from @BotFather, then any message to that bot, so the script finds the chat and sends a test | `alert-telegram-bot-token`, `alert-telegram-chat-id` |
| 4 of 5, optional | Hidden prompt | A Healthchecks.io ping URL, for a check with a period of 5 minutes and a grace of 10, which says when the whole server is down | `alert-healthchecks-url` |
| 5 of 5, optional | Prompts, the key hidden | An S3-compatible endpoint, bucket, key id and application key, for a copy of the backups off the VPS | `offsite-s3-*` |
| After the bootstrap | Infisical, through `make remote-ui TARGET=plane-prod UI=infisical`, in Chrome or Firefox | The admin password, which `make remote-infisical-admin TARGET=plane-prod VERB=login` puts on the clipboard, then an authenticator app's code. Keep sign-up Invite-only, and keep the ten recovery codes in the password manager, apart from the phone | Infisical's database |
| At stage `owner` | `https://wayline.bereket.dev/god-mode/`, from the owner's own address | Plane's instance admin. The first to post owns the instance | Plane's database |
| Any time | `https://grafana.bereket.dev` | The login `make remote-grafana-admin TARGET=plane-prod VERB=login` prints and copies | Secret `monitoring/grafana-admin` |
| To prove it | `make remote-smoke TARGET=plane-prod`, in a Terminal tab | An existing Plane account's email and password, at hidden prompts | Nothing |

`owner-inputs.sh <step>` runs one step again, to add or replace a value: `github`, `ghcr`, `telegram`, `healthchecks` or `offsite`.
After a change to the Telegram or Healthchecks files, `make remote-alerts TARGET=plane-prod CONFIRM=plane-prod` renders alert delivery
again. Keep `~/.wayline/recovery-identity.txt` in a password manager: with it, the bundle and this repository, a person can bring
production back on a new machine.

### Firewall stages

`scripts/hosted/edge.sh` moves the host firewall between four stages. It is an nftables table of its own, `inet wayline_edge`, at
prerouting priority mangle, so it runs before the DNAT of kube-proxy and portmap, and a hostPort or NodePort cannot get around it.

| Stage | Open to everyone | When |
|---|---|---|
| `closed` | 22 | A new VPS, after `provision-node.sh os` |
| `http` | 22, 80 | Set by the bootstrap before Argo CD starts, so Let's Encrypt reaches the HTTP-01 challenge. Port 80 only redirects, and answers the challenge |
| `owner <ipv4>` | 22, 80, and 443 from that one address | While Plane's first admin is made, and whenever the site must stay off the internet but reach the owner |
| `open` | 22, 80, 443 | The site is public |

Every change needs `TARGET=plane-prod CONFIRM=plane-prod`, and sets a timer on the server that puts the previous stage back after 2
minutes unless a new SSH login works. Port 22 is open in every stage, so going back cannot lock anyone out. `edge.sh status` prints the
stage in force over SSH. `edge.sh scan` tries ports 22, 80, 443, 6443, 10250, 9100, 2379, 30000 and 32767 from this Mac, which is the
check that counts, because a check from the server sees nothing the internet sees.

### Hosted URLs

| URL | Service | Sign-in |
|---|---|---|
| `https://wayline.bereket.dev` | Plane | Workspace users. Sign-up is off, with `ENABLE_SIGNUP` at `0` |
| `https://wayline.bereket.dev/god-mode/` | Plane's instance admin | The owner's admin. The route is public |
| `https://grafana.bereket.dev` | Grafana | One admin login, from `make remote-grafana-admin TARGET=plane-prod VERB=login` |
| `https://infisical.bereket.dev` | Infisical | Its one admin, with an authenticator app. Public from 2026-11-07, by the owner's choice: [ADR 0017](adr/0017-infisical-public-route.md) |
| `make remote-ui TARGET=plane-prod UI=argocd` | Argo CD, on `http://localhost:18080` | `admin`, password in Secret `argocd/argocd-initial-admin-secret`, key `password` |
| `make remote-ui TARGET=plane-prod UI=prometheus`, `UI=alertmanager` | Prometheus and Alertmanager, on 19090 and 19093 | None |
| `make remote-ui TARGET=plane-prod UI=grafana`, `UI=infisical` | Grafana and Infisical, on 18090 and 18100 | The same logins. This is the way in when a public route is down |

Argo CD, Prometheus, Alertmanager and the storage consoles have no public route, and `policy/hosted.rego` refuses one. `make remote-ui`
takes the next free port when its own is taken, and prints the address it used.

### Hosted make targets

Each needs `TARGET=plane-prod`.

| Target | What it does | Parameters |
|---|---|---|
| `make remote-tunnel` | The SSH tunnel to K3s's API. Scripts start it when they need it | `VERB=start`, `stop` or `status` |
| `make remote-kubeconfig` | Fetches K3s's kubeconfig for the tunnel, and prints the `kube-system` UID | |
| `make remote-status` | Read-only: the node and its disk, Applications, pods that are not ready, certificates, backups, the firewall, branch `deploy/plane-prod`, alert delivery, copies off the VPS, when Infisical's admin token ends, and the recovery bundle | |
| `make remote-bootstrap` | `scripts/hosted/bootstrap.sh`, above | `CONFIRM=plane-prod` |
| `make remote-ui` | A port-forward to one admin UI, until Ctrl-C | `UI=argocd`, `grafana`, `prometheus`, `alertmanager` or `infisical`, `PORT=` |
| `make remote-grafana-admin` | Grafana's admin login: `apply` makes it once, `rotate` replaces the password, `login` prints the URL and username and copies the password | `VERB=`, and `CONFIRM=plane-prod` for `apply` and `rotate` |
| `make remote-infisical-admin` | `VERB=login` prints Infisical's URL and admin email, and copies the password | `VERB=login` |
| `make remote-smoke` | The smoke test over HTTPS on an existing account, asked at hidden prompts. It removes what it makes | `SMOKE_WORKSPACE=`, `SMOKE_ALLOW_STAGING=yes` |
| `make remote-test` | The hosted suite. Sections: `outside`, `argo`, `netpol`, `routes`, `psa`, `secrets`, `smoke`, `alerts`, `backups`. Exits 0 when every row passed, 1 on a failure, and 2 when nothing failed and something read BLOCKED or INCOMPLETE | `CONFIRM=plane-prod`, `ONLY="<sections>"` |
| `make remote-netpol` | The NetworkPolicy sentinel and matrix alone, with short-lived probe pods | `CONFIRM=plane-prod`, `FROM_NS=` |
| `make remote-backup` | Tonight's backups, now | `CONFIRM=plane-prod`, `ONLY=plane-prod` or `infisical` |
| `make remote-restart-check` | Restarts Plane's pods one at a time and compares what Postgres holds before and after. The site is down briefly, and an alert may reach the owner's phone | `CONFIRM=plane-prod` |
| `make remote-pull-setup`, `make remote-pull-backups` | The read-only SFTP user on the node, then a pull of the encrypted backups to this Mac | `CONFIRM=plane-prod` for the first |
| `make remote-backup-dest` | Copies off the VPS | `VERB=verify`, `push` or `status` |
| `make remote-restore-test` | Restores the newest backup into an isolated namespace, proves it and removes it, on the VPS or, with `RESTORE_ON=kind`, from this Mac's copy into the kind cluster | `CONFIRM=plane-prod`, `ONLY=`, `KEEP=yes` |
| `make remote-alerts` | Renders alert delivery from the owner's files, and says COMPLETE or INCOMPLETE | `CONFIRM=plane-prod`, `VERB=state` |
| `make remote-bundle` | Writes the recovery bundle and proves it decrypts | `VERB=init` or `verify` |
| `make remote-publish-evidence` | Keeps the hosted Secrets' values for the scrub, then runs `make publish-evidence` | |

Four scripts have no target, because they run before there is a cluster or outside it: `provision-node.sh`, `edge.sh`,
`host-terraform.sh` and `owner-inputs.sh`, with `contabo-login.sh` beside them. `make scan-images-hosted` is local: it scans what hosted
production runs from the registries alone, and reaches no cluster. See [security.md](security.md).

### What has run on hosted production

Each result with its date and evidence. A run that has not happened yet reads PENDING.

| Run | Result | When | Evidence |
|---|---|---|---|
| The VPS before any change, and wayline's A record | PASS: Contabo reads instance 203733427 running with 12 cores; the server ran Ubuntu 24.04.5 with 47 GiB of memory and 385 GiB of disk free; the record answered `5.253.234.127` from both Vercel name servers, 8.8.8.8 and 1.1.1.1 | 2026-11-06T21:27Z | [hosted-access-dns](evidence/runs/hosted-access-dns-20261106T212722Z.txt) |
| `provision-node.sh access`, `os`, `k3s` | PASS: the node Ready on v1.36.6+k3s1, secrets encryption enabled, SSH by public key alone with root login off, the firewall at `closed`, and from this Mac only 22 open of the nine ports `edge.sh scan` tries | 2026-11-06T22:59Z | [hosted-node](evidence/runs/hosted-node-20261106T225936Z.txt) |
| First `make remote-bootstrap` | BLOCKED at step 6, which refused, as it should, because the GHCR token, an owner input, did not exist yet, so the stop says nothing about the platform. Steps 1 to 5 had run: Terraform added 26 resources and then 2, port 80 opened, and secret zero was made. Exit 2 in 191 s | 2026-11-07T04:26Z | [log](evidence/runs/hosted-bootstrap-20261107T042651Z.txt) |
| First `make remote-netpol`, before any Plane workload | BLOCKED: 143 PASS, 0 FAIL and 67 INCONCLUSIVE of 210 rows, exit 2, 62 of them because Plane's Services did not exist yet. A try without `CONFIRM=plane-prod` refused first | 2026-11-07T04:38Z | [refused](evidence/runs/hosted-netpol-first-20261107T043754Z.txt), [run](evidence/runs/hosted-netpol-first-20261107T043810Z.txt), [rows](evidence/runs/netpol-plane-prod-20261107T043811Z.tsv) |
| Second `make remote-bootstrap`, with the token | PASS, exit 0 in 94 s. Terraform found nothing to change, and Infisical's root added 5 resources. Alert delivery and the recovery bundle read INCOMPLETE, because the owner's Telegram and Healthchecks files and the bundle's recipient did not exist yet | 2026-11-07T05:03Z | [log](evidence/runs/hosted-bootstrap-20261107T050333Z.txt) |
| `make remote-test ONLY=secrets`, after Infisical's new values | PASS, every row, 47 of 47 | 2026-11-07T18:44Z | Not published: `.local/evidence-raw/test-hosted-20261107T184239Z.txt`, so not a result until it is in `docs/evidence` |
| Infisical's route: `make remote-test ONLY="outside secrets routes"` | PENDING | 2026-11-07 | |
| `make remote-netpol`, the whole matrix | PENDING | 2026-11-07 | |
| `make remote-test`, the whole suite | PENDING | 2026-11-07 | |
| `make remote-restart-check` | PENDING | 2026-11-07 | |
| `make remote-smoke`, on the owner's account | PENDING | 2026-11-07 | |
| `scan-hosted.yml` on GitHub, every hosted image | PENDING | 2026-11-07 | |
| `make remote-bootstrap` as it stands now, from start to end | NOT RUN. Both runs above were at `201c85b`. Grafana's login in step 2 and the Infisical checks in steps 3 and 6 came later | | |
| The whole order above, on a second VPS | NOT RUN. It is read from the scripts | | |

The dev side of the first promotion, which ran the exact digests on this Mac, is in [argocd.md](argocd.md#exact-digest-image-sets).

### Day to day

- **Look first.** `make remote-status TARGET=plane-prod` reads everything above and changes nothing.
- **By hand.** Scripts set the kubeconfig for themselves. For `kubectl`, define this in your shell, and never merge that kubeconfig into
  `~/.kube/config`, where another tool could pick it up:
  ```bash
  kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
  ```
- **Credentials.** The `login` verbs put a password on the clipboard and print none. Argo CD's is read the same way as the local one,
  with `kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy`.
- **The recovery bundle.** `make remote-bundle TARGET=plane-prod` after every bootstrap, token change or Terraform apply, because a newer
  secret or state makes the older bundle stale. `make remote-bundle TARGET=plane-prod VERB=verify` says whether it is.
- **Backups.** The nightly CronJobs keep them on the VPS. `make remote-pull-backups TARGET=plane-prod` is the copy off it, and it runs
  only when someone runs it, unless the owner set up the S3 copy.
- **Teardown.** No target deletes hosted production, and none should. Do not run `terraform destroy` on either hosted root: see
  [terraform.md](terraform.md#destroy-caveats).
- **When something breaks.** The hosted runbooks: [rollback](runbooks/hosted-rollback.md), [restore](runbooks/hosted-restore.md) and
  [lockout](runbooks/hosted-lockout.md).

### When a hosted step stops

Every row but the last quotes the script's own message.

| Message | Why | What to do |
|---|---|---|
| `.local/hosted/known_hosts is missing` | The host's key is not recorded | Record it with `ssh-keyscan`, then run the step again |
| `target.yaml says kube_system_uid: pending, which admits only provisioning` | The cluster's UID is not recorded | `make remote-kubeconfig TARGET=plane-prod`, then record the UID it prints |
| `the live kube-system UID is ... and target.yaml records ...` | This is another cluster, or K3s was installed again | Find out which before changing `target.yaml` |
| `.local/hosted/plane-prod/ghcr-pull-token is missing` | The bootstrap's step 6 needs the pull token | `scripts/hosted/owner-inputs.sh ghcr`, then the bootstrap again. The first real bootstrap ended here |
| `443 is open to everyone, and Infisical reads ...` | The bootstrap would deploy Infisical's route before its admin exists | `TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh http`, the bootstrap, then `edge.sh open` |
| `the firewall's table is not loaded, so this node has no public firewall` | No stage is loaded | `TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh http` |
| `... terraform.tfstate is missing, so Terraform would import wayline again` | `host-terraform.sh` ran in a checkout that holds no state | Run it from the checkout that holds `.local/hosted/plane-prod`, or bring the state back from the recovery bundle |
| `this plan is: ... EXPECT says: ... Nothing was applied` | The plan changed since you read it | Run `plan` again and read it |
| `Plane's instance reads 'unclaimed'` from `edge.sh open` | Plane has no first admin, and whoever posts first would own it | Make the admin at stage `owner`, then `open` |
| `something else already listens on 127.0.0.1:16443` | The tunnel's port is taken | Free that port. The tunnel will not share it |
| A Certificate stays not Ready after port 80 opened | Its first order failed behind the closed firewall, and the next try is an hour away, doubling up to 32 | `scripts/hosted/README.md`, section The first certificate |
