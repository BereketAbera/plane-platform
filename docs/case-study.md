# Case study: a production-inspired local platform for Plane Community Edition

The application in this project is [Plane Community Edition](https://github.com/makeplane/plane) v1.4.3, written by the Plane team and licensed AGPL-3.0. I did not write it. "Wayline" is the name of this customized deployment. My work is the platform around Plane: the cluster, delivery, secrets, hardening, observability, backups, and tests.

This case study was written before the platform was fully deployed. Sections that report results say what is proven and what is not. Open items carry `VERIFY` and `MEASURE` markers until evidence exists, as [the documentation index](README.md#how-to-read-these-documents) explains.

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

## Hard problems

Research was not a formality. A skeptical cross-check of seven research reports found 31 conflicts, nine of which would have broken a build or a sync if taken as written. For each problem below, "how it was found" says whether it came from reading a source or from running something. Most came from reading.

### 1. `kind load` cannot work on this Docker image store

**How it was found:** reading. Docker reports `io.containerd.snapshotter.v1` on this host. kind's loader runs `ctr images import --all-platforms --digests` (`pkg/cluster/nodeutils/util.go`), and [kind #3795](https://github.com/kubernetes-sigs/kind/issues/3795) is open and listed in kind's Known Issues. Four of the seven research reports assumed `kind load` would work. I did not reproduce the failure, because the design avoids it.

**Response:** `kind load` is forbidden by the contract. Branded images go through a local registry at `localhost:5001`, and every image is referenced by digest. The other workaround disables the containerd store for the whole host, which would have affected unrelated containers.

**Status:** gate 1 recorded PASS for a digest pull from `localhost:5001` ([evidence](evidence/day1-gates.txt)). It pulled a retagged busybox image, not a Wayline image.

### 2. kindnet can fail open without saying so

**How it was found:** reading first, then running. kind v0.33.0's kindnet uses `kube-network-policies` with `FailOpen: true`, and on setup errors it logs `skipping network policies` and carries on. A cluster in that state looks healthy, and every NetworkPolicy is decoration. Reading also showed that only new connections are evaluated, and that root sockets in the node's network namespace skip evaluation, so a test from a `hostNetwork` pod proves nothing.

**Response:** a runtime gate before anything else was built on top of it. Gate 2 in `tests/gates/day1.sh` has three steps:

1. Positive control: a new connection succeeds with no policy. Without this, a later block could be a broken test.
2. Apply a deny-all ingress policy, and try a new connection from a new pod.
3. Add an allow rule for one label, and try from a new pod with that label.

The [capture](evidence/day1-gates.txt) from 2026-11-04 recorded, for step 2, `client saw: wget: download timed out`, and it listed `table inet kindnet-network-policies` on the node. A timeout is the right signal: a refused connection would mean the packet arrived.

**What the gate does not prove.** These limits are as important as the result:

- It shows enforcement on one kernel at one moment, not that kindnet cannot fail open later. The monitoring rules have no alert for it. `scripts/test-netpol.sh` repeats a stricter sentinel and checks kindnet's logs, but only when someone runs it.
- The gate's code treats any probe failure as a block, including a DNS failure. Only the captured message shows it was a timeout in this run. `scripts/test-netpol.sh` is the strict version: deny passes only on a timeout, and DNS failure is inconclusive.
- Step 3 confirms the labelled client is admitted. It does not re-probe an unlabelled client after the allow rule, so the "only" in its output line goes further than the check. The matrix covers that case.

The real policy set is a 383-row matrix in `tests/network-policy-matrix.yaml`. [[VERIFY: make test-netpol ran all 383 rows with the sentinel first, and its result is in docs/evidence]]

### 3. Helm at sync time was not trustworthy

**How it was found:** reading. Two separate issues combine here.

- **Nondeterminism.** The chart puts a `timestamp` annotation from Helm's `now` in pod templates. Every render differs, so every regeneration would roll every Deployment, and it would hit the migrator Job's immutable template under a constant name.
- **An open Argo CD regression.** [argo-cd #30215](https://github.com/argoproj/argo-cd/issues/30215) affects `--enable-helm` in repo-server, with cause unsettled, and it appears only at manifest regeneration because the Redis cache masks it until then. A failure that shows up late, during an unrelated change, is the worst kind on a delivery path.

**Response:** `make render` runs `kustomize build --enable-helm` on a developer machine or in CI, and writes plain YAML to `gitops/environments/{dev,prod-sim}/manifests.yaml`. Argo CD syncs those files with no Helm or Kustomize at sync time. The hardening component strips the annotation, and `scripts/render.sh` fails if it survives, if any `kind: Secret` appears, or if any image lacks a digest. Rendering also makes a change reviewable as a diff of what will actually apply.

**What this does not solve.** Platform charts (Traefik, monitoring, Infisical) still use Argo CD Helm sources. Nondeterminism exists there too: `kube-prometheus-stack` draws a new Grafana admin password on each render, which `gitops/applications/kube-prometheus-stack.yaml` handles with `ignoreDifferences`.

[[VERIFY: make render run twice produces no diff, captured in docs/evidence]]

[[VERIFY: Argo CD syncs the rendered manifests on a fresh install without a Helm or Kustomize step]]

### 4. RabbitMQ 4.3 leaves Celery with zero consumers

**How it was found:** reading. [makeplane/helm-charts PR #304](https://github.com/makeplane/helm-charts/pull/304) reports `celery` queue consumers of 1 on 3.13.6, 1 on 4.2.9, and 0 on 4.3.5. The fix is in a private upstream repository, and the relevant setting is absent from CE v1.4.3. One research report had proposed 4.3.7 as the first promotion candidate. If that report holds, the failure would be quiet: broker up, pods running, background work not happening. I have not reproduced this myself.

**Response:** the contract pins `rabbitmq:3.13.7-management-alpine` and allows only 3.13 or 4.2. 3.13 is an end-of-life series, which is an accepted risk.

A related trap: the default relative memory watermark may not detect a cgroup limit. So `vm_memory_high_watermark.absolute = 256Mi` is mounted through `conf.d`, under a 512 Mi limit.

[[VERIFY: celery consumer count is at least 1 on rabbitmq 3.13.7 in plane-dev]]

[[VERIFY: the absolute memory watermark takes effect through conf.d, from rabbitmq-diagnostics]]

### 5. Smaller traps found by reading upstream code

| Trap | What would have happened | Response |
|---|---|---|
| Migrator as an Argo `PreSync` hook | `wait_for_db` does not actually wait, and Postgres is not applied until the Sync phase, so a fresh install exhausts retries and stops | `Sync` hook at wave 2 |
| A per-environment bucket name such as `plane-dev-uploads` | `export_task.py` strips the literal `/uploads`, so export links break | Bucket is `uploads` in both environments, with one Silo per environment for isolation |
| Rotating `SECRET_KEY` | It derives the key for encrypted config rows, and `decrypt_data` fails silently to an empty string | Documented as never rotated. `make rotate` handles database credentials |
| `*.localhost` inside pods | The API dials its own public host for `copy_object`, and loopback inside a pod is wrong | CoreDNS rewrite to Traefik, owned by Terraform |
| Retained volumes combined with data-loss drills | A new PVC reattaches the old directory, so the drill loses nothing and proves nothing | Default `standard` class in the VM |
| `docker login` for the Hub quota | kind nodes pull with their own containerd, so a laptop login does nothing for pods | Containerd mirrors point at local pull-through caches, with Hub as the fallback |

### 6. Disk limits the cluster cannot see

**How it was found:** reading and a host check. In a research reading of `df`, not captured in `docs/evidence/`, the VM filesystem showed about 410 GiB free on a sparse disk while the host had 39 GiB free. Node filesystem alerts cannot fire before the Mac runs out. kind also sets `imageGCHighThresholdPercent: 100` and eviction thresholds of `0%`, so there is no image garbage collection and no eviction, and a full disk appears as write errors.

**Response:** `guard_disk` in `scripts/lib/common.sh` checks real host free space, and `scripts/prereqs.sh` requires 25 GiB before starting.

[[VERIFY: whether kind delete cluster shrinks Docker.raw on this host]]

### 7. The gate itself was wrong once

The first day-1 gate run reported 8 passed and 1 failed: pods "cannot resolve plane-git". The failure was in the test, not the platform. Busybox `nslookup` exits non-zero on the first NXDOMAIN from a search domain, even though `git ls-remote` to the same name succeeded in the next check. A trailing dot on the name (`plane-git.`) skips search domains, and the second run recorded 9 passed. Both captures are committed: the [first run](evidence/day1-gates-20261104T184733Z.txt) and the [second run](evidence/day1-gates.txt). I include this because a green gate is only as good as the gate.

### 8. Integration findings from static review

Components built separately can each be correct and still not work together. A static integration review, with no cluster involved, reported the items below. Each was open at the time of that review.

- `make up` and `make test` called scripts that did not exist yet. [[VERIFY: scripts/up.sh and scripts/test.sh exist and run]]
- The root app-of-apps' sync waves do not hold back a child whose first internal wave is already Healthy, because Argo CD skips hooks and not-yet-created resources in health aggregation. First boots would overlap, which is the memory worst case. [[VERIFY: the Application health check holds the root wave until the child's sync ends]]
- Silo metrics default to authenticated access, so a critical alert would fire on a healthy store. [[VERIFY: PlaneMinioDown does not fire on a healthy Silo]]
- `postgres-exporter` would keep the old password after rotation. [[VERIFY: postgres-exporter stays up after make rotate]]

## What was validated, with evidence

Status here is deliberately narrow. [validation.md](validation.md) is authoritative. Everything below is either backed by a file in `docs/evidence/` or not yet run.

### Run so far: nine checks in three gate groups

`tests/gates/day1.sh` contains gates numbered 1, 2, and 5. Capture: [day1-gates.txt](evidence/day1-gates.txt). The file has no date or command header, so the [evidence index](evidence/README.md#index) records both and says how it inferred them.

| Gate | Check | Result |
|---|---|---|
| 1 | `docker.io` digest pull | PASS |
| 1 | `quay.io` digest pull | PASS |
| 1 | Pull-through cache holds blobs, so it was not bypassed | PASS |
| 1 | `localhost:5001` digest pull | PASS |
| 2 | Positive control: traffic flows before any policy | PASS |
| 2 | Default-deny blocks a new connection | PASS |
| 2 | Allow rule admits the labelled client | PASS |
| 5 | Pods resolve the Docker-network name `plane-git` | PASS |
| 5 | `git ls-remote` over `git://` from a pod | PASS |

These nine checks do not cover Plane. Gate 5 used an `alpine/git` pod with no policy applied, so it does not establish that Argo CD's repo-server can fetch through default-deny. Items 3 and 4 of the research's day-1 list (NodePort source at Traefik, API server egress) are not in this script.

### Not yet validated

| Claim to prove | Command | Result |
|---|---|---|
| Full platform comes up from clean | `make up` | [[VERIFY: make up from a clean machine, all Applications Synced and Healthy]] |
| Instance setup, sign-in, workspace, project, work item, background job, attachment round trip, real-time auth, sentinel data | `make test-e2e ENV=dev` | [[VERIFY: smoke.py result for dev]] |
| Same in the production simulation | `make test-e2e ENV=prod-sim` | [[VERIFY: smoke.py result for prod-sim]] |
| Real-time collaboration through Traefik buffering | `make test-e2e` for WebSocket auth, then a manual two-tab test | [[VERIFY: live WebSocket works through Traefik with Hocuspocus auth, and edits appear in a second tab]] |
| Export links with the `uploads` bucket | Manual, since the smoke test has no export step | [[VERIFY: an exported file downloads through its generated link]] |
| Network allow and deny matrix | `make test-netpol` | [[VERIFY: test-netpol result, all rows]] |
| Non-root on all Plane workloads | Pod inspection | [[VERIFY: which workloads run non-root, and which remain root]] |
| Secret sync and cross-project isolation | Bootstrap, then cross-read | [[VERIFY: the dev identity gets 403 reading the prod-sim project]] |
| Credential rotation | `make rotate ENV=dev` | [[VERIFY: rotate completes and Plane stays healthy]] |
| Backup and restore into an empty environment | `make backup`, `make restore` | [[VERIFY: restored environment returns the sentinel data]] |
| Alert reaches the sink | `make test-alert ENV=dev` | [[VERIFY: alert fired and was received, with timings]] |
| Bad image is refused, old pods keep serving, revert restores | `tests/drills/failed-deploy-rollback.sh` | [[VERIFY: failed-deploy drill result]] |
| Data persists across pod restart | `tests/drills/pod-restart-persistence.sh` | [[VERIFY: pod-restart drill result]] |
| Prod-sim refuses a digest not recorded for dev | `make promote ENV=prod-sim` | [[VERIFY: promotion refusal observed at runtime]] |
| Wayline branded images build and run | `make images` | [[VERIFY: apps/wayline delivered, images build, branded UI is served]] |
| CI runs on GitHub | Push | [[VERIFY: ci.yml result on GitHub]] |

### Numbers

All current figures are estimates, derived as described in the [README](../README.md#resource-expectations). They come from planning figures and registry metadata, not from this platform running.

| Quantity | Estimate | Measured |
|---|---:|---|
| Workload memory at idle | 5.5 to 9.3 GiB | [[MEASURE: idle RSS across all workloads]] |
| Peak on the Docker VM | 9.9 to 13.7 GiB | [[MEASURE: peak VM memory during first boot]] |
| Host disk growth | 16.7 to 22 GiB | [[MEASURE: host disk growth after full install]] |
| First `make up` duration | None | [[MEASURE: first make up wall-clock time]] |
| API time to Ready under limits | None | [[MEASURE: api pod start to Ready]] |
| Restore duration | None | [[MEASURE: restore wall-clock time and data size]] |
| Load test latency and error rate | None | [[MEASURE: k6 p95 latency and error rate at the tested load]] |

## What would change for production

This list is the honest gap between this project and a production service.

| Area | Here | For production |
|---|---|---|
| Isolation | Two namespaces on one node | Independent clusters or accounts per environment, with separate failure and blast-radius boundaries. Pass 2 starts this |
| Availability | One node, one replica of each stateful service | Multiple nodes, replicated or managed Postgres, a RabbitMQ and Valkey HA story, and PodDisruptionBudgets |
| Data durability | Dumps on the same laptop | Offsite encrypted backups, point-in-time recovery, and scheduled restore tests |
| Object storage | One Silo per environment on a local volume | A managed S3-compatible service |
| Network | kindnet, which fails open | A CNI that fails closed, plus egress control and continuous enforcement checks |
| Ingress | HTTP on loopback | TLS and a WAF at the edge. Pass 2 plans Cloudflare |
| Pod security | PSA `baseline` enforced, `restricted` warned | `restricted` enforced where workloads allow it, which needs per-workload proof |
| Delivery approval | A pull request merge, not enforced by GitHub Free | Required reviewers, protected branches, environment gates, image signing and attestation, which need a public repository or a paid plan |
| Secrets | Self-hosted, unlicensed Infisical, secret zero in a local file | A secret-zero path through a KMS, audit log retention, automated rotation, and Infisical run with its own backup and HA |
| Data dependencies | RabbitMQ 3.13, an end-of-life series | A supported series, after confirming upstream Celery compatibility |
| Observability | One Prometheus and Loki on the same node as what they watch | Monitoring that survives the failure it reports, and a real paging destination |
| Compliance | Source is private, and no outside users | Publish the modified source before anyone else uses it, as AGPL section 13 requires. See [agpl-compliance.md](agpl-compliance.md) |

## What I would point to

If you read one thing besides this page, read `tests/gates/day1.sh`, then `scripts/test-netpol.sh`. Together they show the approach: decide what would prove an assumption wrong, run it before building on it, and write down what the check does not establish.

Next to read:

- [Status and evidence](validation.md)
- [Known limitations](known-limitations.md)
- [Binding contract](platform-contract.md)

## Credit

Plane Community Edition is the work of the Plane team and its contributors. This project deploys and customizes it under AGPL-3.0, and it depends on many other open-source projects, including kind, Argo CD, Infisical, Traefik, the Prometheus and Grafana ecosystems, PostgreSQL, Valkey, RabbitMQ, and Silo.
