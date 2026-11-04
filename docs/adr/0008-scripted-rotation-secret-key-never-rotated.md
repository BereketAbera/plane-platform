# 0008. Scripted rotation, and `SECRET_KEY` is never rotated

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked. `scripts/rotate.sh` has been exercised against stubs only (`infisical/README.md`).

## Context

The platform should show that a credential can change through the secret store and take effect in the application. Native secret rotation and dynamic secrets are paid features on this Infisical tier ([0007](0007-self-hosted-infisical-per-environment-projects.md)). So rotation has to be scripted.

Which secret to rotate matters more than it first appears.

**`SECRET_KEY` must not be rotated.** It derives the key that encrypts secret-class instance configuration rows, 7 of them per the contract. `decrypt_data` logs and returns `""` on failure, so after a rotation those rows read as empty with no visible error. Sessions are invalidated too. A failure that quiet is the worst outcome for a demonstration of good practice.

**`LIVE_SERVER_SECRET_KEY` proves nothing.** In v1.4.3, `requireSecretKey` in `apps/live/src/lib/auth-middleware.ts` appears only as a definition and in a comment. No route uses it, so an old value cannot be shown to fail (CRITIQUE.md C22).

**`PG_PASSWORD` can be demonstrated.** The role can be changed in place, and the old value can be shown to fail.

## Decision

`make rotate ENV=dev` runs `scripts/rotate.sh`. It rotates only `PG_PASSWORD`. Prod-sim also requires `CONFIRM=yes`.

1. Preflight: Infisical, both Secrets and Postgres agree, Plane answers, and a random password is rejected, which shows the check can fail at all.
2. Write both passwords to a journal in `.local/secret-zero/rotation-<env>/`, then write the new one to Infisical as a new version.
3. Nudge the custom resources and wait for the operator to update `plane-pgdb` and `plane-app-env`.
4. Run `ALTER ROLE` over the socket, with the statement on stdin and kept out of the server log.
5. Wait for rollouts, then record the proofs in `.local/evidence-raw/rotate-<env>-<stamp>.log`, which holds no values.

Each step checks real state rather than trusting a log, so `RESUME=yes` and `ROLLBACK=yes` run the same code aimed at a different password.

Two details exist because the obvious check would pass falsely:

| Obvious check | Why it proves nothing | What the script uses |
|---|---|---|
| Login over `127.0.0.1` | The image's `pg_hba.conf` trusts it, so any password passes | Login over the pod IP, which reaches `scram-sha-256` |
| `GET /api/instances/` | Cached in Valkey for two hours, answers 200 with Postgres down. [[VERIFY: /api/instances/ stays 200 with Postgres stopped]] | `/api/public/anchor/__probe__/settings/`, where a 404 with "does not exist" needs the database |

The script compares `SECRET_KEY` before and after, and records whether it moved.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Infisical native rotation | Paid on this tier |
| Dynamic per-pod Postgres credentials | Paid on this tier |
| Rotate `SECRET_KEY` with a re-encryption step | Would have to be written and tested against Plane's encrypted configuration rows. Not attempted. A failure would be silent |
| Rotate `LIVE_SERVER_SECRET_KEY` as the demo | Nothing consumes it, so there is nothing to observe |
| Rotate RabbitMQ or Silo credentials too | Separate procedures, not scripted in Pass 1 |
| Only update Infisical and restart pods | Postgres would keep the old password until its role is altered, and the next restart would fail |

## Consequences

- This is scripted rotation with an error window. It is not native, scheduled or per-pod credentials. The one replica restarts with a password Postgres may not accept yet. [[MEASURE: error window in seconds from the per-second probe during make rotate, for dev and prod-sim]]
- The role is a shared superuser, so rotation does not reduce what a leaked password can do while it is valid.
- In-flight Jobs keep their old environment.
- The journal holds both passwords on disk until the rotation finishes. It is inside `.local/secret-zero/`, mode 0600, and gitignored.
- Changing `PG_PASSWORD` by hand in the Infisical UI does not change the role. Plane then fails at its next restart. Only the script keeps both sides together.
- [[VERIFY: after make rotate ENV=dev the old password is rejected and the new one accepted over the pod IP]]
- [[VERIFY: Plane uses a new database connection after rotation, shown by the anchor probe returning 404 does not exist]]
- [[VERIFY: SECRET_KEY is unchanged after rotation and instance configuration rows still decrypt]]
- [[VERIFY: the operator's restart annotations do not cause an Argo CD self-heal loop during rotation]]
- [[VERIFY: a rotation stopped partway is recovered by RESUME=yes and by ROLLBACK=yes]]
- **A leaked `SECRET_KEY` has no scripted response.** Handling it would mean generating a new key and re-entering the encrypted configuration rows. That procedure is not written or tested in Pass 1. See [known limitations](../known-limitations.md).
- `SECRET_KEY` must match the database it was used with. A restored Plane database with a freshly generated key breaks instance configuration silently, so the two are restored as a matched set. See [disaster recovery](../disaster-recovery.md).
- A missing `SECRET_KEY` fails unevenly: api aborts in `configure_instance`, while worker, beat and migrator silently take a random key (`settings/common.py:32`). The Secret contract requires the key for this reason.
