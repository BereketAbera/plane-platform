# Environments

The platform runs two deployments of customized Plane Community Edition v1.4.3: `dev` and `prod-sim`. They sit in two namespaces of one cluster on one laptop.

**Namespace separation is not equivalent to independent production clusters.** `prod-sim` is a rehearsal of production practices. It is not production, and it is not isolated the way production would be. This page says exactly what is separate, what is shared, and how that fails.

Nothing here has been shown to work yet, except where a link to evidence says so. Plane is not deployed at the time of writing. Statements describe configuration, and runtime claims carry markers.

## At a glance

| | `dev` | `prod-sim` |
|---|---|---|
| URL | `http://plane.dev.localhost` | `http://plane.prod-sim.localhost` |
| Namespace | `plane-dev` | `plane-prod-sim` |
| Argo CD Application | `plane-dev`, root wave -1 | `plane-prod-sim`, root wave 0 |
| Overlay | `helm/plane/overlays/dev` | `helm/plane/overlays/prod-sim` |
| Rendered manifests | `gitops/environments/dev/manifests.yaml` | `gitops/environments/prod-sim/manifests.yaml` |
| How it changes | Automated sync with self-heal, from Git | Same. The control point is the Git change, not a sync button |

Object names match in both, because the Helm release is `plane` in each. That lets one patch set fit both.

## What is separate

| Layer | `dev` | `prod-sim` | How strong the separation is |
|---|---|---|---|
| Namespace | `plane-dev` | `plane-prod-sim` | A naming and RBAC scope. Not a security boundary on its own |
| Database | `plane-pgdb` StatefulSet and PVC | Same names, own instance | Separate process and volume. NetworkPolicy denies cross-namespace access |
| Cache and queue | Own Valkey, own RabbitMQ | Own Valkey, own RabbitMQ | Separate. Valkey has no password, so NetworkPolicy is its only access control |
| Object storage | Own Silo, bucket `uploads` | Own Silo, bucket `uploads` | Separate instance and volume. The bucket name is the same in both on purpose, because `export_task.py` hardcodes it |
| Credentials | Generated and stored in project `plane-dev` | Generated and stored in project `plane-prod-sim` | Different values, generated at seed time |
| Secrets operator | Release `infisical-operator-dev`, `fullnameOverride: iso-dev`, scoped to `plane-dev` | Release `infisical-operator-prod-sim`, `iso-prod-sim`, scoped to `plane-prod-sim` | Separate pods and namespaced RBAC. **The CRDs are shared and owned by the dev release** |
| Machine identity | `plane-dev-reader`, built-in `viewer`, org role `no-access` | `plane-prod-sim-reader`, same roles | Each may log in only from its own namespace and ServiceAccount |
| Infisical project | `plane-dev` | `plane-prod-sim` | This is the free-tier isolation boundary. Same server, same database, same encryption key |
| Argo CD project | `plane-dev`: deploys to `plane-dev` only | `plane-prod-sim`: deploys to `plane-prod-sim` only | Stops a Plane Application from writing elsewhere, cluster-scoped objects, or NetworkPolicies |
| ResourceQuota | `plane-budget`: 2704Mi requests, 7904Mi limits, memory and object counts only | Same | Bounds memory declared by pods. No CPU quota |
| Backup storage | PV `backups-dev`, host path `/backups/dev`, PVC `backups` | PV `backups-prod-sim`, `/backups/prod-sim` | A pod mounts only its own folder. `restore.sh` refuses another environment's backup |

The cross-environment deny rows in `tests/network-policy-matrix.yaml` describe the intended reach. They have not yet run against both environments. [[VERIFY: every deny row between plane-dev and plane-prod-sim in tests/network-policy-matrix.yaml times out, run by make test-netpol]]

[[VERIFY: dev machine identity gets 403 reading the plane-prod-sim project in Infisical]]

[[VERIFY: an InfisicalAuth in plane-dev that names the prod-sim identity id fails to log in]]

### Intended differences

The two overlays are almost identical. Apart from names and hostnames, these are the only differences.

| Setting | `dev` | `prod-sim` | Why |
|---|---|---|---|
| `env.enable_drf_spectacular` | `true`, serves `/api/schema/` | `false` | Scripted testing in dev. No debug surface in prod-sim |
| CPU request on api, worker, postgres, rabbitmq | Component default | `100m` | Scheduler weight, so the tiers prod-sim depends on win when dev competes. Memory is unchanged |
| k6 load-test NetworkPolicy | Present | Absent | Load tests run only in dev |
| Image digests | Current build | Whatever was last promoted | The point of having two environments |

## What is shared

