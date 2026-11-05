# Infisical

How secret values reach the two Plane environments of Wayline, a customized Plane Community Edition v1.4.3 deployment, and what happens when the secret store is lost.

**Status: run on the real cluster on 2026-11-04 and 2026-11-05, including `ROLLBACK=yes` and a full restore into a new cluster.** A result links to its file under `docs/evidence/runs/`. Prose with no file describes configuration in the repository, not observed behaviour. All of this is one local kind node, and it says nothing about Infisical on another host. Two later drills restored Infisical into new clusters too, every restore step PASS: one with the registry and caches removed as well, and `LOSE_CLUSTER=yes`, whose log reads `RESULT PASS` ([second](evidence/runs/restore-infisical-20261105T124950Z.json), [third](evidence/runs/restore-infisical-20261105T132002Z.json), [log](evidence/runs/drill-clean-restore-20261105T130633Z.log)). [`infisical/README.md`](../infisical/README.md) holds the full list of measurements. Where its status line, its rotation lines or its list of what is not yet proven disagree with a run linked here, the run stands.

| Component | Version | Where it is pinned |
|---|---|---|
| Infisical server | v0.167.6, by digest | `helm/values/infisical.yaml` |
| Chart `infisical-standalone` | 1.12.0 | `gitops/applications/infisical.yaml` |
| Operator `secrets-operator` | v0.11.16, chart 0.11.16, by digest | `helm/values/infisical-operator-dev.yaml`, `helm/values/infisical-operator-prod-sim.yaml` |
| Terraform provider `infisical/infisical` | 0.20.10 | `infisical/terraform/versions.tf` |
| Infisical's Postgres | `postgres:16.15-alpine`, by digest | `infisical/manifests/postgres.yaml` |
| Infisical's Redis | `redis:7.2.17-alpine`, by digest | `infisical/manifests/redis.yaml` |

Postgres and Redis here are dedicated to Infisical and never shared with Plane, so the secret store does not depend on what it protects. This Postgres runs with `max_locks_per_transaction=128`, because a backup's scratch restore held 3422 locks at the default of 64 ([dr-locks-2.txt](evidence/runs/dr-locks-2.txt)), on a table of 3328, which is `max_locks_per_transaction` times MaxBackends, 52 here. After the change it held 3437, on a table of 6656 ([dr-locks-5.txt](evidence/runs/dr-locks-5.txt)).

## What this design does and does not solve

It gives one source for every Plane secret value, keeps those values out of Git and out of Terraform state, and gives each environment its own read-only credential.

It does not remove secret zero. It moves the problem to the laptop: `ENCRYPTION_KEY` and friends sit in files under `.local/secret-zero/`. Materialised values are still Kubernetes Secrets, which are base64 in kind's etcd and not encrypted at rest. See [security.md](security.md) for what that leaves open.

## Ownership

| Thing | Owner | Never |
|---|---|---|
| Infisical server, its Postgres and Redis, both operators | Argo CD, `platform` project | `helm install` by hand |
| Projects, environment, identities, memberships, Kubernetes Auth | Terraform in `infisical/terraform`, separate root, state in `.local/terraform/infisical/` | Secret values. They never enter a variable, a plan or state |
| First admin and organization | `scripts/infisical-bootstrap.sh`, one API call | The chart's bootstrap Job, which would put the admin token in a cluster Secret. `autoBootstrap.enabled` is false |
| Plane secret values | `scripts/infisical-seed.sh`, first time only, then Infisical | Any copy on disk |
| Secrets `infisical-db`, `infisical-redis`, `infisical-secrets` | `scripts/secret-zero.sh` | Git, Argo CD |
| Secret `plane-infisical-identity` in each Plane namespace | `scripts/infisical-bootstrap.sh` | Rendered manifests, which hold zero `kind: Secret` |
| The six contract Secrets in each Plane namespace | The operator, through `InfisicalStaticSecret` | Hand edits, which the operator reverts on its next reconcile |

## Bootstrap from secret zero

The order matters because each step needs what the previous one created.

```mermaid
flowchart TD
  A["Terraform local root: namespaces"] --> B["scripts/secret-zero.sh: files, then 3 Secrets in namespace infisical"]
  B --> C["Argo CD: Infisical Postgres, Redis, server. 602 migrations on first boot"]
  C --> D["Argo CD: 2 namespaced operators"]
  C --> E["scripts/infisical-bootstrap.sh, from the host"]
  E --> E1["POST /api/v1/admin/bootstrap, once only"]
  E1 --> E2["Terraform in infisical/terraform"]
  E2 --> E3["scripts/infisical-seed.sh"]
  E3 --> E4["Publish plane-infisical-identity to both namespaces"]
  E4 --> F["Operators log in, 6 Secrets per namespace appear"]
  D --> F
  F --> G["Plane StatefulSets, migrator, Deployments"]
```

| # | Step | Run by | Waits until |
|---|---|---|---|
| 1 | Namespaces | Terraform, `infrastructure/terraform/environments/local` | |
| 2 | `scripts/secret-zero.sh` | Script. Needs step 1 | Files exist and the 3 Secrets are applied. Postgres and Redis wait in `CreateContainerConfigError` until then |
| 3 | `infisical` Application, wave -4. Inside it: ServiceAccount -2, Postgres and Redis -1, server 0, IngressRoute 1 | Argo CD | First boot finishes its migrations |
| 4 | `infisical-operator-dev` and `infisical-operator-prod-sim`, wave -3 | Argo CD | `infisical-operator-dev` alone installs the CRDs, so the prod-sim manager restarts until they exist |
| 5 | `scripts/infisical-bootstrap.sh` | Script, from the host. Needs `http://infisical.localhost` | Terraform applied, values seeded, identity Secrets published |
| 6 | `plane-dev` wave -1, `plane-prod-sim` wave 0 | Argo CD | `InfisicalAuth` stays unready until step 5 publishes the identity Secret |

Step 5 is outside Argo CD because it needs the admin token, and that token never enters the cluster. It seeds before it publishes identity ids, so an operator never logs in to an empty project.

