# AGPL compliance

**This is engineering analysis, not legal advice. Have counsel review it before any public launch.**

Wayline is a customized deployment of open-source Plane Community Edition v1.4.3. It is not an original product. Plane is copyright Plane Software, Inc. and contributors, and licensed under AGPL-3.0-only. This page records what that means here, what is done, and what is not done.

Written 2026-11-04, against commit `f733b87` and the uncommitted `apps/wayline/` as it stood at 23:16 local time. Facts about upstream come from the pinned source at tag `v1.4.3`, commit `37a15d99231042b3ff5a4401fed479fdbec9effe`, and from the research notes. Anything about the running system carries a `VERIFY` marker.

## Status at a glance

| Item | State when written |
|---|---|
| Modified Plane code in this repository | **Partial, in progress, uncommitted.** `apps/wayline/` holds the upstream pin, brand CSS, vendored fonts, and check scripts. `patches/`, `codemod/`, `runtime/`, and `scripts/` are empty, and there is no `images.txt`, so nothing can be built yet |
| Images in the rendered manifests | Unmodified upstream `docker.io/makeplane/*` by digest (`helm/plane/overlays/*/kustomization.yaml`) |
| Who can reach the deployment | The owner, on loopback only (`127.0.0.1:80`, `:443`) |
| `/source` offer | Not implemented |
| Repository visibility | Private (`BereketAbera/plane-platform`) |
| `LICENSE` and `NOTICE` at this repository's root | **Missing.** `git ls-files` finds no licence or notice file |
| Conveying to others | None known. GitHub Actions can push to GHCR, and that visibility matters (below) |

[[VERIFY: at reconciliation, update this table for apps/wayline, the deployed image references, /source, and the root LICENSE and NOTICE files]]

Contract section 5 states the intended end state: branded images at `localhost:5001/wayline/{web,admin,space,backend}`. Those are modified versions, so everything below applies once they run.

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
| Modified version reached only by the owner on loopback | No other users exist to offer it to, so it has no practical effect. The offer is still built, so the design can be tested before Pass 2 |
| Modified version reached by anyone else, including a tester or a colleague | **Yes. The offer must work for them** |

Sitting behind a proxy or Cloudflare probably does not change the analysis. The FSF FAQ has an entry on this (`#AGPLProxy`, cited in `plane-branding.md`), and counsel should read it.

### What the offer must lead to

Corresponding Source is defined in section 1 and includes scripts used to build and install. For this project:

| Part | Location | State |
|---|---|---|
| Pinned upstream ref | Contract section 1, `apps/wayline/UPSTREAM` | Recorded in both, same commit |
| Patches, overlay, codemod | `apps/wayline/{patches,overlay,codemod}` | Overlay CSS and fonts present, uncommitted. Patches and codemod empty |
| Dockerfiles and build scripts | `apps/wayline/`, `scripts/ci/build-images.sh` | Build script present. It exits without building until `apps/wayline/images.txt` exists |
| Deployment configuration | This repository | Not strictly the Program's source, but publishing it is the simple way to avoid arguing about it |
| Fully patched tree as a release tarball | Not built | Safer than depending on upstream's GitHub staying up (`plane-branding.md`) |

Existing upstream GitHub links in the UI, such as `star-us-link.tsx`, point to unmodified upstream and do not satisfy this.

### The `/source` offer on each surface

Design from `plane-branding.md`: a small "Source code" link, reusing places that already hold version or footer information. It targets `/source`, an nginx `return 302` in the web runtime image, so the target can change without a rebuild. It should resolve to the exact commit of the running build.

All of this is a plan. `apps/wayline/patches/` and `runtime/` are empty as of this writing, so none of it exists yet. File paths are upstream's at `v1.4.3`.

