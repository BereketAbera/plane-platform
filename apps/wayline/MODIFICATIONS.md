# Modifications to Plane Community Edition v1.4.3

The AGPL section 5 notice of what this directory changes. [`NOTICE.md`](../../NOTICE.md) has the short
form and the license statement.

- **Upstream:** <https://github.com/makeplane/plane>, tag `v1.4.3`, commit
  `37a15d99231042b3ff5a4401fed479fdbec9effe`. Copyright 2023-present Plane Software, Inc. and contributors.
  AGPL-3.0.
- **Modified by:** Bereket Abera, 2026-11-04 to 2026-11-05.
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
| Telemetry starts off: the god-mode setup form starts unticked, and instance registration writes `is_telemetry_enabled=False`. The setting stays available. The model default is unchanged | `patches/40-admin.patch`, `backend/edit_strings.py` |
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
| Sign-up keeps sending `has_marketing_email_consent`, as upstream does, with its upstream default of true | not changed, recorded here because the label changed |

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

Measured with `git apply --numstat` on 2026-11-05: 85 files, +310 -499, 139 hunks, about 110 KB.

| Patch | Files | Lines | Scope |
|---|---|---|---|
| `00-brand-import` | 1 | +1 -0 | One `@import` in `packages/tailwind-config/index.css` |
| `01-fonts` | 3 | +3 -31 | `apps/{web,admin,space}/app/root.tsx`: stops loading Inter and IBM Plex Mono, ink `theme-color` |
| `10-shell` | 20 | +43 -32 | `apps/web`: full-bleed content (`workspace/content-wrapper.tsx`, `(projects)/layout.tsx`, `settings/profile/layout.tsx`), shell attributes (`navigation/top-navigation-root.tsx`, `sidebar/*`, the three settings sidebars), active item hooks, section label classes, metadata hooks |
| `20-auth` | 17 | +91 -155 | `apps/web`: split sign-in (`auth-screens/*`, `account/auth-forms/*`, `accounts/*/page.tsx`, `instance/not-ready-view.tsx`, `onboarding/*`, `create-workspace`, `invitations`), customer logos removed, terms text |
| `30-surfaces` | 21 | +74 -178 | `apps/web`, `packages/constants`: help menu, error and maintenance pages, product updates, badges, active cycles, billing, theme swatches, reserved slugs, chart colours |
| `40-admin` | 13 | +49 -42 | `apps/admin`: split sign-in, shell, help section, setup and general forms, failure view |
| `50-space` | 10 | +49 -61 | `apps/space`: split sign-in, ink band, source badge, terms text, error and failure views |

### Backend image (`backend/`, `runtime/Dockerfile.backend`)

Derived from `makeplane/plane-backend:v1.4.3` by digest, and shared by api, worker, beat and migrator.

| Group | Files |
|---|---|
| Email templates, rewritten: 12, plus new `_wayline_base.html` | `backend/templates/emails/**` |
| Scripted string edits, each with an exact match count: email subjects, bot name, activity text, default instance name, default sender, API error text, OpenAPI metadata, admin titles, seed data | `backend/edit_strings.py`, which holds the full list |
| Logo | `plane/static/logos/Logo.png`, from `backend/assets/Logo.png` |

The Docker context holds only these templates and `wayline/`. Upstream's other templates come from the base image.

Left on purpose: `plane` module and `X-Plane-*` headers, the "New at Plane" choice label in
`db/models/workspace.py`, because changing it would call for a migration, and the GitHub releases check in
`register_instance.py`. Databases that already exist keep their stored instance name, bot name, telemetry flag,
demo content and activity rows.

### Runtime and build (`runtime/`, `scripts/`, `checks/`)

New files, not derived from upstream except as stated: thin Dockerfiles, `runtime/nginx-{web,admin}.conf` (modified
from `apps/{web,admin}/nginx/nginx.conf`: pid on `/run`, two workers, no rate-limit zone, `/source` on web), the build
and authoring scripts, and the checks. Upstream's own Dockerfiles are not used.

## Preserved

`LICENSE.txt`, `COPYRIGHT.txt`, and every SPDX and copyright line in upstream's files are untouched. Modified files
keep their original header. New source files carry an AGPL-3.0-only header. The exceptions are files that cannot or
should not carry one: JSON manifests and other generated data (`overlay.lock`, `images.txt`, `UPSTREAM`), binaries, the
fonts' `SOURCES.txt`, and third-party licence texts. Every image carries the licence texts in
`/usr/share/licenses/wayline/`.

## Open item: one file with a commercial license header

`apps/api/plane/utils/email.py` in upstream's v1.4.3 tag, 42 lines, one function that strips tags from an HTML email,
is headed `SPDX-License-Identifier: LicenseRef-Plane-Commercial` and "Proprietary and confidential". It is the only
such file in that tag. Upstream publishes it in the same tag and in its public `plane-backend` image, and every email
task imports it. Wayline inherits it from that image and does not change it. Whether that header or the repository's
AGPL `LICENSE.txt` governs it is a question for the owner, ideally with counsel, before the image or source is
conveyed to anyone. This is not a claim either way.

Decision D12 in `PASS2_HANDOFF.md`, not yet made. The options are upstream's PR #9865 change as a named patch, a release
carrying that fix, or leaving it with sign-off. Until then:

- The backend image's license label reads `AGPL-3.0-only AND LicenseRef-Plane-Commercial`.
- `backend/email-py-decision.txt` says `pending`, so `scripts/ci/build-images.sh` refuses any registry but the local one,
  and the `publish` job in `images.yml` stops before GHCR with a warning.
