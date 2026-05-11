#!/usr/bin/env bash
# Take a running, empty Infisical to the point where operators can read secrets: first admin and org,
# Terraform config, seeded values, then the identity ids the InfisicalAuth CRs need. Idempotent.
#
# Runs from the host so the admin token never enters the cluster. Publishing comes last, after
# seeding, so an operator never logs in to an empty project.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

guard_disk
need_commands curl jq kubectl openssl terraform yq
ia_init
trap ia_cleanup EXIT

ADMIN_EMAIL="admin@wayline.localhost"
ADMIN_ORG="wayline"
TF_ROOT="$ROOT/infisical/terraform"
TF_STATE_DIR="$LOCAL_DIR/terraform/infisical"

# Fixed by helm/plane/overlays/*/infisical.yaml and infisical/manifests/token-reviewer.yaml.
IDENTITY_SECRET=plane-infisical-identity
IDENTITY_KEY=identityId
AUTH_SERVICE_ACCOUNT=plane-infisical-auth

# Terraform would bind Kubernetes Auth to the wrong account and login would fail with a 401 long
# after this script finished, so a rename in the overlay stops here instead.
check_overlay() {
  local env file actual
  for env in dev prod-sim; do
    file="$ROOT/gitops/environments/$env/manifests.yaml"
    [[ -f "$file" ]] || die "$file is missing. Run: make render"
    actual="$(yq -N 'select(.kind == "InfisicalAuth") | [.spec.kubernetes.identityIdRef.name, .spec.kubernetes.identityIdRef.key, .spec.kubernetes.serviceAccountRef.name] | join(" ")' "$file" \
      | awk 'NF && !found { found = $0 } END { print found }')"
    [[ "$actual" == "$IDENTITY_SECRET $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT" ]] \
      || die "$file references '$actual', this script publishes '$IDENTITY_SECRET $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT'. Align them."
  done
}

# A fresh instance cannot use state or credentials from a previous one. Moved, never deleted.
archive_stale_state() {
  local stamp archive f
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$SECRET_ZERO_DIR/archive-$stamp"
  if [[ -e "$ADMIN_FILE" || -e "$MACHINE_FILE" || -e "$ADMIN_PASSWORD_FILE" ]]; then
    mkdir -p "$archive"
    for f in "$ADMIN_FILE" "$MACHINE_FILE" "$ADMIN_PASSWORD_FILE"; do
      if [[ -e "$f" ]]; then mv "$f" "$archive/"; fi
    done
    warn "Infisical is uninitialized but credentials from an older instance existed: moved to $archive"
  fi
  if [[ -e "$TF_STATE_DIR/terraform.tfstate" ]]; then
    mv "$TF_STATE_DIR/terraform.tfstate" "$TF_STATE_DIR/terraform.tfstate.stale-$stamp"
    warn "Moved Terraform state of the older instance aside"
  fi
}

bootstrap_instance() {
  local password body
  password="$(openssl rand -hex 24)"
  # Written before the call: this route works once, so a lost response must still leave a way in.
  printf '%s' "$password" > "$ADMIN_PASSWORD_FILE"
  chmod 600 "$ADMIN_PASSWORD_FILE"

  body="$(printf '%s' "$password" | jq -Rs --arg email "$ADMIN_EMAIL" --arg org "$ADMIN_ORG" \
    '{email: $email, password: ., organization: $org}')"
  log "Bootstrapping the first admin and organization"
  ia_request POST /api/v1/admin/bootstrap "$body"
  # `infisical bootstrap` exits 0 on failure, which is why this calls the API and reads the response.
  [[ "$IA_STATUS" == 200 ]] || die "bootstrap returned HTTP $IA_STATUS: $(ia_error)"

  printf '%s' "$IA_BODY" | jq -e '(.identity.credentials.token | length > 0) and (.organization.id | length > 0)' >/dev/null \
    || die "bootstrap answered 200 without a token and organization. Response not printed: it may hold credentials."

  printf '%s' "$IA_BODY" | jq '{
      email: .user.email,
      token: .identity.credentials.token,
      organization: {id: .organization.id, name: .organization.name, slug: .organization.slug},
      identity: {id: .identity.id, name: .identity.name}
    }' > "$ADMIN_FILE.tmp"
  chmod 600 "$ADMIN_FILE.tmp"
  mv "$ADMIN_FILE.tmp" "$ADMIN_FILE"
  ok "bootstrapped organization $(jq -r '.organization.slug' "$ADMIN_FILE"), credentials in $ADMIN_FILE"
}

