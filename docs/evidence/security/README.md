# Image scan evidence

Raw results of `scripts/ci/scan-images.sh`, captured on 2026-11-04 and 2026-11-05 UTC with trivy 0.76.1. Every run here used the vulnerability database updated
2026-11-04T19:02Z, so none of them knows an advisory newer than that. Each image was read from its registry for linux/arm64, and nothing was loaded into Docker.

## Runs

| Directory | Command | Disk limits | Scanned | Exit | Result |
|---|---|---|---|---|---|
| `scan-images-20261104T213712Z` | `SCAN_OUTPUT_DIR=<that directory> scripts/ci/scan-images.sh`, before the code was committed | 15 GiB to start, 15 GiB floor | 2 of 35 images | 1 | FAIL. It stopped when the host fell below 15 GiB free, so 33 images are listed as not scanned |
| `scan-images-20261104T215437Z` | `make scan-images SCAN_MIN_FREE_GIB=13 SCAN_FLOOR_GIB=12` at 06c8dca. It kept its summaries and gave up its `images/*.json` in 76e98ee | 13 GiB to start, 12 GiB floor | 36 of 36 targets: 35 images and the Wayline source lockfiles | 1, which `make` reports as 2 | FAIL on the policy: 5 CRITICAL findings with a fix, in 2 images we build |
| `scan-images-20261104T235800Z` | `SCAN_ONLY=built SCAN_MIN_FREE_GIB=12 SCAN_OUTPUT_DIR=<a scratch directory> scripts/ci/scan-images.sh`, on the images built from 1563cbf, with the same database | 12 GiB to start, 12 GiB floor | 5 of 5 targets: the 4 images built here and the Wayline source lockfiles | 0 | PASS: no image we build has a CRITICAL finding with a fix |
| `scan-images-20261105T020423Z` | `SCAN_ONLY=built SCAN_MIN_FREE_GIB=11 SCAN_FLOOR_GIB=10 SCAN_OUTPUT_DIR=<a scratch directory> scripts/ci/scan-images.sh`, on the images built from ec45e21. Its [README](scan-images-20261105T020423Z/README.md) has more | 11 GiB to start, 10 GiB floor | 5 of 5 targets | 0 | PASS, with the same findings |
| `scan-images-20261105T025857Z` | The same command, on the images built from b2ba587. Its [README](scan-images-20261105T025857Z/README.md) has more | 11 GiB to start, 10 GiB floor | 5 of 5 targets | 0 | PASS, with the same findings |
| `scan-images-20261105T052024Z` | The same command, on the images built from 84b63d9, which both environments run. Its [README](scan-images-20261105T052024Z/README.md) has more | 11 GiB to start, 10 GiB floor | 5 of 5 targets | 0 | PASS, with the same findings |
| `scan-images-20261105T140048Z` | `SCAN_MIN_FREE_GIB=10 SCAN_FLOOR_GIB=6 make scan-images` at f30a7f5, on the images both environments run. Its [README](scan-images-20261105T140048Z/README.md) has more | 10 GiB to start, 6 GiB floor | 31 of 31 targets: the images alone, with no lockfile row, because `.build/plane-src` was not on disk | 0 | PASS on the policy: no image we build has a CRITICAL finding with a fix, and every target on its list was scanned. Five upstream images have one, reported only |

The limits changed between the first two runs. The Docker VM was growing while agents deployed, and the first complete run used 13 and 12 GiB,
because each image's temp space comes back after that image. The script's defaults stayed at 15 GiB. That run started with 14 GiB free,
as its `run.log` says, and scanned every target, so the script's check between images never read below 12 GiB. No other reading of free
space from that run is kept.

Across all targets in the first complete run: 26 CRITICAL, 600 HIGH, 837 MEDIUM, 392 LOW, 122 UNKNOWN. In the latest, across its 31: 15 CRITICAL, 515 HIGH, 768 MEDIUM, 378 LOW, 120 UNKNOWN. It has 5 fewer targets, because upstream's four Plane images that no longer run here were not in it, nor the lockfile row. `run.log` has the table by image in each.

## The policy

The script exits 1 if an image we build, under `.../wayline/`, has a CRITICAL finding with a fix available, or if a target could
not be scanned. Everything else is reported and does not fail. An upstream image can only be fixed upstream, so its findings would
hold CI red over something no commit here can change. `.trivyignore` is not read, and nothing is left out of the JSON.

