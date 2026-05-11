# Authentication comes from the environment (INFISICAL_AUTH_METHOD=token, INFISICAL_TOKEN), so the
# admin token never appears in a variable, a plan or state.
provider "infisical" {
  host = var.infisical_host
}

locals {
  # One project per environment is the free-tier isolation boundary. Custom roles and folder RBAC are
  # paid, and additional privileges return 400 on projects created today. See ../README.md.
  environments = {
    dev = {
      project   = "plane-dev"
      namespace = "plane-dev"
    }
    prod-sim = {
      project   = "plane-prod-sim"
      namespace = "plane-prod-sim"
    }
  }

  # The slug is the same in both projects so one InfisicalStaticSecret shape fits both.
  environment_slug = "prod"
}

resource "infisical_project" "plane" {
  for_each = local.environments

  name = each.value.project
  slug = each.value.project
  type = "secret-manager"

  # The only environment is the one declared below. Cannot change after creation.
  should_create_default_envs = false
}

resource "infisical_project_environment" "prod" {
  for_each = local.environments

  project_id = infisical_project.plane[each.key].id
  name       = local.environment_slug
  slug       = local.environment_slug
  # Set explicitly: the API rejects positions below 1.
  position = 1
}

resource "infisical_identity" "reader" {
  for_each = local.environments

  name   = "${each.value.project}-reader"
  org_id = var.org_id
  # Reaches nothing through the organization, only through the one project membership below.
  role = "no-access"
}

resource "infisical_project_identity" "reader" {
  for_each = local.environments

  project_id  = infisical_project.plane[each.key].id
  identity_id = infisical_identity.reader[each.key].id
  roles = [
    {
      role_slug = "viewer"
    }
  ]
}

resource "infisical_identity_kubernetes_auth" "reader" {
  for_each = local.environments

  identity_id = infisical_identity.reader[each.key].id

  # Attaching dials this host, so the Infisical pod needs egress to the API server already.
  token_reviewer_mode       = "api"
  kubernetes_host           = var.kubernetes_host
  kubernetes_ca_certificate = var.kubernetes_ca_certificate
  # token_reviewer_jwt stays unset: the incoming token reviews itself. See token-reviewer.yaml.

  allowed_namespaces            = [each.value.namespace]
  allowed_service_account_names = [var.service_account_name]

  # allowed_audience stays unset. A token minted for another audience could not authenticate to the
  # API server, and that is the token doing the review here.

  # The operator logs in again at 70% of this. Both move together (infisical#7516).
  access_token_ttl     = 3600
  access_token_max_ttl = 3600

  depends_on = [infisical_project_identity.reader]
}
