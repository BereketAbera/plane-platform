# Validation

The test matrix for Wayline, a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0) on a local
kind cluster. Wayline is not an original product, and most of what these tests exercise is upstream Plane behaviour
running under this platform's configuration.

## Read this first

Only the nine day-1 gates have a result. They check low-level assumptions about the cluster. **Plane itself has no
result in this matrix.** As of commit `f733b87` on 2026-11-04, nothing here shows that Plane installs, signs in, keeps
data or recovers on this platform.

A full column of PASS would not change these limits:

- **It would not show production readiness.** This runs on one laptop, on one kind node, in one Docker VM, with no TLS
  and one replica of most workloads. This matrix makes no production readiness claim.
- **Namespace separation is not equivalent to independent production clusters.** `plane-dev` and `plane-prod-sim` share
  a node, a kernel, a control plane, an API server, an ingress controller, an Argo CD and an Infisical. The NET rows test
  NetworkPolicy inside that one cluster. They do not test isolation between clusters.
- **`prod-sim` is a simulation.** It has no real users, no real data and no independent failure domain.

## Status values

| Status | Meaning |
|---|---|
| PASS | The test ran, met its criterion, and its raw output is in [`docs/evidence/`](evidence/README.md) |
| FAIL | The test ran and the system misbehaved |
| BLOCKED | The test could not run or finish because something it depends on failed or is missing. This says nothing about the system under test |
| NOT RUN | The test was not attempted, or it was attempted and no evidence was captured |

A row changes status only when its evidence is committed. Some rows check more than one thing. Such a row is PASS only
when all of them pass.

How script outcomes map to status:

| Script | Outcome | Status |
|---|---|---|
| `tests/e2e/smoke.py` | Exit 0, all named steps PASS | PASS |
| `tests/e2e/smoke.py` | Exit 1, at least one FAIL | FAIL |
| `tests/e2e/smoke.py` | Exit 2, no FAIL but a step BLOCKED | BLOCKED |
| `scripts/test-netpol.sh` | Any row FAIL | FAIL |
| `scripts/test-netpol.sh` | No FAIL, any row INCONCLUSIVE (DNS failure or no result) | BLOCKED, never PASS |
| `scripts/restore.sh` | A proof step recorded as NOT RUN | Not PASS, even if every other step passed |
| `tests/drills/*.sh` | The last line, `RESULT PASS` or `RESULT FAIL` | The same |
| `tests/load/run.sh` | A k6 threshold fails, but the run finished and captured its data | PASS for the measurement. Report the threshold failure in the row, because the thresholds are starting points (`tests/load/plane.js`) |

## Current state of the entry points

These affect how the rows below run. They describe commit `f733b87`.

| Item | State | Effect |
|---|---|---|
| `scripts/up.sh` | Called by `make up`, not in the repository | INST and TEAR rows cannot run through `make up` until it exists. [[VERIFY: scripts/up.sh exists and make up runs]] |
| `scripts/test.sh` | Called by `make test` and `make test-e2e`, not in the repository | Run `python3 -B tests/e2e/smoke.py --env dev` directly until it exists. [[VERIFY: scripts/test.sh exists and make test-e2e runs smoke.py]] |
| `drill-*` make targets | Listed in contract section 11, not in the Makefile | Drills are shown below as direct script calls. [[VERIFY: make drill-* targets exist, or the contract no longer lists them]] |
| `apps/wayline/` | Not in the repository, and the overlays reference upstream `docker.io/makeplane/*` images | Until it exists, tests exercise unbranded upstream images. `make images` and `images.yml` build nothing, and exit 0. [[VERIFY: apps/wayline/images.txt exists and Wayline images are built by digest]] |

Commands that use `kubectl` assume `export KUBECONFIG=.local/kubeconfig`, and run from the repository root.

## Summary

| Status | Rows |
|---|---:|
| PASS | 9 |
| FAIL | 0 |
| BLOCKED | 0 |
| NOT RUN | 75 |

The owner's required list maps to these sections:

