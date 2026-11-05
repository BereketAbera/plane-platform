# Notice

This repository contains a modified version of **Plane Community Edition v1.4.3**, the open-source
project management software by Plane Software, Inc. and contributors, licensed under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.txt) (AGPL-3.0-only).

- **Upstream:** <https://github.com/makeplane/plane>, tag `v1.4.3`, commit
  `37a15d99231042b3ff5a4401fed479fdbec9effe`.
- **Modified by:** AI coding agents, under the name of this repository's owner, Bereket Abera (the owner, below), from
  2026-11-04. His name on the work does not mean he reviewed each change.
  [`apps/wayline/MODIFICATIONS.md`](apps/wayline/MODIFICATIONS.md) is the dated, per-file-group record.
- **Modified version's name:** Wayline. It is a customized Plane Community Edition deployment, not an
  original product. "Plane" and its logos belong to their owners, and nothing here implies endorsement.
- **License of the modifications:** AGPL-3.0-only, the same as upstream.
- **Source:** <https://github.com/BereketAbera/plane-platform>. Every running web image also answers
  `/source` with a redirect to the repository at the commit that built it (AGPL section 13).
  The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an instance.
- **Licence texts:** every image carries `LICENSE`, `COPYRIGHT.txt`, this notice, the record of changes and the font
  licences in `/usr/share/licenses/wayline/`, and the web image serves the same files at `/licenses/`.

## What changed from upstream

All changes live in [`apps/wayline/`](apps/wayline/) and are applied to the pinned upstream source at
build time. Application functionality is unchanged except where listed.

| Change | Where |
|---|---|
| Visual identity: colours, type, radii, shadows, shell, sign-in layout, logos, images | `overlay/`, `patches/` |
| Fonts added: Instrument Sans and JetBrains Mono (SIL OFL 1.1, licenses alongside the files) | `overlay/packages/tailwind-config/fonts/` |
| Fonts no longer loaded: Inter and IBM Plex Mono | `patches/01-fonts.patch` |
| Product name in UI text, translations, manifests and page titles | `codemod/rebrand.mjs`, run at build time |
| Links to upstream's marketing, legal, support and community pages removed or pointed at `/source` | `codemod/rebrand.mjs`, `patches/` |
| Upstream's customer logos and most paid-plan prompts removed | `patches/` |
| Telemetry starts off in the setup form, at instance registration and when the setup request omits it, for a new instance only: one registered earlier by upstream's image keeps its stored setting. Marketing consent starts off in onboarding | `patches/40-admin.patch`, `patches/20-auth.patch`, `backend/edit_strings.py` |
| `plane/utils/email.py` replaced with upstream's later AGPL-3.0-only version, unchanged, and the backend image flattened, so none of its layers holds the original | `backend/vendor/email.py`, `runtime/Dockerfile.backend` |
| Dependencies with known critical vulnerabilities replaced or removed: PyJWT, proxy-addr, storybook, tinypool | `backend/pyjwt-requirements.txt`, `runtime/space-deps.mjs` |
| Billing settings refused for every role, and the page for a paid feature (active cycles across projects) replaced with a plain statement | `patches/30-surfaces.patch` |
| Email templates and subjects, seed data, bot name, default sender and API metadata rebranded | `backend/`, `runtime/Dockerfile.backend` |
| Container images: thin runtime images instead of upstream's Dockerfiles, fitted to non-root UIDs. Web and admin tell browsers to revalidate everything without a content hash in its name, and every error. They serve no byte ranges | `runtime/` |

## What is preserved

- Upstream's licence, as `LICENSE`, and `COPYRIGHT.txt`, verbatim at this repository's root. Every SPDX and copyright
  header line in source files. The build's text rewrite skips those lines by rule, and modified files keep their
  original header.
- Functional identifiers: `@plane/*` packages, the `plane` Python module, `X-Plane-*` headers.
- Only upstream's public Community Edition tag and images are used, and license gates are neither unlocked
  nor bypassed. One file in that tag, `plane/utils/email.py`, carries a commercial license header. The backend image
  replaces it with upstream's own later AGPL-3.0-only version and is flattened, so no layer of the published image holds the original.
  The build still downloads upstream's image from Docker Hub as a local input, and does not republish it. An AI coding agent chose this, not a
  person. The owner has not reviewed it, and no legal review has happened. See D12 in `apps/wayline/MODIFICATIONS.md`.

## Third-party notices

- Instrument Sans, Copyright 2022 The Instrument Sans Project Authors, SIL OFL 1.1.
- JetBrains Mono, Copyright 2020 The JetBrains Mono Project Authors, SIL OFL 1.1.

The Wayline wordmark uses outlines from Instrument Sans.
