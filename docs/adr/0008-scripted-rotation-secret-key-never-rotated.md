# 0008. Scripted rotation, and `SECRET_KEY` is never rotated

**Status:** Accepted, 2026-11-04. `make rotate` ran for real in both environments on 2026-11-05 and ended PASS ([dev](../evidence/runs/rotate-dev-20261105T072345Z.log), [prod-sim](../evidence/runs/rotate-prod-sim-20261105T073240Z.log)). A rotation killed partway was finished by `RESUME=yes` in prod-sim. Another, killed the same way on the restored cluster, was undone by `ROLLBACK=yes` ([SEC-4b](../evidence/runs/SEC-4b-20261105T084615Z.txt)).

## Context

The platform should show that a credential can change through the secret store and take effect in the application. Native secret rotation and dynamic secrets are paid features on this Infisical tier ([0007](0007-self-hosted-infisical-per-environment-projects.md)). So rotation has to be scripted.

Which secret to rotate matters more than it first appears.

**`SECRET_KEY` must not be rotated.** It derives the key that encrypts secret-class instance configuration rows, 7 of them per the contract, and 7 by count on a real instance ([smoke-dev-20261104T225856Z.json](../evidence/runs/smoke-dev-20261104T225856Z.json)). `make backup` then adds an eighth, its own sentinel. `decrypt_data` logs and returns `""` on failure, so after a rotation those rows read as empty with no visible error. Sessions are invalidated too. A failure that quiet is the worst outcome for a demonstration of good practice.

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
| `GET /api/instances/` | Cached in Valkey for two hours, answers 200 with Postgres down. It stayed 200 through each Postgres round of the pod restart drill on 2026-11-04, each under a minute ([monitoring-history-reads-1.txt](../evidence/runs/monitoring-history-reads-1.txt)). | `/api/public/anchor/__probe__/settings/`, where a 404 with "does not exist" needs the database |

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

- This is scripted rotation with an error window. It is not native, scheduled or per-pod credentials. The one replica restarts with a password Postgres may not accept yet. In dev a signed-in request sampled about once a second answered 500 from 07:23:51 to 07:24:29 UTC on 2026-11-05, about 38s from just after `ALTER ROLE` until the new api pod was ready: 38 of the 1,002 samples taken up to 07:40:19, with every other one answering 200 ([watch](../evidence/runs/SEC-2-20261105T072331Z-watch.txt)). The script's own once-a-second probe printed 60s in dev, 39 of 62 failed, and 39s in prod-sim, 37 of 60 failed (the logs above). Dev's number reads high: the probe is anonymous and counts anything but its 404 as a failure, Plane answered that route with 429 after 30 requests ([precheck](../evidence/runs/SEC-2-throttle-precheck-20261105T061924Z.txt)), and its last three failures came 19s after the signed-in request had recovered, though its log keeps no status code ([probe](../evidence/runs/rotate-dev-20261105T072345Z.probe)). No signed-in request is on record for prod-sim, so 39s there is the script's number alone. That is one run each. `make test-load ENV=dev` started alongside prod-sim's rotation, but its k6 container started only at 07:33:48 UTC, 22s after prod-sim's last failed probe, so dev was not under k6 load during those 39s ([run](../evidence/runs/LOAD-1-20261105T073240Z-run.txt), [windows](../evidence/runs/LOAD-3-20261105T074543Z-prometheus-windows.json)).
- The role is a shared superuser, so rotation does not reduce what a leaked password can do while it is valid.
- In-flight Jobs keep their old environment.
- The journal holds both passwords on disk until the rotation finishes. It is inside `.local/secret-zero/`, mode 0600, and gitignored.
- Changing `PG_PASSWORD` by hand in the Infisical UI does not change the role. Plane then fails at its next restart. Only the script keeps both sides together.
- After `make rotate ENV=dev` the old password was refused and the new one accepted, by `psql` over the pod IP and by `psycopg` over the Service, while a random value was refused as the control. Before the rotation, the same checks accepted the old password ([SEC-2-20261105T072331Z-old-value.txt](../evidence/runs/SEC-2-20261105T072331Z-old-value.txt)). In prod-sim the script's own check read the same, old refused and new accepted over TCP, in both rotations ([first](../evidence/runs/rotate-prod-sim-20261105T073240Z.log), [resumed](../evidence/runs/rotate-prod-sim-20261105T073847Z.log)).
- Plane used a new database connection after that rotation. `scripts/rotate.sh` read the anchor route's 404, which needs a database login with what the pods now hold, and the running api, worker and beat pods no longer held the old value ([log](../evidence/runs/rotate-dev-20261105T072345Z.log), [same file](../evidence/runs/SEC-2-20261105T072331Z-old-value.txt)).
- `SECRET_KEY` did not move. The script compared it before and after, and each rotation logged `SECRET_KEY unchanged` (the logs above). Encrypted instance configuration still decrypts: the in-place restore after each environment's first rotation read its encrypted sentinel back as the seeded value, with no row decrypting to nothing ([dev](../evidence/runs/restore-dev-20261105T074337Z.json), [prod-sim](../evidence/runs/restore-prod-sim-20261105T073438Z.json)). That check found one encrypted row with a value, the sentinel, so the other encrypted rows held nothing to test. It was not repeated after prod-sim's second rotation.
- The operator's restart annotations caused no Argo CD self-heal loop. In dev `plane-dev` stayed Synced through the rollout, and its last sync operation stayed the one from 06:49:44 UTC until [the self-heal test](../evidence/runs/GITOPS-4-20261105T073240Z.txt) started its own at 07:32:41. No other had started when the watch ended at 07:40:51 ([SEC-6-20261105T072331Z-application-watch.txt](../evidence/runs/SEC-6-20261105T072331Z-application-watch.txt)). In each rotation the script saw workload generations stay still for 20s after the rollout (the logs above). So the watch is about 17 minutes in dev and 20s in prod-sim.
- A rotation stopped partway is recovered by `RESUME=yes`. In prod-sim on 2026-11-05 `make rotate` got SIGKILL 4 seconds in, after `ALTER ROLE` and before the rollouts finished. `RESUME=yes` kept Infisical at the same version, found Postgres accepting the new password and refusing the replaced one, finished the rollouts and ended PASS ([SEC-4-20261105T073843Z.txt](../evidence/runs/SEC-4-20261105T073843Z.txt), [log](../evidence/runs/rotate-prod-sim-20261105T073847Z.log)). Its probe printed 57s, 46 of 55 failed, counted from the resume and not from the kill. k6 was running on dev through the kill and the resume. That is one stop at one point, and the resume ran with `SKIP_BACKUP=yes`, so it took no Infisical backup. `ROLLBACK=yes` undid another such run at 08:46Z, once, at the same point ([SEC-4b](../evidence/runs/SEC-4b-20261105T084615Z.txt)).
- **A leaked `SECRET_KEY` has no scripted response.** Handling it would mean generating a new key and re-entering the encrypted configuration rows. That procedure is not written or tested in Pass 1. See [known limitations](../known-limitations.md).
- `SECRET_KEY` must match the database it was used with. A restored Plane database with a freshly generated key breaks instance configuration silently, so the two are restored as a matched set. See [disaster recovery](../disaster-recovery.md).
- A missing `SECRET_KEY` fails unevenly: api aborts in `configure_instance`, while worker, beat and migrator silently take a random key (`settings/common.py:32`). The Secret contract requires the key for this reason.
