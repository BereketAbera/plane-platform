# 0002. The kind CLI creates the cluster, not Terraform

**Status:** Accepted, 2026-11-04.

## Context

Terraform's `kubernetes` and `helm` providers read a kubeconfig during plan. So the cluster has to exist before any plan that uses them. HashiCorp's provider documentation warns against passing credentials from a resource to the Kubernetes provider in the same module, because it leads to intermittent errors.

So one root that creates the cluster and its contents is out. The real choice is between a shell step and a second Terraform root.

This is a laptop cluster. It gets stopped and resumed often (`make down`, `make up`). Its node is a Docker container whose config cannot be changed in place, and containerd needs its mirror configuration mounted before the first image pull.

## Decision

`scripts/cluster-up.sh` runs `kind create cluster` with a config rendered from `infrastructure/kind/cluster.yaml.tmpl`. The node image is pinned by digest. Terraform starts only after that, and its root takes the kubeconfig path and context as inputs.

The script is idempotent. It starts a stopped node instead of recreating it, and fails if the `kind` Docker network falls outside `172.16.0.0/12`, because NetworkPolicies assume that range ([0010](0010-networkpolicy-under-kindnet.md)).

What kind owns, and why it has to be set at creation:

| Setting | Value | Why at creation |
|---|---|---|
| Port mappings | `127.0.0.1:80` and `:443` to NodePorts 30080 and 30443 | Loopback only. kind's default of `0.0.0.0` would expose unauthenticated UIs to the LAN |
| Mount | `infrastructure/kind/containerd-certs.d` to `/etc/containerd/certs.d`, read-only | Must be present before containerd pulls anything |
| Mount | `.local/backups` to `/backups` | Backups must survive cluster deletion |

## Alternatives considered

| Alternative | Why not |
|---|---|
| One Terraform root for the cluster and its contents | The provider warning above |
| Two roots, with a `cluster` root using the community `tehcyx/kind` provider | See the table below |
| A bash wrapper around `terraform apply` with `-target` | Works around the problem rather than removing it, and hides the ordering in flags |

| Criterion | kind CLI plus Terraform (chosen) | `tehcyx/kind` root (v0.13.0, research, 2026-11-04) |
|---|---|---|
| Dependencies | First-party tool only | Adds a community provider with one lead maintainer |
| Changing config | Delete and recreate, explicitly | `ForceNew` attributes, so a `-/+` in a plan that is easy to approve by accident |
| Stopped node | No effect | `Read` runs `cat /etc/kubernetes/admin.conf` in the node, so `plan` errors when the node or Docker is down |
| Upstream lag | None | About 8 weeks last time (kind v0.33.0 on 2026-08-26, provider bump on 2026-10-21) |
| State | None for a throwaway cluster | State holds kubeconfig keys |
| "Everything in Terraform" story | Weaker | Stronger |

The last row is the honest cost of this decision. The two-root option is viable. It lost on laptop lifecycle and on having one fewer dependency, not because it cannot work.

## Consequences

- **Terraform does not create or manage the cluster in Pass 1.** It manages only what is listed in [0001](0001-ownership-boundaries.md), inside a cluster that already exists. Any description of this platform has to keep that distinction.
- Changing a port mapping, a mount or the node image means deleting and recreating the cluster. `make destroy` does that and takes a backup first unless `SKIP_BACKUP=yes`.
- `make down` stops the node container and the local services. `make up` starts them again. On 2026-11-05 `make down` took 15 s and `make up` 82 s, and the sentinel row and attachment read back in both environments ([PERS-3](../evidence/runs/PERS-3-20261105T083304Z.txt)). One stop, on test data. The pod restart drills replaced each data pod and kept its claim and data ([dev](../evidence/runs/drill-pod-restart-dev-20261105T070414Z.log), [prod-sim](../evidence/runs/drill-pod-restart-prod-sim-20261105T072331Z.log)), which is not a node stop.
- The Pass 2 seam is the pair `kubeconfig_path` and `kube_context`. Pass 1 proposed, in each placeholder root's `INTERFACE.md`, a separate `cluster` root for Hetzner that would produce them. That root was never built. Hosted production's `environments/prod` takes the same pair, for a K3s node that `scripts/hosted/provision-node.sh` installs and an SSH tunnel reaches, so Terraform creates no cluster there either ([terraform.md](../terraform.md#hosted-production)).
- The cluster gets kind's kubelet defaults, including no image garbage collection and no disk-based eviction (research, 2026-11-04, `pkg/cluster/internal/kubeadm/config.go`). So `guard_disk` runs on the host in the scripts that write, because the Docker VM reports free space the host does not have. Contract section 11 lists which do not.
- `scripts/cluster-up.sh` finished in 2s against the running cluster on 2026-11-04 ([bootstrap-up-traefik-1.txt](../evidence/runs/bootstrap-up-traefik-1.txt)). Against a stopped node it ran inside `make up` on 2026-11-05, in 82 s in all ([PERS-3](../evidence/runs/PERS-3-20261105T083304Z.txt)).

## What we found when we ran it

Added 2026-11-05.

- Docker gave the `kind` network `172.24.0.0/16` on this host, inside the assumed pool ([bootstrap-up-traefik-1.txt](../evidence/runs/bootstrap-up-traefik-1.txt)).
- Each run of the script recreated `plane-git`, because buildx stamped a provenance attestation that gave the same layers a new image ID. `7708cc8` sets `BUILDX_NO_DEFAULT_ATTESTATIONS=1`, since Argo CD reads Git through that container.
- A disk floor of 15 GiB on every run could strand a platform whose first install had already used the space. So since `7708cc8` a resume needs only the default floor, and 15 GiB applies only when creating a cluster. The cold install ended with 13 GiB free, and its second `make up` ran in 16 s, which the old floor would have refused ([readings](../evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt), [summary](../evidence/runs/clean-install-20261105T105546Z/summary.txt)).
