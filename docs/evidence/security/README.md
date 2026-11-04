# Image scan evidence

Raw results of `scripts/ci/scan-images.sh`, captured on 2026-11-04 UTC with trivy 0.76.1 and a vulnerability database
updated 2026-11-04T19:02Z. Each image was read from its registry for linux/arm64, and nothing was loaded into Docker.

## Runs

| Directory | Command | Disk limits | Scanned | Exit | Result |
|---|---|---|---|---|---|
| `scan-images-20261104T213712Z` | `SCAN_OUTPUT_DIR=<that directory> scripts/ci/scan-images.sh`, before the code was committed | 15 GiB to start, 15 GiB floor | 2 of 35 images | 1 | FAIL. It stopped when the host fell below 15 GiB free, so 33 images are listed as not scanned |
| `scan-images-20261104T215437Z` | `make scan-images SCAN_MIN_FREE_GIB=13 SCAN_FLOOR_GIB=12` at 06c8dca | 13 GiB to start, 12 GiB floor | 36 of 36 targets: 35 images and the Wayline source lockfiles | 1, which `make` reports as 2 | FAIL on the policy: 5 CRITICAL findings with a fix, in 2 images we build |
| `scan-images-20261104T233230Z` | `SCAN_ONLY=built SCAN_MIN_FREE_GIB=12 SCAN_OUTPUT_DIR=<a scratch directory> scripts/ci/scan-images.sh`, on the images built from 8e328a0, with the same database | 12 GiB to start, 12 GiB floor | 5 of 5 targets: the 4 images built here and the Wayline source lockfiles | 0 | PASS: no image we build has a CRITICAL finding with a fix |

The limits changed between the two runs. The Docker VM was growing while agents deployed, and the coordinator set 13 and 12 GiB for
the second run because each image's temp space comes back after that image. The script's defaults stayed at 15 GiB. The lowest
free space sampled during the second run was about 13 GiB. It was sampled by hand every few minutes, not continuously.

Across all targets in the complete run: 26 CRITICAL, 600 HIGH, 837 MEDIUM, 392 LOW, 122 UNKNOWN. `run.log` has the table by image.

## The policy

The script exits 1 if an image we build, under `.../wayline/`, has a CRITICAL finding with a fix available, or if a target could
not be scanned. Everything else is reported and does not fail. An upstream image can only be fixed upstream, so its findings would
hold CI red over something no commit here can change. `.trivyignore` is not read, and nothing is left out of the JSON.

## What failed the complete run

| Image | Finding | Package | Installed | Fixed in |
|---|---|---|---|---|
| `wayline/backend` | CVE-2026-102268 | PyJWT | 2.13.0 | 2.14.0 |
| `wayline/space` | CVE-2026-90711 | proxy-addr | 2.0.7 | 2.0.8 |
| `wayline/space` | CVE-2026-114125 | storybook | 10.4.6 | 10.6.2 on that line |
| `wayline/space` | CVE-2026-104848 | tinypool | 2.1.0 | 2.1.1 |
| `wayline/space` | CVE-2026-104849 | tinypool | 2.1.0 | 2.1.2 |

All five come from the upstream images these two are built on, `makeplane/plane-backend:v1.4.3` and `makeplane/plane-space:v1.4.3`,
whose rows show the same findings. storybook and tinypool are development tools sitting in a runtime image.

Upstream images with a CRITICAL finding that has a fix, reported only: postgres 15.19 and 16.15, rabbitmq 3.13.7, plane-backend,
plane-live, plane-space, and argocd v3.5.7. `critical.tsv` lists every CRITICAL finding, with or without a fix.

## After the fixes

The run `scan-images-20261104T233230Z` covers only what is built here, so the upstream images above were not scanned again. All five findings are gone from the
two images, which are rebuilt with PyJWT 2.14.0, proxy-addr 2.0.8, and no storybook or tinypool.

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 |
| `wayline/backend` | 0 | 4, in Django 5.2.15 and djangorestframework 3.17.2 | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

The policy is unchanged. These remain, and each HIGH and MEDIUM has a fix upstream that this work did not take:

- **The CRITICAL in the lockfile row is proxy-addr 2.0.7, CVE-2026-90711, in upstream's `pnpm-lock.yaml`.** It does not ship in any bundle: its code is in none of the
  web, admin or space build output, and the space server loads it from `node_modules`, where it is now 2.0.8. `docs/evidence/branding/lockfile-critical.txt` has the
  check. Upstream's unmodified `plane-live` image, which this platform runs, still has 2.0.7 and was reported in the complete run.
- PyJWT 2.14.0 is the version the CRITICAL names. Two MEDIUM findings on it, CVE-2026-101918 and CVE-2026-102275, need 2.15.0.
- The fixes replace or remove files in the container's filesystem. The old packages are still bytes in the `FROM` layers, which an image scan does not report.

## What this does not say

- `wayline/web` and `wayline/admin` show no findings because their clients are static files with no package metadata. The row
  `wayline-source-lockfiles` is the view of those dependencies: `pnpm-lock.yaml` in the source they were built from.
- Python requirements in the source are not in that row: `apps/api/requirements.txt` only includes other files, whose names trivy does not look for. The backend image's installed packages are scanned.
- Local services outside the cluster manifests were not scanned: the `distribution` registry, `plane-git` and the kind node.
- The operator's Thanos default was left out because nothing runs it. See `policy/charts.rego`.
- A finding means a package version is listed as affected. Nobody has checked whether any of them can be reached in this platform.
- `redis:7.2.17-alpine` is on an end-of-life Alpine, where trivy warns that its OS findings may be incomplete.

## Files

Each directory holds the output of one run:

| File | What it is |
|---|---|
| `run.log` | What the command printed, with the table by image and the verdict |
| `exit-code.txt` | The exit code of that command |
| `inventory.tsv` | Every target, the sources that name it, and its result file |
| `summary.tsv` | Counts per target by severity, with how many have a fix, and the OS |
| `critical.tsv` | Every CRITICAL finding |
| `not-scanned.txt` | Each target not scanned, and why |
| `images/*.json` | Trivy's JSON for each target, run with `--list-all-pkgs=false`, so it lists findings and not every package |
| `scan.log` | What trivy printed for each target |
| `db-update.log` | The database check at the start |
| `trivy-version.txt` | Only in the later run: trivy's version and the database's date, from `trivy version` |

## Edits

Eleven strings in `images/*.json` in the complete run were replaced with `<redacted>`, as `docs/evidence/README.md` allows, because gitleaks flagged
them. None is a secret of this platform. Six are the CPython release key fingerprint in `GPG_KEY`, three are the `POSTHOG_API_KEY`
in the public Infisical image's configuration, and two are an example token in the text of a PyJWT advisory. In `scan-images-20261104T233230Z` the same was done to two strings, both that
fingerprint, and ANSI colour codes were stripped from `run.log`. Everything else is byte for byte. A later scan copied here will need the same replacements before it can be committed.
