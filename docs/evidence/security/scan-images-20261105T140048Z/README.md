# Complete scan of everything the platform runs, on the final images

Command: `SCAN_MIN_FREE_GIB=10 SCAN_FLOOR_GIB=6 make scan-images`, at `f30a7f5`, from 2026-11-05T14:00:48Z to about 14:10Z, with trivy 0.76.1 and the database in `trivy-version.txt`, updated 2026-11-04T19:02Z. The limits are below the script's default of 15 because the host had 16 GiB free and other checks were running beside it. Exit 0: all 31 targets were scanned, and no image built here has a CRITICAL finding with a fix.

| Scope | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN |
|---|---|---|---|---|---|
| All 31 targets | 15 | 515 | 768 | 378 | 120 |
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 | 0 |
| `wayline/backend`, flattened | 0 | 4 | 11 | 2 | 0 |
| `wayline/space` | 0 | 30 | 22 | 5 | 0 |

**The policy passed. The findings did not go away.** The policy fails only on an image built here with a fixable CRITICAL finding, or on an image it could not scan. Everything else is reported.

Five upstream images have a CRITICAL finding with a fix, so a newer version may help. `critical.tsv` lists every CRITICAL finding:

- `postgres:15.19-alpine` and `postgres:16.15-alpine`: CVE-2025-68121, in Go's `stdlib` inside `gosu`.
- `rabbitmq:3.13.7-management-alpine`: CVE-2026-31789, in `libcrypto3` and `libssl3`.
- `makeplane/plane-live:v1.4.3`: CVE-2026-90711 in `proxy-addr`, CVE-2026-114125 in `storybook`, and CVE-2026-104848 and CVE-2026-104849 in `tinypool`.
- `argocd:v3.5.7`: CVE-2025-68121, in Go's `stdlib`, inside `git-lfs` and `kustomize`.

`infisical:v0.167.6` has 5 CRITICAL findings with no fix available. `redis:7.2.17-alpine` is on an end-of-life Alpine, where trivy warns that its OS findings may be incomplete.

## What this does not say

- **This run has no lockfile row.** The script scans the lockfiles of the Wayline source only when `.build/plane-src` exists, and it did not exist here. So 31 targets is the images alone, against 36 on 2026-11-04, which held 35 images and that row. The last read of those lockfiles on this Mac is in `scan-images-20261105T052024Z`, on the same frontends: 1 CRITICAL with a fix, which the policy does not fail. A runner read them at 14:28Z, in run 42044273310 of `images.yml`, with the same counts, and only the table in its log remains ([log](../../ci/ci-4-20261105T142148Z-run-42044273310.log)).
- The zeros for web and admin cover OS packages only. `scan.log` has `Number of language-specific files num=0` for those two images, because their clients are bundled static files with no package metadata.
- A finding means a package version is listed as affected. Nobody has checked whether any of them can be reached in this platform.
- Local services outside the cluster manifests were not scanned: the `distribution` registry, `plane-git` and the kind node.

## Edits

Eight occurrences in `images/*.json` became `<redacted>`, seven of them flagged by gitleaks and one the same string beside them: the CPython release key fingerprint in `GPG_KEY`, in the python and backend images, and the `POSTHOG_API_KEY` in the public Infisical image's configuration. None is a secret of this platform. ANSI colour codes were stripped from `run.log`. Everything else is byte for byte.