| Audience | Surface | Upstream file to patch | Proof required |
|---|---|---|---|
| Signed-in users | Help menu, beside the version line | `apps/web/core/components/workspace/sidebar/help-section/root.tsx:87` | [[VERIFY: source link is visible in the help menu when signed in]] |
| Before sign-in | Auth footer, replacing the customer logo strip | `apps/web/core/components/auth-screens/footer.tsx` | [[VERIFY: source link is visible on the sign-in page]] |
| God-mode admins | Help section beside version, and admin sign-in | `apps/admin/app/(all)/(dashboard)/sidebar-help-section.tsx:139` | [[VERIFY: source link is visible in god-mode and on its sign-in page]] |
| Anonymous public pages | Corner badge, repurposed | `apps/space/components/common/powered-by.tsx` | [[VERIFY: source link is visible on a public space page]] |
| API clients, optional | `Link: <url>; rel="source"` at ingress | Traefik middleware | [[VERIFY: decide on and test the API source header]] |
| The route itself | `/source` | Web runtime nginx config | [[VERIFY: /source returns a redirect to the exact deployed commit, from a logged-out browser]] |

The `/source` path and the Plane routing need to coexist. The chart's route for the web app must reach this path. [[VERIFY: Traefik routes /source to the web container in the rendered IngressRoute]]

### The private repository caveat

`origin` is a private GitHub repository. **Before anyone other than the owner uses an instance, the repository must be public, or the source must be offered another way.** A `/source` link to a private repository returns a 404 to everyone without access, which is not an offer.

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
| Pushing a modified image to private GHCR with only the owner's access | Probably not. Confirm | `images.yml` does this on `main` |
| Pushing a modified image to public GHCR | Yes | Section 5 notices, section 6 source |
| Making this repository public once it holds patches | Yes | Section 5 notices |
| Handing an image or tarball to anyone | Yes | Same |

What section 5 asks of the modified work:

| Requirement | Plan | State |
|---|---|---|
| Prominent notices that it is modified, with a relevant date | `NOTICE.md`: modified from Plane v1.4.3, by whom, when | Not written |
| Notice that it is released under this licence | Root `LICENSE`, `NOTICE.md`, and headers on new files | Headers present on the new CSS (`Copyright (c) 2026 Bereket Abera`, `AGPL-3.0-only`). `LICENSE` and `NOTICE.md` not written |
| Whole work licensed under the AGPL | New files get an AGPL-3.0-only header | Applied to the overlay CSS read. [[VERIFY: every new file under apps/wayline carries an AGPL-3.0-only header or a stated third-party licence]] |
| Appropriate Legal Notices on interactive interfaces | Upstream's UI shows none, and the licence does not then oblige a modified version to add them (`plane-branding.md`). The source link is still required under section 13 | Not applicable |

## Preserved notices

| Must keep | Rule |
|---|---|
| `LICENSE.txt`, `COPYRIGHT.txt` | In the tree and in the source offer |
| SPDX and copyright headers | `Copyright (c) 2023-present Plane Software, Inc. and contributors`. The codemod must never touch these lines |
| Licences of bundled fonts | Upstream's Inter, Figtree, Geist, and Instrument Sans are OFL-1.1, per `plane-branding.md`. Wayline vendors Instrument Sans and JetBrains Mono under `apps/wayline/overlay/packages/tailwind-config/fonts/`, with their OFL texts and `SOURCES.txt`. Keep those with the fonts |
| The name "Plane" in source and notices | Branding removes it from the UI. It must stay in notices, source headers, and this documentation |

[[VERIFY: a leak scan confirms the codemod removed UI strings and changed no SPDX or copyright line, by diffing headers against the tag]]

## The commercial header in `email.py`

At tag `v1.4.3`, `apps/api/plane/utils/email.py` is headed `SPDX-License-Identifier: LicenseRef-Plane-Commercial`, and states it is proprietary and that its notice must not be removed. It is the only such file in the tree. It is a small plain-text helper imported by several email tasks, so it ships in the upstream `plane-backend` image and in any image derived from it.

