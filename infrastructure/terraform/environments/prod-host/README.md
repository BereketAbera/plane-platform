# environments/prod-host: the VPS and its DNS records

Two things outside the cluster, in a root of their own, so that a cluster plan never needs these credentials.

- `data "contabo_instance"`: read only, and only ever a data source. As a resource, the Contabo provider can reinstall the disk or cancel the
  contract, and `prevent_destroy` stops neither.
- `vercel_dns_record.wayline`: the A record for `wayline.bereket.dev`, imported by its id, with `prevent_destroy`.
- `vercel_dns_record.grafana`: the A record for `grafana.bereket.dev`, made here, with `prevent_destroy`, so the zone's wildcard no longer answers
  for that name.
- `vercel_dns_record.infisical`: the A record for `infisical.bereket.dev`, made the same way and for the same reason.
- `vercel_dns_record.frameflow`: the A record for `frameflow.bereket.dev`, made the same way and for the same reason.
- `vercel_dns_record.rillmark`: the A record for `rillmark.bereket.dev`, the same.
- `vercel_dns_record.cloudgarden`: the A record for `devops.bereket.dev`, Awushi Cloudgarden's host, the same.

Each app's record has to be live before Argo CD first sees that app's Certificate, because the wildcard points at Vercel and a failed order
waits an hour or more to try again. So apply this root before the change that adds the Certificate reaches `deploy/plane-prod`. There are A
records only: the cluster is IPv4 single-stack, and none of `wayline`, `grafana` and `infisical` has an AAAA.

Vercel's provider acts on one record id and never lists the zone, so nothing else in `bereket.dev` can change. It also cannot see a record it
does not hold: run `vercel dns ls bereket.dev` first, because a `grafana`, `infisical`, `frameflow`, `rillmark` or `devops` record made by
hand would become a second A beside Terraform's.

Credentials come from the environment, as [`providers.tf`](providers.tf) lists, and never from a file in Git. State is at
`.local/hosted/plane-prod/terraform/host/terraform.tfstate`, relative to the checkout, and only the checkout that made it holds it. From any
other, Terraform starts from nothing: it imports wayline's record again and makes a second A record for each of the others. So
`scripts/hosted/host-terraform.sh`, which runs Terraform with the credentials the two CLIs already hold, stops when that file is missing, and
`apply` applies only a plan whose changes are exactly the ones you name:

```bash
TARGET=plane-prod scripts/hosted/host-terraform.sh plan
# Before infisical's record existed it ended: This plan: create vercel_dns_record.infisical, and this applied it:
#   TARGET=plane-prod CONFIRM=plane-prod EXPECT='create vercel_dns_record.infisical' scripts/hosted/host-terraform.sh apply
# With wayline's, grafana's and infisical's records in state it ends, three to add and no other change:
# This plan: create vercel_dns_record.cloudgarden, create vercel_dns_record.frameflow, create vercel_dns_record.rillmark
TARGET=plane-prod CONFIRM=plane-prod \
  EXPECT='create vercel_dns_record.cloudgarden, create vercel_dns_record.frameflow, create vercel_dns_record.rillmark' \
  scripts/hosted/host-terraform.sh apply
# Once all six records are in state and nothing changes, the plan ends: This plan: nothing.
```

If the plan shows anything else, stop and read it. `apply` makes its own plan again and refuses, applying nothing, unless its changes are
the ones in `EXPECT`.
