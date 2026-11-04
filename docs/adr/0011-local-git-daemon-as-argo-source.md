# 0011. Local git daemon as Argo CD's source in Pass 1

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

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
- A publish that changes a prod-sim image digest takes a backup first, unless `SKIP_BACKUP=yes`. A promotion merged on GitHub reaches the cluster at this step, so this is where the dump has to happen.

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
- **Merging on GitHub does not deploy anything.** A person has to run `make gitops-publish`. Nothing checks that local `main` matches `origin/main`, so an unreviewed local commit can be published. In Pass 1 the deploy control is who can write to this laptop, not a review gate.
- This is not fully offline. Platform charts are Argo CD Helm sources, so repo-server still reaches public chart repositories over HTTPS, and images come through caches that need upstream on a miss.
- Gate 5 in `tests/gates/day1.sh` records PASS for a pod resolving `plane-git` and running `git ls-remote` over `git://` ([evidence](../evidence/day1-gates.txt)). That shows name resolution and the protocol from a pod. It does not show an Argo CD sync.
- [[VERIFY: Argo CD syncs an Application over git://plane-git/plane-platform.git, with no protocol restriction at v3.5.7]]
- [[VERIFY: a commit published by make gitops-publish reaches Argo CD and is applied, without a manual refresh]]
- [[VERIFY: the promotion backup runs when a publish changes a prod-sim image digest]]
- `git_repo_url` is a Terraform variable, and `sourceRepos` follows it, so Pass 2 can point at GitHub. Every Application under `gitops/applications` also hard-codes the `git://` URL, so that move is more than one variable.
