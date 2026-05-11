output "argocd_url" {
  description = "Argo CD UI. Answers only after the root Application has synced Traefik and the route."
  value       = module.argocd.url
}

output "namespaces" {
  description = "Namespaces owned by Terraform."
  value       = sort(keys(module.foundation.namespaces))
}
