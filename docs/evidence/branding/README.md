# Wayline branding: build and image evidence

Recorded 2026-11-05. The final images were built from commit `84b63d9b6294319787276f303e354a66b945558b`, which is also what the
web image's `/source` names. Everything here ran on the owner's Mac (arm64, Node 22), with the kind cluster running beside it.
These checks deployed and promoted nothing. The promotions came after, at `1fc9fbe` and `9c8e098`.

| Image | Digest, as `docker buildx imagetools inspect` reads it |
|---|---|
| web | `sha256:3d7575a1b9341b24dc882356b24d3d45126a4f5ccfb6abc72b07699668543747` |
| admin | `sha256:ce7adc37b1a7ff2f9f04457f89f7758152c9740be8e7f801b3ff0ae2a7a9c796` |
| space | `sha256:5f0119ff2266a7f0493e5903f1fdf47c022cc5ca86b6f8fa14d8485513cc0039` |
| backend | `sha256:8c04bd18bb0823f5740881cbed2f8759a98729a9c687b4009f0a3641c853adbe` |

`b2ba587`, named below, is the build before this one: web `316d6dd37336`, admin `0480d65f1078`, space `79c25c465f33`, backend `cd44a752e7ee`. Of what the images hold, only text changed since: `MODIFICATIONS.md` and `NOTICE.md`, which ship in every image. `images-compare-since-b2ba587.txt` lists what differs, and the other source paths that changed, which do not ship. `ec45e21`, also named below, is the build before that: web `96841278d02a`, admin `c24ead5a02a1`, space `0a4ca742292d`, backend `9c7130942d90`. What changed between those two is what `cache-errors.txt` and `walk-before-publish.txt` record, and the licence texts.

**The source offer was not live when this was captured.** The repository was private on 2026-11-05, so `/source` ended in a 404 for
anyone without access. It has been public since 2026-11-08. The commit it names, `84b63d9`, is on GitHub. `smoke.txt` marks the
redirect PASS, which proves only that the image answers with a 302 to the right commit. Its NOTE line records what that target
answered then: 404.

## Files

From the images above, unless the row says otherwise.

| File | What it is |
|---|---|
| `checks.txt` | The exit code of every gate, each run directly with no pipe |
| `digests.tsv`, `digests-confirmed.txt` | The digests, and each as the registry states it |
| `sizes.txt` | Layers, compressed registry size, Docker image size, user, build context sizes |
| `build.txt`, `images-build.txt` | `scripts/ci/build-images.sh localhost:5001/wayline`: the native part with `time -l` over the whole command, and Docker's part. Each image goes to the throwaway registry and is walked, and only then are the four copied by digest and walked again. The frontends came from turbo's cache, because their inputs have not changed since an earlier build. In web, admin and the backend's first stage Docker reused everything above the licence texts, and space, whose per-commit build arguments sit above its first `RUN`, rebuilt everything after its `FROM`. So these times do not measure a cold build. `build-ci-settings.txt` does |
| `token-diff.txt`, `contrast.txt`, `leak-scan.txt`, `source-links.txt`, `font-urls.txt`, `bundle-art.txt` | Their output |
| `smoke.txt` | `apps/wayline/checks/smoke-images.sh`: each image by digest under the chart's UID, memory, CPU and security settings, licence texts, nginx's redirects with an ingress's Host, what a browser may keep (`Cache-Control`, the 4 security headers and 304s on every kind of response, including an unreadable hashed file, a POST, a failed `If-Match` and ranges), the onboarding default, X-Forwarded-For on the space image, `space-deps.mjs check`, then the backend's in-image check and `flatten-config.py`. 780 PASS, 0 FAIL |
| `check-image.txt` | `apps/wayline/backend/check-image.sh` alone: `manage.py check`, `makemigrations --check`, and `check_image.py`. 114 PASS, 0 FAIL |
| `backend-db.txt` | `WAYLINE_BASE_CONTROL=yes apps/wayline/checks/backend-db.sh`: the backend against a scratch Postgres, Redis and mail server on an internal network, then the same checks failing on upstream's image |

### The stale page

