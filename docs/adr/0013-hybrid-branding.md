# 0013. Hybrid branding: overlay, patches and codemod

**Status:** Accepted, 2026-11-04, with measured numbers added 2026-11-05. Runtime validation pending where marked. The images are built. `plane-dev` has run branded images since promotion `4f622e3` on 2026-11-05 and `plane-prod-sim` since `0af8956`, and both run the final build from `ec45e21`.

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
- A frontend build needs the pinned Node and pnpm toolchain. Peak memory during a build was estimated at 3 to 5 GiB in `plane-branding.md`. Measured on this Mac on 2026-11-04, at 23:26 UTC at commit `ffbef80` with the CI settings and a cold turbo cache, the native build took 88s, with a largest process of 1556 MiB and a sampled sum of 1640 MiB ([build-ci-settings.txt](../evidence/branding/build-ci-settings.txt)), and on 2026-11-05 at 01:57 UTC at `ec45e21`, with turbo's and BuildKit's caches warm, the whole of `make images` took 42s ([build.txt](../evidence/branding/build.txt)). That ran beside the full cluster. It is not a run on the 2-core arm runner.
- Replacing `build/` in space keeps upstream's dependencies. An upstream `node_modules` change would need the base digest bumped too.
- A user choosing Plane's `custom` theme overrides the palette, and keeps Wayline's shapes and type.
- **AGPL.** Section 13 requires offering Corresponding Source to users who interact over a network. The offer has to include the pinned upstream ref, overlay, patches, codemod, build scripts and Dockerfiles. See [AGPL compliance](../agpl-compliance.md). The source tree and notices keep Plane's name and copyright, even where the UI shows Wayline.
- The AGPL licenses the code, not the name or mark. Plane's name and logo are treated as off limits in the UI.
- `apps/wayline` exists, and `make images` builds web, admin, space and backend from the pinned commit. The digests from `ec45e21` are in [digests.tsv](../evidence/branding/digests.tsv), each read back from the registry ([digests-confirmed.txt](../evidence/branding/digests-confirmed.txt)).
- The rendered manifests reference `localhost:5001/wayline` images by digest, dev's since `4f622e3` and prod-sim's since `0af8956`, and on 2026-11-05 the pods in both ran those digests ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt)).
- The leak scan over built output found 0 leaks in 2,117 files, with 350 allowlisted matches, and 0 SPDX or copyright lines were removed from the patched tree ([leak-scan.txt](../evidence/branding/leak-scan.txt), [headers.txt](../evidence/branding/headers.txt)). A real browser session on `plane-dev` on 2026-11-05, on the build from `1563cbf`, showed Wayline's name on the pages it visited ([live-dev](../evidence/branding/live-dev/README.md)). It did not visit every page, and a workspace created before the promotion keeps "Welcome to Plane", because seed text is written once.
- **The UI exposes a source link, and that link does not reach the Corresponding Source yet.** `/source` answers 302 to the repository at the image's commit, and that target answers 404 to anyone without access, because the repository is private and the commit is unpushed ([smoke.txt](../evidence/branding/smoke.txt)). That must be fixed before anyone else uses an instance. See [AGPL compliance](../agpl-compliance.md).
- The branded backend runs migrations and serves the API. Against a scratch database it ran 164 migrations and registered an instance, and its control on upstream's image failed 8 checks ([backend-db.txt](../evidence/branding/backend-db.txt)). On the real platform `make test-e2e` passed all 38 steps in `plane-dev` on the build from `1563cbf` ([smoke](../evidence/runs/smoke-dev-20261105T001213Z.json)), the same steps as on upstream's images. A run on the final build, in dev, is still in `.local/evidence-raw/`. That is the behaviour those steps reach, not all of the API.

## What we found when we ran it

Added 2026-11-05.

- **The patch estimate was far too low.** About 20 files became 86, as the tables above say, and the first scan then failed: 5 CRITICAL findings with a fix, all inherited through `FROM` lines. The derived images now replace those packages, and the scan of the final build passes its policy ([scan evidence](../evidence/security/README.md)). The final build flattens the backend, since `5adbc78`, so the old bytes are in no layer of it. They stay in the `FROM` layers of the space image, which a scan does not report ([final scan](../evidence/security/scan-images-20261105T020423Z/README.md)). Flattening has a cost: a registry grows by 97.5 MiB for each new backend version, where it grew by 0.25 MiB ([flatten-size.txt](../evidence/branding/flatten-size.txt)).
- **Thin nginx images inherited upstream's caching.** web and admin sent `ETag` and `Last-Modified` with no `Cache-Control`, so after the first promotion a browser with a cached page kept showing the upstream sign-in page, with no error ([live-dev](../evidence/branding/live-dev/README.md)). `e885fc0` adds the header, and since the final build both answer `Cache-Control: no-cache` through the ingress in both environments ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt)). In a real browser on a local port, the final images gave the new page at the next request, where the earlier ones kept the old one ([cache-browser.txt](../evidence/branding/cache-browser.txt)). A browser through the ingress across a promotion has not been tried with the header.
- **Hydration errors are upstream's.** React #418 and #423 appear on the web app with these images, and the same two on upstream's in both environments, so branding did not introduce them. Their cause was not found.
