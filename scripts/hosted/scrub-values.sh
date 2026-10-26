#!/usr/bin/env bash
# Remember the values of hosted production's Secrets for scripts/publish-evidence.sh, which scrubs evidence of them. That script is a
# local make target, and no local target reaches this cluster, so it reads files and this writes one.
#
#   TARGET=plane-prod scripts/hosted/scrub-values.sh
#
# Read-only on the cluster. What it read before stays, so a rotated value is still scrubbed from an older file. One value per line, as
# Kubernetes keeps them in base64, in .local/hosted/plane-prod/evidence-scrub-values at mode 0600. It prints counts and never a value.
# With the cluster out of reach it says so and exits 0, because the scrub still has that file and the owner's own files. Grafana's admin
# password is read from its file either way, and so is what scripts/hosted/frameflow-inputs.sh made for Frameflow.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq not found. Run: make setup"

FILE="$LOCAL_DIR/evidence-scrub-values"
NAMESPACES="plane-prod infisical monitoring argocd cert-manager traefik rillmark awushi-cloudgarden frameflow"

tmp="$(mktemp "$LOCAL_DIR/.scrub-values.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Grafana's admin password, which lives in a file here and works from outside. Secret monitoring/grafana-admin holds it too, but this needs
# no cluster. It, Infisical's admin password and Frameflow's owner key are the three logins a stranger could use from the internet, and
# Infisical's is a file in secret-zero, every file of which scripts/publish-evidence.sh scrubs already.
if [[ -s "$LOCAL_DIR/grafana-admin-password" ]]; then
  { base64 <"$LOCAL_DIR/grafana-admin-password" | tr -d '\n'; printf '\n'; } >>"$tmp"
fi
# Frameflow's owner key, which no Secret holds: Frameflow has only its sha256. The sha256 and Hatchet's keysets are in Secrets in
# frameflow as well, and are read from their files too, so that a scrub with no cluster knows them.
for file in owner-access-key OWNER_TOKEN_SHA256 HATCHET_MASTER_KEYSET HATCHET_JWT_PRIVATE_KEYSET HATCHET_JWT_PUBLIC_KEYSET; do
  if [[ -s "$LOCAL_DIR/frameflow/$file" ]]; then
    { base64 <"$LOCAL_DIR/frameflow/$file" | tr -d '\n'; printf '\n'; } >>"$tmp"
  fi
done

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
