# 0016. Datastore versions: Postgres 15, Valkey 7.2, RabbitMQ 3.13

**Status:** Accepted, 2026-11-04. A restore into a new cluster is not yet recorded.

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
- Patch bumps are low risk, not zero. Plane migrates and serves on postgres 15.19, Valkey 7.2.15 and RabbitMQ 3.13.7 in both environments: `make test-e2e` passes on them, on earlier images ([dev](../evidence/runs/smoke-dev-20261105T001213Z.json), [prod-sim](../evidence/runs/smoke-prod-sim-20261104T235926Z.json)) and on the final images: 45 PASS and 1 SKIP in dev, 44 PASS and 1 SKIP in prod-sim ([smoke-dev-20261105T070735Z-94252.json](../evidence/runs/smoke-dev-20261105T070735Z-94252.json), [smoke-prod-sim-20261105T053533Z-8468.json](../evidence/runs/smoke-prod-sim-20261105T053533Z-8468.json)). That shows what those steps reach.
- The `celery` queue has 1 consumer, and a task round trip completes on 3.13.7, in steps `celery-consumers` and `background-job`, in 3.1s on those runs. The job also ran after each data pod restarted ([dev drill](../evidence/runs/drill-pod-restart-dev-20261104T224424Z.log)), with one exception in the last section. On the final images the drill passed again in both environments ([dev](../evidence/runs/drill-pod-restart-dev-20261105T070414Z.log), [prod-sim](../evidence/runs/drill-pod-restart-prod-sim-20261105T072331Z.log)).
- RabbitMQ reports the absolute watermark from `conf.d`: step `broker-memory` reads `{absolute,"256Mi"}` from `rabbitmq-diagnostics`, with no alarms, in both environments.
- Postgres, Valkey and RabbitMQ run under their non-root patches on kind's standard storage class, as UIDs 70, 999 and 100 ([dev](../evidence/runs/plane-dev-psa-1.txt), [prod-sim](../evidence/runs/plane-prod-sim-host-and-identity-1.txt)).
- Memory against the contract's limits, MiB, in dev then prod-sim. Postgres: quiet 66 and 34 by `kubectl top` ([snapshot](../evidence/runs/plane-prod-sim-snapshot-final-1.txt)), highest cgroup peak read 173 and 202 of 512. Valkey: highest peak 19 and 15 of 96. RabbitMQ: quiet 136 and 128, highest peak 250 and 222 of 512 ([dev](../evidence/runs/plane-dev-memory-1.txt), [prod-sim](../evidence/runs/plane-prod-sim-memory-1.txt)). Those peaks are from smoke runs, not a load test, and cgroup peak includes page cache.
- `pg_dump` refuses a server newer than itself, so `scripts/backup.sh` reads the running server's image and uses that. `make backup` works on postgres 15.19, and each dump restores into a scratch database in the same Job ([dr-backup-dev-1.txt](../evidence/runs/dr-backup-dev-1.txt)). The restore Job also ran into a scratch database and bucket ([dr-plane-restore-rehearsal-1.txt](../evidence/runs/dr-plane-restore-rehearsal-1.txt)). On 2026-11-05 `make backup` and then `make restore BACKUP=latest CONFIRM=yes` round-tripped in place on postgres 15.19 in both environments. Each restore ended PASS, with row counts and content hashes equal to the backup, and `make test-e2e` passed after it: 45 PASS and 1 SKIP in dev, 44 PASS and 1 SKIP in prod-sim ([dev](../evidence/runs/BKP-2-20261105T074322Z.txt), [prod-sim](../evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt)). With no `CONFIRM` the prod-sim restore refused and changed nothing ([refusal](../evidence/runs/restore-prod-sim-20261105T073428Z.json)). Those ran in the same cluster, on the same volumes, minutes after the backup, over data that had not been lost, so they do not show a restore into a new cluster. That rebuild has finished, and its evidence is not published yet. [[VERIFY: data across the rebuild, with dev, prod-sim and Infisical restored from backup into a new cluster]]
- Valkey has no password here and holds transient data, so NetworkPolicy is the only access control on it. Losing it loses the cache and locks, not user data.
- A future major bump of Postgres is a dump and restore, not an in-place change, since the StatefulSet's volume format is tied to the major.

## What we found when we ran it

Added 2026-11-05. The versions hold, and the explicit watermark was the right call: the broker's alarm did not fire, and RabbitMQ's real peak stayed under the 512Mi limit.

The one failure was Celery's, not RabbitMQ's. In prod-sim on 2026-11-04 jobs stopped after a broker restart, because the smoke test's control had already run `cancel_consumer` and `add_consumer` on that worker. On a clean worker the consumer came back in 34s and the job ran ([plane-prod-sim-worker-broker-restart-1.txt](../evidence/runs/plane-prod-sim-worker-broker-restart-1.txt)). The first pod restart drill there ended FAIL for that reason, and the second PASS ([FAIL](../evidence/runs/drill-pod-restart-prod-sim-20261104T233500Z.log), [PASS](../evidence/runs/drill-pod-restart-prod-sim-20261104T235402Z.log)). The trap of RabbitMQ 4.3 remains unrun here, and `PlaneCeleryQueueMissing` has been seen pending, not firing.
