# Clean rebuild

Delete the cluster and bring the platform back, with or without its data.

Pick the smallest thing that solves your problem:

| Goal | Command | Data |
|---|---|---|
| Stop for now, resume later | `make down`, then `make up` | Kept |
| Replace the cluster, keep the data | `make destroy CONFIRM=yes`, `make up`, then restore | Comes back from backups |
| Start with an empty platform | `make destroy CONFIRM=yes SKIP_BACKUP=yes`, `make up` | Gone. Backups remain on disk |
| Also drop registry, mirrors and Git daemon data | Add `PURGE=yes` | Branded images are gone until rebuilt |

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
```

Check these:

| Check | Why |
|---|---|
| The cluster is running, if you want a backup | `backup.sh` needs the API. If it is stopped, `make destroy` fails with "backup failed, so nothing was deleted". Run `make up` first, or pass `SKIP_BACKUP=yes` knowingly |
| `.local/secret-zero/` exists, and you have a copy of what you cannot lose | Without `ENCRYPTION_KEY`, an Infisical dump is unreadable |
| All work is committed to `main` | `make up` publishes commits only. Argo CD reads nothing else |
| At least 25 GiB free on the host, 35 recommended | `scripts/prereqs.sh` refuses below 25 |
| A recent `make test-e2e` ran before the backup | Otherwise the restore's sentinel proofs report `NOT RUN` |

## Destroy

```bash
make destroy CONFIRM=yes
```

`scripts/destroy.sh`:

1. Refuses without `CONFIRM=yes`.
2. Runs `scripts/backup.sh all`, in the order Infisical, dev, prod-sim, unless `SKIP_BACKUP=yes`. A failed backup stops everything, and nothing is deleted.
3. Runs `kind delete cluster`.
4. Removes `.local/terraform/local` and `.local/terraform/infisical`, because that state describes a cluster that no longer exists.
5. With `PURGE=yes`, runs `docker compose down --volumes` on the local services.

What survives without `PURGE`:

| Kept | Where |
|---|---|
| Backups | `.local/backups/` |
| Secret zero | `.local/secret-zero/` |
| Bare Git repo | `.local/git/` |
| Registry and mirrors | Docker volumes `plane-platform-local_*` |
| Test accounts and sentinels | `.local/test-accounts.env`, `.local/test-sentinel-*.json` |

Check whether space came back. This is unresolved on this host, so record it:

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

[[VERIFY: scripts/up.sh exists and make up completes; at commit f733b87 the Makefile called it and the file was missing]]

The design order in the integration review:

1. `scripts/cluster-up.sh`: kind, Compose services, kubeconfig.
2. `make gitops-publish`, before Terraform, so the root's first compare has a repo.
3. Terraform in `infrastructure/terraform/environments/local`: namespaces, quotas, CoreDNS rewrite, Argo CD, projects, root.
4. `scripts/secret-zero.sh`.
5. Wait for Traefik, which also tests NodePort under NetworkPolicy.
6. `scripts/infisical-bootstrap.sh`, which waits for `/api/status`, then Terraform, seed, and identity ids.
7. Wait for all Applications to be Synced and Healthy.

A first install pulls about 8.56 GiB of unpacked images (estimate: summed from registry layer sizes before anything was deployed, critique section 5), so expect it to take a while.

[[MEASURE: duration of make up from nothing, with empty mirrors and with full mirrors]]

**Do not wait on `root` alone.** Its operation can succeed right after applying the last wave, and `plane-dev` stays `Degraded` until bootstrap publishes the identity Secret.

## Restore data

Order matters, because Plane's encrypted rows depend on the `SECRET_KEY` held in Infisical.

```bash
make restore ENV=infisical BACKUP=latest CONFIRM=yes
scripts/infisical-bootstrap.sh
make restore ENV=dev BACKUP=latest CONFIRM=yes
make restore ENV=prod-sim BACKUP=latest CONFIRM=yes
```

Re-run bootstrap after the Infisical restore, because Kubernetes Auth stores the cluster CA and this cluster has a new one. Wait for the operators to re-sync Secrets before restoring Plane, or the fingerprint check will refuse. [[VERIFY: this order on a new cluster gives matching SECRET_KEY fingerprints and restore results of PASS]]

Bootstrap on a fresh Infisical over old local state moves files aside when it detects `initialized=false`. So restoring Infisical changes that detection. [[VERIFY: bootstrap's behaviour when Infisical was restored from a dump onto a new cluster, using the existing infisical-admin.json]]

If you skip the restore, seeding generates new secrets, including a new `SECRET_KEY`. Those are not compatible with old Plane dumps. To go back to the old data later, you must restore Infisical from its matching dump as well.

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
| `kind delete cluster` by hand and stop there | Terraform state in `.local/terraform/` still describes the old cluster |
| `kubectl delete namespace` to "reset" an environment | Terraform owns namespaces. PVCs go too, and Argo CD will not recreate the namespace |
| `helm install` anything by hand | Argo CD owns workloads. A second owner is a bug that CI checks for |
| `kind load docker-image` | It cannot work with this host's containerd image store (kind #3795). Use the registry at `localhost:5001` |
| Restore Plane before Infisical | `SECRET_KEY` mismatch |
| `PURGE=yes` without a way to rebuild images | `make images` needs the branding inputs. [[VERIFY: make images rebuilds the branded images from a clean registry; at commit f733b87 apps/wayline/images.txt was missing]] |
| Claim a rebuild proves production recovery | This rebuilds one laptop's kind cluster. Pass 2 on Hetzner is a different system, and has its own proof to make |
