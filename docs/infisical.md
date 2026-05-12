# Infisical

How secret values reach the two Plane environments of Wayline, a customized Plane Community Edition v1.4.3 deployment, and what happens when the secret store is lost.

**Status: NOT RUN.** Nothing in this file has run against a real cluster or a real Infisical yet. `docs/evidence/` holds no Infisical result. Every statement below that depends on a runtime result carries a `[[VERIFY: ...]]` marker. Prose without a marker describes configuration in the repository, not observed behaviour.

| Component | Version | Where it is pinned |
|---|---|---|
| Infisical server | v0.167.6, by digest | `helm/values/infisical.yaml` |
| Chart `infisical-standalone` | 1.12.0 | `gitops/applications/infisical.yaml` |
| Operator `secrets-operator` | v0.11.16, chart 0.11.16, by digest | `helm/values/infisical-operator-dev.yaml`, `helm/values/infisical-operator-prod-sim.yaml` |
| Terraform provider `infisical/infisical` | 0.20.10 | `infisical/terraform/versions.tf` |
| Infisical's Postgres | `postgres:16.15-alpine`, by digest | `infisical/manifests/postgres.yaml` |
| Infisical's Redis | `redis:7.2.17-alpine`, by digest | `infisical/manifests/redis.yaml` |

Postgres and Redis here are dedicated to Infisical and never shared with Plane, so the secret store does not depend on what it protects.

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
  B --> C["Argo CD: Infisical Postgres, Redis, server. About 600 migrations on first boot"]
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

[[VERIFY: first boot of about 600 migrations finishes under the 1Gi limit and 640 MiB heap on arm64]]

[[VERIFY: the sequence above completes on a fresh cluster with scripts/up.sh, which does not exist at commit f733b87]]

[[MEASURE: seconds from infisical pod start to /api/status answering 200 on first boot]]

### Idempotence, and the trap in it

Steps 2 and 5 are written to be rerun. With an initialized instance and intact local files, the bootstrap script finds the admin file, Terraform changes nothing except a new cluster CA, and the seed writes nothing.

The other branch is destructive to local state. If `GET /api/v1/admin/config` reports `initialized: false`, the script assumes a fresh instance. It moves `infisical-admin.json`, `infisical-machine.json` and `infisical-admin-password` to `.local/secret-zero/archive-<stamp>/`, moves the Terraform state aside, creates a new admin, new projects and new identities, and seeds new values including a new `SECRET_KEY`.

So never run the bootstrap against an empty Infisical that you intend to restore. Restore first, then bootstrap. [disaster-recovery.md](disaster-recovery.md) gives the order.

## What lives in `.local/secret-zero`

The directory is mode 0700, files are 0600, and `.local/` is gitignored. No script copies this directory off the machine. That is a manual duty, and the whole recovery story depends on it.

