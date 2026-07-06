# Argo CD sync stuck

An Application is not reaching `Synced` and `Healthy`, or a commit is not reaching the cluster.

Preamble for raw commands. The Argo CD CLI is not in `tools.lock`, so everything here uses `kubectl`:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
APP=plane-dev
```

## The display trap: "Running" may mean "failing"

Every Application sets `retry.limit: -1`. Finite retries would strand an app on first boot, because automated sync never reattempts a failed commit.

The cost is how a failure looks. Argo CD v3.5.7 handles a failed attempt with retries left by setting the phase **back to `Running`**, setting `finishedAt`, and appending to the message. Measured on 2026-11-04 on a throwaway Application that its project refuses, in a loop of 30 minutes ([h16-throwaway-1.txt](../evidence/runs/h16-throwaway-1.txt), and [h16-fire-1.txt](../evidence/runs/h16-fire-1.txt) for the end of the loop):

| Field | Value |
|---|---|
| `status.operationState.phase` | `Running` |
| `status.operationState.finishedAt` | Set. This is the giveaway: a real running sync has no finish time |
| `status.operationState.retryCount` | Climbing, to 8 in that time |
| `status.operationState.message` | `one or more synchronization tasks are not valid: ... Retrying attempt #7 at 11:22PM.` |
| `status.conditions` | Empty |

The UI shows it as syncing. It never reaches `Failed` or `Error`, and three things follow:

