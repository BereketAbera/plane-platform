# 0016. Datastore versions: Postgres 15, Valkey 7.2, RabbitMQ 3.13

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Plane upstream pins three data services for v1.4.3, through its compose files and chart values:

| Service | Upstream pin |
|---|---|
| PostgreSQL | `postgres:15.7-alpine` |
| Valkey | `valkey/valkey:7.2.11-alpine` |
| RabbitMQ | `rabbitmq:3.13.6-management-alpine` |

Those tags are old. A newer major is tempting, for support and for scanner results. But upstream tests against these lines, and this platform carries no patches to make other lines work.

RabbitMQ has a specific trap. makeplane/helm-charts PR #304, open at research time, reports that Celery consumers on the `celery` queue were 1 on 3.13.6, 1 on 4.2.9, and 0 on 4.3.5, with error 541 on pidbox queues. The report places the fix in a private repository (`plane-ee#9162`). `CELERY_CONTROL_QUEUE_EXCLUSIVE`, the setting associated with that fix, is absent from CE v1.4.3. On 4.3 the broker looks healthy while no worker attaches.

## Decision

Stay on upstream's major and minor lines, and take the newest patch within each. All are pinned by index digest (contract section 9).

| Service | Pin | Change from upstream |
|---|---|---|
| PostgreSQL | `postgres:15.19-alpine` | Patch bump |
| Valkey | `valkey/valkey:7.2.15-alpine` | Patch bump |
| RabbitMQ | `rabbitmq:3.13.7-management-alpine` | Patch bump. Last release in the series |

**RabbitMQ must stay on 3.13 or 4.2 (contract section 9).** `4.2.9-management-alpine` is a candidate for dev only. It is not configured today.

**RabbitMQ memory is set explicitly:** `vm_memory_high_watermark.absolute = 256Mi` in `conf.d`, with a 512Mi limit. The default relative watermark is 0.4, and RabbitMQ's docs say it may not detect a cgroup limit. If it detects the 512Mi limit, 0.4 is about 205 MiB, just above the idle range of 140 to 200 MiB (an estimate anchored on a third-party Railway template figure for v1.4.2, not measured here), so publishers could block and hang `.delay()`. If it misses the limit, 0.4 of the VM's memory means an OOM kill.

Infisical's own data services are separate and follow its needs: `postgres:16.15-alpine` and `redis:7.2.17-alpine` in `infisical/manifests/`. They are not shared with Plane.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep upstream's exact pins | Patch releases are the low-risk fix. The 15.7 image was built in 2024 |
| Postgres 16 or later | Untested by upstream for this release, and a major upgrade path to own. Migrations use no extensions, so it may well work, but there is no gain in Pass 1 |
| Redis in place of Valkey | Upstream moved to Valkey. No reason to differ |
| RabbitMQ 4.3.x | Celery attaches no consumers, per PR #304. One research note named it as the first promotion target, and CRITIQUE.md C8 overruled that |
| RabbitMQ 4.2.9 as the default | The next safe step on paper. CE on 4.x has not been run here. Keep 3.13 until a dev test has |
| Redis as Celery's broker | Mechanically possible through `AMQP_URL`. Undocumented upstream, and long tasks would meet Redis's visibility-timeout redelivery |
| `rabbitmq:3.13.7-alpine`, without the management plugin | Would save memory. The management image matches upstream, and a lean mode can come later |

## Consequences

- **RabbitMQ 3.13 is out of community support.** Support ended on 30 September 2024, per [RabbitMQ's release information](https://www.rabbitmq.com/release-information), and 3.13.7 is the last patch. It gets no fixes, and scanners will flag it. This is an accepted risk for Pass 1 only, and it should be re-decided before anything leaves this laptop. See [known limitations](../known-limitations.md).
- The version constraint comes from Plane, not from RabbitMQ. It lifts when CE ships the control-queue fix. Each Plane upgrade should re-check PR #304.
- `PlaneCeleryQueueMissing` exists to catch the 4.3 failure mode, and it would also catch a similar regression on any version. See [0012](0012-monitoring-without-backend-metrics.md).
- Patch bumps are low risk, not zero. Compatibility with these exact patches is unproven until they run. [[VERIFY: Plane migrates and serves on postgres 15.19, Valkey 7.2.15 and RabbitMQ 3.13.7 in both environments]]
- [[VERIFY: the celery queue has at least one consumer and a task round trip completes on 3.13.7]]
- [[VERIFY: RabbitMQ reports the absolute 256Mi watermark from conf.d, using rabbitmq-diagnostics]]
- [[VERIFY: Postgres, Valkey and RabbitMQ run under their non-root patches on kind's standard storage class]]
- [[MEASURE: idle and peak RSS of Postgres, Valkey and RabbitMQ in each environment, to compare with the contract section 10 limits]]
- `pg_dump` refuses a server newer than itself, so `scripts/backup.sh` reads the running server's image and uses that. [[VERIFY: make backup and make restore round-trip on postgres 15.19]]
- Valkey has no password here and holds transient data, so NetworkPolicy is the only access control on it. Losing it loses the cache and locks, not user data.
- A future major bump of Postgres is a dump and restore, not an in-place change, since the StatefulSet's volume format is tied to the major.
