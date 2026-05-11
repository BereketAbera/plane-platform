output "url" {
  description = "Argo CD UI URL, read from the values file so there is one source for it."
  value       = yamldecode(file(var.values_file)).configs.cm.url
}
