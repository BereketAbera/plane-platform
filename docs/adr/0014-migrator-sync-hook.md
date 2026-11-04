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

- A failed migration holds wave 3, so no Deployment changes. A bad backend digest should leave the old pods serving. [[VERIFY: a migrator forced to exit 1 stops the sync at wave 2 with existing Deployments unchanged, using tests/drills/failed-deploy-rollback.sh]]
- [[VERIFY: a fresh install completes in order, with wave 1 healthy, then the migrator, then wave 3]]
- **The hook runs on every sync operation,** not only when the backend image changes. That includes self-heal syncs, so an unrelated drift correction re-runs `migrate`. Django migrations are idempotent, so the expected cost is one more short Job. [[MEASURE: migrator wall time on a fresh database and on an up-to-date database]]
- Applications use unlimited retry with `refresh: true`, because automated sync does not re-attempt a failed commit, and finite retries would strand an app on first boot. So a broken migrator retries until a revert lands. A revert should land during those retries. [[VERIFY: a reverted commit is applied while the failed hook is retrying]]
- **Migrations go forward only.** `make rollback` reverts a digest, not a schema. If a new image has migrated the database, the old image runs against the new schema. For prod-sim, the Postgres dump taken at promotion is the way back. See [disaster recovery](../disaster-recovery.md).
- Memory limits and CPU limits may slow a first run. The 900-second deadline was chosen without a measurement behind it. [[VERIFY: the first migration run finishes inside activeDeadlineSeconds and the 512Mi limit]]
- With `BeforeHookCreation` the last Job and its pod remain until the next sync replaces them, so its logs stay readable.
