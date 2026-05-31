# 0007. Self-hosted Infisical with one project per environment

**Status:** Accepted, 2026-11-04. The layer has run on the real cluster since then, and what that changed is in the last section. Runtime validation pending where still marked.

## Context

The platform brief names Infisical as the secret store. The rendered manifests must contain zero `kind: Secret`, and each environment must be unable to read the other's secrets.

An unlicensed self-hosted instance has its own feature set, which differs from Infisical Cloud's pricing page. It was read from `backend/src/ee/services/license/license-fns.ts` at `Infisical/infisical@v0.167.6` (research, 2026-11-04):

| Feature | Unlicensed self-hosted |
|---|---|
| Custom roles and folder RBAC (`rbac`) | Off. Rejected at `role-service.ts:92,131` |
| Additional project privileges | 400 on projects created today |
| Secret rotation, dynamic secrets | Off |
| Audit log retention | 0 days |
| Identities, projects, environments | No limit |
| Secret versioning | On |
| Rate limits | 40 secret requests, 60 reads, 200 writes per minute. Not enforced when it ran: see the last section |

So there is no way on this tier to grant a reader one environment inside a project. The only available boundary is the project.

## Decision

- Infisical v0.167.6 runs in the `infisical` namespace, with its own Postgres and Redis. The chart's bundled subcharts stay off: Bitnami images are frozen legacy, and ingress-nginx is archived.
- **One project per Plane environment:** `plane-dev` and `plane-prod-sim`. Each holds one Infisical environment, slug `prod`. The slug is `prod` in the dev project too, so one `InfisicalStaticSecret` shape fits both. It does not mean production.
- **One machine identity per project**, with built-in project role `viewer` and org role `no-access`.
- **Kubernetes Auth.** The only auth value stored in a Plane namespace is an identity id. The operator mints a short-lived ServiceAccount token for each login. The client JWT acts as its own reviewer.
- A separate Terraform root, `infisical/terraform`, manages projects, environments, identities and auth config. Values never enter Terraform: `scripts/infisical-seed.sh` generates them in memory and sends them through the API.
- Secret zero (`ENCRYPTION_KEY`, `AUTH_SECRET`, database passwords) lives in `.local/secret-zero/`, directory 0700 and files 0600.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Infisical Cloud | Its free plan has different limits (5 identities, 3 environments, no versioning, research, 2026-11-04). Secret values would leave the laptop, and the platform would need the internet to start |
| One project with `dev` and `prod-sim` environments | The obvious layout. Without custom roles, a reader sees every environment in its project, so a compromised dev identity could read prod-sim |
| A paid licence for custom roles | Out of scope for a free local platform. It would also hide what the free tier can and cannot do |
| Universal Auth | A long-lived client secret in a Kubernetes Secret, valid from any address, since trusted IP limits are paid. Kept as a fallback if Kubernetes Auth fails on kind |
| Chart's bundled Postgres and Redis | Frozen Bitnami images with default passwords. The chart's docs call them for testing |

## Consequences

- **Isolation is per project, not finer.** A reader sees every secret in its own project. On 2026-11-04 the `plane-dev` identity got 403 reading the `plane-prod-sim` project, and the reverse, on list, single read and slug lookup ([infisical-isolation-3.txt](../evidence/runs/infisical-isolation-3.txt)).
- **Both environments share one Infisical server.** An outage stops updates in both, while existing Kubernetes Secrets remain. One `ENCRYPTION_KEY` protects both. This is one more place where namespace separation is not equivalent to independent production clusters.
- Secret zero moves the problem to the laptop rather than solving it. Kubernetes Secrets are base64 in kind's etcd, unencrypted at rest. Losing `ENCRYPTION_KEY` everywhere loses every secret, even with a database dump.
- `ALLOW_INTERNAL_IP_CONNECTIONS=true` is required for token review on kind, because `kubernetes.default.svc` resolves to a private address. It relaxes SSRF protection for the whole instance. That is acceptable on a single-user local instance, and needs a new decision for Pass 2.
- No audit trail of who read what. Secret version history is the only record.
- The operator polls, since instant updates are paid. `refreshInterval` is 60s, and that is the update latency. Six custom resources polling every 60s per operator saw no 429 during steady-state polling or first-time seeding ([infisical-rate-limit-1.txt](../evidence/runs/infisical-rate-limit-1.txt)). The reason differs from what this record expected, as the last section says.
- `InfisicalAuth` stays unready until bootstrap publishes the identity Secret. On 2026-11-04 the sync failed and retried rather than failing for good: the identity was published at 21:25:44 UTC, and the retry landed at 21:28:54 ([infisical-unready-sync-1.txt](../evidence/runs/infisical-unready-sync-1.txt)).
- First boot runs about 600 migrations under a 1Gi limit and a 640 MiB heap. On arm64 on 2026-11-04 it ran 602 in 11.5s, from container start to Ready in 21s, peaking at 807 MiB with 0 OOM kills ([infisical-firstboot-1.txt](../evidence/runs/infisical-firstboot-1.txt)). Pulling the image took 4m49s before that.
- The layer's own memory use was estimated at 610 to 990 MiB, summed from per-component rows in `infisical.md`, anchored on issue #4795. Measured at idle on 2026-11-04 by `kubectl top`: server 646 MiB, Postgres 55 MiB, Redis 9 MiB, operators 22 and 38 MiB, about 770 MiB in all ([infisical-memory-1.txt](../evidence/runs/infisical-memory-1.txt)).

## What we found when we ran it

Added 2026-11-05. Nothing in this layer failed at runtime on its first real run, and the boundary held. Three things read differently now.

- **The rate limits in the table above are not enforced on self-hosted.** They were read from the licence file. 240 reads in 4s from one address all answered 200 with no rate-limit headers, and `app.ts` registers the limiter only when `isProductionMode && isCloud` ([infisical-rate-limit-1.txt](../evidence/runs/infisical-rate-limit-1.txt)). So the `Retry-After` handling in the scripts has never run for real.
- **The server's memory request went from 650Mi to 768Mi,** on measured idle use. Its peak on a second boot was 822 MiB of the 1Gi limit ([infisical-second-boot-1.txt](../evidence/runs/infisical-second-boot-1.txt)).
- **A restart costs a little.** The API went silent for about 12s when Redis restarted, and reads answered 500 for about 6s when Postgres did ([infisical-restart-1.txt](../evidence/runs/infisical-restart-1.txt)). Existing Kubernetes Secrets stay in place through that.
