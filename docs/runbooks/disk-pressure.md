# Disk pressure

The Mac is the real limit, and nothing inside the cluster can see it.

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NODE=plane-platform-control-plane
```

## Why this is different from a normal cluster

Three traps were found by reading kind's source and Docker's docs, in the build's research notes, which are not in this repository. Each breaks a normal assumption.

| Trap | What happens | Consequence |
|---|---|---|
| **kind disables disk protection** | `pkg/cluster/internal/kubeadm/config.go` sets `imageGCHighThresholdPercent: 100` and `evictionHard` with `nodefs.available: "0%"` and `imagefs.available: "0%"` | No image garbage collection and no eviction. Old images stay until removed by hand. A full disk gives write errors, not pod eviction |
| **The VM cannot see the real limit** | The VM filesystem reports hundreds of free GiB on a sparse disk, while the Mac may have far less | `NodeFilesystem*` alerts watch the VM disk only, and will not fire before the Mac runs out. `/backups`, Docker Desktop's mount of the Mac, is excluded from node-exporter: it reported 4397 GiB available with 17 GiB free, which sent the percentage rules critical on a healthy cluster (`helm/values/kube-prometheus-stack.yaml`). local-path ignores PVC size |
| **`Docker.raw` does not shrink by itself** | Docker's docs say space comes back when images are deleted, but not automatically when files are deleted inside running containers | Deleting data inside the VM may not return space to the Mac |

Confirm the first on the running node:

```bash
docker exec "$NODE" grep -E 'imageGC|nodefs|imagefs' /var/lib/kubelet/config.yaml
```

On 2026-11-05 the running kubelet reported `imageGCHighThresholdPercent` 100 and `evictionHard` of 0% on `imagefs.available`, `nodefs.available` and `nodefs.inodesFree`, and the command above printed the same ([node-kubelet-config-1.txt](../evidence/runs/node-kubelet-config-1.txt)).

## Symptoms

| Symptom | Where |
|---|---|
| `only N GiB free on the host, need at least M GiB` | `guard_disk`, from most scripts. The default floor is 10 GiB. On a new cluster `up.sh` needs 25 and `cluster-up.sh` 15. `make test` and the failed-deploy, failing-migrator and pod-restart drills need 2, and `make promote`, `make rollback`, `make gitops-publish`, `make render` and `make test-netpol` need 1. `ALLOW_LOW_DISK="<reason>"` goes past the check for a new cluster, and `MIN_FREE_DISK_GIB=<n>` lowers the floor. A value below 10 and each reason are logged in `.local/evidence-raw/low-disk-overrides.log`. The refusal was seen on 2026-11-05: `MIN_FREE_DISK_GIB=999` stopped `make backup` before a Job started, and `make status`, which does not call the guard, still ran ([OPS-7-20261105T061555Z.txt](../evidence/runs/OPS-7-20261105T061555Z.txt)) |
| `the host is below N GiB free, so stopping here` | `make scan-images` wants 15 GiB to start and stops below its floor, reporting the rest as not scanned. `SCAN_MIN_FREE_GIB` and `SCAN_FLOOR_GIB` change those. One run stopped at 2 of 35 images this way ([security README](../evidence/security/README.md)) |
| `fail N GiB free ... 25 GiB is the minimum` | `scripts/prereqs.sh`. 35 GiB is the recommendation |
| Postgres logs `No space left on device`, or pods fail on writes | The VM's disk could not grow |
| Image pulls fail with write errors | Same |
| Docker Desktop hangs, or macOS warns about low disk | The Mac itself is out |
| `make status` shows low "Host disk free" | The one number that matters |

There is deliberately no project disk alert. See [Monitoring](../monitoring.md#chart-defaults-that-stay-on).

## Diagnosis

Start on the host, then go in.

```bash
df -h .
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
docker system df
du -sh .local/backups .local/git .local/trivy-cache .tools 2>/dev/null
```

The first column of `ls -kls` is what the file really occupies. The size column is the sparse maximum, which means little.

Inside the node:

```bash
docker exec "$NODE" df -h /var
docker exec "$NODE" sh -c 'du -sh /var/lib/containerd /var/local-path-provisioner /var/log/pods 2>/dev/null'
docker exec "$NODE" crictl images
docker exec "$NODE" sh -c 'du -sh /var/local-path-provisioner/* 2>/dev/null | sort -h | tail'
```

Local services, kept in named volumes outside the cluster:

```bash
docker system df -v | grep plane-platform-local
```

Budget, for comparing what you see. Both figures are estimates from the build's research notes, which are not in this repository, made before anything was deployed. Workload images on the node come to about 8.56 GiB unpacked, derived from each gzip layer's size trailer in the registry. Total host growth of 16.7 to 22 GiB adds planning figures for volumes and logs. [Resource utilization](../resource-utilization.md#disk) adds the caches.

Read on the running platform on 2026-11-05 at 02:01Z, with both environments up: the node's `/var` volume 12.94 GiB by `du`, of which images 10.51 and volumes 1.53, local services' volumes 3.62 GiB and the node image 1.19 GiB, so about 17.75 GiB for this platform. `Docker.raw` allocated 42.18 GiB, which holds whatever else is on this host's Docker too ([dr-disk-1.txt](../evidence/runs/dr-disk-1.txt)). That comes from a platform that has been running and promoted several times, not from a first install on an empty disk. Read again on 2026-11-05 at 07:44Z, just after the load test: `Docker.raw` allocated 39.59 GiB and the host had 17.67 GiB free ([LOAD-3-20261105T074440Z-host.txt](../evidence/runs/LOAD-3-20261105T074440Z-host.txt)). Across `make test-load ENV=dev`, with prod-sim rotated and restored in the same minutes, the VM's `/var` moved by about 60 MiB ([results.json](../evidence/runs/load-20261105T073241Z/results.json)).

Host free space across the first clean install, inside `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` on 2026-11-05: 31 GiB free at 07:50:41Z before `make setup`, and 19 GiB at 08:06:41Z after `make up`, so about 12 GiB went, with whatever else ran on the host in those 16 minutes included. Those are warm mirrors: that run kept the local registry and the pull-through caches, so nothing was pulled from the internet, and this is not a cold install's figure ([summary](../evidence/runs/clean-install-20261105T075041Z/summary.txt), [status](../evidence/runs/clean-install-20261105T075041Z/make-status.txt)).

Across the cold install of 2026-11-05, with the registry and caches removed first: 31 GiB free at 10:55:46Z, 29 GiB at 11:13:10Z, after the first build's source tree, package store and Docker build cache were removed, and 13 GiB at 12:40:48Z, after `make up`, so about 18 GiB went ([summary](../evidence/runs/clean-install-20261105T105546Z/summary.txt), [readings](../evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)). At that last reading `Docker.raw` allocated 40060992 KiB, 38.21 GiB, and `docker system df` read images 17.91 GB, volumes 16.72 GB and build cache 2.665 GB, across everything on this host's Docker. The local services' volumes read 1.992 GB for the Docker cache, 552.7 MB for the registry, 447.5 MB for the Quay cache and 37.64 MB for the Kubernetes cache.

Do not plan on those as a good install's figures. That run built its images twice, because of [the umask defect](../known-limitations.md#what-real-runs-found), so the registry holds both sets, and the second build's source tree, package store and build cache were still on disk at the 13 GiB reading. What an install with no defect grows by: Not measured in Pass 1. On this run's figure, a host with just the 25 GiB `make up` asks for would end near 7 GiB, under the 10 GiB floor.

`Docker.raw` before a first full install: Not measured in Pass 1. `tests/drills/clean-install.sh` reads it once, after `make up`, and nothing reads it before. Use `ls -klsh` by hand around a later install, as row TEAR-5b does for a delete.

## Fix

Work down this list. Each step costs more than the last.

**1. Old backups.** Retention keeps 3 for dev and 5 for others. `make backup ENV=all KEEP=2` removed the older ones on 2026-11-05 ([dr-backup-retention-1.txt](../evidence/runs/dr-backup-retention-1.txt)). To keep fewer on the next run:

```bash
make backup ENV=dev KEEP=1
```

Remove by hand only with a newer good backup in place.

**2. Old images on the node.** Nothing removes them automatically. Each Plane version bump can leave up to about 2.2 GiB, an estimate from the unpacked size of the five Plane images, in the same research notes. This removes images no running container uses:

```bash
docker exec "$NODE" crictl rmi --prune
```

Anything removed is pulled again when next needed. Jobs such as the backup's rclone image and k6 will re-pull from the pull-through caches, so expect a delay. Running this on the platform was not tested in Pass 1.

**3. Trivy cache and other host caches.** `.local/trivy-cache` is rebuildable. Its Java vulnerability database, needed because Infisical's image holds JARs, comes back on the next `make scan-images`:

```bash
.tools/bin/trivy clean --java-db --cache-dir .local/trivy-cache
```

**4. Registry blobs and mirrors.** The local registry has delete enabled, but deleted manifests free nothing until garbage collection, and the mirrors hold copies of every pulled blob. Removing a mirror's volume frees space at the cost of re-pulling, and it can hit Docker Hub's quota for images `mirror.gcr.io` does not hold.

```bash
export REPO_ROOT="$PWD"
docker compose -f infrastructure/local-services/compose.yaml rm -sf mirror-quay
docker volume rm plane-platform-local_mirror-quay-data
docker compose -f infrastructure/local-services/compose.yaml up -d mirror-quay
```

Do not do this to `registry-data`. It holds the branded images that both overlays name, and those digests exist nowhere else. A rebuild gives other digests, as the cold install's two builds both did ([make up](../evidence/runs/clean-install-20261105T105546Z/make-up-stops-on-new-digests.txt)). Those commands, on one mirror, were not tested in Pass 1. The cold install's `PURGE=yes` removed all the mirrors' volumes and pulled through them again ([summary](../evidence/runs/clean-install-20261105T105546Z/summary.txt)). Its files show no quota being met, but they do not read pull errors, so that says little.

**5. Return freed VM space to the Mac.** Docker's FAQ recommends this after deleting data inside containers:

```bash
docker run --privileged --pid=host docker/desktop-reclaim-space
```

It runs a privileged container from Docker Hub, so read what it does first. Its effect on this host was not tested in Pass 1.

**6. Delete the cluster.** See [Clean rebuild](clean-rebuild.md). Host free space does come back. In `make drill-clean-restore` on 2026-11-05 it went from 17.5 to 31.6 GiB across the first delete, which the script read as 14.1 GiB back. After the second delete it read 19 GiB at 08:10:16Z, and 26.8 GiB at the next plan. The local services and their volumes stayed both times ([log](../evidence/runs/drill-clean-restore-20261105T074859Z.log), lines 59, 74, 98 and 108). The cold drill's delete, with `PURGE`, so with those volumes too, read 31.7 GiB free and 15.6 GiB back, where the check, counting the kind volume alone, expected 27.0 ([log](../evidence/runs/drill-clean-restore-20261105T105347Z.log), line 81).

No delete has a `Docker.raw` reading directly before and after it. The last drill, `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, deleted with kind alone, and read 38,276,744 KiB at the top of [its output](../evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt) and 38,301,404 KiB at the bottom. They bracket the whole drill, delete and restore, so the second holds a restored cluster. Whether `kind delete cluster` alone shrinks that file's allocated size here: Not measured in Pass 1, so measure it with `ls -klsh` before you count on it.

