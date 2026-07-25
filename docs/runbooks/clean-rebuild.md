# Clean rebuild

Delete the cluster and bring the platform back, with or without its data.

**Status, 2026-11-05.** The clean install, the cold install and the full restore have all run. `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` deleted the cluster through `scripts/destroy.sh`, ran a clean install from a fresh clone with new secrets, tested it and deleted it, then restored Infisical, dev and prod-sim from backup into a new cluster. It kept the local registry and the pull-through caches. A second run, at `18af97a`, added `COLD_INSTALL=yes`: it removed the registry and caches as well, installed from source in a fresh clone, and restored again, on code with the recovery fixes merged. Their results are under [Rebuild](#rebuild) and [Restore data](#restore-data). `.tools` was copied rather than downloaded both times, so neither is a new machine. A third, `LOSE_CLUSTER=yes`, from 13:06Z to 13:35Z at `f9abc2a`, deleted with kind alone, restored with every restore step PASS, and read `RESULT PASS`, `make` exit 0 ([output](../evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), [log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)).

Pick the smallest thing that solves your problem:

| Goal | Command | Data |
|---|---|---|
| Stop for now, resume later | `make down`, then `make up` | Kept |
| Replace the cluster, keep the data | `make destroy CONFIRM=yes`, then `make restore-clean BACKUP=latest` | Comes back from backups |
| Start with an empty platform | `make destroy CONFIRM=yes SKIP_BACKUP=yes`, `make up` | Gone. Backups remain on disk |
| Also remove the local services, with the registry and mirror volumes and the `plane-git` container | Add `PURGE=yes` | Branded images are gone until rebuilt, and a rebuild makes new digests. The bare repo in `.local/git` stays |

## Symptoms that bring you here

- Cluster state is confused beyond what other runbooks fix.
- You need to prove the platform builds from nothing.
- You need to change something only cluster creation sets, such as the node image or mounts.
- Disk reclamation, see [Disk pressure](disk-pressure.md).

## Before you start

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
make status
git status --short
git log -1 --format='%h %s' main
git --git-dir=.local/git/plane-platform.git log -1 --format='%h %s' main
df -h .
ls -la .local/secret-zero/
ls -1 .local/backups/dev .local/backups/prod-sim .local/backups/infisical 2>/dev/null
make restore-clean BACKUP=latest PLAN_ONLY=yes   # if you want the data back. Changes nothing, and works on a live cluster
```

Check these:

| Check | Why |
|---|---|
| The cluster is running, if you want a backup | `backup.sh` needs the API. If it is stopped, `make destroy` fails with "backup failed, so nothing was deleted". Run `make up` first, or pass `SKIP_BACKUP=yes` knowingly, because that deletes what the cluster holds with no backup of it. A clean restore marked as under way does not stop this backup: `scripts/destroy.sh` passes `ALLOW_BACKUP_DURING_RESTORE=yes` by itself, since what it deletes may be all there is. That has run only on stubs |
| `.local/secret-zero/` exists, and you have a copy of what you cannot lose | Without `ENCRYPTION_KEY`, an Infisical dump is unreadable |
| All work is committed to `main` | `make up` publishes commits only. Argo CD reads nothing else |
| At least 25 GiB free on the host to create a cluster | `scripts/prereqs.sh` and `make up` refuse below 25. The cold install used about 18 GiB, from 31 to 13 GiB free, with a second image build in it because of [the umask defect](#the-umask-defect), so that is not a good install's figure, and an install with no defect has not been read. 25 GiB lets it start, and this figure would end near 7 GiB ([summary](../evidence/runs/clean-install-20261105T105546Z/summary.txt), [readings](../evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). A delete gives space back first, which a plan counts: on 2026-11-05 it read about 24.9 GiB after a delete, and refused ([dr-plan-4.txt](../evidence/runs/dr-plan-4.txt)). `ALLOW_LOW_DISK="<reason>"` goes past it, and logs the reason |
| A recent `make test-e2e` ran before the backup | Otherwise the restore's sentinel proofs report `NOT RUN` |

## Destroy

```bash
make destroy CONFIRM=yes
```

`scripts/destroy.sh`:

1. Refuses without `CONFIRM=yes`. Run with none in the environment on 2026-11-05 at `00126ea`, it printed what it would delete, make exited 2, and the node read the same before and after ([TEAR-1-20261105T083304Z.txt](../evidence/runs/TEAR-1-20261105T083304Z.txt)). Called from a make that has `CONFIRM=yes` on its own command line, it obeys, because make passes that down in `MAKEFLAGS`.
2. Runs `scripts/backup.sh all`, in the order Infisical, dev, prod-sim, unless `SKIP_BACKUP=yes`, and past the refusal for a clean restore under way. A failed backup stops everything, and nothing is deleted.
3. Runs `kind delete cluster`.
4. Removes `.local/terraform/local`, because that state describes a cluster that no longer exists, and `.local/restore-clean.state`.
5. With `PURGE=yes`, runs `docker compose down --volumes` on the local services.

`BACKUP=latest` now names the backup just taken. If what was deleted held nothing you want, name an older one with `BACKUP=<id>`, and `PLAN_ONLY=yes` shows what each holds.

What survives without `PURGE`:

| Kept | Where |
|---|---|
| Backups | `.local/backups/` |
| Secret zero | `.local/secret-zero/` |
| Terraform state of `infisical/terraform` | `.local/terraform/infisical/`. It describes what is in the Infisical database, which a backup can bring back. Each Infisical backup also holds a copy |
| Bare Git repo | `.local/git/` |
| Registry and mirrors | Docker volumes `plane-platform-local_*` |
| Test accounts and sentinels | `.local/test-accounts.env`, `.local/test-sentinel-*.json`. On an empty platform the first `make test-e2e` replaces a kept sentinel, because a new database cannot hold it. A restore puts back the ones in its backup |

Check whether space came back. A 273 MB kind volume gave back 254 MB within 15 s (`scripts/lib/up-checks.sh`). On 2026-11-05 a delete with a 12.8 GiB kind volume took host free disk from 17.5 GiB to 31.6 GiB, 14.1 GiB back by the first reading, so the 93% a plan counts on held on this volume ([drill log](../evidence/runs/drill-clean-restore-20261105T074859Z.log), lines 59 and 74). That is free disk, not `Docker.raw`, and the first reading is not always the end: after the clean install's delete it read 19 GiB, and a plan moments later 26.8 GiB (lines 98 and 108). The cold drill's delete, with `PURGE`, so with the local services' volumes too, read 31.7 GiB free and 15.6 GiB back, where the check, counting the kind volume alone, expected 27.0 ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log), line 81). The last drill's delete, with kind alone, read 28.3 GiB free and 11.2 GiB back, where the check expected about 26.6 ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log), line 73).

`Docker.raw` before and after `make destroy`: Not measured in Pass 1. The nearest readings are from the last drill, which deleted with kind alone: 38,276,744 KiB at the top of [its output](../evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt) and 38,301,404 KiB at the bottom. They bracket the whole drill, delete and restore, so the second holds a restored cluster. To read it around your own delete:

```bash
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```

## Rebuild

```bash
make setup
make up
make status
```

One whole `make up` from nothing exited 0 on 2026-11-05 at `7d5ff62`, as the clean install step of the drill, and all 14 Applications read Synced and Healthy. `make test-e2e` then passed with no SKIP, 46 PASS in dev and 45 in prod-sim, including `branding-fresh-install`, and `make test-infisical` exited 0 with 118 PASS lines. A second `make up` took 16 s and left the same pod uids, and Terraform found no differences ([summary.txt](../evidence/runs/clean-install-20261105T075041Z/summary.txt), [apps-after-up.txt](../evidence/runs/clean-install-20261105T075041Z/apps-after-up.txt), [e2e-dev-first.txt](../evidence/runs/clean-install-20261105T075041Z/e2e-dev-first.txt), [e2e-prod-sim-first.txt](../evidence/runs/clean-install-20261105T075041Z/e2e-prod-sim-first.txt), [test-infisical.txt](../evidence/runs/clean-install-20261105T075041Z/test-infisical.txt), [make-up-again.txt](../evidence/runs/clean-install-20261105T075041Z/make-up-again.txt), [terraform-plan-local.txt](../evidence/runs/clean-install-20261105T075041Z/terraform-plan-local.txt)). The summary's `Steps that failed: 1` is `destroy-refused`, which is a defect in the test and says nothing about the platform: it inherited `CONFIRM=yes`, so `make destroy` obeyed. `00126ea` cleared the variable, make still passed it down in `MAKEFLAGS`, so the cold install's step did the same, and `36d3011` clears that too. That step has not run since. Run clean, `make destroy` refused ([TEAR-1-20261105T083304Z.txt](../evidence/runs/TEAR-1-20261105T083304Z.txt)). Before this, `UP_STOP_AFTER` had stopped `make up` at three of its stages ([bootstrap-up-terraform-1.txt](../evidence/runs/bootstrap-up-terraform-1.txt), [bootstrap-up-secret-zero-1.txt](../evidence/runs/bootstrap-up-secret-zero-1.txt), [bootstrap-up-traefik-1.txt](../evidence/runs/bootstrap-up-traefik-1.txt)).

The steps, in `scripts/up.sh`. `UP_STOP_AFTER=<step>` stops after one, and running it again continues:

1. `cluster`: kind, Compose services, kubeconfig. With no cluster, it first moves a stale `.local/terraform/local` aside.
2. `publish`: checks the local image digests, then `scripts/gitops-publish.sh`, before Terraform, so the root's first compare has a repo. A digest the registry cannot serve stops it here, with the ways out.
3. `terraform`, in `infrastructure/terraform/environments/local`: namespaces, quotas, CoreDNS rewrite, Argo CD, projects, root.
4. `secret-zero`: `scripts/secret-zero.sh`.
5. `traefik`: waits for Traefik, then a real request through it, which also tests NodePort under NetworkPolicy.
6. `infisical`: waits for `/api/status`, then `scripts/infisical-bootstrap.sh`: first admin, Terraform, seed, and identity ids.
7. Waits for all Applications to be Synced and Healthy, and prints `make status`.

It refuses uncommitted changes under `gitops`, `helm`, `monitoring` and `infisical`, because Argo CD reads only commits.

**With the registry and caches kept.** One `make up` from nothing took 955 s on 2026-11-05 at `7d5ff62`, on a fresh clone, with the registry, mirrors and node image on disk and `.tools` copied ([summary.txt](../evidence/runs/clean-install-20261105T075041Z/summary.txt)). By step: `cluster` 173 s, `publish` 3 s, `terraform` 54 s, `secret-zero` 2 s, `traefik` 151 s, `infisical` 245 s, and the wait for all Applications 324 s ([make-up.txt](../evidence/runs/clean-install-20261105T075041Z/make-up.txt)).

Host free disk went from 31 GiB to 19 GiB by `df`, in whole GiB, so about 12 GiB, the clone included ([summary.txt](../evidence/runs/clean-install-20261105T075041Z/summary.txt), [make-status.txt](../evidence/runs/clean-install-20261105T075041Z/make-status.txt)). The registry, mirrors and node image were already on disk, so this is not a first install on an empty machine.

**With the registry and caches gone.** The cold install of 2026-11-05 ran on a fresh clone of `18af97a`, with no `.local` and no `.build`, and `.tools` copied ([summary](../evidence/runs/clean-install-20261105T105546Z/summary.txt), [drill log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)). A new machine has to take these steps, because the digests in Git do not exist on it:

```bash
make setup
make up      # creates the cluster and local services, builds the images, then stops by design
make promote ENV=dev
make promote ENV=prod-sim CONFIRM=yes SKIP_BACKUP=yes OVERRIDE_DEV_CHECK="<reason>"
make up
```

| Step | Took | Note |
|---|---|---|
| `make setup` | 3 s | Checks `.tools`, which it would download on a real new machine |
| First `make up` | 1008 s | The cluster step 33 s, then the build, which reproduced no digest, so it [lists them and stops](../evidence/runs/clean-install-20261105T105546Z/make-up-stops-on-new-digests.txt) |
| `make promote`, each | 10 s and 3 s | [dev](../evidence/runs/clean-install-20261105T105546Z/make-promote-dev.txt), [prod-sim](../evidence/runs/clean-install-20261105T105546Z/make-promote-prod-sim.txt) |
| Second `make up` | 5238 s, which is not a good install's time | Pulled everything through empty caches, and held by the defect below. `cluster` 95 s, `publish` 1 s, `terraform` 179 s, `secret-zero` 3 s, `traefik` 46 s, `infisical` 1974 s, and the wait for all Applications 2935 s ([make-up.txt](../evidence/runs/clean-install-20261105T105546Z/make-up.txt)) |

**A full cold install with no defect has not been timed end to end.** The steps before the last wait took 2298 s on cold pulls and reached no image built here. `kube-prometheus-stack`'s first sync started 17.5 minutes after `metrics-server`'s, and the two Infisical operators' finished at 11:51:01Z, 37 m 51 s into that `make up` ([app-timeline.txt](../evidence/runs/clean-install-20261105T105546Z/app-timeline.txt)). The last wait took 2935 s. `plane-dev` held it until 12:32:35Z, about 41 minutes, and `plane-prod-sim`'s sync started at 12:37:10Z, so at most about 46 minutes went on the defect, less what a healthy `plane-dev` first boot takes. That time on cold pulls: Not measured in Pass 1.

After that `make up`, all 14 Applications read Synced and Healthy ([apps-after-up.txt](../evidence/runs/clean-install-20261105T105546Z/apps-after-up.txt)). `make test-e2e` passed with no SKIP, 46 PASS in dev and 45 in prod-sim, including `branding-fresh-install` ([dev](../evidence/runs/clean-install-20261105T105546Z/e2e-dev-first.txt), [prod-sim](../evidence/runs/clean-install-20261105T105546Z/e2e-prod-sim-first.txt)), and `make test-infisical` exited 0 ([test-infisical.txt](../evidence/runs/clean-install-20261105T105546Z/test-infisical.txt)). A second `make up` took 16 s and left the same pod uids, Terraform found no differences ([make-up-again.txt](../evidence/runs/clean-install-20261105T105546Z/make-up-again.txt), [terraform-plan-local.txt](../evidence/runs/clean-install-20261105T105546Z/terraform-plan-local.txt)), and a dev backup from another install was refused on `SECRET_KEY` ([restore-foreign-key-refused.txt](../evidence/runs/clean-install-20261105T105546Z/restore-foreign-key-refused.txt)). The summary's `Steps that failed: 1` is `destroy-refused` again, above, and TEAR-1 has its own clean run.

Host free disk went from 31 GiB to 13 GiB by `df`, and `Docker.raw` read 40060992 KiB, 38.21 GiB, with the second build's leftovers on disk ([disk-after-install.txt](../evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). [Disk pressure](disk-pressure.md#diagnosis) has the rest.

**Do not wait on `root` alone.** Its operation can succeed right after applying the last wave, and `plane-dev` stays `Degraded` until bootstrap publishes the identity Secret ([infisical-unready-sync-1.txt](../evidence/runs/infisical-unready-sync-1.txt)).

### The umask defect

The drill ran under umask 077, so every file in a build context was 0600, and the build kept those modes. Every build step passed. Then web, admin, space and api crashed at start with Permission denied, while worker, beat and live ran, because their images' non-root users could not read their own files. `make up` waited with no explanation: it read `plane-dev=OutOfSync/Progressing`, then `OutOfSync/Degraded`, up to 2407 s ([make-up.txt](../evidence/runs/clean-install-20261105T105546Z/make-up.txt)).

`6f5a426` fixes it in `scripts/ci/build-images.sh`, with `chmod -R a+rX` on each context. The recovery, in the same cluster, with that `make up` still waiting: `make images` under the same umask, 598 s, then both promotions, then ending the stuck operation with [the `Terminating` patch](argo-sync-stuck.md#end-an-operation), after which `plane-dev` and `plane-prod-sim` came up healthy ([rebuild](../evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt)). The clone held the same fix as `8770097`. The pods' logs and the patch were not saved, so those two facts have no file. The fix has run through `make images` and that promotion, not through a whole cold install from its start.

So if `make up` sits on `plane-dev` and its pods read `Permission denied`, look at the images' file modes first: images built before `6f5a426` under a restrictive umask stay wrong until rebuilt, and nothing here checks an image's modes.

## Restore data

Order matters, because Plane's encrypted rows depend on the `SECRET_KEY` held in Infisical. `make up` first and a restore after it do not give a matched set, because bootstrap on a fresh Infisical creates new secrets. So run this after `make destroy`, instead of `make up`:

```bash
make restore-clean BACKUP=latest
```

It runs `make up` as far as Traefik, replaces Infisical's database, runs `make up` from there with bootstrap in restored mode, waits for all Applications, restores dev and then prod-sim, and checks everything again. It exits 0 when everything is proven, 1 when something failed, 2 when nothing failed but a proof could not run or a person has to act, and 4 when everything is proven and it overwrote what `ALLOW_RESUME_OVERWRITE` named, which is not a pass either. Through `make`, any of those but 0 is make's own exit 2, so read `jq '.result, .not_run' .local/evidence-raw/restore-clean-*.json`. Run the same command again to go on after any failure, including a hard stop. A resume refuses an environment that holds something other than its backup, and keeps one whose data has already come back: [Disaster recovery](../disaster-recovery.md#off-the-normal-path) has both. [Disaster recovery](../disaster-recovery.md#full-restoration-into-a-clean-environment) has the stages and what each rests on, and [`infisical/README.md`](../../infisical/README.md#clean-restore) has every refusal.

Don't change `gitops`, `helm`, `monitoring` or `infisical` until it ends. `make up` runs twice inside it, and refuses uncommitted changes there.

This order ran on a new cluster on 2026-11-05, at `00126ea`, in 1,201 s from the start stamp to the evidence file's last write. `SECRET_KEY` fingerprints matched in both environments, every restore step read PASS with `not_run` empty, all 14 Applications read Synced and Healthy, and all 38 rendered Secret keys held the old values under a new cluster CA ([restore-clean-20261105T081017Z.json](../evidence/runs/restore-clean-20261105T081017Z.json), [restore-dev-20261105T082337Z.json](../evidence/runs/restore-dev-20261105T082337Z.json), [restore-prod-sim-20261105T082657Z.json](../evidence/runs/restore-prod-sim-20261105T082657Z.json), [drill log](../evidence/runs/drill-clean-restore-20261105T074859Z.log)). The drill's last line reads `RESULT FAIL   1 failure(s)`, and that one failure is the `destroy-refused` step above. After `make down` and `make up`, `make test` exited 0 ([MAKE-TEST-20261105T083455Z.txt](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)), and a real browser found a work item typed by hand before the delete ([live-final](../evidence/branding/live-final/README.md)). That run had a backup moments old, with the registry and caches kept.

It ran again that day after the cold install, on code with the recovery fixes merged at `18af97a`, in 1,067 s from the start stamp to the evidence file's last write. Again every step read PASS with `not_run` empty, all 14 Applications read Synced and Healthy, and all 38 rendered Secret keys held the old values under a new cluster CA, and the e2e and Infisical tests passed ([restore-clean-20261105T124518Z.json](../evidence/runs/restore-clean-20261105T124518Z.json), [Infisical](../evidence/runs/restore-infisical-20261105T124950Z.json), [dev](../evidence/runs/restore-dev-20261105T125720Z.json), [prod-sim](../evidence/runs/restore-prod-sim-20261105T130009Z.json), [drill log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)). Its last line reads `RESULT FAIL   1 failure(s)` too, for the same step, line 121. That restore was not cold either: it found the caches the cold install had just filled, and a registry put back from the drill's own snapshot.

It ran a third time at `f9abc2a`, on a cluster deleted with kind alone, with no install in the gap, in 1,474 s from the delete. The stale Terraform state moved aside by itself, every step read PASS with `not_run` empty, and the drill's last line reads `RESULT PASS` ([restore-clean-20261105T130828Z.json](../evidence/runs/restore-clean-20261105T130828Z.json), [Infisical](../evidence/runs/restore-infisical-20261105T132002Z.json), [dev](../evidence/runs/restore-dev-20261105T132634Z.json), [prod-sim](../evidence/runs/restore-prod-sim-20261105T132932Z.json), [drill log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)). The registry and caches stayed, so that was not cold either.

Restored mode finds `initialized=true` and reuses the credentials. It updates only the Kubernetes Auth CA, publishes the identity Secrets, writes no value, and refuses a fresh instance, a token the server rejects, or Terraform wanting to create or delete anything. On the live instance and on a throwaway new server it ran that way ([dr-restored-bootstrap-1.txt](../evidence/runs/dr-restored-bootstrap-1.txt), [dr-fresh-instance-rehearsal-2.txt](../evidence/runs/dr-fresh-instance-rehearsal-2.txt)). On the real new clusters of 2026-11-05 Terraform changed 2 resources, the CA on each identity, the seed wrote nothing, and a second run found nothing to change, both times ([first log](../evidence/runs/drill-clean-restore-20261105T074859Z.log), [second log](../evidence/runs/drill-clean-restore-20261105T105347Z.log), stages 5 and 7).

If you run `make up` with no restore, seeding generates new secrets, including a new `SECRET_KEY`. Those are not compatible with old Plane dumps. To go back to the old data later, you must restore Infisical from its matching dump as well, which `make destroy CONFIRM=yes SKIP_BACKUP=yes` and `make restore-clean BACKUP=<id>` do. While `.local/restore-clean.state` exists, a plain `make up` refuses to bootstrap a fresh instance. Removing that file by hand ends the restore and deletes nothing.

See [Backup and restore](backup-restore.md) and [Disaster recovery](../disaster-recovery.md).

## Confirm

```bash
make status
make test
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
make test-alert ENV=dev
```

After the restore of 2026-11-05, and `make down` and `make up`, `make status` read all 14 Applications Synced and Healthy and no pod unready ([PERS-3-20261105T083304Z.txt](../evidence/runs/PERS-3-20261105T083304Z.txt)). `make test` exited 0: gates, NetworkPolicy 418 of 418, Infisical isolation and rendered Secrets, routes, e2e in both environments with one SKIP each, and separation at 384 network and 97 state checks ([MAKE-TEST-20261105T083455Z.txt](../evidence/runs/MAKE-TEST-20261105T083455Z.txt)). `make test-alert` has not run on that cluster. An alert did reach the sink there, from `tests/drills/alert-rules.sh` ([alert-rules-dev-20261105T101707Z.txt](../evidence/runs/alert-rules-dev-20261105T101707Z.txt)).

Save output to `docs/evidence/`, labelled with date and command. A rebuild that needed a manual step counts as that, and must say so.

## What not to do

| Do not | Why |
|---|---|
| `rm -rf .local` | It holds secret zero and backups. `ENCRYPTION_KEY` lost everywhere means all secrets are gone, even with a dump |
| `docker system prune -a` | Removes cached images for unrelated containers that cannot be pulled again. See [Disk pressure](disk-pressure.md) |
| `kind delete cluster` by hand and stop there | No backup was taken first, and `.local/terraform/local` still describes the old cluster. The next `make up` or `make restore-clean` moves it to `local.stale-<time>` by itself, which `make restore-clean` did for real in the last drill ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log), line 85), and `make up` alone has done only on stubs |
| `kubectl delete namespace` to "reset" an environment | Terraform owns namespaces. PVCs go too, and Argo CD will not recreate the namespace |
| `helm install` anything by hand | Argo CD owns workloads. A second owner is a bug that CI checks for |
| `kind load docker-image` | It cannot work with this host's containerd image store (kind #3795). Use the registry at `localhost:5001` |
| Restore Plane before Infisical | `SECRET_KEY` mismatch |
| `PURGE=yes` without a way to rebuild images | No backup holds the digests Git deploys, and GHCR holds other ones. `make images` needs the branding inputs. It has built and pushed the four images here (`docs/evidence/branding/build.txt`), and from a purged registry on the cold install, in a clone, where they got other digests ([make up](../evidence/runs/clean-install-20261105T105546Z/make-up-stops-on-new-digests.txt)) |
| Claim a rebuild proves production recovery | This rebuilds one laptop's kind cluster. Pass 2 on Hetzner is a different system, and has its own proof to make |
