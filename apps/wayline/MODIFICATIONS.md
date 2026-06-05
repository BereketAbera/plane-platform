# Modifications to Plane Community Edition v1.4.3

The AGPL section 5 notice of what this directory changes. [`NOTICE.md`](../../NOTICE.md) has the short
form and the license statement.

- **Upstream:** <https://github.com/makeplane/plane>, tag `v1.4.3`, commit
  `37a15d99231042b3ff5a4401fed479fdbec9effe`. Copyright 2023-present Plane Software, Inc. and contributors.
  AGPL-3.0.
- **Modified by:** AI coding agents, under the name of this repository's owner, Bereket Abera (the owner, below), 2026-11-04 to
  2026-11-05. His name on the work does not mean he reviewed each change, and the D12 section below says what he has not reviewed.
- **Modified version's name:** Wayline, a customized deployment of Plane Community Edition, not an
  original product.
- **License of the modifications:** AGPL-3.0-only.
- **How to read the changes:** `overlay/` files replace or add whole files, `patches/` are unified diffs,
  `codemod/rebrand.mjs` rewrites text at build time, and `backend/edit_strings.py` lists every edit to
  upstream's Python. None of the results are committed. `scripts/apply.sh` reproduces the modified tree in
  `.build/plane-src` from the pinned commit.

The `live` service is unmodified and keeps upstream's image.

**The source offer is not live yet.** The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an instance.

## Behaviour changes

Most of this is appearance and text. These are the changes that alter what the software does:

