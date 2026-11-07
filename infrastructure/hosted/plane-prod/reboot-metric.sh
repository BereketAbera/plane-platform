#!/bin/sh
# /usr/local/sbin/wayline-reboot-metric, from /etc/cron.d/wayline-reboot-metric. Tells node-exporter whether a security update
# is waiting for a reboot, because unattended-upgrades does not reboot by itself here. Written atomically, so no scrape reads half.
dir=/var/lib/node_exporter/textfile
mkdir -p "$dir"
tmp="$(mktemp "$dir/.reboot.XXXXXX")"
if [ -f /var/run/reboot-required ]; then value=1; else value=0; fi
printf '# HELP node_reboot_required 1 if the node is waiting for a reboot to finish an update.\n# TYPE node_reboot_required gauge\nnode_reboot_required %s\n' "$value" >"$tmp"
chmod 644 "$tmp"
mv "$tmp" "$dir/reboot_required.prom"
