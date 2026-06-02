# Wayline branding: build and image evidence

Recorded 2026-11-05. The final images were built from commit `ec45e212ee6185d286762a753913c253dac51358`, which is also what the
web image's `/source` names. Everything here ran on the owner's Mac (arm64, Node 22), with the kind cluster running beside it.
Nothing was deployed to the cluster and nothing was promoted.

| Image | Digest, as `docker buildx imagetools inspect` reads it |
|---|---|
| web | `sha256:96841278d02af51d83c0a5886530961dd330e11ae55f8d0b784d94f811f3dcc5` |
| admin | `sha256:c24ead5a02a18f4cd452c1b3650e57136352ed6b49102de2bbe491d2649432f1` |
| space | `sha256:0a4ca742292d635eb0a894efff20858baf3a3667e35f08d0a650208d185a32a2` |
| backend | `sha256:9c7130942d90a4920f59fb4e92bd2dc1bf7a70cf035d560a0cdac5caf02c839e` |

**The source offer is not live yet.** The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without
access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an
instance. `smoke.txt` marks the redirect PASS, which proves only that the image answers with a 302 to the right commit. Its
NOTE line records what that target answered: 404.

## Files

From the images above, unless the row says otherwise.

| File | What it is |
|---|---|
| `checks.txt` | The exit code of every gate, each run directly with no pipe |
| `digests.tsv`, `digests-confirmed.txt` | The digests, and each as the registry states it |
| `sizes.txt` | Layers, compressed registry size, Docker image size, user, build context sizes |
| `build.txt`, `images-build.txt` | `scripts/ci/build-images.sh localhost:5001/wayline`: the native part with `time -l` over the whole command, and Docker's part. The frontends came from turbo's cache and the backend's stages from BuildKit's, because their inputs have not changed since an earlier build in this round. So these times do not measure a cold build. `build-ci-settings.txt` does |
| `token-diff.txt`, `contrast.txt`, `leak-scan.txt`, `source-links.txt`, `font-urls.txt`, `bundle-art.txt` | Their output |
| `smoke.txt` | `apps/wayline/checks/smoke-images.sh`: each image by digest under the chart's UID, memory, CPU and security settings, licence texts, what a browser may keep (`Cache-Control`, the 4 security headers and 304s on every kind of response), the onboarding default, X-Forwarded-For on the space image, `space-deps.mjs check`, then the backend's in-image check and `flatten-config.py`. 680 PASS, 0 FAIL |
| `check-image.txt` | `apps/wayline/backend/check-image.sh` alone: `manage.py check`, `makemigrations --check`, and `check_image.py`. 114 PASS, 0 FAIL |
| `backend-db.txt` | `WAYLINE_BASE_CONTROL=yes apps/wayline/checks/backend-db.sh`: the backend against a scratch Postgres, Redis and mail server on an internal network, then the same checks failing on upstream's image |

### The stale page

| File | What it is |
|---|---|
| `live-dev/` | The real browser session on plane-dev, from commit `1563cbf`, which found the defect |
| `cache-headers-negative-control.txt` | The new checks in `smoke-images.sh` on the images from `1563cbf`, committed before the fix. 75 FAIL, all on `Cache-Control`, and the 304s pass, so they do fail where they should |
| `cache-names.txt` | `checks/cache-names.sh`: what the real build output holds against the rule in nginx |
| `cache-names-across-builds.txt` | The real build output listed, and whether a name under `assets/` really stands for one content: 2474 web names and 238 admin names over eight builds each, with no name having two contents |
| `cache-browser.txt` | A real browser, on a local port. On the images from `1563cbf` it does not ask after the first load, and keeps the old page when the file changes. On the final images it asks each time, gets 304s, and has the new page at the next request |
| `space-cache.txt` | The space image, by the same test. Its HTML has no lifetime and no validator, and each fetch reaches the server, so no patch was made |

### No commercially headed file in any layer

| File | What it is |
|---|---|
| `layer-check.txt` | `checks/layer-check.py`, the gate, on the four images we build: every layer clean |
| `layer-check-negative-control.txt` | The same on the images from `1563cbf`, where it must fail: `email.py` in backend layers 13 and 20 of 28, and our own check and prose, which then held the identifier literally |
| `layer-check-deployed.txt` | `--report-only` on the 31 images this platform deploys unmodified, with their digests. Information, not a gate. Upstream's `plane-backend` holds the identifier in layers 13 and 20 of 20. `plane-live`, `plane-frontend`, `plane-admin`, `plane-space` and the other 26 are clean |
| `layer-check-deployed-images.txt` | An earlier record of the same walk, by the coordinator, from the first version of the script |
| `flatten-compare-4add277c.txt` | Acceptance of the flattening itself: the published stage, copying exactly the image the platform runs in dev, against that image. 28235 paths: none on one side only, and no difference in type, mode, uid, gid, size, link target, device, xattrs, sha256 or hard links. Config the same. Two directories differ in time, explained there |
| `flatten-compare-final.txt` | The final backend against its own derived stage, with the same result, and against the image from `1563cbf`, with every difference explained. Also every `.pyc` against its source: none stale |
| `flatten-config.txt`, `flatten-config-negative-control.txt` | The final backend's config against the pinned base, field by field, and the same check failing on a base with five things added |
| `flatten-size.txt` | Size and push time before and after, holding the same files, and what it means on disk |
| `email-py.txt` | D12: `plane/utils/email.py` in upstream's image and the published one, the pin against upstream, the identifier anywhere in the published filesystem, the layers, the label and the decision |
| `pyjwt.txt` | What pins PyJWT, `pip freeze` between base and published, that 2.13.0 is gone, and the pinned hash |
| `refusals.txt` | Each refusal run on purpose: other registries, a pending or old decision, a dirty stamp, a missing stamp, a changed vendored file, the image build without the `email.py` COPY or the PyJWT install, and `build-images.sh` stopping with no digest recorded when the layer check or the config check fails after a push |