| File | Written by | Used for | If lost |
|---|---|---|---|
| `ENCRYPTION_KEY` | `secret-zero.sh`, `openssl rand -hex 16` | Encrypts Infisical's KMS root key, and so every secret in the database | Recoverable from Secret `infisical-secrets` while the cluster lives. **Unrecoverable once that is gone too** |
| `AUTH_SECRET` | `secret-zero.sh` | Signs JWTs | Sessions and tokens die, identities log in again |
| `DB_PASSWORD` | `secret-zero.sh` | Infisical's Postgres | Recoverable from Secret `infisical-db` |
| `REDIS_PASSWORD` | `secret-zero.sh` | Infisical's Redis | Recoverable from Secret `infisical-redis` |
| `infisical-admin.json` | Bootstrap | Admin token, org id. The token carries a JWT expiry capped at 90 days | See [Recovery](#recovery) |
| `infisical-admin-password` | Bootstrap, before the call, because the route works once | First admin's UI password | The token still works |
| `infisical-machine.json` | Bootstrap, from Terraform outputs | Project ids, identity ids. Not secret, but 0600 like the rest | Rerun bootstrap |
| `rotation-<env>/` | `rotate.sh` | Old and new password in plaintext, only while a rotation is stopped partway | That rotation cannot be resumed automatically |
| `archive-<stamp>/` | `secret-zero.sh REGENERATE`, bootstrap on a fresh instance | Files moved aside, never deleted | |

`secret-zero.sh` reuses existing files. It restores a missing one from the cluster when it can. It refuses to replace a differing `ENCRYPTION_KEY` in the cluster without `CONFIRM=yes`. It replaces the whole set only with `REGENERATE=yes CONFIRM=yes`, which is meant for an empty database, because Postgres keeps its old password until its volume is recreated.

The six Plane Secrets contain no secret zero. The seed generates values in memory, sends them, and keeps no copy. Infisical's database plus `ENCRYPTION_KEY` is the whole recovery set for them.

Terraform state in `.local/terraform/infisical/` is not in this directory, yet recovery also needs it. See [Recovery](#recovery).

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

Passwords are hex because the chart and the templates do not URL-encode into connection strings. The seed uses one batch write and 3 requests per environment, because unlicensed self-hosted Infisical allows 40 secret requests per minute per client IP (read from `license-fns.ts` at v0.167.6).

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

[[VERIFY: Kubernetes Auth login succeeds on kind under default-deny, including TLS verification against kubernetes.default.svc.cluster.local]]

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

[[VERIFY: operators reconcile all 6 InfisicalStaticSecret in both namespaces and the rendered keys match contract section 8]]

[[VERIFY: the custom Lua health checks report Healthy and Degraded as written]]

[[VERIFY: whether Argo CD waits or fails the sync while InfisicalAuth is unready before bootstrap publishes the identity Secret]]

Instant updates are paid, so the operator polls. `refreshInterval` is the propagation delay, up to 60 s. Each operator polls 6 CRs per minute from its own pod IP, below the 40 per minute limit.

### Two operators, not one

There is one operator release per Plane namespace, each with `scopedRBAC: true` and `scopedNamespaces` set to its namespace. In cluster mode a single operator could mint a token for any ServiceAccount and read every Secret, and nothing would stop an `InfisicalAuth` in `plane-dev` from referencing the prod-sim identity.

Scoped mode still renders three cluster-scoped objects per release. The chart truncates its fullname to 15 characters, so both release names would collide. `fullnameOverride` sets `iso-dev` and `iso-prod-sim`. Both deploy under the `platform` project, the only one allowed cluster-scoped objects.

## Auto-reload

The annotation `secrets.infisical.com/auto-reload: "true"` sits on the workload's own metadata, not the pod template, on `plane-api-wl`, `plane-worker-wl`, `plane-beat-worker-wl` and `plane-live-wl`.

From the operator source at v0.11.16: when a target Secret really changes, the operator merge-patches `secrets.infisical.com/managed-secret.<hash>` with the new etag into the workload and pod template annotations, which causes a normal rolling update. It covers Deployment, DaemonSet and StatefulSet, not Jobs. An operator restart causes no rollout. The patch is attempted only in the reconcile that changed the Secret.

| Workload | Annotated | Why |
|---|---|---|
| api, worker, beat, live | Yes | Read connection strings from env at start |
| Postgres, RabbitMQ | No, on purpose | `POSTGRES_PASSWORD` and `RABBITMQ_DEFAULT_*` act only on an empty data directory, so a restart achieves nothing and causes an outage |
| Migrator Job | Not supported | A Job is not restarted. It reads the current Secret on its next run |
| `postgres-exporter` | No, at commit f733b87 | Reads `plane-pgdb` at start, so it keeps the old password after a rotation until it restarts. `PlanePostgresDown` could then fire on a healthy Postgres. [[VERIFY: postgres-exporter survives make rotate, or carries auto-reload in the final manifests]] |

[[VERIFY: the operator's template annotation does not cause a sync loop with Argo CD self-heal]]

`rotate.sh` tests that loop by comparing workload generations for 20 s after the rollout. If the operator did not mark every pod template within 120 s, the script restarts the workloads itself and records it.

## Rotation

```bash
make rotate ENV=dev
make rotate ENV=prod-sim CONFIRM=yes
scripts/rotate.sh ENV=dev RESUME=yes
scripts/rotate.sh ENV=dev ROLLBACK=yes
```

**Why it is a script.** Secret rotation is a paid feature (`secretRotation: false` for unlicensed self-hosted, `license-fns.ts` at v0.167.6). So this is scripted rotation of one value, `PG_PASSWORD`. It is not native rotation, scheduled rotation, or per-pod credentials. Dynamic secrets are paid too. `PG_PASSWORD` was chosen because the role can be changed in place and the old value can be shown to fail.

**Order of operations:**

1. Preflight. Infisical, both Secrets and Postgres agree. Plane answers. Every consumer of `plane-app-env` carries auto-reload. A random password is rejected, so the rejection proof means something.
2. Write old and new values to the journal `.local/secret-zero/rotation-<env>/`, then write the new one to Infisical as a new version.
3. Nudge the CRs by annotation and wait for the operator to update `plane-pgdb` and `plane-app-env`. The operator starts restarting Plane at this point.
4. `ALTER ROLE` over the Unix socket, with the statement on stdin and logging suppressed for the session.
5. Wait for the rollouts, then record the proofs.

Step 3 precedes step 4 because the operator owns the restart. New pods crash-loop until the role has the new password, which is the error window.

**Proofs written to `.local/evidence-raw/rotate-<env>-<stamp>.log`, which holds no values:**

| Proof | How | Trap avoided |
|---|---|---|
| Old rejected, new accepted | Login over the pod IP | The image's `pg_hba.conf` trusts the socket and 127.0.0.1, so a login there accepts any password |
| The test can fail | Random password rejected first | |
| Plane uses a new connection | `/api/public/anchor/__probe__/settings/` returns 404 "does not exist" | `/api/instances/` is cached in Valkey for two hours and answers 200 with Postgres down |
| Plane rolled | Pod template names the Secret's new version, `rollout status` finishes | |
| Postgres untouched | Pod start time compared before and after | |
| `SECRET_KEY` unchanged | Value compared before and after | |
| Error window | A probe every second | |
| No fight with Argo CD | Generations stable after the rollout | |

[[VERIFY: make rotate ENV=dev completes against real Postgres and every proof above records PASS]]

[[VERIFY: the socket and 127.0.0.1 are trusted while the pod IP requires scram-sha-256 in postgres:15.19-alpine]]

[[MEASURE: error window in seconds during make rotate ENV=dev, from the probe log]]

[[MEASURE: error window in seconds during make rotate ENV=prod-sim, from the probe log]]

**What this does not cover:**

- The role is a shared superuser. One credential for all Plane components.
- In-flight Jobs keep their old environment.
- Audit logs are not stored on this tier (`auditLogsRetentionDays: 0`). Secret version history is the only trail.
- Changing `PG_PASSWORD` by hand in the UI does not change the role. The next Plane restart then fails. Only `ROLLBACK=yes` keeps both sides together.
- A dump of Infisical taken before a rotation holds the old password. Restoring it makes Infisical and the Postgres role disagree. So back up Infisical straight after a rotation: `make backup ENV=infisical`. Nothing does this automatically.

If it stops partway, the script prints what Infisical, the Secret and Postgres each hold. `RESUME=yes` finishes and `ROLLBACK=yes` undoes. Both run the same steps against real state, so running either twice is meant to be safe. [[VERIFY: RESUME and ROLLBACK recover a rotation interrupted between the Infisical write and ALTER ROLE]]

## What is never rotated, and why

| Value | Decision | Why |
|---|---|---|
| Plane `SECRET_KEY` | **Never** | It derives the Fernet key for encrypted instance configuration rows. `decrypt_data` fails silently to `""` on a wrong key, so SMTP and OAuth settings vanish with no error. Auto-reload on `plane-api-wl` is safe only because this key does not change |
| `LIVE_SERVER_SECRET_KEY` | Not rotated | Nothing consumes it at v1.4.3: `requireSecretKey` is defined and never used on a route (`apps/live/src/lib/auth-middleware.ts` in Plane v1.4.3). Rotating it would prove nothing |
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
| 40 secret requests, 60 reads, 200 writes per minute | One seed batch. Scripts honour `Retry-After` on 429 |
| Non-wildcard trusted IPs are paid | 1 hour token TTL |
| Gateway reviewer is paid | The client JWT reviews itself |

## Recovery

| Situation | Result | Do this |
|---|---|---|
| Server pod lost | Stateless, rescheduled | Nothing |
| Redis lost | Pending jobs and locks only | Nothing |
| Operator pod lost | Existing Secrets stay. Sync pauses until it returns | Nothing |
| Infisical down, Plane running | Plane keeps running on its existing Kubernetes Secrets. Restarted Plane pods still start, for the same reason. Rotation and new Secrets stop | Restore service. [[VERIFY: Plane survives an Infisical outage and restarts with existing Secrets]] |
| `ENCRYPTION_KEY` file lost, cluster alive | Recoverable | `scripts/secret-zero.sh` restores it from the cluster |
| `ENCRYPTION_KEY` lost everywhere | **Secrets are gone**, even with the database dump | New instance, new values. `SECRET_KEY` is gone too, so see [disaster-recovery.md](disaster-recovery.md#path-b-encryption_key-is-lost) |
| Postgres lost, key kept, dump exists | Recoverable | [disaster-recovery.md](disaster-recovery.md#scenario-infisical-lost) |
| Postgres lost, no dump | All secret values gone | As `ENCRYPTION_KEY` lost |
| Cluster recreated | New CA must reach Kubernetes Auth | Rerun bootstrap, which passes the CA to Terraform |
| `infisical-admin.json` lost, instance initialized | Bootstrap refuses, because it works only once | Sign in at `http://infisical.localhost` as `admin@wayline.localhost` with `infisical-admin-password`, create a Token Auth token for "Instance Admin Identity", and recreate the file in the shape the bootstrap writes |
| Admin token expired | 90 day cap. Scripts warn in the last 7 days, then refuse | As above |
| Terraform state lost, instance alive | Terraform would try to create what exists, and bootstrap runs Terraform unconditionally, so it fails before publishing identity ids | Import each resource, or start from a fresh instance. A destroyed project keeps its slug for 14 days. [[VERIFY: terraform import works for infisical_project, infisical_project_environment, infisical_identity, infisical_project_identity and infisical_identity_kubernetes_auth at provider 0.20.10]] |
| Rotation stopped partway | Plane may be failing | `RESUME=yes` or `ROLLBACK=yes` |

Infisical's migrations run forward only. An older image refuses to start on a newer schema, so a Helm rollback alone does not restore it. A restore must use the same or a newer image.

Back up `ENCRYPTION_KEY` separately from the dump. A dump with its key in one archive defeats the point, and `scripts/backup.sh` deliberately writes only a truncated hash to the manifest.

A restored Plane database needs the `SECRET_KEY` it was written with. `SECRET_KEY` lives in Infisical. So Infisical and Plane restore as a matched set, Infisical first. `scripts/restore.sh` compares the fingerprint and refuses a mismatch unless `ALLOW_SECRET_KEY_MISMATCH=yes`.

## Least-privilege evidence plan

No script tests this yet. The contract requires per-project isolation as the free-tier boundary, so it needs direct evidence. Capture the output to `docs/evidence/` with date and command, label each row **PASS**, **FAIL**, **BLOCKED** or **NOT RUN**, and record no tokens or values.

| # | Claim | Test | Expected | Result |
|---|---|---|---|---|
| L1 | Dev reader lists its own project | `status GET` below against `$OWN` | 200 | NOT RUN |
| L2 | Dev reader cannot read prod-sim | Same against `$OTHER` | 403 or 404 | NOT RUN |
| L3 | Dev reader cannot write its own project | `POST /api/v4/secrets/LEAST_PRIVILEGE_PROBE` to `$OWN` | 403. A success is a FAIL, and the probe key must then be deleted | NOT RUN |
| L4 | Org role `no-access` reaches nothing at org level | An org-level read with the same token | 403 | NOT RUN |
| L5 | Wrong namespace cannot log in | Token for `plane-prod-sim/plane-infisical-auth` with the dev identity id | 401 or 403 | NOT RUN |
| L6 | Wrong ServiceAccount cannot log in | Token for `plane-dev/plane` with the dev identity id | 401 or 403 | NOT RUN |
| L7 | Dev operator cannot read prod-sim Secrets | `kubectl auth can-i` below | `no` | NOT RUN |
| L8 | Dev operator cannot mint tokens in prod-sim | `kubectl auth can-i` below | `no` | NOT RUN |
| L9 | Workloads hold no API token | `automountServiceAccountToken` on running pods, expected false except the two operators | No exception | NOT RUN |
| L10 | Rendered manifests hold no Secret | `make ci`, conftest rule in `policy/gitops.rego` | Passes | NOT RUN |

[[VERIFY: run the table above, including the same tests with dev and prod-sim swapped, and replace each NOT RUN with a labelled result]]

The commands print status codes only. The token travels on stdin, so it never reaches an argv.

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
MACHINE=.local/secret-zero/infisical-machine.json
URL=http://infisical.localhost
IDENTITY="$(jq -r '.identity_ids.dev' "$MACHINE")"
OWN="$(jq -r '.project_ids.dev' "$MACHINE")"
OTHER="$(jq -r '.project_ids["prod-sim"]' "$MACHINE")"

login() { # namespace serviceaccount: prints the access token, or nothing
  kubectl --context kind-plane-platform -n "$1" create token "$2" --duration=10m \
    | jq -Rs --arg id "$IDENTITY" '{identityId: $id, jwt: rtrimstr("\n")}' \
    | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- \
        "$URL/api/v1/auth/kubernetes-auth/login" \
    | jq -r '.accessToken // empty'
}

ACCESS="$(login plane-dev plane-infisical-auth)"

status() { # project id: HTTP status of a key listing, values not requested
  printf 'Authorization: Bearer %s\n' "$ACCESS" | curl -sS -o /dev/null -w '%{http_code}\n' -H @- \
    "$URL/api/v4/secrets?projectId=$1&environment=prod&secretPath=%2F&viewSecretValue=false"
}

status "$OWN"    # L1
status "$OTHER"  # L2
[ -z "$(login plane-prod-sim plane-infisical-auth)" ] && echo "L5 refused"
[ -z "$(login plane-dev plane)" ] && echo "L6 refused"

SA=system:serviceaccount:plane-dev:iso-dev-controller-manager
kubectl --context kind-plane-platform auth can-i get secrets -n plane-prod-sim --as="$SA"                         # L7
kubectl --context kind-plane-platform auth can-i create serviceaccounts --subresource=token -n plane-prod-sim --as="$SA"  # L8
```

The login route and the v4 listing route come from the Infisical source at v0.167.6. Neither has been called from here yet. [[VERIFY: the commands above work as written against the running instance]]

## Related documents

- [security.md](security.md): threat model and what is not protected.
- [data-operations.md](data-operations.md): backup contents and restore.
- [disaster-recovery.md](disaster-recovery.md): failure scenarios and full restoration.
- [platform-contract.md](platform-contract.md): the binding names.
- [`infisical/README.md`](../infisical/README.md): the layer's own notes, including the names other layers rely on.
