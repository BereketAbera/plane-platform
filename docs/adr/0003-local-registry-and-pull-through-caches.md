# 0003. Local registry and pull-through caches instead of `kind load`

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

The cluster needs branded images that exist only locally, plus many upstream images. Three constraints shaped how they get onto the node.

**`kind load` is reported not to work with this host's image store. This platform did not reproduce the failure, because the design never calls it.** kind runs `ctr images import --all-platforms --digests`. With Docker's containerd image store, which this host uses (`driver-type: io.containerd.snapshotter.v1`), that fails with a missing content digest. This is kind issue #3795, listed in [kind's known issues](https://kind.sigs.k8s.io/docs/user/known-issues/) and re-confirmed on v0.33.0 (research, 2026-11-04). The documented workaround, `docker image save --platform`, reportedly fails on images with attestations, and Plane's image indexes carry attestation manifests. The other workaround turns off the containerd store for the whole host, which would affect unrelated containers. kind issue #2394 separately records that loaded images and digest references do not work together.

**Every image is referenced by digest** (contract section 5). So the node has to resolve digests through a registry.

**Docker Hub's anonymous quota runs out.** On 2026-11-04 at 17:55 UTC the research pass saw `ratelimit-remaining: 0` and HTTP 429, on `HEAD` as well. A full build needs about 21 Hub images, so about 40 or more manifest requests. That is an estimate from counting images, with at least two manifest requests per image. Two fresh builds in one window would exhaust the quota. `docker login` on the laptop does not help, because kind nodes pull with their own containerd.

## Decision

Docker Compose runs four registry containers on the `kind` Docker network (`infrastructure/local-services/compose.yaml`). They live outside the cluster so that they survive `kind delete cluster`.

| Container | Role | Reached by the node through |
|---|---|---|
| `plane-registry` | Holds branded images. Published on `127.0.0.1:5001` for pushes from the host | `certs.d/localhost:5001/hosts.toml` to `http://plane-registry:5000` |
| `plane-mirror-docker` | Pull-through cache in front of `mirror.gcr.io`. Falls through to `registry-1.docker.io` via `server` | `certs.d/docker.io/hosts.toml` |
| `plane-mirror-quay` | Pull-through cache for `quay.io` | `certs.d/quay.io/hosts.toml` |
| `plane-mirror-k8s` | Pull-through cache for `registry.k8s.io` | `certs.d/registry.k8s.io/hosts.toml` |

`scripts/ci/build-images.sh` builds with `--provenance=false --sbom=false`, so a digest names one plain manifest and survives a copy between registries. It then confirms the registry serves that digest.

Digests are what make a mirror safe to trust: containerd verifies content against the pinned hash, whichever host served it.

**Where code and research differ.** Research named `registry:3.1.2` from Docker Hub. The code uses `ghcr.io/distribution/distribution:3.1.2` by digest, so that setup spends no Hub quota. Research also proposed `mirror.gcr.io` directly in `hosts.toml`, and the code puts a local cache in front of it. The code is what runs.

## Alternatives considered

| Alternative | Why not |
|---|---|
| `kind load docker-image` | Fails on this host, as above |
| `docker image save --platform` piped to `kind load image-archive` | Reportedly fails on images with attestations |
| Disable Docker's containerd image store | Changes the whole host, including unrelated containers |
| Registry inside the cluster | Lost on `kind delete cluster`, and cannot serve images the cluster needs in order to start |
| Node pulls directly from upstream, no cache | Spends quota on every rebuild, and repeats every download |
| Authenticated Hub pull-through with a `config.json` at `/var/lib/kubelet/config.json` | Puts a real credential on the node. CRITIQUE.md suggested it so that the Hub fallback is authenticated. Not implemented. See Consequences |

## Consequences

- Branded and upstream images share one mechanism, and both environments reference images the same way, by digest.
- Cached blobs outlive the cluster, so a rebuild should not re-download. [[VERIFY: a second cluster build after kind delete pulls from the local caches rather than upstream]]
- Disk use grows. The Docker Hub set is 2.28 GiB compressed, summed from registry metadata on 2026-11-04. [[MEASURE: on-disk size of the four registry volumes after a full make up]]
- `mirror.gcr.io` is not complete. Blob fetches for `plane-live` and the Infisical operator returned 404 there during research, so a pull depends on falling through to Docker Hub. containerd's fallback was read in source, not run at this level of the stack. [[VERIFY: an image with blobs absent from mirror.gcr.io completes through the Docker Hub fallback]]
- **That fallback is anonymous.** No credential is configured, so a blob missing from the mirror can still hit the Hub quota.
- Gate 1 in `tests/gates/day1.sh` records PASS for digest pulls from `docker.io`, `quay.io` and `localhost:5001`, and for the cache holding blobs ([evidence](../evidence/day1-gates.txt)). That covers one small image per path. It does not cover the full image set or the Hub fallback.
- The registries speak plain HTTP on the `kind` Docker network, with no authentication. Only `plane-registry` is published to the host, and only on loopback.
- `make images` and CI differ only in registry prefix. Pass 2 is expected to replace this Compose file with GHCR. That is intent, not configuration.
