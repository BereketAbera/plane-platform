# 0013. Hybrid branding: overlay, patches and codemod

**Status:** Accepted, 2026-11-04, with measured numbers added 2026-11-05. The images are built. `plane-dev` has run branded images since promotion `4f622e3` on 2026-11-05 and `plane-prod-sim` since `0af8956`, and both run the final build from `84b63d9`, since `1fc9fbe` and `9c8e098`.

## Context

The application is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), under the name Wayline. It is not an original product, and no document may present it as one.

The aim is a distinct look and name without taking ownership of Plane's code. Plane's frontends limit how that can be done (research, 2026-11-04):

| App | Render mode | Runtime | What it means |
|---|---|---|---|
| web | `ssr: false` | nginx, static `build/client` | Can be rebuilt into a thin nginx image |
| admin | `ssr: false` | nginx, static `build/client` | Same |
| space | `ssr: true` | Node, `react-router-serve` | Client and server bundles must be replaced together, since the SSR bundle embeds asset URLs |

All three are React Router 7 on Vite. The design system is CSS variables, so a lot can change through tokens. Structure (auth layout, shell, source link) can change only in source.

Upstream has 5,268 tracked files. As built, 86 are patched and 155 replaced whole by the overlay, nearly all images. The research's estimate before any of this was built was about 20 edited files.

## Decision

A thin layer in `apps/wayline/`, applied on top of the pinned source commit at build time.

| Piece | Method |
|---|---|
| web, admin | Pinned source, then overlay, patches and codemod. Build, then `COPY build/client` into a thin nginx image |
| space | Same source build. `COPY build/` over `FROM makeplane/plane-space@digest`, which keeps upstream's Linux `node_modules` |
| backend, worker, beat, migrator | Derived image `FROM makeplane/plane-backend@digest`, with `COPY templates/` and a scripted edit of `.py` subject strings |
| live | Unmodified in Pass 1. Only PDF export colours are affected |

| Layer | Holds |
|---|---|
| Overlay | New files copied in: tokens, fonts, images |
| Patches | 86 files, +311 -500 lines (measured 2026-11-05), applied with plain `git apply`. A failed hunk stops the build. `--3way` depends on which git objects a machine has, so it moved to a separate rebase path (`patchwork.sh --rebase-from`) |
| Codemod | Scripted text replacement at build time. Its output is never committed |

The codemod must never touch SPDX and copyright headers, which are in 3,804 source files.

Images are published to `localhost:5001/wayline/{web,admin,space,backend}` and always referenced by digest. See [0003](0003-local-registry-and-pull-through-caches.md).

## Alternatives considered

