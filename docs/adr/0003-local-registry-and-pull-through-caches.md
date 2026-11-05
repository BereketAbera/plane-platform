# 0003. Local registry and pull-through caches instead of `kind load`

**Status:** Accepted, 2026-11-04. What the clean rebuild shows is not yet recorded.

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
| `kind load docker-image` | Reported to fail on this image store, as above. Not reproduced here, because nothing calls it |
| `docker image save --platform` piped to `kind load image-archive` | Reportedly fails on images with attestations |
| Disable Docker's containerd image store | Changes the whole host, including unrelated containers |
| Registry inside the cluster | Lost on `kind delete cluster`, and cannot serve images the cluster needs in order to start |
| Node pulls directly from upstream, no cache | Spends quota on every rebuild, and repeats every download |
| Authenticated Hub pull-through with a `config.json` at `/var/lib/kubelet/config.json` | Puts a real credential on the node. CRITIQUE.md suggested it so that the Hub fallback is authenticated. Not implemented. See Consequences |

## Consequences

- Branded and upstream images share one mechanism, and both environments reference images the same way, by digest.
- Cached blobs outlive the cluster, so a rebuild should not re-download. `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` deletes the cluster and keeps the local registry and pull-through caches, so it could test this. It has finished, and no file from that run reads a mirror's access log, so it did not record whether it pulled from them rather than upstream.
- Disk use grows. The Docker Hub set is 2.28 GiB compressed, summed from registry metadata on 2026-11-04. The four registry volumes held 3.89 GB on 2026-11-05 at 02:01 UTC, with the whole platform up: the Docker cache 2.486, `plane-registry` 0.919, the Quay cache 0.448 and the Kubernetes cache 0.038 ([dr-disk-1.txt](../evidence/runs/dr-disk-1.txt)). That is this host after staged bring-ups and several builds, not what a clean `make up` leaves. [[MEASURE: disk growth of a first install, from the clean install in make drill-clean-restore]]
- `mirror.gcr.io` is not complete. Blob fetches for `plane-live` and the Infisical operator returned 404 there during research, so a pull depends on falling through to Docker Hub. containerd's fallback was read in source, not run at this level of the stack. An image with blobs absent from `mirror.gcr.io` completing through the Docker Hub fallback: Not tested in Pass 1.
- **That fallback is anonymous.** No credential is configured, so a blob missing from the mirror can still hit the Hub quota.
- Gate 1 in `tests/gates/day1.sh` records PASS for digest pulls from `docker.io`, `quay.io` and `localhost:5001`, and, since 2026-11-04, for containerd having asked each of `plane-mirror-docker` and `plane-mirror-quay` for that digest in that run, read from the mirror's access log ([day1-gates-20261104T231136Z.txt](../evidence/day1-gates-20261104T231136Z.txt)). That covers one small image per path, and no gate covers `plane-mirror-k8s`. It does not cover the Hub fallback, and for a layer already on the node it shows the route, not the bytes.
- The registries speak plain HTTP on the `kind` Docker network, with no authentication. Only `plane-registry` is published to the host, and only on loopback.
- `make images` and CI run the same script, `scripts/ci/build-images.sh`. They differ in registry prefix, in `WAYLINE_TURBO_CONCURRENCY` and `WAYLINE_HEAP_MB`, which `images.yml` sets lower for its runner, and in the host of the native build, this Mac or a Linux arm runner. Their digests do not match: the images `images.yml` published at `9c8e098` have other digests than the local build, and share only part of their layers ([compare](../evidence/ci/ci-4-20261105T060219Z-published-compare.txt)). So what CI publishes is not what the cluster runs until it is copied and promoted, which has not happened. Pass 2 is expected to replace this Compose file with GHCR. That is intent, not configuration.

## What we found when we ran it

Added 2026-11-05.

- The whole image set reached the node under this configuration on 2026-11-04, and the branded images came from `localhost:5001` by digest on 2026-11-05 ([running pods](../evidence/runs/cluster-readings-2.txt)). Which blobs fell through to Docker Hub was not recorded.
- Mirror pulls are slow, and the kubelet pulls one image at a time. Wave 3's four images took 175s, 216s, 52s and 5s in turn on the first boot ([plane-dev-firstboot-1.txt](../evidence/runs/plane-dev-firstboot-1.txt)), which is why `progressDeadlineSeconds` went from 360 to 600.
- `plane-registry` was OOM-killed at 128m during the first branded pushes. The registry's own memory is not the cause: a push fills the container's cgroup with dirty page cache faster than the disk drains it. On scratch registries 128m was killed in 8 of 17 runs pushing with buildx or all at once, and 512m kept the largest push off the limit entirely, so that is the limit now ([registry-memory-1.txt](../evidence/runs/registry-memory-1.txt)).
