# scripts/hosted: everything that touches the VPS

`lib.sh` is the only way to reach the cluster from a script that needs it. It sources `scripts/lib/common.sh`, which stays hard-wired to
kind, overrides `KUBECONFIG`, `KUBE_CONTEXT`, `LOCAL_DIR` and `kc`, needs `TARGET=plane-prod`, and refuses to go on unless the live
`kube-system` UID and node name match [`infrastructure/hosted/plane-prod/target.yaml`](../../infrastructure/hosted/plane-prod/target.yaml).
What changes something also needs `CONFIRM=plane-prod`, and `CONFIRM=yes` does not count. `provision-node.sh` and `edge.sh` stand apart from
it, because they run before there is a cluster to compare with.

Through make: `make remote-<verb> TARGET=plane-prod`. No local target can reach this cluster.

| Script | Does | Target |
|---|---|---|
| `tunnel.sh` | SSH tunnel, 127.0.0.1:16443 to the node's 6443. Started by `lib.sh` when needed | `remote-tunnel` |
| `kubeconfig.sh` | Fetch K3s's kubeconfig, rewrite it for the tunnel, and print the UID for `target.yaml` | `remote-kubeconfig` |
| `status.sh` | Read-only summary | `remote-status` |
| `bootstrap.sh` | Deploy key, Terraform, backup folders, restic password, secret zero, Infisical, alerts, bundle | `remote-bootstrap` |
| `ui.sh` | Port-forward an admin UI, which has no public route | `remote-ui` |
| `alerts.sh` | Render `alertmanager.yaml` from the owner's files into a Secret, and say COMPLETE or INCOMPLETE | `remote-alerts` |
| `bundle.sh` | The age-encrypted recovery bundle, proved by decrypting it again | `remote-bundle` |
| `backup.sh` | Run tonight's backups now, from the CronJobs | `remote-backup` |
| `pull-backups.sh` | Copy the encrypted repositories here, over a read-only SFTP user | `remote-pull-setup`, `remote-pull-backups` |
| `backup-dest.sh` | `verify`, `push` and `status` of the copies off the VPS | `remote-backup-dest` |
| `restore-test.sh` | Restore into an isolated namespace, prove it, and remove it, on the VPS or in kind | `remote-restore-test` |
| `smoke.sh` | `tests/e2e/smoke.py --env hosted --mode verify` on an existing account, asked at a hidden prompt | `remote-smoke` |
| `test-hosted.sh` | The hosted test suite. Exits 0, 1 or 2, and says BLOCKED or INCOMPLETE plainly | `remote-test` |
| `target.sh` | The opt-in shared scripts source when `WAYLINE_TARGET` is set: `scripts/secret-zero.sh`, `infisical-bootstrap.sh`, `infisical-seed.sh`, `test-netpol.sh`, `infisical/tests/rendered-secrets.sh` | |

Local state lives in `.local/hosted/plane-prod/`, mode 0700, and never in Git. Bash 3.2, because macOS ships it.
