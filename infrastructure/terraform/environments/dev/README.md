# environments/dev: not operational

**This is an untested template for pass 2 (Hetzner). It contains no Terraform and nothing here has ever run.**
There is no `versions.tf` and no resource on purpose, so `terraform init` here does nothing useful.

[`INTERFACE.md`](INTERFACE.md) records what the pass 2 implementation must take and produce so that
`modules/foundation` and `modules/argocd` can be reused, plus a commented remote state template.
Pass 1 runs only from [`environments/local`](../local).