## Confirm

```bash
df -h .
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
make status
```

Free space should be above 25 GiB before a first install, and above the 10 GiB floor for normal work. 25 GiB lets an install start. The cold install, with a second build in it, used about 18 GiB ([above](#diagnosis)).

## What not to do

| Do not | Why |
|---|---|
| `docker system prune -a` | On this host, unrelated containers (`frameflow-minio-1`, `local-r2-minio-1`) run from a cached `quay.io/minio/minio` image that can no longer be pulled anonymously. Removing it may not be recoverable |
| `docker container prune` or any prune after `make down` | The stopped kind node is a stopped container. Pruning removes it, and the cluster with it |
| `docker volume prune` | Removes registry, mirror and possibly other projects' data |
| Lower Docker Desktop's disk limit | Docker's docs warn that this loses every container and image |
| Delete `Docker.raw` | That removes every container and image on the host, including unrelated projects |
| Trust `NodeFilesystem*` or `df` inside a pod | They read the sparse VM disk. `df` on `/backups` inside a pod reads the Mac with the wrong block size |
| Delete a Postgres PVC to free space | That is data loss, for a few hundred MiB. Look at images first |
| Delete from `/var/lib/containerd` directly | It corrupts the store. Use `crictl` |
| Set `MIN_FREE_DISK_GIB=0` to get past a refusal | The guard exists because a full disk gives write errors in Postgres, not a clean stop |

## Hosted production

On hosted production the disk is the node's own, and the traps above do not apply. One filesystem, `/`, holds the system, K3s and its
images, every volume and the backups. It read 387G, with 2.7G used, right after provisioning on 2026-11-06
([hosted-node-20261106T225936Z.txt](../evidence/runs/hosted-node-20261106T225936Z.txt)). At 19:31Z on 2026-11-07 the kubelet read 18.45 GB used of
414.92 GB ([hosted-resources-20261107T193041Z.txt](../evidence/runs/hosted-resources-20261107T193041Z.txt)).

| | Here | Hosted production |
|---|---|---|
| Disk protection | Off: kind sets image GC at 100% and eviction at 0% | On, from [`kubelet.conf`](../../infrastructure/hosted/plane-prod/kubelet.conf): image GC from 75% down to 65%, images unused for 336h removed, and eviction below 10% free or 5% of inodes |
| What sees the real limit | Nothing in the cluster | `NodeDiskLow` under 20% free for 10 minutes, `NodeDiskCritical` under 10% for 5 minutes, `NodeDiskNotRead` when nothing reports `/` ([rules](../../gitops/clusters/plane-prod/platform/monitoring-extras/shared/rules-hosted.yaml)) |
| Volumes | local-path on the VM, size ignored | Class `local-path-retain`, under `/var/lib/rancher/k3s/storage`, reclaim `Retain`. Sizes are not enforced either, and each namespace's `requests.storage` quota caps what claims ask for |
| Backups | `.local/backups` on the Mac | `/srv/wayline/backups`, on the same disk. Its three PVs are 40Gi, 10Gi and 24Gi, which are labels: hostPath enforces nothing |
| Budget | | [`capacity.yaml`](../../infrastructure/hosted/plane-prod/capacity.yaml): 40Gi for the system and images, every quota's `requests.storage`, the backups' 74 GiB among them, and Frameflow's 30Gi of scratch, which `scripts/ci/check-capacity.sh` holds under the 80% where `NodeDiskLow` warns |

**Diagnosis.** `make remote-status TARGET=plane-prod` prints `df -h` of `/` and `/srv/wayline/backups` over SSH. To look closer:

```bash
ssh -i ~/.ssh/wayline_contabo_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=.local/hosted/known_hosts wayline-admin@5.253.234.127 \
  'df -h /; sudo du -sh /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/storage/* /srv/wayline/backups/* /var/log 2>/dev/null; sudo k3s crictl images'
```

**Fix**, cheapest first. None of these has run on hosted production: NOT RUN.

1. **Images.** The kubelet removes unused ones itself from 75% use. `sudo k3s crictl rmi --prune` on the node removes every image no
   container uses now, and a Job's image is pulled again when it next runs.
2. **Backups.** The nightly prunes restic's repositories after each run, and seals the plain predeploy dumps. `make remote-backup TARGET=plane-prod
   CONFIRM=plane-prod ONLY=plane-prod` seals a plain dump at once. Do not remove repository files by hand: [Restore on hosted production](hosted-restore.md#what-not-to-do).
3. **Logs and metrics.** Loki keeps 168h, and Prometheus 15 days or 12GiB, whichever comes first. Their claims of 10Gi and 16Gi are
   labels that local-path does not enforce, so those retention settings are what bound them.
4. **A volume that grew.** Find it under `/var/lib/rancher/k3s/storage`, and fix what writes it. Never delete a volume's folder: reclaim is
   `Retain` so that a deleted claim keeps its data.

**This Mac's disk** still matters for hosted work. `make remote-pull-backups` and `make remote-backup-dest VERB=verify` check it with
`guard_disk` first, because a pull copies both repositories here and a verify restores them into a folder here.