The disk effect, in full in `flatten-size.txt` and in `apps/wayline/README.md`: a registry grows by 97.5 MiB for each new backend version, where it grew by 0.25 MiB. The flattened
image shares no layer with upstream's, so in Docker it holds 479 MB of its own, where the unflattened one held 1.3 MB of its own and shared 511 MB. **Upstream's layers do not go away yet.** They
remain as a build input on any machine that builds this image, and `plane-prod-sim` still names upstream's image. Nothing else uses them only after that environment is promoted, and only then can a node drop them.

### The space server and the scan

| File | What it is |
|---|---|
| `space-deps.txt` | What the server bundle imports and reaches in `node_modules`, what Node loads while serving, why X-Forwarded-For reaches proxy-addr, the check failing on the previous image, and, in sections 6 to 8, what those cannot see: the packages inlined into the bundle, from `checks/space-regions.mjs`, with their findings. Sections 1 to 5 are from image `a8c49151ee94` |
| `lockfile-critical.txt` | From commit `1563cbf`, and the frontends have not changed since. The one CRITICAL in the source lockfile row: what it is, and that no bundle ships it |
| `../security/scan-images-20261105T020423Z/` | `SCAN_ONLY=built scripts/ci/scan-images.sh` on the final images. Exit 0 |

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 |
| `wayline/backend` | 0 | 4, in Django and djangorestframework | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

**The zeros for web and admin cover OS packages only.** trivy reports `Number of language-specific files num=0` on those two images, in the run's `scan.log`, because their clients are
bundled static files with no package metadata. Those bundles do contain libraries with findings: a search of the build output finds markdown-it, prosemirror-view, nanoid, @tiptap and axios in the web client, and
ProseMirror and axios in admin. The lockfile row is the only view of those. In space, findings sit both in packages the server loads from `node_modules` and in packages inlined into its bundle: `space-deps.txt`.

The backend's and space's findings are the same as on the images from `1563cbf`: 17 and 57, none added and none gone. The backend's `os` now reads `alpine 3.23.7`, where the same scan of the layered image read 3.23.3.
`/etc/alpine-release` says 3.23.7 in both images.

### The rest

| File | What it is |
|---|---|
| `upgrade-check.txt` | `checks/upgrade-check.sh`, in a clone of the commit with its own `.build`, because it rewrites `.build/plane-src`. Exit 0 |
| `upstream-check.txt` | Overlay and patches dry-run against `v1.4.2`, `v1.4.0`, `v1.3.0` and `preview`. The upgrade table in `apps/wayline/README.md` comes from here |
| `lint.txt` | shellcheck, actionlint, zizmor, hadolint, py_compile, `node --check`, `trivy config` and gitleaks on what this work owns. Not the whole of `scripts/ci/lint.sh`, which runs `terraform init` in directories other agents use, or `scripts/ci/security.sh`. Exit 0 each |
| `lint-failed-baeaa4b.txt` | The same set on the first final build, at `baeaa4b`. `trivy config` failed: DS-0031 on `GPG_KEY`, in `Dockerfile.backend`. So that build was not kept. `ec45e21` scopes one inline ignore to that line, and the images above are the rebuild |
| `surface-checks.txt` | Strings the review named, read from build output, consent and telemetry defaults including the onboarding default on upstream's image, image labels, and the who-chose text as it ships |
| `headers.txt` | SPDX and copyright lines removed against the tag. It should say 0 |
| `build-ci-settings.txt` | From commit `ffbef80`, and the frontends have not changed since. `apps/wayline/scripts/build.sh` under the settings `images.yml` gives both jobs, concurrency 2 and a 2560 MB heap, from a cold turbo cache |
| `typecheck.txt` | `check:types` per package, from `1242134`, and `apps/web` from `1563cbf`. TypeScript has not changed since |
| `bump-test.txt` | From commit `1242134`. A synthetic upstream bump in an isolated copy: the same result with an existing and an empty `.build`, rollback, overlay lock naming a moved and a changed file, and the rebase path |
| `upstream-images-kept.txt` | From commit `efb5af9`. Shipped images byte-identical to an upstream file. The overlay's images have not changed since |
| `browser-console.txt`, `screens/` | From commit `1242134`, in the setup below |

