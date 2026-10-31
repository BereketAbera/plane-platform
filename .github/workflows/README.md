# Workflows

Each workflow is a thin wrapper over a script that `make` runs too. Nothing here talks to a cluster. On kind, Argo CD reads the local
Git remote, and only `make gitops-publish` writes to it. Hosted production's Argo CD reads `deploy/plane-prod` on GitHub, which
`ci.yml`'s `release-plane-prod` job moves after a push to main, though any job with `contents: write` could push it, as below.

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | pull request, push to main | `scripts/ci/lint.sh`, `validate-manifests.sh`, `ownership.sh`, `test-prod-gate.sh`, `check-capacity.sh`, `security.sh`, with no secrets. Then, on main, `release-plane-prod` moves `deploy/plane-prod` |
| `images.yml` | changes under `apps/wayline`, to `scripts/ci/build-images.sh`, or to `images.yml` itself | Builds `linux/amd64` images natively on x86-64. On main, pushes to GHCR, records digests, scans them, runs them by digest, and opens a digest-bump PR for dev. Deletes nothing |
| `wayline-upstream-check.yml` | weekly, manual dispatch | Dry-runs the Wayline overlay and patches against an upstream ref, default `preview`, and reports the size of the work. Builds and pushes nothing |
| `promote-prod-sim.yml` | manual dispatch | Opens a PR copying a digest already recorded for dev to prod-sim. Never rebuilds |
| `promote-plane-prod.yml` | manual dispatch, with a set's hash | Opens a PR moving hosted production to a set dev has signed evidence for, once `check-prod-evidence.sh` and `validate-manifests.sh` pass on it. Never rebuilds. After the merge, `release-plane-prod` moves `deploy/plane-prod` |
| `promote-app.yml` | manual dispatch | Opens a PR pointing one image of Rillmark, Awushi Cloudgarden or Frameflow at a digest its own repository published, through `scripts/ci/promote-app.sh`, which edits the app's manifest and `policy/hosted-images.txt` together. One branch per app, `promote/<app>`. Never rebuilds, and cannot read those private packages, so it does not look the digest up. [docs/hosted-apps.md](../../docs/hosted-apps.md) says how a person does |
| `check-deploy-branch.yml` | daily, manual dispatch | Goes red if `deploy/plane-prod` differs from what its `RELEASE.json` says, which means someone pushed it by hand. Changes nothing, and has not run on GitHub yet |
| `scan-hosted.yml` | weekly, manual dispatch | `make scan-images-hosted`: scans what hosted production runs, as main says, for `linux/amd64`, from the registries alone: what the hosted tree, its charts and its render name, K3s's own images and the probes' images. Reads the render on `deploy/plane-prod` too, and its report says whether that branch's trees differ from main's. Has `packages: read` for the private Wayline images, and for the apps' once each of their packages grants this repository Read access, under Manage Actions access: until then it fails on their images. Keeps the report as an artifact. Has not run on GitHub yet |

`scripts/ci/negative-controls.sh` shows that the checks can fail. It plants one defect at a time in a throwaway
clone and requires the matching check to go red. It takes minutes, so `make ci` does not run it.

`scripts/ci/test-promotion-flows.sh` runs `promote.sh`, `rollback.sh`, `gitops-publish.sh` and the failed-deploy drill
against a stub `kubectl`. The full `validate-manifests.sh` runs it. It proves how the scripts behave given those answers,
and nothing about a real cluster. `scripts/ci/test-grafana-admin.sh` does the same for `scripts/hosted/grafana-admin.sh`: the
password file, the Secret and the admin a running Grafana pod holds must agree after each verb, and after each step of one fails.
`validate-manifests.sh` runs it, with the charts or without them. `scripts/ci/test-hosted-target.sh` sources
`scripts/hosted/target.sh` with no cluster: which environments it hands Infisical's bootstrap and Terraform, and that it leaves
the apps' out for a restore of Infisical alone, refused anywhere else before it reaches for the cluster. `lint.sh` runs it.