| File | What it is |
|---|---|
| `live-dev/` | The real browser session on plane-dev, from commit `1563cbf`, which found the defect |
| `cache-headers-negative-control.txt` | The new checks in `smoke-images.sh` on the images from `1563cbf`, committed before the fix. 75 FAIL, all on `Cache-Control`, and the 304s pass, so they do fail where they should |
| `cache-names.txt` | `checks/cache-names.sh`: what the real build output holds against the rule in nginx |
| `cache-errors.txt` | From `b2ba587`, whose images it calls final, and the nginx configs have not changed since. Errors for a real hashed name, which the earlier rule stamped with the year. A real browser on the images from `ec45e21` and on the final ones: on the first it keeps a 403 after the server recovers, and a directory without its slash fails, and on the final ones neither happens. It did not keep a 405 on either, or the 416 the first ones answer, which the final ones no longer do. The same on all four with curl. Then what else was tried for the 416, and why byte ranges are off |
| `cache-errors-negative-control.txt` | From `b2ba587`, and `smoke-images.sh` has not changed since. `smoke-images.sh` as committed on web and admin from `ec45e21`, where it must fail: 34 FAIL, all on the new checks, and 561 PASS |
| `cache-names-across-builds.txt` | From `ec45e21`, and the frontends have not changed since. The real build output listed, and whether a name under `assets/` really stands for one content: 2474 web names and 238 admin names over eight builds each, with no name having two contents |
| `cache-browser.txt` | From `ec45e21`, whose images it calls final. A real browser, on a local port. On the images from `1563cbf` it does not ask after the first load, and keeps the old page when the file changes. On the images from `ec45e21` it asks each time, gets 304s, and has the new page at the next request. `cache-errors.txt` shows the page still asked about, with 304s, on the images from `b2ba587` |
| `upstream-html-age.txt` | The command and the line behind the 17.5 h in `MODIFICATIONS.md`: the age of `index.html` in upstream's image, what nginx sends for it, and a tenth of that age. A tenth is assumed, as the file's header says, and no browser was timed |
| `space-cache.txt` | From `ec45e21`, whose server has not changed since. The space image, by the same test. Its HTML has no lifetime and no validator, and each fetch reaches the server, so no patch was made |

### No commercially headed file in any layer

