output "namespaces" {
  description = "Every namespace this module owns, by name. Referencing an entry orders work after that namespace exists."
  value       = { for name, ns in kubernetes_namespace_v1.this : name => ns.metadata[0].name }
}
