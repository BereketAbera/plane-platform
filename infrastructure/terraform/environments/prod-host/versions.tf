terraform {
  required_version = "~> 1.17.0"

  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "0.1.44"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "5.26.1"
    }
  }

  # Relative to this directory. .local/ is gitignored, and scripts/destroy.sh never touches this path. The state holds the one DNS
  # record's id and value and no credential, because credentials come from the environment.
  backend "local" {
    path = "../../../../.local/hosted/plane-prod/terraform-host/terraform.tfstate"
  }
}