| File | What it is |
|---|---|
| `layer-check.txt` | `checks/layer-check.py`, the gate, on the four images we build: every layer clean, and nothing it could not open |
| `layer-check-cases.txt` | From `b2ba587`, and the script has not changed since. The same script on what it must catch: a gz named `x.body`, an `x.tar.zst`, UTF-16, lower case, an email pyc and more, each through its Walk and then as a real image through the command. Then the zstd paths, upstream's real image, where both the identifier and the sha256 hit in layers 13 and 20, and the backend from `1563cbf`, where the gate fails |
| `layer-check-negative-control.txt` | From the script as it was before it opened archives by content. The same on the images from `1563cbf`, where it must fail: `email.py` in backend layers 13 and 20 of 28, and our own check and prose, which then held the identifier literally |
| `layer-check-deployed.txt` | From the script as it was before it opened archives by content, or looked for other spellings, the sha256 or bytecode. `--report-only` on the 31 images this platform deploys unmodified, with their digests. Information, not a gate. Upstream's `plane-backend` holds the identifier in layers 13 and 20 of 20. `plane-live`, `plane-frontend`, `plane-admin`, `plane-space` and the other 26 are clean |
| `layer-check-deployed-images.txt` | Superseded by `layer-check-deployed.txt`. An earlier record of the same walk, by the agent that stopped on the prod-sim finding, from the first version of the script |
| `layer-check-live.txt` | `plane-live`, the `live` service's image, at the digest the overlays pin, read with the current script. Information, not a gate. Clean. From commit `a93ad02`, and the script and the digest have not changed since |
| `flatten-compare-4add277c.txt` | Acceptance of the flattening itself: the published stage, copying exactly the image the platform runs in dev, against that image. 28235 paths: none on one side only, and no difference in type, mode, uid, gid, size, link target, device, xattrs, sha256 or hard links. Config the same. Two directories differ in time, explained there |
| `flatten-compare-final.txt` | From `ec45e21`, whose image it calls final. That backend against its own derived stage, with the same result, and against the image from `1563cbf`, with every difference explained. Also every `.pyc` against its source: none stale |
| `flatten-compare-since-ec45e21.txt` | That backend against the one from `b2ba587`, path by path: 28235 paths in both, the two licence texts that changed, 12 `.pyc` files for jwt differing only in the source time they store, and file times. The revision label differs and nothing else in the config |
| `images-compare-since-b2ba587.txt` | All four final images against the ones from `b2ba587`, with `flatten-compare.py`: the source paths that changed, then every path and config field that differs. No path is on one side only. Apart from file times, what differs is `MODIFICATIONS.txt` and `NOTICE.txt` in each image and at `/licenses/` in web, the revision label, web's `nginx.conf`, where only the commit `/source` names changed, and the backend's 12 `.pyc` files for jwt, where only the source time they store changed. Each compare exits 1, because they differ |
| `flatten-config.txt`, `flatten-config-negative-control.txt` | The final backend's config against the pinned base, field by field, and, from `ec45e21`, the same check failing on a base with five things added |
| `flatten-size.txt` | From `ec45e21`, and `sizes.txt` reads the same layers and compressed size. Size and push time before and after, holding the same files, and what it means on disk. `flatten-size-script.sh.txt` is the script that measured it, and `pyc-stale-script.py.txt` the one that read every `.pyc` |
| `email-py.txt` | D12: `plane/utils/email.py` in upstream's image and the published one, the pin against upstream, the identifier anywhere in the published filesystem, the layers, the label and the decision |
| `pyjwt.txt` | What pins PyJWT, `pip freeze` between base and published, that 2.13.0 is gone, and the pinned hash |
| `walk-before-publish.txt` | From `b2ba587`, and `build-images.sh` has not changed since. `build-images.sh` stopping on purpose, on shims in a clone of that commit, with what reached a scratch target each time: a failed walk and a failed config check, nothing, a failed second walk, that image alone, a port taken, nothing. Then `PUSH=no`, a run with nothing failing, and one image through the kind of builder the publish job asks for, on this Mac, which is not GitHub or GHCR |
| `refusals.txt` | From `ec45e21`. Each refusal run on purpose: other registries, a pending or old decision, a dirty stamp, a missing stamp, a changed vendored file, the image build without the `email.py` COPY or the PyJWT install. Its last two sections, a failure after a push, are from before the walk moved in front of the publish: `walk-before-publish.txt` replaces them |

The disk effect, in full in `flatten-size.txt` and in `apps/wayline/README.md`: a registry grows by 97.5 MiB for each new backend version, where it grew by 0.25 MiB. The flattened
image shares no layer with upstream's, so in Docker it holds 479 MB of its own, where the unflattened one held 1.3 MB of its own and shared 511 MB. **Upstream's layers do not go away yet.** They
remain as a build input on any machine that builds this image. `helm/plane/overlays/prod-sim` named upstream's image until commit `0af8956`, which promoted the images from `ec45e21`. Only after that can a node drop them, and whether one has was not read here.

### The space server and the scan

| File | What it is |
|---|---|
| `space-deps.txt` | What the server bundle imports and reaches in `node_modules`, what Node loads while serving, why X-Forwarded-For reaches proxy-addr, the check failing on the previous image, and, in sections 6 to 8, what those cannot see: the packages inlined into the bundle, from `checks/space-regions.mjs`, with their findings. Sections 1 to 5 are from image `a8c49151ee94`, and 6 to 8 from `0a4ca742292d`, which is `ec45e21`'s |
| `space-high.txt` | Every package with a HIGH finding in the final scan, 13 with 30 findings, each named in `MODIFICATIONS.md`, and on the final image, that the development packages among them are neither in the server's reach nor inlined |
| `lockfile-critical.txt` | From commit `1563cbf`, and the frontends have not changed since. The one CRITICAL in the source lockfile row: what it is, and that no bundle ships it |
| `../security/scan-images-20261105T052024Z/` | `SCAN_ONLY=built scripts/ci/scan-images.sh` on the final images. Exit 0 |

