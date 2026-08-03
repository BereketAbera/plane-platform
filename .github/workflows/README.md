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
in full. `images.yml` runs it on what it just built, with `SCAN_ONLY=built`, as in runs 41975430939 and 42044273310.

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

- **Workflows may open pull requests.** *Settings, Actions, General, Workflow permissions, Allow GitHub Actions to create and
  approve pull requests* has been on since 2026-11-05, by the owner's decision. `images.yml` opened #1 and `promote-prod-sim.yml`
  opened #2. With it off, as it was before, `promote-prod-sim.yml` edits, validates and pushes `promote/prod-sim`, then GitHub
  refuses the pull request, the run goes red at that step, and the failed run links to the page for opening it by hand. A second
  dispatch with the same inputs while that pull request is open succeeds and changes nothing, in run 41977288287.
- A pull request opened with `GITHUB_TOKEN` starts no job. GitHub does make a `ci` run for it, and holds it at `action_required`
  with no jobs and no log until someone approves it. Closing the pull request turned such a run to `failure`, still with no jobs,
  so that red run is no check's result: runs 41976206674, 42045522553 and 41977201138, the last being the red one. Those workflows run `validate-manifests.sh` themselves
  before opening it. No job of `ci.yml` has run on `on: pull_request` yet, and no person has opened a pull request here.
- **Native arm64 runners work here.** `ubuntu-24.04-arm` ran in this private repository, billed as `Actions Linux ARM` at
  $0.005 a minute against included compute. It had 2 cores, 7.7 GiB of memory and 34 GiB free on `/`. The x64 runner had
  14 GiB free. Those sizes come from one run, so treat them as what was seen, not as a promise. Run 41975430939 built, checked
  and published all four images in a job of 6 minutes 26 seconds, 321 seconds of it in the build step, billed as 7 minutes.
  Run 42044273310 did the same in 6 minutes 49 seconds, 325 seconds of it in the build step.
- **Included compute on Free is $12 a month**, shared by all of the account's private repositories: about 2,000 x64 minutes
  or 2,400 arm64 minutes. Without a payment method, GitHub blocks usage once it is spent. A build that reaches the
  90-minute timeout in `images.yml` costs $0.45.
- **`GITHUB_TOKEN` pushes to GHCR.** Runs 41975430939 and 42044273310 each pushed all four images to `ghcr.io/bereketabera/wayline/` and walked every
  layer again as GHCR served it. **The packages are private:** with no credentials, GHCR's token endpoint answered 401 for those
  names after the first build, 200 for a public image, and 403 for a name with no package. Do not push these names by hand: GitHub's documentation says
  `GITHUB_TOKEN` cannot push to a package that was pushed earlier without being connected to the repository. The prune job lists
  versions with that token and has deleted nothing in either run, so a delete with it is still untested.
- **The GHCR quota is documented, and the images have not met it.** GitHub's Packages billing page gives Free 500 MB of storage,
  shared with Actions artifacts, and 1 GB of transfer a month, then adds: "Container image storage and bandwidth for the Container
  registry is currently free." It promises a month's notice before that changes. Compressed, as run 41975430939 read them from
  GHCR: web 40.7, admin 30.3, space 263.9 and backend 97.4 MiB, 401.8 MiB counting each distinct layer once. Run 42044273310 added a second build, whose total no file here reads.
  `gh api users/<owner>/settings/billing/usage/summary` showed no packages row right after the push. The local `gh` token cannot
  read the package pages, because it lacks `read:packages`.
- Digests built in GitHub Actions live in GHCR, while Argo CD pulls from `localhost:5001`. After merging a digest bump, run
  `scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev`, which lower-cases the owner, and only then
  `make gitops-publish`, which does not look in the registry. Copying keeps the digest, and rebuilding would not: run 41975430939
  built from `9c8e098`, run 42044273310 from `76e98ee` and the Mac from `84b63d9`, and all their digests differ. The `docker login ghcr.io` the copy needs takes
  a token with `read:packages`, which the `gh` logins on this host do not have. Without it the script stops at its first image
  with a 401 and writes nothing, so it has never finished a copy. The digests the Mac built were never pushed to GHCR, so it
  cannot bring those back.
- **CI depends on GitHub serving each pinned tool.** Each job of `ci.yml` starts by fetching what it needs from release URLs, through
  `scripts/install-tools.sh`, so a job that cannot fetch one fails before any of its checks. On 2026-11-05 GitHub answered 504 for one release
  asset and then another, on and off: Manifests lost three attempts at `76e98ee`, and Lint lost a run at `7cde05a`, while GitHub's status page read
  All Systems Operational. `6edde64` lengthens the retries and keeps each job's tools in the Actions cache, keyed on `tools.lock`. Run 42048656380 at
  that commit passed all three jobs and saved those caches, and no run has restored one yet. A longer retry does not help a 504 that lasts longer than
  that, and a new `tools.lock` starts with no cache. [The evidence](../../docs/evidence/ci/README.md#the-504-on-a-pinned-tool) has each run.
- `$GITHUB_STEP_SUMMARY` output shows only on the run's page. `gh run view --json` and the check-run API do not return it.
  A scan's raw results stay on the runner, so of `images.yml`'s scan only its table in the log remains.
