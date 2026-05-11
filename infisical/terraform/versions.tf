terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    infisical = {
      source  = "infisical/infisical"
      version = "0.20.10"
    }
  }

  # State and instance share one lifecycle: a fresh Infisical needs fresh state, which
  # scripts/infisical-bootstrap.sh takes care of. Relative to this directory, gitignored.
  backend "local" {
    path = "../../.local/terraform/infisical/terraform.tfstate"
  }
}