| Option | Reach | Why not |
|---|---|---|
| Post-build only, editing CSS and images in published images | Colours, radii, density, fonts, images | Cannot restructure anything. It would be a recoloured Plane, which the owner already rejected |
| Full fork | Everything | Carries 5,268 files to patch 86, and makes each upstream release a merge |
| Runtime theme (`custom` in Plane's settings) | Two colours, per user | No fonts, radii or layout, and no instance-wide default |
| No branding, deploy upstream images | None | Would be simplest, but the owner requires a distinct product name |

## Consequences

The numbers that decided this, from research on 2026-11-04:

| Measure | Value | Basis |
|---|---|---|
| Candidate patch files touched, v1.3.0 to v1.4.0 | 12 of 65 | GitHub commits API per file |
| Candidate patch files touched, v1.4.0 to v1.4.3 | 1 of 65 | GitHub commits API per file |
| Patch size, estimated | About 20 files, 150 to 200 changed lines | Estimate, from listing the edits while reading source. Nothing was built. This was far too low |
| Patch size, as built | 86 files, +311 -500 lines, 140 hunks | `git apply --numstat`, 2026-11-05 |
| Patches against other upstream refs | `v1.4.2` and `v1.4.0`: 0 of 7 fail. `v1.3.0`: 4 of 7, 14 files. `preview` (1.5.0, unreleased): 7 of 7, 68 files, and `variables.css` is gone | `apps/wayline/checks/upstream-check.sh`, 2026-11-05 |
| Disk, native build | 1.3 GiB or less on the host, about 1 GiB in the Docker VM | Estimate, from dependency and output sizes |
| Disk, upstream's three Dockerfiles | About 5 GiB in the Docker VM | Computed from image and layer sizes |

- Each Plane upgrade means re-applying patches. A patch release has needed nothing so far, a minor release a sixth of the patched files, and the next minor line looks like a rework of tokens and most patches. A failed hunk or `overlay.lock` is the signal, and `wayline-upstream-check` gives early warning.
- A frontend build needs the pinned Node and pnpm toolchain. Peak memory during a build was estimated at 3 to 5 GiB in `plane-branding.md`. Measured on this Mac on 2026-11-04, at 23:26 UTC at commit `ffbef80` with the CI settings, a cold turbo cache and a pnpm store already filled, the native build took 88s, with a largest process of 1556 MiB and a sampled sum of 1640 MiB ([build-ci-settings.txt](../evidence/branding/build-ci-settings.txt)). On 2026-11-05 at 05:13 UTC at `84b63d9` the whole of `make images` took 91s, beside the full cluster, with every frontend from turbo's cache and Docker reusing most layers outside space, so that is not a cold build ([build.txt](../evidence/branding/build.txt), [what it measures](../evidence/branding/README.md#files)). On the arm runner, in run 41975430939 at `9c8e098`, the build step took 321s and the whole job 386s ([ci evidence](../evidence/ci/README.md)).
- Replacing `build/` in space keeps upstream's dependencies. An upstream `node_modules` change would need the base digest bumped too.
- A user choosing Plane's `custom` theme overrides the palette, and keeps Wayline's shapes and type.
- **AGPL.** Section 13 requires offering Corresponding Source to users who interact over a network. The offer has to include the pinned upstream ref, overlay, patches, codemod, build scripts and Dockerfiles. See [AGPL compliance](../agpl-compliance.md). The source tree and notices keep Plane's name and copyright, even where the UI shows Wayline.
- The AGPL licenses the code, not the name or mark. Plane's name and logo are treated as off limits in the UI.
- `apps/wayline` exists, and `make images` builds web, admin, space and backend from the pinned commit. The digests from `84b63d9` are in [digests.tsv](../evidence/branding/digests.tsv), each read back from the registry ([digests-confirmed.txt](../evidence/branding/digests-confirmed.txt)).
- The rendered manifests reference `localhost:5001/wayline` images by digest, dev's since `4f622e3` and prod-sim's since `0af8956`. On 2026-11-05 the pods in both ran the final digests ([FINAL-state-20261105T062807Z.txt](../evidence/runs/FINAL-state-20261105T062807Z.txt) for prod-sim, [DEP-3-20261105T064517Z-drill.txt](../evidence/runs/DEP-3-20261105T064517Z-drill.txt) for dev). `images.yml` published four private GHCR packages from `9c8e098`, under other digests. Those have not been copied to the local registry or promoted ([ci evidence](../evidence/ci/README.md)).
- The leak scan over built output found 0 leaks in 2,117 files, with 350 allowlisted matches, and 0 SPDX or copyright lines were removed from the patched tree ([leak-scan.txt](../evidence/branding/leak-scan.txt), [headers.txt](../evidence/branding/headers.txt)). A real browser session on `plane-dev` on 2026-11-05, on the build from `1563cbf`, showed Wayline's name on the pages it visited ([live-dev](../evidence/branding/live-dev/README.md)). It did not visit every page, and a workspace created before the promotion keeps "Welcome to Plane", because seed text is written once.
- **The UI exposes a source link, and that link does not reach the Corresponding Source yet.** `/source` answers 302 to the repository at the image's commit. That commit is on GitHub, and the target answers 404 to anyone without access, because the repository is private ([logged out](../evidence/ci/br-3-20261105T054812Z-source-logged-out.txt)). That must be fixed before anyone else uses an instance. See [AGPL compliance](../agpl-compliance.md).
- The branded backend runs migrations and serves the API. Against a scratch database it ran 164 migrations and registered an instance, and its control on upstream's image failed 8 checks ([backend-db.txt](../evidence/branding/backend-db.txt)). On the real platform `make test-e2e` on the final images ended PASS in both: 45 PASS and 1 SKIP in `plane-dev`, and 44 PASS and 1 SKIP in `plane-prod-sim` ([smoke-dev-20261105T070735Z-94252.json](../evidence/runs/smoke-dev-20261105T070735Z-94252.json), [smoke-prod-sim-20261105T053533Z-8468.json](../evidence/runs/smoke-prod-sim-20261105T053533Z-8468.json)). The SKIP, `branding-fresh-install`, needs a clean database. It read PASS on the first smoke of the clean install and of the cold install, in both environments: before setup, the instance the image registered is named Wayline, with telemetry off ([clean, dev](../evidence/runs/clean-install-20261105T075041Z/e2e-dev-first.txt), [clean, prod-sim](../evidence/runs/clean-install-20261105T075041Z/e2e-prod-sim-first.txt), [cold, dev](../evidence/runs/clean-install-20261105T105546Z/e2e-dev-first.txt), [cold, prod-sim](../evidence/runs/clean-install-20261105T105546Z/e2e-prod-sim-first.txt)). The cold install's images were built from source in its clone, so that also shows a rebuild carries the brand. On the build from `ec45e21`, prod-sim's first run after its promotion, at 02:22:10 UTC, ended FAIL on `branding-backend`, which read upstream's changelog URL from `/api/instances/`, and the next, at 02:22:56 on the same api pod, ended PASS ([smoke-prod-sim-20261105T022210Z-2247.json](../evidence/runs/smoke-prod-sim-20261105T022210Z-2247.json), [smoke-prod-sim-20261105T022256Z-12154.json](../evidence/runs/smoke-prod-sim-20261105T022256Z-12154.json)). The likely cause is the two-hour cache on that route, which was inferred and not measured, and the step now reads a key nothing else fills. That is the behaviour those steps reach, not all of the API.

## What we found when we ran it

Added 2026-11-05.

- **The patch estimate was far too low.** About 20 files became 86, as the tables above say, and the first scan then failed: 5 CRITICAL findings with a fix, all inherited through `FROM` lines. The derived images now replace those packages, and the scan of the final build passes its policy. That scan covers only the 5 targets built here, and its zeros for web and admin cover OS packages only ([final scan](../evidence/security/scan-images-20261105T052024Z/README.md)). The last complete scan failed its policy and has not been repeated, so the upstream images were not scanned again ([scan evidence](../evidence/security/README.md)). The final build flattens the backend, since `5adbc78`, so the old bytes are in no layer of it. They stay in the `FROM` layers of the space image, which a scan does not report ([final scan](../evidence/security/scan-images-20261105T052024Z/README.md)). Flattening has a cost: a registry grows by 97.5 MiB for each new backend version, where it grew by 0.25 MiB ([flatten-size.txt](../evidence/branding/flatten-size.txt)).
- **`email.py` was replaced, and no person chose that.** AI agents replaced the backend's `plane/utils/email.py` with upstream's AGPL version and flattened the image, so the original is in no layer ([email-py.txt](../evidence/branding/email-py.txt)). The owner, Bereket Abera, was told and has not reviewed it, and no legal review happened. See [AGPL compliance](../agpl-compliance.md).
- **A build context's file modes reach the image.** Under umask 077 every file in a context was 0600, the build kept those modes, and the images' non-root users could not read their own files: web, admin, space and api crashed at start, with Permission denied in the logs of web, admin and api on the cold install, and every build step, gate and leak scan had passed. `6f5a426` runs `chmod -R a+rX` on each context, and the same umask then gave images that came up healthy ([rebuild](../evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt)). Nothing checks an image's modes.
- **Thin nginx images inherited upstream's caching.** web and admin sent `ETag` and `Last-Modified` with no `Cache-Control`, so after the first promotion a browser with a cached page kept showing the upstream sign-in page, with no error ([live-dev](../evidence/branding/live-dev/README.md)). `e885fc0` adds the header, and the rule now goes by status: a year and `immutable` on a success for the bundler's hashed files, and `no-cache` on every error, on HTML and on everything else without a content hash in its name. Byte ranges are off, because nginx's range handling runs after that rule. On 2026-11-05 a real browser through the ingress got the new page at its next plain navigation with no hard reload, after one promotion in each environment and one rollback in dev ([auth-6-browser-promotion-dev-1.txt](../evidence/runs/auth-6-browser-promotion-dev-1.txt), [AUTH-6-rollback-20261105T064032Z.txt](../evidence/runs/AUTH-6-rollback-20261105T064032Z.txt)). That is Chromium only, read by etag on `/sign-in/`, the page's scripts were not checked at the rollback reading, and a browser left open across a promotion or a rollback was not tested. One limit stays: a browser still holding HTML from an image without the header reuses it unasked until its own time runs out, and a rollback to a digest built before `e885fc0` brings that HTML back. Nobody timed that, and a tenth of the file's age is assumed, about 17.5 hours for upstream's `index.html` on 2026-11-05 ([upstream-html-age.txt](../evidence/branding/upstream-html-age.txt)).
- **The hydration errors also appear on upstream's images.** React #418 and #423 appear on the web app on the build from `1563cbf` ([live-dev](../evidence/branding/live-dev/README.md)), and the same two appeared on upstream's images in both environments ([dev](../evidence/runs/plane-dev-browser-1.txt), [prod-sim](../evidence/runs/plane-prod-sim-browser-1.txt)), so branding did not introduce them on that build. That comparison was not repeated on the final build ([branding evidence](../evidence/branding/README.md#limits-of-the-browser-renders)). Their cause was not found.
