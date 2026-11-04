# Wayline branding: build and image evidence

Recorded 2026-11-05. Built from commit `efb5af9d6e75f2a65cb9f664cf7ebb78b4735435`, which is also what the web
image's `/source` names. Everything here ran on the owner's Mac (arm64, Node 22), with the kind cluster running
beside it. Nothing was deployed to the cluster.

| File | What it is |
|---|---|
| `digests.tsv` | Image digests, confirmed against the registry with `docker buildx imagetools inspect` |
| `sizes.txt` | Compressed registry size, Docker image size, user, build context sizes |
| `build.txt` | `apps/wayline/scripts/build.sh` from `rm -rf .build/plane-src`, with peak memory |
| `images-build.txt` | Excerpt of `scripts/ci/build-images.sh localhost:5001/wayline` |
| `typecheck.txt` | `check:types` per package, exit codes and memory |
| `checks.txt` | token-diff, contrast, leak-scan and font-urls exit codes, each run directly with no pipe |
| `token-diff.txt`, `contrast.txt`, `leak-scan.txt` | Their output |
| `smoke.txt` | `apps/wayline/checks/smoke-images.sh`: each image by digest under the chart's UID, memory, CPU and security settings, plus the backend's in-image check |
| `upstream-images-kept.txt` | Shipped images that are byte-identical to an upstream file |
| `browser-console.txt` | Page titles and console errors, this build against unmodified upstream images, same stub |
| `screens/` | Headless Chrome renders of these images |

## Limits of the browser renders

`screens/` and `browser-console.txt` come from the real images behind a small scratch proxy shaped like the
ingress, with a stub API that returned fixed JSON and empty lists. There was no real backend, database, session
or data. Sign-in pages rendered with real code. The shell rendered with a stub user, one workspace and one project,
and project pages stop at "not found" because the stub has no project detail. No form was submitted.

Both the hydration errors (React #418 and #423) and the swapped sign-in page titles also appear on unmodified
upstream images with the same counts, so they are not from this work.

## Not verified here

Anything that needs the running platform: deployment under PSA `restricted` and the ingress, sign-in and sign-up against
the real API, the signed-in shell with real data (boards, pages, cycles, peek and collapsed sidebars, extended
sidebars), god-mode beyond its sign-in page, public issue pages, emails actually sent, migrations and seeding with
these strings, `collectstatic`, and amd64 images.
