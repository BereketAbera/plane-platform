# Case study: a production-inspired local platform for Plane Community Edition

The application in this project is [Plane Community Edition](https://github.com/makeplane/plane) v1.4.3, written by the Plane team and licensed AGPL-3.0. I did not write it. "Wayline" is the name of this customized deployment. My work is the platform around Plane: the cluster, delivery, secrets, hardening, observability, backups, and tests.

I first wrote this page before anything was deployed, and updated it on 2026-11-05 with what real runs showed. The platform now runs on one laptop, and Plane works in both environments, through the staged runs described below. **A clean install, teardown and recreation, a full restore, secret rotation, the failed-deploy drill, a load test and `make test-alert` have not run.** Those items keep their `VERIFY` and `MEASURE` markers until evidence exists, as [the documentation index](README.md#how-to-read-these-documents) explains.

## Problem

Take an existing open-source application with a real set of dependencies (API, workers, scheduler, three frontends, a collaboration server, Postgres, Valkey, RabbitMQ, an S3-compatible store) and run it the way a small team would want to run it in production. That means Git-driven delivery, secrets outside Git, least privilege, restricted network paths, monitoring with alerts that demonstrably reach someone, backups that demonstrably restore, and a promotion path between environments.

The upstream chart is a starting point, but it leaves those concerns to the operator. Reading it showed, for example, that its defaults add up to about 14,000 Mi of limits across the app Deployments, with the worker at 12 forks and no limit on the datastores (estimate: a reading of `values.yaml`, not a measurement).

The goal also includes honesty about the result. A local kind cluster cannot be production, so the useful output is a platform that is reproducible, states its limits, and separates what was tested from what was only designed.

## Constraints

| Constraint | Effect on the design |
|---|---|
| One laptop with 24 GiB of memory, arm64 | The Docker VM gets 14 GiB. Two full environments plus the platform had to fit, so every workload has a contract budget and environments boot one after the other |
| Limited host disk, shared with other projects | Install size mattered. Scripts that consume disk check free host space first |
| Other containers already on the same Docker VM | The platform must not disturb them. The kubeconfig stays in `.local/`, and the host's containerd image store stays enabled even though it rules out `kind load` |
| GitHub Free, private repository | No required reviewers, protected branches, environments, or artifact attestations. Approval can only be a process |
| No paid infrastructure | Nothing cloud in Pass 1. Infisical runs unlicensed, so no custom roles, folder RBAC, or built-in rotation |
| Docker Hub anonymous pull quota | Research hit HTTP 429 on Hub during the work. Pulls had to survive it |

## Key decisions

| Decision | Why | Cost accepted |
|---|---|---|
| Two namespaces on one cluster, not two clusters | One laptop cannot carry two control planes alongside everything else | **Namespace separation is not equivalent to independent production clusters.** Both environments share a node, kernel, API server, etcd, CNI, ingress, Argo CD, and monitoring. Pass 2 moves to independent environments |
| The kind CLI creates the cluster; Docker Compose creates the registry, caches, and Git remote; Terraform handles what is inside | One owner per resource, and these services must outlive the cluster. See [ADR 0002](adr/0002-cluster-creation.md) | Terraform does not provision the local infrastructure, and the docs must not imply it. Pass 2 is where Terraform creates machines |
| Argo CD reads a local `git://` remote, not GitHub | No inbound path or stored GitHub credential is needed for a laptop cluster | A merge on GitHub changes nothing until someone runs `make gitops-publish` |
| Plane manifests are rendered and committed | See [problem 3](#3-helm-at-sync-time-was-not-trustworthy) | Generated YAML in the repository, and a CI check to keep it current |
| Each environment has its own Infisical project and machine identity, built-in `viewer` role | Custom roles and folder RBAC are paid features, so a project is the free-tier isolation boundary | Rotation is a script (`scripts/rotate.sh`), not Infisical's rotation feature |
| Volumes stay on kind's `standard` class in the VM, backups go to a host mount | Avoids Postgres on VirtioFS, and data-loss drills actually lose data | `make destroy` removes the volumes, so it backs up first unless told not to |
| kindnet, not Calico | Saves memory, and kindnet ships with kind | It fails open silently. See [problem 2](#2-kindnet-can-fail-open-without-saying-so) |
| Silo instead of MinIO | Official MinIO images no longer pull anonymously. Silo is the AGPL-3.0 fork that upstream's chart pins, and it speaks the same S3 API | A smaller project to depend on. The docs say "MinIO-compatible (Silo)" |
| Prod-sim auto-syncs with self-heal, gated at the Git change | Manual sync would make drift drills raise false alerts | GitHub cannot enforce that gate on this plan |
| Branding through a pinned source, an overlay, patches and a codemod, not a fork | Upstream stays upgradable, and the identity can be rebuilt from one upstream commit | A build pipeline to maintain. 85 patched files, +310 -499, and a check that measures the work for another upstream ref |

## Hard problems

Research was not a formality. A skeptical cross-check of seven research reports found 31 conflicts, nine of which would have broken a build or a sync if taken as written. For each problem below, "how it was found" says whether it came from reading a source or from running something. Reading caught the traps that would have stopped a first boot. Running caught what reading could not.

### 1. `kind load` cannot work on this Docker image store

**How it was found:** reading. Docker reports `io.containerd.snapshotter.v1` on this host. kind's loader runs `ctr images import --all-platforms --digests` (`pkg/cluster/nodeutils/util.go`), and [kind #3795](https://github.com/kubernetes-sigs/kind/issues/3795) is open and listed in kind's Known Issues. Four of the seven research reports assumed `kind load` would work. I did not reproduce the failure, because the design avoids it.

**Response:** `kind load` is forbidden by the contract. Branded images go through a local registry at `localhost:5001`, and every image is referenced by digest. The other workaround disables the containerd store for the whole host, which would have affected unrelated containers.

**Status:** the design held. The four branded images reached `plane-dev` from that registry by digest ([promotion `4f622e3`](evidence/branding/live-dev/README.md)).

### 2. kindnet can fail open without saying so

**How it was found:** reading first, then running. kind v0.33.0's kindnet uses `kube-network-policies` with `FailOpen: true`, and on setup errors it logs `skipping network policies` and carries on. A cluster in that state looks healthy, and every NetworkPolicy is decoration. Reading also showed that only new connections are evaluated, and that root sockets in the node's network namespace skip evaluation, so a test from a `hostNetwork` pod proves nothing.

**Response:** a runtime gate before anything was built on top of it. Gate 2 in `tests/gates/day1.sh` starts with positive controls, applies a deny-all ingress policy, then adds an allow rule for one label. A timeout is the right signal, because a refused connection would mean the packet arrived. A timeout alone can also come from something else, so each deny row now also needs a reference server that answers the same client at the same moment, and the node's root curl reaching the target, which proves the target is up. That took three rounds, because each review found another way to make it pass with no policy at all ([faults](evidence/runs/day1-gates-faults-1.txt)). The [latest run](evidence/day1-gates-20261104T231136Z.txt) has 17 checks and 0 failed.

**What running settled**, on the real policies:

- A denied connection times out, and the fail-open line appeared 0 times ([real pods](evidence/runs/netpol-real-pods-1.txt)).
- NodePort traffic reaches Traefik from the kind gateway, `172.24.0.1`, read from conntrack. With the `172.16.0.0/12` block removed, a request from the host timed out. The policy had also allowed Docker's VM subnet, `192.168.65.0/24`. No traffic used it, so it went ([source](evidence/runs/traefik-nodeport-source-1.txt)).
- API server egress is evaluated after DNAT: a pod dialling `10.96.0.1:443` connects under a rule that allows only 6443, and repo-server, which has no such rule, times out on both.
- A pod that can leave through `host.docker.internal` comes back as the host. That is a hole in the route allow list that only NetworkPolicy closes ([probe](evidence/runs/h17-doors-free-egress-2.txt)).

**What watches it now.** `KindnetSkippedNetworkPolicies` counts that log line through Alloy. On a synthetic pod it went from the line to the sink in 66 seconds, and resolved after the pod was deleted ([run](evidence/runs/h18-synthetic-2.txt)). An early version resolved falsely when Alloy restarted, because the count lives in Alloy's memory, so the rule now holds the count across a restart ([run](evidence/runs/kindnet-hold-1.txt)).

**What this does not prove.**

- No real kindnet failure has been produced, only a synthetic line, and the alert sees that one line and nothing else.
- The gate shows enforcement on one kernel at one moment. `make test-netpol` is the real check, and it only speaks when someone runs it.
- A client-side rule that drops only the traffic to the target can still read as blocked. The script's comment says so, and its PASS lines say what was observed rather than "blocked".

The real policy set is a matrix in `tests/network-policy-matrix.yaml`. From the two Plane namespaces all rows passed, 135 and 134 as the matrix then stood, with 0 FAIL and 0 INCONCLUSIVE ([dev](evidence/runs/plane-prod-sim-netpol-from-dev-1.txt), [prod-sim](evidence/runs/plane-prod-sim-netpol-from-prod-sim-1.txt)). The rows from `argocd` and `traefik` last ran before their targets existed. [[VERIFY: make test-netpol ran all 383 rows with the sentinel first, and its result is in docs/evidence]]

### 3. Helm at sync time was not trustworthy

**How it was found:** reading. Two separate issues combine here.

- **Nondeterminism.** The chart puts a `timestamp` annotation from Helm's `now` in pod templates. Every render differs, so every regeneration would roll every Deployment, and it would hit the migrator Job's immutable template under a constant name.
- **An open Argo CD regression.** [argo-cd #30215](https://github.com/argoproj/argo-cd/issues/30215) affects `--enable-helm` in repo-server, with cause unsettled, and it appears only at manifest regeneration because the Redis cache masks it until then. A failure that shows up late, during an unrelated change, is the worst kind on a delivery path.

**Response:** `make render` runs `kustomize build --enable-helm` on a developer machine or in CI, and writes plain YAML to `gitops/environments/{dev,prod-sim}/manifests.yaml`. Argo CD syncs those files with no Helm or Kustomize at sync time. The hardening component strips the annotation, and `scripts/render.sh` fails if it survives, if any `kind: Secret` appears, or if any image lacks a digest. Rendering also makes a change reviewable as a diff of what will actually apply.

**Status:** a second render matched the first ([`render.sh --check`](evidence/runs/render-m4-m7-3.txt)), and Argo CD synced those plain files on the first boot of both environments ([dev](evidence/runs/plane-dev-firstboot-1.txt), [prod-sim](evidence/runs/plane-prod-sim-firstboot-1.txt)).

**What this does not solve.** Platform charts (Traefik, monitoring, Infisical) still use Argo CD Helm sources. Nondeterminism exists there too: `kube-prometheus-stack` draws a new Grafana admin password on each render, which `gitops/applications/kube-prometheus-stack.yaml` handles with `ignoreDifferences` ([render diff](evidence/runs/kps-render-diff-1.txt)).

### 4. RabbitMQ 4.3 leaves Celery with zero consumers

**How it was found:** reading. [makeplane/helm-charts PR #304](https://github.com/makeplane/helm-charts/pull/304) reports `celery` queue consumers of 1 on 3.13.6, 1 on 4.2.9, and 0 on 4.3.5. The fix is in a private upstream repository, and the relevant setting is absent from CE v1.4.3. One research report had proposed 4.3.7 as the first promotion candidate. If that report holds, the failure would be quiet: broker up, pods running, background work not happening. I have not reproduced this myself.

**Response:** the contract pins `rabbitmq:3.13.7-management-alpine` and allows only 3.13 or 4.2. 3.13 is an end-of-life series, which is an accepted risk.

A related trap: the default relative memory watermark may not detect a cgroup limit. So `vm_memory_high_watermark.absolute = 256Mi` is mounted through `conf.d`, under a 512 Mi limit.

**Status:** on 3.13.7, the smoke test reads 1 consumer on queue `celery`, and a watermark of `{absolute,"256Mi"}` with no alarms ([output](evidence/runs/branded-dev-smoke-1.txt)). Celery on 4.2.9 has not been tried.

### 5. Sync waves that did not wait

**How it was found:** reading found the bug, and running proved the fix. A static review of the integrated code found that the root app-of-apps' waves would not hold back the next child. Argo CD removed its health check for `Application` in 1.8, and the documented replacement only copies the child's health. The controller's aggregation skips hooks and resources not created yet, so a child reads Healthy between its own waves and through its migrator. First boots would have overlapped, which is the memory worst case.

**Response:** a custom Lua health check. A child counts as Healthy only with health Healthy, no `.operation` in flight, and sync status Synced. Against 19 Application cases, the text it replaced passed 10 and the review's proposal 13, so I went further than that proposal after reading the v3.5.7 source ([static](evidence/runs/argocd-lua-static-1.txt)).

**Proof.** All 36 cases, across the four health checks, passed through `argocd admin settings resource-overrides health` in the real pod, which is gopher-lua and not the PUC Lua I had used first ([runtime](evidence/runs/argocd-lua-runtime-1.txt)). Then scratch Applications on the real controller: the child's raw health read Healthy through the whole of a 63-second hook, the check read Progressing, and the next child was created in the same second the hook finished. A resync behaved the same ([wave gating](evidence/runs/argocd-wave-gating-1.txt)).

**A second problem the first boot showed.** Argo CD's built-in check reads a Prometheus with no ready pod as Degraded, and that is every Prometheus start. On first boot, that failed the root sync, and root's retry backoff then outlasted the image pull ([timeline](evidence/runs/bootstrap-timeline-1.txt)). With an override that reads it as Progressing, the same restart closed root's sync at +29 seconds instead of +91, with no retry ([before](evidence/runs/h43-repro-before-1.txt), [after](evidence/runs/h43-repro-after-1.txt)).

**The costs, which I kept visible.** A child that stays OutOfSync now holds every later wave. A Prometheus that can never start reads Progressing rather than Degraded, and with Prometheus down no rule evaluates, so nothing says so. Root's own operation also ends right after it applies wave 0, so `make up` never reads readiness from root: it waits for all 14 Applications. None of this has run in one clean install yet.

### 6. A registry killed by its own page cache

**How it was found:** running. `plane-registry` was OOM-killed twice during pushes of the branded images, at a 128 MiB limit. The kernel's kill line was the odd part: `anon-rss:232kB`, then `anon-rss:0kB`. A process with almost no memory of its own was being killed for using too much.

**Root cause:** a cgroup is charged for the page cache its writes create. A push fills the cgroup with dirty pages faster than the disk drains them, and dirty pages cannot be reclaimed until they are written. At the kills I reproduced, `file_dirty` was 117 to 125 MB and anon was 0 to 12 KB ([runs](evidence/runs/registry-memory-1.txt)).

**Response:** I measured it on a scratch registry with the same image and flags, pushing the four real images (412 MiB on disk) in each mode, then chose the limit from that:

| Limit | Pushes | Runs | Killed | Times the limit was hit |
|---:|---|---:|---:|---|
| 128 MiB | buildx, the real path | 8 | 2 | 4,223 to 5,237 |
| 128 MiB | four at once | 9 | 6 | 4,750 to 6,716 |
| 256 MiB | four at once | 6 | 0 | 2,732 to 3,174 |
| 384 MiB | four at once | 6 | 0 | 798 to 1,115 |
| 512 MiB | four at once | 9 | 0 | 0 |

512 MiB keeps the largest push off the limit entirely, with anon and swap at or below 32 MiB. It is only a ceiling, and nearly all of it is cache the VM can reclaim once written.

**What this does not prove.** The table is from a scratch registry on this laptop's disk, and a slower disk would drain the cache more slowly. `plane-registry` itself has since taken the final image rebuild with no restart ([push](evidence/branding/images-build.txt)), and nothing has sampled its memory during such a push.

### 7. A negative control that broke the thing it tested

**How it was found:** running, and I caused it. The smoke test has a negative control: it cancels the Celery consumer, shows the background job check then fails, and adds the consumer back. Later, a pod-restart drill in prod-sim came back FAIL with exit 2. The sentinel data was intact after every restart, and new background jobs stopped running after the RabbitMQ restart ([drill](evidence/runs/drill-pod-restart-prod-sim-20261104T233500Z.log)).

**Root cause:** in Celery 5.5.3, `cancel_consumer` empties the worker's queue selection, and `add_consumer` attaches a consumer without restoring it. Everything looks fine until the next broker reconnect, which then builds its consumer from the empty selection. The worker consumes nothing, while `inspect ping` still answers pong. I reproduced it on purpose: a clean worker got its consumer back after a broker restart, and the same worker after cancel and add did not. Replacing the pod drained the 210 parked messages ([experiment](evidence/runs/plane-prod-sim-worker-broker-restart-1.txt), [source in the image](evidence/runs/harness-celery-selection-source-1.txt)).

**Response:** the smoke test now replaces the worker's pod after its control. That is a real pod replacement in dev on every `make test`, and `scripts/test.sh` says so where it runs it ([after the fix](evidence/runs/harness-worker-control-prod-sim-1.txt)). The drill passed on a clean worker ([second run](evidence/runs/drill-pod-restart-prod-sim-20261104T235402Z.log)).

**The useful accident.** `PlaneWorkerNoConsumer` fired on this real fault: pending at 23:36:20, active in Alertmanager at 23:38:20, cleared after the repair ([alert](evidence/runs/plane-prod-sim-worker-no-consumer-alert-1.txt)). Nobody set that up to fire. Checking `ping` alone would have missed it.

### 8. Stale HTML, found by the first real browser

**How it was found:** running, and only in a browser. The smoke test had passed 38 of 38 on the branded images. Then I opened `http://plane.dev.localhost` by hand, in a browser that had visited before the promotion, and it showed the old upstream page, titled "Sign up - Plane", with no error ([screenshot](evidence/branding/live-dev/00-stale-cache-after-promotion.jpg)). `fetch('/', {cache:'default'})` returned the old title and `Last-Modified`, and `{cache:'no-store'}` returned the new one.

**Root cause:** nginx in the web and admin images sends `ETag` and `Last-Modified` with no `Cache-Control`, the same as upstream's config. A browser may then reuse the HTML without asking, for about a tenth of the file's age. The upstream file was a week old. The smoke test cannot see this, because its client keeps no cache.

**Response:** a `Cache-Control` header on the HTML, which means one more image rebuild. That rebuild was still under way when I wrote this, so the fix is not yet shown in a browser.

**What else that session showed** ([record](evidence/branding/live-dev/README.md)): the first real browser sign-in on this deployment, a work item added from a board, and a page edited in one tab appearing in a second within 2 seconds. It did not cover Safari, an attachment through the file dialog, or prod-sim.

React errors #418 and #423 (hydration mismatch) appear in the console on both the upstream and the branded images. I did not find their cause, and the app works past them.

### 9. One commercially headed file in an AGPL tree

**How it was found:** reading. Source files at `v1.4.3` carry `SPDX-License-Identifier: AGPL-3.0-only`. One does not: `apps/api/plane/utils/email.py` is headed `LicenseRef-Plane-Commercial` and "Proprietary and confidential". Every email task imports it, so it ships in upstream's backend image and in anything derived from it. The owner's brief forbids using commercial-only assets without authorization, and removing a notice is not an option.

**What upstream shows:** it treats the header as a mistake. Commit `3e44777e6c` (#9865) makes the file AGPL-3.0-only on `preview`, but the latest release and `master` still carry the old header.

**Response (D12):** the notice is not edited. The derived image replaces the whole file with upstream's own later AGPL-3.0-only version, pinned by commit and hash. That version fits every caller at `v1.4.3`. The image build stops if any file under `/code` contains the commercial identifier, and removing the `COPY` did stop it. A real mail went through the file to a scratch SMTP server and back ([proof](evidence/branding/email-py.txt), [mail](evidence/branding/backend-db.txt)).

**The limit, stated plainly:** the original is still in the upstream `FROM` layer underneath, as a [walk of every layer](evidence/branding/layer-check-deployed-images.txt) confirms. A running container cannot see it, and anyone who unpacks that layer can read it. Prod-sim still runs upstream's image, where the file is in the running filesystem. So publishing is gated to private packages under the owner's account (`apps/wayline/scripts/publish-gate.sh`), and a public image is a point to take legal advice on. This is engineering, not legal advice ([details](agpl-compliance.md#the-commercial-header-in-emailpy)).

### 10. Smaller traps found by reading upstream code

| Trap | What would have happened | Response |
|---|---|---|
| Migrator as an Argo `PreSync` hook | `wait_for_db` does not actually wait, and Postgres is not applied until the Sync phase, so a fresh install exhausts retries and stops | `Sync` hook at wave 2 |
| A per-environment bucket name such as `plane-dev-uploads` | `export_task.py` strips the literal `/uploads`, so export links break | Bucket is `uploads` in both environments, with one Silo per environment for isolation |
| Rotating `SECRET_KEY` | It derives the key for encrypted config rows, and `decrypt_data` fails silently to an empty string | Documented as never rotated. `make rotate` handles database credentials |
| `*.localhost` inside pods | The API dials its own public host for `copy_object`, and loopback inside a pod is wrong | CoreDNS rewrite to Traefik, owned by Terraform |
| Retained volumes combined with data-loss drills | A new PVC reattaches the old directory, so the drill loses nothing and proves nothing | Default `standard` class in the VM |
| `docker login` for the Hub quota | kind nodes pull with their own containerd, so a laptop login does nothing for pods | Containerd mirrors point at local pull-through caches, with Hub as the fallback |

### 11. Smaller problems found by running

| Problem | What was seen | Response | Evidence |
|---|---|---|---|
| Rollouts dropped requests | Traefik kept routing to pods that were gone: 10 failed of about 2,760 samples | A 5-second `preStop` on web, admin, space, live and api. 0 failed of 5,902 across two more rollouts | [before](evidence/runs/plane-dev-rollout-availability-1.txt), [after](evidence/runs/plane-dev-rollout-availability-2.txt) |
| A first boot missed its deadline | The kubelet pulls one image at a time, so wave 3 took 448 s against a 360 s deadline. `plane-dev` read Degraded until a retry recovered it | `progressDeadlineSeconds` 600 | [first boot](evidence/runs/plane-prod-sim-firstboot-1.txt) |
| Grafana's sidecars died at start | OOM-killed at 96 MiB before logging a line, with `grafana.localhost` answering 503 | They watch ConfigMaps only, and have 160 MiB | [record](evidence/runs/bootstrap-1.txt) |
| A failing sync raised no alert | With retries unlimited the phase stays Running, the sync counter does not move, and no condition is set. A throwaway Application looped for 30 minutes unseen | `ArgoSyncFailed` also reads the open operation. It fired at 15 minutes and reached the sink 10 seconds later | [loop](evidence/runs/h16-throwaway-1.txt), [fire](evidence/runs/h16-fire-1.txt) |
| A commit that cannot render was silent too | Sync Unknown, health Healthy, no operation, so auto-sync never starts and no rule matched | `ArgoAppSyncUnknown` | [run](evidence/runs/argo-sync-unknown-1.txt) |
| A Plane pod could read every metric | `api` must reach Traefik for its self-dial, and Traefik routes by Host header. From an `api` pod, 30 rows of a new test failed | A `node-network-only` allow list on all 5 internal UIs. A source-address check, not a login | [before](evidence/runs/routes-before-1.txt), [after](evidence/runs/routes-after-2.txt) |
| Research was wrong about Infisical's rate limit | 240 reads in 4 seconds all returned 200 on self-hosted | The limit claim was corrected | [run](evidence/runs/infisical-rate-limit-1.txt) |
| The images built here had fixable CRITICAL findings | The first complete scan failed its policy: PyJWT, proxy-addr, storybook, tinypool | Pinned or removed, and the rescan of those images passes. Upstream's images still report findings, which no commit here can change | [scans](evidence/security/README.md) |

### 12. Disk limits the cluster cannot see

**How it was found:** reading and a host check. In a research reading of `df`, not captured in `docs/evidence/`, the VM filesystem showed about 410 GiB free on a sparse disk while the host had 39 GiB free. Node filesystem alerts cannot fire before the Mac runs out. kind also sets `imageGCHighThresholdPercent: 100` and eviction thresholds of `0%`, so there is no image garbage collection and no eviction, and a full disk appears as write errors.

**Response:** `guard_disk` in `scripts/lib/common.sh` checks real host free space, and `scripts/prereqs.sh` requires 25 GiB before starting. This was not theoretical. Host free space fell to about 13 GiB during this work ([reading](evidence/runs/monitoring-memory-1.txt)), and the image scan's limits had to be lowered to finish ([scan](evidence/security/README.md)).

[[VERIFY: whether kind delete cluster shrinks Docker.raw on this host]]

### 13. The gate itself was wrong, more than once

The first day-1 gate run reported 8 passed and 1 failed: pods "cannot resolve plane-git". The failure was in the test, not the platform. Busybox `nslookup` exits non-zero on the first NXDOMAIN from a search domain, even though `git ls-remote` to the same name succeeded in the next check. A trailing dot on the name (`plane-git.`) skips search domains. Both captures are committed: the [first run](evidence/day1-gates-20261104T184733Z.txt) and the [second run](evidence/day1-gates.txt).

That second run recorded 9 passed, and it overclaimed. It counted any probe failure as a deny, including a DNS failure. One line said "admits only the labelled client" when nothing tried an unlabelled one. Its check that the pull-through cache was not bypassed only counted blobs. Reviews reproduced each of these, and the script grew from 9 checks to 14, then to 17, with negative controls for each ([run](evidence/runs/day1-gates-faults-1.txt)). I include this because a green gate is only as good as the gate.

### 14. Integration findings from static review

Components built separately can each be correct and still not work together. A static integration review, with no cluster involved, reported these. Each was open at the time.

- `make up` and `make test` called scripts that did not exist yet. Both exist now and have run, `make up` in stages ([stage](evidence/runs/bootstrap-up-terraform-1.txt), [summary](evidence/runs/test-20261105T001213Z.txt)).
- The wave gating in [problem 5](#5-sync-waves-that-did-not-wait).
- Silo metrics default to authenticated access, so a critical alert would fire on a healthy store. With `MINIO_PROMETHEUS_AUTH_TYPE=public`, its metrics move, and only Watchdog was firing with 40 of 40 targets up ([metrics](evidence/runs/monitoring-silo-metrics-1.txt), [status](evidence/runs/monitoring-final-status-1.txt)).
- `postgres-exporter` would keep the old password after rotation. [[VERIFY: postgres-exporter stays up after make rotate]]

## What was validated, with evidence

Status here is deliberately narrow. [validation.md](validation.md) is authoritative. Everything below is either backed by a file in `docs/evidence/` or says it has not run. Plane steps ran on upstream images unless the row says branded, and the branded images have reached dev only.

| Claim to prove | Command | Result |
|---|---|---|
| Full platform comes up from clean | `make up` | NOT RUN. It came up in stages, and all 14 Applications read Synced and Healthy ([status](evidence/runs/plane-prod-sim-status-1.txt)). [[VERIFY: make up from a clean machine, all Applications Synced and Healthy]] |
| Instance setup, sign-in, workspace, project, work item, background job, attachment round trip, real-time auth, sentinel data | `make test-e2e ENV=dev` | PASS: 38 of 38 on branded images, 2026-11-05T00:12Z ([output](evidence/runs/branded-dev-smoke-1.txt)). An earlier FAIL is kept ([37 of 38](evidence/runs/smoke-dev-20261104T225624Z.json)) |
| Same in the production simulation | `make test-e2e ENV=prod-sim` | PASS: 37 of 37 on upstream images, 2026-11-04T23:59Z ([JSON](evidence/runs/smoke-prod-sim-20261104T235926Z.json)) |
| Real-time collaboration through Traefik buffering | `make test-e2e`, a soak, then a manual two-tab test | PASS: `realtime-*` steps in the smoke test, a 330-second idle soak ([soak](evidence/runs/plane-dev-smoke-soak-1.txt)), and edits in one tab appearing in a second within 2 seconds on branded images ([browser](evidence/branding/live-dev/README.md)) |
| Export links with the `uploads` bucket | `make test-e2e` | PASS: step `export`, whose link downloads and holds the work item ([JSON](evidence/runs/smoke-dev-20261105T001213Z.json)) |
| Network allow and deny matrix | `make test-netpol` | PASS from both Plane namespaces, and from `monitoring` and `infisical`. No published run covers every row yet. [[VERIFY: test-netpol result, all rows]] |
| Non-root on all Plane workloads | Pod inspection | PASS: each runs as its intended UID, and a server dry run of PSA `restricted` gives no warnings, on upstream images in [dev](evidence/runs/plane-dev-psa-1.txt) and [prod-sim](evidence/runs/plane-prod-sim-host-and-identity-1.txt). Read-only root has not been tried |
| Secret sync and cross-project isolation | Bootstrap, then cross-read | PASS: 88 checks on rendered Secrets ([run](evidence/runs/infisical-rendered-secrets-2.txt)), and 403 in both directions on list, read and slug lookup ([run](evidence/runs/infisical-isolation-3.txt)) |
| Separation between dev and prod-sim | `make test-separation` | PASS: 364 real attempts on the network and 97 checks on state and credentials ([network](evidence/runs/harness-separation-network-1.txt), [state](evidence/runs/harness-separation-state-1.txt)). Each `api` can still reach the other host as any browser could |
| Credential rotation | `make rotate ENV=dev` | NOT RUN. [[VERIFY: rotate completes and Plane stays healthy]] |
| Backup and restore into an empty environment | `make backup`, `make restore` | `make backup` PASS, after two early FAILs ([run](evidence/runs/dr-backup-retention-1.txt), [FAIL](evidence/runs/dr-backup-1.txt)). In-place Infisical restore PASS ([run](evidence/runs/restore-infisical-20261105T001834Z.json)). Restore rehearsed only in throwaway places. [[VERIFY: restored environment returns the sentinel data]] |
| Alert reaches the sink | `make test-alert ENV=dev` | NOT RUN. A temporary rule took 70 s from pending to the sink, and other rules have fired ([path](evidence/runs/monitoring-alert-path-1.txt)). [[VERIFY: alert fired and was received, with timings]] |
| Bad image is refused, old pods keep serving, revert restores | `tests/drills/failed-deploy-rollback.sh` | NOT RUN. [[VERIFY: failed-deploy drill result]] |
| Data persists across pod restart | `tests/drills/pod-restart-persistence.sh` | PASS in dev ([log](evidence/runs/drill-pod-restart-dev-20261104T224424Z.log)), and in prod-sim on its second run, after [problem 7](#7-a-negative-control-that-broke-the-thing-it-tested) |
| Prod-sim refuses a digest not recorded for dev | `promote-prod-sim.yml` | PASS on GitHub, run 41905513020 ([log](evidence/ci/ci-6-20261104T201931Z-run-41905513020.log)). The check on `plane-dev` that local promotion adds has run only against stubs |
| Wayline branded images build and run | `make images`, `make promote ENV=dev` | PASS in dev: every gate exited 0 ([checks](evidence/branding/checks.txt)), the branded UI is served ([browser](evidence/branding/live-dev/README.md)), and smoke passes. Prod-sim has not taken them |
| CI runs on GitHub | Push | PASS: `ci.yml` on 4 runs, first try ([evidence](evidence/ci/README.md)). `images.yml` has never built an image, and GitHub has seen no commit since `da7a4c9` |
| Teardown and recreation | `make destroy`, `make up` | NOT RUN |
| Load | `make test-load` | NOT RUN |

The day-1 gates are in the [evidence index](evidence/README.md#index). They check low-level assumptions about the cluster, and they do not cover Plane.

### Numbers

Measured on this laptop, in the conditions in [resource-utilization.md](resource-utilization.md). Estimates are from planning figures and registry metadata, written before this platform ran.

| Quantity | Estimate | Measured |
|---|---:|---|
| All pods, quiet | 5.5 to 9.3 GiB, for workload memory | 6.65 GiB (6,806 MiB) by `kubectl top`, and 8.14 GiB for the node with kubelet and containerd, 2026-11-05T00:03:44Z ([snapshot](evidence/runs/plane-prod-sim-snapshot-final-1.txt)) |
| The API server alone | 350 to 600 MiB | 1,168 MiB, about twice the high estimate |
| Docker VM used, quiet and under smoke and drills | 7.9 to 11.7 GiB when idle | 9.44 GiB median when quiet, 9.48 to 9.76 GiB by test phase, including 1 GiB of unrelated containers ([samples](evidence/runs/plane-prod-sim-memory-1.txt)) |
| Peak on the Docker VM | 9.9 to 13.7 GiB | 10.49 GiB, highest sampled, right after a change replaced the Argo CD pods. Staged first boots reached 8.62 and 9.23 GiB ([history](evidence/runs/plane-prod-sim-memory-history-1.txt)). A clean install: [[MEASURE: peak VM memory during first boot]] |
| Host disk growth | 19.5 to 24.8 GiB | [[MEASURE: host disk growth after full install]] |
| First `make up` duration | None | [[MEASURE: first make up wall-clock time]] |
| API time to Ready under limits | None | 31 to 36 seconds, with the image on the node ([startup](evidence/runs/plane-dev-startup-1.txt), [first boots](evidence/runs/plane-prod-sim-firstboot-1.txt)) |
| Restore duration | None | [[MEASURE: restore wall-clock time and data size]] |
| Load test latency and error rate | None | [[MEASURE: k6 p95 latency and error rate at the tested load]] |

## What would change for production

This list is the honest gap between this project and a production service.

| Area | Here | For production |
|---|---|---|
| Isolation | Two namespaces on one node | Independent clusters or accounts per environment, with separate failure and blast-radius boundaries. Pass 2 plans this |
| Availability | One node, one replica of each stateful service | Multiple nodes, replicated or managed Postgres, a RabbitMQ and Valkey HA story, and PodDisruptionBudgets |
| Data durability | Dumps on the same laptop | Offsite encrypted backups, point-in-time recovery, and scheduled restore tests |
| Object storage | One Silo per environment on a local volume | A managed S3-compatible service |
| Network | kindnet, which fails open | A CNI that fails closed, plus egress control and continuous enforcement checks |
| Ingress | HTTP on loopback | TLS and a WAF at the edge. Pass 2 plans Cloudflare |
| Pod security | PSA `baseline` enforced, `restricted` warned | `restricted` enforced where workloads allow it, which needs per-workload proof |
| Delivery approval | A pull request merge, not enforced by GitHub Free | Required reviewers, protected branches, environment gates, image signing and attestation, which need a public repository or a paid plan |
| Secrets | Self-hosted, unlicensed Infisical, secret zero in a local file | A secret-zero path through a KMS, audit log retention, automated rotation, and Infisical run with its own backup and HA |
| Data dependencies | RabbitMQ 3.13, an end-of-life series | A supported series, after confirming upstream Celery compatibility |
| Observability | One Prometheus and Loki on the same node as what they watch, delivering to an in-cluster sink that pages nobody | Monitoring that survives the failure it reports, and a real paging destination |
| Compliance | Source is private, and no outside users | Publish the modified source before anyone else uses it, as AGPL section 13 requires. See [agpl-compliance.md](agpl-compliance.md) |

## What I would point to

If you read one thing besides this page, read `tests/gates/day1.sh`, then `scripts/test-netpol.sh`. Together they show the approach: decide what would prove an assumption wrong, run it before building on it, and write down what the check does not establish. Then read the [first browser session](evidence/branding/live-dev/README.md), for what a passing API test could not see.

Next to read:

- [Status and evidence](validation.md)
- [Known limitations](known-limitations.md)
- [Binding contract](platform-contract.md)

## Credit

Plane Community Edition is the work of the Plane team and its contributors. This project deploys and customizes it under AGPL-3.0, and it depends on many other open-source projects, including kind, Argo CD, Infisical, Traefik, the Prometheus and Grafana ecosystems, PostgreSQL, Valkey, RabbitMQ, and Silo.