- `argocd_app_sync_total` does not move, so `ArgoSyncFailed` reads the open operation instead, and fires at 15m. See [what fires for which failure](#what-fires-for-which-failure).
- `argo_wait_idle` in `monitoring/ops/lib.sh` waits on this phase. After 180s it ends the operation, so `make restore` and `make test-alert` go on, and Argo CD will not retry that revision. That has run against a stub only ([test_lib-stub-1.txt](../evidence/runs/test_lib-stub-1.txt)).
- Turning off auto-sync does not stop an operation already recorded.

The manifests set a backoff of 30 seconds, factor 2, capped at 5 minutes, so an attempt can be up to 5 minutes away. On a real controller the first wait read about a minute, not 30 seconds: 61s and 62s after a first failure, then 120s, then 242s ([DEP-3-20261105T064517Z-timeline.txt](../evidence/runs/DEP-3-20261105T064517Z-timeline.txt), [DEP-1-20261105T062323Z-timeline.txt](../evidence/runs/DEP-1-20261105T062323Z-timeline.txt)).

The root loops the same way. A comment in `root-application.yaml` notes that a Degraded child fails the root's sync, and a child is often briefly Degraded on first boot, so a retrying root is normal on the way up. A root waiting on a child that stays `Progressing` is different: nothing failed, so it never retries.

## Symptoms

| Symptom | Go to |
|---|---|
| Phase `Running`, message "Retrying attempt #N" | Read the message: the real error is before "Retrying" |
| Phase `Running`, message "waiting for healthy state of ..." | A wave is waiting, and nothing will retry. Read the Application it names |
| Commit made, Application still on the old revision | [Not published](#the-commit-never-reached-argo-cd) |
| Sync `Unknown`, health `Healthy`, no operation | [A commit that cannot render](#a-commit-that-cannot-render) |
| `plane-dev` `Degraded` on a fresh install | Expected until bootstrap publishes the identity Secret. See below |
| `root` never finishes | A child at an earlier wave is not Healthy |
| `kube-prometheus-stack` flips between `Healthy` and `Progressing` | Something in it keeps restarting. See [Memory pressure](memory-pressure.md) |
| `OutOfSync` forever, on a resource you did not touch | A field another controller writes |
| Migrator hook Job never finishes | See below |
| `automated.enabled: false` and nothing is syncing | A script was killed before it could resume |

## What fires for which failure

Read from `monitoring/manifests/shared/rules-platform.yaml`. The last column says what has really run, with the status words from [validation](../validation.md#status-values). [Monitoring](../monitoring.md#platform) has each alert on its own.

| Failure | What Argo CD reads | What fires | Status |
|---|---|---|---|
| A commit that cannot render, or a Git that cannot be read | Sync `Unknown`, health unchanged, no operation, condition `ComparisonError` | `ArgoAppSyncUnknown` after 15m of reading Unknown, and nothing else. On an Application that was rendering, `rules-platform.yaml` estimates about 21m after the commit, and up to about 26m | PASS on a throwaway only, whose path never existed ([argo-sync-unknown-1.txt](../evidence/runs/argo-sync-unknown-1.txt)). That proves the path, not the timing from a real commit, which has not fired |
| A sync refused or failing, under retry | Phase `Running`, `retryCount` climbing | `ArgoAppDegraded` at 5m if health reads `Degraded` or `Missing`, `ArgoAppOutOfSync` and `ArgoSyncFailed` at 15m | PASS on a throwaway only ([h16-fire-1.txt](../evidence/runs/h16-fire-1.txt)) |
| A bad image in a Plane Deployment | Deployments are wave 3 of 4, so the operation stays open, fails at the 600s deadline, and retries | `ArgoAppDegraded` once Degraded for 5m, `ArgoSyncFailed` at 15m, if nobody reverts | NOT RUN for firing, pending seen. The one drill reverted 8s after the first Degraded, at 10m24s, so nothing fired: `ArgoSyncFailed` stayed pending for 13m45s, and a revert about 75s later would have let it fire ([drill-failed-deploy-20261105T062343Z-alerts.tsv](../evidence/runs/drill-failed-deploy-20261105T062343Z-alerts.tsv)) |
| A migrator that fails, in a Plane Application | `OutOfSync`, **`Healthy`**, `Running`, `retryCount` climbing. The Job fails, wave 3 is not touched | `ArgoAppOutOfSync` and `ArgoSyncFailed` at 15m, and the chart's `KubeJobFailed`. `ArgoAppDegraded` does not fire, because health stays `Healthy` | NOT RUN for firing, pending seen on all three. The one drill held for 6 minutes and then reverted ([drill-failed-migrator-20261105T064940Z.log](../evidence/runs/drill-failed-migrator-20261105T064940Z.log)) |
| A bad image in a single-wave chart Application | The sync succeeds on apply, which closes the operation, then `Degraded` at the rollout's deadline | `ArgoAppDegraded`, and `ArgoSyncFailed` never | NOT RUN |
| A chart child with no deadline to miss, such as a stuck StatefulSet | Operation closed, `Synced` and `Progressing`, while a root sync waits on it with no retry | The chart's `Kube*` rules at 15m, `ArgoAppStuckProgressing` at 30m, `ArgoRootSyncStuck` at 60m | `ArgoAppStuckProgressing`: PASS on a throwaway only, on 2026-11-05 ([monitoring-history-reads-1.txt](../evidence/runs/monitoring-history-reads-1.txt), and the run's own [argo-stuck-progressing-1.txt](../evidence/runs/argo-stuck-progressing-1.txt)). The rest: NOT RUN |
| A child `Healthy` but not `Synced`, which the override in `helm/values/argocd.yaml` reads as `Progressing` for root only | Root waits on it, while the child's own series says `Healthy` | `ArgoAppSyncUnknown` or `ArgoAppOutOfSync` at 15m, by its sync status. `ArgoAppStuckProgressing` stays quiet | NOT RUN, read from the rules |
| A Prometheus that cannot start | `Progressing`, by the override in `helm/values/argocd.yaml` | Nothing, because nothing evaluates rules. `Watchdog` stops reaching the sink, and nothing watches for that | The `Progressing` read: PASS ([h43-repro-after-1.txt](../evidence/runs/h43-repro-after-1.txt)). The rest: NOT RUN, read from the code |

## Diagnosis

Overview:

```bash
make status
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase,RETRIES:.status.operationState.retryCount,AUTO:.spec.syncPolicy.automated.enabled'
```

One Application:

```bash
kubectl -n argocd get application "$APP" -o json | jq '{sync: .status.sync.status, health: .status.health, op: .status.operationState | {phase, retryCount, finishedAt, message}, conditions: .status.conditions}'
kubectl -n argocd get application "$APP" -o json | jq -r '.status.resources[] | select(.hook != true and (.status != "Synced" or (.health.status // "Healthy") != "Healthy")) | "\(.kind)/\(.name) \(.status) \(.health.status // "-") \(.health.message // "")"'
```

A hook has no sync status, so that filter leaves hooks out: `plane-api-migrate-1` would otherwise print as `null` on a healthy Application. [Migrator hook will not finish](#migrator-hook-will-not-finish) covers the hook.

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

The controller's looks were measured 120 to 289s apart, median 193s ([alert-text-figures-1.txt](../evidence/runs/alert-text-figures-1.txt)). If `plane-git` is stopped, `make up` starts it. The bare repo can be rebuilt: remove it and republish, since the working repo is the source of truth.

If `gitops-publish` refuses, see the note on non-fast-forward in [Failed deploy](failed-deploy-rollback.md#what-not-to-do).

### A commit that cannot render

Argo CD cannot compare with Git, so sync reads `Unknown` and health stays as it was. Auto-sync runs only from `OutOfSync`, so no operation opens, nothing retries, and the cluster stays on the old commit.

Only `ArgoAppSyncUnknown` fires, after 15m of reading Unknown. A throwaway whose path never existed read Unknown from the start and reached the sink at 15m ([argo-sync-unknown-1.txt](../evidence/runs/argo-sync-unknown-1.txt)). An Application that was rendering takes longer, because the controller ignores the failure for 180s and its looks are 120 to 289s apart. A real commit read Unknown 5m57s after it, with the object it had deployed still there, so `rules-platform.yaml` estimates the alert about 21m after the commit, and up to about 26m by reading. That run stopped at pending, when the commit was taken out, so neither figure has been seen ([argo-sync-unknown-2.txt](../evidence/runs/argo-sync-unknown-2.txt)).

```bash
kubectl -n argocd get application "$APP" -o jsonpath='{.status.conditions}{"\n"}'
```

The condition `ComparisonError` holds the repo server's error. Fix or revert the commit, and publish.

**A broken file does not always read `Unknown`.** Argo CD ignores an unparsable file unless its text holds `apiVersion:`, `kind:` and `metadata:`. A first attempt at that test, a file with no `metadata:`, read `Synced` at the new revision with no condition ([argo-sync-unknown-2.txt](../evidence/runs/argo-sync-unknown-2.txt)). So a mangled manifest can pass with no alert, and with `prune: true` its objects could be pruned. That last part is from reading, not tested. Only the CI checks would catch it, and only `make gitops-publish` after them reaches the cluster.

### A bad revision is retrying

Every Application, `root` included, sets `retry.refresh: true`, so a retry picks up the newest commit. Fix forward or revert in Git, then publish, and the next attempt uses it. No manual step is needed beyond waiting for backoff.

Root's revision moved this way on the first boot, from `b98fa47` to `4a49a9c` with no new operation ([bootstrap-up-terraform-1.txt](../evidence/runs/bootstrap-up-terraform-1.txt), [argocd-root-terminate-1.txt](../evidence/runs/argocd-root-terminate-1.txt)). A revert during `plane-dev`'s retry loop landed this way twice on 2026-11-05, with a message reading `Retrying operation with latest revisions` and no step by hand. Until the next attempt, the Application can read `Synced`, `Healthy`, `Running`. See [Failed deploy](failed-deploy-rollback.md#roll-back-the-image). Nobody has watched a fix to an Application manifest land this way.

### End an operation

Use this when a retrying or hung operation blocks a restore or a drill, or when a root waiting on a child needs a fix to an Application manifest. The Argo CD CLI's `terminate-op` does the same thing, but the CLI is not installed here. The chart's CRD has no status subresource, so this patch reaches the phase the controller reads:

```bash
kubectl -n argocd patch application "$APP" --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd get application "$APP" -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}{"\n"}'
```

Measured on v3.5.7 on 2026-11-04:

| When | Result | Evidence |
|---|---|---|
| While a hook ran, on a scratch Application | `Failed`, `Operation terminated`, in the same second, and the hook Job is deleted | [argocd-terminate-2.txt](../evidence/runs/argocd-terminate-2.txt) |
| During retry backoff, on a scratch Application | `Failed`, `Operation terminated (retried 1 times).` | same file |
| During retry backoff, on the real root | `Failed`, `Operation terminated (retried 5 times).`, within 2 seconds | [argocd-root-terminate-1.txt](../evidence/runs/argocd-root-terminate-1.txt) |

**A terminated revision does not start again.** 40 seconds later the same revision had not restarted, and the controller logged `Skipping auto-sync: failed previous sync attempt to [...] and will not retry`.

**A newer commit starts it only if it leaves the Application `OutOfSync`.** One such commit synced within 5 seconds of a hard refresh ([argocd-terminate-2.txt](../evidence/runs/argocd-terminate-2.txt)). A commit that changed only a hook did nothing, because hooks are not compared and the Application stayed `Synced` ([argocd-terminate-1.txt](../evidence/runs/argocd-terminate-1.txt)).

**What root needs after it.** A terminated root stays `Failed`, and the children of its later waves stay uncreated, until there is a newer commit that leaves it `OutOfSync`. Publish one and ask for a hard refresh:

```bash
make gitops-publish
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```

Measured: root started its automated sync in the same second as the annotation and walked its waves again ([argocd-root-terminate-1.txt](../evidence/runs/argocd-root-terminate-1.txt)). Any newer commit did, because root was still `OutOfSync` with children missing. A root that reads `Synced` has nothing left to do.

### Start a child ahead of its wave

There is no need to end the root's operation. Apply the child's own file, as it is at the published commit, and its automated sync starts at once:

```bash
kubectl -n argocd apply -f gitops/applications/<child>.yaml
```

Measured with a scratch parent holding on a 60-second hook: the child started in the same second and was `Synced` and `Healthy` within a second. When the parent's wave came, it adopted the child in place, with the same UID and a tracking annotation added ([argocd-early-child-1.txt](../evidence/runs/argocd-early-child-1.txt)). That was a scratch parent, not a real child. Objects inside an Application adopt the same way: prod-sim's ServiceAccounts and Infisical CRs were applied by hand 17 minutes before root reached wave 0, and kept their UIDs ([infisical-prod-sim-crs-1.txt](../evidence/runs/infisical-prod-sim-crs-1.txt)).

### First install: Degraded or waiting

These are expected on the way up, and are not faults on their own:

| What you see | Why | Ends when |
|---|---|---|
| `plane-dev` or `plane-prod-sim` `Degraded`, `InfisicalAuth` unhealthy | The sync fails and retries until the identity Secret exists. On the first boot the retry landed 3m10s after it was published ([infisical-unready-sync-1.txt](../evidence/runs/infisical-unready-sync-1.txt)) | `scripts/infisical-bootstrap.sh` publishes the identity Secret, then backoff runs out |
| Pods in `CreateContainerConfigError` | Chart references are `optional: false`, so pods wait for the Secret | The operator writes it |
| A Plane Application in wave 3 for minutes, with pods `ContainerCreating` | The kubelet pulls one image at a time, so a Deployment also waits for every pull queued ahead of it. Four new images took 175s, 216s, 52s and 5s in turn, 448s for the last ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt), [plane-prod-sim-firstboot-1.txt](../evidence/runs/plane-prod-sim-firstboot-1.txt)) | The pulls finish. The deadline is 600s, and a 360s deadline failed web, admin and space on that boot. That event was read live and is not in a saved file. The nearest saved trace is `ArgoAppDegraded` pending on `plane-dev` and `root` from 21:41:45Z to 21:43:00Z ([monitoring-history-reads-1.txt](../evidence/runs/monitoring-history-reads-1.txt)). A miss reads `Degraded` until a retry |
| `kube-prometheus-stack` `Progressing` for about 10 minutes | Its images pull through the mirror: 591s on the first boot ([bootstrap-1.txt](../evidence/runs/bootstrap-1.txt)). A Prometheus with no ready pod reads `Progressing`, so root waits with no retry | The pod is ready |
| prod-sim operator crash-looping | Only `infisical-operator-dev` installs CRDs. Predicted from the chart, and not seen on the first boot | The dev release in the same wave installs them |
| `postgres-exporter` not ready | Its Secret appears at wave -1 or later. It has `ignore-healthcheck`, so it does not hold the wave ([monitoring-ignore-healthcheck-1.txt](../evidence/runs/monitoring-ignore-healthcheck-1.txt)) | The Secret appears |
| PVC `Pending` | `WaitForFirstConsumer` | The pod schedules |
| A monitoring failure at waves -7 to -5 holds Infisical and Plane back | The root gates each wave on health | That app is fixed |

Do not wait on `root` alone: its operation can succeed right after applying the last wave. Check all Applications.

Root's waves do hold later waves back until a child's internal waves finish. A child read raw `Healthy` for a whole 63s hook while the check read `Progressing`, and the next child was created in the second the hook finished ([argocd-wave-gating-1.txt](../evidence/runs/argocd-wave-gating-1.txt)). Details are in [Argo CD](../argocd.md#health-gating).

### Migrator hook will not finish

`plane-api-migrate-1` is a `Sync` hook at wave 2, with `backoffLimit: 3`, `activeDeadlineSeconds: 900`, and `BeforeHookCreation`. It is never `PreSync`, which would deadlock a fresh install because Postgres is applied in the Sync phase.

```bash
NS=plane-dev
kubectl -n "$NS" describe job plane-api-migrate-1 | tail -20
kubectl -n "$NS" logs job/plane-api-migrate-1 --tail=50
```

Without a deadline a bad image on the hook hangs, because `ImagePullBackOff` under `restartPolicy: OnFailure` deliberately does not count as Degraded. The 900 seconds is what ends that. Note that `wait_for_db` in Plane does not actually wait, so an early attempt can fail before Postgres is ready, and `backoffLimit` covers that.

The migrator succeeded on each environment's first boot on 2026-11-04 with no step by hand on the hook itself: dev applied 164 migrations in 83s after a 69s pull ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt)), and prod-sim's Job started at 21:47:17 with the image already there ([plane-prod-sim-firstboot-1.txt](../evidence/runs/plane-prod-sim-firstboot-1.txt)). Those boots were not a clean `make up`.

Deployments stay on the old image until the hook passes, so a failed migration does not on its own take the environment down. That held in the one run, on 2026-11-05 in dev, with a throwaway backend whose migrator exits 1. The Job failed `BackoffLimitExceeded` 58s after the publish, and over 67 samples no Deployment changed generation, image or pod, and the host answered 200 ([drill-failed-migrator-20261105T064940Z.log](../evidence/runs/drill-failed-migrator-20261105T064940Z.log)). That migrator changed nothing before it failed, so this does not cover one that fails partway through a schema change.

### OutOfSync that will not clear

| Resource | Cause | State |
|---|---|---|
| Secret `kps-grafana` | New random password per render | `ignoreDifferences` on `/data/admin-password`, in place |
| Deployment `kps-grafana` `checksum/secret` | Same render | `ignoreDifferences` in place. With 8 chart Applications hard-refreshed at once, Grafana stayed at generation 1 with one ReplicaSet ([argocd-render-load-1.txt](../evidence/runs/argocd-render-load-1.txt)) |
| Deployment pod-template annotations from the Infisical operator | The operator patches templates for auto-reload | Three-way diff ignores fields not in Git, and the annotation caused no sync loop. During `make rotate ENV=dev` on 2026-11-05 api, worker and beat each moved one generation and no further through the end of the watch at 07:40:17Z, and `plane-dev` stayed `Synced` with no operation for it ([SEC-6-20261105T072331Z-application-watch.txt](../evidence/runs/SEC-6-20261105T072331Z-application-watch.txt), [SEC-2-20261105T072331Z-watch.txt](../evidence/runs/SEC-2-20261105T072331Z-watch.txt)). An operator restart moved no generation ([infisical-operator-restart-1.txt](../evidence/runs/infisical-operator-restart-1.txt)). `make rotate ENV=prod-sim` read the same on the script's own 20s check, which is all prod-sim has ([rotate-prod-sim-20261105T073240Z.log](../evidence/runs/rotate-prod-sim-20261105T073240Z.log)) |

If a new one appears, read the diff from the UI at `http://argocd.localhost`, or compare the live object with `gitops/environments/`. Add `ignoreDifferences` in Git only when another controller legitimately owns the field. Otherwise self-heal is correctly telling you something is drifting.

### Auto-sync was left paused

Scripts save the `automated` block and restore it in a trap. That trap cannot run after `kill -9`, a crash, or a reboot. The script prints the exact command when a restore fails. A re-run of `make restore-clean` after a hard stop puts back any it finds (`argo_unpause_all` in `monitoring/ops/lib.sh`). Other scripts do not.

Check for a pause with the overview command above. `false` in the `AUTO` column means paused, and `<none>` is the normal state.

Restore each paused Application by hand. Root will not do it for you: root stayed `Synced` through a hard refresh with a child's `enabled: false` in place, and a dry run of applying the child's manifest kept the field ([dr-child-pause-1.txt](../evidence/runs/dr-child-pause-1.txt)). The `automated` block in Git is `prune: true, selfHeal: true` on every Application:

```bash
for app in root plane-dev; do   # each one that reads false
  kubectl -n argocd patch application "$app" --type json \
    -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":{"prune":true,"selfHeal":true}}]'
done
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,AUTO:.spec.syncPolicy.automated.enabled'
```

If a script terminated a sync before it stopped, auto-sync being back is not enough. See [End an operation](#end-an-operation).

### Argo CD itself is unwell

- The repo-server limit is 512 MiB, with concurrent renders capped at 2. Its peak was 247 MiB in the test with all 8 chart Applications hard-refreshed at once, with 0 errors ([argocd-render-load-1.txt](../evidence/runs/argocd-render-load-1.txt)), and the highest read on that pod was 269 MiB ([plane-dev-memory-1.txt](../evidence/runs/plane-dev-memory-1.txt)).
- The controller's limit is 1 GiB. Its peak was 731 MiB with Plane running ([plane-dev-memory-1.txt](../evidence/runs/plane-dev-memory-1.txt)). An OOM kill there stalls every sync. See [Memory pressure](memory-pressure.md).
- The controller has a liveness probe on purpose, with 5-minute slack, so a wedged controller restarts instead of hanging silently.
- Each Argo pod comes back under default-deny, and a new repo server fetches Git and charts on new connections ([argocd-restart-under-policy-1.txt](../evidence/runs/argocd-restart-under-policy-1.txt)).
- Multi-source Applications have an empty `.status.sync.revision`. The `REVISION` column in `make status` shows the Git commit from `.status.sync.revisions`.
- Argo CD has an open regression at manifest regeneration for Helm sources (#30215), masked by the Redis cache until then. Plane is not exposed to it, because Plane's manifests are rendered and committed. Platform charts are Helm sources. After the repo-server pod was replaced on 2026-11-04, a hard refresh of `traefik` and later of all 8 chart Applications ran on the new pod with no repo-server error ([argocd-restart-under-policy-1.txt](../evidence/runs/argocd-restart-under-policy-1.txt), [argocd-render-load-1.txt](../evidence/runs/argocd-render-load-1.txt)).

## Confirm

```bash
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase'
```

All of them should read `Synced`, `Healthy`, `Succeeded`, and automated sync should be on everywhere. `ArgoAppOutOfSync`, `ArgoAppDegraded` and `ArgoSyncFailed` should resolve.

With a refresh asked and no retry open, the sync starts within about a second of the annotation. With a retry open it waits for the next attempt, as under [a bad revision is retrying](#a-bad-revision-is-retrying). On 2026-11-05 in dev, each with no retry open: four images took 67s from the publish of a rollback to `Synced` and `Healthy`, and 64s for the promotion after it ([DEP-2-20261105T064032Z-timeline.txt](../evidence/runs/DEP-2-20261105T064032Z-timeline.txt)). The controller logged a refresh asked for by annotation at each run on record ([argocd-refresh-reasons-1.txt](../evidence/runs/argocd-refresh-reasons-1.txt)). The drills ask for it themselves, through `refresh_app` in `tests/drills/lib.sh`. `make promote` and `make rollback` do not, and for those the log does not say who did. So the wait with no refresh, and a change of one digest with no retry open, were not tested in Pass 1. Self-heal needs no publish: a replica change was put back in 3s ([GITOPS-4-20261105T073240Z.txt](../evidence/runs/GITOPS-4-20261105T073240Z.txt)).

## What not to do

| Do not | Why |
|---|---|
| Read `Running` as healthy progress | Check `retryCount` and `finishedAt` |
| Read a quiet `ArgoSyncFailed` as success | Its open-operation form needs 15m, and neither form sees a commit that cannot render or a chart child stuck with its operation closed |
| Delete an Application to reset it | It depends on the finalizer, and neither result is a clean reset. `alloy`, `kube-prometheus-stack`, `loki`, `metrics-server`, `monitoring-extras` and `traefik` have one, and **deleting them deletes their workloads**. The others, including `plane-*` and `infisical`, leave their objects orphaned |
| Sync by hand with `Replace` or `Force` on data StatefulSets | It can recreate them. Fix the cause |
| Create namespaces to get past an error | Terraform owns every namespace, and `CreateNamespace=false` is deliberate |
| Expect root to restore a paused child | It leaves `enabled: false` alone. Patch the child back |
| Leave self-heal paused after a drill | The environment silently stops following Git |
| Move the migrator to `PreSync` | It deadlocks a fresh install |