`make scan-images` runs trivy over every image the platform runs, for `PLATFORM`, by default `linux/arm64`. It fails only on a
CRITICAL finding with a fix in an image we build, on an image it could not scan, or on a result of another architecture, and reports
everything else. After a digest bump dev runs `linux/amd64` digests under Rosetta, so a full scan on the laptop then needs
`SCAN_ALSO_PLATFORM=linux/amd64`. It needs a few GiB of transfer, so no workflow runs it in full. `images.yml` runs it on what it
just built, with `SCAN_ONLY=built` and `PLATFORM=linux/amd64`. Runs 41975430939 and 42044273310 did that for `linux/arm64`.

`images.yml` also runs `apps/wayline/checks/smoke-images.sh` on that x86-64 runner, against the digests it just published, and a
failure stops the digest bump. That step has not run on a runner yet. Run by hand, on the Mac, it passed for `linux/arm64` images.

The runs behind every statement below are in [docs/evidence/ci/](../../docs/evidence/ci/README.md), along with
what has not run yet.

## What GitHub does and does not enforce on this plan

The repository is private on the GitHub Free plan. For a private repository that plan has **no environment
reviewers or wait timers, no protected branches, no rulesets, no code owners, and no artifact attestations**.
The branch protection and ruleset APIs answer 403 here. The rest comes from GitHub's documentation.

So production approval here is a process, not a control:

- `promote-prod-sim.yml`, `promote-plane-prod.yml` and `promote-app.yml` each open a pull request, and a person merging it is the
  approval.
- **GitHub cannot enforce that.** Anyone with write access can merge their own pull request, push straight
  to `main`, or skip CI. `CODEOWNERS` does nothing on this plan, so it does not even request a review.
- The same goes for `deploy/plane-prod`, which hosted Argo CD syncs: anyone with write access can push it, and so can any job with
  `contents: write`. `publish-release.sh`, `check-deploy-branch.yml` and `make remote-status` go red if it differs from what its `RELEASE.json`
  says. They notice a push, and by then Argo CD may have deployed it. Only a paid plan or verification on the cluster would prevent one.
- What is enforced is in the scripts: `scripts/promote.sh` and `scripts/ci/check-promoted-digests.sh` refuse a prod-sim
  digest dev never recorded for that image. CI runs that check, but nothing makes a failing check block a merge.
- For the apps beside Wayline, `scripts/ci/promote-app.sh` holds the manifest and `policy/hosted-images.txt` to one and the
  same image string, and refuses one named anywhere else Argo CD reads. Nothing confirms the digest itself: `publish-release.sh`
  confirms Wayline's on GHCR and no others, so a wrong one shows only after the sync, as ImagePullBackOff.
- Run locally, `scripts/promote.sh` also refuses unless plane-dev is Synced and Healthy with that digest in a ready container.
  `promote-prod-sim.yml` has no cluster in reach, so there the check is skipped, and the run and the commit message
  (`Promote-Dev-Check: skipped`) say so. `make gitops-publish` then runs it after the merge, and refuses to publish a prod-sim
  digest dev has not proven unless `OVERRIDE_DEV_CHECK="<reason>"` is set. `rollback.sh` publishes with `SKIP_DEV_CHECK`, so an
  emergency does not depend on dev. Both reasons go in `.local/evidence-raw/promotion-overrides.log`.
- On kind a merge changes nothing running. It reaches the cluster only when someone pulls `main` and runs
  `make gitops-publish`, which takes a prod-sim backup first if the change touches a prod-sim image. On hosted production a push to
  `main` is a deploy: once CI passes, `release-plane-prod` moves `deploy/plane-prod`, and Argo CD syncs it.

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
- **`images.yml` builds on `ubuntu-24.04`, because the VPS is x86-64, and has not yet run there.** That runner, on this plan, was
  measured at about 2 cores and 7 GiB of memory, with about 14 GiB free on `/`. So each job first removes `/usr/local/lib/android` and
  `/opt/hostedtoolcache/CodeQL`, which hold nothing it uses, and allows two build tasks.
- **Native arm64 runners work here, and `images.yml` used them until then.** `ubuntu-24.04-arm` ran in this private repository, billed as
  `Actions Linux ARM` at $0.005 a minute against included compute. It had 2 cores, 7.7 GiB of memory and 34 GiB free on `/`. Those sizes
  come from one run, so treat them as what was seen, not as a promise. Run 41975430939 built, checked and published all four images in a
  job of 6 minutes 26 seconds, 321 seconds of it in the build step, billed as 7 minutes. Run 42044273310 did the same in 6 minutes
  49 seconds, 325 seconds of it in the build step.