| Fact | Status |
|---|---|
| Header on the tag | Read directly on 2026-11-04 |
| Upstream treats it as a mistake | Issue #9595 (closed) and PR #9865, which switches it to AGPL-3.0-only, merged into `preview` on 2026-09-22, per `plane-app.md` |
| `v1.4.3` and `master` | Still carried the commercial header when researched |

Why it matters: if source or images are conveyed, this file goes with them, under a header that conflicts with the rest of the tree.

| Option | Note |
|---|---|
| Leave the file untouched, and document it | Honest and minimal. Does not resolve the conflict |
| Apply upstream's PR #9865 change as a named patch, citing the PR | Follows upstream's own stated fix. Changes a notice that says not to change it |
| Move to an upstream release carrying the fix | Cleanest. Requires a version change |

**Decision: open, and for the owner with legal advice.** Do not strip the header silently, and do not let a codemod alter it. Recorded as D12 in the [handoff](../PASS2_HANDOFF.md#12-open-decisions). [[VERIFY: whether a newer upstream release carries the AGPL header on email.py]]

## Other AGPL components

Unmodified, but relevant if the deployment is offered to others or images are redistributed.

| Component | Licence | Note |
|---|---|---|
| Silo (`pgsty/silo`) | AGPL-3.0, per `critique` section 1.5 | MinIO-compatible fork, unmodified |
| Grafana | AGPL-3.0 from memory | [[VERIFY: Grafana licence at the pinned version]] |
| Loki | AGPL-3.0 from memory | [[VERIFY: Loki licence at the pinned version]] |

A full inventory of the platform's licences has not been done. [[VERIFY: licence inventory for all pinned images and charts]]

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

Whether Wayline itself is free to use as a name has not been checked. [[VERIFY: trademark search on the name Wayline in relevant classes]]

## Telemetry

Not an AGPL matter, but it belongs in any honest account of what a deployment sends upstream.

| Fact | Source at `v1.4.3` |
|---|---|
| `Instance.is_telemetry_enabled` defaults to `True` | `apps/api/plane/license/models/instance.py:35` |
| The setup form pre-ticks it, and its parameter always ends true | `apps/admin/components/instance/setup-form.tsx:57,67` (`... \|\| true`) |
| Target and interval | `https://telemetry.plane.so`, OTLP, every 360 minutes by default (`plane-app.md`) |
| Contents | Instance ID, name, domain, versions, per-workspace counts (`plane-app.md`) |
| Other call | `register_instance.py` fetches the latest release from `api.github.com` |

What this platform does:

| Control | Where | State |
|---|---|---|
| Create the admin with `is_telemetry_enabled=False`, then check it | `tests/e2e/smoke.py:531-553` | Script exists. [[VERIFY: instance API reports telemetry off after smoke setup in both environments]] |
| Deny the egress | `gitops/platform/network-policies/plane-{dev,prod-sim}.yaml` (no internet route) | Policy exists. [[VERIFY: matrix rows from api and worker to telemetry.plane.so are denied at runtime]] |
| A branded default of off | `apps/wayline/patches/` | Not present, directory empty |

Limit: an admin created by hand through the upstream UI gets telemetry on, because of that `|| true`. Then egress denial is the only control. In Pass 2 the API may gain outbound paths (SMTP, self-dial), so re-check this. Infisical's and Grafana's own telemetry are off in `helm/values/`.

## Checklist before the first other user

- [ ] Root `LICENSE` (AGPL-3.0) and `NOTICE.md` committed.
- [ ] `apps/wayline` committed and complete, with patches, codemod, overlay, Dockerfiles, and build instructions someone else could follow.
- [ ] Upstream headers unchanged by the codemod, by diff against the tag.
- [ ] `email.py` decision made and recorded.
- [ ] Repository public, or a complete source tarball served. `gitleaks` clean over full history.
- [ ] `/source` works logged out, on every surface above, and points at the deployed commit.
- [ ] A person outside the project followed the link and rebuilt, or the attempt is recorded.
- [ ] Telemetry off and egress denied, on the deployed instance.
- [ ] Counsel has read this page.

None of these are checked. See [known limitations](known-limitations.md).
