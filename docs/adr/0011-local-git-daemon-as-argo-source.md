# 0011. Local git daemon as Argo CD's source in Pass 1

**Status:** Accepted, 2026-11-04.

## Context

Argo CD needs a Git URL it can reach from inside the cluster. The repository is on GitHub (`origin`, private), where CI runs. The obvious setup is to point Argo CD at GitHub.

That has costs for a local platform:

- A private repository means a deploy key or token inside the cluster, in the first Application, before Infisical exists. That is one more secret-zero item.
- Every change would need a push and CI before it could be tried on a laptop.
- Cluster state would depend on an external service for a platform that is meant to be rebuilt locally.

Whatever serves Git also cannot be something Argo CD deploys, because Argo CD cannot deploy what it reads its first manifest from.

## Decision

`plane-git`, a Compose container on the `kind` Docker network, serves `.local/git/plane-platform.git` read-only at `git://plane-git/plane-platform.git`. Argo CD reads branch `main` from there. **Argo CD does not read GitHub in Pass 1.** GitHub runs CI only.

- It is read-only three ways: `git daemon` has no `receive-pack` enabled, the volume is mounted `:ro`, and the container filesystem is read-only. It runs as UID 65534 with a 64 MiB memory limit.
- `make gitops-publish` is the only writer. It pushes `main` from the working repo to the bare repo on the host's file path.
- The push is a plain fast-forward. A rewrite is refused, since Argo CD would follow it with no record. Reverts are the way back.
- The bare repo holds nothing unique, so it can be deleted and republished from the working repo at any time.
- A publish that changes a prod-sim image digest takes a backup first, unless `SKIP_BACKUP=yes`. A promotion merged on GitHub reaches the cluster at this step, so this is where the dump has to happen. Since `3a67ba0` it also requires `plane-dev` to be running that digest, Synced and Healthy.

**Where code and research differ.** `infra-versions.md` proposed `gitd` as a Deployment inside the cluster, in a `gitops` namespace at PSA `baseline`, with a hostPath volume. Baseline forbids hostPath (CRITIQUE.md C7). The code moved the daemon out of the cluster, which removes the PSA question and lets it outlive the cluster.

## Alternatives considered

| Option | Footprint | Why not |
|---|---|---|
| GitHub as Argo CD's source | No local process | Credential in the cluster, a push for every change, and a dependency on an external service |
| Soft Serve | About 20 to 50 MiB, an estimate from `infra-versions.md` | `charmbracelet/soft-serve` is archived, and its README announces no further security updates (research, 2026-11-04). See [0015](0015-exclusions.md) |
| Gitea | 100 to 250 MiB, an estimate from Gitea's guidance and `infra-versions.md` | Solid, but stateful, with a database and more to reseed. Remains a fallback |
| In-cluster `gitd` with a hostPath | Small | Fails PSA `baseline`, and is lost with the cluster |
| `git http-backend` | Small | Remains the fallback if Argo CD cannot use `git://` |

## Consequences