| Change | Where |
|---|---|
| Telemetry starts off for a new instance: the god-mode setup form starts unticked, instance registration writes `is_telemetry_enabled=False`, and the setup endpoint falls back to false when the field is missing. The setting stays available. The model default is unchanged, because changing it would call for a migration. **An instance registered earlier by upstream's image keeps its stored setting, which is on unless someone turned it off, after moving to this image.** The worker's metrics task then exports to upstream's default, `telemetry.plane.so:443`. On this platform, `tests/network-policy-matrix.yaml` expects the api and worker pods to be denied that host and port in both environments, and the recorded runs saw them time out, so the export fails there. An instance on this image without that NetworkPolicy would send it | `patches/40-admin.patch`, `backend/edit_strings.py` |
| Telemetry consent text says the data goes to the upstream project, whose endpoint is still the default | `patches/40-admin.patch` |
| Billing settings are refused for every role (`access: []`): hidden from navigation and search, and a direct URL shows the not-authorized view. Upstream's page behind it is unchanged and never mounts | `patches/30-surfaces.patch` |
| The upgrade badge and the bulk operations banner render nothing, and the edition badge component no longer opens a paid-plan modal. License gates are not changed: nothing paid is unlocked | `patches/30-surfaces.patch` |
| The workspace "Active cycles" menu item is gone. Its route, which in Community Edition only ever held an upsell, now says plainly that the feature is not part of this edition | `patches/30-surfaces.patch` |
| "Star us on GitHub" and the edition badge footer are no longer rendered in the shell | `patches/10-shell.patch` |
| The backend image sets `INSTANCE_CHANGELOG_URL` empty, so "What's new" shows the local fallback rather than upstream's page. The setting still works for an operator who sets it | `runtime/Dockerfile.backend`, `patches/30-surfaces.patch` (fallback wording) |
| `source` is a reserved workspace slug, because the web image answers that path itself. (Upstream already reserves `licenses`, the other path it answers.) A workspace that already uses it keeps working, except that the exact URL `/source` goes to nginx | `patches/30-surfaces.patch`, `backend/edit_strings.py` |
| The maintenance and error pages say "contact your administrator" and link the source code, not upstream's support address | `patches/30-surfaces.patch` |
| The "Learn more about projects" button and the expired-invitation page's "Star us on GitHub" and "Join our community" items are removed | `patches/30-surfaces.patch` |
| Help menus lose the forum, contact-sales and bug-report entries, and gain a source code link | `patches/30-surfaces.patch`, `patches/40-admin.patch` |
| The public pages' corner badge is always on where it renders, because it carries the AGPL section 13 offer | `patches/50-space.patch` |
| The sign-up consent label and terms text name the instance administrator, not upstream | `patches/20-auth.patch`, `patches/50-space.patch` |
| Marketing, legal, support and community links go to `/source` or are removed | `codemod/rebrand.mjs`, `patches/` |
| Seed data for new workspaces is reworded, and 7 images hotlinked from upstream's CDN are gone | `backend/edit_strings.py` |
| Default sender is `Wayline <noreply@wayline.invalid>`. `EMAIL_FROM` still takes precedence | `backend/edit_strings.py` |
| Web and admin run nginx as UID 101, space and backend as UID 1000. Web answers `/source` with a 302 to this repository at the commit that built the image, and serves the licence texts at `/licenses/` | `runtime/` |
| Onboarding's `has_marketing_email_consent` starts false. Upstream's starts true, and is sent even when the checkbox is hidden | `patches/20-auth.patch` |
| The plain-text part of mail decodes HTML character references, and style blocks are stripped in linear time, because `plane/utils/email.py` is upstream's later version. See the D12 section below | `backend/vendor/email.py` |
| The workspace and project invitation tasks also store that helper's result in the invitation's `message` column, which the API serves. So that field now holds decoded raw markup where it held escaped text: a workspace named `<b>x</b>` is stored as `<b>x</b>`, not `&lt;b&gt;x&lt;/b&gt;`. No frontend reads it | `backend/vendor/email.py`, proved by `backend/check_db.py` |
| Web and admin tell browsers what they may keep: a year and `immutable` on a success for the bundler's hashed files, and `Cache-Control: no-cache` on every error, on HTML and on everything else without a content hash in its name, so a browser holding HTML from these images sees a promotion or a rollback at the next request. Upstream's config sends no `Cache-Control`, so a browser reuses HTML unasked for about a tenth of the file's age. That is the limit on the above: a browser still holding HTML from an image without the header reuses it unasked until that time runs out, which for upstream's `index.html` was about 17.5 h at the time of writing, on 2026-11-05, and grows with the file's age. A rollback to any digest built before `e885fc0` brings back the header-less HTML | `runtime/nginx-web.conf`, `runtime/nginx-admin.conf` |
| Web and admin ignore a `Range` header and answer with the whole file, because nginx sends its 416 with what it had already set for a 200. No file they serve needs part of a file. Their redirects for a directory asked for without its slash are relative, because an absolute one names port 3000, which the ingress does not serve | `runtime/nginx-web.conf`, `runtime/nginx-admin.conf` |
| The backend image has PyJWT 2.14.0 in place of 2.13.0. The space image has proxy-addr 2.0.8 in place of 2.0.7, and does not have storybook or tinypool. See the dependency section below | `backend/pyjwt-requirements.txt`, `runtime/space-deps.mjs` |

## Files, by group

### Build-time text rewrite

`codemod/rebrand.mjs` runs over the TS and TSX of `apps/web`, `apps/admin`, `apps/space` and `packages/`, the
i18n JSON for all 19 locales, and the web manifests. It changes the product name, domain links and form
placeholders, and swaps upstream's blue `#3f76ff` and teal `#028375` where tokens cannot reach (data and status
colours, the page PDF, the default avatar). It never touches SPDX or copyright lines, import lines, JSON keys, `@plane/*` packages, `X-Plane-*`
headers or `PlaneLogo`-style component names.

### Overlay: whole files (`overlay/`, 175 files: 155 replace an upstream file, 20 are new)

`overlay.lock` records the upstream blob each one replaces, and `scripts/apply.sh` stops if that changes.

