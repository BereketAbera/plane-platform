output "argocd_url" {
  description = "Argo CD UI, through scripts/hosted/ui.sh argocd. It has no public route."
  value       = module.argocd.url
}

output "namespaces" {
  description = "Namespaces owned by Terraform."
  value       = sort(keys(module.foundation.namespaces))
}
