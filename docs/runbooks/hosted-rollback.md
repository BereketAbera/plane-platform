# Rollback on hosted production

A release reached hosted production, namespace `plane-prod` at https://wayline.bereket.dev, and you need what ran before it. Hosted
production runs the same customized Plane Community Edition v1.4.3 images as dev, by digest, on one K3s node on a Contabo VPS. A change
reaches it by another path than the local platform's, so `make promote` and `make rollback` do not touch it.

**Status, 2026-11-07.** No rollback has run on hosted production: NOT RUN. Every release on `deploy/plane-prod` has moved forward, and each
one since the first promotion, `ac2ddfa` at 06:02:53Z, has carried the same image set, `6d3610b95f01` (`git log origin/deploy/plane-prod`).
That is the only set with signed evidence ([promotion evidence](../evidence/promotions/README.md)). So an image rollback has no older set to
go to yet, and a revert of that first promotion is refused, as [below](#roll-back-the-images) says. What follows is read from the code.

Preamble for raw commands, from the checkout that holds `.local/hosted/plane-prod/`:

```bash
kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
make remote-tunnel TARGET=plane-prod VERB=status   # VERB=start if it is down
```

## How a change reaches each environment

| | dev and prod-sim, on kind | Hosted production |
|---|---|---|
| What Argo CD reads | `git://plane-git/plane-platform.git`, the bare repository on this Mac that `make gitops-publish` writes | Branch `deploy/plane-prod` on GitHub, over `ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git`, with a read-only deploy key |
| What moves it | `make gitops-publish`, which `make promote` and `make rollback` run | Job `release-plane-prod` in [`ci.yml`](../../.github/workflows/ci.yml), on each push to `main`, once `lint`, `manifests` and `security` pass. It runs [`publish-release.sh`](../../scripts/ci/publish-release.sh), the branch's only writer |
| Promote | `make promote ENV=dev`, then `make promote ENV=prod-sim CONFIRM=yes` | `gh workflow run promote-plane-prod.yml -f set_hash=<set-hash>` opens a pull request, and merging it is the approval |
| What the gate reads | For prod-sim, that `plane-dev` runs the digest, Synced and Healthy | [`check-prod-evidence.sh`](../../scripts/ci/check-prod-evidence.sh): every Wayline digest in the render is covered by one signed evidence file. It asks no cluster |
| Roll back | `make rollback ENV=dev`, or `ENV=prod-sim CONFIRM=yes` | A revert on `main`, or the promotion workflow with an older set's hash. Either is a new commit on `main`, so the branch moves forward to it |
| Dump before a migration | `make promote ENV=prod-sim` takes one, unless `SKIP_BACKUP=yes` | Sync hook `plane-prod-predeploy-dump`, one per backend image |
| If the step fails | The promotion stays on `main` and leaves with the next publish | The branch stays where it was, and the commit on `main` reaches nothing |

`make promote ENV=prod` and `make rollback ENV=prod` stop at their usage line: the local scripts take `dev` and `prod-sim` only, and reach
kind only. The branch holds nothing but `gitops/clusters/plane-prod`, `gitops/environments/prod` and `RELEASE.json`, which names the
`main` commit, the CI run and the set.

## What Argo CD does with a release

- `root` reads `gitops/clusters/plane-prod/applications` at `deploy/plane-prod`, and [`plane-prod`](../../gitops/clusters/plane-prod/applications/plane-prod.yaml)
  reads `gitops/environments/prod` there. Both sync by themselves, with prune and self-heal, and `plane-prod` prunes last, once the new
  state is healthy.
- Each retries without limit, from 30s doubling to 5 minutes, and `retry.refresh` makes each retry read the newest commit. So a revert lands
  while a bad release is still retrying. That was seen twice in dev ([Failed deploy](failed-deploy-rollback.md#roll-back-the-image)), and not
  yet on hosted production.
- Inside `plane-prod`, wave 1 applies the four data StatefulSets and runs `plane-prod-predeploy-dump`, wave 2 the migrator `plane-api-migrate-1`,
  and wave 3 the seven Deployments. A dump or a migrator that fails stops the sync before wave 3, so the Deployments keep their images.
- The dump runs only for a backend digest that has no folder yet in `/srv/wayline/backups/plane-prod/predeploy`, which keeps the newest five,
  so a retry of the same image keeps the first dump.
- Neither Application has a finalizer. Deleting one, or removing its file from the branch, leaves its objects running unmanaged.
- How soon Argo CD looks at GitHub after a release has not been measured here. Locally its looks came 120 to 289s apart
  ([alert-text-figures-1.txt](../evidence/runs/alert-text-figures-1.txt)).

## Symptoms

| Symptom | Go to |
|---|---|
| The site misbehaves after a release, and the release is the likely cause | [Roll back the images](#roll-back-the-images) |
| The migrator failed, or ran and damaged the data | [The database does not go back](#the-database-does-not-go-back) |
| A commit on `main` did not reach the cluster, or `release-plane-prod` is red | [Argo sync stuck](argo-sync-stuck.md#hosted-production) |
| `check-deploy-branch.yml` is red, or `make remote-status` says the branch differs from its `RELEASE.json` | Someone pushed the branch by hand. See [What not to do](#what-not-to-do) |

## Diagnosis

```bash
make remote-status TARGET=plane-prod
git fetch origin
git log -3 --format='%h %cI %s' origin/deploy/plane-prod
git show origin/deploy/plane-prod:RELEASE.json
gh run list --workflow ci.yml --branch main --limit 5
kc -n argocd get application plane-prod \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{" "}{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'
kc -n plane-prod get pods,jobs
kc -n plane-prod logs job/plane-prod-predeploy-dump --tail=20
kc -n plane-prod logs job/plane-api-migrate-1 --tail=50
```

Only the backend image carries migrations, so a release that changed `web`, `admin`, `space` or `live` alone cannot have changed the schema.
[Argo sync stuck](argo-sync-stuck.md) reads an Application's state: the commands there work with `kc` in place of `kubectl`.

## Roll back the images

Each `<set-hash>.json` in `docs/evidence/promotions/`, with its `.sig` beside it, is one evidenced set. To go back to an older one:

```bash
ls docs/evidence/promotions/
gh workflow run promote-plane-prod.yml -f set_hash=<older-set-hash>
```

That runs the gate on the change and opens a pull request with the older digests. Read it. A pull request opened by a workflow starts no
checks by itself, so approve or re-run its held `ci` run in Actions, or close and reopen the pull request. Wait for `Lint`, `Manifests` and
`Security`, and merge it with a merge commit, the method this project uses because a squash or rebase changes any commit already published to local dev. Or revert the
promotion from a branch, which does the same through a pull request of your own, and that one starts its checks by itself:

```bash
git fetch origin
git switch -c rollback/<name> origin/main
git log --grep='^promote(plane-prod)' --format='%h %s' -3
git revert <commit>                                        # a merge commit needs -m 1
git push -u origin HEAD
gh pr create --fill
sleep 30
gh pr checks --watch --required
gh pr merge --merge
```

The `sleep` is there because `gh pr checks` stops with an error until the run has started. A rollback through a pull request has to wait for
those three checks. The ruleset on `main` requires them, refuses a direct push and has no
bypass actors, so going around them would need an admin to change the ruleset. Whether an emergency may do that has not been decided.

After the merge CI runs again on `main`, `release-plane-prod` moves `deploy/plane-prod`, and Argo CD takes it at its next look. To ask for
that look now:

```bash
kc -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite
kc -n argocd annotate application plane-prod argocd.argoproj.io/refresh=normal --overwrite
```

**A revert does not undo the first promotion.** It would take Application `plane-prod` away, root would prune it, and Plane would keep running
unmanaged with its availability alerts quiet. So `publish-release.sh` refuses to go from a promoted set back to none, and the branch stays
where it is. Promote another set, or revert the revert.

**A platform change**, such as values, policies, monitoring or the backup Jobs, rolls back the same way: `git revert` on a branch, and a pull request.
Argo CD's own install, the namespaces, quotas, LimitRanges, the CoreDNS rewrite and the bootstrap chart belong to Terraform's
[`environments/prod`](../../infrastructure/terraform/environments/prod/README.md), and the DNS records to
[`environments/prod-host`](../../infrastructure/terraform/environments/prod-host/README.md). A revert of those needs their apply as well,
which no release does.

## The database does not go back

A rollback moves the images, not the database. A migration the newer backend ran stays applied. If the older backend runs on that schema,
stop there. If it does not, or if the migration did the damage, restore the dump taken just before it. Everything written since that dump is
lost, so a person decides.

[`scripts/hosted/README.md`](../../scripts/hosted/README.md), section After a rollback: the database does not go back, has the steps and the
Job. In outline:

1. `make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod`, so what is there now is kept too.
2. Roll the images back first, as above, and wait for Argo CD. With the newer backend still deployed, its migrator would run the same
   migrations again on what you restore.
3. Pause auto-sync, root first, and wait until neither Application has a sync running.
4. Scale the API, worker, beat and live to zero.
5. Restore, with a Job in `plane-prod`, the dump named for the backend whose migrations you are undoing, not the one you are going back to.
6. Flush Valkey and purge the `celery` queue.
7. Delete the Job and put auto-sync back, `plane-prod` first and root last, then test as under [Confirm](#confirm).

Where each dump lives is in [Restore on hosted production](hosted-restore.md#the-copies). NOT RUN: none of these steps has run on a cluster.

## Confirm

```bash
make remote-status TARGET=plane-prod
git show origin/deploy/plane-prod:RELEASE.json
make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=argo
make remote-smoke TARGET=plane-prod
```

You want `RELEASE.json` naming the merge commit on `main`, every Application Synced and Healthy, and no pod on the digest you
left. The smoke signs
in with an existing account, whose email and password it asks for at hidden prompts, so the owner runs it in a terminal.

## What not to do

| Do not | Why |
|---|---|
| Push `deploy/plane-prod` by hand | The ruleset covers `main` only, so nothing stops anyone with write access, and Argo CD syncs whatever the branch holds. The next release then stops and names the commit, and [`check-deploy-branch.yml`](../../.github/workflows/check-deploy-branch.yml) goes red each day until the branch matches its `RELEASE.json` again |
| Force-push or rewrite `main` | The release refuses to move backwards: the commit `RELEASE.json` names must be an ancestor of the next one. Revert instead |
| `kubectl set image` or `kubectl rollout undo` | Self-heal puts back what the branch says |
| Edit `gitops/environments/prod/manifests.yaml` by hand | It is generated, CI fails on the difference, and a digest with no evidence is refused |
| Revert the first promotion | Refused, as above |
| Delete a folder under `/srv/wayline/backups/plane-prod/predeploy` | Its name is how the hook knows a backend has its dump, and its dump is the way back past that backend's migrations |
| Delete Application `plane-prod` to reset it | It has no finalizer, so Plane keeps running unmanaged, and its availability alerts, which wait for that Application, go quiet |
