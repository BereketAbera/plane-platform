# Disk pressure

The Mac is the real limit, and nothing inside the cluster can see it.

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NODE=plane-platform-control-plane
```

## Why this is different from a normal cluster

Three traps were found by reading kind and Docker Desktop sources (critique section 5). Each breaks a normal assumption.

| Trap | What happens | Consequence |
|---|---|---|
| **kind disables disk protection** | `pkg/cluster/internal/kubeadm/config.go` sets `imageGCHighThresholdPercent: 100` and `evictionHard` with `nodefs.available: "0%"` and `imagefs.available: "0%"` | No image garbage collection and no eviction. Old images stay until removed by hand. A full disk gives write errors, not pod eviction |
| **The VM cannot see the real limit** | The VM filesystem reports hundreds of free GiB on a sparse disk, while the Mac may have far less | `NodeFilesystem*` alerts watch the VM disk only, and will not fire before the Mac runs out. `/backups`, Docker Desktop's mount of the Mac, is excluded from node-exporter: it reported 4397 GiB available with 17 GiB free, which sent the percentage rules critical on a healthy cluster (`helm/values/kube-prometheus-stack.yaml`). local-path ignores PVC size |
| **`Docker.raw` does not shrink by itself** | Docker's docs say space comes back when images are deleted, but not automatically when files are deleted inside running containers | Deleting data inside the VM may not return space to the Mac |

Confirm the first on the running node:

```bash
docker exec "$NODE" grep -E 'imageGC|nodefs|imagefs' /var/lib/kubelet/config.yaml
```

[[VERIFY: the node's kubelet config shows imageGCHighThresholdPercent 100 and 0% eviction thresholds]]

## Symptoms

| Symptom | Where |
|---|---|
| `only N GiB free on the host, need at least M GiB` | `guard_disk`, from most scripts. The default floor is 10 GiB. On a new cluster `up.sh` needs 25 and `cluster-up.sh` 15. `make test` and the failed-deploy and pod-restart drills need 2, and `make promote`, `make rollback`, `make gitops-publish`, `make render` and `make test-netpol` need 1 |
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

Budget, for comparing what you see. Both figures are estimates from critique section 5, made before anything was deployed. Workload images on the node come to about 8.56 GiB unpacked, derived from each gzip layer's size trailer in the registry. Total host growth of 16.7 to 22 GiB adds planning figures for volumes and logs. [Resource utilization](../resource-utilization.md#disk) adds the caches.

[[MEASURE: actual Docker.raw growth and host free space after a first full install]]

## Fix

Work down this list. Each step costs more than the last.

**1. Old backups.** Retention keeps 3 for dev and 5 for others. `make backup ENV=all KEEP=2` removed the older ones on 2026-11-05 ([dr-backup-retention-1.txt](../evidence/runs/dr-backup-retention-1.txt)). To keep fewer on the next run:

```bash
make backup ENV=dev KEEP=1
```

Remove by hand only with a newer good backup in place.

**2. Old images on the node.** Nothing removes them automatically. Each Plane version bump can leave up to about 2.2 GiB, an estimate from the unpacked size of the five Plane images (critique section 5). This removes images no running container uses:

```bash
docker exec "$NODE" crictl rmi --prune
```

Anything removed is pulled again when next needed. Jobs such as the backup's rclone image and k6 will re-pull from the pull-through caches, so expect a delay. [[VERIFY: crictl rmi --prune leaves running workloads unaffected and frees space inside the VM]]

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

Do not do this to `registry-data`. It holds the branded images that dev's overlay names, and they exist nowhere else until rebuilt, and a rebuild can give other digests. [[VERIFY: removing one mirror volume and restarting it leaves pulls working through the cache]]

**5. Return freed VM space to the Mac.** Docker's FAQ recommends this after deleting data inside containers:

```bash
docker run --privileged --pid=host docker/desktop-reclaim-space
```

It runs a privileged container from Docker Hub, so read what it does first. [[VERIFY: docker/desktop-reclaim-space shrinks Docker.raw on this host, measured with ls -klsh before and after]]

**6. Delete the cluster.** See [Clean rebuild](clean-rebuild.md). Whether `kind delete cluster` alone shrinks `Docker.raw` here is unresolved, so measure it. [[VERIFY: Docker.raw allocated size before and after kind delete cluster]]

## Confirm

```bash
df -h .
ls -klsh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
make status
```

Free space should be above 25 GiB before a first install, and above the 10 GiB floor for normal work.

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
