# Clean rebuild

Delete the cluster and bring the platform back, with or without its data.

**Status, 2026-11-05.** None of this has run end to end. `make destroy`, a whole `make up` from nothing, and `make restore-clean` past its plan are all still to run, and need the owner's go-ahead. `make up` has run stage by stage. Each `VERIFY` or `MEASURE` marker here waits on those runs. A file name in code with no link is a raw run in `.local/evidence-raw/`, not yet published.

Pick the smallest thing that solves your problem:

| Goal | Command | Data |
|---|---|---|
| Stop for now, resume later | `make down`, then `make up` | Kept |
| Replace the cluster, keep the data | `make destroy CONFIRM=yes`, then `make restore-clean BACKUP=latest` | Comes back from backups |
| Start with an empty platform | `make destroy CONFIRM=yes SKIP_BACKUP=yes`, `make up` | Gone. Backups remain on disk |
| Also drop registry, mirrors and Git daemon data | Add `PURGE=yes` | Branded images are gone until rebuilt, and a rebuild makes new digests |

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
| The cluster is running, if you want a backup | `backup.sh` needs the API. If it is stopped, `make destroy` fails with "backup failed, so nothing was deleted". Run `make up` first, or pass `SKIP_BACKUP=yes` knowingly |
| `.local/secret-zero/` exists, and you have a copy of what you cannot lose | Without `ENCRYPTION_KEY`, an Infisical dump is unreadable |
| All work is committed to `main` | `make up` publishes commits only. Argo CD reads nothing else |
| At least 25 GiB free on the host to create a cluster | `scripts/prereqs.sh` and `make up` refuse below 25. A first install measured 17.75 GiB (`dr-disk-1.txt`). A delete gives space back first, which a plan counts: on 2026-11-05 it read about 24.9 GiB after a delete, and refused (`dr-plan-4.txt`). `ALLOW_LOW_DISK="<reason>"` goes past it, and logs the reason |
| A recent `make test-e2e` ran before the backup | Otherwise the restore's sentinel proofs report `NOT RUN` |

## Destroy

```bash
make destroy CONFIRM=yes
```

`scripts/destroy.sh`:

1. Refuses without `CONFIRM=yes`.
2. Runs `scripts/backup.sh all`, in the order Infisical, dev, prod-sim, unless `SKIP_BACKUP=yes`. A failed backup stops everything, and nothing is deleted.
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

Check whether space came back. A 273 MB kind volume gave back 254 MB within 15 s (`scripts/lib/up-checks.sh`). A whole cluster has not been measured, so record it:

```bash
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```

[[MEASURE: Docker.raw allocated size before and after make destroy]]

## Rebuild

```bash
make setup
make up
make status
```

`scripts/up.sh` exists, and each stage has run on its own with `UP_STOP_AFTER` ([bootstrap-up-terraform-1.txt](../evidence/runs/bootstrap-up-terraform-1.txt), [bootstrap-up-secret-zero-1.txt](../evidence/runs/bootstrap-up-secret-zero-1.txt), [bootstrap-up-traefik-1.txt](../evidence/runs/bootstrap-up-traefik-1.txt)). It has not yet run whole from nothing.

[[VERIFY: scripts/up.sh exists and make up completes; at commit f733b87 the Makefile called it and the file was missing]]

The steps, in `scripts/up.sh`. `UP_STOP_AFTER=<step>` stops after one, and running it again continues:

1. `cluster`: kind, Compose services, kubeconfig. With no cluster, it first moves a stale `.local/terraform/local` aside.
2. `publish`: checks the local image digests, then `scripts/gitops-publish.sh`, before Terraform, so the root's first compare has a repo. A digest the registry cannot serve stops it here, with the ways out.
3. `terraform`, in `infrastructure/terraform/environments/local`: namespaces, quotas, CoreDNS rewrite, Argo CD, projects, root.
4. `secret-zero`: `scripts/secret-zero.sh`.
5. `traefik`: waits for Traefik, then a real request through it, which also tests NodePort under NetworkPolicy.
6. `infisical`: waits for `/api/status`, then `scripts/infisical-bootstrap.sh`: first admin, Terraform, seed, and identity ids.
7. Waits for all Applications to be Synced and Healthy, and prints `make status`.

It refuses uncommitted changes under `gitops`, `helm`, `monitoring` and `infisical`, because Argo CD reads only commits.

A first install measured about 17.75 GiB on the host: 10.51 GiB of images on the node, with both environments up, and the rest in volumes and the node image (`dr-disk-1.txt`). So expect it to take a while.

[[MEASURE: duration of make up from nothing, with empty mirrors and with full mirrors]]