## What failed the first complete run

| Image | Finding | Package | Installed | Fixed in |
|---|---|---|---|---|
| `wayline/backend` | CVE-2026-102268 | PyJWT | 2.13.0 | 2.14.0 |
| `wayline/space` | CVE-2026-90711 | proxy-addr | 2.0.7 | 2.0.8 |
| `wayline/space` | CVE-2026-114125 | storybook | 10.4.6 | 10.6.2 on that line |
| `wayline/space` | CVE-2026-104848 | tinypool | 2.1.0 | 2.1.1 |
| `wayline/space` | CVE-2026-104849 | tinypool | 2.1.0 | 2.1.2 |

All five come from the upstream images these two are built on, `makeplane/plane-backend:v1.4.3` and `makeplane/plane-space:v1.4.3`,
whose rows show the same findings. storybook and tinypool are development tools sitting in a runtime image.

Upstream images with a CRITICAL finding that has a fix, reported only, in that run: postgres 15.19 and 16.15, rabbitmq 3.13.7, plane-backend,
plane-live, plane-space, and argocd v3.5.7. In the latest complete run: postgres 15.19 and 16.15 in `gosu`, rabbitmq 3.13.7 in `libcrypto3` and `libssl3`, plane-live, and argocd v3.5.7 in `git-lfs` and `kustomize`. Upstream's plane-backend and plane-space are build inputs now, so that run did not scan them. `critical.tsv` lists every CRITICAL finding, with or without a fix.

## After the fixes

The four runs after the first complete one cover only what is built here, and the complete run at f30a7f5 read the same counts for the four images. All five findings are gone from the
two images, which are rebuilt with PyJWT 2.14.0, proxy-addr 2.0.8, and no storybook or tinypool. Each of the four runs gives this table, none adding or removing a finding, and the images built from 84b63d9 are what runs today:

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin`, OS packages only | 0 | 0 | 0 | 0 |
| `wayline/backend`, flattened since ec45e21 | 0 | 4, in Django 5.2.15 and djangorestframework 3.17.2 | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

The policy is unchanged. These remain, and each HIGH and MEDIUM has a fix upstream that this work did not take:

- **The CRITICAL in the lockfile row is proxy-addr 2.0.7, CVE-2026-90711, in upstream's `pnpm-lock.yaml`.** It does not ship in any bundle: its code is in none of the
  web, admin or space build output, and the space server loads it from `node_modules`, where it is now 2.0.8. `docs/evidence/branding/lockfile-critical.txt` has the
  check, read at 1563cbf, and the frontends have not changed since, apart from their nginx settings. Upstream's unmodified `plane-live` image, which this platform runs, still has 2.0.7 and was reported in the complete run.
- PyJWT 2.14.0 is the version the CRITICAL names. Two MEDIUM findings on it, CVE-2026-101918 and CVE-2026-102275, need 2.15.0.
- The fixes replace or remove files in the container's filesystem. In `wayline/space` the old packages are still bytes in the `FROM` layers, which an image scan does not report. The backend is flattened since ec45e21, so no layer holds them.
- On GitHub, the step `Scan what was just pushed` in run 41975430939 ran this policy on the 4 images it published from 9c8e098, and in run 42044273310 on the 4 it published from 76e98ee, with exit 0 each time and the same counts. Those are other digests than the ones deployed, and only the table in the log remains: [ci/README.md](../ci/README.md).

## What this does not say

- `wayline/web` and `wayline/admin` show no findings because their clients are static files with no package metadata, and those bundles do contain libraries with findings. The row
  `wayline-source-lockfiles` is the view of those dependencies: `pnpm-lock.yaml` in the source they were built from. The complete run at f30a7f5 has no such row, because `.build/plane-src` was not on disk, so those dependencies were not read in it. The last read of them on this Mac is `scan-images-20261105T052024Z`, on the same frontends. A runner read them at 2026-11-05T14:28Z, in run 42044273310, with the same counts: 1 CRITICAL with a fix, 31 HIGH, 24 MEDIUM, 7 LOW. The policy does not fail on that row.
- The space image also has code inlined into its server bundle, which no scan attributes to it: `docs/evidence/branding/space-deps.txt`, sections 6 and 7. `docs/evidence/branding/space-high.txt` lists its HIGH findings by package.
- Python requirements in the source are not in that row: `apps/api/requirements.txt` only includes other files, whose names trivy does not look for. The backend image's installed packages are scanned.
- Local services outside the cluster manifests were not scanned: the `distribution` registry, `plane-git` and the kind node.
- The operator's Thanos default was left out because nothing runs it. See `policy/charts.rego`.
- A finding means a package version is listed as affected. Nobody has checked whether any of them can be reached in this platform.
- `redis:7.2.17-alpine` is on an end-of-life Alpine, where trivy warns that its OS findings may be incomplete.

## Host listeners

Read on the host, and not a scan. `docs/security.md` and `docs/agpl-compliance.md` cite it. `lsof` lists only the processes of the account it runs under, so the refused connections on the LAN address are the cross-check, made from the Mac itself and not from another device. The last read asks whether the local registry still holds the backend image from `1563cbf`, the unflattened one, which no environment runs now.

```text
date_utc: 2026-11-05T07:19:45Z
user: bek, so lsof lists that account's processes

