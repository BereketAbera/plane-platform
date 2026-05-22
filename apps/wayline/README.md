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
| `checks/smoke-images.sh` | Runs each pushed image by digest under the chart's UID, limits and security settings, and checks the licence texts. `backend/check-image.sh` is the backend's part. **Manual:** no workflow runs it |
| `checks/upgrade-check.sh` | `make wayline-upgrade-check`. After a bump, with no build: overlay lock, patches, tokens, contrast, and upstream's Dockerfiles and nginx configs against what was derived from them |
| `checks/upstream-check.sh` | `make wayline-upstream-check REF=preview`. Dry-runs overlay and patches against another upstream ref and reports the size of the work. A workflow also runs it weekly against `preview` |
| `runtime/` | Thin Dockerfiles and nginx configs. Upstream's Dockerfiles are not used |
| `assets/` | `masters/` holds logo masters and spinner source. `generate.mjs`, `generate-contours.mjs` and `generate-empty-states.mjs` regenerate the overlay's images, manifests, the sign-in chart and the empty states. See `assets/README.md` |
| `backend/` | Email templates, scripted string edits and the in-image check for the derived backend image |

```sh
apps/wayline/scripts/build.sh                                    # the whole thing
WAYLINE_APPS="web" apps/wayline/scripts/build.sh                 # subset of: web admin space backend
PLANE_SOURCE_MIRROR=/path/to/clone apps/wayline/scripts/build.sh # no GitHub fetch; the commit is still verified
make images                                                      # build.sh, then images, then push locally
SKIP_NATIVE_BUILD=yes make images                                # reuse .build/wayline-dist, if its source has not changed
```

Everything is written under `.build/` at the repo root, including a project-local pnpm store and
corepack home, so the user's global store does not grow. The build runs under `env -i` because each
`vite.config.ts` embeds every `VITE_*` it can see.

## Why this shape

A native build plus thin images costs little. Time and peak memory of the latest clean build are in
[`docs/evidence/branding/build.txt`](../../docs/evidence/branding/build.txt). `.build/` is about 2.4 GiB on disk, against
an estimated 5 GiB in the Docker VM for upstream's Dockerfiles. Static web and admin output is portable. Space keeps
upstream's Linux `node_modules` and swaps only `build/`.

Post-build rewriting alone cannot restructure the shell or the sign-in screen, and a full fork would carry over 5,000
files to change 85 by patch and replace 155 whole. Those are measured, on 2026-11-05: patches are 85 files, +310 -499,
139 hunks, about 110 KB, and brand CSS is about 1,200 lines. The research's estimate of about 20 files and 150 to 200
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

**The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an instance.**

The licence texts are in every image at `/usr/share/licenses/wayline/`, and at `/licenses/` on the web image.

## Images

| Image | Base | Runs as | Notes |
|---|---|---|---|
| `wayline/web` | `nginx:1.31-alpine` | UID 101 (hardening patch) | pid on `/run`, temp on `/var/cache/nginx`, both emptyDirs |
| `wayline/admin` | `nginx:1.31-alpine` | UID 101 | Served under `/god-mode/` |
| `wayline/space` | `makeplane/plane-space:v1.4.3` | UID 1000 | Only `build/` replaced |
| `wayline/backend` | `makeplane/plane-backend:v1.4.3` | UID 1000 | Templates and strings. Used by api, worker, beat, migrator. Label says `AGPL-3.0-only AND LicenseRef-Plane-Commercial`, see `MODIFICATIONS.md` |

Base digests come from `docker buildx imagetools inspect`, and are written in each Dockerfile with the date. Rebuilding
the same commit can give a different digest, because file times and OS packages move. A digest, not a rebuild, is the
identity of a release.

### GHCR quota

The free private quota is 500 MB, shared with Actions artifacts. GHCR stores upstream's layers too,
because nothing is mounted across registries. Compressed arm64 sizes measured on 2026-11-04 with
`docker buildx imagetools inspect --raw`: backend base 105.9 MiB, nginx base 25.0 MiB. The space base
is 255.8 MiB from the research's registry measurement. With about 25 MiB of app layers, that is about
415 MiB for one set (nginx counted once), so one set fits and little else does. So:

- **`images.yml` has never run with `apps/wayline` in it.** One pull request is needed to exercise the build-only job,
  and the native arm64 build, GHCR push, prune and these numbers are unproven until then.
- Publishing is off until the owner decides D12 (`backend/email-py-decision.txt`), so a push to main stops before GHCR.
- Pull requests only build, and never push.
- A push to main publishes, then `scripts/prune-ghcr.sh` keeps the newest two versions per image. Later
  versions share the upstream layers, so a second version should cost only its app layers if GHCR
  counts shared layers once. That is an assumption: GitHub does not document it, so check the
  package page after the first two publishes.
- Pruning with `GITHUB_TOKEN` has not been run yet, and may need the package's Actions access set to Admin.
- `make images` to the local registry uses no quota and is the path in pass 1.

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
5. Run `make images`, which is the only place `backend/edit_strings.py` runs, with an exact match count for every edit. Its
   failure names the string that moved. `leak-scan` reports new brand strings, usually a line for `codemod/rebrand.mjs`.
6. Run `checks/smoke-images.sh` by hand, with `WAYLINE_EXPECT_REF` set to the commit. No workflow runs it.
7. Look at the app: sign-in, sidebar, board, settings, an empty state, god-mode, a public page.

What this costs, measured on 2026-11-05 with `checks/upstream-check.sh`, which applies the current overlay and every
patch file by file:

| Upstream | Patches failing | Files needing a rebase | Overlay paths gone or changed | Design system |
|---|---|---|---|---|
| `v1.4.2` | 0 of 7 | 0 of 85 | 0 | Same |
| `v1.4.0` | 0 of 7 | 0 of 85 | 0 | Same |
| `v1.3.0` | 4 of 7 | 14 of 85 | 0 | Same |
| `preview` (`package.json` 1.5.0, unreleased, may change) | 7 of 7 | 67 of 85 | 45 gone, 3 changed of 155 | `variables.css` is gone, tokens moved to `@makeplane/propel` |

So a patch release has needed nothing, and an earlier minor release needed about a sixth of the patched files reworked.
**Expect 1.5 to need a rework of the brand tokens and most patches**, not a routine rebase. No time estimate is given,
because none has been measured. The weekly `wayline-upstream-check` workflow, or `make wayline-upstream-check REF=preview`,
shows that size growing before it arrives.
