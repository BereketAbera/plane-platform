#!/usr/bin/env bash
# Secret ghcr-pull in each static site's namespace, so its ServiceAccount web can pull the site's private image from GHCR. It is made
# from the owner's token, .local/hosted/plane-prod/ghcr-pull-token, which scripts/hosted/owner-inputs.sh ghcr saves and Plane's ghcr-pull
# gets through Infisical. That token reads every private package on the account, and no pod here can read this Secret: the kubelet
# uses it, and web holds no API token.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/pull-secrets.sh
#
# No Infisical operator in these namespaces: it would add a pod and cluster-scoped RBAC for each site, to deliver one token.
# scripts/hosted/bootstrap.sh runs this once Terraform has made the namespaces, ahead of its full apply. It needs nothing of the sites but
# their namespaces, and their manifests merge only after that bootstrap, so a site's first pod finds the Secret in place.
#
# To rotate the token, save the new one with scripts/hosted/owner-inputs.sh ghcr and run this again. A running pod keeps the image it
# has, and the next pull reads the new Secret. Plane's copy comes from Infisical, and the seed never overwrites a value there, so a new
# token reaches Plane only once it is written in Infisical too.
#
# No value reaches an argv or stdout. jq reads the token from its file, the config goes to a file in .local/hosted/plane-prod, which
# lib.sh holds at 0700 with umask 077, and the Secret goes on through stdin. The file goes when this ends, and only names are logged.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this writes Secret ghcr-pull in the static sites' namespaces"

command -v jq >/dev/null 2>&1 || die "jq not found. Run: make setup"

SECRET=ghcr-pull
TOKEN_FILE="$LOCAL_DIR/ghcr-pull-token"
# The account is not a secret: the token's scope, read:packages, is. The same as Plane's template in helm/plane/overlays/prod/infisical.yaml.
USERNAME=BereketAbera
# Each namespace is its app's own, so it is also what its Secret is part of.
NAMESPACES="rillmark awushi-cloudgarden"

[[ -s "$TOKEN_FILE" ]] || die "${TOKEN_FILE#"$ROOT"/} is missing. Run: scripts/hosted/owner-inputs.sh ghcr"
# A line break would become part of the password, and every pull would fail with no hint why.
[[ "$(tr -d '\r\n' <"$TOKEN_FILE" | wc -c)" == "$(wc -c <"$TOKEN_FILE")" ]] ||
  die "${TOKEN_FILE#"$ROOT"/} holds a line break, which would become part of the password. Save it again: scripts/hosted/owner-inputs.sh ghcr"

for namespace in $NAMESPACES; do
  kc get namespace "$namespace" >/dev/null 2>&1 ||
    die "namespace $namespace does not exist yet. Terraform creates it: make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod"
done

config="$(mktemp "$LOCAL_DIR/.pull-secrets.XXXXXX")"
trap 'rm -f "$config"' EXIT
# Username and password with no auth field, which the kubelet takes, as Plane's template gives them.
jq -n -c -j --rawfile token "$TOKEN_FILE" --arg username "$USERNAME" '{auths: {"ghcr.io": {username: $username, password: $token}}}' >"$config"

secret_checksum() { # namespace: a digest of the Secret as it stands, or of nothing if it is not there
  kc -n "$1" get secret "$SECRET" -o json 2>/dev/null | jq -cS '{type, data: (.data // {})}' | hosted_sha256 || true
}

for namespace in $NAMESPACES; do
  before="$(secret_checksum "$namespace")"
  kc -n "$namespace" create secret docker-registry "$SECRET" --from-file=.dockerconfigjson="$config" --dry-run=client -o yaml |
    NAMESPACE="$namespace" yq '.metadata.labels."app.kubernetes.io/part-of" = strenv(NAMESPACE) | .metadata.labels."plane-platform/managed-by" = "hosted-bootstrap"' |
    kc apply --server-side --field-manager=hosted-pull-secrets --force-conflicts -f - >/dev/null
  after="$(secret_checksum "$namespace")"
  if [[ "$before" == "$after" ]]; then
    ok "Secret $namespace/$SECRET already holds this token"
  else
    ok "Secret $namespace/$SECRET written"
  fi
done
