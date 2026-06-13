# Wayline assets

`generate.mjs` draws every image and web manifest into `../overlay` at upstream's file names and, apart from the
spinners and `auth/unauthorized.svg`, upstream's pixel dimensions, so no application code changes. The outputs are committed, so a build needs none of the tools
below. Only regenerating does.

```sh
node apps/wayline/assets/generate.mjs                     # needs rsvg-convert, cwebp, dwebp, ffmpeg
node apps/wayline/assets/generate.mjs --only cycle        # just the paths containing "cycle"
node apps/wayline/assets/generate.mjs --verify --against <upstream checkout>   # needs only Node. apply.sh runs it on every build
node apps/wayline/assets/generate-contours.mjs            # the sign-in chart, one copy per app. Needs only Node
node apps/wayline/assets/generate-empty-states.mjs        # propel's empty-state registry. Needs only Node
```

To check that the committed overlay still matches its generators, run the first command and then
`git status --short apps/wayline/overlay`, which should list nothing. That last held on 2026-11-05 with rsvg-convert 2.62.3,
cwebp 1.6.0 and ffmpeg 9.0.1. Other encoder versions may change bytes. No CI step runs this, because CI has no reason
to install encoders.

The images still draw the route in `#B0186E`, the brief's value. The token moved to `#9F1265` for contrast, and the
difference does not justify re-encoding 143 files. `lib/chart.mjs` is the place to change it if it ever does.

A full run also writes a contact sheet of the encoded outputs to `.local/evidence-raw/wayline-assets-sheet.png`.
Drawings are seeded from their path, so a run reproduces the same pictures.

| Path | What it is |
|---|---|
| `generate.mjs` | The list of outputs, the compositions, encoders, manifests, verification, contact sheet |
| `lib/chart.mjs` | Palettes, seeded contours, neatline, graticule, north arrow, scale bar |
| `lib/motifs.mjs` | One chart symbol per topic |
| `masters/` | Logo masters and spinner source, read and not changed by this script |

## The system

Illustrations use real chart ideas, so a topic is recognisable rather than a recoloured copy. They contain no
words and no figures, so they claim nothing and need no translation. The only lettering in any image is the
wordmark from the logo masters.

| Topic | Symbol |
|---|---|
| Cycles | Holding pattern around a fix |
| Modules | Airspace sectors handed along a route |
| Views | Stacked frames with crop marks |
| Pages | Chart sheet with a ruled route |
| Work items | Log of waypoints, one to a row |
| Intake | Arrivals merging on one fix |
| Analytics | Terrain profile with the route above it |
| Search | Range rings with a bearing |
| Stickies | Annotations pinned along a route |
| Projects | Folded chart |
| Priority, progress, burn-down | Flight levels, position on route, flown against planned |
| No access | Restricted airspace, hatched on the inside, with the route going around it |
| Not found | Expanding-square search |
| Maintenance | Charted obstruction with its light, and the route around it |
| Failure | A leg that stops at a failed waypoint |
| API token, webhook | Key made of the logo's ring and route, radio beacon |

Three treatments, chosen by how upstream uses the slot:

- **Plate** for large images: opaque, with neatline, contours, graticule, north arrow and scale bar. Light and
  dark use Chart and Night Ops.
- **Symbol** for small slots: transparent, in Chart and Night Ops.
- **Neutral symbol** where upstream ships one file for both themes. A mid-tone palette, which reads on paper
  and on ink.

The tour images (`onboarding/*`) are one file in both themes, so they are Night Ops plates, matching the shell.

Icons put the logo on an ink tile, the shell's colour, so they hold up on light and dark browser chrome. The
spinner is 88x88 rather than upstream's 553x306, because its slot sets only the height (`h-6 sm:h-11 w-auto`). Its
edges are composited over the theme's canvas before the outside is keyed to transparent, since GIF has no partial
alpha.

## Replaced but not imported by any code

These do not ship, because Vite only emits what is imported, but they carry upstream's marks, so they are replaced
anyway: `plane-takeoff.png` (3 apps), `plane-logos/*` under `app/assets` (web, space), `plane-logo.svg`,
`instance-not-ready.webp`, `plane-instance-not-ready.webp`, `instance-setup-done.webp`, `intake-sent-*.png`,
`project-not-published.svg`, `auth/access-denied.svg`, web's `auth/background-pattern*.svg`, web's
`favicon/apple-touch-icon.png`. `packages/propel/public/plane-lockup-light.svg` is Storybook only.

## Left alone on purpose

`generate.mjs --against` reads this table: an image imported by shipping code must be generated or listed here.

| Path | Why it is left alone |
|---|---|
| `apps/web/app/assets/attachment/` | File-type icons (PDF, CSV and so on). They identify a format, not a product, and carry no upstream mark |
| `apps/web/app/assets/cover-images/` | Stock photographs offered as project covers. User-selectable content. All 29 viewed: no upstream mark or UI |
| `apps/*/app/assets/logos/gitea-logo.svg` | Third-party sign-in provider, identifies that service |
| `apps/*/app/assets/logos/github-` | Third-party sign-in provider, identifies that service |
| `apps/*/app/assets/logos/gitlab-logo.svg` | Third-party sign-in provider, identifies that service |
| `apps/*/app/assets/logos/google-logo.svg` | Third-party sign-in provider, identifies that service |
| `apps/web/app/assets/services/` | Third-party integrations (GitHub, Slack, and format icons), identify those services |
| `apps/web/app/assets/user.png` | Generic silhouette, the fallback avatar. No brand in it |
| `apps/web/app/assets/scribble/` | A decorative underline in the licence modal. No brand in it. It goes if that modal does |

Not imported by any code, so they do not ship and were not replaced: the other 256 files under
`apps/web/app/assets/empty-state/` (some of them are screenshots of upstream's UI), `users/user-profile-cover-default-img.png` (a photograph of an airliner, no code refers to it),
`users/user-*.png`, `mac-command.svg`, `emoji/project-emoji.svg`.

Not replaced because nothing can fix it from here: `apps/web/core/components/estimates/empty-screen.tsx` asks for
`/empty-state/project-settings/estimates-*.png` under `public/`, where upstream ships no such file. It is a broken
image upstream too, and adding one would be a behaviour change.

## Licence

The generator and its outputs are AGPL-3.0-only, like the rest of this directory. Generated SVGs carry the notice in
a comment. PNG, WebP, GIF and ICO files cannot carry it, and this file states it for them. The wordmark outlines come
from Instrument Sans (OFL-1.1), as noted in the masters.