The image scan's raw results are in `docs/evidence/security/scan-images-20261105T020423Z/`.

**Edits to these files.** ANSI colour codes were stripped. The public fingerprint of CPython's release key, `GPG_KEY` in the images' config, became `<redacted>` because gitleaks reads it as a credential, as in the earlier scans.
Scratch paths became `<scratch>` or `<clone>`. Lines starting `#` are headers written by whoever ran the command.

## Two failed runs whose raw output is gone

Both happened in the earlier round that built `1563cbf`. A search of `.local/evidence-raw` and the scratch directories on 2026-11-05 found no output from either, so this is all that is known, and it comes from that round's report and commit message:

- **`backend-db.sh` failed once**, before commit `1563cbf`. Its readiness check could pass against the temporary server the Postgres image starts while initializing, which answers on its Unix socket and then stops, so the next step found no database. The check now uses TCP. That round's report says it then passed four runs in a row, including the one it recorded. Which step failed, and its exact message, are not known.
- **The first build with the vendored `email.py` failed**, before commit `bcde940`. The file sat beside `check_image.py` in `/opt/wayline`, where it shadowed the standard library's `email` package when the build-time checks ran. It now sits in `backend/vendor/`, and `backend/assemble.sh` says why. The exact error is not known.

## Labels to read with care

- `check_db.py`'s line about a new profile's marketing consent reads a model default, and it passes on upstream's image too. It does not cover the onboarding patch, and it now says so. What covers that patch is a check in `smoke.txt` on the built web client, where the form defines its default, and `surface-checks.txt` shows the same line reading `!0` on upstream's image.
- The telemetry checks cover a newly registered instance. An instance registered earlier by upstream's image keeps its stored setting, and the worker's task then exports to `telemetry.plane.so:443`. `tests/network-policy-matrix.yaml` expects api and worker denied on that host and port in both environments, and `docs/evidence/runs/netpol-20261104T232752Z.tsv` and `netpol-20261104T233304Z.tsv` record them timing out. So on this platform the export fails. Without that NetworkPolicy it would send. Nothing here has run an instance in that state.

## Limits of the browser renders

`screens/` and `browser-console.txt` come from the built client files served through Playwright routing with a stub API that
returned fixed JSON and empty lists, not from the images behind an ingress. Public pages (`space-*`) ran from the built
`server/index.js` with `react-router-serve` on the host. There was no real backend, database, session or data, and no form was
submitted. Signed-in pages used a stub user, one workspace and two projects. The help menu closing on click and opening a new
tab at `/source` was checked in that setup, with the target stubbed.

The hydration errors (React #418 and #423) are filtered from `browser-console.txt`. On the previous build they appeared with the
same counts on unmodified upstream images. That comparison was not repeated on this build.

## Limits of `backend-db.txt`

It ran `postgres:15.6`, Redis 8 and Mailpit, already on this machine, not the platform's data services. Tasks that views queue stay in
an in-memory broker with no worker, so the mails are the invitation task called directly, and no worker or beat ran. `POST` project
invitations answers 500 on the base image too, upstream's bug at `v1.4.3`, so `jwt.encode` in that view has no request that reaches it:
`smoke.txt` runs the same call directly. The api steps leave out `create_bucket`, because no object store was started.

## Not verified here

Anything that needs the running platform: deployment under PSA `restricted` and the ingress, `/source` and `/licenses/` through
Traefik, `Cache-Control` through Traefik and across a real promotion or rollback, the flattened backend in the cluster, sign-in and sign-up against the real API, the signed-in shell with real data (boards, pages, cycles, peek and collapsed
sidebars, extended sidebars), god-mode beyond its sign-in page, public issue pages with data, the worker and beat running, seeding with
these strings, mail in real clients, `create_bucket`, the page PDF export, and amd64 images. Browsers other than Chromium.

`.github/workflows/images.yml` has never run with `apps/wayline` in it, and `wayline-upstream-check.yml` has never run. The native
arm64 build on GitHub, GHCR push, the layer walk and scan of what was pushed with GHCR's login, prune and the publishing gate step were read and linted with actionlint
and zizmor, not executed. `build-ci-settings.txt` ran on this Mac, not on a 2-core runner, at commit `ffbef80`. `apps/wayline/scripts/publish-gate.sh` ran here.

GitHub's documentation conflicts on a linked package's visibility, read on 2026-11-05: its page on publishing with Actions says a package a workflow creates takes the repository's visibility, and its page on access control and visibility says a linked
package takes the repository's access permissions and not its visibility. It says elsewhere that a package is private when first published. **None of this has been observed, because nothing has been pushed.** `apps/wayline/README.md` has the step: read each package's
visibility after the first publish and before making the repository public.
