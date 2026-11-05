# Scan of the Wayline images from commit b2ba587

Command: `SCAN_ONLY=built SCAN_MIN_FREE_GIB=11 SCAN_FLOOR_GIB=10 SCAN_OUTPUT_DIR=<a scratch directory> scripts/ci/scan-images.sh`, on 2026-11-05, with trivy 0.76.1 and the
vulnerability database in `trivy-version.txt`. The limits are below the script's default of 15 because the host had 13 GiB free. Exit 0: every target was scanned, and no image built here has a CRITICAL finding with a fix.

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 |
| `wayline/backend`, flattened | 0 | 4, in Django and djangorestframework | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

**The zeros for web and admin cover OS packages only.** `scan.log` has `Number of language-specific files num=0` for those two images. Their clients are bundled static files with no package metadata, and those bundles contain
libraries with findings. The lockfile row is the only view of them.

The space image also has code inlined into its server bundle, which neither this scan nor the closure in `runtime/space-deps.mjs` attributes to the bundle: `docs/evidence/branding/space-deps.txt`, sections 6 and 7. `docs/evidence/branding/space-high.txt` lists every HIGH finding in this scan by package.

The findings are the same as in `scan-images-20261105T020423Z`, on the same vulnerability database, none added and none gone: web 0, admin 0, space 57, backend 17 and the lockfiles 63. 63 is what trivy reports and what the table adds up to. 62 of them are distinct, because `@tiptap/core` 2.26.3's GHSA-cp6q-959q-f8rh is listed for each of its two entries in `pnpm-lock.yaml`. Between those two scans only the licence texts and the nginx configs changed.

The old package versions are in no layer of the backend, because it is flattened. They are still bytes in the `FROM` layers of the space image, which an image scan does not report.

## Edits

Three strings in the backend's JSON became `<redacted>`, the public fingerprint of CPython's release key in `GPG_KEY`, because gitleaks reads it as a credential. ANSI colour codes were stripped from `run.log`, and scratch paths became `<scratch>`. Everything else is byte for byte.
