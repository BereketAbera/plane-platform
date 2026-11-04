# Wayline branding: build and image evidence

Recorded 2026-11-05. Built from commit `1242134361ffff7ddff5144bc912a98832181401`, which is also what the web image's
`/source` names. Everything here ran on the owner's Mac (arm64, Node 22), with the kind cluster running beside it. Nothing
was deployed to the cluster.

**The source offer is not live yet.** The repository is private as of 2026-11-05, so `/source` returns 404 to anyone without
access until it is made public, and the commit it names must also be pushed. This must be fixed before anyone else uses an
instance. `smoke.txt` marks the redirect PASS, which proves only that the image answers with a 302 to the right commit. Its
NOTE line records what that target answered: 404.

| File | What it is |
|---|---|
| `digests.tsv` | Image digests, confirmed against the registry with `docker buildx imagetools inspect` |
| `sizes.txt` | Compressed registry size, Docker image size, user, build context sizes |
| `build.txt` | `apps/wayline/scripts/build.sh` from `rm -rf .build/plane-src`, with `time -l`. The `maximum resident set size` is the largest single process, in bytes |
| `images-build.txt` | Excerpt of `scripts/ci/build-images.sh localhost:5001/wayline`, reusing that build's stamped contexts |
| `refusals.txt` | `build-images.sh` refusing a dirty stamp, a missing stamp, and a registry other than the local one while D12 is pending |
| `typecheck.txt` | `check:types` per package, exit codes and memory |
| `checks.txt` | token-diff, contrast, leak-scan, source-links, font-urls, bundle-art and smoke exit codes, each run directly with no pipe |
| `token-diff.txt`, `contrast.txt`, `leak-scan.txt` | Their output |
| `smoke.txt` | `apps/wayline/checks/smoke-images.sh`: each image by digest under the chart's UID, memory, CPU and security settings, licence texts, plus the backend's in-image check |
| `surface-checks.txt` | Strings the review named, read from build output, and image labels |
| `headers.txt` | SPDX and copyright lines removed against the tag. It should say 0 |
| `upstream-check.txt` | Overlay and patches dry-run against `v1.4.2`, `v1.4.0`, `v1.3.0` and `preview`. The upgrade table in `apps/wayline/README.md` comes from here |
| `bump-test.txt` | A synthetic upstream bump in an isolated copy: the same result with an existing and an empty `.build`, rollback, overlay lock naming a moved and a changed file, and the rebase path |
| `upstream-images-kept.txt` | Shipped images byte-identical to an upstream file. From the previous build, on commit `efb5af9`. The overlay's images have not changed since |
| `browser-console.txt` | Pages rendered for `screens/`, and any page errors other than hydration errors |
| `screens/` | Headless Chromium renders of this build |

## Limits of the browser renders

`screens/` and `browser-console.txt` come from the built client files served through Playwright routing with a stub API that
returned fixed JSON and empty lists, not from the images behind an ingress. Public pages (`space-*`) ran from the built
`server/index.js` with `react-router-serve` on the host. There was no real backend, database, session or data, and no form was
submitted. Signed-in pages used a stub user, one workspace and two projects. The help menu closing on click and opening a new
tab at `/source` was checked in that setup, with the target stubbed.

The hydration errors (React #418 and #423) are filtered from `browser-console.txt`. On the previous build they appeared with the
same counts on unmodified upstream images. That comparison was not repeated on this build.

Sampled peak memory for all build processes together was not captured on this run. `time -l` gives only the largest process.

## Not verified here

Anything that needs the running platform: deployment under PSA `restricted` and the ingress, `/source` and `/licenses/` through
Traefik, sign-in and sign-up against the real API, the signed-in shell with real data (boards, pages, cycles, peek and collapsed
sidebars, extended sidebars), god-mode beyond its sign-in page, public issue pages with data, emails actually sent, migrations and
seeding with these strings, `collectstatic`, the page PDF export, and amd64 images.

`.github/workflows/images.yml` has never run with `apps/wayline` in it, and `wayline-upstream-check.yml` has never run. The native
arm64 build on GitHub, GHCR push, prune and the D12 gate step were read and linted with actionlint, not executed.