| Group | Files |
|---|---|
| Brand CSS, new | `packages/tailwind-config/brand.css`, `brand/{tokens,shell,auth,admin,space}.css` |
| Fonts, new | `packages/tailwind-config/fonts/`: Instrument Sans and JetBrains Mono, SIL OFL 1.1, licenses and checksums alongside |
| Logo components, replaced artwork at upstream's names | `packages/propel/src/icons/brand/plane-{logo,lockup,wordmark}.tsx`, `sub-brand/plane-icon.tsx`, `packages/propel/public/plane-lockup-light.svg` |
| Images, replaced at upstream's names and dimensions: 143 favicons, PWA icons, spinners, marks, empty states, tour art | `apps/{web,admin,space}/app/assets/**`, `apps/{web,admin,space}/public/**`. Generated by `assets/generate.mjs` |
| Manifests, 7 | `apps/web/manifest.json`, `apps/{web,admin,space}/public/**`, `apps/space/app/assets/favicon/site.webmanifest` |
| Sign-in chart, new. One sheet, three generated copies, from `assets/generate-contours.mjs` | `apps/web/core/components/auth-screens/wayline-{chart,split}.tsx`, `apps/admin/app/(all)/(home)/{wayline-chart,auth-split}.tsx`, `apps/space/components/views/{wayline-chart,route-chart}.tsx` |
| Empty states, replaced registry: every `assetKey` draws a flat chart symbol, not upstream's isometric illustrations. Generated by `assets/generate-empty-states.mjs` | `packages/propel/src/empty-state/assets/asset-registry.tsx` |

Upstream images kept unchanged, with reasons in `assets/README.md`: file-type icons, stock cover photos,
third-party sign-in logos, the fallback avatar.

### Patches (`patches/`)

Measured with `git apply --numstat` on 2026-11-05: 86 files, +311 -500, 140 hunks, about 110 KB.

| Patch | Files | Lines | Scope |
|---|---|---|---|
| `00-brand-import` | 1 | +1 -0 | One `@import` in `packages/tailwind-config/index.css` |
| `01-fonts` | 3 | +3 -31 | `apps/{web,admin,space}/app/root.tsx`: stops loading Inter and IBM Plex Mono, ink `theme-color` |
| `10-shell` | 20 | +43 -32 | `apps/web`: full-bleed content (`workspace/content-wrapper.tsx`, `(projects)/layout.tsx`, `settings/profile/layout.tsx`), shell attributes (`navigation/top-navigation-root.tsx`, `sidebar/*`, the three settings sidebars), active item hooks, section label classes, metadata hooks |
| `20-auth` | 18 | +92 -156 | `apps/web`: split sign-in (`auth-screens/*`, `account/auth-forms/*`, `accounts/*/page.tsx`, `instance/not-ready-view.tsx`, `onboarding/*`, `create-workspace`, `invitations`), customer logos removed, terms text, marketing consent starts false |
| `30-surfaces` | 21 | +74 -178 | `apps/web`, `packages/constants`: help menu, error and maintenance pages, product updates, badges, active cycles, billing, theme swatches, reserved slugs, chart colours |
| `40-admin` | 13 | +49 -42 | `apps/admin`: split sign-in, shell, help section, setup and general forms, failure view |
| `50-space` | 10 | +49 -61 | `apps/space`: split sign-in, ink band, source badge, terms text, error and failure views |

### Backend image (`backend/`, `runtime/Dockerfile.backend`)

Derived from `makeplane/plane-backend:v1.4.3` by digest, then flattened, and shared by api, worker, beat and migrator.

| Group | Files |
|---|---|
| Email templates, rewritten: 12, plus new `_wayline_base.html` | `backend/templates/emails/**` |
| Scripted string edits, each with an exact match count: email subjects, bot name, activity text, default instance name, telemetry defaults, default sender, API error text, OpenAPI metadata, admin titles, seed data, the PyJWT line in `requirements/base.txt` | `backend/edit_strings.py`, which holds the full list |
| Replaced, unchanged from upstream's `preview`: `plane/utils/email.py` | `backend/vendor/email.py`, with its commit and sha256 in `backend/vendor/email.py.pin` |
| Logo | `plane/static/logos/Logo.png`, from `backend/assets/Logo.png` |
| Flattened: the derived filesystem is copied into an empty image, and the base image's config is restated by hand | `runtime/Dockerfile.backend`, checked by `checks/flatten-config.py` |