**Do not wait on `root` alone.** Its operation can succeed right after applying the last wave, and `plane-dev` stays `Degraded` until bootstrap publishes the identity Secret ([infisical-unready-sync-1.txt](../evidence/runs/infisical-unready-sync-1.txt)).

## Restore data

Order matters, because Plane's encrypted rows depend on the `SECRET_KEY` held in Infisical. `make up` first and a restore after it do not give a matched set, because bootstrap on a fresh Infisical creates new secrets. So run this after `make destroy`, instead of `make up`:

```bash
make restore-clean BACKUP=latest
```

It runs `make up` as far as Traefik, replaces Infisical's database, runs `make up` from there with bootstrap in restored mode, waits for all Applications, restores dev and then prod-sim, and checks everything again. It exits 0 when everything is proven, 1 when something failed, and 2 when nothing failed but a proof could not run or a person has to act. Through `make`, any of those but 0 is make's own exit 2, so read `jq '.result, .not_run' .local/evidence-raw/restore-clean-*.json`. Run the same command again to go on after any failure, including a hard stop. [Disaster recovery](../disaster-recovery.md#full-restoration-into-a-clean-environment) has the stages and what each rests on, and [`infisical/README.md`](../../infisical/README.md#clean-restore) has every refusal.

Don't change `gitops`, `helm`, `monitoring` or `infisical` until it ends. `make up` runs twice inside it, and refuses uncommitted changes there.

[[VERIFY: this order on a new cluster gives matching SECRET_KEY fingerprints and restore results of PASS]]

Restored mode finds `initialized=true` and reuses the credentials. It updates only the Kubernetes Auth CA, publishes the identity Secrets, writes no value, and refuses a fresh instance, a token the server rejects, or Terraform wanting to create or delete anything. On the live instance and on a throwaway new server it ran that way ([dr-restored-bootstrap-1.txt](../evidence/runs/dr-restored-bootstrap-1.txt), [dr-fresh-instance-rehearsal-2.txt](../evidence/runs/dr-fresh-instance-rehearsal-2.txt)). A real new cluster has not been involved.

[[VERIFY: bootstrap's behaviour when Infisical was restored from a dump onto a new cluster, using the existing infisical-admin.json]]

If you run `make up` with no restore, seeding generates new secrets, including a new `SECRET_KEY`. Those are not compatible with old Plane dumps. To go back to the old data later, you must restore Infisical from its matching dump as well, which `make destroy CONFIRM=yes SKIP_BACKUP=yes` and `make restore-clean BACKUP=<id>` do. While `.local/restore-clean.state` exists, a plain `make up` refuses to bootstrap a fresh instance. Removing that file by hand ends the restore and deletes nothing.

See [Backup and restore](backup-restore.md) and [Disaster recovery](../disaster-recovery.md).

## Confirm

```bash
make status
make test
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
make test-alert ENV=dev
```

[[VERIFY: a rebuild from nothing ends with all 14 Applications Synced and Healthy]]

[[VERIFY: make test passes after a rebuild]]

Save output to `docs/evidence/`, labelled with date and command. A rebuild that needed a manual step counts as that, and must say so.

## What not to do

| Do not | Why |
|---|---|
| `rm -rf .local` | It holds secret zero and backups. `ENCRYPTION_KEY` lost everywhere means all secrets are gone, even with a dump |
| `docker system prune -a` | Removes cached images for unrelated containers that cannot be pulled again. See [Disk pressure](disk-pressure.md) |
| `kind delete cluster` by hand and stop there | No backup was taken first, and `.local/terraform/local` still describes the old cluster. The next `make up` or `make restore-clean` moves it to `local.stale-<time>` by itself, which has run only on stubs |
| `kubectl delete namespace` to "reset" an environment | Terraform owns namespaces. PVCs go too, and Argo CD will not recreate the namespace |
| `helm install` anything by hand | Argo CD owns workloads. A second owner is a bug that CI checks for |
| `kind load docker-image` | It cannot work with this host's containerd image store (kind #3795). Use the registry at `localhost:5001` |
| Restore Plane before Infisical | `SECRET_KEY` mismatch |
| `PURGE=yes` without a way to rebuild images | No backup holds the digests Git deploys, and GHCR holds other ones. `make images` needs the branding inputs. It has built and pushed the four images here (`docs/evidence/branding/build.txt`), not from a purged registry. [[VERIFY: make images rebuilds the branded images from a clean registry; at commit f733b87 apps/wayline/images.txt was missing]] |
| Claim a rebuild proves production recovery | This rebuilds one laptop's kind cluster. Pass 2 on Hetzner is a different system, and has its own proof to make |
