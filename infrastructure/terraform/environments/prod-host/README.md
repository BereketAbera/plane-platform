# environments/prod-host: the VPS and its DNS record

Two things outside the cluster, in a root of their own, so that a cluster plan never needs these credentials.

- `data "contabo_instance"`: read only, and only ever a data source. As a resource, the Contabo provider can reinstall the disk or cancel the
  contract, and `prevent_destroy` stops neither.
- `vercel_dns_record.wayline`: the one A record for `wayline.bereket.dev`, imported by its id, with `prevent_destroy`. Vercel's provider acts on
  one record id and never lists the zone, so nothing else in `bereket.dev` can change.

Credentials come from the environment, as [`providers.tf`](providers.tf) lists, and never from a file in Git. State is at
`.local/hosted/plane-prod/terraform-host/terraform.tfstate`.

```bash
TF=infrastructure/terraform/environments/prod-host
terraform -chdir=$TF init
terraform -chdir=$TF plan    # expect one import, and no other change
terraform -chdir=$TF apply
```

If the plan shows anything but the import, stop and read it. Not yet planned or applied against either service.
