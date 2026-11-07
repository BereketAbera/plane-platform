#!/bin/sh
# /usr/local/sbin/wayline-reboot-metric, from /etc/cron.d/wayline-reboot-metric. Tells node-exporter whether a security update
# is waiting for a reboot, because unattended-upgrades does not reboot by itself here, and whether the public firewall's table
# is loaded, because the API and kubelet ports answer on the public address without it. Written atomically, so no scrape reads half.
dir=/var/lib/node_exporter/textfile
mkdir -p "$dir"
tmp="$(mktemp "$dir/.reboot.XXXXXX")"
if [ -f /var/run/reboot-required ]; then value=1; else value=0; fi
if /usr/sbin/nft list table inet wayline_edge >/dev/null 2>&1; then edge=1; else edge=0; fi
{
  printf '# HELP node_reboot_required 1 if the node is waiting for a reboot to finish an update.\n# TYPE node_reboot_required gauge\nnode_reboot_required %s\n' "$value"
  printf '# HELP wayline_edge_table_loaded 1 if the public firewall table is loaded.\n# TYPE wayline_edge_table_loaded gauge\nwayline_edge_table_loaded %s\n' "$edge"
} >"$tmp"
chmod 644 "$tmp"
mv "$tmp" "$dir/reboot_required.prom"
