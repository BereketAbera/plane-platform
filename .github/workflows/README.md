# Workflows

Each workflow is a thin wrapper over a script that `make` runs too. Nothing here talks to the cluster:
Argo CD reads the local Git remote in pass 1, and only `make gitops-publish` writes to it.

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | pull request, push to main | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `security.sh`, with no secrets |
| `images.yml` | changes under `apps/wayline` | Builds images. On main, pushes to GHCR, records digests, opens a digest-bump PR for dev |
| `promote-prod-sim.yml` | manual dispatch | Opens a PR copying a digest already recorded for dev to prod-sim. Never rebuilds |

## What GitHub does and does not enforce on this plan

The repository is private on the GitHub Free plan. That plan has **no environments with required reviewers,
no protected branches, and no artifact attestations** for private repositories.

So production approval here is a process, not a control:

- `promote-prod-sim.yml` opens a pull request, and a person merging it is the approval.
- **GitHub cannot enforce that.** Anyone with write access can merge their own pull request, push straight
  to `main`, or skip CI. `CODEOWNERS` only requests a review.
- What is enforced is in the scripts: `scripts/promote.sh` and `scripts/ci/check-promoted-digests.sh` refuse a prod-sim
  digest never recorded for dev. CI runs that check, but nothing makes a failing check block a merge.
- In pass 1 a merge changes nothing running. It reaches the cluster only when someone pulls `main` and runs
  `make gitops-publish`, which takes a prod-sim backup first if the change touches a prod-sim image.

## Settings and limits to know

- Enable *Settings, Actions, General, Allow GitHub Actions to create and approve pull requests*, or the two PR
  workflows fail at their last step.
- A pull request opened with `GITHUB_TOKEN` does not trigger `on: pull_request`, so CI does not run on it.
  Those workflows run `validate-manifests.sh` themselves before opening it.
- GHCR gives a private repository on Free 500 MB of storage, shared with Actions artifacts, and 1 GB of transfer a month. One
  full image set is close to that limit (estimate: about 450 MiB compressed, not measured), so old versions need pruning.
- Digests built in GitHub Actions live in GHCR, while Argo CD pulls from `localhost:5001`. After merging a digest bump, run
  `scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev`. Copying keeps the digest, and rebuilding would not.
