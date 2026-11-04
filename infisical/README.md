# Infisical

Secret store for both Plane environments. Infisical Community Edition v0.167.6 runs in the `infisical` namespace with its own Postgres and Redis, and two namespace-scoped operators copy values into each Plane namespace.

**Status: run on the real cluster on 2026-11-04, except `scripts/rotate.sh`.** [Measured](#measured) says what ran and what it showed. [Not yet proven](#not-yet-proven) lists the rest.

| Path | What it is |
|---|---|
| `manifests/` | Postgres, Redis, IngressRoute, the server's ServiceAccount, the token-review binding. A path source of the `infisical` Application |
| `terraform/` | Projects, the environment, machine identities, Kubernetes Auth. Separate root, state in `.local/terraform/infisical/` |
| `lib/api.sh` | Shared by the scripts below |
| `tests/isolation.sh` | Real logins and reads: each reader against its own project and the other one, from the host and from inside each namespace |
| `tests/rendered-secrets.sh` | The six Secrets in each namespace against contract section 8, without printing a value |
| `../helm/values/infisical*.yaml` | Server chart and the two operator releases |
| `../scripts/secret-zero.sh` | Creates what must exist before Infisical does |
| `../scripts/infisical-bootstrap.sh` | First admin, Terraform, seed, identity ids |
| `../scripts/infisical-seed.sh` | Plane secret values, first time only |
| `../scripts/rotate.sh` | The rotation demo |

## Bootstrap order

| # | Step | Who | Blocks until |
|---|---|---|---|
| 1 | Namespaces | `infrastructure/terraform` | |
| 2 | `scripts/secret-zero.sh` | Script. Needs step 1 | `infisical-db`, `infisical-redis`, `infisical-secrets` exist. Postgres and Redis wait in `CreateContainerConfigError` until then, then recover |
| 3 | `infisical` Application, wave -4 | Argo CD. Inside it: ServiceAccount -2, Postgres and Redis -1, server 0, IngressRoute 1 | First boot runs 602 migrations, 11.5s on this machine |
| 4 | `infisical-operator-dev` and `-prod-sim`, wave -3 | Argo CD | |
| 5 | `scripts/infisical-bootstrap.sh` | Script. Needs `http://infisical.localhost` | Terraform applied, secrets seeded, identity Secrets published |
| 6 | `plane-dev` wave -1, `plane-prod-sim` wave 0 | Argo CD | `InfisicalAuth` stays unready until step 5 publishes `plane-infisical-identity` |

Step 5 is not an Argo CD step because it needs the admin token, which never enters the cluster. It seeds before it publishes identity ids, so an operator cannot log in to an empty project.

While `InfisicalAuth` is unready, a Plane sync fails at wave -2 and Argo CD retries it, every 5 minutes once backed off. After step 5 the CR turns Ready within a second, because the operator watches the Secret, but the sync moves on only at its next retry. On the first run that took 3m10s. This is normal.

Steps 2 and 5 are idempotent, so rerun them on every `make up`. Step 5 finds the instance already bootstrapped, Terraform changes nothing, the seed writes nothing, and it picks up a new cluster CA if the cluster was recreated.

## Secret zero

Everything Infisical needs before it can answer lives in `.local/secret-zero/` (directory 0700, files 0600, gitignored) and nowhere in Git. This moves the problem to the laptop rather than solving it, which is the honest answer locally. Kubernetes Secrets are base64 in kind's etcd, unencrypted at rest.

| File | Used for | If lost |
|---|---|---|
| `ENCRYPTION_KEY` | Encrypts every secret in the database | **Unrecoverable once the cluster Secret is gone too.** Keep a copy off this machine |
| `AUTH_SECRET` | Signs JWTs | Sessions and tokens die. Identities log in again |
| `DB_PASSWORD`, `REDIS_PASSWORD` | Infisical's own data services | Recoverable from the cluster Secrets |
| `infisical-admin.json` | Admin token, org id. Written by bootstrap | See Recovery |
| `infisical-admin-password` | First admin's UI password. Written before the bootstrap call | Admin token still works |
| `infisical-machine.json` | Project and identity ids. Not secret | Rerun bootstrap |
| `rotation-<env>/` | Both passwords, only while a rotation is stopped partway | Rotation cannot be resumed automatically |

`secret-zero.sh` reuses existing files and restores a missing one from the cluster if it can. It refuses to replace a differing `ENCRYPTION_KEY` in the cluster without `CONFIRM=yes`, and replaces the whole set only with `REGENERATE=yes CONFIRM=yes`, which archives the old files first. Regenerating is meant for an empty database: Postgres keeps its old password until its volume is recreated.

The contract's six Plane Secrets contain no secret zero. Their values live only in Infisical. The seed generates them in memory, sends them, and keeps no copy, so Infisical plus `ENCRYPTION_KEY` is the whole recovery set for them.

Identity ids are not credentials, since login also needs a token for the ServiceAccount. They still sit in a Secret, `plane-infisical-identity`, because the CRD accepts only a Secret reference, and they change on every re-bootstrap, so they cannot be rendered into Git. Bootstrap applies them out of band, so the rendered manifests stay free of `kind: Secret`.

## Names other layers rely on

| Name | Where | Relied on by |
|---|---|---|
| `http://infisical.infisical.svc.cluster.local:8080` | Service `infisical`, from `infisical.fullnameOverride` | Operators, IngressRoute |
| `app=infisical-standalone,component=infisical` | Server pods | NetworkPolicy |
| `app.kubernetes.io/name=infisical-postgres`, `infisical-redis` | Data pods | NetworkPolicy |
| `app.kubernetes.io/name=secrets-operator` | Operator pods | NetworkPolicy |
| `infisical-db` (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) | Secret | `scripts/backup.sh` |
| `plane-infisical-auth` | ServiceAccount, from the Plane overlay | Terraform, `manifests/token-reviewer.yaml` |
| `plane-infisical-identity`, key `identityId` | Secret, from bootstrap | `InfisicalAuth` in the Plane overlay |

Bootstrap stops with a clear error if the rendered `InfisicalAuth` disagrees with the last two.

## Operators

Two releases, one per Plane namespace, each with `scopedRBAC=true`. In cluster mode one operator could mint a token for any ServiceAccount and read every Secret, and nothing would stop an `InfisicalAuth` in `plane-dev` from referencing the prod-sim identity.

Scoped mode still renders three cluster-scoped objects per release: ClusterRoles `*-metrics-auth-role` and `*-metrics-reader`, and ClusterRoleBinding `*-metrics-auth-rolebinding`. They grant only token and access reviews. So:

- **The releases would collide without `fullnameOverride`.** The chart truncates its fullname to 15 characters, so `infisical-operator-dev` and `infisical-operator-prod-sim` both become `infisical-opera`. Values set `iso-dev` and `iso-prod-sim`.
- **Only `infisical-operator-dev` installs CRDs.** The prod-sim manager crash-loops until they exist, then recovers.
- **Both deploy under the `platform` project**, which is the only one allowed cluster-scoped objects.

The ServiceMonitor stays off. Scraping needs a binding for Prometheus to the metrics-reader role, and the contract does not name operator metrics.

## Rotation

`make rotate ENV=dev`, or `scripts/rotate.sh ENV=dev`. Prod-sim also needs `CONFIRM=yes`.

1. Preflight: Infisical, both Secrets and Postgres agree, Plane answers, and a random password is rejected.
2. Write both passwords to the journal, then the new one to Infisical as a new version of `PG_PASSWORD`.
3. Nudge the CRs and wait for the operator to update `plane-pgdb` and `plane-app-env`. It starts restarting api, worker and beat at this point.
4. `ALTER ROLE` over the socket, with the statement on stdin and kept out of the server log.
5. Wait for the rollouts, then record the proofs in `.local/evidence-raw/rotate-<env>-<stamp>.log`, which holds no values.

| Proof | How |
|---|---|
| Old password rejected, new accepted | Login over the pod IP. **Not 127.0.0.1:** the image's `pg_hba.conf` trusts it, so any password would pass there |
| The test can fail at all | A random password must be rejected first |
| Plane uses a new connection | `/api/public/anchor/__probe__/settings/` returns 404 "does not exist". **Not `/api/instances/`:** that is cached in Valkey for two hours and answers 200 with Postgres down |
| Plane rolled | Each pod template names the Secret's new version, and `rollout status` finishes |
| Postgres untouched, `SECRET_KEY` unchanged | Start time and value compared before and after |
| Error window | A probe every second during the run |
| No fight with Argo CD | Workload generations stable after the rollout |

**What this does not cover.** It is scripted rotation with an error window, not native, scheduled or per-pod credentials. The role is a shared superuser. In-flight Jobs keep their old environment. There is no audit trail beyond secret version history. RabbitMQ and Silo are separate procedures, and `SECRET_KEY` must never be rotated.

If it stops partway it prints what Infisical, the Secret and Postgres each hold. `RESUME=yes` finishes and `ROLLBACK=yes` undoes. Both run the same steps against real state, so running either twice is safe. Changing `PG_PASSWORD` by hand in the UI does not change the role, and the next time Plane restarts it will fail.

## Recovery

| Situation | Result | Do this |
|---|---|---|
| `ENCRYPTION_KEY` lost locally, cluster alive | Recoverable | `scripts/secret-zero.sh` restores it from the cluster |
| `ENCRYPTION_KEY` lost everywhere | **Secrets are gone**, even with the database | New instance, reseed. Plane's config rows are bound to the old `SECRET_KEY`, so also restore Plane from a backup that matches, or start Plane empty |
| Postgres lost, key kept | All secrets gone unless a dump exists | Restore the dump, start on the same or newer image with the same key, rerun bootstrap |
| Redis lost | Pending jobs and locks only | Nothing |
| Cluster recreated | New CA stored in Kubernetes Auth | Rerun bootstrap, which passes the new CA to Terraform |
| Fresh instance over old local state | State and credentials point at nothing | Bootstrap detects `initialized=false` and moves the old files aside |
| `infisical-admin.json` lost, instance initialized | Bootstrap works once, so it refuses | Sign in at `http://infisical.localhost` as `admin@wayline.localhost` with `infisical-admin-password`, create a Token Auth token for "Instance Admin Identity", and recreate the file from the archive shape with that token |
| Admin token expired | It carries a 90-day cap. Scripts warn in the last 7 days and then refuse | Same as above |
| Terraform state lost, instance alive | Terraform would try to create what exists | Import each resource, or start from a fresh instance. A destroyed project keeps its slug for 14 days, so `destroy` then `apply` on a live instance probably conflicts |
| Rotation stopped partway | Plane may be failing | `RESUME=yes` or `ROLLBACK=yes` |

Back up `ENCRYPTION_KEY` separately from the database dump. A restored Plane database with freshly generated Infisical secrets breaks instance configuration silently, so restore the two as a matched set.

Infisical's migrations run forward only: an older image refuses to start on a newer schema, so a Helm rollback alone does not restore it.

## Free-tier limits and what they forced

From `license-fns.ts` and the enforcement sites at v0.167.6. An unlicensed self-hosted instance differs from the Cloud pricing page.

| Limit | What it forced |
|---|---|
| Custom roles and folder RBAC are paid. Additional privileges return 400 on projects created today | **One project per environment**, built-in `viewer`, org role `no-access`. Isolation is per project: a reader sees every secret in its environment and nothing in the other |
| Secret rotation is paid | `scripts/rotate.sh` is a script, with an error window |
| Dynamic secrets are paid | One shared Postgres role, not per-pod credentials |
| Audit logs are not stored (`auditLogsRetentionDays: 0`) | Who read what cannot be shown. Secret version history is the only trail |
| `instantUpdates` is paid | The operator polls, so `refreshInterval` is the latency. The rotation script nudges the CR to shorten it |
| None for rate limits. The plan names 40 secret requests, 60 reads and 200 writes per minute, but v0.167.6 registers the limiter only on Infisical Cloud (`app.ts`: `isProductionMode && isCloud`), and here 240 reads in 4s from one address all answered 200 | The seed still uses one batch and 3 requests per environment, and the scripts still honour `Retry-After` on 429, in case a later version applies the limit. That path has never run. Each operator polls 6 times a minute |
| Non-wildcard trusted IPs are paid | Access tokens are valid from any address, so short TTLs (1 hour) do that job instead |
| Gateway reviewer is paid | The client JWT reviews itself, which needs `system:auth-delegator` on `plane-infisical-auth` and `ALLOW_INTERNAL_IP_CONNECTIONS=true` |

Free and sufficient: unlimited identities, projects and environments, Kubernetes Auth, built-in roles, secret versioning.

`ALLOW_INTERNAL_IP_CONNECTIONS` relaxes SSRF protection for the whole instance. That is acceptable on a single-user local instance and needs a new decision for pass 2.

## Measured

Real runs on this cluster on 2026-11-04: Kubernetes 1.36, arm64, default-deny on. Raw output is in `.local/evidence-raw/`, under the names shown.

| What | Result | Evidence |
|---|---|---|
| First boot under the 1Gi limit and 640 MiB heap | 602 migrations in 11.5s. Container start to Ready in 21s. Peak 807 MiB by cgroup `memory.peak`, 0 OOM events | `infisical-firstboot-1.txt` |
| A later boot | "No migrations pending". Created to Ready in 15s. Peak 822 MiB. Idle is 650 to 730 MiB | `infisical-second-boot-1.txt`, `infisical-memory-1.txt` |
| Postgres and Redis, non-root with a read-only root on local-path | `initdb` and AOF both work, the root rejects a write, and both come back after a pod delete (8s and 11s) with all data. Postgres reached its 256Mi limit by `memory.peak`, but that is page cache: 8 MiB anon, 0 OOM events | `infisical-firstboot-1.txt`, `infisical-restart-1.txt` |
| What a restart costs | Redis down: the API does not answer for about 12s. Postgres down: reads answer 500 for about 6s. No CR went into error, and values and rendered Secrets did not change | `infisical-restart-1.txt` |
| Bootstrap and Terraform against the real API | 10 resources in 12s for the whole script. Read back: one `prod` environment per project, secrets at `/`, reader identities with org role `no-access` and project role `viewer` | `infisical-bootstrap-1.txt`, `infisical-config-1.txt` |
| Idempotent | Three reruns, the last with both Plane environments up: Terraform "No changes", seed writes nothing, and secret ids, versions, Secret contents, pods and Plane generations are identical. The first rerun raises the state serial once, to record `auth_modes` and a KMS key id; later ones do not | `infisical-idempotency-1.txt`, `infisical-idempotency-2.txt` |
| A second `POST /api/v1/admin/bootstrap` | 400, "Instance has already been set up". Sign-up is off | `infisical-config-1.txt` |
| Partial state | With one key deleted, the CR goes to error and its Secret keeps the last good value. The seed writes only that key, the other 8 keep their id and version, and the CR recovers | `infisical-seed-partial-1.txt` |
| Kubernetes Auth end to end | The operator logs in and caches for 42m, 70% of the TTL. The token reviews itself, with no reviewer JWT stored. A wrong CA is refused with "SSL certificate verification failed", so verification is on, and the certificate's SANs include `kubernetes.default.svc.cluster.local` | `infisical-isolation-2.txt`, `infisical-k8s-auth-tls-1.txt` |
| Token renewal | The dev operator logged in again 42m17s after its first login, with a fresh ServiceAccount token. 24 reconciles in the 4 minutes around it, 0 errors, so the wedge in operator #113 does not show on this CRD | `infisical-token-renewal-1.txt` |
| Who may log in | Other namespace: 401, "K8s namespace not allowed". Same namespace, other account: 401, "K8s name not allowed". Forged token: 401 | `infisical-isolation-2.txt` |
| Cross-project read | **403 in both directions**, on list, single read and slug lookup, from the host and from a pod over the Service. Same tokens read their own project, 200 | `infisical-isolation-2.txt` |
| Reader role | Writing to its own project and listing org identities: both 403 | `infisical-isolation-2.txt` |
| Rendered Secrets | All six in both namespaces hold exactly the contract's keys, with no empty or `<no value>` value, hex passwords, consistent URLs and nothing shared across environments. The check fails when a Secret is tampered with, and the operator repaired that in 9s | `infisical-rendered-secrets-1.txt`, `infisical-tamper-1.txt` |
| `secretFrom` against `.KEY.Value` | With a missing key, `secretFrom` sets `error: true` and creates no Secret. `.KEY.Value` renders a literal `<no value>` and reports success, which is why the overlays do not use it | `infisical-no-value-1.txt` |
| Operator scope | Each operator can read Secrets and mint tokens only in its own namespace. A CR in `plane-dev` that references the prod-sim account and identity stays unready | `infisical-rbac-1.txt` |
| Operator restart | No workload generation, pod or restart count moved. Each CR reports 0 deployments redeployed | `infisical-operator-restart-1.txt` |
| Argo CD gating on the real CRs | Wave -2 waits for `InfisicalAuth`, and wave -1 for all six secrets, whose "Secrets synced" message reached the sync result 3s after creation. A failing CR reads Degraded. While `InfisicalAuth` is unready the sync fails and retries | `infisical-unready-sync-1.txt`, `argocd-lua-infisical-live-1.txt` |
| Rate limit | **Not enforced on this instance.** 240 secret reads in 4s from one address: all 200, no rate-limit headers. Each operator makes 6 secret requests a minute. So the free-tier limit the research listed does not apply, and the `Retry-After` handling has not been exercised | `infisical-rate-limit-1.txt`, `infisical-server-log-1.txt` |
| Terraform state | Holds no admin token, no secret-zero file's content and none of the 12 generated values | `infisical-config-1.txt` |
| `secret-zero.sh` | With all four local files gone, it restores each from the cluster, byte for byte, and no Secret or pod moves. It refuses a different `ENCRYPTION_KEY` on disk, and `REGENERATE=yes` without `CONFIRM=yes` | `infisical-secret-zero-1.txt` |
| Admin token recovery | Sign-in with the generated password, then a new Token Auth token for the admin identity, works as Recovery describes. The probe token was revoked afterwards and then got 401 | `infisical-recovery-1.txt` |
| NetworkPolicy | With both environments up, rows from `infisical`: 14 PASS, 0 FAIL, 0 INCONCLUSIVE. To the server from each Plane namespace: the operator label connects, `api`, `worker` and `web` time out | `netpol-infisical-2.txt`, `netpol-infisical-3.txt`, `netpol-infisical-4.txt` |

## Not yet proven

In the order that blocks the most:

1. Everything in `rotate.sh` against real Postgres: socket trust, 127.0.0.1 trust versus pod-IP password checks, the probe route, the error window.
2. Argo CD and the operator's template annotations during a rotation (critique gate 8). The first sync is covered: `postgres-exporter` was patched once when `plane-pgdb` appeared and not again, and `monitoring-extras` stayed Synced. `rotate.sh` restarts by hand if the annotation is missing and reports a generation change as FAIL.
3. A clean install through the real waves. Here bootstrap ran with the operators already up, and the prod-sim ServiceAccounts and CRs were applied by hand ahead of wave 0, 19 minutes before `plane-prod-sim` existed. Argo CD then adopted them with the same UIDs, generation still 1 (`infisical-prod-sim-crs-1.txt`).
