# Wayline branding: build and image evidence

Recorded 2026-11-05. Built from commit `8e328a06545030a43066b65112082491311e0048`, which is also what the web image's
`/source` names. Everything here ran on the owner's Mac (arm64, Node 22), with the kind cluster running beside it. Nothing
was deployed to the cluster and nothing was promoted.

**The source offer is not live yet.** The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without
access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an
instance. `smoke.txt` marks the redirect PASS, which proves only that the image answers with a 302 to the right commit. Its
NOTE line records what that target answered: 404.

| File | What it is |
|---|---|
| `digests.tsv` | Image digests |
| `digests-confirmed.txt` | Each digest as `docker buildx imagetools inspect` reads it from the registry |
| `sizes.txt` | Compressed registry size, Docker image size, user, build context sizes |
| `build.txt` | The native part of `scripts/ci/build-images.sh localhost:5001/wayline` from `rm -rf .build/plane-src`, with `time -l` over the whole command. The `maximum resident set size` is the largest single process, in bytes |
| `images-build.txt` | Docker's part of that command: all four images, with the backend's and space's checks at build time |
| `build-ci-settings.txt` | `apps/wayline/scripts/build.sh` under the settings `images.yml` gives both jobs, concurrency 2 and a 2560 MB heap, from a cold turbo cache, with the sum of build-process memory sampled each second |
| `checks.txt` | token-diff, contrast, leak-scan, source-links, font-urls, bundle-art, smoke and backend-db exit codes, each run directly with no pipe |
| `token-diff.txt`, `contrast.txt`, `leak-scan.txt` | Their output |
| `smoke.txt` | `apps/wayline/checks/smoke-images.sh`: each image by digest under the chart's UID, memory, CPU and security settings, licence texts, X-Forwarded-For on the space image, `space-deps.mjs check`, plus the backend's in-image check |
| `backend-db.txt` | `WAYLINE_BASE_CONTROL=yes apps/wayline/checks/backend-db.sh`: the backend against a scratch Postgres, Redis and mail server on an internal network. Migrations, `makemigrations --check`, instance registration, the setup endpoint, an invitation, a mail read back, then the same checks failing on upstream's image |
| `email-py.txt` | D12: `plane/utils/email.py` in the base and derived images, the pin against upstream, the base layers still in the derived image, the label and the decision |
| `pyjwt.txt` | What pins PyJWT, `pip freeze` between base and derived, the hash against PyPI |
| `space-deps.txt` | What the server bundle imports and reaches, what Node loads while serving on the previous and final images, why X-Forwarded-For reaches proxy-addr, and the check failing on the previous image |
| `lockfile-critical.txt` | The one CRITICAL in the source lockfile row: what it is, and that no bundle ships it |
| `refusals.txt` | `build-images.sh` refusing other registries, a pending decision, a dirty stamp and a missing stamp. The image build stopping without the `email.py` COPY or the PyJWT install, and `assemble.sh` refusing a changed vendored file |
| `surface-checks.txt` | Strings the review named, read from build output, consent and telemetry defaults, and image labels |
| `headers.txt` | SPDX and copyright lines removed against the tag. It should say 0 |
| `typecheck.txt` | `check:types` per package, exit codes and memory. Only `apps/web` was run again on this commit, and it says so |
| `upstream-check.txt` | Overlay and patches dry-run against `v1.4.2`, `v1.4.0`, `v1.3.0` and `preview`. The upgrade table in `apps/wayline/README.md` comes from here |
| `bump-test.txt` | From commit `1242134`. A synthetic upstream bump in an isolated copy: the same result with an existing and an empty `.build`, rollback, overlay lock naming a moved and a changed file, and the rebase path |
| `upstream-images-kept.txt` | From commit `efb5af9`. Shipped images byte-identical to an upstream file. The overlay's images have not changed since |
| `browser-console.txt`, `screens/` | From commit `1242134`, in the setup below. Since then the only change that reaches a browser is onboarding's consent default, which is not drawn on a self-managed instance |

The image scan of this build is in `docs/evidence/security/scan-images-20261104T233230Z/`.

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
an in-memory broker with no worker, so the one mail is the invitation task called directly, and no worker or beat ran. `POST` project
invitations answers 500 on the base image too, upstream's bug at `v1.4.3`, so `jwt.encode` in that view has no request that reaches it:
`smoke.txt` runs the same call directly.

## Not verified here

Anything that needs the running platform: deployment under PSA `restricted` and the ingress, `/source` and `/licenses/` through
Traefik, sign-in and sign-up against the real API, the signed-in shell with real data (boards, pages, cycles, peek and collapsed
sidebars, extended sidebars), god-mode beyond its sign-in page, public issue pages with data, the worker and beat running, seeding with
these strings, mail in real clients, `collectstatic`, the page PDF export, and amd64 images.

`.github/workflows/images.yml` has never run with `apps/wayline` in it, and `wayline-upstream-check.yml` has never run. The native
arm64 build on GitHub, GHCR push, the scan of what was pushed, prune and the publishing gate step were read and linted with actionlint
and zizmor, not executed. `build-ci-settings.txt` ran on this Mac, not on a 2-core runner. `scripts/publish-gate.sh` ran here. GitHub's documentation says a package
is private when first published, and that one a workflow creates takes its repository's visibility. Neither has been seen here, because nothing has been pushed.
