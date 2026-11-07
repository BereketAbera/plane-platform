output "instance" {
  description = "What Contabo says the VPS is. Read only."
  value = {
    name      = data.contabo_instance.vps.name
    status    = data.contabo_instance.vps.status
    cpu_cores = data.contabo_instance.vps.cpu_cores
    ram_mb    = data.contabo_instance.vps.ram_mb
    disk_mb   = data.contabo_instance.vps.disk_mb
    ipv4      = data.contabo_instance.vps.ip_config[0].v4[0].ip
  }
}

output "dns_record" {
  description = "Wayline's DNS record."
  value       = "${vercel_dns_record.wayline.name}.${vercel_dns_record.wayline.domain} ${vercel_dns_record.wayline.type} ${vercel_dns_record.wayline.value}"
}

output "grafana_dns_record" {
  description = "Grafana's DNS record."
  value       = "${vercel_dns_record.grafana.name}.${vercel_dns_record.grafana.domain} ${vercel_dns_record.grafana.type} ${vercel_dns_record.grafana.value}"
}

output "infisical_dns_record" {
  description = "Infisical's DNS record."
  value       = "${vercel_dns_record.infisical.name}.${vercel_dns_record.infisical.domain} ${vercel_dns_record.infisical.type} ${vercel_dns_record.infisical.value}"
}
