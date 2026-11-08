# Wayline

Wayline is a customized [Plane Community Edition](https://github.com/makeplane/plane) deployment, not
an original product. This directory holds everything that makes it different: the rest of Plane comes
from the pinned upstream commit in [`UPSTREAM`](UPSTREAM), unmodified. See
[`NOTICE.md`](../../NOTICE.md) for the AGPL notice and [`MODIFICATIONS.md`](MODIFICATIONS.md) for the
dated list of what changed. Patch authors should read [`AUTHORING.md`](AUTHORING.md).

## How the pipeline works

```text
UPSTREAM commit ──> overlay/ ──> patches/*.patch ──> codemod/rebrand.mjs ──> turbo build ──> leak-scan ──> .build/wayline-dist
   fetch.sh         whole files   plain git apply     text in TS, i18n,      one per app     font-urls      Docker contexts
                    rsync, lock   numeric order       manifests                               bundle-art     licences, SOURCE.<app>
```

| Piece | What it is |
|---|---|
| `overlay/` | Files copied verbatim over the checkout: brand CSS, fonts, logo components, images, empty states |
| `overlay.lock` | The upstream blob each overlay file replaces. `scripts/apply.sh` stops, naming the file, if upstream moved or changed it |
| `patches/` | Small unified diffs for structure the tokens cannot reach. A failed hunk stops the build. Applied without `--3way`, so the result does not depend on which git objects a machine has |
| `codemod/rebrand.mjs` | Scripted brand text replacement. Runs after patches, and its output is never committed |
| `checks/token-diff.mjs` | Every token in brand CSS must exist upstream. Catches a design-system rewrite loudly |
| `checks/contrast.mjs` | WCAG contrast in all four themes, the ink shell and the paper page scope: resting colours, every hover, active and selected layer, and accent tints composited over their surface |
| `checks/source-links.mjs` | Fails if a router link points at `/source`, which nginx answers, not the app |
| `checks/leak-scan.sh` | Fails on the upstream brand in what the frontends ship and in the rewritten mail templates, except allowlisted entries with reasons. `backend/check_image.py` covers the rest of the backend image, inside the image |
| `checks/bundle-art.sh` | Fails if upstream's isometric empty states reach a bundle |
| `checks/font-urls.sh` | Proves from the built CSS that fonts resolve under `/`, `/god-mode/`, `/spaces/` |
| `checks/smoke-images.sh` | Runs each pushed image by digest under the chart's UID, limits and security settings, and checks the licence texts, that X-Forwarded-For behaves, nginx's redirects, and what a browser may keep: `Cache-Control` on every kind of response including errors for a real hashed name, the 4 security headers and 304s. `backend/check-image.sh` is the backend's part. `images.yml` runs it on the x86-64 runner against the digests it just published, and a failure stops the digest bump. Every image must be `PLATFORM`, or nothing runs. By hand, it reads `.build/digests.tsv` |
| `checks/cache-names.sh` | Stops the build if a file could reach `assets/` with a name no bundler hashed, because nginx keeps such names for a year |
| `checks/layer-check.py` | Reads every layer of an image as a registry serves it, including files a later layer hides, and fails if any holds the identifier on upstream's commercially licensed files in any case or in UTF-16, the original file's sha256, or bytecode at its path. It opens archives by their first bytes, not their names, and an image with something it could not open exits 2. It reads the child of an index for `PLATFORM`, and an image whose config says another platform exits 2 too. `scripts/ci/build-images.sh` runs it before publishing anything and again on what it published. `--report-only` does the same for images we deploy unmodified, and never fails a build on them |
| `checks/layer-check-cases.py` | Tests `layer-check.py` on layers it makes in memory, what it and the other readers do with an image of another architecture, on a read-only registry it serves on loopback, and with `--registry` real images through the command. `images.yml` runs it without `--registry`, before each build |
| `checks/flatten-config.py` | Fails if the flattened backend dropped anything its base's config says. `scripts/ci/build-images.sh` runs it before publishing anything, and `checks/smoke-images.sh` on what was published |
| `checks/flatten-compare.py` | Compares two images path by path and field by field, read from their registries. Manual, for evidence |
| `checks/space-regions.mjs` | Lists the packages the bundler inlined into the space server, which `runtime/space-deps.mjs` cannot see. Manual, for evidence |
| `checks/backend-db.sh` | Runs the backend against a scratch Postgres, Redis and mail server it starts itself: migrations, registration, the setup endpoint, an invitation and a mail read back. `WAYLINE_BASE_CONTROL=yes` also shows the same checks failing on upstream's image. **Manual:** no workflow runs it |
| `checks/upgrade-check.sh` | `make wayline-upgrade-check`. After a bump, with no build: overlay lock, patches, tokens, contrast, and upstream's Dockerfiles and nginx configs against what was derived from them |
| `checks/upstream-check.sh` | `make wayline-upstream-check REF=preview`. Dry-runs overlay and patches against another upstream ref and reports the size of the work. A workflow also runs it weekly against `preview` |
| `runtime/` | Thin Dockerfiles and nginx configs. Upstream's Dockerfiles are not used |
| `assets/` | `masters/` holds logo masters and spinner source. `generate.mjs`, `generate-contours.mjs` and `generate-empty-states.mjs` regenerate the overlay's images, manifests, the sign-in chart and the empty states. See `assets/README.md` |
| `backend/` | Email templates, scripted string edits, the in-image checks for the derived backend image, upstream's AGPL `email.py` in `vendor/`, and the PyJWT pin |
| `scripts/publish-gate.sh` | Where images may go, from `backend/email-py-decision.txt`. `scripts/ci/build-images.sh` and `images.yml` both call it |

```sh
apps/wayline/scripts/build.sh                                    # the whole thing
WAYLINE_APPS="web" apps/wayline/scripts/build.sh                 # subset of: web admin space backend
PLANE_SOURCE_MIRROR=/path/to/clone apps/wayline/scripts/build.sh # no GitHub fetch; the commit is still verified
make images                                                      # build.sh, then images, then push locally
SKIP_NATIVE_BUILD=yes make images                                # reuse .build/wayline-dist, if its source has not changed
```

`make images` builds `linux/arm64`, which the laptop's kind node runs. `PLATFORM` chooses another, and `images.yml` sets `linux/amd64` on an x86-64 runner,
because the VPS is x86-64. `scripts/ci/build-images.sh`, `scripts/ci/scan-images.sh`, `checks/smoke-images.sh` and the readers in `checks/` all follow it, so
a walk or a scan reads the image production runs. A plain manifest names one architecture, and reading it for another fails.

Everything is written under `.build/` at the repo root, including a project-local pnpm store and
corepack home, so the user's global store does not grow. The build runs under `env -i` because each
`vite.config.ts` embeds every `VITE_*` it can see.

## Why this shape

A native build plus thin images costs little. Time and peak memory of the latest clean build are in
[`docs/evidence/branding/build.txt`](../../docs/evidence/branding/build.txt). `.build/` is about 2.4 GiB on disk, against
an estimated 5 GiB in the Docker VM for upstream's Dockerfiles. Static web and admin output is portable. Space keeps
upstream's Linux `node_modules` and swaps only `build/`.

Post-build rewriting alone cannot restructure the shell or the sign-in screen, and a full fork would carry over 5,000
files to change 86 by patch and replace 155 whole. Those are measured, on 2026-11-05: patches are 86 files, +311 -500,
140 hunks, about 110 KB, and brand CSS is about 1,200 lines. The research's estimate of about 20 files and 150 to 200
lines was far too low. `MODIFICATIONS.md` has the breakdown.

## Domain and link policy

Set out at the top of `codemod/rebrand.mjs` and mirrored in `checks/leak-allowlist.txt`:

- Marketing, legal, support and community links point at `/source`, or are removed by a patch.
- `VITE_WEBSITE_URL` is `/source`, and `VITE_SUPPORT_EMAIL` is empty, which takes upstream's existing
  "contact your administrator" branch. No address is invented.
- Form placeholders use `example.com`.
- Kept, each with a stated reason: `docs.plane.so`, exactly the root URL and the estimates page in the frontends, and in
  the backend's seeded work items `core-concepts/{cycles,issues/layouts,issues/overview,workspaces/members}`; the
  telemetry page on `developers.plane.so`, because no other manual exists for this software; and `intake@plane.so`,
  because the code compares against it. In the backend, `backend/check_image.py` also allows whole files that are
  telemetry code or docstrings (`telemetry_metrics.py`, `otlp_endpoints.py`, `utils/core/__init__.py`), each with its reason there.
- "Built on Plane Community Edition" is the one permitted UI credit, linking to `/source`.

`/source` is an nginx redirect in the web image to `<repo>/tree/<commit>`, and `<commit>` is the one `build.sh` stamped
into the context in `.build/wayline-dist/SOURCE.<app>`. `scripts/ci/build-images.sh` refuses to push a context built from
uncommitted source, or one whose source has changed since, and warns when the commit is not on `origin/main`. The ingress
routes `/` to web, so the path works from `/god-mode/` and `/spaces/` too. The target can be overridden at image build time
with `WAYLINE_SOURCE_REPO`.

**The link works once the repository is public. It is private as of 2026-11-07, so `/source` returns 404 to anyone without access. An image `images.yml` publishes is built from a commit already on GitHub, so the commit the link names is there. The owner must make the repository public before anyone else uses an instance.**

`NOTICE.md` and `MODIFICATIONS.md` say the same, in words meant to stay true after that. Both ship in every image and `images.yml` watches them, so an edit to either rebuilds the images on the next push.

The licence texts are in every image at `/usr/share/licenses/wayline/`, and at `/licenses/` on the web image.

## Images

| Image | Base | Runs as | Notes |
|---|---|---|---|
| `wayline/web` | `nginx:1.31-alpine` | UID 101 (hardening patch) | pid on `/run`, temp on `/var/cache/nginx`, both emptyDirs |
| `wayline/admin` | `nginx:1.31-alpine` | UID 101 | Served under `/god-mode/` |
| `wayline/space` | `makeplane/plane-space:v1.4.3` | UID 1000 | `build/` replaced, proxy-addr 2.0.8, no storybook or tinypool: `runtime/space-deps.mjs` |
| `wayline/backend` | `scratch`, holding a filesystem derived from `makeplane/plane-backend:v1.4.3` | UID 1000 | Templates, strings, upstream's AGPL `email.py`, PyJWT 2.14.0. Used by api, worker, beat, migrator. Label says `AGPL-3.0-only`. Flattened, so no layer holds the commercially headed original. See D12 in `MODIFICATIONS.md` |

Base digests come from `docker buildx imagetools inspect`, and are written in each Dockerfile with the date. Rebuilding
the same commit can give a different digest, because file times and OS packages move. A digest, not a rebuild, is the
identity of a release.

In an image that keeps its `FROM` layers, which is every image here but the backend, a file replaced or removed stays in those layers. It is gone from
the container's filesystem, and from what `trivy image` reports, but not from the bytes of the image. So the space image still holds
proxy-addr 2.0.7, storybook and tinypool. The backend is flattened, so PyJWT 2.13.0 and the original `email.py` are in no layer of it.

### What flattening costs

Disk, for every version after the first, and not push time. Measured on 2026-11-05 in
[`docs/evidence/branding/flatten-size.txt`](../../docs/evidence/branding/flatten-size.txt), holding the same files and pushing with `docker push` into a new registry on loopback:

| | Unflattened | Flattened |
|---|---|---|
| Layers | 28 | 2, one of them BuildKit's empty layer for `WORKDIR` |
| Compressed size | 106.0 MiB | 97.4 MiB, because no file is stored twice |
| A registry grows, first version | 106.3 MiB | 97.5 MiB |
| A registry grows, each later version | 0.25 MiB | 97.5 MiB, because a new version shares no layer with the last |
| In Docker, unique to one image | 1.3 MB, and 511 MB shared with upstream's image | 479 MB, and nothing shared |
| `docker push`, first version, 3 runs | 0.93 to 0.99 s | 0.84 to 1.02 s |
| `docker push`, a later version, 3 runs | 0.73 to 0.74 s | 0.92 to 1.06 s |

Loopback hides the transfer, so on a real network a later version takes as long as its 97.5 MiB does, where it took almost nothing. The build itself copies the
filesystem and compresses it for each change to the context: 3.2 s and 8.5 s on this Mac. `plane-registry` keeps every version pushed to it, so it now grows by that much per backend build.
Upstream's backend image stays on any machine that builds this one, because it is a build input, and on any node while an environment still runs it. Its layers go out of use on a node only after every environment there has moved to this image, and kubelet then removes them when it needs the space. That last part was not measured.

### Publishing to GHCR

- **`images.yml` has run with `apps/wayline` in it.** Runs 41975430939 at `9c8e098` and 42044273310 at `76e98ee` each built the four images natively on arm64, walked them before and after publishing, scanned them, and
  published them to GHCR as private packages ([CI evidence](../../docs/evidence/ci/README.md)). The build-only job on a pull request has not run, and those digests are not the ones deployed. Those two runs were `linux/arm64`, on `ubuntu-24.04-arm`.
- **`images.yml` now builds `linux/amd64`, natively on `ubuntu-24.04`, because the VPS is x86-64. Neither job has run that way yet,** and `linux/amd64` digests are not on GHCR until one does.
- Images go only to the local registry or `ghcr.io/bereketabera/wayline`. That is decision D12 (`backend/email-py-decision.txt`,
  `scripts/publish-gate.sh`, `MODIFICATIONS.md`). The `images.yml` publish job runs that gate first, and fails where publishing is not allowed.
- Pull requests only build, and never push.
- A push to main walks every layer of each image in a throwaway registry on the runner, and publishes only when all four pass, copying each by digest. It then walks each again as GHCR serves it, scans what it published with `scripts/ci/scan-images.sh`, and runs it by digest with `checks/smoke-images.sh`. A failure in any of these stops the digest bump. An image that fails the first walk or the config check reaches nobody. One that fails the second walk stays in GHCR, with no digest recorded. One that fails the scan or the smoke stays in GHCR, and no bump opens for it.
- `make images` builds, walks and copies the same way with the local registry in place of GHCR, for `linux/arm64`, so the throwaway registry, the walks and the copy by digest have run here. On GitHub they ran twice, in runs 41975430939 at `9c8e098` and 42044273310 at `76e98ee`, with the copy to GHCR and its login.
- `make images` to the local registry uses no GHCR storage and is the path in pass 1.
- **Nothing prunes GHCR.** `images.yml` had a job that kept the newest two versions per image, and it was removed, because it could delete a digest production runs or the evidence names. It listed versions in both runs and deleted none, so a prune that deletes something has never run, and that may need the package's Actions access set to Admin. `scripts/prune-ghcr.sh` stays, and refuses to delete anything until it exempts every digest in `docs/evidence/promotions` and the prod overlay.

**Publishing has no requirement that the repository be private.** The publish job used to require it, and the gate allowed only private packages. The requirement that the repository be private was removed, because no layer holds the original, and that has not been reviewed. So nothing in `publish-gate.sh` stops a public image: it checks the namespace, not the visibility.

What the owner still has to confirm. The first push of this directory went ahead on 2026-11-05 at 05:39Z and published, with this review open, and `76e98ee` published again:

- [ ] D12 in `MODIFICATIONS.md`, all of it: `email.py` replaced with upstream's later AGPL-3.0-only version, the backend flattened, and publishing with no requirement that the repository be private. All three are done, none has been reviewed, and no lawyer or other legal reviewer has looked at them.

Before the repository is made public, in this order:

1. Read each package's visibility on its GitHub page: `web`, `admin`, `space`, `backend`. Images have been published twice. With no credentials the first four answered 401 ([record](../../docs/evidence/ci/ci-4-20261105T055033Z-ghcr-visibility.txt)), and no file records anyone reading the package pages. The API needs `read:packages`, which the local token lacks.
2. Do this before making the repository public, because GitHub's documentation conflicts. One page says a package a workflow creates takes the repository's visibility. Another says a linked package takes the repository's access permissions and not its visibility. So do not assume either way what a package becomes.
3. Read them again after making the repository public. The same documentation says a package made public cannot be made private again.

Pruning was a precaution, not a response to a known limit, so GHCR can keep growing for now. GitHub's Packages billing page lists 500 MB of storage for private
packages on Free, and also says "Container image storage and bandwidth for the Container registry is currently free", with at
least a month's notice before that changes. So the 500 MB should not apply to `ghcr.io` today. Two builds are stored there, the first holding 401.8 MiB, and November's usage summary showed no packages row after it ([compare](../../docs/evidence/ci/ci-4-20261105T060219Z-published-compare.txt), [billing](../../docs/evidence/ci/plan-facts-20261105T062632Z.txt)).
No file records anyone reading the package page. GHCR stores upstream's layers for space too, because nothing is
mounted across registries. Compressed arm64 sizes with `docker buildx imagetools inspect --raw`: flattened backend 97.4 MiB
on 2026-11-05, nginx base 25.0 MiB on 2026-11-04. The space base is 255.8 MiB from the research's registry measurement. With about
25 MiB of app layers, that is about 405 MiB for one set (nginx counted once), and each further backend version adds about 97 MiB, as below.

## Upgrading upstream

1. Bump `UPSTREAM` (tag and commit) and the digests in `runtime/` in one commit, with digests from
   `docker buildx imagetools inspect`. The `v1.4.3` in the `FROM` lines is also the upstream version. Also bump the
   `plane-live` digest in `helm/plane/overlays/*/kustomization.yaml` and the vendored chart, which `apps/wayline` does
   not own, and the version lines in `NOTICE.md` and `MODIFICATIONS.md`.
2. Run `make wayline-upgrade-check`. It stops first on `overlay.lock`, naming each path upstream moved, deleted or
   changed. Merge those by hand, including TSX and CSS replaced whole, then run `scripts/overlay-lock.sh --update`.
3. It then applies the patches. A failed hunk stops it and names the patch. Run
   `scripts/patchwork.sh --rebase-from <old tag>`, which fetches the old blobs so patches can merge with `--3way`, resolve
   the conflicts in `.build/plane-patchwork`, and save each patch again with `scripts/save-patch.sh`.
4. It finishes with token-diff, contrast, `VITE_*` in `scripts/build.sh` against upstream's Dockerfiles, and upstream's
   nginx configs and Dockerfiles against what `runtime/` derived from them. Read anything it names.
5. Run `make images`, which is the only place `backend/edit_strings.py` and `runtime/space-deps.mjs` run. Each states exactly
   what it expects, so its failure names the string or package that moved. If upstream has moved past a dependency this replaces, or
   a release now carries the AGPL header on `email.py`, delete the replacement rather than updating it, and see whether the backend still needs flattening.
   `leak-scan` reports new brand strings, usually a line for `codemod/rebrand.mjs`. `checks/flatten-config.py` stops here if the new base's
   config says something the last stage of `runtime/Dockerfile.backend` does not restate, and `checks/layer-check.py` if a layer holds the commercial identifier.
6. Run `checks/smoke-images.sh` by hand on what `make images` built, with `WAYLINE_EXPECT_REF` set to the commit, and `WAYLINE_BASE_CONTROL=yes checks/backend-db.sh`.
   `images.yml` runs the first again on `linux/amd64` after a push. No workflow runs the second.
7. Look at the app: sign-in, sidebar, board, settings, an empty state, god-mode, a public page.

What this costs, measured on 2026-11-05 with `checks/upstream-check.sh`, which applies the current overlay and every
patch file by file:

| Upstream | Patches failing | Files needing a rebase | Overlay paths gone or changed | Design system |
|---|---|---|---|---|
| `v1.4.2` | 0 of 7 | 0 of 86 | 0 | Same |
| `v1.4.0` | 0 of 7 | 0 of 86 | 0 | Same |
| `v1.3.0` | 4 of 7 | 14 of 86 | 0 | Same |
| `preview` (`package.json` 1.5.0, unreleased, may change) | 7 of 7 | 68 of 86 | 45 gone, 3 changed of 155 | `variables.css` is gone, tokens moved to `@makeplane/propel` |

So a patch release has needed nothing, and an earlier minor release needed about a sixth of the patched files reworked.
**Expect 1.5 to need a rework of the brand tokens and most patches**, not a routine rebase. No time estimate is given,
because none has been measured. The weekly `wayline-upstream-check` workflow, or `make wayline-upstream-check REF=preview`,
shows that size growing before it arrives.
