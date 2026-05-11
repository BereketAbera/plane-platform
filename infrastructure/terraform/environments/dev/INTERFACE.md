# environments/dev interface (pass 2, untested)

A contract for a root module that does not exist yet. Every name below is a proposal until pass 2 builds and runs it.

## Shape

Two roots, or the kubeconfig problem in `infrastructure/terraform/README.md` returns: a `cluster` root creates the
Hetzner servers and Kubernetes, then this root reads its outputs and calls the same two modules that `environments/local` calls.

## Variables the Hetzner implementation must take

| Variable | Type | Sensitive | Purpose |
|---|---|---|---|
| `hcloud_token` | string | yes | Hetzner API token. From `TF_VAR_hcloud_token` at runtime, never a file in Git |
| `location` | string | no | Hetzner location |
| `server_type` | string | no | Node size. Must fit the memory budget in contract section 10 |
| `ssh_public_key` | string | no | Admin access to nodes |
| `admin_cidrs` | list(string) | no | Sources allowed to reach SSH and the Kubernetes API. No default, so it cannot silently be open |
| `kubernetes_version` | string | no | Exact version, as contract section 1 does for kind |
| `base_domain` | string | no | Public parent domain, replacing `*.localhost` |
| `cloudflare_api_token` | string | yes | DNS and TLS at Cloudflare (contract section 3). From `TF_VAR_cloudflare_api_token` at runtime |
| `git_repo_url` | string | no | GitHub URL. Passed to `modules/argocd`, replacing `git://plane-git/plane-platform.git` |
| `git_target_revision` | string | no | Passed to `modules/argocd` |

## Outputs it must produce

| Output | Consumed by |
|---|---|
| `kubeconfig_path`, `kube_context` | The `kubernetes` and `helm` provider blocks of this root, the same two values `environments/local` uses |
| `argocd_url` | Operators. `environments/local` already has this output |
| `namespaces` | Operators. `environments/local` already has this output |
| `node_ipv4` | DNS records and the origin firewall |

## What changes when the modules are reused

- `modules/foundation`: leave `coredns_rewrites` empty unless the same pod-to-public-host problem exists. Its template is
  the kubeadm Corefile for Kubernetes 1.36 and would overwrite a different distribution's config.
- `modules/argocd`: needs its own values file, because `helm/values/argocd.yaml` hard-codes `argocd.localhost` and plain HTTP.
- `gitops/bootstrap/chart`: `sourceRepos` follows `git_repo_url` through a value. `gitops/bootstrap/argocd-route` hard-codes
  its host and the `web` entrypoint, so it needs an overlay.

## Remote state template

Local state does not work for a shared environment. Hetzner Object Storage is S3-compatible, so this uses the `s3`
backend. Terraform 1.17 `terraform init` accepted these arguments and failed only at the network call, against a dead local
endpoint. The template has never reached a real bucket, and whether the service supports `use_lockfile` conditional
writes is unknown, so test locking before relying on it.

```hcl
# terraform {
#   backend "s3" {
#     bucket = "CHANGE-ME-state-bucket"
#     key    = "plane-platform/dev/terraform.tfstate"
#     region = "CHANGE-ME"
#
#     endpoints = {
#       s3 = "https://CHANGE-ME.your-objectstorage.com"
#     }
#
#     # Not AWS, so skip the AWS-only checks.
#     skip_credentials_validation = true
#     skip_metadata_api_check     = true
#     skip_region_validation      = true
#     skip_requesting_account_id  = true
#     skip_s3_checksum            = true
#
#     use_lockfile = true
#   }
# }
#
# Credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY at runtime. Never write them here.
```
