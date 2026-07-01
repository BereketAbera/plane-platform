# AGPL compliance

**This is engineering analysis, not legal advice. Have counsel review it before any public launch.**

Wayline is a customized deployment of open-source Plane Community Edition v1.4.3. It is not an original product. Plane is copyright Plane Software, Inc. and contributors, and licensed under AGPL-3.0-only. This page records what that means here, what is done, and what is not done.

Written 2026-11-04, and reconciled on 2026-11-05 against `apps/wayline/` as committed then, the final images built from `84b63d9`, which both environments run, the first image build on GitHub, and the first real browser session on the branded images. Facts about upstream come from the pinned source at tag `v1.4.3`, commit `37a15d99231042b3ff5a4401fed479fdbec9effe`, and from the research notes.

Two kinds of proof are kept apart below. **Built output verified** means it was checked in the build output or by running the image (`docs/evidence/branding/`). **Seen on `plane-dev`** means it was checked on the deployed platform on 2026-11-05 ([the browser session](evidence/branding/live-dev/README.md)), on the images built from `1563cbf`, unless the row names a later record. What neither has checked says so in its row.

## Status at a glance

| Item | State on 2026-11-05 |
|---|---|
| Modified Plane code in this repository | Committed: `apps/wayline/` holds the upstream pin, overlay, patches, codemod, runtime and checks. Images build from it |
| Images in the rendered manifests | Both environments run the four branded images by digest from `localhost:5001/wayline`, built from `84b63d9`: web `3d7575a1`, admin `ce7adc37`, space `5f0119ff` and a flattened backend `8c04bd18`, with upstream's `live` image unmodified (`helm/plane/overlays/*/kustomization.yaml`, [digests](evidence/branding/digests-confirmed.txt)) |
| Who can reach the deployment | The owner, on loopback only (`127.0.0.1:80`, `:443`, [readings](evidence/security/README.md#host-listeners)) |
| `/source` offer | Built output verified, and through Traefik in both environments: the web image answers it with a 302 to `84b63d9`, the commit that built it. **Dead today**: with no credentials that target answers 404, because the repository is private. The commit is on GitHub ([record](evidence/ci/br-3-20261105T054812Z-source-logged-out.txt)) |
| Repository visibility | **Private** (`BereketAbera/plane-platform`). Anonymous requests get 404 (checked 2026-11-05, [record](evidence/ci/br-3-20261105T054812Z-source-logged-out.txt)) |
| `LICENSE`, `COPYRIGHT.txt` and `NOTICE.md` at this repository's root | Present. `LICENSE` and `COPYRIGHT.txt` are upstream's text, byte-identical |
| Licence texts in images | Built output verified: every image has them at `/usr/share/licenses/wayline/`. Seen on `plane-dev`: the web image serves them at `/licenses/` |
| Conveying to others | None known, and whether a private package counts is for counsel. `images.yml` published four modified images from `9c8e098` to the owner's GHCR namespace (`ghcr.io/bereketabera/wayline`), the one destination `publish-gate.sh` allows besides the local registry ([what the run published](evidence/ci/ci-4-20261105T060219Z-published-compare.txt)). They are not the images running, which were built on this Mac. With no credentials all four answer 401 ([who can read them](evidence/ci/ci-4-20261105T055033Z-ghcr-visibility.txt)). The gate does not read package visibility, so making the repository public no longer stops publishing, and the API that states a package's visibility was not read, because the local token lacks `read:packages` |

Contract section 5 states the end state: branded images at `localhost:5001/wayline/{web,admin,space,backend}`. Those are modified versions, and both environments run them, so everything below applies now.

## The licence

| Fact | Basis |
|---|---|
| `LICENSE.txt` at `v1.4.3` is AGPLv3 | `plane-app.md`, a diff against the FSF text shows trivial differences in the how-to-apply appendix |
| No section 7 additional terms | Same diff. So there is no "Powered by Plane" attribution term |
| Source files carry `SPDX-License-Identifier: AGPL-3.0-only` | `git grep` on the tag, 3,804 files on 2026-11-04. `plane-app.md` says 3,805, `plane-branding.md` says 3,804 |
| One file carries a commercial header | `apps/api/plane/utils/email.py`, below |
| No `TRADEMARK` or `NOTICE` file upstream | `plane-app.md` |
| The Helm chart | AGPL-3.0 by `artifacthub.io/license` annotation only. There is no LICENSE file in the chart repository (`plane-helm.md`). `helm/plane/vendor/` is kept byte-identical, as the contract requires |

## Section 13: network use

A modified version "must prominently offer all users interacting with it remotely" an opportunity to receive its Corresponding Source, from a network server, at no charge (`LICENSE.txt`, section 13).

### When it applies here

The author's reading, to confirm with counsel:

| Situation | Section 13 triggered? |
|---|---|
| Unmodified upstream images configured through env vars, Helm values, ingress, and NetworkPolicies | Probably not, since it is triggered by modifying the Program. Configuration is unlikely to be modification |
| Patched or derived images, including frontend bundles rebuilt from patched source and a derived backend image | Yes |
| Modified version reached only by the owner on loopback | This is the state today. No other users exist to offer it to, so it has no practical effect. The offer is still built, so the design can be tested before Pass 2 |
| Modified version reached by anyone else, including a tester or a colleague | **Yes. The offer must work for them** |

Sitting behind a proxy or Cloudflare probably does not change the analysis. The FSF FAQ has an entry on this (`#AGPLProxy`, cited in `plane-branding.md`), and counsel should read it.

### What the offer must lead to

Corresponding Source is defined in section 1 and includes scripts used to build and install. For this project:

| Part | Location | State |
|---|---|---|
| Pinned upstream ref | Contract section 1, `apps/wayline/UPSTREAM` | Recorded in both, same commit |
| Patches, overlay, codemod | `apps/wayline/{patches,overlay,codemod}` | Committed |
| Dockerfiles and build scripts | `apps/wayline/`, `scripts/ci/build-images.sh`, `scripts/lib/common.sh` | Committed. The stamped commit in `/source` is the one that built the context, and a push refuses a context whose source has since changed |
| Deployment configuration | This repository | Not strictly the Program's source, but publishing it is the simple way to avoid arguing about it |
| Fully patched tree as a release tarball, or a mirror of the pinned upstream commit | **Not built.** The tree at `/source` holds patches and a pinned ref, not upstream's source, so complete source depends on upstream's GitHub staying up. Do this before the repository goes public | Safer (`plane-branding.md`) |

Existing upstream GitHub links in the UI, such as `star-us-link.tsx`, point to unmodified upstream and do not satisfy this.

### The `/source` offer on each surface

A small "Source code" link, in places that already hold version or footer information. It targets `/source`, an nginx `return 302` in the web runtime image, resolved at image build time to the commit that built the client. Built output verified means the link is in the built bundle and the image answers the redirect. Nobody has yet followed it to working source on the deployed platform, because of [the private repository](#the-private-repository-caveat).

| Audience | Surface | Where | Built output | Runtime |
|---|---|---|---|---|
| Signed-in users | Help menu, above the version line | `patches/30-surfaces.patch`, `help-section/root.tsx` | Verified, and rendered against a stub API | Not tested in Pass 1 |
| Before sign-in | Auth footer, replacing the customer logo strip | `patches/20-auth.patch`, `auth-screens/footer.tsx` | Verified, and rendered | Seen on `plane-dev` ([screenshot](evidence/branding/live-dev/01-sign-in-dark.jpg)) |
| God-mode admins | Help section, and admin sign-in | `patches/40-admin.patch`, `overlay/.../(home)/auth-split.tsx` | Verified, and rendered at sign-in | Admin sign-in seen on `plane-dev` ([screenshot](evidence/branding/live-dev/07-admin-sign-in.jpg)). The help section inside god-mode was not opened. Not tested in Pass 1 |
| Anonymous public pages | Corner badge, repurposed | `patches/50-space.patch`, `powered-by.tsx` | Verified | Seen on `plane-dev` while signed in, on the `/spaces/` landing page ([screenshot](evidence/branding/live-dev/09-public-space.jpg)). No anonymous view of a public page has been checked on the branded images, and a published board with real content was not opened. Not tested in Pass 1 |
| API clients, optional | `Link: <url>; rel="source"` at ingress | Traefik middleware | Not built | Unverified: nobody has decided whether to add this header, and nothing has tested it. Check it at the start of Pass 2 |
| The route itself | `/source` | `runtime/nginx-web.conf` | Verified by `checks/smoke-images.sh`: 302 to `<repo>/tree/<commit>` | Through Traefik in both environments, `curl -I` with no session answers 302 to the tree at `84b63d9`, the commit that built the deployed images, and that target answers 404 with no credentials ([record](evidence/ci/br-3-20261105T054812Z-source-logged-out.txt)). BR-3 is FAIL. No browser has followed it |

The `/source` path and the Plane routing coexist. `source` is a reserved workspace slug in both the frontend and backend lists, and no router link may point at `/source` (`checks/source-links.mjs`). Traefik routes it to the web container: that 302 comes from the branded image, where upstream's image answered 200 with the app's page ([plane-dev-branded-images-1.txt](evidence/runs/plane-dev-branded-images-1.txt)).

### The private repository caveat

`origin` is a private GitHub repository. **Before anyone other than the owner uses an instance, the repository must be public, or the source must be offered another way.** A `/source` link to a private repository returns a 404 to everyone without access, which is not an offer. Making it public is not enough on its own: the commit an image names must also be pushed, which is why `scripts/ci/build-images.sh` warns when it is not on `origin/main`. `84b63d9` is pushed. `WAYLINE_REQUIRE_PUBLIC_SOURCE=yes checks/smoke-images.sh` follows the link logged out and fails unless it answers 200.

| Option | Notes |
|---|---|
| Make the repository public | Simple, and also unlocks protected branches and environment reviewers on GitHub Free (`cicd-security.md`). Run `gitleaks` over the full history first |
| Serve a source tarball from the deployment | Keeps the infrastructure repository private. Must be complete, must match the running version, and must be rebuilt on each change |

This does not bite in Pass 1, which is local and owner-only. It blocks Pass 2, and is a gate in the [handoff](../PASS2_HANDOFF.md#9-agpl-section-13). Until then, any screenshot or docs statement showing `/source` should say that the target is not yet public.

## Section 5: conveying

Section 5 applies when modified source is conveyed, and sections 4 to 6 cover copies generally. Running a modified version privately is not conveying. These events are:

| Event | Conveying? | Consequence |
|---|---|---|
| Pushing to the local registry | No | |
| Pushing a modified image to private GHCR with only the owner's access | Probably not. Confirm | This has happened: run 41975430939 pushed four images, and with no credentials they answer 401 ([who can read them](evidence/ci/ci-4-20261105T055033Z-ghcr-visibility.txt)). Nothing shows who else holds access. Check suites from two third-party GitHub Apps sit queued on pushed commits of the repository, and what each installation covers was not read ([record](evidence/ci/br-3-20261105T060937Z-apps.txt)) |
| Pushing a modified image to public GHCR | Yes | Section 5 notices, section 6 source. The gate checks the namespace and not the visibility, so nothing stops this. GitHub's documentation reads two ways on whether a package a workflow creates takes its repository's visibility, so read each package's visibility again before the repository goes public |
| Making this repository public once it holds patches | Yes | Section 5 notices |
| Handing an image or tarball to anyone | Yes | Same |

What section 5 asks of the modified work:

| Requirement | Plan | State |
|---|---|---|
| Prominent notices that it is modified, with a relevant date | `NOTICE.md`, `apps/wayline/MODIFICATIONS.md`: modified from Plane v1.4.3, by whom, when | Written, and in every image |
| Notice that it is released under this licence | Root `LICENSE`, `NOTICE.md`, and headers on new files | Written. `LICENSE` and the font licences are in every image (section 4 and OFL 1.1) |
| Whole work licensed under the AGPL | New source files get an AGPL-3.0-only header | Applied, with the exceptions named in `MODIFICATIONS.md`: JSON manifests and other generated data, binaries, third-party licence texts |
| Appropriate Legal Notices on interactive interfaces | Upstream's UI shows none, and the licence does not then oblige a modified version to add them (`plane-branding.md`). The source link is still required under section 13 | Not applicable |

## Preserved notices

| Must keep | Rule |
|---|---|
| `LICENSE.txt`, `COPYRIGHT.txt` | At this repository's root (`LICENSE`, `COPYRIGHT.txt`), so in the source offer, and in every image |
| SPDX and copyright headers | `Copyright (c) 2023-present Plane Software, Inc. and contributors`. The codemod must never touch these lines |
| Licences of bundled fonts | Upstream's Inter, Figtree, Geist, and Instrument Sans are OFL-1.1, per `plane-branding.md`. Wayline vendors Instrument Sans and JetBrains Mono under `apps/wayline/overlay/packages/tailwind-config/fonts/`, with their OFL texts and `SOURCES.txt`. Keep those with the fonts |
| The name "Plane" in source and notices | Branding removes it from the UI. It must stay in notices, source headers, and this documentation |

`checks/leak-scan.sh` runs on every build and fails on any brand string it has no stated reason for. Removed or changed header lines against the tag are recorded in `docs/evidence/branding/headers.txt`, run by hand: `git -C .build/plane-src diff <tag> | grep -E '^-.*(SPDX|Copyright)'`.

## The commercial header in `email.py`

At tag `v1.4.3`, `apps/api/plane/utils/email.py` is headed `SPDX-License-Identifier: LicenseRef-Plane-Commercial`, and states it is proprietary and that its notice must not be removed. It is the only such file in the tree. It is a small plain-text helper imported by every email task, so it ships in the upstream `plane-backend` image and in any image derived from it.

| Fact | Status |
|---|---|
| Header on the tag | Read directly on 2026-11-04 |
| Upstream treats it as a mistake | Issue #9595 (closed), and commit `3e44777e6c` (PR #9865), which switches it to AGPL-3.0-only on `preview`, 2026-09-22 |
| Upstream's later changes on `preview` | `297c3fdf2a` (#9841) decodes character references in the text part, and `86d9b158fa` (#10053, a security fix) strips style blocks in linear time |
| Upstream releases | On 2026-11-05 the latest release is `v1.4.3`. It and `master` still carry the commercial header. Only `preview` carries AGPL-3.0-only (read from each ref) |

**What was done, recorded as D12 in the [handoff](../PASS2_HANDOFF.md#12-open-decisions): the notice is not edited. The backend image replaces the file with upstream's own AGPL-3.0-only version from `preview`, pinned by commit, and the image is flattened, so that what is published holds no layer with the original.**

**Who chose this.** No person did. The agent coordinating the work chose to replace the file, under the owner's rule against using commercial-only assets without authorization, and an AI coding agent implementing the image made that change. The coordinating agent then required the flattening, under the same rule. It also removed the requirement that the repository be private, because no layer holds the original. The repository's owner, Bereket Abera, was told of all three in progress messages, each after it was decided. He has not reviewed them, and has not authorized the original file. No lawyer or other legal reviewer has looked at any of it, so this records what was done and is not a legal claim either way ([the full record](../apps/wayline/MODIFICATIONS.md#d12-the-one-file-with-a-commercial-license-header)). The first push of `apps/wayline` to `main` went ahead on 2026-11-05 at 05:39Z, and it published, with that review still open.

| What was done | Where |
|---|---|
| Upstream's file at `86d9b158fa4edd0c5deebb29367b5dd9b821716f`, unchanged, sha256 `620fe6f7396669e20af5659611189618bf55ac563b1ccfd8a473cc4e95a2dbda`. It fits every caller at `v1.4.3`: 11 modules import only `generate_plain_text_from_html`, with one argument | `apps/wayline/backend/vendor/email.py`, `email.py.pin` |
| Copied over the original in the image's first stage | `apps/wayline/runtime/Dockerfile.backend` |
| The image build stops if any file in that stage's filesystem contains `LicenseRef-Plane-Commercial`, or if this file is not that AGPL-3.0-only version | `apps/wayline/backend/check_image.py --build-time` |
| The last stage is `FROM scratch` and copies that filesystem, so the image has one layer holding it and BuildKit's empty layer for `WORKDIR`. Both environments run this image | `apps/wayline/runtime/Dockerfile.backend`, `apps/wayline/checks/flatten-config.py`, `docs/evidence/branding/flatten-compare-final.txt` |
| Every layer of each image built here is read in a throwaway registry before anything is published, and again as the target serves it, and an image with a hit records no digest | `apps/wayline/checks/layer-check.py`, `scripts/ci/build-images.sh` |
| The image's license label is `AGPL-3.0-only` | `apps/wayline/runtime/Dockerfile.backend` |
| The file renders mail from the real templates, in the image, and a mail went through it to a scratch SMTP server and back | `docs/evidence/branding/smoke.txt`, `backend-db.txt` |
| Publishing is limited to the local registry and the owner's GHCR namespace, and for anywhere else the job fails. A pending or unknown value in the decision file publishes only to the local registry. The gate does not read visibility, so making the repository public no longer stops publishing | `apps/wayline/backend/email-py-decision.txt`, `apps/wayline/scripts/publish-gate.sh`, `.github/workflows/images.yml` |

**What runs today.** Both environments run backend `8c04bd18`, built from `84b63d9`. It is flattened. A walk of every layer of the four images read 0 hits ([record](evidence/branding/layer-check.txt)), and the running path holds the AGPL-3.0-only file ([email-py.txt](evidence/branding/email-py.txt)). Run 41975430939 did the same walk on what it published from `9c8e098`, before and after publishing, with 0 hits ([what the run published](evidence/ci/ci-4-20261105T060219Z-published-compare.txt)). Upstream's image is still an input to that build, which downloads it and does not republish it. The unflattened image from `1563cbf`, `4add277c`, is still in the local registry on this Mac ([read 2026-11-05](evidence/security/README.md#host-listeners)), deployed nowhere, and its upstream base layers hold the original file. Promoting or rolling back to that digest would run it again.

**What a walk of the layers found, on 2026-11-05.** The images this platform deploys unmodified were read for the identifier too ([record](evidence/branding/layer-check-deployed.txt), [`live`](evidence/branding/layer-check-live.txt)). The only hit is `email.py`, in two layers of upstream's `plane-backend`, which is a build input and which no environment runs now. The same two layers are in `4add277c` ([earlier record](evidence/branding/layer-check-deployed-images.txt)). Those walks read the images and say nothing about whether anything is cleared.

**What remains for the owner before a public launch.** D12 itself, since nobody has reviewed it. Publishing no longer waits for that: a push to `main` that touches `apps/wayline/` publishes. A public distribution of the image from `1563cbf` would hand out those layers, so it is a point to take advice on. Upstream publishes the same layers publicly itself, which is a fact to give counsel and not a conclusion. The flattened image holds no layer of upstream's, and it is still derived from upstream's image as a build input, which says nothing about whether anything is cleared. Moving to an upstream release that carries the AGPL header would end the need for the replacement and the flattening, and no such release exists yet. Sending images anywhere else means a new value in `email-py-decision.txt` and a change to `publish-gate.sh`.

Source is a separate matter. `apps/wayline/UPSTREAM` pins `v1.4.3`, whose tree holds the commercially headed file, so the source offer names that tree. This repository does not copy the original, and it holds the AGPL version in `backend/vendor/`.

## Other AGPL components

Unmodified, but relevant if the deployment is offered to others or images are redistributed.

| Component | Licence | Note |
|---|---|---|
| Silo (`pgsty/silo`) | AGPL-3.0-or-later, by the label on the pinned image ([scan record](evidence/security/scan-images-20261104T215437Z/images/docker.io_pgsty_silo_RELEASE.2026-10-26T00-00-00Z-distroless_e6544a902f42.json)) | MinIO-compatible fork, unmodified |
| Grafana 13.3.0 | AGPL-3.0, by the top-level [`LICENSE` at tag `v13.3.0`](https://github.com/grafana/grafana/blob/v13.3.0/LICENSE), read 2026-11-05 | Unmodified. The file inside the pinned image was not read, and the repository's other licence files were not reviewed |
| Loki 3.7.9 | AGPL-3.0, by the top-level [`LICENSE` at tag `v3.7.9`](https://github.com/grafana/loki/blob/v3.7.9/LICENSE), read 2026-11-05 | Unmodified. The file inside the pinned image was not read, and the repository's other licence files were not reviewed |

Unverified: a full inventory of the licences of the pinned images and charts has not been done. Check it at the start of Pass 2.

## Trademark position (not legal advice)

The AGPL licenses code, not a name or a logo. That is why the product has a distinct name, and why documentation says what it is based on.

| Question | Finding | Confidence |
|---|---|---|
| Trademark or logo policy in the repository? | None found | Read in the repository (`plane-branding.md`) |
| On plane.so? | Terms updated 2026-04-09 reserve IP in the service generally and do not address CE. `plane.so/open-source` has no brand terms | Read through a summarising fetch, not in full |
| Registrations | A third-party aggregator lists serial 99169453 (Plane Software, Inc., filed 2025-05-05) as dead or abandoned, and an unrelated registration for another owner | **Unverified.** USPTO TSDR was not checked |
| White-labelling | A contributor said on issue #4272 that it would be an Enterprise plan feature. This is a commercial position, not a licence term | Issue comment |

Practical position: treat the name and logo as off limits for the product identity, whatever a registry says.

**Do not reuse in the product:** "Plane", "Plane Publish", "Plane Pages", "Plane AI", "Galileo", "Plane Pro" or "Plane Business". The logo set, takeoff marks, and spinner GIFs. `media.docs.plane.so` hotlinks and upstream's support addresses. Plane's Terms and Privacy pages. Customer logos and the "10,000+ teams" claim. Any confusingly similar name or mark.

**Fine, and required here:** a factual "based on Plane Community Edition, AGPL-3.0" statement in the repository, `NOTICE.md`, and documentation. The owner requires the application be documented as a customized Plane Community Edition deployment. A factual statement of origin is not branding.

Items to settle with counsel before a public launch: the public hostname, since `plane.dev.localhost` is local-only and a public `plane.` host would use the upstream name (D9 in the handoff), and internal names such as the `plane-dev` namespace, which users do not see.

Unverified: whether Wayline itself is free to use as a name has not been checked, and no trademark search has run in any class. Check it at the start of Pass 2.

## Telemetry

Not an AGPL matter, but it belongs in any honest account of what a deployment sends upstream.

| Fact | Source at `v1.4.3` |
|---|---|
| `Instance.is_telemetry_enabled` defaults to `True` | `apps/api/plane/license/models/instance.py:35` |
| Upstream's setup form pre-ticks it, and its parameter always ends true | `apps/admin/components/instance/setup-form.tsx:57,67` (`... \|\| true`), changed by `patches/40-admin.patch` |
| Target and interval | `https://telemetry.plane.so`, OTLP, every 360 minutes by default (`plane-app.md`) |
| Contents | Instance ID, name, domain, versions, per-workspace counts (`plane-app.md`) |
| Other call | `register_instance.py` fetches the latest release from `api.github.com` |

What this platform does:

| Control | Where | State |
|---|---|---|
| Create the admin with `is_telemetry_enabled=False`, then check it | `step_instance_setup` in `tests/e2e/smoke.py` | PASS: the instance API read telemetry off when each admin was created, on upstream images, in [dev](evidence/runs/smoke-dev-20261104T221730Z.json) and [prod-sim](evidence/runs/smoke-prod-sim-20261104T231359Z.json) |
| Deny the egress | `gitops/platform/network-policies/plane-{dev,prod-sim}.yaml` (no internet route) | PASS: rows from api and worker to `telemetry.plane.so` time out in [dev](evidence/runs/netpol-20261104T232752Z.tsv) and [prod-sim](evidence/runs/netpol-20261104T233304Z.tsv) |
| A branded default of off | `apps/wayline/patches/40-admin.patch`, `backend/edit_strings.py` | Built output verified: the setup form starts unticked with no `\|\| true`, and instance registration writes false. God-mode on `plane-dev` shows telemetry off ([screenshot](evidence/branding/live-dev/08-admin-general.jpg)), but for an admin the smoke test created through the API. An admin created through the UI was not tested in Pass 1 |

An instance that already exists keeps its stored setting. In Pass 2 the API may gain outbound paths (SMTP, self-dial), so re-check the egress denial. Infisical's and Grafana's own telemetry are off in `helm/values/`.

## Checklist before the first other user

- [x] Root `LICENSE` (AGPL-3.0), `COPYRIGHT.txt` and `NOTICE.md` committed.
- [x] `apps/wayline` committed and complete, with patches, codemod, overlay, Dockerfiles, and build instructions. It is pushed. Someone else following them is a separate item below.
- [x] Upstream headers unchanged by the codemod, by diff against the tag. `docs/evidence/branding/headers.txt` reads 0 removed notice lines.
- [ ] The owner's decision on `email.py` (D12) recorded. Agents applied the replacement and the flattening, and removed the requirement that the repository be private, and `apps/wayline/backend/email-py-decision.txt` names that. The owner has not reviewed it, and no legal reviewer has, [above](#the-commercial-header-in-emailpy).
- [ ] Each GHCR package's visibility read after its first publish, and again before the repository goes public. After the first publish, with no credentials, all four answer 401 ([who can read them](evidence/ci/ci-4-20261105T055033Z-ghcr-visibility.txt)). The API that states visibility has not been read, and the gate does not read it.
- [ ] Repository public, or a complete source tarball served. `gitleaks` clean over full history.
- [ ] A tarball of the patched tree or a mirror of the pinned upstream commit published, and linked from `NOTICE.md`.
- [x] The commit each running image names is pushed. `84b63d9` is on GitHub ([record](evidence/ci/br-3-20261105T054812Z-source-logged-out.txt)). Check again at each promotion.
- [ ] `/source` followed logged out from a browser returns 200, on every surface above, and lands on the deployed commit. `WAYLINE_REQUIRE_PUBLIC_SOURCE=yes apps/wayline/checks/smoke-images.sh` checks the redirect's target.
- [ ] A person outside the project followed the link and rebuilt, or the attempt is recorded.
- [x] Telemetry off and egress denied, on the deployed instances, by API and by the matrix, as above. Check again after any new egress in Pass 2, and for an admin made through the UI.
- [ ] Counsel has read this page.

See [known limitations](known-limitations.md).