$ lsof -nP -iTCP:80 -iTCP:443 -iTCP:5001 -sTCP:LISTEN
COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
com.docke 37598  bek  191u  IPv4 0x58efe86225773f8d      0t0  TCP 127.0.0.1:80 (LISTEN)
com.docke 37598  bek  193u  IPv4 0x847deba6d3844084      0t0  TCP 127.0.0.1:443 (LISTEN)
com.docke 37598  bek  291u  IPv4 0x9bd1c7654dcdc268      0t0  TCP 127.0.0.1:5001 (LISTEN)
[exit 0]

$ docker ps --filter name=plane-registry --filter name=plane-platform-control-plane --format '{{.Names}} {{.Ports}}'
plane-registry 127.0.0.1:5001->5000/tcp
plane-platform-control-plane 127.0.0.1:49732->6443/tcp, 127.0.0.1:80->30080/tcp, 127.0.0.1:443->30443/tcp
[exit 0]

$ curl -q -sS -o /dev/null -m 5 -w 'HTTP %{http_code}\n' http://192.168.0.101:80/
curl: (7) Failed to connect to 192.168.0.101 port 80 after 1 ms: Couldn't connect to server
HTTP 000
[exit 7]

$ curl -q -sS -o /dev/null -m 5 -w 'HTTP %{http_code}\n' http://192.168.0.101:443/
curl: (7) Failed to connect to 192.168.0.101 port 443 after 1 ms: Couldn't connect to server
HTTP 000
[exit 7]

$ curl -q -sS -o /dev/null -m 5 -w 'HTTP %{http_code}\n' http://192.168.0.101:5001/
curl: (7) Failed to connect to 192.168.0.101 port 5001 after 1 ms: Couldn't connect to server
HTTP 000
[exit 7]

$ curl -q -s -o /dev/null -w 'HTTP %{http_code}\n' -H 'Accept: <the OCI and Docker manifest and index types>' http://127.0.0.1:5001/v2/wayline/backend/manifests/sha256:4add277ce63eb11d4159f266f7dc880fc5254f1e4e13dac050ab97c90460658c
HTTP 200
[exit 0]
```

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
| `images/*.json` | Trivy's JSON for each target, run with `--list-all-pkgs=false`, so it lists findings and not every package. `scan-images-20261104T215437Z` no longer has these: a complete scan gives them up when a later complete scan arrives, as [the evidence rules](../README.md#layout) say |
| `scan.log` | What trivy printed for each target |
| `db-update.log` | The database check at the start |
| `trivy-version.txt` | Only in the later runs: trivy's version and the database's date, from `trivy version` |
| `README.md` | Only in the last four runs: what that run covered, how it compares with the run before, and its edits |

## Edits

Eleven strings in `images/*.json` in the first complete run, which those files have since left, were replaced with `<redacted>`, as `docs/evidence/README.md` allows, because gitleaks flagged
them. None is a secret of this platform. Six are the CPython release key fingerprint in `GPG_KEY`, three are the `POSTHOG_API_KEY`
in the public Infisical image's configuration, and two are an example token in the text of a PyJWT advisory. In `scan-images-20261104T235800Z` the same was done to two strings, both that
fingerprint, and ANSI colour codes were stripped from `run.log`. Each of the last four runs records its own edits in its README. Everything else is byte for byte. A later scan copied here will need the same replacements before it can be committed.
