# Workflows

Each workflow is a thin wrapper over a script that `make` runs too. Nothing here talks to the cluster:
Argo CD reads the local Git remote in pass 1, and only `make gitops-publish` writes to it.

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | pull request, push to main | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `security.sh`, with no secrets |
| `images.yml` | changes under `apps/wayline`, to `scripts/ci/build-images.sh`, or to `images.yml` itself | Builds images. On main, pushes to GHCR, records digests, opens a digest-bump PR for dev |
| `wayline-upstream-check.yml` | weekly, manual dispatch | Dry-runs the Wayline overlay and patches against an upstream ref, default `preview`, and reports the size of the work. Builds and pushes nothing |
| `promote-prod-sim.yml` | manual dispatch | Opens a PR copying a digest already recorded for dev to prod-sim. Never rebuilds |

`scripts/ci/negative-controls.sh` shows that the checks can fail. It plants one defect at a time in a throwaway
clone and requires the matching check to go red. It takes minutes, so `make ci` does not run it.

`scripts/ci/test-promotion-flows.sh` runs `promote.sh`, `rollback.sh`, `gitops-publish.sh` and the failed-deploy drill
against a stub `kubectl`. The full `validate-manifests.sh` runs it. It proves how the scripts behave given those answers,
and nothing about a real cluster.

`make scan-images` runs trivy over every image the platform runs. It fails only on a CRITICAL finding with a fix in an image
we build, or on an image it could not scan, and reports everything else. It needs a few GiB of transfer, so no workflow runs it
in full. `images.yml` should run it on what it just built, with `SCAN_ONLY=built`.

The runs behind every statement below are in [docs/evidence/ci/](../../docs/evidence/ci/README.md), along with
what has not run yet.

## What GitHub does and does not enforce on this plan

The repository is private on the GitHub Free plan. For a private repository that plan has **no environment
reviewers or wait timers, no protected branches, no rulesets, no code owners, and no artifact attestations**.
The branch protection and ruleset APIs answer 403 here. The rest comes from GitHub's documentation.

So production approval here is a process, not a control:

- `promote-prod-sim.yml` opens a pull request, and a person merging it is the approval.
- **GitHub cannot enforce that.** Anyone with write access can merge their own pull request, push straight
  to `main`, or skip CI. `CODEOWNERS` does nothing on this plan, so it does not even request a review.
- What is enforced is in the scripts: `scripts/promote.sh` and `scripts/ci/check-promoted-digests.sh` refuse a prod-sim
  digest dev never recorded for that image. CI runs that check, but nothing makes a failing check block a merge.
- Run locally, `scripts/promote.sh` also refuses unless plane-dev is Synced and Healthy with that digest in a ready container.
  `promote-prod-sim.yml` has no cluster in reach, so there the check is skipped, and the run and the commit message
  (`Promote-Dev-Check: skipped`) say so. `make gitops-publish` then runs it after the merge, and refuses to publish a prod-sim
  digest dev has not proven unless `OVERRIDE_DEV_CHECK="<reason>"` is set. `rollback.sh` publishes with `SKIP_DEV_CHECK`, so an
  emergency does not depend on dev. Both reasons go in `.local/evidence-raw/promotion-overrides.log`.
- In pass 1 a merge changes nothing running. It reaches the cluster only when someone pulls `main` and runs
  `make gitops-publish`, which takes a prod-sim backup first if the change touches a prod-sim image.

## Settings and limits to know

- **Workflows may not open pull requests yet.** *Settings, Actions, General, Workflow permissions, Allow GitHub Actions
  to create and approve pull requests* is off, the default for a repository under a personal account. With it off,
  `promote-prod-sim.yml` edits, validates and pushes `promote/prod-sim`, then GitHub refuses the pull request and the run
  goes red at that step. `images.yml` uses the same action for `bump/dev-images`, so expect the same there, although no
  run has reached that step. Turning it on is the owner's decision. The alternative is to open the pull request by hand
  from the pushed branch, and the failed run links to the page for that.
- A pull request opened with `GITHUB_TOKEN` does not trigger `on: pull_request`, so CI does not run on it.
  Those workflows run `validate-manifests.sh` themselves before opening it. A pull request a person opens does start CI.
- **Native arm64 runners work here.** `ubuntu-24.04-arm` ran in this private repository, billed as `Actions Linux ARM` at
  $0.005 a minute against included compute. It had 2 cores, 7.7 GiB of memory and 34 GiB free on `/`. The x64 runner had
  14 GiB free. Those sizes come from one run, so treat them as what was seen, not as a promise.
- **Included compute on Free is $12 a month**, shared by all of the account's private repositories: about 2,000 x64 minutes
  or 2,400 arm64 minutes. Without a payment method, GitHub blocks usage once it is spent. A build that reaches the
  90-minute timeout in `images.yml` costs $0.45.
- **`GITHUB_TOKEN` is accepted for a GHCR push, but no image has been pushed.** With `packages: write` GHCR opened an upload
  session for `ghcr.io/bereketabera/wayline/ci-probe`, and with `packages: read` or no packages permission it answered 403.
  That proves the permission, not a whole push or a recorded digest. Do not push these names by hand first: GitHub's
  documentation says `GITHUB_TOKEN` cannot push to a package that was pushed earlier without being connected to the repository.
- **The GHCR quota is documented, not measured.** GitHub's Packages billing page gives Free 500 MB of storage, shared with
  Actions artifacts, and 1 GB of transfer a month, then adds: "Container image storage and bandwidth for the Container
  registry is currently free." It promises a month's notice before that changes. So the 500 MB should not limit `ghcr.io`
  today, but nothing has been stored there to prove it. After the first push, read
  `gh api users/<owner>/settings/billing/usage/summary` and the package page. The upstream arm64 images for web, admin,
  space and backend total 437 MiB compressed, not counting shared layers. Wayline's own sizes are not measured yet.
- Digests built in GitHub Actions live in GHCR, while Argo CD pulls from `localhost:5001`. After merging a digest bump, run
  `scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev`. Copying keeps the digest, and rebuilding would not.
  The `docker login ghcr.io` it needs takes a token with `read:packages`, which the `gh` logins on this host do not have.
- `$GITHUB_STEP_SUMMARY` output shows only on the run's page. `gh run view --json` and the check-run API do not return it.
