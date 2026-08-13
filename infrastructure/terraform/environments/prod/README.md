# environments/prod: hosted production's cluster bootstrap

Namespaces with their PSA levels, quotas and limit ranges (from [`infrastructure/hosted/plane-prod/capacity.yaml`](../../../hosted/plane-prod/capacity.yaml)),
storage class `local-path-retain`, K3s's `coredns-custom` rewrite, the Argo CD release, and the bootstrap chart with AppProjects
`platform` and `plane-prod` and the `root` Application. Argo CD deploys everything else, from branch `deploy/plane-prod`.

It runs only through `scripts/hosted/bootstrap.sh`, against `.local/hosted/plane-prod/kubeconfig` and the SSH tunnel, with state at
`.local/hosted/plane-prod/terraform/terraform.tfstate`. No variable can point it elsewhere, and a plan stops unless the live `kube-system`
UID matches `infrastructure/hosted/plane-prod/target.yaml`. So `kube_system_uid` there must be recorded first.

`terraform validate` needs no cluster: `terraform -chdir=infrastructure/terraform/environments/prod init -backend=false`, then `validate`.
Not run against a cluster yet.

**Do not run `terraform destroy` here.** It deletes the namespaces, and with them every claim. The volumes stay, on reclaim Retain, but
nothing would be bound to them. See [`environments/prod-host`](../prod-host) for the VPS and the DNS record, which this root does not touch.
