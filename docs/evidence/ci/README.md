# CI evidence

Raw output from GitHub Actions for `BereketAbera/plane-platform` and from the same scripts run locally, captured on
2026-11-04 and 2026-11-05. Nothing is edited or trimmed by hand, apart from the signed query strings cut from one read of the tool URLs, as its row below says. GitHub masks tokens as `***`, and a gitleaks scan of this directory, last at 2026-11-05T15:11Z, exit 0, found
nothing. Row IDs are from [validation.md](../../validation.md), and results use the labels in contract section 12.

## Results

| Row | Result | Basis |
|---|---|---|
| CI-1, `ci.yml` on a real runner | PASS | Runs 41903137276, 41907667785, 41907841985, 41909741166, 41975431001 at 9c8e098, 41978707479 at 0dde813, and 42048656380 at 6edde64: Lint, Manifests and Security all green, on `push`. In between, run 42044273346 at 76e98ee and run 42046683167 at 7cde05a each lost a job to a 504 fetching a pinned tool, before any check in that job ran, as [below](#the-504-on-a-pinned-tool) says. No job has run on `on: pull_request`: GitHub holds those runs with no jobs, see `ci-1-20261105T060416Z-pull-request-runs.txt` |
| CI-2, `make ci` locally | PASS | Exit 0 every time, see the `ci-2` files. The newest is a clean clone of f30a7f5, from 2026-11-05T14:00:06Z to 14:14:34Z, with `.tools` copied and 149 of 149 stubbed scenarios ([ci-2-20261105T140005Z-clean-clone-f30a7f5.txt](../runs/ci-2-20261105T140005Z-clean-clone-f30a7f5.txt)). That clone was made from this checkout, not from GitHub, because the commit was not yet pushed. The two before it are clean clones from GitHub, of 9c8e098 at 05:54Z and of 0dde813 at 06:16Z, each with 132. The stubbed flows alone stood at 149 of 149 at 53aab26 ([hardening-round-5-flows-1.txt](../runs/hardening-round-5-flows-1.txt)), and a runner first read them at 7cde05a, in run 42046683167 |
| CI-3, a failing check goes red | PASS, by another route than the row names | Run 41907873100, 21 controls on a real runner. No pull request: the defect was planted in the runner's checkout. Not run on `on: pull_request`. The later controls, 45 of 45 at cc88450 ([negative-controls-alerts-track-3.txt](../runs/negative-controls-alerts-track-3.txt)), ran only on this Mac |
| CI-4, `images.yml` builds and pushes | PASS | Run 42044273310 at 76e98ee, and run 41975430939 at 9c8e098 before it, on `ubuntu-24.04-arm`: each built four images, walked them clean before and after publishing, and recorded four digests. Run 41903137226 built nothing, because `apps/wayline/images.txt` was not on main |
| CI-5, `images.yml` opens a dev bump | PASS | Run 41975430939 opened [pull request 1](https://github.com/BereketAbera/plane-platform/pull/1), with the four digests it published. Run 42044273310 force-updated it at 2026-11-05T14:29:32Z, head de9525e, to its own four. Not merged. Nothing has copied those digests to the local registry |
| CI-6, refuses an unrecorded digest | PASS | Runs 41976950402, an invented digest, and 41977025314, another image's digest, at 9c8e098. Both exit 1 at `promote.sh`, and no branch is pushed. Run 41905513020 was the first, at f733b87 |
| CI-6b, opens a pull request | PASS | Run 41977114312 at 9c8e098 opened [pull request 2](https://github.com/BereketAbera/plane-platform/pull/2), closed unmerged as a test. Run 41977288287, the same inputs again, succeeds and changes nothing. Runs 41905611391 and 41908167069 show GitHub's refusal while the setting was off |
| CI-7b, the images built here have no CRITICAL finding with a fix | PASS | The step `Scan what was just pushed`, in run 42044273310 and in run 41975430939, on the GHCR digests. Exit 0 on a real runner, each time. Only the table in the log remains, because the raw results stayed on the runner. The Mac's digests are in [security/scan-images-20261105T052024Z](../security/scan-images-20261105T052024Z/run.log), not repeated here |
| BR-3, `/source` from outside | FAIL | `br-3-20261105T054812Z-source-logged-out.txt`: 302 to 84b63d9, which answers 404 with no credentials. The commit is on GitHub. The repository is private |

## What GitHub has not seen

76e98ee reached GitHub at 2026-11-05T14:21:38Z, the first push since 0dde813 at 06:10:56Z, with 347 commits, the drills and fixes among them ([state](ci-1-20261105T150014Z-github-state.txt)). gitleaks over the history exited 0 and the search for session values found 0 at 13:53Z and 13:55Z, over the 344 commits up to 07feb13, and [history-rewrite.md](../history-rewrite.md) has both checks. `make ci` read `gitleaks history` clean again at f30a7f5, before the push ([output](../runs/ci-2-20261105T140005Z-clean-clone-f30a7f5.txt)), and the Security job read it clean at 76e98ee at 14:22Z, after the push ([log](ci-1-20261105T142148Z-run-42044273346-attempt-1.log)). No file records the search for session values on the last three commits before the push. 7cde05a followed at 14:36:42Z, and 6edde64 at 14:48:53Z, each changing how CI fetches its tools.

So the drills and fixes are on GitHub, and a commit after 6edde64 is covered by no run here, as read at 15:00Z. Run 42048656380 at 6edde64 covers Lint, Manifests and Security, so the policy rules, promtool on Linux, the digest binding and the 149 stubbed promotion scenarios have run on a real runner at a commit that holds the drills' fixes. `images.yml` ran at 76e98ee, run 42044273310, and not on the two later pushes, because nothing it watches changed. `scripts/ci/negative-controls.sh` has not run on a real runner since run 41907873100. The jobs that went red on 2026-11-05 went red fetching a tool, before any check in them ran, so nothing new shows a check going red there.

### The 504 on a pinned tool

`scripts/ci/lint.sh`, `validate-manifests.sh` and `security.sh` each start by running `scripts/install-tools.sh`, which fetches each pinned tool from its release URL and checks it against `tools.lock`. A job that cannot fetch one fails there, before any of its checks.

| When | Job | What the log reads |
|---|---|---|
| 14:22:13Z, run 42044273346, attempt 1, at 76e98ee | Manifests. Lint and Security passed | `curl: (22) The requested URL returned error: 504`, four times in six seconds, exit 22. The log names no tool, because `validate-manifests.sh` sends that script's stdout to /dev/null |
| 14:31:17Z, attempt 2, a re-run of that job from 14:30:39Z | Manifests | The same |
| 14:35:53Z, attempt 3, a re-run of that job from 14:35:37Z | Manifests | The same |
| 14:37:34Z, run 42046683167, at 7cde05a | Lint. Manifests and Security passed | One 504 at 14:36:50Z, then six from 14:37:09Z to 14:37:34Z, then `could not download shellcheck v0.11.0`, exit 1 |
| 14:49:44Z and 14:58:17Z, run 42048656380, at 6edde64 | Lint, Manifests and Security all passed | No 504. `Cache not found` on each job's first run, so each fetched its tools, and `Cache saved` after |

So no check failed in any of these, and the first three say nothing about the code at 76e98ee. Read at 14:32Z from this Mac, with no file kept: GitHub answered 504 for `https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.8.3/kustomize_v5.8.3_linux_amd64.tar.gz`, repeatedly and in about 0.3 s with no redirect, while the same asset through api.github.com's asset route answered 200 with the checksum `tools.lock` pins, the darwin asset answered 200, GitHub's status page read All Systems Operational, and the other five tools' URLs answered 200. Two later reads are in files, and they show it coming and going: at 14:39:16Z that URL answered 302 three times ([read](ci-1-20261105T143916Z-tool-urls.txt)), and at 14:40:17Z 504 three times, with the other five tools answering as before and the API naming the digest `tools.lock` pins ([read](ci-1-20261105T144017Z-tool-urls.txt)). The shellcheck failure shows it was not that one asset alone.

Three commits answer it. `30f422a` lengthened the retries to `--retry 5 --retry-delay 5 --retry-connrefused`, and [install-tools-retry-check.txt](../runs/install-tools-retry-check.txt) shows those options reaching a 200 after three 504s from a local stub. Run 42046683167 shows that was not always enough: six tries over 25 s all read 504. `7cde05a` makes the script name the tool and URL when a download fails. `6edde64` changes the retries to `--retry 8 --retry-connrefused`, with [the same stub](../runs/install-tools-retry-check-2.txt), and keeps each job's tools in the Actions cache, keyed on `tools.lock`. Run 42048656380 met no 504, so it shows neither at work, and no run yet has restored that cache. A longer retry does not help if the 504 lasts longer than that.

## Files

Each run has `<row>-<UTC start>-run-<id>.json` from `gh run view <id> --json attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,jobs,name,number,startedAt,status,updatedAt,url,workflowDatabaseId,workflowName`,
holding the run URL, the conclusion, and every job and step. `.jobs-api.json` is `gh api repos/BereketAbera/plane-platform/actions/runs/<id>/jobs`,
which adds runner labels. `.log` is `gh run view <id> --log`. A run with re-runs has one set per attempt, named `-attempt-<n>`, from `--attempt <n>` and `actions/runs/<id>/attempts/<n>/jobs`. Step summaries are not here, because neither `gh run view --json`
nor the check-run API returns them: `plan-step-summary-check-20261104T204404Z.txt` shows `summary: null` for a job that wrote one.

| Run | Workflow, commit | Trigger | Conclusion | What it shows |
|---|---|---|---|---|
| [41903137276](https://github.com/BereketAbera/plane-platform/actions/runs/41903137276) | `ci`, f733b87 | push | success | First real run. It needed no fix on GitHub |
| [41907667785](https://github.com/BereketAbera/plane-platform/actions/runs/41907667785) | `ci`, ada8dc9 | push | success | After the concurrency and lint changes |
| [41907841985](https://github.com/BereketAbera/plane-platform/actions/runs/41907841985) | `ci`, b350fdc | push | success | With the temporary probe linted too |
| [41909741166](https://github.com/BereketAbera/plane-platform/actions/runs/41909741166) | `ci`, 5fdf41d | push | success | After the probe was removed, with this directory in the tree |
| [41903137226](https://github.com/BereketAbera/plane-platform/actions/runs/41903137226) | `images`, f733b87 | push | success | **Not a build.** It warns that there is nothing to build. It does show `ubuntu-24.04-arm` running in this private repository and `docker login ghcr.io` accepting `GITHUB_TOKEN` |
| [41905415595](https://github.com/BereketAbera/plane-platform/actions/runs/41905415595) | `promote-prod-sim`, f733b87 | dispatch, no inputs | success | Dev and prod-sim match, so there is nothing to open |
| [41905513020](https://github.com/BereketAbera/plane-platform/actions/runs/41905513020) | `promote-prod-sim`, f733b87 | dispatch, `image=web`, invented digest | failure, as intended | The digest was never recorded for dev, so `promote.sh` refuses it and no branch is pushed |
| [41905611391](https://github.com/BereketAbera/plane-platform/actions/runs/41905611391) | `promote-prod-sim`, f733b87 | dispatch, `image=web`, the admin digest | failure | Edits, validates and pushes `promote/prod-sim`. GitHub then refuses the pull request |
| [41908167069](https://github.com/BereketAbera/plane-platform/actions/runs/41908167069) | `promote-prod-sim`, b350fdc | same inputs | failure | Same refusal, and the new step that explains it runs |
| [41907873100](https://github.com/BereketAbera/plane-platform/actions/runs/41907873100) | `ci-probe`, b350fdc | dispatch | failure, as intended | See below |
| [41975431001](https://github.com/BereketAbera/plane-platform/actions/runs/41975431001) | `ci`, 9c8e098 | push | success | Lint 52 s, Security 31 s, Manifests 358 s, nearly all of it the 132 stubbed scenarios |
| [41975430939](https://github.com/BereketAbera/plane-platform/actions/runs/41975430939) | `images`, 9c8e098 | push | success | **The first real build.** Build and push 386 s, the build step 321 s and the scan 29 s, prune 7 s, digest bump 50 s. `Build only` is skipped on a push |
| [41976206674](https://github.com/BereketAbera/plane-platform/actions/runs/41976206674) | `ci`, 33b9109 | pull request 1, by `github-actions[bot]` | action_required | Held by GitHub for approval, with no jobs and no log. Nobody has approved it |
| [41976950402](https://github.com/BereketAbera/plane-platform/actions/runs/41976950402) | `promote-prod-sim`, 9c8e098 | dispatch, `image=web`, invented digest | failure, as intended | `was never recorded for dev`, and no branch pushed |
| [41977025314](https://github.com/BereketAbera/plane-platform/actions/runs/41977025314) | `promote-prod-sim`, 9c8e098 | dispatch, `image=web`, the admin digest | failure, as intended | `was recorded for dev under another image`, and no branch pushed |
| [41977114312](https://github.com/BereketAbera/plane-platform/actions/runs/41977114312) | `promote-prod-sim`, 9c8e098 | dispatch, `image=web`, the web digest of 62699c9 | success | Opened pull request 2 |
| [41977201138](https://github.com/BereketAbera/plane-platform/actions/runs/41977201138) | `ci`, 4bdb73c | pull request 2, by `github-actions[bot]` | failure | **Not a check's result.** Held like 41976206674, and it turned to failure when the pull request closed, with no jobs and no log |
| [41977288287](https://github.com/BereketAbera/plane-platform/actions/runs/41977288287) | `promote-prod-sim`, 9c8e098 | the same inputs again | success | `pull-request-operation = none`, the branch unchanged, so a second dispatch does not fail |
| [41978707479](https://github.com/BereketAbera/plane-platform/actions/runs/41978707479) | `ci`, 0dde813 | push | success | With `--prefer-index=false` in `copy-to-local-registry.sh`. Lint 51 s, Security 35 s, Manifests 295 s |
| [42044273310](https://github.com/BereketAbera/plane-platform/actions/runs/42044273310) | `images`, 76e98ee | push | success | **The second real build.** Tag `76e98ee725a8`. web `02021903218c`, admin `556d9fa49ab7`, space `9640dd473509`, backend `b447fc9acb97`, each walked clean before and after publishing. Build and push 409 s, the build step 325 s and the scan 43 s, prune 8 s, digest bump 51 s. Its prune log reads `pruned, keeping 2 versions per image`, with no `deleting` line, so it removed nothing. It force-updated pull request 1. `Build only` is skipped on a push |
| [42044273346](https://github.com/BereketAbera/plane-platform/actions/runs/42044273346), attempt 1 | `ci`, 76e98ee | push | failure | **Not a check's result.** Lint 64 s and Security 38 s passed. Manifests failed fetching a tool, before any check ran |
| [42044273346](https://github.com/BereketAbera/plane-platform/actions/runs/42044273346), attempt 2 | `ci`, 76e98ee | re-run of Manifests, 14:30:39Z | failure | **Not a check's result.** The same |
| [42044273346](https://github.com/BereketAbera/plane-platform/actions/runs/42044273346), attempt 3 | `ci`, 76e98ee | re-run of Manifests, 14:35:37Z | failure | **Not a check's result.** The same |
| [42045522553](https://github.com/BereketAbera/plane-platform/actions/runs/42045522553) | `ci`, de9525e | pull request 1, by `github-actions[bot]` | action_required | Held by GitHub for approval, the same way as 41976206674, with no jobs and no log, so it has `.json` and `.jobs-api.json` and no `.log`. Nobody has approved it |
| [42046683167](https://github.com/BereketAbera/plane-platform/actions/runs/42046683167) | `ci`, 7cde05a | push | failure | **Lint's failure is not a check's result:** it failed fetching shellcheck. Manifests passed in 605 s, the first on a commit after 0dde813, with 149 of 149 stubbed scenarios. Security 36 s |
| [42048656380](https://github.com/BereketAbera/plane-platform/actions/runs/42048656380) | `ci`, 6edde64 | push | success | All three green. Lint 51 s, Security 40 s, Manifests 566 s, with 149 of 149 stubbed scenarios |

The admin digest under `web` in runs 41905611391 and 41908167069 is a test fixture: dev and prod-sim matched, so no other digest
recorded for dev existed to create a difference. Nobody should merge that, so both `promote/prod-sim` branches were
deleted after their runs. Those runs also show a limit the invariant had then: it asked whether dev ever recorded the digest, not
whether dev recorded it for that image. Run 41977025314 shows the limit gone.

Pull request 2 moves prod-sim's web image back to a digest dev recorded at 62699c9, because prod-sim equals dev today and a pull request
needs a difference. It was closed unmerged with a comment. Its branch `promote/prod-sim` is still on GitHub, at 4bdb73c, because the
session's permission system refused deleting it, and that is the owner's to delete. Pull request 1 is open, unmerged, for the owner.

### The temporary probe, run 41907873100

`.github/workflows/ci-probe.yml` and `scripts/ci/ghcr-probe.sh` existed only for this run. Commit b350fdc added them, and the
commit that added this README removed them. It wrote no layer, manifest or tag.

| Job | Conclusion | Result |
|---|---|---|
| Manifests check, red on purpose | failure, as intended | A `kind: Secret` appended on the runner made `validate-manifests.sh` exit 1 |
| Every planted defect, on a real runner | success | `scripts/ci/negative-controls.sh`: 21 of 21 defects caught, each by the check meant to catch it |
| GHCR with packages write, on arm64 | success | Token 200, then upload session **HTTP 202**. Canceling it answered 405, so the empty session could not be closed from here. Nothing was uploaded to it |
| GHCR with packages read, the control | success | Same token request, then upload session **HTTP 403**, `DENIED` |
| GHCR with no packages permission, the control | success | Upload session **HTTP 403**, `DENIED` |

The control jobs ran after the write job, and they still got `NAME_UNKNOWN` for `wayline/ci-probe` and for `wayline/{web,admin,space,backend}`,
so no image existed under those names then. The packages REST API could not confirm it: `GITHUB_TOKEN` got 400, and the local `gh`
token lacks `read:packages`. The same logs hold the runner sizes the workflows README quotes.

### Other files

| File | What it is |
|---|---|
| `ci-2-20261104T201032Z-make-ci.log`, `.rc` | `make ci` in the shared checkout at f733b87, redirected to a file, and its exit code, 0. `README.md`, `docs/README.md` and `docs/case-study.md` were untracked at the time |
| `ci-2-20261104T204746Z-make-ci.log`, `.rc` | `make ci` in a clean clone of 5fdf41d, redirected to a file, and its exit code, 0 |
| `ci-2-20261104T223712Z-make-ci.log`, `.rc` | `make ci` in a clean clone of 283b51a, redirected to a file, and its exit code, 0. It includes the 24 stubbed scenarios of `scripts/ci/test-promotion-flows.sh` |
| `ci-3-20261104T223937Z-negative-controls-local.log`, `.rc` | `scripts/ci/negative-controls.sh` in that clone, and its exit code, 0: 33 of 33 planted defects caught |
| `promotion-flows-against-the-old-scripts-20261104T212746Z.log` | `scripts/ci/test-promotion-flows.sh` with `promote.sh`, `rollback.sh`, `gitops-publish.sh`, `check-promoted-digests.sh` and the drill put back to their earlier versions, in a scratch clone at 4a49a9c: 19 of 24 scenarios fail, so they can tell the difference |
| `ci-2-20261104T225907Z-make-ci.log`, `.rc` | `make ci` in a clean clone of 6fc3708, and its exit code, 0, with 41 stubbed scenarios after the publish check was added |
| `promotion-flows-against-the-code-before-the-publish-check-20261104T225631Z.log`, `.rc` | The same 41 scenarios against the scripts at c61e057, which had no publish check: 16 fail. Fifteen are new. The sixteenth, `promote-override-is-logged`, fails only because the override's wording changed. The two new ones that pass there, `publish-dev-change-needs-no-dev-check` and `make-passes-the-documented-options`, guard against the check blocking too much |
| `ci-3-20261104T202916Z-negative-controls-local.log` | `scripts/ci/negative-controls.sh` on this Mac, in a scratch clone at bc8bb91 plus the changes that became ada8dc9. Start time approximate. The last line is added by the wrapper that ran it |
| `plan-facts-20261104T204023Z.txt` | Plan, Actions settings, the 403s from branch protection and rulesets, billing rows for this repository, pinned action SHAs compared with their tags. Commands are shown inline |
| `plan-upstream-image-sizes-20261104T204023Z.txt` | Compressed arm64 sizes of the pinned upstream Plane images. Not Wayline images |
| `plan-step-summary-check-20261104T204404Z.txt` | The check-run API's answer for a job that wrote a step summary |
| `ci-1-20261105T060416Z-pull-request-runs.txt` | What GitHub says of the `ci` runs it made for the two pull requests: no jobs, no log, and the check suites |
| `ci-2-20261105T055459Z-make-ci.log`, `.rc` | `make ci` in a clean clone of 9c8e098 from GitHub, and its exit code, 0, with `.tools` and the trivy cache copied from the checkout to save disk |
| `ci-2-20261105T061644Z-make-ci.log`, `.rc` | The same in a clean clone of 0dde813, exit code 0 |
| `ci-4-20261105T055033Z-ghcr-visibility.txt` | With no credentials: the token endpoint and a manifest read for each image, by digest and by tag, a public image and a name with no package as controls. Then the local token through `gh api`, and `docker` |
| `ci-4-20261105T055130Z-ghcr-local-token.txt` | What the local token gets from GHCR itself, with the same controls. It lacks `read:packages`, so nothing here reads these images |
| `ci-4-20261105T060219Z-published-compare.txt` | From the run's log: each digest in both walks, layer counts, compressed sizes. Compared with pull request 1 and with the local registry. Python source at the end |
| `plan-facts-20261105T060710Z.txt`, `plan-facts-20261105T062632Z.txt` | Settings after the change the owner approved, billing rows for this repository, account totals, run timing, and the run list, read twice. A row's quantity lagged behind its discount |
| `ci-5-20261105T055743Z-pr-1.txt` | Pull request 1 as `gh pr view` and `gh pr diff` give it |
| `ci-5-20261105T060108Z-copy-keeps-digest.txt` | The command in `copy-to-local-registry.sh` against a throwaway registry: without `--prefer-index=false` the tag answers with a new index's digest, and with it the source's. The local registry was only read |
| `ci-5-20261105T060504Z-copy-rehearsal.txt` | The script itself on this Mac, in a scratch clone at pull request 1's head: an owner in capitals is refused, and in lower case it stops at the first image with a 401. Nothing reached the local registry |
| `ci-6b-20261105T055738Z-pr-2-opened.txt`, `ci-6b-20261105T055943Z-pr-2-closed.txt` | Pull request 2 when opened, and after it was closed unmerged |
| `br-3-20261105T054812Z-source-logged-out.txt` | `/source` through Traefik in both environments, then its target and the repository with no credentials, then who can read it, from the owner's login |
| `br-3-20261105T060937Z-apps.txt` | The check suites `netlify` and `builder-io-integration` left on pushed commits, what each App's permissions are, and the 403 that keeps this token from listing installations |
| `ci-5-20261105T150014Z-pr-1.txt` | Pull request 1 after run 42044273310 force-updated it, as `gh pr view` and `gh pr diff` give it, with the branches |
| `ci-1-20261105T150014Z-github-state.txt` | What GitHub says of the pushes, in its activity feed, the remote refs, the commits from 0dde813 to 76e98ee, the newest runs, and the two runs held for pull request 1 |
| `ci-1-20261105T143916Z-tool-urls.txt`, `ci-1-20261105T144017Z-tool-urls.txt` | What GitHub answered this Mac, not a runner, for the six tools `validate-manifests.sh` fetches, three tries each, asking for the first 1024 bytes and keeping nothing. Then the digest GitHub's API states for the kustomize asset, beside `tools.lock`, and its status page. Each redirect's signed query string is cut to the host: by hand after the read in the first, by the command in the second |
| `make-status-20261105T150014Z.txt` | `make status`, which only reads, on the cluster the checks at f30a7f5 ran on. Not a CI result. It is here because this write-up did not write to `.local/evidence-raw/` |
| `publish-evidence-20261105T145421Z.txt`, `publish-evidence-20261105T150341Z.txt` | What `make publish-evidence` printed, with its exit code, for the two publishes after `76e98ee`. Not CI results either, and here for the same reason |

## GitHub Free, private repository: what is measured and what is only documented

| Question | Answer | Basis |
|---|---|---|
| Is `ubuntu-24.04-arm` usable? | Yes | Runs 41975430939 and 42044273310 built all four images on it. Billing shows `Actions Linux ARM`, 7 minutes for that job, at $0.005 a minute, netted to $0 against included compute |
| May `GITHUB_TOKEN` push to GHCR? | Yes | Runs 41975430939 and 42044273310 each pushed four images, and read every layer back from GHCR with the same login |
| Are the packages private? | Yes, to anyone who can test it from outside | With no credentials the token endpoint answered 401 for all four names at 05:50Z, after the first build, 200 for a public image and 403 for a name with no package. The API that states a package's visibility needs `read:packages`, which the local token lacks |
| What is the GHCR quota? | Documented only | [Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages) gives Free 500 MB and 1 GB a month, shared with Actions artifacts, and says Container registry storage and bandwidth are free for now. The first four images hold 401.8 MiB, counting each distinct layer once. November's usage summary showed no packages row after that push. Run 42044273310 added a second build, whose total no file here reads. Nothing has met the limit |
| Can `promote-prod-sim.yml` open a pull request? | Yes, with the setting on, as it has been since 2026-11-05T02:32:59Z, when the owner said yes in chat ([ci-actions-pr-setting-1.txt](../runs/ci-actions-pr-setting-1.txt)) | Run 41977114312. `can_approve_pull_request_reviews` is `true` in `plan-facts-20261105T060710Z.txt`. With it off, run 41905611391 shows the refusal |
| Is approval enforceable? | No | Branch protection and rulesets answer 403. [Environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) and [attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations) are documented as unavailable on this plan and visibility |

## Not run yet

- `images.yml` on a pull request, so its `Build only` job, and a prune that deletes something. In both real builds the prune job listed versions and deleted none.
- A job of `ci.yml` on `on: pull_request`. GitHub holds the run for a pull request a workflow opens, and no person has opened one or approved one.
- A promotion pull request reviewed and merged, and `scripts/ci/copy-to-local-registry.sh` finishing a copy. It needs a token with `read:packages`.
- A read of the published images from this Mac, for the same reason. Their digests as GHCR serves them are what the run's own walk, inspect and scan read, on the runner.
- `trivy fs` has found no lockfile in this repository, so it has scanned no dependency yet. The `vulnerable-lockfile-trivy-fs`
  control shows it fails when given one. `make scan-images` scans the images and the Wayline source lockfiles instead. Its results
  are in [docs/evidence/security/](../security/README.md).
- This directory says nothing about `rollback.sh` or the failed-deploy drill against a real cluster. [validation.md](../../validation.md) has those rows.