First boot ran 602 migrations in about 11 s under the 1Gi limit and 640 MiB heap on arm64, with a peak of 807 MiB by cgroup `memory.peak` and 0 OOM events ([infisical-firstboot-1.txt](evidence/runs/infisical-firstboot-1.txt)). The container started at 21:10:39Z and the `infisical` Application read Healthy at 21:11:00Z, 21 s later ([bootstrap-timeline-1.txt](evidence/runs/bootstrap-timeline-1.txt)). `/api/status` itself was not timed apart from that.

`make up` runs these steps in this order. Its first whole run on a fresh cluster finished on 2026-11-05, inside `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes`: exit 0 in 955 s, all 14 Applications Synced and Healthy, and `make test-infisical` exit 0 with 118 PASS lines ([summary.txt](evidence/runs/clean-install-20261105T075041Z/summary.txt), [test-infisical.txt](evidence/runs/clean-install-20261105T075041Z/test-infisical.txt)). See [clean-rebuild.md](runbooks/clean-rebuild.md#rebuild). Before it, bootstrap ran with the operators already up, and the prod-sim ServiceAccounts and CRs were applied by hand 19 minutes before `plane-prod-sim` existed, after which Argo CD adopted them with the same UIDs ([infisical-prod-sim-crs-1.txt](evidence/runs/infisical-prod-sim-crs-1.txt)).

### Idempotence, and the trap in it

Steps 2 and 5 are written to be rerun. With an initialized instance and intact local files, the bootstrap script finds the admin file, Terraform changes nothing except a new cluster CA, and the seed writes nothing. Three reruns on the live instance, the last with both Plane environments up, gave "No changes" and left secret ids, versions, Secret contents, pods and Plane generations identical ([infisical-idempotency-1.txt](evidence/runs/infisical-idempotency-1.txt), [infisical-idempotency-2.txt](evidence/runs/infisical-idempotency-2.txt)).

The other branch is destructive to local state. If `GET /api/v1/admin/config` reports `initialized: false`, the script assumes a fresh instance. It moves `infisical-admin.json`, `infisical-machine.json` and `infisical-admin-password` to `.local/secret-zero/archive-<stamp>/`, moves the Terraform state aside, creates a new admin, new projects and new identities, and seeds new values including a new `SECRET_KEY`.

So never run the plain bootstrap against an empty Infisical that you intend to restore. `make restore-clean` does the order, and while `.local/restore-clean.state` exists the script refuses that branch. `INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh` is restored mode: same credentials, new cluster CA through Terraform, identity Secrets published, no value written. It refuses a fresh instance, a token the server rejects, Terraform wanting to create or delete anything, or a missing secret. On the live instance it gave "No changes" and wrote nothing ([dr-restored-bootstrap-1.txt](evidence/runs/dr-restored-bootstrap-1.txt), [dr-restored-bootstrap-2.txt](evidence/runs/dr-restored-bootstrap-2.txt)). On the real new cluster of 2026-11-05 Terraform changed 2 resources and created and deleted none, the seed wrote nothing, and both identity Secrets were published. A second run, in restored mode and plain, then found nothing to change or write ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log), stages 5 and 7). [disaster-recovery.md](disaster-recovery.md#full-restoration-into-a-clean-environment) gives the order.

## What lives in `.local/secret-zero`

The directory is mode 0700, files are 0600, and `.local/` is gitignored. No script copies this directory off the machine. That is a manual duty, and the whole recovery story depends on it. No backup copies these files either. Each Infisical backup records their sha256 in `recovery/set.json`, and a restore finds them by that, here or in any `archive-*` inside here. So this directory and `.local/backups/` both have to be kept. Apart is better, and one encrypted archive of both is the tradeoff accepted here, as [disaster-recovery.md](disaster-recovery.md#before-anything-fails) says.

| File | Written by | Used for | If lost |
|---|---|---|---|
| `ENCRYPTION_KEY` | `secret-zero.sh`, `openssl rand -hex 16` | Encrypts Infisical's KMS root key, and so every secret in the database | Recoverable from Secret `infisical-secrets` while the cluster lives. **Unrecoverable once that is gone too** |
| `AUTH_SECRET` | `secret-zero.sh` | Signs JWTs | Recoverable from Secret `infisical-secrets` while the cluster lives ([infisical-secret-zero-1.txt](evidence/runs/infisical-secret-zero-1.txt)). Once that is gone too, a clean restore refuses before it touches anything, and a new value kills every session and token |
| `DB_PASSWORD` | `secret-zero.sh` | Infisical's Postgres | Recoverable from Secret `infisical-db` |
| `REDIS_PASSWORD` | `secret-zero.sh` | Infisical's Redis | Recoverable from Secret `infisical-redis` |
| `infisical-admin.json` | Bootstrap, or a script that replaced an ended token | Admin token, org id. The token carries a JWT expiry capped at 90 days | A password login makes another. See [Recovery](#recovery) |
| `infisical-admin-password` | Bootstrap, before the call, because the route works once | First admin's UI password | The token still works until it ends. After that a person needs a copy |
| `infisical-admin-token.new` | A person, after a sign-in, one line | There only until a script has checked it against the server and moved it into place | |
| `infisical-admin-replaced.log` | Each replacement of `infisical-admin.json` | When, why, how, and the sha256 before and after. No token | Nothing depends on it. It is the record |
| `infisical-machine.json` | Bootstrap, from Terraform outputs | Project ids, identity ids. Not secret, but 0600 like the rest | Rerun bootstrap. A restore rebuilds it from the backup's Terraform state |
| `rotation-<env>/` | `rotate.sh` | Old and new password in plaintext, only while a rotation is stopped partway | That rotation cannot be resumed automatically |
| `archive-<stamp>/` | `secret-zero.sh REGENERATE`, bootstrap on a fresh instance | Files moved aside, never deleted | |
| `archive-token-<time>/`, `archive-pre-restore-<time>/` | A token replacement, a restore | The admin file or machine file taken over from, so a restore can still find it by checksum | |

`secret-zero.sh` reuses existing files. It restores a missing one from the cluster when it can. It refuses to replace a differing `ENCRYPTION_KEY` in the cluster without `CONFIRM=yes`. It replaces the whole set only with `REGENERATE=yes CONFIRM=yes`, which is meant for an empty database, because Postgres keeps its old password until its volume is recreated.

The six Plane Secrets contain no secret zero. The seed generates values in memory, sends them, and keeps no copy. Infisical's database plus `ENCRYPTION_KEY` is the whole recovery set for them.

Terraform state in `.local/terraform/infisical/` is not in this directory, yet recovery also needs it. `make destroy` keeps it, and each Infisical backup copies it to `recovery/terraform.tfstate`, because state and database are a pair. See [Recovery](#recovery).

## Projects and the secret layout

Two projects, `plane-dev` and `plane-prod-sim`, each with one environment, slug `prod`, and flat keys at path `/`. The slug is the same in both so one `InfisicalStaticSecret` shape fits both. Default environments are off.

Why one project per environment: custom roles and folder RBAC are paid features. One project with two environments could not stop a reader of one environment from reading the other. Two projects can.

| Infisical key | Generated as | Feeds |
|---|---|---|
| `PG_USER`, `PG_DB` | Literal `plane`. Identifiers, so no quoting in SQL | `plane-pgdb`, `plane-app-env` |
| `PG_PASSWORD` | `openssl rand -hex 24` | `plane-pgdb`, `plane-app-env` |
| `RABBITMQ_USER` | Literal `plane` | `plane-rabbitmq`, `plane-app-env` |
| `RABBITMQ_PASSWORD` | `openssl rand -hex 24` | `plane-rabbitmq`, `plane-app-env` |
| `SILO_ACCESS_KEY` | `openssl rand -hex 10` | `plane-doc-store` |
| `SILO_SECRET_KEY` | `openssl rand -hex 20` | `plane-doc-store` |
| `SECRET_KEY` | `openssl rand -hex 32` | `plane-app-keys` |
| `LIVE_SERVER_SECRET_KEY` | `openssl rand -hex 32` | `plane-app-keys` |

Passwords are hex because the chart and the templates do not URL-encode into connection strings. The seed uses one batch write and 3 requests per environment. The research named a limit of 40 secret requests per minute per client IP, but v0.167.6 registers the limiter only on Infisical Cloud (`app.ts`), and 240 reads in 4 s from one address all answered 200 ([infisical-rate-limit-1.txt](evidence/runs/infisical-rate-limit-1.txt)).

## Machine identities and Kubernetes Auth

Each project has one identity, `plane-dev-reader` and `plane-prod-sim-reader`. Org role `no-access`. Project role built-in `viewer`.

Each identity authenticates through Kubernetes Auth:

| Setting | Value | Why |
|---|---|---|
| `token_reviewer_mode` | `api` | Infisical calls the API server's TokenReview |
| `kubernetes_host` | `https://kubernetes.default.svc.cluster.local` | As Infisical sees it from inside the cluster |
| `kubernetes_ca_certificate` | From ConfigMap `kube-root-ca.crt` | Supplying it turns TLS verification on. A new cluster has a new CA |
| `token_reviewer_jwt` | Unset | The client's token reviews itself, so no long-lived reviewer JWT exists anywhere |
| `allowed_namespaces` | The environment's own namespace | Binds the identity to one namespace |
| `allowed_service_account_names` | `plane-infisical-auth` | Binds it to one ServiceAccount |
| `allowed_audience` | Unset | A token minted for another audience could not authenticate to the API server, and that token does the review |
| `access_token_ttl`, `access_token_max_ttl` | 3600 s | The operator logs in again at 70% of this. Non-wildcard trusted IPs are paid, so short TTLs do that job |

The login flow: the operator mints a short-lived token for `plane-infisical-auth`, Infisical sends it to TokenReview, checks namespace and name, and returns an access token.

Three costs come with this choice:

- `plane-infisical-auth` needs `system:auth-delegator`, a ClusterRoleBinding in `infisical/manifests/token-reviewer.yaml`, which grants only `tokenreviews` and `subjectaccessreviews` create. No pod runs as this account. It sets `automountServiceAccountToken: false`.
- The server pod needs egress to the API server. kindnet sees that as the node IP on 6443, so the policy allows `172.16.0.0/12` on 6443.
- `ALLOW_INTERNAL_IP_CONNECTIONS=true` is set, because token review goes through a safe-request path that rejects private IPs, and `kubernetes.default.svc` is a private IP on kind. This relaxes SSRF protection for the whole instance. It is acceptable on a single-user local instance and needs a new decision for Pass 2.

Login works on kind under default-deny. The operator logs in and caches for 42 m, 70% of the TTL. A wrong CA is refused with "SSL certificate verification failed", so verification is on, and the API server's certificate covers `kubernetes.default.svc.cluster.local` ([infisical-k8s-auth-tls-1.txt](evidence/runs/infisical-k8s-auth-tls-1.txt), [infisical-isolation-2.txt](evidence/runs/infisical-isolation-2.txt)). The dev operator logged in again 42m17s after its first login, with 0 errors in the 24 reconciles around it ([infisical-token-renewal-1.txt](evidence/runs/infisical-token-renewal-1.txt)).

An identity id is not a credential, since login also needs a token for the ServiceAccount. It still sits in a Secret, because the CRD accepts only a Secret reference, and it changes on every re-bootstrap, so it cannot be rendered into Git.

## Static secret CRDs

Each Plane overlay, `helm/plane/overlays/<env>/infisical.yaml`, holds three kinds of resource:

| Kind | Sync wave | Role |
|---|---|---|
| `InfisicalConnection` | -3 | Address `http://infisical.infisical.svc.cluster.local:8080/api`. Always set, because empty falls back to the chart's `hostAPI`, whose default is Infisical Cloud |
| `InfisicalAuth` | -2 | Method `kubernetes`, identity from Secret `plane-infisical-identity`, ServiceAccount `plane-infisical-auth` |
| `InfisicalStaticSecret`, 6 of them | -1 | Source: project, slug `prod`, path `/`. Target: one Secret, `creationPolicy: Owner`, `refreshInterval: 60s` |

Details that exist because of a specific failure:

- **Templates use `secretFrom`, not `.KEY.Value`.** With `secretFrom` a missing key fails the reconcile and the CR goes Degraded. `.KEY.Value` renders a literal `<no value>` and reports success (operator issue 121), and a database would accept that as a password. `rotate.sh` also refuses to run if any Plane Secret contains that literal.
- **`targets[].metadata` is explicit.** It stops the operator copying the CR's labels and annotations, including Argo CD's tracking id, onto the Secret.
- **A target with a template gets only its template's keys.** No Secret carries a key it does not need.
- **Argo CD health is custom Lua** in `helm/values/argocd.yaml`. `InfisicalStaticSecret` is Healthy only when `status.observedGeneration` matches and `status.error` is not true. `InfisicalAuth` and `InfisicalConnection` read the `secrets.infisical.com/IsReady` condition. Wave 1 and later wait on this.

All 6 `InfisicalStaticSecret` reconcile in both namespaces, and each rendered Secret holds exactly the keys of contract section 8, with no empty or `<no value>` value and nothing shared across environments. The check fails on a tampered Secret, and the operator repaired that one in 9 s ([infisical-rendered-secrets-1.txt](evidence/runs/infisical-rendered-secrets-1.txt), [infisical-tamper-1.txt](evidence/runs/infisical-tamper-1.txt)). `make test-infisical` runs it again.

The Lua checks, run through `argocd admin` in the real server pod, read Healthy on the real CRs and Degraded on a failing one ([argocd-lua-infisical-live-1.txt](evidence/runs/argocd-lua-infisical-live-1.txt)).

Argo CD fails the sync and retries it. While `InfisicalAuth` is unready, a Plane sync fails at wave -2 and retries, every 5 minutes once backed off. After bootstrap publishes the identity Secret the CR turns Ready within a second, but the sync moves on only at its next retry, which took 3m10s on the first run ([infisical-unready-sync-1.txt](evidence/runs/infisical-unready-sync-1.txt)).

Instant updates are paid, so the operator polls. `refreshInterval` is the propagation delay, up to 60 s. Each operator polls 6 CRs per minute from its own pod IP.

### Two operators, not one

There is one operator release per Plane namespace, each with `scopedRBAC: true` and `scopedNamespaces` set to its namespace. In cluster mode a single operator could mint a token for any ServiceAccount and read every Secret, and nothing would stop an `InfisicalAuth` in `plane-dev` from referencing the prod-sim identity.

Scoped mode still renders three cluster-scoped objects per release. The chart truncates its fullname to 15 characters, so both release names would collide. `fullnameOverride` sets `iso-dev` and `iso-prod-sim`. Both deploy under the `platform` project, the only one allowed cluster-scoped objects.

## Auto-reload

The annotation `secrets.infisical.com/auto-reload: "true"` sits on the workload's own metadata, not the pod template, on `plane-api-wl`, `plane-worker-wl`, `plane-beat-worker-wl`, `plane-live-wl` and `postgres-exporter`.

From the operator source at v0.11.16: when a target Secret really changes, the operator merge-patches `secrets.infisical.com/managed-secret.<hash>` with the new etag into the workload and pod template annotations, which causes a normal rolling update. It covers Deployment, DaemonSet and StatefulSet, not Jobs. An operator restart causes no rollout. The patch is attempted only in the reconcile that changed the Secret.

| Workload | Annotated | Why |
|---|---|---|
| api, worker, beat, live | Yes | Read connection strings from env at start |
| Postgres, RabbitMQ | No, on purpose | `POSTGRES_PASSWORD` and `RABBITMQ_DEFAULT_*` act only on an empty data directory, so a restart achieves nothing and causes an outage |
| Migrator Job | Not supported | A Job is not restarted. It reads the current Secret on its next run |
| `postgres-exporter` | Yes, in `monitoring/manifests/environments/base/exporters.yaml` | Reads `plane-pgdb` at start, so without a restart it would keep the old password after a rotation, and `PlanePostgresDown` could fire on a healthy Postgres. In the dev rotation the operator restarted it by 07:23:49Z, `pg_up` stayed 1 at every 15 s reading, and `PlanePostgresDown` did not fire in dev ([SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt)) |

The operator's template annotation did not cause a sync loop in the dev rotation. `plane-dev` stayed Synced, went Progressing at 07:23:47Z and Healthy at 07:24:28Z, and the rotation started no sync operation ([SEC-6-20261105T072331Z-application-watch.txt](evidence/runs/SEC-6-20261105T072331Z-application-watch.txt)). The file runs to 07:40:51Z, 16 minutes after the rollouts. The one operation in it came at 07:32:41Z, from a replica change made on purpose to test self-heal ([GITOPS-4-20261105T073240Z.txt](evidence/runs/GITOPS-4-20261105T073240Z.txt)). The api, worker and beat generations did not move again in the watcher's readings to 07:40:17Z ([SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt)). The script watches them for only 20 s ([rotate-dev-20261105T072345Z.log](evidence/runs/rotate-dev-20261105T072345Z.log)). At the first sync, on 2026-11-04, `postgres-exporter` in prod-sim read generation 2 and one etag at 21:52Z, so the operator had patched it once ([infisical-operator-restart-1.txt](evidence/runs/infisical-operator-restart-1.txt)). `monitoring-extras` read Synced and Healthy in every sample from 21:05Z to 22:19Z, while the exporter waited for `plane-pgdb` and after ([monitoring-ignore-healthcheck-1.txt](evidence/runs/monitoring-ignore-healthcheck-1.txt)).

`rotate.sh` tests that loop by comparing workload generations for 20 s after the rollout. If the operator did not mark every pod template within 120 s, the script restarts the workloads itself and records it.

## Rotation

```bash
make rotate ENV=dev
make rotate ENV=prod-sim CONFIRM=yes
scripts/rotate.sh ENV=dev RESUME=yes
scripts/rotate.sh ENV=dev ROLLBACK=yes
```

**`make rotate` has run in both environments on 2026-11-05, with the owner's approval, and every proof reads PASS**: dev at 07:23Z ([SEC-2-20261105T072331Z.txt](evidence/runs/SEC-2-20261105T072331Z.txt), [rotate-dev-20261105T072345Z.log](evidence/runs/rotate-dev-20261105T072345Z.log)), prod-sim at 07:32Z ([SEC-3-BKP-3-20261105T073240Z.txt](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt), [rotate-prod-sim-20261105T073240Z.log](evidence/runs/rotate-prod-sim-20261105T073240Z.log)). An earlier dev attempt was refused by the session's permission system before anything ran ([SEC-2-20261105T062211Z-refused.txt](evidence/runs/SEC-2-20261105T062211Z-refused.txt)). `RESUME=yes` has finished one killed rotation, and `ROLLBACK=yes` has undone another, both in prod-sim ([SEC-4b-20261105T084615Z.txt](evidence/runs/SEC-4b-20261105T084615Z.txt)).

**Why it is a script.** Secret rotation is a paid feature (`secretRotation: false` for unlicensed self-hosted, `license-fns.ts` at v0.167.6). So this is scripted rotation of one value, `PG_PASSWORD`. It is not native rotation, scheduled rotation, or per-pod credentials. Dynamic secrets are paid too. `PG_PASSWORD` was chosen because the role can be changed in place and the old value can be shown to fail.

**Order of operations:**

1. Preflight. Infisical, both Secrets and Postgres agree. Plane answers. Every consumer of `plane-app-env` carries auto-reload. A random password is rejected, so the rejection proof means something.
2. Write old and new values to the journal `.local/secret-zero/rotation-<env>/`, then write the new one to Infisical as a new version.
3. Nudge the CRs by annotation and wait for the operator to update `plane-pgdb` and `plane-app-env`. The operator starts restarting Plane at this point.
4. `ALTER ROLE` over the Unix socket, with the statement on stdin and logging suppressed for the session.
5. Wait for the rollouts, then record the proofs.
6. Take an Infisical backup, because an older dump holds the old `PG_PASSWORD`. `SKIP_BACKUP=yes` skips it. If it fails, the rotation stands and the script exits 3.

Step 3 precedes step 4 because the operator owns the restart. From `ALTER ROLE` until the new api pod is ready, Plane has no pod that can log in, which is the error window.

**Proofs written to `.local/evidence-raw/rotate-<env>-<stamp>.log`, which holds no values:**

| Proof | How | Trap avoided |
|---|---|---|
| Old rejected, new accepted | Login over the pod IP | The image's `pg_hba.conf` trusts the socket and 127.0.0.1, so a login there accepts any password |
| The test can fail | Random password rejected first | |
| Plane uses a new connection | `/api/public/anchor/__probe__/settings/` returns 404 "does not exist" | `/api/instances/` is cached in Valkey for two hours. In the three Postgres rounds of the pod restart drill on upstream images on 2026-11-04, each under a minute, the probe route answered 500 for one 15 s sample while `/api/instances/` stayed 200 ([monitoring-history-reads-1.txt](evidence/runs/monitoring-history-reads-1.txt)). On the final images in dev a signed-in request answered 500 for about 7 s, and no 15 s probe reading caught it ([PERS-1-20261105T070358Z-watch.txt](evidence/runs/PERS-1-20261105T070358Z-watch.txt)). A longer outage has not been tried |
| Plane rolled | Pod template names the Secret's new version, `rollout status` finishes | |
| Postgres untouched | Pod start time compared before and after | |
| `SECRET_KEY` unchanged | Value compared before and after | |
| Error window | A probe every second | It is anonymous, so Plane's throttle can count as failure. See below |
| No fight with Argo CD | Generations stable after the rollout | |

**What the dev rotation showed.** `PG_PASSWORD` went from version 1 to 2 and the operator synced both Secrets in 4 s. The rollouts finished at 07:24:28Z, with no restart by hand. Postgres was not restarted, `SECRET_KEY` did not change, and the Infisical backup at the end succeeded. An independent check, which held the old password in memory, found it refused over the pod IP and over the Service, the new one accepted, a random one refused, and all three Deployments holding the new value ([SEC-2-20261105T072331Z-old-value.txt](evidence/runs/SEC-2-20261105T072331Z-old-value.txt)). `plane-live-wl` does not consume `plane-app-env`, so it was not restarted. Prod-sim's sign-in page answered 200 throughout, while its own pod restart drill ran. This run says nothing about a rotation that stops partway.

**What the prod-sim rotation showed.** The same proofs in the same order: version 1 to 2, the operator synced in 4 s, `ALTER ROLE` by 07:32:47Z, Postgres refused the replaced password, the rollouts finished at 07:33:25Z, Postgres was not restarted, `SECRET_KEY` did not change, and the Infisical backup at the end succeeded ([rotate-prod-sim-20261105T073240Z.log](evidence/runs/rotate-prod-sim-20261105T073240Z.log)). These are the script's own checks. No independent check and no signed-in watcher ran beside this one.

The proofs use the pod IP because `scripts/rotate.sh` takes the image's `pg_hba.conf` to trust the socket and 127.0.0.1, where a login would accept any password. No file here records a reading of `pg_hba.conf`, so the negative control is what stands: Postgres refused a random password, then the replaced one, over the pod IP ([rotate-dev-20261105T072345Z.log](evidence/runs/rotate-dev-20261105T072345Z.log), [rotate-prod-sim-20261105T073240Z.log](evidence/runs/rotate-prod-sim-20261105T073240Z.log)). The rotation's own `ALTER ROLE` ran over the socket with no password.

**The error window in dev was about 38 s, not the 60 s the script printed.** A signed-in request once a second, outside the anonymous limit, answered 500 from 07:23:51Z to 07:24:29Z: of the 1002 readings in the file, 38 answered 500 and 964 answered 200 ([SEC-2-20261105T072331Z-watch.txt](evidence/runs/SEC-2-20261105T072331Z-watch.txt)). The file's first session row, at 07:23:31Z, is the watcher's own "signed in" note, 14 s before `make rotate` started, so it is not part of the window. So the window is the new api pod's start, after the role changed. The script reported 60 s from first to last failed probe, 39 of 62 ([rotate-dev-20261105T072345Z.probe](evidence/runs/rotate-dev-20261105T072345Z.probe)). Its first 36 failures match that window. Its last three, at 07:24:48Z to 07:24:50Z, came while the signed-in request answered 200, which fits the anonymous throttle: the 31st request in a minute to this route got 429 ([SEC-2-throttle-precheck-20261105T061924Z.txt](evidence/runs/SEC-2-throttle-precheck-20261105T061924Z.txt)). The probe log keeps no status code, so that cause is not proven. No Plane alert reached firing in dev: `PlaneApiDatabaseProbeFailing` and `PlaneApiDown` stayed pending.

**In prod-sim the script printed 39 s, 37 of 60 probes.** The failures were one unbroken run from 07:32:48Z to 07:33:26Z, with no late failures this time, and that run matches `ALTER ROLE` and the end of the rollouts ([rotate-prod-sim-20261105T073240Z.log](evidence/runs/rotate-prod-sim-20261105T073240Z.log), [rotate-prod-sim-20261105T073240Z.probe](evidence/runs/rotate-prod-sim-20261105T073240Z.probe)). No signed-in reading ran beside it, so this number rests on the anonymous probe alone.

**What this does not cover:**

- The role is a shared superuser. One credential for all Plane components.
- In-flight Jobs keep their old environment.
- Audit logs are not stored on this tier (`auditLogsRetentionDays: 0`). Secret version history is the only trail.
- Changing `PG_PASSWORD` by hand in the UI does not change the role. The next Plane restart then fails. Only `ROLLBACK=yes` keeps both sides together.
- A dump of Infisical taken before a rotation holds the old password. Restoring it in place makes Infisical and the Postgres role disagree, so `make restore ENV=infisical` refuses it unless `ALLOW_STALE_PLANE_SECRETS=yes`. A clean restore does not care: Plane's Postgres initializes with whatever Infisical says, and a dump carries no role password.

If it stops partway, the script prints what Infisical, the Secret and Postgres each hold. `RESUME=yes` finishes and `ROLLBACK=yes` undoes. Both run the same steps against real state, so running either twice is meant to be safe.

**One stopped rotation has been recovered.** In prod-sim on 2026-11-05 a rotation was killed with SIGKILL 4 s in, after `ALTER ROLE`, while it waited for the operator's restart. `RESUME=yes` finished it: Postgres took the new password and refused the replaced one, the rollouts finished at 07:39:21Z, `SECRET_KEY` did not change, and it exited 0 ([SEC-4-20261105T073843Z.txt](evidence/runs/SEC-4-20261105T073843Z.txt), [rotate-prod-sim-20261105T073847Z.log](evidence/runs/rotate-prod-sim-20261105T073847Z.log)). The resume ran with `SKIP_BACKUP=yes` and took no Infisical backup, so the newest dump held the previous password until `20261105T074912Z`.

**One stopped rotation has been undone.** On the restored cluster on 2026-11-05 another rotation of prod-sim was killed with SIGKILL 4 s in, after `ALTER ROLE`, with `PG_PASSWORD` at version 4. `ROLLBACK=yes` wrote the journal's old password as version 5, and the operator synced in 4 s. Postgres took that password and refused the replaced one, the rollouts finished at 08:47:03Z, 43 s after it began, Postgres was not restarted, `SECRET_KEY` did not change, and it exited 0 ([SEC-4b-20261105T084615Z.txt](evidence/runs/SEC-4b-20261105T084615Z.txt), [rotate-prod-sim-20261105T084620Z.log](evidence/runs/rotate-prod-sim-20261105T084620Z.log)). The script printed 36 s, 12 of 61 probes, in two stretches, 08:46:20Z to 08:46:23Z and 08:46:46Z to 08:46:55Z ([rotate-prod-sim-20261105T084620Z.probe](evidence/runs/rotate-prod-sim-20261105T084620Z.probe)), with no signed-in reading beside it. It ran with `SKIP_BACKUP=yes` and took no Infisical backup. Nothing independent compared that password with the one before the rotation.

Each of those is one stop at one point. A stop between the Infisical write and `ALTER ROLE`: Not tested in Pass 1. Running either one twice: Not tested in Pass 1.

**Up to `6935b77`, SIGKILL left the script's probe loop running.** The first killed run's loop went on writing [rotate-prod-sim-20261105T073843Z.probe](evidence/runs/rotate-prod-sim-20261105T073843Z.probe). The raw file's last line is at 07:53:32Z, about 15 minutes after the kill, and the copy committed so far reaches 07:48:34Z. The file holds one unbroken run of 36 failures from 07:38:45Z to 07:39:22Z, which matches the role change and the rollouts. The resume's own line, 57 s and 46 of 55, is likely too long: two probes were spending one anonymous limit, and its last 12 failures came after the script's database-backed check had passed. The probe log keeps no status code, so that cause is not proven. The second kill's run stopped its loop by hand. Since `6f4077b` the loop checks that the script is alive, so it should end within a second of a SIGKILL, which has run only on stubs. After a hard stop, `pgrep -fl rotate.sh` still shows whether anything is left.

## What is never rotated, and why

| Value | Decision | Why |
|---|---|---|
| Plane `SECRET_KEY` | **Never** | It derives the Fernet key for encrypted instance configuration rows. `decrypt_data` fails silently to `""` on a wrong key, so SMTP and OAuth settings vanish with no error. Auto-reload on `plane-api-wl` is safe only because this key does not change |
| `LIVE_SERVER_SECRET_KEY` | Not rotated | `live` requires it to be set (`apps/live/src/env.ts`), and nothing uses it at v1.4.3: `requireSecretKey` is defined and never used on a route (`apps/live/src/lib/auth-middleware.ts` in Plane v1.4.3). Rotating it would prove nothing |
| `ENCRYPTION_KEY` | Not rotated in Pass 1 | No procedure exists. After a key rotation, older dumps would need the older key (Infisical docs, v0.164 and later). Each dump's manifest records a truncated hash of the key in use, so a mismatch is detectable |
| `AUTH_SECRET` | Not rotated in Pass 1 | No procedure exists. Changing it kills every session and token, including the admin token |
| Infisical `DB_PASSWORD`, `REDIS_PASSWORD` | Not rotated in Pass 1 | `REGENERATE=yes` is only for an empty database |
| `RABBITMQ_PASSWORD`, `SILO_*` | Not rotated in Pass 1 | Separate procedures that nothing implements. The env values act only on an empty data directory |

## Free-tier limits and what they forced

Read from `license-fns.ts` and its enforcement sites at v0.167.6. An unlicensed self-hosted instance differs from the Cloud pricing page.

| Limit | What it forced |
|---|---|
| Custom roles and folder RBAC are paid. Additional privileges return 400 on projects created today | One project per environment, built-in `viewer`, org role `no-access`. A reader sees every secret in its environment and nothing in the other |
| Secret rotation is paid | `scripts/rotate.sh`, with an error window |
| Dynamic secrets are paid | One shared Postgres role |
| Audit logs are not stored | Who read what cannot be shown |
| Instant updates are paid | The operator polls every 60 s |
| None for rate limits. The research named 40 secret requests, 60 reads and 200 writes per minute, but v0.167.6 registers the limiter only on Infisical Cloud, and 240 reads in 4 s all answered 200 ([infisical-rate-limit-1.txt](evidence/runs/infisical-rate-limit-1.txt)) | The seed still uses one batch, and scripts still honour `Retry-After` on 429, in case a later version applies a limit. That path has never run |
| Non-wildcard trusted IPs are paid | 1 hour token TTL |
| Gateway reviewer is paid | The client JWT reviews itself |

## Recovery

| Situation | Result | Do this |
|---|---|---|
| Server pod lost | Stateless, rescheduled | Nothing |
| Redis lost | Queued jobs, schedules and caches. While it is down the API does not answer, for about 12 s in the restart test ([infisical-restart-1.txt](evidence/runs/infisical-restart-1.txt)) | Nothing |
| Operator pod lost | Existing Secrets stay. Sync pauses until it returns | Nothing |
| Infisical down, Plane running | Plane keeps running on its existing Kubernetes Secrets, and Plane pods should still start, for the same reason. Rotation and new Secrets stop. Across in-place restores with the server down for 39 s to 52 s, every Plane pod uid and restart count, workload generation and Secret resourceVersion stayed the same, apart from probe pods of another test and one worker another test replaced ([dr-inplace-restore-3.txt](evidence/runs/dr-inplace-restore-3.txt), [dr-inplace-no-token-no-password-2.txt](evidence/runs/dr-inplace-no-token-no-password-2.txt), [dr-inplace-no-token-no-password-3.txt](evidence/runs/dr-inplace-no-token-no-password-3.txt)). A Plane pod restarted on purpose during an outage: Not tested in Pass 1 | Restore service |
| `ENCRYPTION_KEY` file lost, cluster alive | Recoverable | `scripts/secret-zero.sh` restores it from the cluster |
| `ENCRYPTION_KEY` lost everywhere | **Secrets are gone**, even with the database dump | New instance, new values. `SECRET_KEY` is gone too, so see [disaster-recovery.md](disaster-recovery.md#path-b-encryption_key-is-lost) |
| Postgres lost, key kept, dump exists | Recoverable | `make restore ENV=infisical BACKUP=<id> CONFIRM=yes` on the same or a newer image with the same key, then `INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh`. See [disaster-recovery.md](disaster-recovery.md#scenario-infisical-lost) |
| Postgres lost, no dump | All secret values gone | As `ENCRYPTION_KEY` lost |
| Cluster and everything in it gone | New CA must reach Kubernetes Auth, and the data must come back | `make restore-clean BACKUP=latest`, which read PASS on a new cluster on 2026-11-05. See [disaster-recovery.md](disaster-recovery.md#full-restoration-into-a-clean-environment) |
| Cluster recreated with `make up`, data not wanted back | New instance, new secrets | Bootstrap detects `initialized=false` and moves the old files aside, never deleting them |
| `infisical-admin.json` lost, instance initialized | Bootstrap's own route works once, so it cannot make another | `scripts/infisical-bootstrap.sh` signs in with `infisical-admin-password`, mints a token for the instance admin identity and records it. Run through the API on the live instance ([dr-mint-1.txt](evidence/runs/dr-mint-1.txt)). With no password it stops with the steps for a person, whose labels were read from this image's frontend build and not yet clicked through |
| Admin token expired | 90 day cap. Scripts warn in the last 7 days. A backup or `make up` then replaces it the same way, and anything else refuses and says so. `RENEW_ADMIN_TOKEN=yes scripts/infisical-bootstrap.sh` does it ahead of time | As above. A token that has really ended has run only on stubs |
| Admin token and password both gone | Nothing here can log in, and the instance and its secrets are fine | Write a new bcrypt hash into the restored database, as [`infisical/README.md`](../infisical/README.md#admin-token-and-password-both-gone) shows. Run in place on 2026-11-05 ([dr-inplace-no-token-no-password-1.txt](evidence/runs/dr-inplace-no-token-no-password-1.txt), [dr-inplace-no-token-no-password-2.txt](evidence/runs/dr-inplace-no-token-no-password-2.txt), [dr-inplace-no-token-no-password-3.txt](evidence/runs/dr-inplace-no-token-no-password-3.txt)), not on a clean restore |
| Terraform state lost, instance alive | Terraform would try to create what exists, and bootstrap runs Terraform unconditionally, so it fails before publishing identity ids | Copy `recovery/terraform.tfstate` from the newest Infisical backup. With no backup, import each resource, or start from a fresh instance. A destroyed project keeps its slug for 14 days. `terraform import` of these resources at provider 0.20.10: Not tested in Pass 1 |
| Rotation stopped partway | Plane may be failing | `RESUME=yes` or `ROLLBACK=yes`. Each has run once. See [Rotation](#rotation) |

Infisical's migrations run forward only. An older image refuses to start on a newer schema, so a Helm rollback alone does not restore it. A restore must use the same or a newer image.

`scripts/backup.sh` deliberately writes only a truncated hash of `ENCRYPTION_KEY` to the manifest, so no dump holds its key. Keeping the key apart from the dumps is better, for example in a password manager. One encrypted archive of both, as [disaster-recovery.md](disaster-recovery.md#before-anything-fails) shows, is the tradeoff accepted on this local platform.

A restored Plane database needs the `SECRET_KEY` it was written with. `SECRET_KEY` lives in Infisical. So Infisical and Plane restore as a matched set, Infisical first. `scripts/restore.sh` compares the fingerprint and refuses a mismatch unless `ALLOW_SECRET_KEY_MISMATCH=yes`.

An in-place Infisical restore has run seven times, 44 s to 71 s in all. Six read PASS. One read BLOCKED, the 71 s, because that run removed the token and the password on purpose ([dr-inplace-no-token-no-password-2.txt](evidence/runs/dr-inplace-no-token-no-password-2.txt)). The first two took 47 s and 44 s ([dr-inplace-restore-1.txt](evidence/runs/dr-inplace-restore-1.txt), [dr-inplace-restore-2.txt](evidence/runs/dr-inplace-restore-2.txt)). In the last five the server did not answer for 39 s to 52 s by a probe once a second, and the 52 s is that same BLOCKED run ([dr-inplace-restore-3.txt](evidence/runs/dr-inplace-restore-3.txt), [dr-inplace-token-lost-1.txt](evidence/runs/dr-inplace-token-lost-1.txt), [dr-inplace-token-back-1.txt](evidence/runs/dr-inplace-token-back-1.txt), [dr-inplace-no-token-no-password-3.txt](evidence/runs/dr-inplace-no-token-no-password-3.txt)). Afterwards `make test-infisical` exited 0 with 118 PASS lines, and all 14 Applications were Synced and Healthy ([dr-after-restores-1.txt](evidence/runs/dr-after-restores-1.txt)).

The restore into a new cluster ran on 2026-11-05, onto a brand-new server, with result PASS, in 43 s, with the server not answering for 34 s. Gate 1 matched all 785 tables. The file the backup names was accepted as the admin token, and `proof-values` read every Plane secret at the value, version and id the backup recorded ([restore-infisical-20261105T081608Z.json](evidence/runs/restore-infisical-20261105T081608Z.json)). Under a new cluster CA the operators then rendered all 38 keys with their old values, and the organization, project and identity ids, secret zero and the admin password were the old ones, with nothing archived ([log](evidence/runs/drill-clean-restore-20261105T074859Z.log), stage 6). On that cluster `make test` passed isolation and rendered Secrets, 116 rows in all ([infisical-isolation-20261105T083455Z-37296.txt](evidence/runs/infisical-isolation-20261105T083455Z-37296.txt), [infisical-rendered-secrets-20261105T083455Z-37296.txt](evidence/runs/infisical-rendered-secrets-20261105T083455Z-37296.txt)). That was the first of three, each from a backup taken moments before the delete. It ran before the fixes under [Off the normal path](disaster-recovery.md#off-the-normal-path). The later two ran with them and took none of those paths, which have run only on stubs.

## Least-privilege evidence

`make test-infisical` runs `infisical/tests/isolation.sh` and `infisical/tests/rendered-secrets.sh`: real logins and reads with the same ServiceAccount tokens the operators use, from the host and from inside each namespace. Every 403 is checked against a positive control with the same token, so a wrong project id or a dead token cannot pass as isolation. It prints status codes and the server's messages, and no token or value.

| # | Claim | Test | Expected | Result |
|---|---|---|---|---|
| L1 | Dev reader lists its own project | `make test-infisical` | 200 | PASS, 200 |
| L2 | Dev reader cannot read prod-sim, and the other way round | Same: list, single read and slug lookup | 403 or 404 | PASS, 403 in both directions |
| L3 | Dev reader cannot write its own project | Same | 403. A success is a FAIL | PASS, 403. Asked of the dev reader only |
| L4 | Org role `no-access` reaches nothing at org level | Same: list the organization's identities | 403 | PASS, 403. Asked of the dev reader only |
| L5 | Wrong namespace cannot log in | Same: each namespace's account with the other's identity | 401 or 403 | PASS, 401 "K8s namespace not allowed" in both directions |
| L6 | Wrong ServiceAccount cannot log in | Same: `plane-dev/default` and `plane-dev/iso-dev-controller-manager` with the dev identity | 401 or 403 | PASS, 401. A forged token also gets 401 |
| L7 | Dev operator cannot read prod-sim Secrets, and the other way round | `kubectl auth can-i` below | `no` | PASS, `no` |
| L8 | Dev operator cannot mint tokens in prod-sim, and the other way round | `kubectl auth can-i` below | `no` | PASS, `no` |
| L9 | Workloads hold no API token | `policy/workloads.rego` denies a rendered workload without `automountServiceAccountToken: false`, except the two operators | No exception | PASS on rendered manifests, in `make ci`. Running pods have not been read |
| L10 | Rendered manifests hold no Secret | `make ci`, conftest rule in `policy/gitops.rego` | Passes | PASS |

L1 to L6: [infisical-isolation-2.txt](evidence/runs/infisical-isolation-2.txt), [infisical-isolation-3.txt](evidence/runs/infisical-isolation-3.txt), [infisical-isolation-20261104T232524Z.txt](evidence/runs/infisical-isolation-20261104T232524Z.txt), on the restored database [dr-after-restores-1.txt](evidence/runs/dr-after-restores-1.txt), and on the new cluster [infisical-isolation-20261105T083455Z-37296.txt](evidence/runs/infisical-isolation-20261105T083455Z-37296.txt). L7 and L8: [infisical-rbac-1.txt](evidence/runs/infisical-rbac-1.txt). L9 and L10: [ci-2-20261105T061644Z-make-ci.log](evidence/ci/ci-2-20261105T061644Z-make-ci.log), exit 0. These show the boundary the free tier allows, per project. A reader still sees every secret in its own environment.

```bash
SA=system:serviceaccount:plane-dev:iso-dev-controller-manager
kubectl --context kind-plane-platform auth can-i get secrets -n plane-prod-sim --as="$SA"                         # L7
kubectl --context kind-plane-platform auth can-i create serviceaccounts --subresource=token -n plane-prod-sim --as="$SA"  # L8
```

## Related documents

- [security.md](security.md): threat model and what is not protected.
- [data-operations.md](data-operations.md): backup contents and restore.
- [disaster-recovery.md](disaster-recovery.md): failure scenarios and full restoration.
- [platform-contract.md](platform-contract.md): the binding names.
- [`infisical/README.md`](../infisical/README.md): the layer's own notes, including the names other layers rely on.