- **Included compute on Free is $12 a month**, shared by all of the account's private repositories: about 2,000 x64 minutes
  or 2,400 arm64 minutes. Without a payment method, GitHub blocks usage once it is spent. A build that reaches the
  90-minute timeout in `images.yml` costs about $0.54, at the x64 rate those figures give.
- **`GITHUB_TOKEN` pushes to GHCR.** Runs 41975430939 and 42044273310 each pushed all four images to `ghcr.io/bereketabera/wayline/` and walked every
  layer again as GHCR served it. **The packages are private:** with no credentials, GHCR's token endpoint answered 401 for those
  names after the first build, 200 for a public image, and 403 for a name with no package. Do not push these names by hand: GitHub's documentation says
  `GITHUB_TOKEN` cannot push to a package that was pushed earlier without being connected to the repository.
- **Nothing deletes a version in GHCR.** `images.yml` had a prune job that kept the newest two, and it was removed, because it could delete
  a digest production runs or the evidence names. It listed versions in both runs and deleted nothing, so a delete with `GITHUB_TOKEN` is
  still untested. `apps/wayline/scripts/prune-ghcr.sh` stays, and refuses to delete until it exempts every digest in
  `docs/evidence/promotions` and the prod overlay.
- **The GHCR quota is documented, and the images have not met it.** GitHub's Packages billing page gives Free 500 MB of storage,
  shared with Actions artifacts, and 1 GB of transfer a month, then adds: "Container image storage and bandwidth for the Container
  registry is currently free." It promises a month's notice before that changes. Compressed, as run 41975430939 read them from
  GHCR: web 40.7, admin 30.3, space 263.9 and backend 97.4 MiB, 401.8 MiB counting each distinct layer once. Run 42044273310 added a second build, whose total no file here reads.
  `gh api users/<owner>/settings/billing/usage/summary` showed no packages row right after the push. The local `gh` token cannot
  read the package pages, because it lacks `read:packages`.
- Digests built in GitHub Actions live in GHCR, while Argo CD pulls from `localhost:5001`. After merging a digest bump, run
  `scripts/ci/copy-to-local-registry.sh ghcr.io/<owner>/wayline dev`, which lower-cases the owner, and only then
  `make gitops-publish`, which does not look in the registry. Copying keeps the digest, and rebuilding would not: run 41975430939
  built from `9c8e098`, run 42044273310 from `76e98ee` and the Mac from `84b63d9`, and all their digests differ. If Docker cannot read the first image, the
  script logs it in to `ghcr.io` with `gh auth token`, through a pipe, and prints no token. That login needs `read:packages`, which the `gh` logins on this host did not
  have when last read: `gh auth refresh -h github.com -s read:packages`. Without it the script stops at its first image, says so and writes nothing, so it has
  never finished a copy from GHCR. The digests the Mac built were never pushed to GHCR, so it cannot bring those back.
- **CI depends on GitHub serving each pinned tool.** Each job of `ci.yml` starts by fetching what it needs from release URLs, through
  `scripts/install-tools.sh`, so a job that cannot fetch one fails before any of its checks. On 2026-11-05 GitHub answered 504 for one release
  asset and then another, on and off: Manifests lost three attempts at `76e98ee`, and Lint lost a run at `7cde05a`, while GitHub's status page read
  All Systems Operational. `6edde64` lengthens the retries and keeps each job's tools in the Actions cache, keyed on `tools.lock`. Run 42048656380 at
  that commit passed all three jobs and saved those caches, and run 42088240603 at `d6b76c1` restored them, and all three jobs passed. A longer retry does not help a 504 that lasts longer than
  that, and a new `tools.lock` starts with no cache. [The evidence](../../docs/evidence/ci/README.md#the-504-on-a-pinned-tool) has each run.
- `$GITHUB_STEP_SUMMARY` output shows only on the run's page. `gh run view --json` and the check-run API do not return it.
  A scan's raw results stay on the runner, so of `images.yml`'s scan only its table in the log remains.
