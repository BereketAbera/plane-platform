variable "infisical_host" {
  description = "URL of the Infisical instance, as seen from the host running Terraform."
  type        = string
  default     = "http://infisical.localhost"
}

variable "org_id" {
  description = "Organization created by /api/v1/admin/bootstrap. Terraform cannot create the root org, and it is instance-specific, so the bootstrap script passes it."
  type        = string
}

variable "kubernetes_host" {
  description = "API server URL as Infisical reaches it from inside the cluster, for token review."
  type        = string
  default     = "https://kubernetes.default.svc.cluster.local"
}

variable "kubernetes_ca_certificate" {
  description = "PEM CA of the cluster, from ConfigMap kube-root-ca.crt. Public. Supplying it turns TLS verification on. A new cluster has a new CA, so rerun Terraform after recreating it."
  type        = string
}

variable "service_account_name" {
  description = "ServiceAccount each InfisicalAuth references in its own namespace. Must match the Plane overlay and infisical/manifests/token-reviewer.yaml."
  type        = string
  default     = "plane-infisical-auth"
}

variable "environments" {
  description = "Project and namespace for each environment. The default is the local platform's, so its plan stays empty. Hosted production passes its own through TF_VAR_environments, from scripts/hosted/target.sh."
  type = map(object({
    project   = string
    namespace = string
  }))
  default = {
    dev = {
      project   = "plane-dev"
      namespace = "plane-dev"
    }
    prod-sim = {
      project   = "plane-prod-sim"
      namespace = "plane-prod-sim"
    }
  }
}