| Owner's item | Rows |
|---|---|
| 1. Clean local installation | [INST](#1-clean-local-installation) |
| 2. Plane auth and basic workflows | [AUTH](#2-plane-auth-and-basic-workflows) |
| 3. Persistent data after Pod restarts | [PERS](#3-persistent-data-after-pod-restarts) |
| 4. GitOps sync | [GITOPS](#4-gitops-sync) |
| 5. Secret sync and rotation | [SEC](#5-secret-sync-and-rotation) |
| 6. Failed deployment and rollback | [DEP](#6-failed-deployment-and-rollback) |
| 7. Backup and restoration, including one full restoration into a clean environment | [BKP](#7-backup-and-restoration), row BKP-6 |
| 8. Basic load and resource measurements | [LOAD](#8-basic-load-and-resource-measurements) |
| 9. Monitoring and alert verification | [MON](#9-monitoring-and-alert-verification) |
| 10. Clean teardown and recreation | [TEAR](#10-clean-teardown-and-recreation) |
| Background jobs | [JOB](#background-jobs) |
| Real-time collaboration | [RT](#real-time-collaboration) |
| File uploads surviving restarts | [UP](#file-uploads), row UP-2 |
| NetworkPolicy matrix | [NET](#networkpolicy-matrix) |
| Real GitHub Actions runs | [CI](#real-github-actions-runs) |

## Test matrix

### Day-1 gates

Cheap checks that run before the platform is deployed. All nine lines come from one run. See the
[evidence index](evidence/README.md#index) for its date and command.

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| G1-1 | A pod pulls a `docker.io` image by digest | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | One small busybox image. Says nothing about the size or quota cost of the full image set |
| G1-2 | A pod pulls a `quay.io` image by digest | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | One small image |
| G1-3 | The Docker Hub pull-through cache holds blobs, so containerd did not bypass it | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | Checks only that the blob directory of `plane-mirror-docker` is not empty. Does not check the quay or `registry.k8s.io` caches, or fallback to Docker Hub |
| G1-4 | A pod pulls from `localhost:5001` by digest | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | A retagged busybox image, not a Wayline image |
| G2-1 | Positive control: traffic flows before any policy | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | Throwaway `gate-checks` namespace |
| G2-2 | kindnet enforces a default-deny on a new connection | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | The client saw `wget: download timed out`. Tests a throwaway policy, not the platform's policies, which NET-2 covers |
| G2-3 | An allow rule admits a labelled client | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | The line reads "admits only the labelled client", but this step tests only the labelled client. The denial of an unlabelled client is G2-2, under the previous policy |
| G5-1 | Pods resolve the Docker-network name `plane-git` | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | An earlier run printed FAIL on this line. The script's comment attributes it to busybox `nslookup` and search domains. See the [evidence index](evidence/README.md#index) |
| G5-2 | `git://` `ls-remote` works from a pod | `make gates` | PASS | [day1-gates.txt](evidence/day1-gates.txt) | From an `alpine/git` pod against a throwaway `gate.git`. This is not Argo CD and not the platform repository. GITOPS-1 covers those |

### 1. Clean local installation

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| INST-1 | From a clean host, repository commands alone reach a running platform with both environments | `make setup`, then `make up` | NOT RUN | none | Clean means no cluster, no `.local/`, no local-service volumes. [[VERIFY: make up finishes with no manual step and make status shows every Application Synced and Healthy]] [[MEASURE: wall-clock time of a first make up]] |
| INST-2 | `make up` is idempotent | `make up` again after INST-1 | NOT RUN | none | [[VERIFY: a second make up changes no workload and exits 0]] |
| INST-3 | The prerequisite check accepts this host, and states its limits | `./scripts/prereqs.sh` | NOT RUN | none | Limits are listed in [resource-utilization.md](resource-utilization.md#minimums-used-by-the-scripts). [[VERIFY: prereqs.sh exits 0 on this host and reports Docker memory, CPUs and free disk]] |
| INST-4 | Terraform's state matches what it owns, with no drift after install | `.tools/bin/terraform -chdir=infrastructure/terraform/environments/local plan -detailed-exitcode` | NOT RUN | none | Covers only namespaces, quotas, LimitRanges, the CoreDNS rewrite, the Argo CD release, AppProjects and the root Application. Terraform does not create the cluster: `scripts/cluster-up.sh` does that through the kind CLI. Compose owns the registry, caches and Git remote. [[VERIFY: plan exits 0 with no changes after a clean install]] |

### 2. Plane auth and basic workflows

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| AUTH-1 | Dev is reachable through Traefik, instance setup completes, CSRF is enforced, and sign-in works | `make test-e2e ENV=dev`, steps `reachable`, `instance-setup`, `csrf-enforced`, `sign-in` | NOT RUN | none | HTTP only, as `smoke.py` drives the API rather than a browser. [[VERIFY: all four steps PASS in the dev smoke evidence]] |
| AUTH-2 | Dev creates and lists a workspace, API token, project and work item | `make test-e2e ENV=dev`, steps `workspace`, `api-token`, `project`, `work-item`, `work-item-list` | NOT RUN | none | [[VERIFY: all five steps PASS in the dev smoke evidence]] |
| AUTH-3 | The same flow works in prod-sim | `make test-e2e ENV=prod-sim` | NOT RUN | none | [[VERIFY: every full-mode smoke step PASSes in the prod-sim evidence]] |
| AUTH-4 | Sessions on the two hosts stay separate in a real browser, and `*.localhost` works in Safari | No script. Sign in to `http://plane.dev.localhost` and `http://plane.prod-sim.localhost` at once, in Chrome and Safari | NOT RUN | none | Evidence would be a screenshot plus browser version. [[VERIFY: both sessions stay signed in at once and each host keeps its own cookie]] |

### 3. Persistent data after Pod restarts

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| PERS-1 | Dev data survives deletion of each StatefulSet pod, one at a time | `tests/drills/pod-restart-persistence.sh dev` | NOT RUN | none | Needs a prior `make test-e2e ENV=dev` for the sentinel. Each round re-reads the sentinel and runs a new background job. [[VERIFY: drill ends RESULT PASS with a round for postgres, valkey, rabbitmq and silo]] |
| PERS-2 | The same in prod-sim | `tests/drills/pod-restart-persistence.sh prod-sim` | NOT RUN | none | Needs a prior `make test-e2e ENV=prod-sim`. [[VERIFY: drill ends RESULT PASS in prod-sim]] |
| PERS-3 | `make down` keeps all data and `make up` resumes it | `make down`, `make up`, then `python3 -B tests/e2e/smoke.py --env dev --mode verify --job-probe` | NOT RUN | none | Repeat with `--env prod-sim`. [[VERIFY: sentinel row and attachment are intact in both environments after a stop and resume]] |

### 4. GitOps sync

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| GITOPS-1 | Argo CD reads `git://plane-git/plane-platform.git`, and the root app brings up all 13 child Applications | `make status`, after INST-1 | NOT RUN | none | G5-2 tested `git://` from a pod, not from Argo CD. [[VERIFY: Argo CD fetches over git:// and all child Applications report Synced and Healthy]] |
| GITOPS-2 | Sync waves gate on health on a fresh install: Infisical CRs, then StatefulSets, then the migrator hook at wave 2, then Deployments | INST-1, then `.tools/bin/kubectl -n argocd get application plane-dev -o yaml` | NOT RUN | none | Contract section 6 requires the migrator to be a `Sync` hook, because `PreSync` deadlocks a fresh install. [[VERIFY: sync history shows wave order and the migrator completes before Deployments start]] |
| GITOPS-3 | A commit published to the local remote reaches the cluster | Change a value, commit, `make gitops-publish`, `make status` | NOT RUN | none | DEP-1 exercises the same path. [[VERIFY: the new revision appears on the Application and the workload changes]] [[MEASURE: seconds from gitops-publish to Synced]] |
| GITOPS-4 | Self-heal reverts a manual change | `.tools/bin/kubectl -n plane-dev scale deployment/plane-web-wl --replicas=0`, then watch the replica count | NOT RUN | none | [[VERIFY: Argo CD restores the replica count with no operator action]] [[MEASURE: seconds until self-heal restores the Deployment]] |
| GITOPS-5 | The `plane-dev` project refuses what the contract says it may not create | No script. Add a NetworkPolicy to `gitops/environments/dev/manifests.yaml` on a throwaway commit, publish, read the sync error, revert | NOT RUN | none | `policy/` checks this statically in CI. This row needs the runtime refusal from Argo CD. [[VERIFY: Argo CD refuses a NetworkPolicy in the plane-dev project]] |
| GITOPS-6 | Rendering is deterministic, and rendered manifests hold zero `kind: Secret` and only digest-pinned images | `make render` twice, then `git diff --exit-code gitops/environments`, then `./scripts/ci/validate-manifests.sh` | NOT RUN | none | A static check. It has been run during development, but its output is not in `docs/evidence/`. [[VERIFY: captured output shows no render diff and no policy failure]] |

### 5. Secret sync and rotation

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| SEC-1 | Infisical bootstraps on arm64, and the operator materialises the six contract Secrets in each Plane namespace | `.tools/bin/kubectl -n plane-dev get infisicalstaticsecrets,secrets`, and the same for `plane-prod-sim` | NOT RUN | none | Only names may go in evidence, not values. `infisical/README.md` lists what is not yet proven. [[VERIFY: all six Secrets exist with the contract's keys in both namespaces]] [[MEASURE: Infisical first-boot time through its migrations]] |
| SEC-2 | Rotating the dev Postgres password through Infisical takes effect, the old value fails, and `SECRET_KEY` does not move | `make rotate ENV=dev` | NOT RUN | none | `SECRET_KEY` must never be rotated (contract section 8). This is script-driven rotation, not native rotation, which is a paid feature. [[VERIFY: rotate log shows the old password refused, the new one accepted, and SECRET_KEY unchanged]] [[MEASURE: error window during rotation, in seconds]] |
| SEC-3 | The same in prod-sim | `make rotate ENV=prod-sim CONFIRM=yes` | NOT RUN | none | [[VERIFY: rotate log shows the same proofs in prod-sim]] |
| SEC-4 | A rotation that stops halfway can be finished or undone | Interrupt `scripts/rotate.sh ENV=dev`, then run `scripts/rotate.sh ENV=dev RESUME=yes`. Repeat with `ROLLBACK=yes` | NOT RUN | none | [[VERIFY: both recovery paths end with Plane connected to Postgres]] |
| SEC-5 | The `plane-dev` machine identity cannot read the `plane-prod-sim` project | No script. Call the Infisical API with the dev identity against the prod-sim project | NOT RUN | none | Isolation is per project, because custom roles are a paid feature. [[VERIFY: the cross-project read returns 403]] |
| SEC-6 | Secret updates do not start a loop between the operator and Argo CD self-heal | Watch `.tools/bin/kubectl -n argocd get application plane-dev -w` during SEC-2 | NOT RUN | none | `rotate.sh` reports a generation change as FAIL and restarts by hand if the annotation is missing. [[VERIFY: Application returns to Synced with no repeating self-heal]] |

### 6. Failed deployment and rollback

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| DEP-1 | A bad image reaches dev through real promotion, fails in the wave 3 rollout, old pods keep serving, and `git revert` restores | `tests/drills/failed-deploy-rollback.sh` | NOT RUN | none | Adds two commits to `main`, the promotion and its revert. [[VERIFY: drill ends RESULT PASS and the host answers 200 on every sample during the failed rollout]] |
| DEP-2 | A good promotion can be rolled back | `make promote ENV=dev IMAGE=web DIGEST=<a digest in the local registry>`, then `make rollback ENV=dev` | NOT RUN | none | This rolls back images, not the database, because migrations are forward-only. [[VERIFY: the Deployment returns to its earlier digest and the Application reports Synced and Healthy]] |
| DEP-3 | A failing migrator stops the rollout before Deployments change | No script. Pause self-heal, promote a backend image whose migrator exits 1, read the sync state, revert | NOT RUN | none | [[VERIFY: wave 3 Deployments are untouched and the Application reports failure]] |
| DEP-4 | Prod-sim refuses a digest never recorded for dev | `make promote ENV=prod-sim IMAGE=web DIGEST=<a digest never promoted to dev>` | NOT RUN | none | `scripts/ci/check-promoted-digests.sh` holds the same invariant in CI. GitHub Free cannot make that check block a merge. [[VERIFY: promote exits non-zero and changes nothing]] |
| DEP-5 | A prod-sim promotion takes a Postgres dump first | `make promote ENV=prod-sim CONFIRM=yes` | NOT RUN | none | [[VERIFY: a new backup exists in .local/backups/prod-sim before the overlay commit]] |

### 7. Backup and restoration

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| BKP-1 | Backups of dev, prod-sim and Infisical complete | `make backup ENV=all` | NOT RUN | none | Each Postgres dump is restored into a scratch database, so its row counts come from the dump. [[VERIFY: each environment has a manifest and matching SHA256SUMS]] [[MEASURE: backup size and duration per environment]] |
| BKP-2 | Restore into the same dev environment brings data back | `make restore ENV=dev BACKUP=latest CONFIRM=yes` | NOT RUN | none | [[VERIFY: restore evidence shows PASS on postgres, objects, proof-sentinel and proof-encrypted-sentinel]] [[MEASURE: dev restore duration]] |
| BKP-3 | The same in prod-sim | `make restore ENV=prod-sim BACKUP=latest CONFIRM=yes` | NOT RUN | none | [[VERIFY: restore evidence shows the same proofs in prod-sim]] |
| BKP-4 | Restore refuses to overwrite a non-empty environment without confirmation | `make restore ENV=dev BACKUP=latest` | NOT RUN | none | [[VERIFY: restore exits non-zero before touching anything]] |
| BKP-5 | Restore refuses a backup taken with a different `SECRET_KEY` | No script. Attempt a restore against an environment seeded with a different key | NOT RUN | none | A wrong key makes `decrypt_data` fail silently to `""`, so this refusal protects encrypted config rows. [[VERIFY: restore stops at key-fingerprint and changes nothing]] |
| BKP-6 | **Full restoration into a clean environment.** Everything is rebuilt, then data returns from backups only | `make backup ENV=all`, `make destroy CONFIRM=yes SKIP_BACKUP=yes`, `make up`, `make restore ENV=infisical BACKUP=latest CONFIRM=yes`, `make restore ENV=dev BACKUP=latest CONFIRM=yes`, `make restore ENV=prod-sim BACKUP=latest CONFIRM=yes`, then `python3 -B tests/e2e/smoke.py --env dev --mode verify --job-probe` and the same with `--env prod-sim` | NOT RUN | none | No script runs this sequence. Order matters: `make up` seeds a new `SECRET_KEY` on a new Infisical, and BKP-5's refusal then blocks a Plane restore unless Infisical's data and the operator's sync return first. `destroy.sh` also deletes Terraform state, so identities may need re-creating. [[VERIFY: restored Infisical returns the original SECRET_KEY to Plane and the restore passes its fingerprint check]] [[VERIFY: sentinel row and attachment read back in both environments after the full rebuild]] [[MEASURE: total time from make destroy to verified restore]] |

### 8. Basic load and resource measurements

Numbers from these rows go in [resource-utilization.md](resource-utilization.md).

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| LOAD-1 | The dev environment's behaviour at 5, 10 and 20 virtual users, 3 minutes each, with think time | `make test-load ENV=dev` | NOT RUN | none | Dev only, and it refuses prod-sim. Needs a prior `make test-e2e ENV=dev`. This measures one laptop, so it does not predict any other host. [[MEASURE: requests per second, p95 and error rate at each load step]] |
| LOAD-2 | Where the single API worker saturates | `make test-load ENV=dev THINK=0` | NOT RUN | none | Run after LOAD-1. [[MEASURE: load step and request rate at which p95 or error rate crosses its threshold]] |
| LOAD-3 | Idle CPU, memory and disk per component in both environments | Commands in [resource-utilization.md](resource-utilization.md#how-to-measure) | NOT RUN | none | No script captures this. `tests/load/run.sh` samples only `plane-dev` during a run, plus before and after snapshots of all namespaces. [[VERIFY: idle capture exists for every row of the resource tables]] |

### 9. Monitoring and alert verification

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| MON-1 | The alert path works end to end in dev: probe, rule, Alertmanager, webhook sink, firing and resolved, while prod-sim stays quiet | `make test-alert ENV=dev` | NOT RUN | none | The delivery target is the in-cluster sink. Nothing reaches a person in Pass 1. [[VERIFY: evidence shows result PASS and isolation PASS]] [[MEASURE: seconds from injection to the firing webhook, and from recovery to resolved]] |
| MON-2 | The same in prod-sim, while dev stays quiet | `make test-alert ENV=prod-sim` | NOT RUN | none | [[VERIFY: evidence shows result PASS and isolation PASS in prod-sim]] |
| MON-3 | Prometheus scrapes every expected target | `curl -s http://prometheus.localhost/api/v1/targets` | NOT RUN | none | [[VERIFY: no expected target reports health down]] |
| MON-4 | Logs from both environments reach Loki | Grafana Explore at `http://grafana.localhost`, query `{namespace="plane-dev"}` and `{namespace="plane-prod-sim"}` | NOT RUN | none | Alloy is a Deployment using `loki.source.kubernetes`. [[VERIFY: recent log lines return for both namespaces]] |
| MON-5 | The four dashboards load with data | No script. Open each in Grafana: platform overview, Plane data services, deployments and rollbacks, logs | NOT RUN | none | [[VERIFY: each dashboard shows data in its panels, not "No data"]] |
| MON-6 | The other alert rules fire when their condition is true | No script | NOT RUN | none | `monitoring/manifests/shared/` defines 18 rules, and `scripts/test-alert.sh` exercises only `PlaneApiDown`. Until this row runs, no other rule has been shown to fire. [[VERIFY: list each rule that was forced to fire, and each that was not]] |

### 10. Clean teardown and recreation

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| TEAR-1 | `make destroy` refuses without confirmation | `make destroy` | NOT RUN | none | [[VERIFY: exits non-zero and the cluster still exists]] |
| TEAR-2 | `make destroy` takes a backup, deletes the cluster, and keeps backups, secret zero and local services | `make destroy CONFIRM=yes` | NOT RUN | none | A failed backup stops the delete, unless `SKIP_BACKUP=yes`. [[VERIFY: a new backup exists, the kind cluster is gone, and .local/backups and .local/secret-zero remain]] |
| TEAR-3 | The platform comes back after a destroy, and works | `make up`, then `make test-e2e ENV=dev` and `make test-e2e ENV=prod-sim` | NOT RUN | none | Starts empty unless BKP-6 restores data. [[VERIFY: every Application reports Synced and Healthy and smoke passes in both environments]] |
| TEAR-4 | Recreation also works after removing the local services and their volumes | `make destroy CONFIRM=yes PURGE=yes`, then `make up` | NOT RUN | none | Re-pulls every image through empty caches, which spends Docker Hub quota. [[VERIFY: make up completes from empty caches]] |
| TEAR-5 | How much disk returns after a destroy | `ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` and `df -h .`, before and after TEAR-2 | NOT RUN | none | Research notes that Docker Desktop does not reliably return space on its own. [[MEASURE: Docker.raw allocated size and host free disk before and after make destroy]] |

### Background jobs

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| JOB-1 | A Celery job runs after a work item is created, in each environment | `make test-e2e ENV=dev`, step `background-job`. Repeat with `ENV=prod-sim` | NOT RUN | none | The step waits for the `issue_activity` row. [[VERIFY: step background-job PASSes in both environments]] [[MEASURE: seconds_until_activity from the smoke evidence]] |
| JOB-2 | Jobs still run after the broker restarts | `tests/drills/pod-restart-persistence.sh dev`, the `plane-rabbitmq-wl` round | NOT RUN | none | The drill uses `--job-probe`, so old rows do not count. [[VERIFY: the rabbitmq round shows a new work item's activity arriving]] |
| JOB-3 | Celery beat dispatches scheduled tasks | No script. `make logs ENV=dev SVC=beat-worker` | NOT RUN | none | [[VERIFY: beat logs show tasks being sent and the worker shows them received]] |

### Real-time collaboration

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| RT-1 | The WebSocket upgrade passes Traefik, `live` checks the session with the API, and a token naming another user is refused | `make test-e2e ENV=dev`, steps `realtime-page`, `realtime-auth`, `realtime-denied` | NOT RUN | none | This tests the handshake and authentication only, not document sync. [[VERIFY: all three steps PASS in the dev smoke evidence]] |
| RT-2 | Two clients editing one page see each other's changes, and the connection holds | No script. Open one page in two browser tabs on `http://plane.dev.localhost`, type in both, leave open for 5 minutes | NOT RUN | none | Traefik's `buffering` middleware on `/live` is the known doubt. [[VERIFY: edits appear in both tabs throughout a 5 minute soak]] |
| RT-3 | Edits survive a restart of `live` | No script. Do RT-2, then delete the `plane-live-wl` pod, reload | NOT RUN | none | [[VERIFY: page content is intact after the live pod restarts and the tabs reconnect]] |

### File uploads

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| UP-1 | An attachment uploads through a presigned URL and downloads with a matching checksum | `make test-e2e ENV=dev`, steps `attachment-upload`, `attachment-download`. Repeat with `ENV=prod-sim` | NOT RUN | none | Silo is a MinIO-compatible store, and is the fork upstream Plane pins. No bucket-creation Job exists. [[VERIFY: both steps PASS with matching sha256 in both environments]] |
| UP-2 | **An uploaded file survives restarts** of Silo and every other StatefulSet | `tests/drills/pod-restart-persistence.sh dev`, then the same with `prod-sim` | NOT RUN | none | `sentinel-reread` downloads the sentinel attachment and compares its checksum. Silo's round also checks the pod reattached the same claim. [[VERIFY: attachment checksum matches after the plane-minio-wl round in both environments]] |
| UP-3 | The API pod's `copy_object` call to its own public host works through the CoreDNS rewrite | No script, and no smoke step covers it. Duplicate an asset in the web app, expect 200 | NOT RUN | none | The rewrite exists because the API dials its own public host. [[VERIFY: asset duplication succeeds through traefik.traefik.svc.cluster.local]] |
| UP-4 | Avatars, a public space page and an export work with no bucket policy Job | No script, and no smoke step covers it. Do each in the web app | NOT RUN | none | The bucket must be `uploads`, or export links break (contract section 8). [[VERIFY: avatar loads, the public page renders, and the export link downloads]] |

### NetworkPolicy matrix

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| NET-1 | Enforcement is on, and the test can tell a block from a refusal and a DNS failure | `make test-netpol`, sentinel stage | NOT RUN | none | kindnet fails open and silently, so the script believes nothing until this passes. Throwaway namespace. [[VERIFY: all five sentinel checks print their expected class]] |
| NET-2 | Every row of [`tests/network-policy-matrix.yaml`](../tests/network-policy-matrix.yaml) behaves as declared: 383 rows, 126 allow and 257 deny | `make test-netpol` | NOT RUN | none | Sources by namespace: plane-dev 135, plane-prod-sim 134, monitoring 50, traefik 28, argocd 19, infisical 14, kube-system 3. Deny passes only on a timeout. The rows naming `telemetry.plane.so` and `api.github.com` need working DNS, or they come out inconclusive. This shows policy behaviour inside one cluster. It does not make namespaces equivalent to independent clusters. [[VERIFY: evidence TSV shows 383 PASS, 0 FAIL, 0 INCONCLUSIVE]] [[MEASURE: duration of the full matrix run]] |
| NET-3 | NodePort traffic from the host reaches Traefik under its default-deny | `make test-e2e ENV=dev`, step `reachable` | NOT RUN | none | A pod cannot exercise this path, so the matrix has no row for it. [[VERIFY: step reachable PASSes with the traefik policies applied]] |
| NET-4 | Egress to the API server works for the operator, and is refused for app pods | `make test-netpol`, rows to `kubernetes.default.svc.cluster.local`, plus SEC-1 | NOT RUN | none | [[VERIFY: operator row allows, app rows time out, and InfisicalAuth reaches ready]] |

A known limit that no row covers: `api` may reach Traefik, and Traefik routes by Host header, so `api` could request the
other environment's public hostname. NetworkPolicy cannot see that.

### Real GitHub Actions runs

Runs exist on GitHub for this repository. Their results are not recorded here, because no captured output is in
`docs/evidence/`.

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| CI-1 | `ci.yml` runs lint, manifest and security jobs on a real runner | Push to `main`, or open a pull request. Capture with `gh run view <id> --log` | NOT RUN | none | [[VERIFY: captured log of a ci.yml run shows all three jobs]] |
| CI-2 | `make ci` runs the same scripts locally | `make ci` | NOT RUN | none | [[VERIFY: captured output shows lint, validate-manifests, ownership and security exit 0]] |
| CI-3 | A failing check goes red: CI can detect a defect | Open a throwaway pull request that adds a `kind: Secret` to rendered manifests | NOT RUN | none | A green run proves little without this. [[VERIFY: the manifests job fails on that pull request]] |
| CI-4 | `images.yml` really builds and pushes Wayline images to GHCR on a native arm64 runner | Push a change under `apps/wayline/` to `main` | NOT RUN | none | **A green `images.yml` run is not evidence while `apps/wayline/images.txt` is absent.** `scripts/ci/build-images.sh` then warns and exits 0 with nothing built. Evidence must show images and digests. [[VERIFY: run log shows real builds and .build/digests.tsv lists every image]] [[MEASURE: image build duration and compressed size in GHCR]] |
| CI-5 | `images.yml` opens a dev digest-bump pull request | Follows CI-4 | NOT RUN | none | Needs the repository setting that allows Actions to create pull requests. [[VERIFY: a pull request opens with changed dev digests]] |
| CI-6 | `promote-prod-sim.yml` opens a promotion pull request, and refuses an unrecorded digest | `gh workflow run promote-prod-sim.yml`, then again with an unrecorded `digest` | NOT RUN | none | A person merging is the approval, and GitHub Free cannot enforce it. See [`.github/workflows/README.md`](../.github/workflows/README.md). [[VERIFY: first dispatch opens a pull request and second fails]] |

### Other run-only checks

Rows that the unknowns below point to, and that fit none of the sections above.

| ID | What it proves | How to run | Status | Evidence | Notes |
|---|---|---|---|---|---|
| OPS-1 | Plane boots within its startup budget under the configured CPU and memory limits | INST-1, then read `plane-api-wl` pod conditions in each environment | NOT RUN | none | [[MEASURE: seconds from pod start to Ready for plane-api-wl, serially, in each environment]] |
| OPS-2 | Each workload runs as non-root, and which accept a read-only root | `.tools/bin/kubectl -n plane-dev get pods -o yaml`, one workload at a time. PSA warnings appear in the Argo CD sync | NOT RUN | none | Contract section 2 keeps `plane-prod-sim` at `baseline` until this passes per workload. [[VERIFY: list each workload's effective UID and root filesystem mode]] |
| OPS-3 | RabbitMQ applies the absolute memory watermark from `conf.d` under its cgroup limit | `.tools/bin/kubectl -n plane-dev exec plane-rabbitmq-wl-0 -- rabbitmq-diagnostics memory_breakdown`, and the same with `status` | NOT RUN | none | [[VERIFY: effective watermark is 256Mi and no memory alarm is set]] |
| OPS-4 | Celery attaches consumers on RabbitMQ 4.2.9 with Plane CE | No script. Dev only: promote the 4.2.9 candidate, check consumers on queue `celery`, run JOB-1 | NOT RUN | none | Optional. The default stays 3.13.7. On 4.3, Celery attaches 0 consumers (contract section 9). [[VERIFY: consumer count is at least 1 and JOB-1 passes on 4.2.9]] |
| OPS-5 | Whether Docker Hub's anonymous window is 1 hour or 6 hours | No script. Read the `ratelimit-remaining` header over time | NOT RUN | none | Research found the header and the docs disagree. [[MEASURE: observed Docker Hub rate limit window]] |
| OPS-6 | The apiserver load added by `loki.source.kubernetes` | Compare apiserver CPU and memory in Prometheus with Alloy running, then scaled to zero | NOT RUN | none | [[MEASURE: apiserver CPU and memory difference with and without Alloy]] |
| OPS-7 | `guard_disk` refuses work when host disk is low | `MIN_FREE_DISK_GIB=999999 ./scripts/backup.sh dev` | NOT RUN | none | The VM cannot see the host's real limit, so `NodeFilesystem*` alerts will not protect it. [[VERIFY: the script exits non-zero before starting a Job]] |

## Run-only unknowns

These come from section 6 of the research cross-check (`CRITIQUE.md`, in the build's working notes, not committed).
Source reading could not settle them. "resolved" means evidence in `docs/evidence/` settles it. Where a gate settled
only part of an unknown, the row is split, so the rest stays visible. Design changes since that note are marked.

| # | Unknown | State | Pointer |
|---|---|---|---|
| 1a | Digest pull from `localhost:5001` and from `docker.io` | resolved | [G1-1, G1-3, G1-4](evidence/day1-gates.txt). The code now uses a local pull-through cache that fronts `mirror.gcr.io`, not `mirror.gcr.io` directly |
| 1b | Blobs missing from the mirror fall back to Docker Hub | unresolved | The gate does not separate this path. The full image set in INST-1 would exercise it |
| 2 | kindnet enforcement on this kernel | resolved | [G2-1 to G2-3](evidence/day1-gates.txt), including the `kindnet-network-policies` table and a blocked connection seen as a timeout. kind issue #4222 stalls were not looked for. NET-1 repeats the sentinel on every run |
| 3 | Pre-SNAT source of NodePort traffic at Traefik | unresolved | NET-3 |
| 4 | API server egress as node IP on 6443 | unresolved | NET-4, SEC-1 |
| 5a | `git://` reachable from a pod, and `plane-git` resolves | resolved | [G5-1, G5-2](evidence/day1-gates.txt). The Git remote is now a Compose container, not a PV-backed pod, so the PSA part of the original question no longer applies |
| 5b | Argo CD syncs an application over `git://` | unresolved | GITOPS-1 |
| 6 | Render determinism and values | unresolved | GITOPS-6 |
| 7 | Sync hook in wave 2, health gating, custom Lua; bad digest; failing migrator | unresolved | GITOPS-2, DEP-1, DEP-3 |
| 8 | Operator pod-template annotations against Argo diff and self-heal | unresolved | SEC-6 |
| 9 | Infisical on arm64: first boot under its limits, Kubernetes Auth on kind, cross-project 403, seeding under the rate limit | unresolved | SEC-1, SEC-5 |
| 10 | Plane boot time under CPU and memory limits | unresolved | OPS-1 |
| 11 | Non-root per workload, then read-only root | unresolved | OPS-2 |
| 12 | RabbitMQ under a cgroup limit, and the absolute watermark through `conf.d` | unresolved | OPS-3 |
| 13 | Celery on RabbitMQ 4.2.9 with CE | unresolved | OPS-4 |
| 14 | Uploads with no bucket Job: presigned POST, avatars, public space page, export | unresolved | UP-1, UP-4 |
| 15 | `copy_object` from the API pod through the CoreDNS rewrite | unresolved | UP-3 |
| 16 | `/live` WebSocket through `buffering`, with Hocuspocus auth | unresolved | RT-1, RT-2 |
| 17 | Postgres on the chosen storage: `initdb`, restart, data check; xattrs and UIDs on the backup mount | unresolved | PERS-1, BKP-1 |
| 18 | `*.localhost` in Safari, and cookie separation between the two hosts | unresolved | AUTH-4 |
| 19 | Real RSS, disk growth, and `Docker.raw` after the cluster is deleted | unresolved | LOAD-3, TEAR-5, [resource-utilization.md](resource-utilization.md) |
| 20 | Load effect of `loki.source.kubernetes` on apiserver and kubelet | unresolved | OPS-6 |
| 21 | Docker Hub window: 1 hour or 6 hours | unresolved | OPS-5 |
