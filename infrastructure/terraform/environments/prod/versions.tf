terraform {
  required_version = "~> 1.17.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }

  # Relative to this directory. .local/ is gitignored, and this path is beyond what scripts/destroy.sh removes.
  backend "local" {
    path = "../../../../.local/hosted/plane-prod/terraform/terraform.tfstate"
  }
}
