# Promotion evidence

Each `<set-hash>.json` here says plane-dev ran an exact set of image digests and that its smoke passed against those
containers. `<set-hash>.json.sig` is the signature. Nothing reaches hosted production without one: `scripts/ci/check-prod-evidence.sh`
refuses any render whose images are not exactly one signed set.

Do not edit these. An edited file no longer verifies, and that is the point. Do not delete one either: a rollback to that set
needs it, and so do the files under `docs/evidence/runs/` they name, and the images on GHCR.

## The flow

1. `images.yml` builds plain linux/amd64 manifests and opens a digest bump for dev. A person starts its held `ci` run and merges it with a merge commit once `Lint`, `Manifests` and `Security` pass.
2. `scripts/ci/copy-to-local-registry.sh ghcr.io/bereketabera/wayline dev`, `make gitops-publish`, `make test-e2e ENV=dev`,
   `make publish-evidence`. Dev runs the exact bytes, under Rosetta.
3. `make record-dev-evidence` writes the two files here, and refuses unless all of it holds. The script's header lists every
   condition. Commit them with the published smoke on a branch, open a pull request, and merge it with a merge commit once `Lint`,
   `Manifests` and `Security` pass.
4. `gh workflow run promote-plane-prod.yml -f set_hash=<set-hash>` checks the change and opens a pull request. Like step 1's, it
   starts no checks until a person approves or re-runs its held `ci` run. A person merges it with a merge commit once `Lint`,
   `Manifests` and `Security` pass, and that merge is the approval.
5. `ci.yml`'s `release-plane-prod` job checks the merged commit, reads each Wayline digest on GHCR, and moves `deploy/plane-prod`,
   the only branch hosted Argo CD reads. If it fails, the branch stays where it is.

A rollback is a revert through a pull request, or step 4 with an older hash. The older set still has its evidence, so the gate passes. Neither
reverts the database: a migration that set ran stays applied, and `scripts/hosted/README.md` has the restore path.

The first promotion is the one a revert does not undo. It would take Application plane-prod away, and root would prune it, leaving Plane
running unmanaged with its availability alerts quiet. So `scripts/ci/publish-release.sh` refuses to go from a promoted set back to none,
and the branch stays where it is. Promote another set, or revert the revert.

## The file

`set_hash` is the sha256 of the sorted, unique lines `<production repository>@<digest>`, each ending in a newline, one for each
image. A tag does not count, because the runtime pulls by digest. It is also the file's name, and the check computes it from the
render, so the render finds its file and a file cannot claim another set.

| Field | What it says |
|---|---|
| `schema` | 1 |
| `environment`, `executed_under` | `plane-dev`, `rosetta-on-arm64`: same bytes, emulated CPU |
| `argo_revision` | The commit Argo CD had plane-dev at. It must be in the history of whatever is promoted, and its dev overlay must name these digests |
| `smoke` | The published smoke JSON: its path, sha256, `result`, `branding_overlay`, `started_at`, `finished_at` |
| `images[].kind` | `branded`, or `upstream-index` |
| `images[].containers` | Each container that ran it, by imageID, with `started_at`. All from before the smoke began, except one with `replaced_by_smoke`: dev's smoke replaces the worker's pod on purpose (`scripts/test.sh`), so that one started during it, and the backend image must have others from before |
| `images[].platform`, `media_type`, `revision`, `built_by_run` | Branded only: plain linux/amd64 on GHCR, its `org.opencontainers.image.revision` label, the `images.yml` run that names the digest in its log |
| `images[].dev_ran`, `production_runs` | Upstream only: the index's linux/arm64 child ran in dev, and production runs its linux/amd64 child, which dev never ran |

## What this does and does not prove

The signature says the holder of `~/.ssh/wayline_evidence_ed25519` signed this. That key stays on the laptop, so nothing in CI can
mint evidence. It does not say the smoke was honest, and the check cannot tell. It reads the signed claims, the published smoke
and Git history, and it asks no cluster.

**Evidence covers the render and nothing else.** That is `gitops/environments/prod/manifests.yaml`, and it says nothing about Traefik,
cert-manager, monitoring, Infisical or the backup Jobs, none of which ran in dev as these do here. Outside the render the check
refuses what Argo CD would act on and nothing reads: a symlink, an override on a source, an Application anywhere but `applications/`,
and anything else in `applications/`. It finds a Wayline image outside the render only by its name, so another name for the same build
would need no evidence. `scripts/ci/validate-manifests.sh` holds every image there to `policy/hosted-images.txt`, which makes a new or
renamed one a diff a person reads, and no more than that.

`.github/evidence-signers` is read as the commit under test holds it. The ruleset on `main` requires no reviewer and does not cover
`deploy/plane-prod`, so anyone with write access can change that file and the check in one pull request, push `deploy/plane-prod`
directly, or merge unread. Nothing here can stop
any of that, and it can only notice a push: `publish-release.sh`, `check-deploy-branch.yml` each day and `make remote-status` go red if
the branch differs from what its `RELEASE.json` says, and by then Argo CD may have deployed it.

So all of this deserves the same reading as a change to production, and none of it is more than a process while no review is required and no rule covers `deploy/plane-prod`. The check and
the signers are not all of it: whatever runs in the release job could mint the same result. That is `.github/workflows/ci.yml`,
`scripts/ci/publish-release.sh`, `scripts/ci/lib-release-branch.sh`, `scripts/lib/common.sh`, `scripts/install-tools.sh`, `tools.lock` and
`.tools`, which the check and `publish-release.sh` refuse to find tracked. See `.github/workflows/README.md`.
