# Argo CD

Argo CD deploys the workloads. Terraform owns namespaces, quotas and the rest that [the bootstrap chain](#the-bootstrap-chain) lists, and Argo CD itself. Wayline, the application Argo CD delivers, is
a customized Plane Community Edition v1.4.3 deployment, not an original product.

There are two Argo CDs, one per cluster. The kind cluster's reads `main` from a Git daemon on this Mac and deploys dev and prod-sim,
and every section from [Access](#access) to [Promotion](#promotion) is about it. Hosted production's reads branch `deploy/plane-prod`
on GitHub, which only CI writes, and [Hosted production](#hosted-production) covers it.

**Status of this page.** It describes the configuration in the code. Its hosted section adds what ran on hosted production on
2026-11-07, where `docs/evidence` holds it. The rest is what ran on local kind clusters, one at a time, on
2026-11-04 and 2026-11-05 with Argo CD v3.5.7: the first, the clean and cold installs' own, and three restored from backup. A measured statement links its file under
[`docs/evidence/runs/`](evidence/README.md). What Pass 1 did not test is stated where it comes up, among them a cluster-scoped refusal, a restore during a failing sync and a rollback of prod-sim.
The clean install inside `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` finished at about 08:10Z on 2026-11-05. Its evidence is [published](evidence/runs/clean-install-20261105T075041Z/summary.txt). Several results come from scratch
Applications on the real controller. They show how Argo CD behaves, not how a first boot from nothing would go.

## Access

| | |
|---|---|
| UI | `http://argocd.localhost`, user `admin`, once Traefik is up. Password: see [install.md](install.md#getting-credentials-without-printing-them). The route admits only the node network, so a pod gets 403 from Traefik ([routes-after-2.txt](evidence/runs/routes-after-2.txt)) |
| Before Traefik exists | `kubectl -n argocd port-forward svc/argocd-server 8080:80` |
| Server version | v3.5.7, chart `argo-cd` 10.11.7. One replica each of controller, repo server, server and Redis. No Dex or notifications. The chart has no switch for the ApplicationSet controller, so its Deployment exists at 0 replicas and pulls nothing |
| Git source | `git://plane-git/plane-platform.git`, branch `main` |
| CLI | **Not in `tools.lock`**, so `make setup` does not install it. If you install it, match the server version v3.5.7, then run `argocd login argocd.localhost --grpc-web --plaintext` |

Commands below use `kubectl` from a shell set up as in [install.md](install.md#shell-setup), and name the CLI form only
where it adds something.

## The bootstrap chain

Nothing in Git can start Argo CD, so the chain has a defined first step.

```mermaid
flowchart TD
  A["scripts/gitops-publish.sh: main to bare repo"] --> B["plane-git container serves git://"]
  C["Terraform: helm_release.argocd"] --> D["Terraform: helm_release.bootstrap"]
  D --> E["AppProjects and root Application"]
  B --> E
  E --> F["Root syncs gitops/applications and argocd-route"]
  F --> G["Child Applications, by wave"]
  G --> H["Traefik, monitoring, Infisical, operators"]
  H --> I["plane-dev, then plane-prod-sim"]
```

| Step | Owner | Notes |
|---|---|---|
| Bare repo at `.local/git/plane-platform.git` | `make gitops-publish`, the only writer | Publishes commits on `main`. Uncommitted work never reaches Argo CD |
| `plane-git` | Compose | Read-only `git daemon` on the `kind` network. GitHub runs CI, and this Argo CD never reads it. Hosted production's reads only GitHub |
| Argo CD release | Terraform | Values in `helm/values/argocd.yaml`. **A change there needs `terraform apply`, not a publish** |
| AppProjects, root Application | Terraform, through local chart `gitops/bootstrap/chart` | Not synced from Git, so a commit cannot edit what a project allows. A commit can still set `project: platform` on an Application. `policy/gitops.rego` refuses that for both Plane Applications, for anything that syncs `gitops/environments`, and for project `default`, in `make ci` and in CI. GitHub Free cannot make a failing check block a merge. See [`.github/workflows/README.md`](../.github/workflows/README.md) |
| Namespaces, quotas, LimitRanges, the CoreDNS rewrite | Terraform, through `infrastructure/terraform/modules/foundation` | No project may deploy a `Namespace`, `ResourceQuota` or `LimitRange`. See [terraform.md](terraform.md#what-terraform-owns) |
| Everything else | Argo CD | |

The root Application has two sources, so its status carries `status.sync.revisions` and `status.sync.revision` is empty.

The repo server fetches `git://plane-git` under default-deny. On 2026-11-04, from a new pod with empty caches, a hard
refresh ran `git fetch` and `helm pull` over new connections and logged no error
([argocd-restart-under-policy-1.txt](evidence/runs/argocd-restart-under-policy-1.txt)).

## Projects

Enforced by the AppProjects in `gitops/bootstrap/chart/templates/appprojects.yaml`.

| Project | Destinations | Source repos | Cluster-scoped | Denied in namespaces |
|---|---|---|---|---|
| `platform` | All namespaces | The Git remote and six chart repos | All except `Namespace` | `ResourceQuota`, `LimitRange` |
| `plane-dev` | `plane-dev` only | The Git remote only | None | `ResourceQuota`, `LimitRange`, `NetworkPolicy` |
| `plane-prod-sim` | `plane-prod-sim` only | The Git remote only | None | `ResourceQuota`, `LimitRange`, `NetworkPolicy` |

**Why NetworkPolicies are in `platform`.** A Plane Application cannot change the rules that contain it. The operators
are in `platform` too, because their charts render CRDs and ClusterRoles.

**A project boundary is not a cluster boundary.** Namespace separation is not equivalent to independent production clusters.
Dev and prod-sim share an API server, a controller and a node. See [environments.md](environments.md).

The refusal of a NetworkPolicy was measured on 2026-11-04, with a throwaway Application in project `plane-dev`:
`resource networking.k8s.io:NetworkPolicy is not permitted in project plane-dev`
([h16-throwaway-1.txt](evidence/runs/h16-throwaway-1.txt)). The table's "None" for cluster-scoped resources is read from the AppProject. A refusal of one was not tested in Pass 1.

## Root Application and waves

`root` syncs `gitops/applications/` and `gitops/bootstrap/argocd-route/`. Each file in the first is one child.

| Wave | Application | Project | Namespace | Source | Finalizer |
|---:|---|---|---|---|---|
| -10 | `network-policies` | platform | several | `gitops/platform/network-policies` | No |
| -10 | `backup-storage` | platform | several | `gitops/platform/backup-storage` | No |
| -9 | `traefik` | platform | `traefik` | chart 42.3.0 | Yes |
| -8 | `metrics-server` | platform | `kube-system` | chart 3.14.0 | Yes |
| -8 | IngressRoute `argocd-server` and Middleware `node-network-only` (not Applications) | platform | `argocd` | `gitops/bootstrap/argocd-route` | |
| -7 | `kube-prometheus-stack` | platform | `monitoring` | chart 92.18.0 | Yes |
| -6 | `loki` | platform | `monitoring` | chart 20.4.1 | Yes |
| -6 | `alloy` | platform | `monitoring` | chart 1.15.0 | Yes |
| -5 | `monitoring-extras` | platform | `monitoring` | `monitoring/manifests` | Yes |
| -4 | `infisical` | platform | `infisical` | chart `infisical-standalone` 1.12.0, plus `infisical/manifests` | No |
| -3 | `infisical-operator-dev` | platform | `plane-dev` | chart `secrets-operator` 0.11.16 | No |
| -3 | `infisical-operator-prod-sim` | platform | `plane-prod-sim` | chart `secrets-operator` 0.11.16 | No |
| -1 | `plane-dev` | plane-dev | `plane-dev` | `gitops/environments/dev` | No |
| 0 | `plane-prod-sim` | plane-prod-sim | `plane-prod-sim` | `gitops/environments/prod-sim` | No |

**What the finalizer means.** With `resources-finalizer.argocd.argoproj.io`, removing the Application deletes what it deployed.
That is fine for replaceable services. Without it, the objects are orphaned. Plane, Infisical, the operators (deleting
them would delete the CRDs, and so every Infisical CR), NetworkPolicies and backup storage deliberately have none. `root`
has none either, so removing it does not cascade.

**Prune.** Every Application has `prune: true`. Deleting a file under `gitops/applications/` removes that Application.
What happens to its workloads depends on the finalizer above.

To start a child before root's waves reach it, see
[Argo sync stuck](runbooks/argo-sync-stuck.md#start-a-child-ahead-of-its-wave).

### Health gating

Argo CD removed the built-in health check for `Application` in 1.8. Without one, a child reports no health and the root's
waves pass straight through. `helm/values/argocd.yaml` adds these Lua checks through `resource.customizations.health.*`:

| Kind | Healthy when | Degraded when | Otherwise |
|---|---|---|---|
| `argoproj.io/Application` | `status.health.status` is Healthy, no `.operation` is open, and `status.sync.status` is Synced | That field is Degraded | Copies that field, or Progressing |
| `monitoring.coreos.com/Prometheus` | Condition `Available` is True, whatever `Reconciled` says | `Available` is not True, and either `Reconciled` is False or its reason is anything but `NoPodReady` and `SomePodsNotReady` | Progressing, which includes no `Available` condition yet |
| `InfisicalStaticSecret` | `observedGeneration` matches and `status.error` is not true | `observedGeneration` matches and `status.error` is true | Progressing |
| `InfisicalAuth`, `InfisicalConnection` | Condition `IsReady` is True for this generation | Condition `IsReady` is False for this generation | Progressing |

A non-hook task waits on anything except Healthy and Degraded. So Missing and Progressing hold the wave. Degraded fails the
sync, and retry reruns it.

**What this gates, measured.** On 2026-11-04, with scratch Applications on the real controller, a child read raw Healthy
for its whole 63s hook while the check read Progressing, and the next child was created in the second the hook finished.
That held on a fresh install and on a resync ([argocd-wave-gating-1.txt](evidence/runs/argocd-wave-gating-1.txt)). The real
first boot agrees: `plane-dev`'s operation closed at 21:46:40Z ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt))
and `plane-prod-sim`'s first sync began at 21:46:41Z
([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)).

The checks ran on Argo CD's own Lua inside the real server pod: 36 behaviour cases and two negative controls on the
Application and Infisical checks ([argocd-lua-runtime-1.txt](evidence/runs/argocd-lua-runtime-1.txt)), 13 cases on the Prometheus
check ([h43-lua-runtime-1.txt](evidence/runs/h43-lua-runtime-1.txt)), and the 16 live Infisical CRs plus one failing scratch CR
([argocd-lua-infisical-live-1.txt](evidence/runs/argocd-lua-infisical-live-1.txt)).

What the gate costs and misses:

- **A child that stays OutOfSync holds every later wave.** `make up` needs all 14 Synced anyway, so this changes how a
  failure looks, not what counts as success.
- **The root looks at a child only when its wave comes round.** A crash-looping child that reads Healthy at that moment lets
  the later waves through, and the root does not go back. This happened on the first real run, with Grafana's sidecars being
  killed for memory ([bootstrap-timeline-1.txt](evidence/runs/bootstrap-timeline-1.txt),
  [monitoring-grafana-before-1.txt](evidence/runs/monitoring-grafana-before-1.txt)).
- **A Prometheus with no ready pod reads Progressing, not Degraded.** Before the override, a root sync open during a Prometheus start
  failed and went into backoff: asked for 2s after the pod was deleted, it failed at +12s and next ran at +72s. After it, the root waits with no retry
  ([h43-repro-before-1.txt](evidence/runs/h43-repro-before-1.txt), [h43-repro-after-1.txt](evidence/runs/h43-repro-after-1.txt)). So a fix
  to `gitops/applications/kube-prometheus-stack.yaml` needs root's operation ended by hand, as under
  [Retry behaviour](#retry-behaviour).

Peak VM memory on those first syncs, one environment after the other, on 2026-11-04: 8.62 GiB for `plane-dev` and 9.23 GiB
for `plane-prod-sim`, of 13.63 GiB, with the owner's unrelated containers and other agents' work included
([plane-prod-sim-memory-history-1.txt](evidence/runs/plane-prod-sim-memory-history-1.txt)). Prod-sim's images were already on the
node. Neither was a clean `make up`.

**Do not wait on `root` alone.** Root's operation finishes right after it applies wave 0, without waiting for
`plane-prod-sim` to become healthy. Measured on the first boot: Prometheus shows root's operation open until about 21:46, while
`plane-prod-sim`'s opened at 21:47 and its last pod turned Ready at 21:49:24
([h16-op-durations-1.txt](evidence/runs/h16-op-durations-1.txt), [plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt)).
Read the child Applications:

```bash
kubectl -n argocd get applications
make status
```

The `REVISION` column in `make status` shows the Git commit, taken from `.status.sync.revisions` for a multi-source Application.

## Inside a Plane Application

The waves are in the rendered manifests, from `helm/plane/components/hardening`, and are the same in both environments.

| Wave | Resources | Gate before moving on |
|---:|---|---|
| -3 | ServiceAccounts `plane`, `plane-infisical-auth`; `InfisicalConnection` | Lua check |
| -2 | `InfisicalAuth` | Lua check. Needs Secret `plane-infisical-identity` from `scripts/infisical-bootstrap.sh` |
| -1 | Six `InfisicalStaticSecret` | Lua check. The operator has written the Secrets |
| 0 | ConfigMaps, Services | Exists |
| 1 | StatefulSets: postgres, valkey, rabbitmq, silo | Ready |
| 2 | Migrator Job `plane-api-migrate-1`, Sync hook | Job complete |
| 3 | Deployments: api, worker, beat, web, admin, space, live | Rollout complete |
| 4 | `plane-ingress`, Middlewares | Exists |

The order held on `plane-dev`'s first boot on 2026-11-04, at commit `e95a6f8`: data pods at 21:29:03Z, 164 migrations from 21:33:49Z
to 21:35:12Z, Deployments at 21:35:15Z, operation closed at 21:46:40Z
([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)). That was a first boot on a running platform, not `make up`
from nothing, which is row INST-1. The clean install of 2026-11-05 finished at about 08:10Z: one `make up` on a fresh clone took 955s, and all 14 Applications read `Synced` and `Healthy`. It kept the local registry and the pull-through caches, so it does not meet that row's definition of clean ([summary](evidence/runs/clean-install-20261105T075041Z/summary.txt)). The cold install at `e602dad` is INST-1a to INST-1c. INST-1, in one go on the fixed code, stays NOT RUN.

While `InfisicalAuth` is unready the sync fails and retries. It does not wait. The identity Secret was published at 21:25:44Z,
and the next attempt, #5 after backoff, moved on at 21:28:54Z
([infisical-unready-sync-1.txt](evidence/runs/infisical-unready-sync-1.txt)).

**A first boot's wave 3 takes minutes.** The kubelet pulls one image at a time, so a Deployment also waits for every pull
queued ahead of it. On `plane-dev`'s first boot, through a cold mirror, four new images took 175s, 216s, 52s and 5s in turn, and
the last pod was Ready 448s in ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt),
[plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt)). The deadline was 360s then, so web, admin and space missed
it and the sync held until a retry. That event was read live and is not in a saved file. The nearest saved trace is `ArgoAppDegraded` pending on `plane-dev` and `root` from 21:41:45Z to 21:43:00Z ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). It is 600s now, since `4b33f75`. That value has not been through a cold first boot.

### Sync hook: the migrator

| Setting | Value | Why |
|---|---|---|
| `argocd.argoproj.io/hook` | `Sync` at wave 2 | **Never `PreSync`.** Postgres is applied in the Sync phase and `wait_for_db` does not wait, so a PreSync migrator exhausts its retries against no database and stops a fresh install |
| `hook-delete-policy` | `BeforeHookCreation` | The Job's name is constant and its template immutable. Each sync deletes and recreates it |
| `ttlSecondsAfterFinished` | Not set | Argo CD can wait forever on a hook Kubernetes already deleted |
| `activeDeadlineSeconds` | 900 | With `restartPolicy: OnFailure`, a bad image gives `ImagePullBackOff` and the Job never fails on its own. The deadline makes it fail |
| `backoffLimit` | 3 | From the chart |

Consequences of this design:

- **The migrator runs on every sync that reaches wave 2.** A re-run with nothing pending is
  harmless: the re-run at 21:46:29Z on `plane-dev` added no row to the 164 of its first run
  ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)), and a later one took 9s
  ([plane-prod-sim-firstboot-1.txt](evidence/runs/plane-prod-sim-firstboot-1.txt)). The one self-heal timed below opened and closed its operation within 07:32:41Z, too short for that
  ([SEC-6-20261105T072331Z-application-watch.txt](evidence/runs/SEC-6-20261105T072331Z-application-watch.txt)). So it did not wait on the hook. That is read from the times, on one replica change.
- **A failed migrator stops the sync before wave 3,** so no Deployment is touched and the old version keeps running. Measured once, on
  2026-11-05 in dev, with a throwaway backend whose migrator exits 1 (`tests/drills/failed-migrator.sh`). The Job failed `BackoffLimitExceeded` 58s after the
  publish, the sync retried, and over 67 samples the Deployments' generations, images and pods equalled the start, and the host answered 200
  ([drill-failed-migrator-20261105T064940Z.log](evidence/runs/drill-failed-migrator-20261105T064940Z.log)). That migrator changed nothing before it failed, so one that fails partway through a schema
  change has not been tried.
- **App health can stay Healthy while the migrator fails,** because aggregate health skips hooks. A failing hook on a scratch
  Application read phase `Running`, health `Healthy` ([argocd-terminate-1.txt](evidence/runs/argocd-terminate-1.txt)), and `plane-dev` read
  `OutOfSync`, `Healthy`, `Running` in that drill. Read the operation phase and message, not only health.

### Other sync options

| Option | Where | Why |
|---|---|---|
| `CreateNamespace=false` | All | Terraform creates every namespace |
| `PruneLast=true` | `plane-dev`, `plane-prod-sim` | Removals apply only after the new state is healthy |
| `ServerSideApply=true`, `RespectIgnoreDifferences=true` | `kube-prometheus-stack` | `crd-prometheuses.yaml` is far over client-side apply's annotation limit. Grafana's password is regenerated on each render, so it is ignored |
| `SkipDryRunOnMissingResource=true` | Middleware `node-network-only` and IngressRoute `argocd-server` | The root's dry run happens before Traefik's CRD exists |

## Self-heal

Every Application has `automated: {prune: true, selfHeal: true}`, including prod-sim. **The prod-sim control point is the
Git change, not the sync button.**

A live change that differs from Git is reverted. The contract says this takes seconds. On 2026-11-05 at 07:32:40Z in dev, `kubectl scale deployment/plane-admin-wl --replicas=2` was back at 1 replica 3s later, with nobody running a second command,
and `plane-dev` read `Synced` and `Healthy` before and after ([GITOPS-4-20261105T073240Z.txt](evidence/runs/GITOPS-4-20261105T073240Z.txt)). Two earlier tries changed nothing: one was refused by the session's permission system
([GITOPS-4-20261105T062155Z.txt](evidence/runs/GITOPS-4-20261105T062155Z.txt)), and one could not call `kubectl` ([GITOPS-4-20261105T072541Z.txt](evidence/runs/GITOPS-4-20261105T072541Z.txt)). A NetworkPolicy edit was back about 6s after its Application's self-heal was switched back on
([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)). That is one replica change on one Deployment in dev, and it says nothing about prod-sim or other fields. A field Git does not set stays, as the table below says.

Git polling has no webhook in Pass 1. A published commit is seen at the controller's next look. The chart's default is 120 seconds plus up to 60
seconds of jitter, and looks were measured 120 to 289s apart, median 193s, because a resync is skipped when the previous look landed later
in its jitter ([alert-text-figures-1.txt](evidence/runs/alert-text-figures-1.txt)). To ask immediately:

```bash
kubectl -n argocd annotate application plane-dev argocd.argoproj.io/refresh=normal --overwrite
```

The controller removes the annotation once it has compared, which took 18s after a hard refresh in one test
([argocd-restart-under-policy-1.txt](evidence/runs/argocd-restart-under-policy-1.txt)). In each promotion and the rollback of 2026-11-05 the controller logged a refresh asked for by annotation,
and the sync began within a second of it ([argocd-refresh-reasons-1.txt](evidence/runs/argocd-refresh-reasons-1.txt)). The drills ask for it themselves, through `refresh_app` in `tests/drills/lib.sh`. `make promote` and `make rollback` do not, and for those the log does not say who did. So after either, expect to wait for a look, or ask. The times below include a refresh for this reason. A refresh does not hurry a revert in a retry loop: the controller read each drill's revert at once, and the sync waited for the next attempt, 54s and 226s after the publish ([DEP-1-20261105T062323Z-timeline.txt](evidence/runs/DEP-1-20261105T062323Z-timeline.txt), [DEP-3-20261105T064517Z-timeline.txt](evidence/runs/DEP-3-20261105T064517Z-timeline.txt)).

Two things that look like drift and should not fight:

| Writer | What it changes | Expected |
|---|---|---|
| Infisical operator | Pod template annotations, through `auto-reload` | Argo's 3-way diff ignores fields it does not manage. No sync loop after an Infisical secret change: during `make rotate ENV=dev` on 2026-11-05 the operator restarted api, worker and beat, each moved one generation and no further through the end of the watch at 07:40:17Z, `plane-dev` stayed `Synced`, read `Progressing` for 41s while they rolled, and opened no operation for it ([SEC-6-20261105T072331Z-application-watch.txt](evidence/runs/SEC-6-20261105T072331Z-application-watch.txt), [SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt)). Earlier, restarting the operator moved no generation ([infisical-operator-restart-1.txt](evidence/runs/infisical-operator-restart-1.txt)). `make rotate ENV=prod-sim` read the same on the script's own 20s check, which is all prod-sim has ([rotate-prod-sim-20261105T073240Z.log](evidence/runs/rotate-prod-sim-20261105T073240Z.log)) |
| Grafana chart | `checksum/secret` and the admin password differ per render, and nothing else ([kps-render-diff-1.txt](evidence/runs/kps-render-diff-1.txt)) | The `kube-prometheus-stack` Application ignores both. With all 8 chart Applications hard-refreshed at once, Grafana's Deployment stayed at generation 1 with one ReplicaSet ([argocd-render-load-1.txt](evidence/runs/argocd-render-load-1.txt)) |

## Retry behaviour

**A failing sync shows `Running`, not `Failed`.** This is the one thing to remember on this page.

Every Application has `retry.limit: -1`. Argo CD's controller sets a failed sync back to phase `Running`, with a retry
scheduled, indefinitely. So you will not see a `Failed` phase. Measured on 2026-11-04 on a throwaway Application refused by its
project: phase `Running`, `retryCount` 7, `finishedAt` set, `status.conditions` empty, and the message
`one or more synchronization tasks are not valid: resource networking.k8s.io:NetworkPolicy is not permitted in project plane-dev. Retrying attempt #7 at 11:22PM.`
([h16-throwaway-1.txt](evidence/runs/h16-throwaway-1.txt)).

| Setting | Value | Why |
|---|---|---|
| `limit` | -1, no limit | Automated sync never reattempts a failed commit. A child is often briefly Degraded on first boot, so a finite limit would strand it until the next commit |
| `backoff` | 30s, factor 2, cap 5m | The waits measured after each failed attempt were 61s or 62s, then 120s, then 242s, so the first wait read about a minute and not the 30s the setting reads as ([DEP-1-20261105T062323Z-timeline.txt](evidence/runs/DEP-1-20261105T062323Z-timeline.txt), [DEP-3-20261105T064517Z-timeline.txt](evidence/runs/DEP-3-20261105T064517Z-timeline.txt)). Later waits, up to the cap, have not been read on a real Plane sync |
| `refresh` | `true` on children and on `root` | A retry picks up the newest commit, so a revert lands while the sync loops. Without it the retry stays pinned to the bad revision |

On the first boot, root's operation began at the first published commit (`b98fa47`) and reached `4a49a9c` on a retry, with no new
operation ([bootstrap-up-terraform-1.txt](evidence/runs/bootstrap-up-terraform-1.txt),
[argocd-root-terminate-1.txt](evidence/runs/argocd-root-terminate-1.txt)). That shows the revision moving. A revert landed the same way during `plane-dev`'s retry loop in both
drills of 2026-11-05, with no step by hand ([DEP-1-20261105T062323Z-timeline.txt](evidence/runs/DEP-1-20261105T062323Z-timeline.txt), [DEP-3-20261105T064517Z-timeline.txt](evidence/runs/DEP-3-20261105T064517Z-timeline.txt)). Nobody has watched a fix to an
Application manifest land this way.

To see the true state:

```bash
kubectl -n argocd get application plane-dev -o json \
  | jq '{sync: .status.sync.status, health: .status.health.status,
         phase: .status.operationState.phase, retries: .status.operationState.retryCount,
         message: .status.operationState.message}'
```

**Stuck child, stuck root.** A retry happens only after an attempt fails. A root waiting on a child that stays `Progressing` never
fails, so it stays in `Running` with no retry. That hold was seen for the 17 seconds a restarting Prometheus read `Progressing`: root
waited, then succeeded, with `retryCount` empty ([h43-repro-after-1.txt](evidence/runs/h43-repro-after-1.txt)). That such a root does not
pick up a new commit is read from the code, as `gitops/bootstrap/chart/templates/root-application.yaml` and
[`infrastructure/terraform/README.md`](../infrastructure/terraform/README.md) say, and has not been measured. In order, fix the child's
cause, or end the operation:

```bash
# With the CLI: argocd app terminate-op <app>
# Without it. The chart's CRD has no status subresource, so this patch reaches status.
kubectl -n argocd patch application root --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
```

The patch works. Measured on v3.5.7 while a hook ran, during retry backoff, and on the real root: the phase turns `Failed` within
2 seconds and a running hook is deleted ([argocd-terminate-1.txt](evidence/runs/argocd-terminate-1.txt),
[argocd-root-terminate-1.txt](evidence/runs/argocd-root-terminate-1.txt)). A terminated revision does not start again by itself. What it
takes to start again is in [Argo sync stuck](runbooks/argo-sync-stuck.md#end-an-operation).

**Scripts that wait for idle.** `argo_wait_idle` in `monitoring/ops/lib.sh` waits while the phase is `Running`. After 180 seconds it
sends that same patch, repeats it if the controller overwrites it, and gives up at 300 seconds. So `make restore` and
`make test-alert` no longer refuse an Application in a retry loop, and a restore after a bad promotion is exactly that case.
`argo_resume` then warns that Argo CD will not retry that revision. This has run against a stub only
([test_lib-stub-1.txt](evidence/runs/test_lib-stub-1.txt)). The real restores of dev and prod-sim on 2026-11-05 did not need it, because no sync was failing. A restore during a failing sync was not tested in Pass 1.

## Rollback

**Rollback is a Git revert.** `argocd app rollback` needs automated sync off, and leaves Git disagreeing with the cluster.

```bash
make rollback ENV=dev
make rollback ENV=prod-sim CONFIRM=yes
```

`scripts/rollback.sh`:

1. Refuses unless you are on `main` with a clean overlay and rendered file, and no merge, cherry-pick or revert is under way.
2. For dev, stops if `main` holds a prod-sim image change Argo CD has not read, and names it, because a publish is all of `main`. `OVERRIDE_DEV_CHECK="<reason>"` sends it along, which is logged, and that publish still asks plane-dev and takes the dump.
3. Looks for a revert of this environment's promotion that is on `main` and was never published. If it finds one, it publishes that and reverts nothing else, unless a promotion newer than that revert waits too. That one is what this run reverts.
4. Otherwise finds the newest promotion of that environment not already reverted. It matches the `Promote-Env:` trailer or the `promote(<env>):` subject, since a squash merge may drop the trailer. If that promotion never reached Argo CD, and `main` holds more that moves prod-sim and has not gone out, it stops and names them, because the publish below would send them with no check.
5. For prod-sim, asks unless `CONFIRM=yes`, then takes one best-effort dump, limited to `ROLLBACK_DUMP_TIMEOUT` seconds (300 by default). A failure there does not stop the rollback. `SKIP_BACKUP=yes` leaves the dump out.
6. Runs `git revert`, re-renders, and commits both as one commit, holding the lock in `scripts/lib/commit-lock.sh` from before the revert until the commit. A conflict only in the rendered file is replaced by rendering. A conflict anywhere else stops it with nothing changed, and undoes only the revert it started. If the revert would change nothing, it reports the promotion as already undone and still publishes `main`.
7. Publishes. For prod-sim that is with `SKIP_BACKUP=yes` and `SKIP_DEV_CHECK`, so the publish takes no dump and asks the cluster nothing, because the cluster may be what is broken. For dev, a publish that moves no prod-sim image asks the cluster nothing anyway.

**Things to know before running it:**

| Point | Detail |
|---|---|
| Images roll back, the schema does not | Migrations are forward only. Old code starts against the newer schema with no warning. The way back for data is the dump taken before a prod-sim promotion, through `make restore` |
| **Do not use `BACKUP=latest` for that** | The rollback's own dump holds the newer schema, so `latest` may name it. A prod-sim rollback prints the dump to use, the newest from before the promotion first went out, which `gitops-publish` records in `.local/publishes.log`. With no record it goes by the commit and says so. If the promotion never reached Argo CD, it says there is nothing to restore. See [Failed deploy](runbooks/failed-deploy-rollback.md#if-a-migration-ran-and-rolling-back-the-image-is-not-enough) |
| A failed publish is safe to retry | The revert stays on `main`. Run `make rollback` again: it publishes that revert and reverts nothing else |
| A rollback publishes all of `main` | A rollback of dev stops on a prod-sim image change that waits there (step 2), and withdrawing a prod-sim promotion that never reached Argo CD stops on one under it (step 4). Anything else a rollback of prod-sim carries goes out under the same skip, with its digests logged in `.local/evidence-raw/promotion-overrides.log` |
| A revert during a retry loop | Children have `retry.refresh: true`, and the retry picks it up. Measured in both drills below, and you wait for the backoff |

`make rollback ENV=dev` ran on the real cluster on 2026-11-05: it reverted `1fc9fbe` as `91ef477` and the six Deployments on those images went back to their earlier digests, with prod-sim's render
unmoved and `smoke.py --mode verify --job-probe` passing on the rolled-back images ([DEP-2-20261105T064032Z-rollback.txt](evidence/runs/DEP-2-20261105T064032Z-rollback.txt)). A rollback of prod-sim has not run on the real cluster. Its logic has, against a stub `kubectl`: `rollback-rerun-after-failed-publish`,
`rollback-prod-sim-with-broken-backup` and the other scenarios in
[ci-2-20261105T055459Z-make-ci.log](evidence/ci/ci-2-20261105T055459Z-make-ci.log).

`make drill-failed-deploy` runs `tests/drills/failed-deploy-rollback.sh`, which exercises this path in dev. It promotes an
unpullable digest for `web`, checks that the old pods keep serving, and reverts. It needs no pause, because the bad state is the
desired state in Git, so Argo CD has nothing to undo. Preflight stops it before anything moves if a prod-sim change waits on `main`, or if Prometheus does not answer. It keeps every pending and firing alert in
`<evidence>-alerts.tsv`, and stage 6 prints them with what the sink received.

It ran once, on 2026-11-05 in dev, and ended RESULT PASS. The old pod stayed Ready and all 61 samples through Traefik read 200 during the failed rollout. The Application first read Degraded 10m24s in, and the revert was published 8s later.
The next attempt took the newest commit, the old image was back 11m48s in, and `plane-dev` read `Synced` and `Healthy` 82s after the revert. Nothing fired: `ArgoSyncFailed` stayed pending for 13m45s against its 15 minutes
([drill-failed-deploy-20261105T062343Z.log](evidence/runs/drill-failed-deploy-20261105T062343Z.log), [its alerts](evidence/runs/drill-failed-deploy-20261105T062343Z-alerts.tsv)). See
[Argo sync stuck](runbooks/argo-sync-stuck.md#what-fires-for-which-failure). That is one bad image on one Deployment, in dev. An image that pulls and then crashes has not been drilled.

Time from `make rollback` to the environment reading `Synced` and `Healthy`: 67s, for `make rollback ENV=dev` moving four images with no retry open. It published at 06:40:59Z, and the Application read so at 06:42:06Z
([DEP-2-20261105T064032Z-timeline.txt](evidence/runs/DEP-2-20261105T064032Z-timeline.txt)). A refresh was asked for, so this does not include waiting for Argo CD's own look. It is one run, in dev.

`progressDeadlineSeconds` is 600 on every rendered Deployment, which decides when a bad rollout is declared failed. It stays
above the longest startup budget (api, worker and beat, 300 seconds), because image pull and scheduling count against
the same deadline, and first-boot pulls measured 448s. The drill's rollout read `ProgressDeadlineExceeded` about 10 minutes after it started. Stage 4 of the drill can wait the deadline plus 120 seconds, so up to 12 minutes.

web, admin, space, live and api keep serving for a 5-second `preStop` sleep after SIGTERM, so that Traefik stops sending to a pod
before it goes. How long Traefik takes to react has not been measured.

What ran, on 2026-11-04 in plane-dev on upstream images: each of the 5 routes sampled at 10 Hz through Traefik while all seven
Deployments rolled, with a failure meaning no answer in 2 seconds or a 5xx. One rollout before the sleep failed 10 of 2,757 samples
([plane-dev-rollout-availability-1.txt](evidence/runs/plane-dev-rollout-availability-1.txt)). Two rollouts after it failed 0 of 5,902
([plane-dev-rollout-availability-2.txt](evidence/runs/plane-dev-rollout-availability-2.txt)). That counts HTTP answers only. On branded images the 10 Hz test has not been repeated. A slower watcher ran across the
rollback and the promotion forward of 2026-11-05 in dev, which rolled six Deployments twice: 239 signed-in requests at about one a second and 120 cycles of four pages, all 200
([DEP-2-20261105T064032Z-timeline.txt](evidence/runs/DEP-2-20261105T064032Z-timeline.txt)). An open WebSocket does not ride through: replacing the `live` pod closed it with code 4205, the
client reconnected 21.2 seconds after the delete, and an edit still inside the debounce was not on the server afterwards
([plane-dev-live-restart-1.txt](evidence/runs/plane-dev-live-restart-1.txt)). That client does not send an edit again. A real browser tab did, in one restart on 2026-11-05, and the text survived a reload ([RT-2b-RT-3-20261105T073208Z.txt](evidence/runs/RT-2b-RT-3-20261105T073208Z.txt)).

**Rolling back a platform change.** Revert the commit and publish:

```bash
git revert <commit>
make render              # only if the revert touched helm/plane
git status --short       # commit anything render changed
make gitops-publish
```

`gitops-publish` refuses a non-fast-forward push on purpose, because a rewrite would leave Argo CD following history with no
record of it. Reverts are the way back. A change owned by Terraform needs `terraform apply` after the revert. See
[terraform.md](terraform.md#what-reaches-the-cluster-how).

## Pausing automation for drills

Drills that inject failure behind Git's back must pause self-heal first, or Argo CD reverts them in seconds.

**Root does not undo `automated.enabled: false` on a child.** Measured on 2026-11-04 on `metrics-server`: root stayed Synced through a
hard refresh and the child's patch held for a minute, and a server dry run of applying the child's manifest kept the field
([dr-child-pause-1.txt](evidence/runs/dr-child-pause-1.txt)). So a child can be paused alone.

`monitoring/ops/lib.sh` does this for `make restore` and `make test-alert`. `argo_pause` pauses `root` first and resumes it last.
`argo_pause_child` pauses one Application and leaves root alone, for when root itself is waiting on what the restore leads to. Each saves the `automated` block without its `enabled` field, sets `enabled: false`, and waits for any running operation to
end, and `argo_pause_child` then checks that the patch held. `argo_resume` puts the saved blocks back in reverse order, from an exit trap, so root sees
no drift. The two in-place Infisical restores went through this: the server stayed at zero while paused, and auto-sync came back
([dr-inplace-restore-2.txt](evidence/runs/dr-inplace-restore-2.txt),
[restore-infisical-20261105T001834Z.json](evidence/runs/restore-infisical-20261105T001834Z.json)). So did the in-place restores of dev and prod-sim on 2026-11-05, which printed auto-sync restored on the Application and then on `root`
([BKP-2-20261105T074322Z.txt](evidence/runs/BKP-2-20261105T074322Z.txt), [SEC-3-BKP-3-20261105T073240Z.txt](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt)). So did `make test-alert` in each environment on 2026-11-05, with `root` and that environment's Application paused from before the injection until it was over, and both blocks back at the end
([MON-1-20261105T055029Z.txt](evidence/runs/MON-1-20261105T055029Z.txt), [MON-2-20261105T072541Z-run.txt](evidence/runs/MON-2-20261105T072541Z-run.txt)).

By hand:

```bash
for app in root plane-dev; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
done

# ... inject the failure, observe ...

for app in plane-dev root; do
  kubectl -n argocd patch application "$app" --type json \
    -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":{"prune":true,"selfHeal":true}}]'
done
```

A sync already in flight keeps going after the pause, and retries can keep re-applying. Check the operation phase before
trusting an injection.

| Drill or script | Pauses? | Why |
|---|---|---|
| `make restore ENV=dev` or `ENV=prod-sim` | Root and child | It scales apps to zero |
| `make restore ENV=infisical` | That Application only | It stops the server. Root may be waiting on what the restore leads to |
| `make test-alert` | Root and child | It injects a failure behind Git's back |
| `make drill-failed-deploy` | No | The change goes through Git |
| `tests/drills/failed-migrator.sh` | No | The change goes through Git |
| `make drill-pod-restart` | No | Deleting a pod changes no spec |

## Diffing

Different questions need different diffs.

| Question | Command |
|---|---|
| What will this overlay change produce? | `make render && git diff gitops/environments/` |
| What is committed but not published? | See below |
| What differs between the two environments? | `diff gitops/environments/dev/manifests.yaml gitops/environments/prod-sim/manifests.yaml` |
| What does Argo CD consider out of sync? | The UI's Diff tab, or `argocd app diff plane-dev` with the CLI |
| Which resources are out of sync? | See below |
| How does the live cluster differ from the render? | See below |

```bash
# Committed on main, not yet visible to Argo CD
git diff "$(git --git-dir=.local/git/plane-platform.git rev-parse main)" main -- gitops helm

# Out-of-sync resources in one Application. A hook has no sync status, so without the first test it prints as null
kubectl -n argocd get application plane-dev -o json \
  | jq -r '.status.resources[] | select(.hook != true and .status != "Synced") | "\(.kind)/\(.name) \(.status)"'

# Live against render, by server-side dry run, leaving out what differs even on a synced environment
kubectl diff -n plane-dev -f gitops/environments/dev/manifests.yaml \
  | grep -E '^[-+] ' | grep -v -E 'tracking-id|generation:'
```

Read the filter as well as the result. On 2026-11-05 on a `plane-dev` reading Synced and Healthy, the plain `kubectl diff` exited 1 with
453 lines, and all 37 objects differed. Each differed by Argo CD's `argocd.argoproj.io/tracking-id` annotation, which the render does not
carry, and the seven Deployments also by a `generation` one higher, in the dry run only. Nothing else differed, so the filtered form printed
nothing ([argocd-kubectl-diff-1.txt](evidence/runs/argocd-kubectl-diff-1.txt)). Argo's diff is the one that decides sync status.

## Promotion

Image digests for an environment live in `helm/plane/overlays/<env>/kustomization.yaml` under `images:`. For dev and
prod-sim only `scripts/promote.sh` writes those lines. It edits them with `kustomize edit set image`, re-renders, commits with
`Promote-Env:` and `Promote-Image:` trailers, and publishes. Hosted production's, in `helm/plane/overlays/prod`, change only through
[a signed set and a pull request](#exact-digest-image-sets).

```mermaid
flowchart LR
  A["make images or GHCR build"] --> B["Digest in dev overlay"]
  B --> C["Render, commit, publish"]
  C --> D["Argo CD syncs plane-dev"]
  D --> E["make test-e2e ENV=dev"]
  E --> F["Promote the same digest to prod-sim"]
  F --> G["Refuse a digest dev never recorded or does not run, dump Postgres"]
  G --> H["Render, commit, publish"]
  H --> I["Argo CD syncs plane-prod-sim"]
```

**Images.** Both overlays name `localhost:5001/wayline/{web,admin,space,backend}` by digest: dev since `4f622e3` and prod-sim since `0af8956`, both on 2026-11-05.
Their `live` image and the data services stay upstream. Prod-sim's overlay names the final Pass 1 images, built on this Mac from `84b63d9` (web `3d7575a1`, admin `ce7adc37`, space `5f0119ff`, backend `8c04bd18`) and promoted by `9c8e098`.
Dev ran those too, promoted by `1fc9fbe` and, after its drills, `29316f2`. Since `e499212` on 2026-11-07, dev's overlay names the four that `images.yml` built on GitHub as plain linux/amd64 manifests
(web `23890443`, admin `c8edb3cb`, space `a0cf0e9a`, backend `9df47b8a`), copied to the local registry with their digests. Dev ran them under Rosetta, and they are the ones hosted production runs. See [Through GitHub](#through-github) below.

### Dev

```bash
# Every image just built (writes .build/digests.tsv, which promote reads)
make images
make promote ENV=dev

# One image. IMAGE is web, admin, space, live, backend, postgres, valkey, rabbitmq or silo
make promote ENV=dev IMAGE=web DIGEST=sha256:<64-hex>
```

`web` maps to the chart's `plane-frontend`. Add `REPO=` when the digest comes from another repository. A digest under
`localhost:5001/` must already be in the local registry, or the script stops before Argo CD can sit in `ImagePullBackOff`.

#### Through GitHub

This is the path hosted production's images take. `images.yml` builds plain linux/amd64 manifests on `ubuntu-24.04`, because the VPS is
x86-64, while `make images` on this Mac stays linux/arm64. Dev runs the same bytes under Rosetta.

1. `images.yml` builds on `main`, pushes to GHCR, and opens a pull request bumping dev. Where publishing is not allowed, the job fails before it builds anything. The workflow rewrites the repository to `localhost:5001/wayline/` first, because that is where the kind cluster's Argo CD pulls from. It needs the repository setting that lets workflows open pull requests, on since 2026-11-05 by the owner's decision.
2. Merge it, and `git pull`.
3. Copy the digests before publishing, or pods fail to pull. Copying keeps the digest. Rebuilding would not. The script lower-cases `<owner>`, because an image reference takes only lower case. The packages are private, so this Mac's `gh` needs `read:packages`, which `scripts/hosted/owner-inputs.sh github` grants.

```bash
scripts/ci/copy-to-local-registry.sh ghcr.io/bereketabera/wayline dev
make gitops-publish
make test-e2e ENV=dev
```

A merge changes nothing running. GitHub Actions cannot reach the kind cluster. It reaches it only at `make gitops-publish`.

All three steps ran on 2026-11-07. Run 42318206339 built the four images from `5161bf9`, which the [signed record](evidence/promotions/6d3610b95f013b4f07212106e467577f8f45e9ede9ec282ef1223b95d72e5d12.json) names,
and [pull request 1](https://github.com/BereketAbera/plane-platform/pull/1), merged that day, carried them as `e499212`. The copy kept every digest, and the copy and the publish each exited 0
([copy and publish](evidence/runs/DEV-VALIDATE-copy-publish-20261107T050522Z.txt)). The smoke test read BLOCKED once, and PASS on a second run after the old pods had gone
([BLOCKED](evidence/runs/DEV-VALIDATE-smoke-20261107T051110Z.txt), [PASS](evidence/runs/DEV-VALIDATE-smoke-20261107T051309Z.txt)). On 2026-11-05 the same copy had stopped at the first image, with `invalid reference format`
before the script lower-cased the owner, and then with a 401, because nothing here could read the private packages yet
([ci-5-20261105T060504Z-copy-rehearsal.txt](evidence/ci/ci-5-20261105T060504Z-copy-rehearsal.txt), [ci-4-20261105T055130Z-ghcr-local-token.txt](evidence/ci/ci-4-20261105T055130Z-ghcr-local-token.txt)). Those were the arm64 builds of
runs 41975430939 and 42044273310 (rows CI-4 and CI-5 in [evidence/ci/README.md](evidence/ci/README.md)), which never reached the cluster.

`scripts/gitops-publish.sh` has no registry check, so a publish without the copy would point `plane-dev` at digests nothing can pull. That is read from the code, and no run has done it.

### Prod-sim

```bash
make test-e2e ENV=dev                                   # earn it first
make promote ENV=prod-sim                               # copies every differing image from dev, asks first
make promote ENV=prod-sim CONFIRM=yes
make promote ENV=prod-sim IMAGE=web DIGEST=sha256:<64-hex>
```

What `scripts/promote.sh` does differently for prod-sim:

| Step | Behaviour |
|---|---|
| Digest check | `scripts/ci/check-promoted-digests.sh` refuses any digest the dev overlay's Git history does not record for that same image. The failure-drill digest is refused by name |
| Plane-dev check | `scripts/lib/dev-check.sh` refuses unless `plane-dev` is Synced and Healthy with that digest in a ready container. `OVERRIDE_DEV_CHECK="<reason>"` goes ahead and logs the reason in `.local/evidence-raw/promotion-overrides.log`. With no cluster in reach, as in CI, the check is skipped, and the output and commit say so |
| Confirmation | Prompts for `yes`, or needs `CONFIRM=yes`. Without a terminal it stops |
| Backup | `scripts/backup.sh prod-sim` before any edit, because rolling back an image does not roll back a migration. `SKIP_BACKUP=yes` overrides, with a warning |
| Failure | Before the commit, restores the overlay and rendered file, so nothing half-promoted stays behind. If the publish is refused after the commit, the promotion stays on `main`, and it leaves with the next publish of any kind. Run `make promote` again, which publishes it, or withdraw it with `make rollback ENV=prod-sim` |
| Nothing to promote | With every digest already in the overlay, it publishes `main` if Argo CD has not read it, and a publish that fails exits non-zero |

The digest check cannot tell order inside one commit, so a change adding a digest to both environments at once passes. Human
review covers that.

**Through GitHub.** `promote-prod-sim.yml`, run by manual dispatch, edits the overlay, validates it, pushes branch `promote/prod-sim`, and
asks GitHub for a pull request. It never builds. On a real runner it refused an unrecorded digest on 2026-11-04 (run 41905513020), and on 2026-11-05 an invented digest and another image's digest
(runs 41976950402 and 41977025314). Run 41977114312 at `9c8e098` opened [pull request 2](https://github.com/BereketAbera/plane-platform/pull/2), closed unmerged as a test
(rows CI-6 and CI-6b in [evidence/ci/README.md](evidence/ci/README.md)). The repository setting that lets a workflow open a pull request has been on since 2026-11-05, by the owner's decision. With it off, GitHub refused
the pull request in runs 41905611391 and 41908167069. A pull request opened this way starts no job: GitHub holds its `ci` run for approval. No prod-sim promotion pull request has been merged, so steps 2 and 3 have not run. Hosted production's first promotion, pull request 3, is another workflow, [below](#exact-digest-image-sets).

1. Run the workflow, with `image` and `digest` or with neither to copy every image from dev. If that setting is off, the run goes red at the pull request step and links to the page for opening it by hand.
2. Review and merge. **Merging is the approval, and GitHub cannot enforce it.** The repository is private on the Free plan, so there are no environment reviewers and no protected branches. See [`.github/workflows/README.md`](../.github/workflows/README.md).
3. Publish. The workflow could not reach the cluster, so both checks happen here.

```bash
git pull
make gitops-publish      # asks plane-dev first, then takes the prod-sim dump, if a prod-sim image changed
```

`gitops-publish.sh` detects this by reading the diff of the prod-sim manifests for `@sha256:` lines. The plane-dev check comes first,
so a refused publish costs no dump, and `SKIP_BACKUP=yes` is not a way past it. It reads to the end of the diff rather than using
`grep -q`, which under `pipefail` could read a match in a large diff as no match. A stub run reproduces that trap on the old script and
takes the dump on the new one ([test_publish-stub-1.txt](evidence/runs/test_publish-stub-1.txt)). Its plane-dev check ran for real at `9c8e098`, where `make promote ENV=prod-sim` had already taken the dump
([promote-prod-sim-final-2.txt](evidence/runs/promote-prod-sim-final-2.txt)). A promotion merged on GitHub, where this script takes the dump itself, has not run.

Promotion covers image lines only. Any other change to prod-sim's rendered manifests gets a warning and is published, because `helm/plane/components/hardening` and the chart reach both environments in one push.
A digest changed by hand gets a warning if `make promote` would have refused it. A publish also warns about commits on `main` that are not on `origin/main`, which GitHub CI and review have not seen.

### After a promotion

Argo CD picks up the commit at its next reconciliation, or ask with the refresh annotation above. Then:

```bash
kubectl -n argocd get application plane-prod-sim
make test-e2e ENV=prod-sim
```

Both halves have run. On 2026-11-05, `make promote ENV=dev` published `1fc9fbe` and `make promote ENV=prod-sim` published `9c8e098`, carrying the final images from `84b63d9` through the local registry
([promote-dev-final-2.txt](evidence/runs/promote-dev-final-2.txt), [promote-prod-sim-final-2.txt](evidence/runs/promote-prod-sim-final-2.txt)). After them, `make test-e2e` read 45 PASS and 1 SKIP in dev, and 44 PASS and 1 SKIP in prod-sim, with the running digests equal to the overlay's ([smoke-dev-20261105T053137Z-52811.json](evidence/runs/smoke-dev-20261105T053137Z-52811.json), [smoke-prod-sim-20261105T053533Z-8468.json](evidence/runs/smoke-prod-sim-20261105T053533Z-8468.json)). The skip needs a clean
database. The clean install's first smoke ran it, and read 46 PASS in dev and 45 PASS in prod-sim ([dev](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-dev-20261105T080642Z-65896.json), [prod-sim](evidence/runs/clean-install-20261105T075041Z/clone-evidence/smoke-prod-sim-20261105T080826Z-22080.json)).

**The dump comes first.** Prod-sim's promotion checked each digest against dev's record, asked plane-dev, and took backup `20261105T053351Z` with its row counts and object check before it committed `9c8e098` at 05:34:06Z. The publish then asked plane-dev
again, and took no second dump ([promote-prod-sim-final-2.txt](evidence/runs/promote-prod-sim-final-2.txt)). That backup has not been restored, so this shows it exists and came first. A later prod-sim backup was restored in place with result PASS ([restore-prod-sim-20261105T073438Z.json](evidence/runs/restore-prod-sim-20261105T073438Z.json)), on the same schema, so going back past a migration was not tested in Pass 1.

**How long it took,** to the Application's operation closing `Synced` and `Healthy`, each with a refresh asked ([argocd-refresh-reasons-1.txt](evidence/runs/argocd-refresh-reasons-1.txt), and `started` and `finished` in [DEP-1-20261105T062323Z-timeline.txt](evidence/runs/DEP-1-20261105T062323Z-timeline.txt)):

| Promotion | From | Sync began | Closed | Total |
|---|---|---|---|---:|
| `1fc9fbe`, dev, four images | Commit at 05:29:47Z | 05:29:48Z | 05:30:54Z | 67s |
| `9c8e098`, prod-sim, the same four, already on the node | Dump started at 05:33:51Z | 05:34:07Z | 05:35:07Z | 76s |

One run each, on a small database: the dump is 806,858 bytes. So about 15 of prod-sim's seconds were that dump, and a large database would take longer. Neither run waited for Argo CD's own look, which can add up to the 289s above.

If it goes wrong, see [Rollback](#rollback). Failure handling is in [runbooks](runbooks/).

## Hosted production

Hosted production runs an Argo CD of its own, the same v3.5.7 from chart `argo-cd` 10.11.7, installed by Terraform root
`environments/prod` with values from `gitops/clusters/plane-prod/values/argocd.yaml`. Those values are a copy of the local ones, with
the same health checks and the same lean shape: one replica of each part that runs, no Dex, no notifications, and the ApplicationSet
controller at 0 replicas. What differs is where it reads, who writes that, and how a change gets there.

| | Kind cluster | Hosted production |
|---|---|---|
| Git source | `git://plane-git/plane-platform.git`, branch `main` | `ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git`, branch `deploy/plane-prod`, with a read-only deploy key |
| Who writes it | `make gitops-publish`, from this Mac | CI's `release-plane-prod` job alone, after a push to `main` passes |
| What the branch holds | All of `main` | `gitops/clusters/plane-prod`, `gitops/environments/prod` and `RELEASE.json`, and nothing else |
| Promotion | `make promote`, with the plane-dev check and a dump | A signed record that dev ran the exact set, then a pull request that a person merges |
| Rollback | `make rollback`: a revert, then a publish | A revert on `main`, or the promotion of an older set. `make rollback` refuses `ENV=prod` |
| Access | `http://argocd.localhost` | No public route: `make remote-ui TARGET=plane-prod UI=argocd`, on `http://localhost:18080` |
| Applications | Root and 13 children | Root and 13 children, a different set, so 14 in all |

No CI job holds a Kubernetes credential, so GitHub cannot reach the cluster: it changes what Argo CD reads, and Argo CD pulls, with no
webhook, at its next look, as locally. With this Mac off, production should keep running, because by design nothing it needs is here, which no test has checked. New digests wait
meanwhile, because new evidence needs this Mac's dev cluster and its signing key.

### The bootstrap chain on hosted production

| Step | Owner | Notes |
|---|---|---|
| Deploy key | `scripts/hosted/bootstrap.sh`, step 1 | Made on this Mac, added to GitHub read-only, and kept in `.local/hosted/plane-prod/argocd-deploy-key`. A key added with `gh`'s token goes if that token's app is de-authorized, and that shows at once as Argo CD failing to fetch |
| Secret `argocd/argocd-repo-plane-platform` | Bootstrap, step 2 | Written after the namespaces and before Argo CD starts, so its first look at the repository works. It cannot come from Infisical, because Argo CD deploys Infisical |
| Argo CD, AppProjects, root Application | Terraform, bootstrap step 3 | The bootstrap chart in `gitops/clusters/plane-prod/bootstrap-chart`. Read from no branch, so nothing Git delivers can widen a project |
| Everything else | Argo CD, from `deploy/plane-prod` | |

The chart's default known hosts already hold `[ssh.github.com]:443`, so no host key is configured.

### Projects on hosted production

| Project | Destinations | Source repos | Cluster-scoped | Denied in namespaces |
|---|---|---|---|---|
| `platform` | All namespaces | The GitHub repository and seven chart repositories, one of them the OCI repository `quay.io/jetstack/charts` | All except `Namespace` | `ResourceQuota`, `LimitRange` |
| `plane-prod` | `plane-prod` only | The GitHub repository only | None | `ResourceQuota`, `LimitRange`, `NetworkPolicy` |

`policy/hosted.rego` holds the hosted tree to more, in CI: one Git source at that branch, paths only under
`gitops/clusters/plane-prod/platform/` or the render, Helm values only from `$values/gitops/clusters/plane-prod`, each chart pinned to one
version, no inline parameters or values on a source, no ApplicationSet, and no project but these two.

### Root and its children

`root` reads `gitops/clusters/plane-prod/applications/`, its one source, so its status carries `status.sync.revision`. Each file there
is one child, and every child reads the same branch. Paths are under `gitops/clusters/plane-prod/`.

| Wave | Application | Project | Namespace | Source | Finalizer |
|---:|---|---|---|---|---|
| -10 | `network-policies` | platform | several | `platform/network-policies` | No |
| -10 | `backup` | platform | `plane-prod`, `infisical`, `frameflow` | `platform/backup`: the static volumes on `/srv/wayline/backups`, their claims, and the nightly CronJobs | No |
| -9 | `traefik` | platform | `traefik` | chart 42.3.0 | Yes |
| -8 | `cert-manager` | platform | `cert-manager` | chart v1.21.3, from the OCI repository | No |
| -8 | `metrics-server` | platform | `kube-system` | chart 3.14.0 | Yes |
| -7 | `certificates` | platform | `plane-prod`, `monitoring`, `infisical`, `rillmark`, `awushi-cloudgarden`, `frameflow` | `platform/certificates`: ClusterIssuers `letsencrypt-staging` and `letsencrypt-production`, and Certificates `wayline-tls`, `grafana-tls`, `infisical-tls`, `rillmark-tls`, `devops-tls` and `frameflow-tls` | No |
| -7 | `kube-prometheus-stack` | platform | `monitoring` | chart 92.18.0 | Yes |
| -6 | `loki` | platform | `monitoring` | chart 20.4.1 | Yes |
| -6 | `alloy` | platform | `monitoring` | chart 1.15.0 | Yes |
| -5 | `monitoring-extras` | platform | `monitoring`, with probes and exporters in `plane-prod` and `infisical`, each app's Probe in its own namespace, and Frameflow's rules and Silo's ServiceMonitor in `frameflow` | `platform/monitoring-extras` | Yes |
| -4 | `infisical` | platform | `infisical` | chart `infisical-standalone` 1.12.0, and `platform/infisical`: Postgres, Redis, the server's ServiceAccount and its public route | No |
| -3 | `infisical-operator-prod` | platform | `plane-prod` | chart `secrets-operator` 0.11.16. The first of the two operators, and the one that installs the CRDs | No |
| 0 | `plane-prod` | plane-prod | `plane-prod` | `gitops/environments/prod` | No |
| 1 | `rillmark` | rillmark | `rillmark` | `platform/rillmark` | Yes |
| 1 | `awushi-cloudgarden` | awushi-cloudgarden | `awushi-cloudgarden` | `platform/awushi-cloudgarden` | Yes |
| 1 | `infisical-operator-frameflow` | platform | `frameflow` | chart `secrets-operator` 0.11.16, as `iso-frameflow`, scoped to `frameflow`, with no CRDs | No |
| 2 | `frameflow` | frameflow | `frameflow` | `platform/frameflow`, with `PruneLast=true` | No |

Against the kind cluster's waves: cert-manager comes at -8, so its CRDs exist before the Certificates at -7. The Certificates, the
ClusterIssuers and the backup CronJobs carry `argocd.argoproj.io/ignore-healthcheck`, so an ACME outage, a closed firewall or a failed
night cannot hold root at their wave, and alert rules report those failures instead. postgres-exporter carries it too, because
`plane-pgdb`'s Secret exists only once Plane's Application does, at wave 0, after it, and so do Frameflow's two CronJobs, so a run that
fails cannot hold `frameflow`'s sync. There is no prod-sim and no route for Argo CD. There are two operators, `iso-prod` for `plane-prod`
and `iso-frameflow` for `frameflow`, each a release of its own as ADR 0009 asks, and only the first installs the CRDs. The apps come
last, after `plane-prod`, as [hosted-apps.md](hosted-apps.md) says, so in a sync of root none of them can hold Plane's wave.

**Plane arrives with the first promotion.** `applications/plane-prod.yaml` is a copy of
`gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl`, which `scripts/ci/promote-prod.sh` makes on the first promotion. Until then
root holds no Plane Application, and the platform comes up alone. A revert of that promotion would take the file away, and root would
prune the Application and leave Plane running unmanaged with its availability alerts quiet. So the release job refuses to go from a set
back to none.

Inside the Plane Application the waves are those of [Inside a Plane Application](#inside-a-plane-application), with two more objects. A
seventh `InfisicalStaticSecret`, `ghcr-pull`, at wave -1, gives ServiceAccount `plane` its GHCR pull secret. Job
`plane-prod-predeploy-dump`, a Sync hook at wave 1, waits for Postgres and dumps it to the backup volume, so every migration at wave 2 has
a fresh dump behind it.

Every hosted Application has `automated: {prune: true, selfHeal: true}`, `retry.limit: -1` with `refresh: true`, and a backoff of 30s,
factor 2, cap 5m. So a failing sync on hosted production reads `Running` too, and [Retry behaviour](#retry-behaviour) applies as it
stands. `monitoring/ops/lib.sh` refuses `ENV=prod`, so pausing auto-sync there is by hand, root first and back last, with the
`kubectl` of [install.md](install.md#day-to-day). The rollback steps in [scripts/hosted/README.md](../scripts/hosted/README.md) show the
patches.

### Releases: deploy/plane-prod

`scripts/ci/publish-release.sh` is the only writer of `deploy/plane-prod`. `ci.yml`'s job `release-plane-prod` runs it on each push to
`main`, once Lint, Manifests and Security have passed, one run at a time, with `contents: write` to move the branch and `packages: read`
to read GHCR. It stops at the first check that fails. A failure leaves the branch where it is, so a merged change that fails reaches
nothing, and production keeps running what it ran.

1. `scripts/ci/check-prod-evidence.sh` on the commit. Exit 0 names the set the render runs. Exit 3 means plane-prod is not promoted yet,
   and the release holds the platform alone. Anything else refuses.
2. It refuses to move backwards: the branch's `RELEASE.json` names a main commit, and this one must descend from it. A rollback is a
   revert, which moves forwards.
3. It refuses a branch that no longer holds what its `RELEASE.json` names, because someone pushed it by hand, and overwriting that would
   hide it. See [check-deploy-branch.yml](#check-deploy-branchyml).
4. It refuses to go from a set back to none, which is what a revert of the first promotion leaves.
5. If the two hosted trees already match the branch's, it changes nothing.
6. Each Wayline digest must be a plain linux/amd64 manifest on GHCR, whose bytes hash to that digest, and whose revision label is the one
   the evidence signed.
7. It writes a commit that holds only `gitops/clusters/plane-prod`, `gitops/environments/prod` and `RELEASE.json`, parented on the
   branch's tip, and pushes it without force. So no workflow file can cross to the branch, and a branch that moved meanwhile refuses it.

`RELEASE.json` says where a release came from:

```json
{
  "main_commit": "<the main commit, 40 hex>",
  "repository": "BereketAbera/plane-platform",
  "run": {"id": "<run id>", "attempt": "<attempt>", "url": "https://github.com/BereketAbera/plane-platform/actions/runs/<run id>"},
  "set_hash": "<the set, 64 hex, or null before the first promotion>"
}
```

The commit's subject is `release: main <12 hex>, set <12 hex>`. To see what production should be running, and what it does run:

```bash
git fetch origin deploy/plane-prod
git log --format='%h %cI %s' FETCH_HEAD | head
git show FETCH_HEAD:RELEASE.json
make remote-status TARGET=plane-prod      # each Application's revision, and the branch check
```

Read from GitHub on 2026-11-07, the branch's first three releases held the platform alone, and each release since the first promotion
names set `6d3610b95f01`. The release job's runs are on GitHub, and none is in `docs/evidence` yet.

### Exact-digest image sets

A set is every image the render runs, by digest. Its name, `set_hash`, is the sha256 of the sorted, unique lines
`<production repository>@<digest>`, one for each image, so a tag does not count, because the runtime pulls by digest.
`docs/evidence/promotions/<set_hash>.json` says plane-dev ran exactly that set and that its smoke passed against those containers, and
`<set_hash>.json.sig` is its signature, made on this Mac with `~/.ssh/wayline_evidence_ed25519`, whose public half is in
`.github/evidence-signers`. The key stays on the laptop, so nothing in CI can make evidence. [The promotions README](evidence/promotions/README.md)
describes the file, and what a signature does and does not prove.

`scripts/ci/check-prod-evidence.sh` reads the commit and not the working tree, asks no cluster, and takes no argument or setting that
could make it lenient. Every image in `gitops/environments/prod/manifests.yaml` must be in one signed record that covers exactly that
set. It holds no clock either, so an older set keeps its evidence, and a rollback to it passes. It covers the render and nothing else:
Traefik, cert-manager, monitoring, Infisical and the backup Jobs never ran in dev as they do here, and `validate-manifests.sh` holds the
images outside the render to `policy/hosted-images.txt`, which makes a new one a diff that a person reads.

From a digest bump to production:

1. Dev runs the exact bytes: the `images.yml` bump merged, the copy, `make gitops-publish`, `make test-e2e ENV=dev` and
   `make publish-evidence`, as [Through GitHub](#through-github) says.
2. `make record-dev-evidence` writes the record and its signature. It refuses unless the newest dev smoke passed, with its branding
   check, every container started before that smoke began, every digest runs in a ready container in plane-dev, and each branded digest
   is a plain linux/amd64 manifest on GHCR, built by a successful `images.yml` run on a commit in `main`'s history. Commit the two files
   with the published smoke, and push.
3. `gh workflow run promote-plane-prod.yml -f set_hash=<set_hash>` maps the set to GHCR names in `helm/plane/overlays/prod`, renders,
   adds `applications/plane-prod.yaml` on the first promotion, runs the check on the result, and opens a pull request from
   `promote/plane-prod`. It never builds, and cannot reach the cluster.
4. A person merges it. **Merging is the approval, and GitHub cannot enforce it**: the repository is private on the Free plan, with no
   environment reviewers and no protected branches. See [`.github/workflows/README.md`](../.github/workflows/README.md).
5. The release job checks the merged commit again, confirms each digest on GHCR, and moves `deploy/plane-prod`. Argo CD syncs it.

On the first promotion Plane's first admin can be claimed by whoever posts first, so keep the firewall at `owner` or lower until the
owner has made it ([install.md](install.md#firewall-stages)).

**The one set promoted so far** is `6d3610b95f01` ([record](evidence/promotions/6d3610b95f013b4f07212106e467577f8f45e9ede9ec282ef1223b95d72e5d12.json)):
the four branded images that `images.yml` run 42318206339 built from `5161bf9`, and five upstream indexes, Plane's `live`, Postgres
15.19, RabbitMQ 3.13.7, Valkey 7.2.15 and Silo. Plane-dev ran it at `201c85b`, under Rosetta, and the record names the smoke it passed
([smoke](evidence/runs/smoke-dev-20261107T051309Z-98217.json)). For an upstream index, dev ran its linux/arm64 child and production runs
its linux/amd64 child, which dev never ran, and the record says so. The promotion was
[pull request 3](https://github.com/BereketAbera/plane-platform/pull/3), merged on 2026-11-07.

### check-deploy-branch.yml

GitHub Free cannot protect a branch of a private repository. Anyone with write access can push `deploy/plane-prod`, and so can any job
with `contents: write`, whatever its comments say. Root and its children sync what the branch holds, so writing it amounts to
cluster-admin. Nothing short of a paid plan or a check on the cluster prevents that. Three places detect it, and by then Argo CD may
have deployed it:

| Where | When | What it does |
|---|---|---|
| `.github/workflows/check-deploy-branch.yml` | Each day at 05:23 UTC, and on dispatch | Runs `scripts/ci/check-deploy-branch.sh` with `contents: read`, and changes nothing. Exit 0: the branch holds what its `RELEASE.json` says main released, or there is no branch yet. 1: it does not, and it names what differs. 2: the branch could not be read, which says nothing |
| `make remote-status TARGET=plane-prod` | When someone runs it | The same script, because GitHub may delay or drop a scheduled run |
| The release job | Each push to `main` | Refuses on the same comparison, step 3 above, rather than overwrite the push and report success |

The comparison: the branch holds nothing but `RELEASE.json` and the two hosted trees, its `RELEASE.json` names a commit on `main`, and
each tree is that commit's, object for object. Without the daily run, a push between two releases could stay for as long as `main` is
quiet. To put the branch back, read the diff the message prints, push a commit on the branch whose trees are the recorded commit's, and
run the release job again.

### Rollback on hosted production

**Rollback is a revert on `main`, or the promotion of an older set.** Both move `deploy/plane-prod` forwards. The release job refuses
to move it backwards, so never push an older release commit to the branch.

| Way | How | Note |
|---|---|---|
| Revert a promotion | `git revert` of the promotion commit on `main`, then the release job | The older set still has its evidence, so the gate passes |
| Promote an older set | `gh workflow run promote-plane-prod.yml -f set_hash=<older set>`, then merge | The same gate, and the same evidence |
| Revert the first promotion | Refused by the release job | It would leave no set, and root would prune Plane's Application. Promote another set, or revert the revert |
| Revert a platform change | `git revert` on `main`, then the release job | A change Terraform owns needs root `prod` applied again: [terraform.md](terraform.md#plan-and-apply-on-hosted-production) |

**Images roll back, the database does not.** A migration the newer image ran stays applied. If the older image runs on that schema,
stop there. If it does not, or if the migration did the damage, restore the dump Job `plane-prod-predeploy-dump` took just before it.
Everything written since that dump is lost, so a person decides. [scripts/hosted/README.md](../scripts/hosted/README.md), section After a
rollback: the database does not go back, says which dump to take and gives the steps in order, and the runbook
[Rollback on hosted production](runbooks/hosted-rollback.md) walks the whole of it. `make rollback` and `make restore` refuse `ENV=prod`.

**What has run.** No rollback of hosted production has run, by either way: NOT RUN. The restore of a predeploy dump has not run on a real
cluster either: NOT RUN.
