# 0014. The migrator is an Argo CD `Sync` hook, not `PreSync`

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Plane's schema migrations run as a Job from the chart. They must run after Postgres is up and before the application rolls out.

`PreSync` is the common recommendation for migrations, and one research note (`cicd-security.md`) proposed it. Here it deadlocks a fresh install:

1. The chart's Postgres is a StatefulSet in the same Application. It is applied in the `Sync` phase.
2. A `PreSync` hook runs before that phase, so the database does not exist.
3. Plane's `wait_for_db` does not wait. It touches `connections["default"]`, which never opens a connection, so `OperationalError` cannot fire.
4. `migrate` fails. The entrypoint is `set -e`. The Job exhausts `backoffLimit: 3`.
5. A failed `PreSync` hook stops the sync, so Postgres is never created.

The Job also has a constant name, `plane-api-migrate-1`, and a Job's template is immutable. A plain Job would fail to apply as soon as its image digest changed.

## Decision

The overlay patches the Job into a `Sync` hook at wave 2:

```yaml
argocd.argoproj.io/hook: Sync
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
argocd.argoproj.io/sync-wave: "2"
```

| Wave | Resources |
|---|---|
| 1 | StatefulSets: postgres, redis, rabbitmq, silo |
| 2 | Migrator Job |
| 3 | Deployments: api, worker, beat, web, admin, space, live |

- `BeforeHookCreation` deletes the previous Job first, which solves the immutable template.
- `activeDeadlineSeconds: 900` bounds a stuck run. The chart's `backoffLimit: 3` stays.
- **No `ttlSecondsAfterFinished`.** Argo CD can wait forever on a hook that Kubernetes has already deleted.
- It runs as UID 1000 with `HOME=/tmp`, a 128Mi request and a 512Mi limit.

Ordering comes from Argo CD's wave gating on health: the wave 1 StatefulSets must be healthy before wave 2 starts. Since `wait_for_db` does not wait, that gate is the only thing holding the migrator back.

## Alternatives considered

| Alternative | Why not |
|---|---|
| `PreSync` hook | Deadlocks a fresh install, as above. It would be workable only if Postgres lived in another Application |
| `PostSync` hook | Deployments would start against an unmigrated schema |
| Plain Job at wave 2, with no hook | Constant name plus immutable template fails on the next image change |
| `initContainer` on the api | Runs on every replica start and restart, and races. It also does not stop worker and beat from starting first |
| Move Postgres to a separate Application, so `PreSync` works | One more Application per environment, and it departs further from the chart's shape |
| Patch `wait_for_db` to really wait | A change in Plane's code for a problem that ordering solves |

## Consequences

- A failed migration holds wave 3, so no Deployment changes, and the old pods keep serving. `tests/drills/failed-migrator.sh` ended PASS in dev on 2026-11-05. It promoted a backend whose migrator exits 1 through the real path. The Job failed at 58s with `BackoffLimitExceeded`, Deployment generations, images and pods equalled the start on all 67 samples, and the host answered 200 on all of them (`.local/evidence-raw/DEP-3-20261105T064517Z-drill.txt`, raw output that is not published yet). `tests/drills/failed-deploy-rollback.sh` could not test this, because it uses a web image. One migrator built to fail is not every way a migration can fail, and this one changed no schema.
- On dev's first boot on 2026-11-04 the order held: the last StatefulSet's image finished at 21:32:35 UTC and the migrator started then, its 164 migrations ended at 21:35:12, and wave 3 started at 21:35:15 ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt)). That boot was not a clean install. [[VERIFY: a fresh install completes in order, with wave 1 healthy, then the migrator, then wave 3]]
- **The hook runs on every sync operation,** not only when the backend image changes. That includes self-heal syncs, so an unrelated drift correction re-runs `migrate`. Django migrations are idempotent, so the expected cost is one more short Job. Measured on 2026-11-04: on a fresh database 164 migrations took 83s, after a 69s image pull. On an up-to-date database the Job took 9s and applied nothing ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt), [plane-prod-sim-firstboot-1.txt](../evidence/runs/plane-prod-sim-firstboot-1.txt)).
- Applications use unlimited retry with `refresh: true`, because automated sync does not re-attempt a failed commit, and finite retries would strand an app on first boot. So a broken migrator retries until a revert lands. A revert does land during those retries: in the same drill it was published at 362s, the migrator ran again on the old image and succeeded, and `plane-dev` read Synced and Healthy with no operation open 251s after the publish, with no Deployment changed and no pod replaced. Plan for minutes there, since the wait follows the retry's backoff.
- **Migrations go forward only.** `make rollback` reverts a digest, not a schema. If a new image has migrated the database, the old image runs against the new schema. For prod-sim, the Postgres dump taken at promotion is the way back. See [disaster recovery](../disaster-recovery.md).
- Memory limits and CPU limits may slow a first run. The 900-second deadline was chosen without a measurement behind it. The first run took 83s and was not OOM-killed under the 512Mi limit, so 900 has room. Nobody read its peak memory.
- With `BeforeHookCreation` the last Job and its pod remain until the next sync replaces them, so its logs stay readable.
