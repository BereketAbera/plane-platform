# 0005. MinIO-compatible store (Silo) after official MinIO images ended

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Plane stores uploads through an S3 API, and its bundled option has always been MinIO. Official MinIO images are no longer anonymously available (research, 2026-11-04):

| Check | Result |
|---|---|
| `hub.docker.com` tags API for `minio/minio` and `minio/mc` | 404 |
| `registry-1.docker.io` manifest for `minio/minio:latest` | 401 |
| `quay.io` manifest with an anonymous token | 401 |
| GitHub `minio/minio` | `archived=true`, last push 2026-04-24 |

Plane's own compose file and the `plane-ce` 1.8.6 chart moved to `pgsty/silo`, a fork under AGPL-3.0.

## Decision

Each environment runs one Silo: `pgsty/silo:RELEASE.2026-10-26T00-00-00Z-distroless`, pinned by index digest. Documentation says "MinIO-compatible (Silo)" and explains why.

- **Kubernetes names stay `plane-minio`.** The chart names them that way, and renaming would mean more patches for no gain. `MINIO_*` variables also stay, because that is what Silo reads.
- **Distroless.** The chart's args fit its entrypoint, and the probes are HTTP, so no shell is needed.
- **Newer than upstream's pin.** Upstream pairs Plane v1.4.3 with `RELEASE.2026-09-16T00-00-00Z`. This repository pins a later distroless build. The 09-16 image is the fallback if the distroless build misbehaves.
- **The bucket is `uploads` in both environments.** `bgtasks/export_task.py:68` removes the literal `/uploads` from a URL, so any other name produces broken export links. Isolation comes from each environment having its own Silo, not from bucket names.
- **The chart's bucket Job is deleted.** Plane's `create_bucket` command makes the bucket. The Job adds an anonymous-download policy compose does not have, always exits 0, and pulls two more images.

## Alternatives considered

| Option | Maintained | Why not |
|---|---|---|
| Last official MinIO image | No. Frozen, no security fixes | Cannot be pulled anonymously |
| `bitnamilegacy/minio` | No. Labelled no longer updated | Older than the last upstream release. See [0015](0015-exclusions.md) |
| Build `minio/minio` from source | Self-maintained, upstream frozen | An image pipeline of our own for frozen code |
| AIStor Free | Yes, by the vendor | Terms unclear at the time of research, and it would replace the AGPL line with a vendor licence |
| Garage, SeaweedFS, RustFS | Varies | Not evaluated. Plane only needs S3 through `AWS_S3_ENDPOINT_URL`, so these remain an exit |

## Consequences

- Silo's [migration page](https://silo.pgsty.com/compatibility/migration/) states that `MINIO_*` variables, flags, on-disk formats, `minio_*` metrics and `/minio/*` routes are retained. That is the fork's claim, read in documentation. It held on real runs: presigned upload, download, avatar and export links all work against Silo in both environments, in steps `attachment-upload`, `attachment-download`, `object-in-silo`, `avatar` and `export` ([dev](../evidence/runs/smoke-dev-20261105T001213Z.json), [prod-sim](../evidence/runs/smoke-prod-sim-20261104T235926Z.json)).
- `create_bucket` swallows every error and exits 0. If Silo is not ready when api boots, the bucket is not created until api restarts. StatefulSets at wave 1 run before the api at wave 3, which should prevent this on a clean sync. On each environment's first boot the `uploads` bucket appeared at 21:35:37 and 21:49:14 UTC, within seconds of that api's start and before it read Ready ([state 2](../evidence/runs/plane-prod-sim-separation-state-2.txt), [first boot](../evidence/runs/plane-prod-sim-firstboot-1.txt)). Neither was a clean install.
- `patches/silo.yaml` runs Silo as UID 1000, while the image's default user is root. It starts and writes to its volume that way on kind's standard storage class. The image has no shell, so the UID comes from the pod spec ([plane-dev-psa-1.txt](../evidence/runs/plane-dev-psa-1.txt)), and the writes from the upload steps above and the restart drills.
- Memory is set to a 256Mi request and a 512Mi limit, because older MinIO containers on this host idled at 254.6 and 301 MiB (measured with `docker stats`, on an older release of the same lineage). This release peaked at 149 MiB in dev and 109 MiB in prod-sim under the smoke runs ([plane-prod-sim-memory-1.txt](../evidence/runs/plane-prod-sim-memory-1.txt)). The load test has not run. [[MEASURE: Silo RSS at idle and under the load test]]
- Project risk moves to a fork. The fork had 6 releases since 2026-08-04 at research time, and upstream Plane chose it, so support questions stay simple. An exit path exists through the S3 endpoint setting.
- Prometheus scrapes Silo's metrics endpoint without credentials, so `patches/silo.yaml` sets `MINIO_PROMETHEUS_AUTH_TYPE=public`. See [0012](0012-monitoring-without-backend-metrics.md).

## What we found when we ran it

Added 2026-11-05. The later distroless build did not misbehave, so the 09-16 fallback was not needed. The decision to run ahead of upstream's pin stands, and the pin is this repository's own. Contract section 9 now says so, because it read as if upstream had chosen this release.
