# CI evidence

Raw output from GitHub Actions for `BereketAbera/plane-platform` and from the same scripts run locally, captured on
2026-11-04. Nothing is edited or trimmed by hand. GitHub masks tokens as `***`, and a gitleaks scan of this directory found
nothing. Row IDs are from [validation.md](../../validation.md), and results use the labels in contract section 12.

## Results

| Row | Result | Basis |
|---|---|---|
| CI-1, `ci.yml` on a real runner | PASS | Runs 41903137276, 41907667785, 41907841985: Lint, Manifests and Security all green |
| CI-2, `make ci` locally | PASS | Exit 0, see the `ci-2` files |
| CI-3, a failing check goes red | PASS, by another route than the row names | Run 41907873100. No pull request: the defect was planted in the runner's checkout. Not run on `on: pull_request` |
| CI-4, `images.yml` builds and pushes | NOT RUN | Run 41903137226 built nothing, because `apps/wayline/images.txt` was not on main |
| CI-5, `images.yml` opens a dev bump | NOT RUN | Follows CI-4. Expect the refusal seen in CI-6 while the setting is off |
| CI-6, refuses an unrecorded digest | PASS | Run 41905513020 |
| CI-6, opens a pull request | BLOCKED | Runs 41905611391, 41908167069: GitHub refuses it, because the repository setting is off |

## Files

Each run has `<row>-<UTC start>-run-<id>.json` from `gh run view <id> --json attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,jobs,name,number,startedAt,status,updatedAt,url,workflowDatabaseId,workflowName`,
holding the run URL, the conclusion, and every job and step. `.jobs-api.json` is `gh api repos/BereketAbera/plane-platform/actions/runs/<id>/jobs`,
which adds runner labels. `.log` is `gh run view <id> --log`. Step summaries are not here, because neither `gh run view --json`
nor the check-run API returns them: `plan-step-summary-check-20261104T204404Z.txt` shows `summary: null` for a job that wrote one.