| Target | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| `wayline/web`, `wayline/admin` | 0 | 0 | 0 | 0 |
| `wayline/backend` | 0 | 4, in Django and djangorestframework | 11 | 2 |
| `wayline/space` | 0 | 30 | 22 | 5 |
| `wayline-source-lockfiles` | 1 | 31 | 24 | 7 |

**The zeros for web and admin cover OS packages only.** trivy reports `Number of language-specific files num=0` on those two images, in the run's `scan.log`, because their clients are
bundled static files with no package metadata. Those bundles do contain libraries with findings: a search of the build output finds markdown-it, prosemirror-view, nanoid, @tiptap and axios in the web client, and
ProseMirror and axios in admin. The lockfile row is the only view of those. In space, findings sit both in packages the server loads from `node_modules` and in packages inlined into its bundle: `space-deps.txt`.

The backend's and space's findings are the same as on the images from `b2ba587`, `ec45e21` and `1563cbf`: 17 and 57, none added and none gone, on the same vulnerability database. The backend's `os` now reads `alpine 3.23.7`, where the same scan of the layered image read 3.23.3.
`/etc/alpine-release` says 3.23.7 in both images.

### The rest

| File | What it is |
|---|---|
| `upgrade-check.txt` | `checks/upgrade-check.sh`, in a clone of the tree's commit at the time with its own `.build`, because it rewrites `.build/plane-src`. Exit 0 |
| `upstream-check.txt` | Overlay and patches dry-run against `v1.4.2`, `v1.4.0`, `v1.3.0` and `preview`. The upgrade table in `apps/wayline/README.md` comes from here |
| `lint.txt` | shellcheck, actionlint, zizmor, hadolint, py_compile, `node --check`, `trivy config` and gitleaks on what this work owns. Not the whole of `scripts/ci/lint.sh`, which runs `terraform init` in directories other agents use, or `scripts/ci/security.sh`. Exit 0 each |
| `lint-failed-baeaa4b.txt` | The same set on an earlier build, at `baeaa4b`. `trivy config` failed: DS-0031 on `GPG_KEY`, in `Dockerfile.backend`. So that build was not kept. `ec45e21` scopes one inline ignore to that line |
| `default-sender.txt` | The sender mail goes from, on the final backend and on upstream's: the fallback, `EMAIL_FROM`, and what `configure_instance` stores. An instance started with no `EMAIL_FROM` sends from `webmaster@localhost` on both, and the fallback is reached only with no stored row |
| `surface-checks.txt` | Strings the review named, read from build output, consent and telemetry defaults including the onboarding default on upstream's image, image labels, and the who-chose text as it ships |
| `headers.txt` | SPDX and copyright lines removed against the tag. It should say 0 |
| `build-ci-settings.txt` | From commit `ffbef80`, and the frontends have not changed since. `apps/wayline/scripts/build.sh` under the settings `images.yml` gives both jobs, concurrency 2 and a 2560 MB heap, from a cold turbo cache |
| `typecheck.txt` | `check:types` per package, from `1242134`, and `apps/web` from `1563cbf`. TypeScript has not changed since |
| `bump-test.txt` | From commit `1242134`. A synthetic upstream bump in an isolated copy: the same result with an existing and an empty `.build`, rollback, overlay lock naming a moved and a changed file, and the rebase path |
| `upstream-images-kept.txt` | From commit `efb5af9`. Shipped images byte-identical to an upstream file. The overlay's images have not changed since |
| `browser-console.txt`, `screens/` | From commit `1242134`, in the setup below |

The image scan's raw results are in `docs/evidence/security/scan-images-20261105T052024Z/`.

**Edits to these files.** ANSI colour codes were stripped. The public fingerprint of CPython's release key, `GPG_KEY` in the images' config, became `<redacted>` because gitleaks reads it as a credential, as in the earlier scans.
In the files this round rewrote, scratch paths became `<scratch>` or `<clone>`. Files left from earlier rounds keep theirs as they ran: `bump-test.txt`, `cache-headers-negative-control.txt`, `flatten-compare-final.txt`, `flatten-config-negative-control.txt`, `flatten-size-script.sh.txt`, `refusals.txt` and `upstream-images-kept.txt`. Lines starting `#` are headers written by whoever ran the command.

