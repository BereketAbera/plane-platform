# 0013. Hybrid branding: overlay, patches and codemod

**Status:** Accepted, 2026-11-04, with measured numbers added 2026-11-05. Runtime validation pending where marked. `apps/wayline/` is committed, and whether the overlays reference its images is the deployment's business, not this record's.

## Context

The application is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), under the name Wayline. It is not an original product, and no document may present it as one.

The aim is a distinct look and name without taking ownership of Plane's code. Plane's frontends limit how that can be done (research, 2026-11-04):

| App | Render mode | Runtime | What it means |
|---|---|---|---|
| web | `ssr: false` | nginx, static `build/client` | Can be rebuilt into a thin nginx image |
| admin | `ssr: false` | nginx, static `build/client` | Same |
| space | `ssr: true` | Node, `react-router-serve` | Client and server bundles must be replaced together, since the SSR bundle embeds asset URLs |

All three are React Router 7 on Vite. The design system is CSS variables, so a lot can change through tokens. Structure (auth layout, shell, source link) can change only in source.

Upstream has 5,268 tracked files. As built, 85 are patched and 155 replaced whole by the overlay, nearly all images. The research's estimate before any of this was built was about 20 edited files.

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
| Patches | 85 files, +310 -499 lines (measured 2026-11-05), applied with plain `git apply`. A failed hunk stops the build. `--3way` depends on which git objects a machine has, so it moved to a separate rebase path (`patchwork.sh --rebase-from`) |
| Codemod | Scripted text replacement at build time. Its output is never committed |

The codemod must never touch SPDX and copyright headers, which are in 3,804 source files.

Images are published to `localhost:5001/wayline/{web,admin,space,backend}` and always referenced by digest. See [0003](0003-local-registry-and-pull-through-caches.md).

## Alternatives considered

| Option | Reach | Why not |
|---|---|---|
| Post-build only, editing CSS and images in published images | Colours, radii, density, fonts, images | Cannot restructure anything. It would be a recoloured Plane, which the owner already rejected |
| Full fork | Everything | Carries 5,268 files to patch 85, and makes each upstream release a merge |
| Runtime theme (`custom` in Plane's settings) | Two colours, per user | No fonts, radii or layout, and no instance-wide default |
| No branding, deploy upstream images | None | Would be simplest, but the owner requires a distinct product name |

## Consequences

The numbers that decided this, from research on 2026-11-04:

| Measure | Value | Basis |
|---|---|---|
| Candidate patch files touched, v1.3.0 to v1.4.0 | 12 of 65 | GitHub commits API per file |
| Candidate patch files touched, v1.4.0 to v1.4.3 | 1 of 65 | GitHub commits API per file |
| Patch size, estimated | About 20 files, 150 to 200 changed lines | Estimate, from listing the edits while reading source. Nothing was built. This was far too low |
| Patch size, as built | 85 files, +310 -499 lines, 139 hunks | `git apply --numstat`, 2026-11-05 |
| Patches against other upstream refs | `v1.4.2` and `v1.4.0`: 0 of 7 fail. `v1.3.0`: 4 of 7, 14 files. `preview` (1.5.0, unreleased): 7 of 7, 67 files, and `variables.css` is gone | `apps/wayline/checks/upstream-check.sh`, 2026-11-05 |
| Disk, native build | 1.3 GiB or less on the host, about 1 GiB in the Docker VM | Estimate, from dependency and output sizes |
| Disk, upstream's three Dockerfiles | About 5 GiB in the Docker VM | Computed from image and layer sizes |

- Each Plane upgrade means re-applying patches. A patch release has needed nothing so far, a minor release a sixth of the patched files, and the next minor line looks like a rework of tokens and most patches. A failed hunk or `overlay.lock` is the signal, and `wayline-upstream-check` gives early warning.
- A frontend build needs the pinned Node and pnpm toolchain. Peak memory during a build is 3 to 5 GiB, an estimate in `plane-branding.md`, so it should not run alongside a full cluster and a browser. [[MEASURE: peak memory and wall time of make images]]
- Replacing `build/` in space keeps upstream's dependencies. An upstream `node_modules` change would need the base digest bumped too.
- A user choosing Plane's `custom` theme overrides the palette, and keeps Wayline's shapes and type.
- **AGPL.** Section 13 requires offering Corresponding Source to users who interact over a network. The offer has to include the pinned upstream ref, overlay, patches, codemod, build scripts and Dockerfiles. See [AGPL compliance](../agpl-compliance.md). The source tree and notices keep Plane's name and copyright, even where the UI shows Wayline.
- The AGPL licenses the code, not the name or mark. Plane's name and logo are treated as off limits in the UI.
- [[VERIFY: apps/wayline exists and make images builds web, admin, space and backend from the pinned commit]]
- [[VERIFY: the rendered manifests reference localhost:5001/wayline images by digest in both environments]]
- [[VERIFY: no upstream brand text remains in the running UI apart from required notices, and copyright headers are intact in the patched tree]]
- [[VERIFY: the UI exposes a source link that reaches the Corresponding Source]]
- [[VERIFY: the branded backend image runs migrations and serves the API with the same behaviour as upstream]]