tf() { # Subshell, so the token lives only in the environment of this one terraform process.
  (
    export TF_DATA_DIR="$TF_STATE_DIR/.terraform" TF_IN_AUTOMATION=1 TF_INPUT=0
    export INFISICAL_AUTH_METHOD=token
    INFISICAL_TOKEN="$(ia_admin_token)"
    export INFISICAL_TOKEN
    export TF_VAR_infisical_host="$INFISICAL_URL"
    export TF_VAR_org_id="$ORG_ID"
    export TF_VAR_kubernetes_ca_certificate="$KUBE_CA"
    export TF_VAR_service_account_name="$AUTH_SERVICE_ACCOUNT"
    terraform -chdir="$TF_ROOT" "$@"
  )
}

publish_identity() { # env. An id is not a credential, yet the CRD accepts only a Secret reference.
  local env="$1" ns id
  ns="$(env_namespace "$env")"
  id="$(machine_value identity_ids "$env")"
  printf '%s=%s\n' "$IDENTITY_KEY" "$id" \
    | kc create secret generic "$IDENTITY_SECRET" --namespace "$ns" --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | yq '.metadata.labels."plane-platform/managed-by" = "infisical-bootstrap"' \
    | kc apply --server-side --field-manager=infisical-bootstrap --force-conflicts -f - >/dev/null
  ok "published identity id to Secret $ns/$IDENTITY_SECRET"
}

check_overlay

log "Waiting for $INFISICAL_URL (first boot runs about 600 migrations)"
wait_for "${INFISICAL_WAIT_SECONDS:-1200}" "Infisical at $INFISICAL_URL/api/status" \
  curl -fsS --max-time 5 "$INFISICAL_URL/api/status"

ia_request GET /api/v1/admin/config
[[ "$IA_STATUS" == 200 ]] || die "GET /api/v1/admin/config returned HTTP $IA_STATUS: $(ia_error)"
# tostring, because jq -e and // both treat a real false as absent.
initialized="$(printf '%s' "$IA_BODY" | jq -r '.config.initialized | tostring')"

case "$initialized" in
  false)
    archive_stale_state
    bootstrap_instance
    ;;
  true)
    [[ -s "$ADMIN_FILE" ]] \
      || die "Infisical is initialized but $ADMIN_FILE is missing, and bootstrap works only once. See infisical/README.md, section Recovery."
    ok "Infisical already bootstrapped"
    ;;
  *) die "GET /api/v1/admin/config answered without config.initialized" ;;
esac

ia_load_admin
ORG_ID="$(jq -er '.organization.id' "$ADMIN_FILE")"
# Public. Stored in Kubernetes Auth, and it changes whenever the cluster is recreated.
KUBE_CA="$(kc -n infisical get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"
[[ -n "$KUBE_CA" ]] || die "could not read the cluster CA from ConfigMap infisical/kube-root-ca.crt"

mkdir -p "$TF_STATE_DIR"
chmod 700 "$TF_STATE_DIR"
log "Applying infisical/terraform"
tf init -input=false -lockfile=readonly >/dev/null
tf apply -input=false -auto-approve

tf output -json | jq --slurpfile admin "$ADMIN_FILE" '{
    organization: $admin[0].organization,
    environment_slug: .environment_slug.value,
    project_ids: .project_ids.value,
    project_slugs: .project_slugs.value,
    identity_ids: .identity_ids.value
  }' > "$MACHINE_FILE.tmp"
chmod 600 "$MACHINE_FILE.tmp"
mv "$MACHINE_FILE.tmp" "$MACHINE_FILE"
ok "machine details in $MACHINE_FILE"

"$(dirname "$0")/infisical-seed.sh"

publish_identity dev
publish_identity prod-sim
ok "Infisical is ready. The operators pick up the identity Secrets on their next reconcile."