## What failed while the last fix was being tried

Both before commit `b2ba587`, in scratch, and fixed before it. `walk-before-publish.txt` ends with the raw error of the first. The raw output of the second was overwritten by the run that passed.

- **A push to the throwaway registry hung for about two minutes and failed**, when the registry was published on a port Docker picked. On Docker Desktop that port is open on the Mac and not inside the VM where the builder runs, which refused it. So the port is fixed, 5059 by default.
- **`smoke-images.sh` failed its own check on the images with the fix, on the first try**: 2 FAIL, "logged permission or fatal errors", because nginx logs the file the check makes unreadable. So that one line is excused, by its exact path.

## Two failed runs whose raw output is gone

Both happened in the earlier round that built `1563cbf`. A search of `.local/evidence-raw` and the scratch directories on 2026-11-05 found no output from either, so this is all that is known, and it comes from that round's report and commit message:

- **`backend-db.sh` failed once**, before commit `1563cbf`. Its readiness check could pass against the temporary server the Postgres image starts while initializing, which answers on its Unix socket and then stops, so the next step found no database. The check now uses TCP. That round's report says it then passed four runs in a row, including the one it recorded. Which step failed, and its exact message, are not known.
- **The first build with the vendored `email.py` failed**, before commit `bcde940`. The file sat beside `check_image.py` in `/opt/wayline`, where it shadowed the standard library's `email` package when the build-time checks ran. It now sits in `backend/vendor/`, and `backend/assemble.sh` says why. The exact error is not known.

## Labels to read with care

- `check_db.py`'s line about a new profile's marketing consent reads a model default, and it passes on upstream's image too. It does not cover the onboarding patch, and it now says so. What covers that patch is a check in `smoke.txt` on the built web client, where the form defines its default, and `surface-checks.txt` shows the same line reading `!0` on upstream's image.
- `check_db.py`'s "default sender" line reads `noreply@wayline.invalid` because `backend-db.sh` runs with `SKIP_ENV_VAR=0` and nothing stored, which is not how the image starts by default. That line proves the fallback, and `default-sender.txt` shows what a started instance sends from.
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

Anything that needs the running platform: deployment under PSA `restricted` and the ingress, `/source`, `/licenses/` and `/licenses` through
Traefik, `Cache-Control` and the absence of byte ranges through Traefik and across a real promotion or rollback, the flattened backend in the cluster, sign-in and sign-up against the real API, the signed-in shell with real data (boards, pages, cycles, peek and collapsed
sidebars, extended sidebars), god-mode beyond its sign-in page, public issue pages with data, the worker and beat running, seeding with
these strings, mail in real clients, `create_bucket`, the page PDF export, and amd64 images. Browsers other than Chromium. What a workspace's mail on the cluster is sent from: `default-sender.txt` read a scratch database.

These checks did not run `.github/workflows/images.yml`. It ran with `apps/wayline` in it in runs 41975430939 at `9c8e098` and 42044273310 at `76e98ee`. The native
arm64 build on GitHub, the throwaway registry on a runner, the copy to GHCR, the walk and scan of what was published with GHCR's login, prune and the publishing gate step all executed, with a prune that deleted nothing ([ci/README.md](../ci/README.md)). `wayline-upstream-check.yml` still has no run. The change to `images.yml`'s path filters, for `MODIFICATIONS.md`, has not been seen to trigger anything. `build-ci-settings.txt` ran on this Mac, not on a 2-core runner, at commit `ffbef80`. `apps/wayline/scripts/publish-gate.sh` ran here.

GitHub's documentation conflicts on a linked package's visibility, read on 2026-11-05: its page on publishing with Actions says a package a workflow creates takes the repository's visibility, and its page on access control and visibility says a linked
package takes the repository's access permissions and not its visibility. It says elsewhere that a package is private when first published. Images have been pushed twice, at `9c8e098` and `76e98ee`. With no credentials the first four answered 401 ([record](../ci/ci-4-20261105T055033Z-ghcr-visibility.txt)). The API that states a package's visibility was not read, because the local token lacks `read:packages`. `apps/wayline/README.md` has the step: read each package's
visibility on its GitHub page.