| Shared thing | What that means |
|---|---|
| **Cluster** | One Kubernetes version, one set of cluster-scoped objects and CRDs. `make destroy` removes both environments together |
| **Node** | One container, `plane-platform-control-plane`, with one memory, CPU, and disk budget. Control plane and workloads run on it together |
| **API server and etcd** | One control plane. Both environments' Secrets sit in one etcd, base64 and not encrypted at rest |
| **Traefik** | One pod with a 192Mi limit serves both environments and every admin UI. Routes from all namespaces merge into one router |
| **Argo CD** | One controller, one repo-server, one Redis, one admin. If it stops, both lose reconciliation and self-heal. Running pods carry on |
| **Infisical server** | One server, one Postgres, one Redis, one `ENCRYPTION_KEY`. Projects are logical separation inside it |
| **Monitoring** | One Prometheus, Alertmanager, Grafana, Loki, and Alloy. Retention and volume are shared |
| **Kernel** | One Linux kernel in the Docker VM, shared with every other container on the host. `monitoring-agents` runs with `hostNetwork` and `hostPID` under PSA `privileged` |
| CoreDNS and kindnet | One resolver and one policy engine. kindnet fails open, for both at once |
| Infisical CRDs | Cluster-scoped, installed by `infisical-operator-dev` alone |
| Registry, caches, Git remote | One `plane-registry`, one `plane-git`, one `main` branch, one bare repo |
| Terraform state | One root for both namespaces |
| Human access | One kubeconfig with cluster-admin, one Argo CD admin, one Infisical admin token. No per-environment operator role exists |
| Host | One Mac and one disk |

## The promotion model

```mermaid
flowchart LR
  build["make images<br/>or images.yml"] --> digests["Digest recorded in<br/>.build/digests.tsv or a PR"]
  digests --> pdev["make promote ENV=dev<br/>edit overlay, render, commit, publish"]
  pdev --> rdev["Argo CD syncs plane-dev"]
  rdev --> check["A person checks dev"]
  check --> pprod["make promote ENV=prod-sim<br/>or promote-prod-sim.yml PR plus make gitops-publish"]
  pprod --> guard{"Digest in dev's Git history?"}
  guard -->|"no"| refuse["Refused"]
  guard -->|"yes"| dump["Back up prod-sim first"]
  dump --> commit["Edit overlay, render, commit, publish"]
  commit --> rsim["Argo CD syncs plane-prod-sim"]
  rsim --> rollback["make rollback ENV=prod-sim CONFIRM=yes<br/>git revert, images only"]
```

```bash
make images                                   # build and push to localhost:5001, write .build/digests.tsv
make promote ENV=dev                          # takes digests from .build/digests.tsv
make promote ENV=dev IMAGE=web DIGEST=sha256:<digest>
make promote ENV=prod-sim CONFIRM=yes         # copies every differing image from the dev overlay
make rollback ENV=prod-sim CONFIRM=yes        # reverts the last promotion of prod-sim, then publishes
```

**What promotion is.** A commit that moves image digests in one overlay. Argo CD then syncs automatically. There is no sync button in the path, and the migrator runs as a Sync hook at wave 2 like any other sync.

**What is enforced, and by what.**

| Rule | Enforced by | Limit |
|---|---|---|
| Prod-sim takes only a digest recorded for dev | `scripts/promote.sh`, `scripts/ci/check-promoted-digests.sh` | "Recorded" means committed to dev's overlay. **It does not mean dev was healthy or tested.** Nothing checks that. A commit adding a digest to both environments at once also passes |
| A backup precedes a prod-sim image change | `scripts/promote.sh`, and `scripts/gitops-publish.sh` for the GitHub path | `SKIP_BACKUP=yes` overrides. It is a safeguard against accidents, not a control |
| A person confirms prod-sim | Terminal prompt or `CONFIRM=yes` | One person can do everything, by design |
| Pull request review | Process only | GitHub Free on a private repo has no required reviewers or protected branches. Anyone with write access can merge their own pull request or push to `main` |
| The local registry holds the digest | `scripts/promote.sh` | Skipped with `SKIP_REGISTRY_CHECK=yes` |

[[VERIFY: promoting a digest never recorded for dev is refused, and a promoted digest reaches prod-sim unchanged]]

[[VERIFY: make promote ENV=prod-sim produces a backup before the commit]]

[[VERIFY: make rollback ENV=prod-sim restores the previous digest through git revert with auto-sync still on]]

**What promotion does not cover.**

- **Only digests are promoted. Configuration is not.** `helm/plane/components/hardening`, the vendored chart, and most of `helm/values/` feed both environments. A change to the hardening component plus `make render` changes both rendered manifests in one commit, and both Applications sync on their own. So a bad patch reaches prod-sim with no dev stage. Sync waves do not help, because waves only order the root's first creation of each Application.
- **Platform changes have no stage at all.** Traefik, Argo CD, Infisical, monitoring, CoreDNS, and NetworkPolicies exist once. A change goes live for both environments.
- **Rollback restores images, not data.** Migrations are forward-only, and old code starts against a newer schema with no warning. The dump taken before promotion is the way back, through `make restore`, as a deliberate second step.
- **Secrets are not promoted.** Each environment has its own values. Adding a key means seeding both projects by hand or by script.

