# Promotion evidence

Each `<set-hash>.json` here says plane-dev ran an exact set of image digests and that its smoke passed against those
containers. `<set-hash>.json.sig` is the signature. Nothing reaches hosted production without one: `scripts/ci/check-prod-evidence.sh`
refuses any render whose images are not exactly one signed set.

Do not edit these. An edited file no longer verifies, and that is the point. Do not delete one either: a rollback to that set
needs it, and so do the files under `docs/evidence/runs/` they name, and the images on GHCR.

## The flow

1. `images.yml` builds plain linux/amd64 manifests and opens a digest bump for dev. A person merges it.
2. `scripts/ci/copy-to-local-registry.sh ghcr.io/bereketabera/wayline dev`, `make gitops-publish`, `make test-e2e ENV=dev`,
   `make publish-evidence`. Dev runs the exact bytes, under Rosetta.
3. `make record-dev-evidence` writes the two files here, and refuses unless all of it holds. The script's header lists every
   condition. Commit them with the published smoke, and push.
4. `gh workflow run promote-plane-prod.yml -f set_hash=<set-hash>` checks the change and opens a pull request. A person merges
   it, and that merge is the approval.
5. `ci.yml`'s `release-plane-prod` job checks the merged commit, reads each Wayline digest on GHCR, and moves `deploy/plane-prod`,
   the only branch hosted Argo CD reads. If it fails, the branch stays where it is.

A rollback is a revert on main, or step 4 with an older hash. The older set still has its evidence, so the gate passes. Neither
reverts the database: a migration that set ran stays applied, and `docs/runbooks` has the restore path.

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

`.github/evidence-signers` is read as the commit under test holds it. On GitHub Free with a private repository, anyone with write
access can change that file and the check in one commit, push `deploy/plane-prod` directly, or merge unread. Nothing here can stop
that, so a change to either file deserves the same reading as a change to production. See `.github/workflows/README.md`.