| Run | Workflow, commit | Trigger | Conclusion | What it shows |
|---|---|---|---|---|
| [41903137276](https://github.com/BereketAbera/plane-platform/actions/runs/41903137276) | `ci`, f733b87 | push | success | First real run. It needed no fix on GitHub |
| [41907667785](https://github.com/BereketAbera/plane-platform/actions/runs/41907667785) | `ci`, ada8dc9 | push | success | After the concurrency and lint changes |
| [41907841985](https://github.com/BereketAbera/plane-platform/actions/runs/41907841985) | `ci`, b350fdc | push | success | With the temporary probe linted too |
| [41903137226](https://github.com/BereketAbera/plane-platform/actions/runs/41903137226) | `images`, f733b87 | push | success | **Not a build.** It warns that there is nothing to build. It does show `ubuntu-24.04-arm` running in this private repository and `docker login ghcr.io` accepting `GITHUB_TOKEN` |
| [41905415595](https://github.com/BereketAbera/plane-platform/actions/runs/41905415595) | `promote-prod-sim`, f733b87 | dispatch, no inputs | success | Dev and prod-sim match, so there is nothing to open |
| [41905513020](https://github.com/BereketAbera/plane-platform/actions/runs/41905513020) | `promote-prod-sim`, f733b87 | dispatch, `image=web`, invented digest | failure, as intended | The digest was never recorded for dev, so `promote.sh` refuses it and no branch is pushed |
| [41905611391](https://github.com/BereketAbera/plane-platform/actions/runs/41905611391) | `promote-prod-sim`, f733b87 | dispatch, `image=web`, the admin digest | failure | Edits, validates and pushes `promote/prod-sim`. GitHub then refuses the pull request |
| [41908167069](https://github.com/BereketAbera/plane-platform/actions/runs/41908167069) | `promote-prod-sim`, b350fdc | same inputs | failure | Same refusal, and the new step that explains it runs |
| [41907873100](https://github.com/BereketAbera/plane-platform/actions/runs/41907873100) | `ci-probe`, b350fdc | dispatch | failure, as intended | See below |

The admin digest under `web` in the two pull request runs is a test fixture: dev and prod-sim matched, so no other digest
recorded for dev existed to create a difference. Nobody should merge that, so both `promote/prod-sim` branches were
deleted after their runs. Those runs also show a limit of the invariant: it asks whether dev ever recorded the digest, not
whether dev recorded it for that image.

### The temporary probe, run 41907873100

`.github/workflows/ci-probe.yml` and `scripts/ci/ghcr-probe.sh` existed only for this run. Commit b350fdc added them, and the
commit that added this README removed them. It wrote no layer, manifest or tag.

| Job | Conclusion | Result |
|---|---|---|
| Manifests check, red on purpose | failure, as intended | A `kind: Secret` appended on the runner made `validate-manifests.sh` exit 1 |
| Every planted defect, on a real runner | success | `scripts/ci/negative-controls.sh`: 21 of 21 defects caught, each by the check meant to catch it |
| GHCR with packages write, on arm64 | success | Token 200, then upload session **HTTP 202**. Canceling it answered 405, so GHCR keeps it until it expires. Nothing was uploaded |
| GHCR with packages read, the control | success | Same token request, then upload session **HTTP 403**, `DENIED` |
| GHCR with no packages permission, the control | success | Upload session **HTTP 403**, `DENIED` |

The control jobs ran after the write job, and they still got `NAME_UNKNOWN` for `wayline/ci-probe` and for `wayline/{web,admin,space,backend}`,
so no image existed under those names then. The packages REST API could not confirm it: `GITHUB_TOKEN` got 400, and the local `gh`
token lacks `read:packages`. The same logs hold the runner sizes the workflows README quotes.

### Other files

| File | What it is |
|---|---|
| `ci-2-20261104T201032Z-make-ci.log`, `.rc` | `make ci` in the shared checkout at f733b87, redirected to a file, and its exit code, 0. `README.md`, `docs/README.md` and `docs/case-study.md` were untracked at the time |
| `ci-3-20261104T202916Z-negative-controls-local.log` | `scripts/ci/negative-controls.sh` on this Mac, in a scratch clone at bc8bb91 plus the changes that became ada8dc9. Start time approximate. The last line is added by the wrapper that ran it |
| `plan-facts-20261104T204023Z.txt` | Plan, Actions settings, the 403s from branch protection and rulesets, billing rows for this repository, pinned action SHAs compared with their tags. Commands are shown inline |
| `plan-upstream-image-sizes-20261104T204023Z.txt` | Compressed arm64 sizes of the pinned upstream Plane images. Not Wayline images |
| `plan-step-summary-check-20261104T204404Z.txt` | The check-run API's answer for a job that wrote a step summary |

## GitHub Free, private repository: what is measured and what is only documented

| Question | Answer | Basis |
|---|---|---|
| Is `ubuntu-24.04-arm` usable? | Yes | Ran twice here. Billing shows `Actions Linux ARM` at $0.005 a minute, netted against included compute |
| May `GITHUB_TOKEN` push to GHCR? | The permission is proven, a push is not | The 202 and 403 above. [GitHub's docs](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) describe the same route |
| What is the GHCR quota? | Documented only | [Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages) gives Free 500 MB and 1 GB a month, shared with Actions artifacts, and says Container registry storage and bandwidth are free for now. No image has been stored here to test it |
| Can `promote-prod-sim.yml` open a pull request? | Not with the setting off | Run 41905611391. `can_approve_pull_request_reviews` is `false` in `plan-facts` |
| Is approval enforceable? | No | Branch protection and rulesets answer 403. [Environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) and [attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations) are documented as unavailable on this plan and visibility |

## Not run yet

- A real image build or GHCR push, so no digest, build time, stored size or billing effect is known.
- `images.yml` on a pull request, its prune step and its dev digest-bump pull request.
- `ci.yml` on `on: pull_request`. Every `ci.yml` run here came from a push to main.
- A promotion pull request opened, reviewed and merged, and `scripts/ci/copy-to-local-registry.sh`.
- `trivy fs` has found no lockfile in this repository, so it has scanned no dependency yet. The `vulnerable-lockfile-trivy-fs`
  control shows it fails when given one.
