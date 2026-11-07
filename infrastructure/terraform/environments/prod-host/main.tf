locals {
  target = yamldecode(file("${path.module}/../../../hosted/plane-prod/target.yaml"))
}

# A data source, never a resource. contabo_instance plans an in-place change that reinstalls the disk when ssh_keys, root_password,
# user_data, image_id or default_user differ, and destroy cancels the contract. prevent_destroy stops neither, so this root must never
# hold it as a resource.
data "contabo_instance" "vps" {
  id = tostring(local.target.contabo_instance_id)
}

# Vercel treats the record by its id, with no listing of the zone, so nothing else in it can change.
import {
  to = vercel_dns_record.wayline
  id = "${local.target.vercel_team_id}/${local.target.vercel_record_id}"
}

resource "vercel_dns_record" "wayline" {
  team_id = local.target.vercel_team_id
  domain  = "bereket.dev"
  name    = "wayline"
  type    = "A"
  ttl     = 60
  value   = local.target.host

  lifecycle {
    prevent_destroy = true

    # A record that points away from the VPS is a public mistake, and target.yaml is what every script trusts.
    precondition {
      condition     = data.contabo_instance.vps.ip_config[0].v4[0].ip == local.target.host
      error_message = "Contabo says this instance's address is ${data.contabo_instance.vps.ip_config[0].v4[0].ip}, and infrastructure/hosted/plane-prod/target.yaml says ${local.target.host}. Fix target.yaml first, because the firewall, policies and scripts all read it."
    }
  }
}

# Made here for the same reason as grafana's. A Certificate for this name ordered before this record is live fails, and its next try is an
# hour or more away, so this goes first: scripts/hosted/README.md, section The first certificate.
resource "vercel_dns_record" "infisical" {
  team_id = local.target.vercel_team_id
  domain  = "bereket.dev"
  name    = trimsuffix(local.target.infisical_domain, ".bereket.dev")
  type    = "A"
  ttl     = 60
  value   = local.target.host

  lifecycle {
    prevent_destroy = true

    # The same public mistake as above, and the same file to fix.
    precondition {
      condition     = data.contabo_instance.vps.ip_config[0].v4[0].ip == local.target.host
      error_message = "Contabo says this instance's address is ${data.contabo_instance.vps.ip_config[0].v4[0].ip}, and infrastructure/hosted/plane-prod/target.yaml says ${local.target.host}. Fix target.yaml first, because the firewall, policies and scripts all read it."
    }
  }
}

# Made here and not imported: the zone's wildcard answered for this name until now, and that points at Vercel, not at this VPS.
resource "vercel_dns_record" "grafana" {
  team_id = local.target.vercel_team_id
  domain  = "bereket.dev"
  name    = trimsuffix(local.target.grafana_domain, ".bereket.dev")
  type    = "A"
  ttl     = 60
  value   = local.target.host

  lifecycle {
    prevent_destroy = true

    # The same public mistake as above, and the same file to fix.
    precondition {
      condition     = data.contabo_instance.vps.ip_config[0].v4[0].ip == local.target.host
      error_message = "Contabo says this instance's address is ${data.contabo_instance.vps.ip_config[0].v4[0].ip}, and infrastructure/hosted/plane-prod/target.yaml says ${local.target.host}. Fix target.yaml first, because the firewall, policies and scripts all read it."
    }
  }
}
