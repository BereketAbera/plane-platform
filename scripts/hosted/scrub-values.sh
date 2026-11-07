#!/usr/bin/env bash
# Remember the values of hosted production's Secrets for scripts/publish-evidence.sh, which scrubs evidence of them. That script is a
# local make target, and no local target reaches this cluster, so it reads files and this writes one.
#
#   TARGET=plane-prod scripts/hosted/scrub-values.sh
#
# Read-only on the cluster. What it read before stays, so a rotated value is still scrubbed from an older file. One value per line, as
# Kubernetes keeps them in base64, in .local/hosted/plane-prod/evidence-scrub-values at mode 0600. It prints counts and never a value.
# With the cluster out of reach it says so and exits 0, because the scrub still has that file and the owner's own files. Grafana's admin
# password is read from its file either way.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq not found. Run: make setup"

FILE="$LOCAL_DIR/evidence-scrub-values"
NAMESPACES="plane-prod infisical monitoring argocd cert-manager traefik"

tmp="$(mktemp "$LOCAL_DIR/.scrub-values.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Grafana's admin password, which lives in a file here and works from outside. Secret monitoring/grafana-admin holds it too, but this needs
# no cluster. It and Infisical's admin password are the two logins a stranger could use from the internet, and Infisical's is a file in
# secret-zero, every file of which scripts/publish-evidence.sh scrubs already.
if [[ -s "$LOCAL_DIR/grafana-admin-password" ]]; then
  { base64 <"$LOCAL_DIR/grafana-admin-password" | tr -d '\n'; printf '\n'; } >>"$tmp"
fi

problem="$(hosted_problem)"
if [[ -n "$problem" ]]; then
  warn "not reading hosted Secrets, because $problem. The scrub has only what was read before, and the files in .local/hosted/plane-prod"
else
  # A Helm release Secret decodes to half a megabyte of compressed chart, which no command prints.
  for namespace in $NAMESPACES; do
    kc -n "$namespace" get secrets -o json | jq -r '.items[] | select(.type != "helm.sh/release.v1") | (.data // {}) | .[]' ||
      warn "could not read the Secrets in $namespace, so the scrub will not know them"
  done >>"$tmp"
fi
if [[ -f "$FILE" ]]; then cat "$FILE" >>"$tmp"; fi
LC_ALL=C sort -u "$tmp" -o "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$FILE"
ok "the scrub knows $(wc -l <"$FILE" | tr -d ' ') values from hosted production's Secrets"
