# Infisical

Secret store for both Plane environments. Infisical Community Edition v0.167.6 runs in the `infisical` namespace with its own Postgres and Redis, and two namespace-scoped operators copy values into each Plane namespace.

**Status: NOT RUN.** Nothing here has run against a real cluster or a real Infisical yet. Terraform, Helm and manifests are validated statically, and the scripts were exercised against stubs only. Everything under [Not yet proven](#not-yet-proven) needs a real run and evidence in `docs/evidence/`.

| Path | What it is |
|---|---|
| `manifests/` | Postgres, Redis, IngressRoute, the server's ServiceAccount, the token-review binding. A path source of the `infisical` Application |
| `terraform/` | Projects, the environment, machine identities, Kubernetes Auth. Separate root, state in `.local/terraform/infisical/` |
| `lib/api.sh` | Shared by the scripts below |
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
| 3 | `infisical` Application, wave -4 | Argo CD. Inside it: ServiceAccount -2, Postgres and Redis -1, server 0, IngressRoute 1 | First boot runs about 600 migrations |
| 4 | `infisical-operator-dev` and `-prod-sim`, wave -3 | Argo CD | |
| 5 | `scripts/infisical-bootstrap.sh` | Script. Needs `http://infisical.localhost` | Terraform applied, secrets seeded, identity Secrets published |
| 6 | `plane-dev` wave -1, `plane-prod-sim` wave 0 | Argo CD | `InfisicalAuth` stays unready until step 5 publishes `plane-infisical-identity` |

Step 5 is not an Argo CD step because it needs the admin token, which never enters the cluster. It seeds before it publishes identity ids, so an operator cannot log in to an empty project.

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
| Secret requests limited to 40 per minute per client IP, reads 60, writes 200 | The seed uses one batch and 3 requests per environment. Scripts honour `Retry-After` on 429. Each operator has its own IP, with 6 CRs polling every 60s |
| Non-wildcard trusted IPs are paid | Access tokens are valid from any address, so short TTLs (1 hour) do that job instead |
| Gateway reviewer is paid | The client JWT reviews itself, which needs `system:auth-delegator` on `plane-infisical-auth` and `ALLOW_INTERNAL_IP_CONNECTIONS=true` |

Free and sufficient: unlimited identities, projects and environments, Kubernetes Auth, built-in roles, secret versioning.

`ALLOW_INTERNAL_IP_CONNECTIONS` relaxes SSRF protection for the whole instance. That is acceptable on a single-user local instance and needs a new decision for pass 2.

## Not yet proven

In the order that blocks the most:

1. First boot of about 600 migrations under the 1Gi limit and 640 MiB heap on arm64. If it OOMKills, raise the limit to 1.5Gi temporarily.
2. Non-root Postgres and Redis with a read-only root filesystem on kind's local-path volume.
3. Kubernetes Auth on kind: API server reachable from the pod under default-deny, certificate SAN for `kubernetes.default.svc.cluster.local`, the token reviewing itself.
4. Bootstrap, Terraform, and the provider's calls against the real API. The scripts have seen only a mock.
5. A cross-project 403: the `plane-dev` reader must not read `plane-prod-sim`.
6. Everything in `rotate.sh` against real Postgres: socket trust, 127.0.0.1 trust versus pod-IP password checks, the probe route, the error window.
7. Argo CD and the operator's template annotations (critique gate 8). `rotate.sh` restarts by hand if the annotation is missing and reports a generation change as FAIL.
8. Whether Argo CD waits or fails a sync while `InfisicalAuth` is unready before step 5.
