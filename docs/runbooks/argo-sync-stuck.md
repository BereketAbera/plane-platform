# Argo CD sync stuck

An Application is not reaching `Synced` and `Healthy`, or a commit is not reaching the cluster.

Preamble for raw commands. The Argo CD CLI is not in `tools.lock`, so everything here uses `kubectl`:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
APP=plane-dev
```

## The display trap: "Running" may mean "failing"

Every Application sets `retry.limit: -1`. Finite retries would strand an app on first boot, because automated sync never reattempts a failed commit.

The cost is how a failure looks. Read at Argo CD v3.5.7, `controller/appcontroller.go` handles a failed attempt with retries left by setting the phase **back to `Running`**, setting `finishedAt`, and appending to the message. So a sync that has failed forty times shows:

| Field | Value |
|---|---|
| `status.operationState.phase` | `Running` |
| `status.operationState.finishedAt` | Set. This is the giveaway: a real running sync has no finish time |
| `status.operationState.retryCount` | Climbing |
| `status.operationState.message` | `... Retrying attempt #40 at 3:12PM.` |

The UI shows it as syncing. It never reaches `Failed` or `Error`, and three things follow:

- `ArgoSyncFailed` is expected to stay silent during the loop, because `argocd_app_sync_total` counts only completed operations. See [Monitoring](../monitoring.md#platform).
- `argo_wait_idle` in `monitoring/ops/lib.sh` waits on this phase, so `make restore` and `make test-alert` die after 180s with "has had a sync running".
- Turning off auto-sync does not stop an operation already recorded.

[[VERIFY: a failing sync under retry.limit -1 shows phase Running, a set finishedAt and a climbing retryCount]]

Backoff starts at 30 seconds, doubles, and caps at 5 minutes, so an attempt can be up to 5 minutes away.

The root loops the same way. A comment in `root-application.yaml` notes that a Degraded child fails the root's sync, and a child is often briefly Degraded on first boot, so a retrying root is normal on the way up.

## Symptoms

| Symptom | Go to |
|---|---|
| Phase `Running`, message "Retrying attempt #N" | Read the message: the real error is before "Retrying" |
| Commit made, Application still on the old revision | [Not published](#the-commit-never-reached-argo-cd) |
| `plane-dev` `Degraded` on a fresh install | Expected until bootstrap publishes the identity Secret. See below |
| `root` never finishes | A child at an earlier wave is not Healthy |
| `kube-prometheus-stack` flips OutOfSync after each publish | Chart draws a new Grafana password and checksum per render |
| `OutOfSync` forever, on a resource you did not touch | A field another controller writes |
| Migrator hook Job never finishes | See below |
| `automated.enabled: false` and nothing is syncing | A script was killed before it could resume |

## Diagnosis

Overview:

```bash
make status
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase,RETRIES:.status.operationState.retryCount,AUTO:.spec.syncPolicy.automated.enabled'
```

One Application:

```bash
kubectl -n argocd get application "$APP" -o json | jq '{sync: .status.sync.status, health: .status.health, op: .status.operationState | {phase, retryCount, finishedAt, message}, conditions: .status.conditions}'
kubectl -n argocd get application "$APP" -o json | jq -r '.status.resources[] | select(.status != "Synced" or (.health.status // "Healthy") != "Healthy") | "\(.kind)/\(.name) \(.status) \(.health.status // "-") \(.health.message // "")"'
```

Which results failed in the last attempt:

```bash
kubectl -n argocd get application "$APP" -o json | jq -r '.status.operationState.syncResult.resources[]? | select(.status != "Synced") | "\(.kind)/\(.name) \(.status) \(.hookPhase // "") \(.message // "")"'
```

Argo CD's own logs:

```bash
kubectl -n argocd logs statefulset/argocd-application-controller --tail=50
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

## Fix by cause

### The commit never reached Argo CD

Argo CD reads only `git://plane-git/plane-platform.git`, which serves the bare repo at `.local/git/plane-platform.git`. It does not read your working tree or GitHub.

```bash
git log -1 --format='%h %s' main
git --git-dir=.local/git/plane-platform.git log -1 --format='%h %s' main
docker ps --filter name=plane-git --format '{{.Names}} {{.Status}}'
make gitops-publish
kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite
```

Polling is every three minutes or so. If `plane-git` is stopped, `make up` starts it. The bare repo can be rebuilt: remove it and republish, since the working repo is the source of truth.

If `gitops-publish` refuses, see the note on non-fast-forward in [Failed deploy](failed-deploy-rollback.md#what-not-to-do).

### A bad revision is retrying

Child Applications set `retry.refresh: true`, so a retry picks up the newest commit. Fix forward or revert in Git, then publish, and the next attempt uses it. No manual step is needed beyond waiting for backoff.

The root does not have `refresh: true` as of commit f733b87, so a fix to an Application manifest cannot land while the root's operation is retrying. [[VERIFY: root-application.yaml sets retry.refresh true; if not, a fix to a child Application needs the root's operation terminated first]]

### Terminate an operation

Use this when a retrying or hung operation blocks a restore, a drill, or a fix to the root. The Argo CD CLI's `terminate-op` does the same thing, but the CLI is not installed here. This patches the phase the controller reads:

```bash
kubectl -n argocd patch application "$APP" --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd get application "$APP" -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}{"\n"}'
```

The static basis is in `appcontroller.go`: it reads this phase, and skips the retry when terminating. It has not been run. [[VERIFY: patching phase to Terminating ends a retrying operation, and auto-sync starts a new one on the next change]]

### First install: Degraded or waiting

These are expected on the way up, and are not faults on their own:

| What you see | Why | Ends when |
|---|---|---|
| `plane-dev` or `plane-prod-sim` `Degraded`, `InfisicalStaticSecret` unhealthy, pods in `CreateContainerConfigError` | Chart references are `optional: false`, so pods wait for the Secret | `scripts/infisical-bootstrap.sh` publishes the identity Secret |
| prod-sim operator crash-looping | Only `infisical-operator-dev` installs CRDs | The dev release in the same wave installs them |
| `postgres-exporter` not ready | Its Secret appears at wave -1 or later. It has `ignore-healthcheck` so it does not hold the wave | The Secret appears |
| PVC `Pending` | `WaitForFirstConsumer` | The pod schedules |
| A monitoring failure at waves -7 to -5 holds Infisical and Plane back | The root gates each wave on health | That app is fixed |

Do not wait on `root` alone: its operation can succeed right after applying the last wave. Check all Applications.

Waves on the root gate only as far as the health check says. [[VERIFY: root waves hold later waves back until the child's internal waves finish; integration review M1 found the Lua does not, and proposed a fix]]

### Migrator hook will not finish

`plane-api-migrate-1` is a `Sync` hook at wave 2, with `backoffLimit: 3`, `activeDeadlineSeconds: 900`, and `BeforeHookCreation`. It is never `PreSync`, which would deadlock a fresh install because Postgres is applied in the Sync phase.

```bash
NS=plane-dev
kubectl -n "$NS" describe job plane-api-migrate-1 | tail -20
kubectl -n "$NS" logs job/plane-api-migrate-1 --tail=50
```

Without a deadline a bad image on the hook hangs, because `ImagePullBackOff` under `restartPolicy: OnFailure` deliberately does not count as Degraded. The 900 seconds is what ends that. Note that `wait_for_db` in Plane does not actually wait, so an early attempt can fail before Postgres is ready, and `backoffLimit` covers that. [[VERIFY: the migrator succeeds on first install without manual steps, in both environments]]

Deployments stay on the old image until the hook passes, so a failed migration does not on its own take the environment down.

### OutOfSync that will not clear

| Resource | Cause | State |
|---|---|---|
| Secret `kps-grafana` | New random password per render | `ignoreDifferences` on `/data/admin-password`, in place |
| Deployment `kps-grafana` `checksum/secret` | Same render. `monitoring/README.md` documents the block | [[VERIFY: the kube-prometheus-stack Application ignores the checksum/secret annotation; at commit f733b87 it did not, so each publish restarted Grafana]] |
| Deployment pod-template annotations from the Infisical operator | The operator patches templates for auto-reload | Three-way diff should ignore fields not in Git. [[VERIFY: the operator's template annotation causes no sync loop]] |

If a new one appears, read the diff from the UI at `http://argocd.localhost`, or compare the live object with `gitops/environments/`. Add `ignoreDifferences` in Git only when another controller legitimately owns the field. Otherwise self-heal is correctly telling you something is drifting.

### Auto-sync was left paused

Scripts save the `automated` block and restore it in a trap. That trap cannot run after `kill -9`, a crash, or a reboot. The script prints the exact command when a restore fails.

Check for a pause with the overview command above. `false` in the `AUTO` column means paused, and `<none>` is the normal state.

Restore the root first. Its `automated` block in `gitops/bootstrap/chart/templates/root-application.yaml` is `prune: true, selfHeal: true`. Once the root is back, its self-heal restores each paused child from Git.

```bash
kubectl -n argocd patch application root --type json \
  -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":{"prune":true,"selfHeal":true}}]'
kubectl -n argocd get application root -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
```

[[VERIFY: after this patch the root restores a paused child's automated block from Git]]

### Argo CD itself is unwell

- repo-server limit is 384 MiB, and several charts rendering at once can pass it. See [Memory pressure](memory-pressure.md).
- The controller has a liveness probe on purpose, with 5-minute slack, so a wedged controller restarts instead of hanging silently.
- Multi-source Applications have an empty `.status.sync.revision`, so the `REVISION` column in `make status` may be blank. Use `.status.sync.revisions`.
- Argo CD has an open regression at manifest regeneration for Helm sources (#30215), masked by the Redis cache until then. Plane is not exposed to it, because Plane's manifests are rendered and committed. Platform charts are still Helm sources. [[VERIFY: no platform Application hits argo-cd#30215 at v3.5.7 across a repo-server restart]]

## Confirm

```bash
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase'
```

All of them should read `Synced`, `Healthy`, `Succeeded`, and automated sync should be on everywhere. `ArgoAppOutOfSync` and `ArgoAppDegraded` should resolve.

[[MEASURE: seconds from gitops-publish to Synced and Healthy for one digest change, with refresh and without]]

## What not to do

| Do not | Why |
|---|---|
| Read `Running` as healthy progress | Check `retryCount` and `finishedAt` |
| Read a quiet `ArgoSyncFailed` as success | It cannot see a retry loop |
| Delete an Application to reset it | It depends on the finalizer, and neither result is a clean reset. `alloy`, `kube-prometheus-stack`, `loki`, `metrics-server`, `monitoring-extras` and `traefik` have one, and **deleting them deletes their workloads**. The others, including `plane-*` and `infisical`, leave their objects orphaned |
| Sync by hand with `Replace` or `Force` on data StatefulSets | It can recreate them. Fix the cause |
| Create namespaces to get past an error | Terraform owns every namespace, and `CreateNamespace=false` is deliberate |
| Pause only a child | Root's self-heal restores it within seconds. Pause root first |
| Leave self-heal paused after a drill | The environment silently stops following Git |
| Move the migrator to `PreSync` | It deadlocks a fresh install |