## Why this is not the same as independent clusters

An independent production cluster has its own control plane, nodes, kernel, ingress, delivery, secret store, and monitoring, and usually its own account, network, and credentials. Here every one of those is shared. A namespace limits names and RBAC, a quota limits declared memory, and a NetworkPolicy limits packets, if the CNI is running. None of them isolates the kernel, the disk, the control plane, or the operator's mistakes.

So:

- A clean result in `prod-sim` shows how the application behaves in this configuration. It does not show production-grade isolation, availability, or capacity.
- An outage in shared infrastructure is an outage in both environments.
- A change to shared infrastructure cannot be tested in `dev` first.

### Failure scenarios

None of these has been run. Each describes what the configuration implies. The drills that do exist are listed in [validation.md](validation.md).

| # | Trigger | What happens to `prod-sim` | With a separate cluster |
|---|---|---|---|
| 1 | The Docker VM restarts, or the kind node container stops | Down, with `dev` | Unaffected |
| 2 | A `dev` load test or migration uses a lot of memory | The node's OOM killer does not respect namespaces, so prod-sim pods can die. Each ResourceQuota allows 7904Mi of limits: two together are 15,808Mi, above the 14,336Mi Docker Desktop memory setting research recorded on 2026-11-04 | Unaffected |
| 3 | `dev` uses a lot of CPU | Each Plane workload has its own CPU limit, but the ResourceQuota has no CPU line, so nothing caps a namespace's total against the node. Prod-sim's `100m` requests give it weight, not a guarantee, and API server latency rises for both | Unaffected |
| 4 | Dev data, images, or logs fill the disk | kind sets no eviction and no image GC, and the VM reports hundreds of free GiB while the Mac runs out. Writes fail for both, with no alert. `guard_disk` only checks at script entry | Unaffected |
| 5 | The API server or etcd is overloaded or corrupted | Both lose scheduling, reconciliation, and log collection, since Alloy reads through the API. Corrupted etcd means both environments' objects and Secrets | Unaffected |
| 6 | Traefik crashes, is OOM-killed at 192Mi during a dev load test, or a route breaks its config | Both Plane hosts and all admin UIs go down together | Unaffected |
| 7 | A `dev` IngressRoute names `Host(plane.prod-sim.localhost)` | Traefik reads routes from all namespaces, the `plane-dev` project allows IngressRoutes in its namespace, and `policy/plane.rego` does not check hostnames. A longer rule could win and capture prod-sim traffic into a dev Service | Impossible: separate ingress and DNS |
| 8 | Argo CD's controller or repo-server stops | No sync and no self-heal for either environment. Running pods carry on | Depends on the design; a separate Argo CD is common |
| 9 | A commit changes `helm/plane/components/hardening` | Both environments change in one commit. See the promotion section | Reaches prod only when promoted |
| 10 | A commit edits a file in `gitops/applications/` to set `project: platform` on a Plane Application | The Plane project's limits no longer apply. The AppProjects are not managed from Git, but the Application's choice of project is, and no policy rule checks it | A separate cluster's credentials would still bound it |
| 11 | Infisical's server stops | No refresh and no rotation for either. Existing Kubernetes Secrets stay in place, so running pods continue | Unaffected |
| 12 | `ENCRYPTION_KEY` and the cluster Secret are both lost, or Infisical's Postgres is lost without a dump | Both environments' secret values are gone. `SECRET_KEY` is bound to each Plane database's encrypted rows, so restores must match | Unaffected |
| 13 | `infisical-operator-dev` is deleted with cascade, or a dev-labelled CRD upgrade goes wrong | Deleting the CRDs deletes every Infisical CR in both namespaces. The Secrets use `creationPolicy: Owner`, so they would be garbage-collected, and prod-sim pods fail at next start. The Application has no finalizer, so plain deletion does not cascade. A cascade requested by hand is not stopped, and neither is auto-prune after a values edit that sets `installCRDs: false` | Unaffected |
| 14 | kindnet crashes or errors | It fails open with only a log line, so every NetworkPolicy stops applying for both, silently. `dev` could then reach prod-sim's Valkey, which has no password | Unaffected |
| 15 | CoreDNS fails, or `terraform destroy` empties its `Corefile` | Name resolution breaks for both at the next restart | Unaffected |
| 16 | A container escape from any pod | One kernel. Root on the node reaches every volume, every Secret on disk, and every container | Bounded to that cluster |
| 17 | Kubernetes or kind upgrade | Both move at once, with no way to try it in dev first. kind config changes mean delete and recreate | Upgrade one cluster, then the other |
| 18 | Noisy dev metrics or logs | Prometheus's `retentionSize: 1GiB` and Loki's volume are shared, so prod-sim's history shortens | Separate retention, or tenant limits |
| 19 | An operator runs a command against the wrong namespace | One kubeconfig reaches both. No separate context or role guards prod-sim, beyond the script prompts | A different context and credentials |
| 20 | `dev`'s api is compromised | See the next section | Network path does not exist |