The Docker context holds only these templates and `wayline/`. Upstream's other templates come from the base image, through that copy.

### Dependencies replaced in images (`backend/pyjwt-requirements.txt`, `runtime/space-deps.mjs`)

All of these arrive through the `FROM` lines, and were CRITICAL findings with a fix in `scripts/ci/scan-images.sh`.

| Image | Package | Change | How |
|---|---|---|---|
| `wayline/backend` | PyJWT | 2.13.0 to 2.14.0, CVE-2026-102268 | `pip install --no-deps --require-hashes --only-binary=:all:`. Nothing else changes: no installed package requires PyJWT, and `pip check` passes |
| `wayline/space` | proxy-addr | 2.0.7 to 2.0.8, CVE-2026-90711 | Tarball checked against the npm registry's `integrity`, installed beside the old store entry, and express's link repointed. Same dependencies |
| `wayline/space` | storybook 10.4.6, tinypool 2.1.0 | Removed, CVE-2026-114125, CVE-2026-104848, CVE-2026-104849 | Development tools. `runtime/space-deps.mjs` refuses to remove them if the server bundle or anything it reaches can import them |

The backend image is flattened, so PyJWT 2.13.0 is in none of its layers. The space image is not flattened, so there these replace or remove files in the container's filesystem only, and the old versions are still bytes in the `FROM` layers underneath. Other development packages in the space image, such as the rest of `@storybook/*`, `vite`, `typescript`, `brace-expansion`, `toml` and `webpack-dev-middleware`, are left for now, because no CRITICAL finding names them and this change stays small. `vite` does have HIGH and MEDIUM findings, and so does `brace-expansion`. `toml` and `webpack-dev-middleware` have HIGH findings.

The space image has other HIGH findings, left as they are. Some are in packages its server loads from `node_modules`: axios, body-parser, compression, follow-redirects and react-router. Others are in code the bundler inlined into `build/server/index.js`, where nothing imports it, so `runtime/space-deps.mjs` cannot see it: markdown-it 14.2.0, nanoid 3.3.8, prosemirror-view 1.40.0 and source-map-js 1.2.1, with a MEDIUM in @tiptap/core 2.26.3. `checks/space-regions.mjs` lists what was inlined. The rest are in the development packages above, which the server does not load: vite 8.0.16, brace-expansion 5.0.7, toml 4.3.0 and webpack-dev-middleware 6.1.3. The web and admin client bundles hold some of these libraries too, and no image scan can see them there. Nobody has checked whether any of these findings can be reached in a way that matters.

Left on purpose: `plane` module and `X-Plane-*` headers, the "New at Plane" choice label in
`db/models/workspace.py`, because changing it would call for a migration, and the GitHub releases check in
`register_instance.py`. Databases that already exist keep their stored instance name, bot name, telemetry flag,
demo content and activity rows.

### Runtime and build (`runtime/`, `scripts/`, `checks/`)

New files, not derived from upstream except as stated: thin Dockerfiles, `runtime/nginx-{web,admin}.conf` (modified
from `apps/{web,admin}/nginx/nginx.conf`: pid on `/run`, two workers, no rate-limit zone, `Cache-Control` by status and file name, no byte ranges, relative redirects, `/source` on web), the build
and authoring scripts, and the checks. Upstream's own Dockerfiles are not used.

## Preserved

