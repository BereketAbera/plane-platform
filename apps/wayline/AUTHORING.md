# Authoring Wayline changes

All branding lives in this directory. Upstream's clone and `.build/` are never committed.

## The commands

```sh
apps/wayline/scripts/patchwork.sh                       # create .build/plane-patchwork (reuses it if present)
# edit files in .build/plane-patchwork
apps/wayline/scripts/save-patch.sh 20-shell path/one "apps/web/app/(all)/[workspaceSlug]/layout.tsx"
apps/wayline/scripts/sync-overlay.sh                    # after editing apps/wayline/overlay, to see it in the patchwork
apps/wayline/scripts/apply.sh                           # fresh tree in .build/plane-src, stops on a failed hunk
apps/wayline/scripts/build.sh                           # the real build, serialized by a lock
```

To inspect your work: `git -C .build/plane-patchwork diff wayline-base -- <your paths>`. To undo a file:
`git -C .build/plane-patchwork show wayline-base:<path> > .build/plane-patchwork/<path>`, then save the patch again.

## Sharing the tree: disjoint paths only

Several authors use one patchwork at once, **without a lock**. That is safe under one rule: **only touch
paths you own, and in the shared repo only run `diff` and `add -N` on your own paths.**

- `save-patch.sh` works in a private temporary index, so it never contends for `.git/index`.
- Never run `git add`, `git commit`, `git checkout`, `git stash`, `git reset` or `git clean` in the
  patchwork, or `patchwork.sh --reset`. They would disturb everyone else's unsaved edits.
- A file belongs to exactly one patch. `save-patch.sh` refuses a file another patch already holds, and refuses
  overlay files. If you need a file someone else owns, ask its owner to change it.
- Save often. Your saved patch is the work; the patchwork is scratch space.
- `checks/roundtrip.sh` compares whole trees, so run it only when nobody else is authoring.

## Patches

Named `NN-area.patch`, zero-padded, lowercase, and applied in numeric order. Numbers in use:

| Patch | Area |
|---|---|
| `00-brand-import.patch` | `packages/tailwind-config/index.css`, the one-line import |
| `01-fonts.patch` | The three `apps/*/app/root.tsx`: drops Inter and IBM Plex Mono imports and the preload |
| `10-shell.patch` | Full-bleed content, ink shell hooks, active nav hooks, top bar removals |
| `20-auth.patch` | Split-screen sign-in, sign-up, password and onboarding, auth footer, terms text |
| `30-surfaces.patch` | Help menu, error page, product updates, edition and upgrade badges, billing page |
| `40-admin.patch` | God-mode: split sign-in, shell, source link, telemetry default off |
| `50-space.patch` | Public pages: split sign-in, ink band, source badge, terms text |

New work takes a free number in the area it belongs to, for example `35-` for another surfaces patch.

Patches apply **before** the codemod, so write them against upstream's text. Do not write "Wayline" into a patch to
fix a string the codemod already handles. `"Built on Plane Community Edition"` is protected, so the codemod leaves
it alone and the leak scan allows it. Any other "Plane" in a patch becomes "Wayline".

Keep patches small. Never touch a copyright or SPDX line. New source files carry the AGPL-3.0-only SPDX header.
Functional identifiers stay: `@plane/*`, the `plane` module, `X-Plane-*`.

## Who owns which CSS

`overlay/packages/tailwind-config/brand.css` imports these, in this order:

| File | Scope | Owner |
|---|---|---|
| `brand/tokens.css` | Palette in four themes, fonts, radii, shadows, type scale, focus, `[data-shell]` tokens | Foundation |
| `brand/shell.css` | Sidebar, top band, active nav route line, full-bleed content | Shell agent |
| `brand/auth.css` | Split-screen sign-in, route-over-contour side | Auth agent |
| `brand/admin.css` | God-mode | Admin agent |
| `brand/space.css` | Public pages | Space agent |

Edit overlay files in `apps/wayline/overlay`, then run `sync-overlay.sh`. Overlay paths are never patched.
Our own tokens use the `--wl-` prefix. Every other token name must exist upstream, or `checks/token-diff.mjs` fails.
In `tokens.css`, a token set in the light block must also be set in dark. Run `checks/contrast.mjs` after a
colour change.

## Scoped tokens beat structural edits

Upstream's utilities resolve straight to variables, as in `.bg-surface-1{background-color:var(--bg-surface-1)}`.
So **redefining a token on an element re-themes its whole subtree.** Reach for that first:

```css
[data-shell] { --bg-surface-1: var(--wl-ink-800); --txt-primary: var(--wl-ink-text); }
```

`[data-shell]` is already defined in `tokens.css`: any element with a `data-shell` attribute goes ink, in every
theme, with contrast checked. A patch that adds `data-shell="nav"` is one attribute, and the rest is CSS. A
structural patch is a last resort, because each one is a future conflict.

The ink values are `--wl-ink-900` to `--wl-ink-400`, `--wl-ink-text`, `--wl-ink-text-muted`, `--wl-ink-text-faint`,
`--wl-ink-accent` and `--wl-ink-accent-text`. The logo route colour is `--wl-logo-route`.

## Layers: no !important

Tailwind's CSS is `@layer properties, theme, base, components, utilities`. **Unlayered rules beat all of it
without `!important`**, so write component rules unlayered in your brand file. Only `@theme` values and the
palette need the layered form they already have in `tokens.css`. Shadows are inlined at compile time, so change
them in `@theme`, not at runtime. Portalled dropdowns keep the page theme, not the scoped one, which is usually right.
