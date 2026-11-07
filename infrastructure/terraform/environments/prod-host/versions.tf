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

  # Relative to this directory. .local/ is gitignored, and scripts/destroy.sh never touches this path. Under terraform/, because
  # scripts/hosted/bundle.sh puts every state there into the recovery bundle. It holds each DNS record's id and value and no
  # credential, because credentials come from the environment.
  backend "local" {
    path = "../../../../.local/hosted/plane-prod/terraform/host/terraform.tfstate"
  }
}
