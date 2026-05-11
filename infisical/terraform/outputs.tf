# None of these are secrets. Identity ids change on every re-bootstrap, so they are published to the
# cluster by scripts/infisical-bootstrap.sh and never committed.
output "project_ids" {
  description = "Project id per environment."
  value       = { for env, project in infisical_project.plane : env => project.id }
}

output "project_slugs" {
  description = "Project slug per environment, which is what InfisicalStaticSecret references."
  value       = { for env, project in infisical_project.plane : env => project.slug }
}

output "environment_slug" {
  description = "Environment slug inside every project."
  value       = local.environment_slug
}

output "identity_ids" {
  description = "Reader machine identity id per environment."
  value       = { for env, identity in infisical_identity.reader : env => identity.id }
}
