# environments/prod: hosted production's cluster bootstrap

Namespaces with their PSA levels, quotas and limit ranges (from [`infrastructure/hosted/plane-prod/capacity.yaml`](../../../hosted/plane-prod/capacity.yaml)),
storage class `local-path-retain`, K3s's `coredns-custom` rewrites, the Argo CD release, and the bootstrap chart with AppProjects
`platform`, `plane-prod`, `frameflow`, `rillmark` and `awushi-cloudgarden` and the `root` Application. Argo CD deploys everything else, from
branch `deploy/plane-prod`.

Each app's namespace, quota and AppProject come from here, and so does the CoreDNS rewrite for its host, without which its Certificate never
becomes Ready. So apply this root before the change that names them reaches `deploy/plane-prod`. Otherwise `network-policies`, at wave -10,
fails on the missing namespace, or an Application naming a project that does not exist yet holds the root with no retry. Either stops
Wayline's releases too.

It is applied only through `scripts/hosted/bootstrap.sh`, against `.local/hosted/plane-prod/kubeconfig` and the SSH tunnel, with state at
`.local/hosted/plane-prod/terraform/terraform.tfstate`. No variable can point it elsewhere, and a plan stops unless the live `kube-system`
UID matches `infrastructure/hosted/plane-prod/target.yaml`. So `kube_system_uid` there must be recorded first.

`terraform validate` needs no cluster: `terraform -chdir=infrastructure/terraform/environments/prod init -backend=false`, then `validate`.
It has run against hosted production since 2026-11-07: the first bootstrap applied 26 resources and then 2, and the second found nothing
to change ([first](../../../../docs/evidence/runs/hosted-bootstrap-20261107T042651Z.txt), [second](../../../../docs/evidence/runs/hosted-bootstrap-20261107T050333Z.txt)).

Bootstrap applies with `-auto-approve` and shows no plan first, and no namespace has `prevent_destroy`, so a key dropped or renamed in
`main.tf`'s `namespaces` deletes that namespace and its claims. So read a plan before bootstrap applies a change here. It changes nothing, and
should end `0 to destroy`:

```bash
make remote-tunnel TARGET=plane-prod
.tools/bin/terraform -chdir=infrastructure/terraform/environments/prod init -input=false -lockfile=readonly
.tools/bin/terraform -chdir=infrastructure/terraform/environments/prod plan -input=false
```

**Do not run `terraform destroy` here.** It deletes the namespaces, and with them every claim. The volumes stay, on reclaim Retain, but
nothing would be bound to them. See [`environments/prod-host`](../prod-host) for the VPS and the DNS records, which this root does not touch.
