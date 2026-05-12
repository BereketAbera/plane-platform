# 0015. Exclusions: Bitnami, cert-manager, CloudNativePG, Soft Serve

**Status:** Accepted, 2026-11-04.

## Context

Each of these is a common default for a Kubernetes platform. A reader will ask why they are missing. Leaving them out was a decision, not an oversight, and each exclusion has a condition that would reverse it.

All status facts here come from research on 2026-11-04 and may change.

## Decision

**Bitnami: use nothing from it.** No Bitnami chart or image.

- `docker.io/bitnami/postgresql` lists only `latest` and `latest-metadata`, plus signature tags. The chart default `bitnami/postgresql:17.6.0-debian-12-r4` returned 404 on Hub, so chart defaults do not pull unless overridden.
- `bitnami/minio` has zero tags. `bitnami/rabbitmq` lists none.
- `bitnamilegacy/*` is labelled no longer updated, with its last update in 2025-08.
- Infisical's chart bundles legacy Bitnami Postgres and Redis with default passwords. `helm/values/infisical.yaml` turns those subcharts off and `infisical/manifests/` supplies its own.

**cert-manager: not in Pass 1.** Nothing terminates TLS locally (contract section 3). The Plane chart's certificate templates activate only with `ssl.createIssuer` and `ssl.generateCerts`, and the overlays set neither.

**CloudNativePG: not in Pass 1.** Its benefits are backups, failover and declarative users. On one node, failover has nowhere to go. Backups are handled by `make backup`, which runs `pg_dump -Fc`. It would add an operator (chart suggests 100 to 200 MiB, an estimate taken from the chart's own guidance) and move Postgres away from the Plane chart's StatefulSet.

**Soft Serve: not used.** `charmbracelet/soft-serve` is archived, and its README announces no further security updates. One research note recommended it. CRITIQUE.md C6 overruled that. See [0011](0011-local-git-daemon-as-argo-source.md).

## Alternatives considered

| Component | What using it would give | Why that is not enough now |
|---|---|---|
| `bitnamilegacy` images | Ready-made images with arm64 | Frozen. Pins a security problem in place |
| Bitnami Secure Images | A maintained line | A vendor product, with terms not reviewed here. Upstream images by digest are simpler |
| cert-manager with self-signed certificates | HTTPS locally | Browser warnings and a CA to trust, for no gain on loopback. It would also make local behaviour differ from Pass 2's Cloudflare termination |
| CloudNativePG | Operator-managed Postgres, PITR | Memory, a CRD set and a chart divergence. Single-node HA is not real HA |
| Gitea in place of Soft Serve | A maintained forge | Stateful and heavier. Kept as a fallback in [0011](0011-local-git-daemon-as-argo-source.md) |

## Consequences

- **Bitnami:** Images are upstream's own, by digest, so each needs its own non-root and probe work. `helm/values/infisical.yaml` holds the only mention in tracked code. No CI rule enforces this exclusion at the time of writing, so it is held by review.
- **cert-manager:** Local traffic is plain HTTP, including login cookies, on loopback only. Certificate behaviour is not exercised in Pass 1, so TLS issues will first appear in Pass 2. The Pass 2 design intends edge termination at Cloudflare, which may keep cert-manager optional.
- **CloudNativePG:** No point-in-time recovery, no replicas, and no automated failover. Recovery point is the last dump. See [disaster recovery](../disaster-recovery.md). The chart's Postgres is a single pod, so its restart is an outage. It stays the candidate path for Pass 2 if real durability is required.
- **Soft Serve:** Git hosting is a bare repo with no UI and no access control beyond the laptop.
- **What would reverse each:** Bitnami, nothing foreseeable. cert-manager, if origin certificates are managed in-cluster. CloudNativePG, if a multi-node cluster and a stated recovery target exist. Soft Serve, only if the project is revived.