`LICENSE.txt`, `COPYRIGHT.txt`, and every SPDX and copyright line in upstream's files are untouched. Modified files
keep their original header. The one file replaced whole by a later upstream version, `plane/utils/email.py`, carries that
version's own header, unedited. New source files carry an AGPL-3.0-only header. The exceptions are files that cannot or
should not carry one: JSON manifests and other generated or plain data (`overlay.lock`, `images.txt`, `UPSTREAM`, `backend/email-py-decision.txt`, `backend/pyjwt-requirements.txt`, `backend/vendor/email.py.pin`), binaries, the
fonts' `SOURCES.txt`, and third-party licence texts. Every image carries the licence texts in
`/usr/share/licenses/wayline/`.

## D12: the one file with a commercial license header

`apps/api/plane/utils/email.py` in upstream's v1.4.3 tag, 42 lines, one function that strips tags from an HTML email,
is headed with an SPDX `LicenseRef` identifier naming Plane's commercial license, and "Proprietary and confidential". It
is the only such file in that tag, and every email task imports it. Upstream relicensed it on its `preview` branch: commit
`3e44777e6c` (#9865) made it AGPL-3.0-only, and `297c3fdf2a` (#9841) and `86d9b158fa` (#10053, a security fix) changed the code.

**What is done.** The notice is not edited. The backend image replaces the file with upstream's own AGPL-3.0-only version,
pinned by commit, and the image is flattened, so what is published holds that version and no layer holds the original.

**Who chose this.** No person did. An AI coding agent implementing this image chose to replace the file, under the
owner's rule: "Do not use commercial-only Plane features or assets without authorization." The agent coordinating the work then required
the flattening, under the same rule. The agent coordinating the work also removed the requirement that the repository be private,
because no layer holds the original, and the owner has not reviewed that.

**What the owner has and has not seen.** The agent told the owner after the fact that the file was replaced. The owner has not reviewed
that choice or the flattening, and has not authorized the original file. No lawyer or other legal reviewer has looked at
any of this, so this section records what was done and is not a legal claim either way.

**What the owner should confirm**, before the first push that carries this directory, because that push publishes:

- [ ] This section, all of it: the file replaced, the image flattened, and publishing with no requirement that the repository be private.

- `backend/vendor/email.py` is upstream's file at `86d9b158fa4edd0c5deebb29367b5dd9b821716f`, the newest commit that touches it,
  unchanged. `backend/vendor/email.py.pin` records the commit, blob and sha256. It fits v1.4.3: 11 modules import from it,
  all import only `generate_plain_text_from_html`, and every call passes one argument.
- `runtime/Dockerfile.backend` copies it over the original in its first stage. `backend/check_image.py --build-time` then stops the image
  build if any file in that stage's filesystem holds the identifier, or if this file is not that AGPL-3.0-only version.
- The last stage is `FROM scratch` and copies that filesystem, so the published image has one layer holding it, and an empty
  layer BuildKit adds for `WORKDIR`. `checks/flatten-compare.py` compared this copy with the unflattened image, path by path.
- `checks/layer-check.py` reads every layer of each image we build as a registry serves it, opening archives by their first
  bytes, and fails if any holds the identifier in any case or in UTF-16, the original's sha256, or bytecode at its path.
  `scripts/ci/build-images.sh` runs it in a throwaway registry before publishing anything, and again on what it published, and
  records no digest for an image that fails.
- **Upstream's image is still a build input.** The build downloads `makeplane/plane-backend:v1.4.3` from Docker Hub as a
  local input to derive this image. It is not republished, and the published image holds no layer from it. This says no more
  than that, and does not say anything is legally cleared.
- `backend/email-py-decision.txt` names this decision. `scripts/publish-gate.sh` then allows only the local registry and
  `ghcr.io/bereketabera/wayline`, and fails for anything else. A new value there, or another registry, needs a change to that script.
- The `live` service keeps upstream's image, unmodified. Its layers hold no such identifier, read at the digest this
  platform pins: `docs/evidence/branding/layer-check-deployed.txt`.

Moving to an upstream release that carries the AGPL header would end the need for the replacement and the flattening.
