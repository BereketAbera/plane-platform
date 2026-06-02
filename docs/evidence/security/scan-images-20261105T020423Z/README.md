# Scan of the final Wayline images, from commit ec45e21

Command: `SCAN_ONLY=built SCAN_MIN_FREE_GIB=11 SCAN_FLOOR_GIB=10 SCAN_OUTPUT_DIR=<a scratch directory> scripts/ci/scan-images.sh`, on 2026-11-05, with trivy 0.76.1 and the
vulnerability database in `trivy-version.txt`. The limits are below the script's default of 15 because the host had 12 GiB free. Exit 0: every target was scanned, and no image built here has a CRITICAL finding with a fix.

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 |
| `wayline/backend`, flattened | 0 | 4, in Django and djangorestframework | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

**The zeros for web and admin cover OS packages only.** `scan.log` has `Number of language-specific files num=0` for those two images. Their clients are bundled static files with no package metadata, and those bundles contain
libraries with findings. The lockfile row is the only view of them.

The space image also has code inlined into its server bundle, which neither this scan nor the closure in `runtime/space-deps.mjs` attributes to the bundle: `docs/evidence/branding/space-deps.txt`, sections 6 and 7.

The findings in the backend and space are the same as in `scan-images-20261104T235800Z`: 17 and 57, none added and none gone. Flattening changed the backend's reported OS from `alpine 3.23.3` to `alpine 3.23.7`. `/etc/alpine-release` says 3.23.7 in both images, so the
layered image read older.

The old package versions are in no layer of the backend now, because it is flattened. They are still bytes in the `FROM` layers of the space image, which an image scan does not report.

## Edits

Three strings in the backend's JSON became `<redacted>`, the public fingerprint of CPython's release key in `GPG_KEY`, because gitleaks reads it as a credential. ANSI colour codes were stripped from `run.log`, and scratch paths became `<scratch>`. Everything else is byte for byte.