- No credential for Git exists anywhere in the cluster. The repository holds no secrets, which CI enforces separately.
- `git://` has no TLS and no authentication. Anything on the `kind` Docker network, and any pod with an egress rule to port 9418, can read the repository. Argo CD does no signature check, so it applies whatever the bare repo holds.
- **Merging on GitHub does not deploy anything.** A person has to run `make gitops-publish`. It warns about commits that are not on `origin/main` (`d6f3b9a`) and goes on, so an unreviewed local commit can be published. In Pass 1 the deploy control is who can write to this laptop, not a review gate.
- This is not fully offline. Platform charts are Argo CD Helm sources, so repo-server still reaches public chart repositories over HTTPS, and images come through caches that need upstream on a miss.
- Gate 5 in `tests/gates/day1.sh` records PASS for a pod resolving `plane-git` and running `git ls-remote` over `git://` ([evidence](../evidence/day1-gates-20261104T231136Z.txt)). That shows name resolution and the protocol from a pod.
- Argo CD syncs over `git://plane-git/plane-platform.git` at v3.5.7, with no protocol restriction. On 2026-11-04 `git ls-remote` with Argo CD's own binary answered in the repo-server pod ([netpol-real-pods-1.txt](../evidence/runs/netpol-real-pods-1.txt)), and the Applications that read this source have synced from it since ([plane-prod-sim-snapshot-final-1.txt](../evidence/runs/plane-prod-sim-snapshot-final-1.txt)).
- Published commits have reached Argo CD many times, including the promotions on 2026-11-05. Two published runs that follow a commit to Argo CD annotated the Application first, and their output prints only `annotated`, so it does not name the annotation ([argocd-root-terminate-1.txt](../evidence/runs/argocd-root-terminate-1.txt), [plane-prod-sim-sync-check-1.txt](../evidence/runs/plane-prod-sim-sync-check-1.txt)). Applications also retry with `refresh: true`, and an attempt logs `Retrying operation with latest revisions` ([argocd-root-terminate-1.txt](../evidence/runs/argocd-root-terminate-1.txt), [infisical-unready-sync-1.txt](../evidence/runs/infisical-unready-sync-1.txt)), though those files do not show a new commit arriving through one. The record of `4f622e3` does not say how that commit arrived. In the controller's log from 00:36 to 02:28 UTC that day, each automated sync to a new commit, `62699c9` and `0af8956` among them, came right after a hard refresh ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt)). So nothing published shows a commit applied by polling alone. A watch on a throwaway Application, with no refresh asked for, saw a new revision 43s after a publish that had nothing to apply ([argo-sync-unknown-2.txt](../evidence/runs/argo-sync-unknown-2.txt)). On 2026-11-05 `make rollback ENV=dev` and `make promote ENV=dev`, whose scripts ask for no refresh, published `91ef477` and `29316f2`, and `plane-dev` started a sync at each new revision 4s and within 1s later ([DEP-2-20261105T064032Z-timeline.txt](../evidence/runs/DEP-2-20261105T064032Z-timeline.txt)). The controller logged a normal refresh asked for by annotation at each of those syncs, and its log does not say who asked ([argocd-refresh-reasons-1.txt](../evidence/runs/argocd-refresh-reasons-1.txt)). So those gaps do not show a commit applied with no refresh, and how long polling alone takes to apply one has not been measured.
- `make promote ENV=prod-sim` ran for real at `0af8956` and `9c8e098` on 2026-11-05. It took the dump itself before its commit, so the publish after it took none ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt), [promote-prod-sim-final-2.txt](../evidence/runs/promote-prod-sim-final-2.txt)). A publish that takes the dump itself, for a digest from a merged pull request, has run only against a stubbed `kubectl`. On a real cluster: Not tested in Pass 1.
- `git_repo_url` is a Terraform variable, and `sourceRepos` follows it, so Pass 2 can point at GitHub. Every Application under `gitops/applications` also hard-codes the `git://` URL, so that move is more than one variable.

## What we found when we ran it

Added 2026-11-05. The decision held. `plane-git` needed one fix: Compose recreated it on every `make up`, because buildx stamped a provenance attestation that gave the same layers a new image ID, and Argo CD reads Git through that container. `7708cc8` turned the attestation off.

`ci.yml` and the promotion workflow first ran on GitHub on 2026-11-04, from `f733b87`, and `images.yml` built nothing then, because `apps/wayline/images.txt` was not on main. The first real image build and both pull requests came on 2026-11-05 at `9c8e098`, after pushes had been on hold, and `ci.yml` also ran at `0dde813`. `ci.yml` passes, `images.yml` published four private GHCR packages and opened pull request 1, which stayed open and unmerged until 2026-11-07, and promotion pull request 2 was opened and closed as a test ([ci evidence](../evidence/ci/README.md)). The push of `76e98ee`, later that day, built the images again and force-updated pull request 1. In Pass 1 no merge on GitHub reached the cluster. On 2026-11-07 pull request 1 was merged as `6204af2`, and its digests reached dev through `make gitops-publish`, after a copy into the local registry ([copy](../evidence/runs/DEV-VALIDATE-copy-publish-20261107T050522Z.txt)). A publish ahead of `origin/main` still warns, and the drills' commits did.