[[VERIFY: scenario 7 is possible as described, by applying a test IngressRoute in plane-dev on a disposable cluster]]

[[VERIFY: scenario 11, existing Plane pods keep running and restart cleanly with Infisical stopped]]

[[VERIFY: scenario 13, CR and Secret deletion follows CRD deletion, on a disposable cluster only]]

[[VERIFY: scenario 14, what kindnet does to enforcement when its pod is deleted and while it restarts]]

## The known gap: api to Traefik to anywhere

Direct pod-to-pod paths between the environments are denied. But **the `api` pod in one environment can reach the other environment over HTTP through Traefik**, and the code does not prevent it.

The path:

1. The api must reach its own public host for `copy_object` and OAuth avatars. So `plane-dev.yaml` allows its egress to Traefik on port 8000, and `traefik.yaml` admits api pods from both Plane namespaces.
2. Traefik routes on the Host header, which a NetworkPolicy cannot see.
3. CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to Traefik for every pod in the cluster, and the Host header can be set regardless.

```mermaid
flowchart LR
  devapi["api in plane-dev"] -->|"allowed: TCP 8000"| traefik["Traefik"]
  traefik -->|"Host: plane.dev.localhost"| devback["dev web, api, space, admin, live, Silo"]
  traefik -->|"Host: plane.prod-sim.localhost"| simback["prod-sim web, api, space, admin, live, Silo"]
  traefik -->|"Host: prometheus.localhost, alertmanager.localhost"| mon["Prometheus and Alertmanager, no login"]
  traefik -->|"Host: argocd, grafana, infisical .localhost"| uis["Admin UIs, login required"]
  devapi -.->|"denied: postgres, valkey, rabbitmq, Silo, api"| simback
```

**What the attacker gets.** The other environment's public HTTP surface, the same as a browser on the laptop has. No direct database, cache, or queue access. A compromised dev api would still need valid credentials to do anything that requires login in prod-sim.

**The reach is wider than the other environment.** The comments in `plane-dev.yaml` and `tests/network-policy-matrix.yaml` name only the other Plane host. Traefik also serves `prometheus.localhost` and `alertmanager.localhost`, neither of which has a login. So the same path gives read access to all metrics for both environments, and to Alertmanager's API, which can silence alerts. Argo CD, Grafana, and Infisical are reachable too, at their login pages.

**Only `api` has this path among Plane pods.** Worker, beat, migrator, web, admin, space, live, and the exporters have no egress rule to Traefik. Blackbox and k6 reach Traefik, but they are platform test tools, not application pods.

**Why it stays in Pass 1.** The api needs the path, and a NetworkPolicy cannot express "only your own hostname". `tests/network-policy-matrix.yaml` leaves it out deliberately, because a row would have to assert allow on something undesirable.

| Possible fix | Effect | Cost |
|---|---|---|
| Separate clusters (Pass 2) | Path no longer exists between environments | The plan already |
| A dedicated route for self-calls in each namespace, or S3 endpoint config that does not use the public host | Closes the path | `settings/storage.py` builds the client from `request.get_host()`, so this means patching Plane behaviour |
| Per-environment Traefik instance | Closes cross-environment reach on one cluster | One more pod and a second NodePort pair |
| Auth Middleware on Prometheus and Alertmanager | Narrows the wider reach only | Basic-auth value to manage. The code already notes this as required before Pass 2 exposure |

[[VERIFY: from a new pod labelled as api in plane-dev, an HTTP request with Host plane.prod-sim.localhost to Traefik reaches prod-sim]]

[[VERIFY: from the same pod, requests with Host prometheus.localhost and alertmanager.localhost return data with no login]]

## Moving to independent environments

Pass 2 moves to Hetzner Cloud with independent dev and prod environments and Cloudflare in front, so most of the shared rows above stop being shared. None of that is provisioned or configured in Pass 1. See [future-hetzner.md](future-hetzner.md) and [PASS2_HANDOFF.md](../PASS2_HANDOFF.md).

Related: [architecture.md](architecture.md), [security.md](security.md), [known-limitations.md](known-limitations.md), [platform-contract.md](platform-contract.md).
