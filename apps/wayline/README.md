# Wayline

Wayline is a customized [Plane Community Edition](https://github.com/makeplane/plane) deployment, not
an original product. This directory holds everything that makes it different: the rest of Plane comes
from the pinned upstream commit in [`UPSTREAM`](UPSTREAM), unmodified. See
[`NOTICE.md`](../../NOTICE.md) for the AGPL notice and [`MODIFICATIONS.md`](MODIFICATIONS.md) for the
dated list of what changed. Patch authors should read [`AUTHORING.md`](AUTHORING.md).

## How the pipeline works

```text
UPSTREAM commit ──> overlay/ ──> patches/*.patch ──> codemod/rebrand.mjs ──> turbo build ──> leak-scan ──> .build/wayline-dist
   fetch.sh         whole files   git apply --3way    text in TS, i18n,      one per app     font-urls      Docker contexts
                    rsync         numeric order       manifests                                              images.txt
```

| Piece | What it is |
|---|---|
| `overlay/` | Files copied verbatim over the checkout: brand CSS, fonts, logo components, images |
| `patches/` | Small unified diffs for structure the tokens cannot reach. A failed hunk stops the build |
| `codemod/rebrand.mjs` | Scripted brand text replacement. Runs after patches, and its output is never committed |
| `checks/token-diff.mjs` | Every token in brand CSS must exist upstream. Catches a design-system rewrite loudly |
| `checks/contrast.mjs` | WCAG contrast of the main pairs in all four themes and the ink shell |
| `checks/leak-scan.sh` | Fails on the upstream brand in build output, except allowlisted entries with reasons |
| `checks/font-urls.sh` | Proves from the built CSS that fonts resolve under `/`, `/god-mode/`, `/spaces/` |
| `runtime/` | Thin Dockerfiles and nginx configs. Upstream's Dockerfiles are not used |
| `assets/` | `masters/` holds logo masters and spinner source. `generate.mjs` and `generate-contours.mjs` regenerate the overlay's images, manifests and the auth chart. See `assets/README.md` |
| `backend/` | Email templates, scripted string edits and the in-image check for the derived backend image |

```sh
apps/wayline/scripts/build.sh                                    # the whole thing
WAYLINE_APPS="web" apps/wayline/scripts/build.sh                 # subset of: web admin space backend
PLANE_SOURCE_MIRROR=/path/to/clone apps/wayline/scripts/build.sh # no GitHub fetch; the commit is still verified
make images                                                      # build.sh, then images, then push locally
SKIP_NATIVE_BUILD=yes make images                                # reuse .build/wayline-dist
```

Everything is written under `.build/` at the repo root, including a project-local pnpm store and
corepack home, so the user's global store does not grow. The build runs under `env -i` because each
`vite.config.ts` embeds every `VITE_*` it can see.

## Why this shape

A native build plus thin images costs little. Measured on 2026-11-04 on this Mac: all three apps in 65 s from a
cold turbo cache with the pnpm store populated, the largest single process at about 2.0 GiB, and about 2.3 GiB for all
build processes together (`.local/evidence-raw/wayline-build-1.txt`). `.build/` is about 2.4 GiB on disk, against an
estimated 5 GiB in the Docker VM for upstream's Dockerfiles. Static web and admin output is portable. Space keeps
upstream's Linux `node_modules` and swaps only `build/`.

Post-build rewriting alone cannot restructure the shell or the sign-in screen, and a full fork would
carry over 5,000 files to change about twenty.

## Domain and link policy

Set out at the top of `codemod/rebrand.mjs` and mirrored in `checks/leak-allowlist.txt`:

- Marketing, legal, support and community links point at `/source`, or are removed by a patch.
- `VITE_WEBSITE_URL` is `/source`, and `VITE_SUPPORT_EMAIL` is empty, which takes upstream's existing
  "contact your administrator" branch. No address is invented.
- Form placeholders use `example.com`.
- Kept, each with a stated reason: the two `docs.plane.so` links and the telemetry page on
  `developers.plane.so`, because no other manual exists for this software, and `intake@plane.so`, because
  the code compares against it.
- "Built on Plane Community Edition" is the one permitted UI credit, linking to `/source`.

`/source` is an nginx redirect in the web image to `<repo>/tree/<commit>`. The ingress routes `/` to web,
so the path works from `/god-mode/` and `/spaces/` too. The target can be overridden at image build time with
`WAYLINE_SOURCE_REPO`. **The repository must be public before anyone other than the owner uses an
instance**, or the AGPL section 13 offer leads nowhere.

## Images

| Image | Base | Runs as | Notes |
|---|---|---|---|
| `wayline/web` | `nginx:1.31-alpine` | UID 101 (hardening patch) | pid on `/run`, temp on `/var/cache/nginx`, both emptyDirs |
| `wayline/admin` | `nginx:1.31-alpine` | UID 101 | Served under `/god-mode/` |
| `wayline/space` | `makeplane/plane-space:v1.4.3` | UID 1000 | Only `build/` replaced |
| `wayline/backend` | `makeplane/plane-backend:v1.4.3` | UID 1000 | Templates and strings. Used by api, worker, beat, migrator |

Base digests come from `docker buildx imagetools inspect`, and are written in each Dockerfile with the date.

### GHCR quota

The free private quota is 500 MB, shared with Actions artifacts. GHCR stores upstream's layers too,
because nothing is mounted across registries. Compressed arm64 sizes measured on 2026-11-04 with
`docker buildx imagetools inspect --raw`: backend base 105.9 MiB, nginx base 25.0 MiB. The space base
is 255.8 MiB from the research's registry measurement. With about 25 MiB of app layers, that is about
415 MiB for one set (nginx counted once), so one set fits and little else does. So:

- Pull requests only build, and never push.
- A push to main publishes, then `scripts/prune-ghcr.sh` keeps the newest two versions per image. Later
  versions share the upstream layers, so a second version should cost only its app layers if GHCR
  counts shared layers once. That is an assumption: GitHub does not document it, so check the
  package page after the first two publishes.
- Pruning with `GITHUB_TOKEN` has not been run yet, and may need the package's Actions access set to Admin.
- `make images` to the local registry uses no quota and is the path in pass 1.

## Upgrading upstream

1. Bump `UPSTREAM` (tag and commit) and the digests in `runtime/` in one commit, with digests from
   `docker buildx imagetools inspect`. The `v1.4.3` in the `FROM` lines is also the upstream version.
2. Run `scripts/apply.sh`. A failed hunk stops it and names the patch. Rebase that patch in the patchwork.
3. Run `checks/token-diff.mjs`. Anything it flags means upstream renamed a token.
4. Run `scripts/build.sh`. `leak-scan` reports new brand strings, usually a line for `codemod/rebrand.mjs`.
5. Look at the app: sign-in, sidebar, board, god-mode, a public page.

Upstream's history suggests 0 or 1 conflicts in an ordinary release, and a day's work for a design-system
rewrite like v1.2 to v1.3 (estimates from the commit history).
