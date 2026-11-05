# Infisical

Secret store for both Plane environments. Infisical Community Edition v0.167.6 runs in the `infisical` namespace with its own Postgres and Redis, and two namespace-scoped operators copy values into each Plane namespace.

**Status: run on the real cluster on 2026-11-04 and 2026-11-05, except `scripts/rotate.sh` and the destroying end of [Clean restore](#clean-restore).** [Measured](#measured) says what ran and what it showed. [Not yet proven](#not-yet-proven) lists the rest.

| Path | What it is |
|---|---|
| `manifests/` | Postgres, Redis, IngressRoute, the server's ServiceAccount, the token-review binding. A path source of the `infisical` Application |
| `terraform/` | Projects, the environment, machine identities, Kubernetes Auth. Separate root, state in `.local/terraform/infisical/`, which `make destroy` keeps and each backup copies |
| `lib/api.sh` | Shared by the scripts below |
| `lib/recovery.sh` | The recovery set each backup carries for [Clean restore](#clean-restore), how a restore logs in, and Infisical's retention |
| `tests/isolation.sh` | Real logins and reads: each reader against its own project and the other one, from the host and from inside each namespace |
| `tests/rendered-secrets.sh` | The six Secrets in each namespace against contract section 8, without printing a value |
| `../helm/values/infisical*.yaml` | Server chart and the two operator releases |
| `../scripts/secret-zero.sh` | Creates what must exist before Infisical does |
| `../scripts/infisical-bootstrap.sh` | First admin, Terraform, seed, identity ids. `INFISICAL_RESTORED=yes` is restored mode |
| `../scripts/infisical-seed.sh` | Plane secret values, first time only |
| `../scripts/rotate.sh` | The rotation demo |
| `../scripts/restore.sh clean` | `make restore-clean`. Brings the whole platform back, this first |
| `../scripts/lib/up-checks.sh` | What `make up` stops on, so a restore and the drill can ask the same before a delete |
| `../tests/drills/clean-restore-harness.sh` | `make drill-clean-restore-harness`. The logic of all this against stubs. Its first lines say what that does and does not prove |
| `../tests/drills/clean-restore-mutants.sh` | Its negative control: takes one line at a time out of a copy of the scripts, and says which the harness notices |

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
| `infisical-admin.json` | Admin token, org id. Written by bootstrap. The token ends after 90 days | A password login makes another. See [How a restore logs in](#how-a-restore-logs-in) |
| `infisical-admin-password` | First admin's UI password. Written before the bootstrap call | Admin token still works until it ends. After that a person has to sign in with a copy |
| `infisical-admin-token.new` | A token a person made by hand after a sign-in, one line. There only until a script has checked it against the server and moved it into place | |
| `infisical-admin-replaced.log` | One line for each time `infisical-admin.json` was replaced: when, why, how, and the sha256 of the file before and after. No token | Nothing depends on it. It is the record |
| `archive-token-<time>/` | The `infisical-admin.json` a replacement took over from, so a restore can still find it by checksum | |
| `infisical-machine.json` | Project and identity ids. Not secret | Rerun bootstrap. A restore rebuilds it from the backup's Terraform state when it is lost, or names other ids than the backup does, and keeps the old one in `archive-pre-restore-<time>/` |
| `rotation-<env>/` | Both passwords, only while a rotation is stopped partway | Rotation cannot be resumed automatically |

`secret-zero.sh` reuses existing files and restores a missing one from the cluster if it can. It refuses to replace a differing `ENCRYPTION_KEY` in the cluster without `CONFIRM=yes`, and replaces the whole set only with `REGENERATE=yes CONFIRM=yes`, which archives the old files first. Regenerating is meant for an empty database: Postgres keeps its old password until its volume is recreated.

The contract's six Plane Secrets contain no secret zero. Their values live only in Infisical. The seed generates them in memory, sends them, and keeps no copy, so an Infisical dump plus `ENCRYPTION_KEY` is the only way back to them.

No backup copies these files. A backup records their sha256, and a restore finds them by that, in `.local/secret-zero/` or in any `archive-*` inside it. So this directory and `.local/backups/` have to be kept, and kept apart.

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

A finished rotation takes an Infisical backup, because an older dump holds the old `PG_PASSWORD`. If that backup fails, the rotation stands and the script exits 3. Restoring an older dump in place is refused for the same reason, unless `ALLOW_STALE_PLANE_SECRETS=yes`. A clean restore does not care: Plane's Postgres initializes with whatever Infisical says, and a dump carries no role password.

## Recovery

| Situation | Result | Do this |
|---|---|---|
| `ENCRYPTION_KEY` lost locally, cluster alive | Recoverable | `scripts/secret-zero.sh` restores it from the cluster |
| `ENCRYPTION_KEY` lost everywhere | **Secrets are gone**, even with the database | New instance, reseed. Plane's config rows are bound to the old `SECRET_KEY`, so also restore Plane from a backup that matches, or start Plane empty |
| Postgres lost, key kept | All secrets gone unless a dump exists | `make restore ENV=infisical BACKUP=<id> CONFIRM=yes`, on the same or a newer image with the same key, then `INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh` |
| Redis lost | Queued jobs, schedules and caches | Nothing |
| Cluster and everything in it gone | | `make restore-clean BACKUP=latest`. See [Clean restore](#clean-restore) |
| Cluster recreated with `make up`, data not wanted back | New instance, new secrets | Bootstrap detects `initialized=false` and moves the old files aside, never deleting them |
| Fresh instance over old local state | State and credentials point at nothing | Bootstrap detects `initialized=false` and moves the old files aside. A clean restore can still find them by checksum |
| `infisical-admin.json` lost, instance initialized | Bootstrap's own route works once, so it cannot make another | `scripts/infisical-bootstrap.sh` signs in with `infisical-admin-password`, mints a token for the instance admin identity and records that it did. With no password it stops with the steps for a person |
| Admin token expired | It carries a 90-day cap. Scripts warn in the last 7 days. A backup or `make up` then replaces it the same way, and anything else refuses and says so | The same. `RENEW_ADMIN_TOKEN=yes scripts/infisical-bootstrap.sh` does it ahead of time. See [How a restore logs in](#how-a-restore-logs-in) |
| Admin token and password both gone | Nothing here can log in, and the instance and its secrets are fine | See [Admin token and password both gone](#admin-token-and-password-both-gone) |
| Terraform state lost, instance alive | Terraform would try to create what exists | Copy `recovery/terraform.tfstate` from the newest Infisical backup. With no backup: import each resource, or start from a fresh instance. A destroyed project keeps its slug for 14 days, so `destroy` then `apply` on a live instance probably conflicts |
| Rotation stopped partway | Plane may be failing | `RESUME=yes` or `ROLLBACK=yes` |

Back up `ENCRYPTION_KEY` separately from the database dump. A restored Plane database with freshly generated Infisical secrets breaks instance configuration silently, so restore the two as a matched set.

Infisical's migrations run forward only: an older image refuses to start on a newer schema, so a Helm rollback alone does not restore it.

## Clean restore

For when the cluster and everything in it are gone. Infisical comes first, because it is the source of truth for every Plane secret, and Plane's volumes and encrypted rows only work with the values it had.

```bash
make restore-clean BACKUP=latest                 # or an Infisical backup id. Resumes if run again
make restore-clean BACKUP=latest PLAN_ONLY=yes   # checks everything, changes nothing, works on a live cluster
make drill-clean-restore CONFIRM=yes             # a fresh backup, then deletes the cluster and does the above
make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes   # the same, deleting with kind alone, as a disaster would
make drill-clean-restore-harness                 # the logic, against stubs. Touches nothing and proves no platform
```

It exits 0 when everything is proven, 1 when something failed, and 2 when nothing failed but a proof could not run or a person has to act, which is not a pass. With 2 the restore stays marked as under way, and the same command goes on from there. It exits 4 when everything is proven and it overwrote what `ALLOW_RESUME_OVERWRITE` named, which is not a pass either, and nothing is left to resume. Only `scripts/restore.sh` itself exits with these: the numbers are the script's, and make itself exits 2 on any of them, and prints which, as in `make: *** [restore-clean] Error 1`. So after `make restore-clean`, read what happened from its evidence: `jq '.result, .not_run' .local/evidence-raw/restore-clean-*.json`.

What a backup holds beyond the dump. `recovery/set.json` is the last thing written, and an Infisical backup without a whole one cannot serve a clean restore:

| What | Where | Why |
|---|---|---|
| Terraform state of `infisical/terraform` | Copied to `recovery/terraform.tfstate` | State and database are a pair. State from any other moment plans to create or delete |
| Secret zero, admin credentials | sha256 in `recovery/set.json`. The files stay in `.local/secret-zero/` | Without `ENCRYPTION_KEY` the dump is unreadable, and without `AUTH_SECRET` nothing it signed can be verified. The admin token and password decide how a restore logs in, and not whether it can start: see [How a restore logs in](#how-a-restore-logs-in) |
| Who the admin token belongs to, and when it ends | `admin` in `recovery/set.json`. Not the token | A plan can say when a backup's token ends without reading the token |
| Project and identity ids | `recovery/set.json` | |
| Each Plane secret: truncated hash, version and id | `recovery/set.json` | Read back from the API at backup time. Proves which `SECRET_KEY` this dump can render, before anything is deleted or created |
| Test accounts and sentinel | `recovery/` of each Plane backup, that environment's lines only | They are rows in that dump. A later `make test-e2e` signs in with them |
| How many rows the dump marks as uploaded, and how many of those have no object in this backup | `uploaded_objects` in each Plane manifest, and the rows in `postgres/uploaded-missing.txt` | The same comparison as a restore's GATE2, which has no override and runs with the data already replaced. So a plan can refuse before a delete. It stays a record and not a failure, because the backup still holds everything else. If the comparison itself cannot run, the manifest holds `null` and a plan says "not recorded" |

The sequence, all of it in `scripts/restore.sh`:

1. **Check, with nothing touched.** Every checksum, the keys the set names, that each Plane backup was taken with the `SECRET_KEY` this Infisical backup holds, that it records no row marked uploaded with no object, and that Git does not deploy an older Infisical than the dump came from. Then everything `make up` would stop on, by the same code: uncommitted changes under `gitops`, `helm`, `monitoring` and `infisical`, digests the local registry cannot serve, and free disk. Refuses a cluster that holds data, or one it cannot read. The plan prints what each backup holds, in rows and objects, and warns if a Plane backup has 0 users, records a sentinel when its dump counts 0 workspaces, or is older than another backup with the same `SECRET_KEY`, which it names with the option that picks it.
2. **`make up` as far as Traefik.** With no cluster at the start, `.local/terraform/local` describes one that is gone, so it first moves aside to `local.stale-<time>`, and says so. `make destroy` removes it, but a cluster lost any other way leaves it behind. Plane stays at wave -2, because it has no identity Secret yet, so nothing can read or render a value.
3. **Wait for the fresh server to finish its migrations, then replace its database.** This pauses auto-sync on `infisical` only, stops the server, restores into a second database, checks the row counts, renames it into place, flushes Redis and starts the server. Root is left alone: its sync is waiting for Plane, and terminating it would stop Argo CD retrying that revision. Then something here has to be able to log in: see [How a restore logs in](#how-a-restore-logs-in).
4. **`make up` from there, with bootstrap in restored mode.** Same credentials. Terraform updates the CA in Kubernetes Auth and nothing else; there is no stored token reviewer to refresh, because the login token reviews itself. Identity Secrets are published and no value is written. The operators render the old values, Plane's data services initialize with them, and it waits for all Applications, the first time through.
5. **Restore each Plane environment,** as `make restore` does, then check it all again from outside. A sentinel proof that could not run reads NOT RUN, the run exits 2 and the marker stays. `ALLOW_NO_SENTINEL=yes` accepts that, as with a backup taken before a sentinel existed: the step still reads NOT RUN, and the result lists it.

Restored mode refuses rather than repairs. A fresh instance, a token the server rejects, Terraform wanting to create or delete anything, or a missing secret each mean the database and the local files are not a pair, and generating anything would only hide that. A token that has merely ended, or a file that is gone, says nothing about the pair, and step 3 has already dealt with those by the time restored mode runs.

While a clean restore is under way, `.local/restore-clean.state` records it. A plain `make up` then refuses to bootstrap a fresh instance, which would create new secrets, and `make destroy` clears the file. So does finishing it. Removing the file by hand ends it and deletes nothing, which is the way out when the platform here is what you want to keep.

That file has no age limit, and exit 2 keeps it with the platform up and in use, so what it names can be overtaken. A resume refuses, and changes nothing, when:

| What happened since | What it says | Ways on |
|---|---|---|
| `BACKUP=latest`, and a newer complete set exists | Names both | `BACKUP=<the id under way>` resumes it. `make destroy CONFIRM=yes SKIP_BACKUP=yes` starts over, and with a cluster here that deletes it |
| `BACKUP=latest`, no cluster, and it would now choose newer Plane backups | Names both. Nothing that run finished still counts, so neither does what it chose | The same |
| Retention or a person removed a backup it names | Names it | `make destroy CONFIRM=yes SKIP_BACKUP=yes`, or remove the file if the platform here stays |
| `BACKUP_DEV`, `BACKUP_PROD_SIM` or `ENVS` differ from what it started with | Names both | The same |
| An environment it has not finished holds other users or objects than its backup | Both counts. The same users and no more objects, or no users and no more objects, is that backup part way through, and goes on | `ALLOW_RESUME_OVERWRITE=<env>`, or `"dev prod-sim"`, which reaches only what it names, and `yes` is refused. Recorded as a FAIL with what was there, and that run does not read PASS: it exits 4, its result reads `OVERWROTE`, and a marker line keeps that for a later run of the same restore. `make backup ENV=<env> ALLOW_BACKUP_DURING_RESTORE=yes` keeps it first. A target with the same counts and other rows is not caught |

While that file is there, `make backup` refuses an environment the restore has not finished, because nothing has looked at what it holds: a backup of an empty or partly restored one would become the newest, and it may also be real data. It goes ahead with a warning for an environment whose data has come back, or that the restore has finished. `ALLOW_BACKUP_DURING_RESTORE=yes` goes past it. `make destroy` passes that by itself, because what it deletes may be all there is, and retention keeps the newest backup with users. `SKIP_BACKUP=yes` on `make destroy` then deletes what is there with no backup.

### Refusals and their overrides

| Refused, before anything is touched | Way past it | What that costs |
|---|---|---|
| A cluster that holds data, or that kubectl cannot read, so this cannot tell what it holds | `make destroy CONFIRM=yes SKIP_BACKUP=yes`, then `make restore-clean BACKUP=<id>`, which the refusal prints. Without `SKIP_BACKUP=yes`, `make destroy` backs up what is there now, and `BACKUP=latest` then names that. If kubectl was only failing for a moment, run it again | The cluster |
| Uncommitted changes under the paths Argo CD reads | Commit or stash them, and keep those paths still until the run ends. `make up` runs twice inside it | |
| Digests the registry cannot serve | See [What a clean restore cannot bring back](#what-a-clean-restore-cannot-bring-back) | |
| A registry that does not answer, with a cluster here. So the drill never deletes on a plan that could not see the digests. With no cluster it is a note, and `up.sh` starts it and checks then | `make up UP_STOP_AFTER=cluster` starts it, and touches no data | |
| A Plane backup that records rows marked uploaded with no object | `BACKUP_DEV` or `BACKUP_PROD_SIM` to another, or `ENVS` to leave that environment out. A backup from before this records nothing, and is not refused for it | That environment is not this backup |
| Too little disk | Free space, or `ALLOW_LOW_DISK="<reason>"`, which `up.sh` and `cluster-up.sh` honour too, and each logs in `.local/evidence-raw/low-disk-overrides.log`. `yes` and blanks are refused: they say nothing | A later `guard_disk` can still stop the run at its 10 GiB floor, which `ALLOW_LOW_DISK` does not go past, and it resumes from there. `MIN_FREE_DISK_GIB=<n>` lowers that floor, and a value below 10 is logged in the same file. A full disk gives write errors in Postgres, not a clean stop |
| A dump from a newer Infisical than will run on it | Deploy that version, or `ALLOW_NEWER_INFISICAL_BACKUP=yes` | That server refuses to start on the dump until a newer image is deployed |
| A key the set names is not on this machine | Put it back. Without `ENCRYPTION_KEY` the dump is unreadable | |

**The disk check.** `make up` asks for 25 GiB to create a cluster, and `cluster-up.sh` alone for 15. Before a delete the drill and the plan compute what would be free after it: what is free now, plus 93% of the kind volume as `docker system df -v` measures it, which reads lower than `du` in the node and so errs towards refusing. 93% is what a 273 MB volume returned within 15s, and a 12 GB volume has not been measured, so the drill prints what really came back. A run that passes this check does not stop at `up.sh`'s check for a new cluster: if less comes back than the check counted on, the drill hands `up.sh` a logged reason saying so, since the cluster is gone by then and stopping protects nothing. `scripts/lib/up-checks.sh` says what the numbers are based on: the node's volume at 12.94 GiB by `du`, the 10 GiB floor later scripts check, and about 2 over.

A plan has a restore to do after `make up`, and that checks the floor too, so it counts what is still to pull. With no registry or mirror volumes that is a first install's 17.75 GiB, plus the floor, so 27.75. An empty cluster that stays, as `make up UP_STOP_AFTER=cluster` leaves one, creates nothing and still has its 12.94 GiB to pull, so it asks for 22.94, or 27.75 with no volumes. A resume on a cluster that stays cannot tell how much it has pulled, and has only the floor.

### How a restore logs in

The admin token is a Token Auth token with an `exp` 90 days out, and every backup names it by checksum, so any restore done later would find it ended. A token is not what makes a dump restorable, so a restore does not depend on one. What it needs is `ENCRYPTION_KEY`, `AUTH_SECRET` and the dump. It decides from the files what it expects, says so in the plan, and once the restored server answers, asks it:

| The file this backup names | Password | What happens |
|---|---|---|
| Here, in place or in an archive, not ended | | Put in place if it was archived. The server accepts it, and nothing is replaced |
| Ended, or not on this machine | The one this backup names by checksum, in place or in an archive | The plan warns. After the database is back it signs in, mints a token for the instance admin identity, moves the old file to `archive-token-<time>/`, and records it in `infisical-admin-replaced.log` and in the run's evidence |
| Ended, or not on this machine | Another, by checksum | It may not be the one this dump holds, so it counts as unknown. The plan warns, and after the database is back this tries it. The server has the last word, as after the last resort below. If it refuses, this is the row below. A trailing newline does not make another password, because the login route trims it |
| Ended, or not on this machine | Not here | The plan warns. It restores Infisical, then stops with exit 2 and exact sign-in steps. Running the same command again takes the replacement, does not restore Infisical again, and goes on |

The server has the last word on any token, because a token minted after a dump is not in that dump. So a token in place that the server refuses goes the same way as one that has ended, and restored mode, which runs next, still refuses a token the server rejects.

The checksum keeps its meaning. It names the file that belongs to this dump, and that file is kept. A token written over `infisical-admin.json` by hand does not pass as that file: it is either accepted by the restored server, which is recorded with both checksums, or it is not, which is treated like no token at all.

In place the same applies, with the check moved ahead of the stop: with no token and no password, or only a password this backup does not name, `make restore ENV=infisical` refuses while the instance can still be signed in to. If its Postgres is lost there is nothing to sign in to, so `ALLOW_NO_ADMIN_TOKEN=yes` restores it, tries any password that is here, and stops with the steps and exit 3 if that does not work. A backup with no complete set is looked at the same way, by what its unfinished set names, or by what is in place if it has none, and after the swap it signs in the same way. It then has nothing to compare values with, so it exits 2.

A backup also gets ahead of this. A token that has ended is replaced before the dump, so the token the set names is a row in that dump. A backup or a plan warns when the token ends within 30 days (`BACKUP_RETENTION_DAYS`), which is an assumption: backups are kept by count, and with no schedule nothing says how old that count gets.

The sign-in steps name these labels: Access Control, Machine Identities, Instance Admin Identity, Token Auth, Add Token. They were read from this image's frontend build, and nobody has clicked through them. The API calls behind a password login were run on the live instance (`dr-mint-1.txt`).

### Admin token and password both gone

The dump holds the password's hash, so with the keys and the dump the instance comes back, and only the way in is missing. `make restore-clean` stops at the sign-in steps, or `make restore ENV=infisical ALLOW_NO_ADMIN_TOKEN=yes` does. The forgot-password mail needs SMTP, which this platform does not configure. So a new hash goes straight into the restored database, using the server's own bcrypt, and the password goes in the file the steps name:

```bash
read -rs NEW   # a new password. Not echoed, and never in an argument
HASH="$(printf '%s' "$NEW" | kubectl --context kind-plane-platform -n infisical exec -i deploy/infisical -- node -e 'const b=require("/backend/node_modules/bcrypt");let s="";process.stdin.on("data",d=>s+=d).on("end",()=>b.hash(s,12).then(h=>console.log(h)))')"
printf "UPDATE users SET \"hashedPassword\" = '%s' WHERE username = 'admin@wayline.localhost';\n" "$HASH" \
  | kubectl --context kind-plane-platform -n infisical exec -i infisical-postgres-0 -c postgres -- sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
printf '%s' "$NEW" > .local/secret-zero/infisical-admin-password; chmod 600 .local/secret-zero/infisical-admin-password; unset NEW HASH
make restore-clean BACKUP=<id>   # or the command the steps named
```

Run on the live instance on 2026-11-05, in place, with a generated password and not `read`: the restore refused with nothing changed, `ALLOW_NO_ADMIN_TOKEN=yes` restored it and stopped with exit 3 and the steps, these commands answered `UPDATE 1`, `scripts/infisical-bootstrap.sh` signed in with the new password and minted a token, and a last restore put the original token and password back by checksum, after which the original password signed in again (`dr-inplace-no-token-no-password-1.txt`, `-2.txt`, `-3.txt`). It has not run on a clean restore. A dump taken before this keeps the old hash, so an older backup then needs the old password.

### After a hard stop

"Run it again" also holds after SIGKILL or a power cut, which run no trap. With `.local/restore-clean.state` still there, the next run first removes any restore Job left with no client, the migrator's among them, puts back any `automated` block that holds `enabled: false`, root last, and scales Infisical and the Plane Deployments to Git's replicas. Each is recorded as a `repair-*` step. It refuses instead if another restore of this checkout is still running, however it was started. The wait for all Applications only runs until it has passed once, because a Plane environment part way through its restore could never satisfy it. After that the restore goes straight to the environments that are not done, and waits at the end.

### When the client ends and the Job does not

A restore Job runs in the cluster, so Ctrl-C, SIGTERM, a closed terminal or a kubectl error while the client polls ends only the client. A Job that carried on would go on to replace Infisical's database or drop Plane's, under a server the client had already started, after it had already said FAILED. So on any exit the client first removes this run's restore Jobs that have not finished, with `--cascade=foreground`, so their pods are gone when that returns. Then it flushes Infisical's Redis, because the database may be the restored one by then, starts the server and puts auto-sync back, root last. The run says the environment may hold the old data, the backup's, or a part of it, and running it again restores it.

If a Job cannot be removed, or kubectl cannot say whether it runs, nothing starts: the server or apps stay down, auto-sync stays paused, and it prints what to run, in order. A clean restore that resumes does all of that by itself.

### What a clean restore cannot bring back

**Images built here.** Since promotion `4f622e3`, `plane-dev` runs `localhost:5001/wayline` digests, which live only in Docker volume `plane-platform-local_registry-data`. No backup holds them. That volume survives `make destroy` and a lost cluster. It does not survive `make destroy PURGE=yes`, a new machine or a lost `Docker.raw`, and a rebuild does not reproduce a digest. Saving them with the recovery set would cost about 900 MB a set, which this disk cannot pay.

So a plan lists each digest the registry cannot serve, by the same check as `make up`, and a run refuses before it touches anything. Two ways out, and neither touches the data. Both need the registry running, and `make up UP_STOP_AFTER=cluster` starts it and publishes nothing:

```bash
# If GHCR has those digests, which keeps them exact. Needs docker login ghcr.io. Has not run: see docs/known-limitations.md
scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev
scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline prod-sim
# Otherwise rebuild and promote, which commits new digests. On that empty cluster plane-dev cannot have proven one
make images
make promote ENV=dev
make promote ENV=prod-sim CONFIRM=yes SKIP_BACKUP=yes OVERRIDE_DEV_CHECK="restoring into an empty cluster"
# Then, either way
make restore-clean BACKUP=<id>
```

The same goes for what the mirrors hold, except that they fetch it again by themselves: those images are upstream's, by digest. This has run only on stubs, because the drill keeps the registry.

**Anything after the backup.** A dump is what it was when it was taken.

### Retention

Plane's runs in its backup Job, and keeps the newest `KEEP` backups and, past that, the newest one whose `postgres/rowcounts.tsv` counts users above 0, so a run of backups of an empty environment cannot push out the last one that holds anything. Infisical's runs from the host, once the backup just taken has a complete recovery set, so a run of backups that cannot finish theirs removes nothing, and only a complete set counts toward `KEEP`, so the newest complete one cannot go. A backup with no complete set is kept while it is newer than the oldest set kept, since an in-place restore can still use its dump, and goes after that.

In place, `make restore ENV=<env> BACKUP=latest` warns if that backup holds 0 users and the environment holds some, and names the newest backup that has them, because a `CONFIRM=yes` would otherwise take real data away with exit 0. It also refuses a backup that records rows marked uploaded with no object, before anything stops.

### Why these details

- **A second database and a rename, not one transaction.** 3,000 partition indexes need more locks in one transaction than this server has (`max_connections=30`, `out of shared memory`, measured). So until the rename the live database is untouched, a bad dump costs nothing, and a server that starts during the restore cannot see half of it. The rename is two statements in one transaction, old name to `_replaced` and new name to the real one, and only then a drop, so wherever a Job stops, a whole database has that name.
- **A larger lock table anyway.** A backup's scratch restore held 3437 locks at once, measured, against a table of `max_locks_per_transaction` x MaxBackends, which at the default of 64 is 3328. The extra came out of spare shared memory, the partitions behind it only grow, and running out fails the backup or the restore. So it is 128 now, for 6656. See [Measured clean restore](#measured-clean-restore).
- **Redis is flushed.** The server caches secrets, permissions, identity revocation versions, KMS material and admin config there, and keeps its queues and schedules there. All of that describes the database that was just replaced.

## Measured clean restore

Real runs on 2026-11-05. Raw output is in `.local/evidence-raw/`.

| What | Result | Evidence |
|---|---|---|
| `make backup ENV=all` | 42s. Infisical 4.4 MB dump, 785 tables counted from a scratch restore. dev and prod-sim 110 tables | `dr-backup-3.txt`, `dr-backup-4.txt` |
| A backup on the host | The folder at 0700, each backup at 0700, each file at 0600, belonging to the Docker Desktop user | `dr-backup-modes-1.txt` |
| Recovery set against the Plane manifests | `SECRET_KEY` hash read back from Infisical equals `secret_key_fp` in every Plane manifest on disk, by a `jq` comparison of the files | `dr-fingerprints-1.txt` |
| `make backup ENV=infisical` | 29s, with `admin` in the set. Retention from the host removed the oldest complete set past `KEEP=5`, twice, and nothing else | `dr-locks-1.txt`, `-2.txt`, `-5.txt` |
| Plan on the live cluster | Row and object counts for each backup. Refused an uncommitted `infisical/README.md`, by the same code as `up.sh`. With the tree clean it refused the disk, at about 24.8 GiB after a delete against 25, and with a reason given it passed, as did the drill's plan up to the delete. Secret zero, Terraform state and the marker did not change | `dr-plan-refusals-2.txt`, `dr-plan-3.txt`, `dr-drill-planonly-2.txt` |
| Plan and refusals on the live cluster, the earlier run | A real run refuses a cluster holding data, a backup with no recovery set, and an unknown id | `dr-plan-refusals-1.txt` |
| In-place restore, five times with a probe once a second | 51s to 71s in all, and the server not answering for 39s to 52s. Before and after: every Plane pod uid and restart count, workload generation and Secret resourceVersion identical, but for one worker that another agent's smoke test replaced, and that test's `netpol-*` probe pods, which those files note. The 28s first written here had no measurement behind it | `dr-inplace-restore-3.txt`, `dr-inplace-token-lost-1.txt`, `dr-inplace-token-back-1.txt`, `dr-inplace-no-token-no-password-2.txt`, `-3.txt` |
| After all five | `make test-infisical` exit 0, with 118 PASS lines. All 14 Applications Synced and Healthy, none paused, no OOM kill in the node | `dr-after-restores-1.txt` |
| The earlier in-place runs | 48s and 44s. 116 isolation and rendered-Secret checks PASS after the first | `dr-inplace-restore-1.txt`, `-2.txt` |
| A password login mints a token, on the live instance | With no admin file and no local file naming the organization: signed in, found the organization and the instance admin identity, minted a token that ends 90 days out, and the server accepted it. A wrong password gives 400, and a made-up token 403. The probe token was revoked | `dr-mint-1.txt` |
| In-place restore, the admin file gone | The plan warned, the restore minted after the swap, proof-values PASS with the new token, and the ledger recorded it | `dr-inplace-token-lost-1.txt` |
| In-place restore, another token in place and the file the backup names in an archive | Put back by checksum, the server accepted it with no login, and the token minted above was gone from the identity | `dr-inplace-token-back-1.txt` |
| Lock use, sampled during a backup | Highest total 3437, of which one `pg_restore` `ALTER TABLE ... ADD CONSTRAINT` held 3428, a `count(*)` over a partitioned table 2929, and `pg_dump` 949. At 64 the table has 3328 slots, by `max_locks_per_transaction` x MaxBackends (52), and those peaks ran on spare shared memory | `dr-locks-1.txt`, `-2.txt`, `-5.txt` |
| `max_locks_per_transaction=128` through Git and Argo CD | Postgres replaced 15s after the refresh, the server not restarted, no Plane pod, generation or Secret moved, no `InfisicalStaticSecret` in error. 1272 KiB more shared memory. `/api/status` stayed 200, which it does with Postgres down, and reads are known to answer 500 for about 6s (`infisical-restart-1.txt`). Backup and in-place restore ran after it | `dr-locks-3.txt`, `-4.txt`, `-5.txt`, `dr-inplace-restore-3.txt` |
| Restored mode on the live instance | Terraform "No changes", seed writes nothing, identity Secrets unchanged | `dr-restored-bootstrap-1.txt`, `-2.txt` |
| A brand-new server in a throwaway namespace, on an empty database | Fresh first: `initialized=false`, 602 migrations. Then the exact restore Job, a flush and a restart: `initialized=true`, the old admin token accepted, all 18 Plane secrets decrypt to the recorded hash, version and id | `dr-fresh-instance-rehearsal-2.txt` |
| Terraform with the backup's state against that instance | No changes, and identities log in. With a stored CA that differs: 2 updates and 8 no-ops, applied as a saved plan, and both identities log in. The API refuses a CA that cannot verify the API server, so a wrong one cannot be stored by request | `dr-fresh-instance-rehearsal-1.txt`, `-2.txt` |
| The exact Plane restore Job, into a scratch database and bucket | Postgres gates pass, objects sync and check by download through the read-only mount, Content-Type put back on 14 of 22 objects, because VirtioFS keeps no xattrs and rclone guessed `text/plain; charset=utf-8` | `dr-plane-restore-rehearsal-1.txt` |
| Retention, and the drill up to the delete | `KEEP=2` removes backups that hold host-written recovery files. `make drill-clean-restore PLAN_ONLY=yes` passes on the live cluster: 38 rendered keys hashed, a fresh set, the plan | `dr-backup-retention-1.txt`, `dr-drill-planonly-1.txt` |
| Puts back a paused `automated` block, as a resume does | On a real Application, for seconds: back to the block with no `enabled`, still Synced and Healthy | `dr-repair-1.txt` |
| The registry check on what the registry cannot have | With real `docker buildx`: an unknown digest is listed, and every digest Git deploys is served | `dr-registry-check-1.txt` |
| Retention on real folders, the reviewer's case | One complete set and five with none, `KEEP=5`: nothing goes, where the old lines removed the complete one | `dr-retention-2.txt` |
| Whether root undoes a paused child | No. Root stayed Synced through a hard refresh, and `kubectl apply` of the child's manifest keeps `enabled: false` | `dr-child-pause-1.txt` |
| Order, resume and every refusal of `make restore-clean`, `make restore`, `make backup`, restored mode and the drill | 905 checks PASS in `make drill-clean-restore-harness`, with stubbed kubectl, kind, docker, `df`, rclone, Terraform, smoke test and API. The scripts, `up.sh` and `cluster-up.sh` among them, and the files on disk are real. This shows the logic, not the platform. The scenarios the second review added or changed, against the code before it: 268 of their 595 checks FAIL, in a scenario for every finding but the one about the harness itself. Those scenarios pass there, because the lines exist, and the one failure is the drill's own check of a plain bootstrap. So for that finding: `tests/drills/clean-restore-mutants.sh` took one line at a time out of a copy, and its scenarios caught 73 of 73, among them all 22 the review tried, written again from its descriptions. Each ran against the scenarios named beside it, and not all of them | `dr-harness-stubbed-4.txt`, `dr-harness-old-code-3.txt`, `dr-mutants-1.txt`, and before this `dr-harness-stubbed-3.txt`, `dr-harness-old-code-2.txt` |
| Stopping a restore at 61 sampled calls, and running the same command again, on those stubs | SIGTERM at 14 calls of a clean restore and SIGKILL at 10, SIGTERM at 11 of an in-place Infisical restore and 26 of an in-place dev restore. Every one came back with exit 0, no Job left running, nothing paused and no ERROR line. One of the 26 had finished before its signal | `dr-stop-sweep-1.txt` |
| The Plane backup Job's new lines in a real Job | `make promote ENV=prod-sim` took a backup at 05:33 UTC with them: 40 rows marked uploaded, 0 with no object, every checksum good, and no error from the retention lines, which had nothing past `KEEP=5` to remove. So the "kept" branch of retention and a row with no object have run only on BusyBox and stubs | `dr-backup-job-real-1.txt`, `dr-job-lines-busybox-2.txt` |
| The plan on the live cluster, after all of this | Reads the real volumes, registry and manifests, and changes nothing. It refuses for disk, at about 24.9 GiB after a delete against 25, and with a reason given it passes, says a real run would refuse this cluster, and says how | `dr-plan-4.txt` |

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

1. **The destroying run: `make drill-clean-restore CONFIRM=yes`, and `LOSE_CLUSTER=yes`.** Everything above stops short of deleting the cluster. Nothing has yet shown the sequence on a real new cluster with a new CA, Plane's data services initializing with the old values, `make restore` of a Plane environment against its real database and bucket, Terraform on a state moved aside, or how much of a 12 GB kind volume reaches the host and how soon: 93% was measured on 273 MB.
1. These have run only on stubs: the repair after a hard stop, the stop for a sign-in and its resume in a clean restore, an admin token that has really ended, a backup replacing one before its dump, a registry that cannot serve a digest, and the disk arithmetic against a real delete. Password login after a restore, and the sign-in stop in place, ran for real.
1. These too, from the second review: a client that ends during a Job and removes it with `--cascade=foreground`, every refusal of a resume, and a kubectl error read as "cannot tell what it holds". The query of uploaded rows has run in one real backup Job and in a restore's Job, and by hand on two dumps, 23 of 34 rows in dev and 28 of 41 in prod-sim, none with no object (`dr-gate2-real-backups-1.txt`). No backup has yet recorded a row with no object outside stubs, and retention has not yet kept a backup past `KEEP` in a real Job. What a fresh Plane holds on a resume is unmeasured: the check there expects 0 users, or the backup's count.
1. The sign-in steps by hand. Their labels come from this image's frontend build, and the password route behind them ran through the API. `scripts/ci/copy-to-local-registry.sh` has never run, and nobody has checked that GHCR holds these digests.
1. Everything in `rotate.sh` against real Postgres: socket trust, 127.0.0.1 trust versus pod-IP password checks, the probe route, the error window, and the Infisical backup it now takes at the end.
2. Argo CD and the operator's template annotations during a rotation (critique gate 8). The first sync is covered: `postgres-exporter` was patched once when `plane-pgdb` appeared and not again, and `monitoring-extras` stayed Synced. `rotate.sh` restarts by hand if the annotation is missing and reports a generation change as FAIL.
3. A clean install through the real waves. Here bootstrap ran with the operators already up, and the prod-sim ServiceAccounts and CRs were applied by hand ahead of wave 0, 19 minutes before `plane-prod-sim` existed. Argo CD then adopted them with the same UIDs, generation still 1 (`infisical-prod-sim-crs-1.txt`).
