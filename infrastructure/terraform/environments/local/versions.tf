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

  # Relative to this directory. .local/ is gitignored, and scripts/destroy.sh removes this path
  # when it deletes the cluster the state describes.
  backend "local" {
    path = "../../../../.local/terraform/local/terraform.tfstate"
  }
}
