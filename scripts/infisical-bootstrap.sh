#!/usr/bin/env bash
# Take a running, empty Infisical to the point where operators can read secrets: first admin and org,
# Terraform config, seeded values, then the identity ids the InfisicalAuth CRs need. Idempotent.
#
# Runs from the host so the admin token never enters the cluster. Publishing comes last, after
# seeding, so an operator never logs in to an empty project.
#
# INFISICAL_RESTORED=yes is restored mode, for an instance whose database just came back from a backup
# (`make restore-clean` runs it). It keeps every credential, refreshes the cluster CA through Terraform,
# republishes the identity Secrets and writes no secret value. It refuses instead of repairing: a
# fresh instance, a token the server rejects, Terraform wanting to create or delete anything, or a
# missing secret all mean this database and these local files are not a pair. Idempotent.
#
# A token that has expired, or a file that is gone, is another matter: it says nothing about the pair. On an
# initialized instance this signs in with the first admin's password and mints another, or takes one a person
# made (.local/secret-zero/infisical-admin-token.new), and records it. RENEW_ADMIN_TOKEN=yes does so
# ahead of time, before a token ends. See infisical/README.md, section Recovery.
#
# PLAN_ONLY=yes prints what Terraform would do to an instance already bootstrapped, and says for each
# environment what it would make and what it would change of what exists, so a new environment's can be
# seen to leave prod's alone. It applies, seeds, publishes and mints nothing, and replaces no file here. On
# hosted production, with Infisical forwarded as `make remote-ui TARGET=plane-prod UI=infisical` does:
#   WAYLINE_TARGET=plane-prod CONFIRM=plane-prod PLAN_ONLY=yes INFISICAL_URL=http://127.0.0.1:<port> scripts/infisical-bootstrap.sh
# Run it on its own like that: scripts/hosted/bootstrap.sh applies Terraform of its own before it calls this.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# Hosted production opts in here. Without the variable this does nothing. See scripts/hosted/target.sh.
# shellcheck source=hosted/target.sh
if [[ -n "${WAYLINE_TARGET:-}" ]]; then source "$ROOT/scripts/hosted/target.sh"; fi
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

guard_disk
need_commands curl jq kubectl openssl terraform yq
ia_init
trap ia_cleanup EXIT

ADMIN_EMAIL="$INFISICAL_ADMIN_EMAIL"
ADMIN_ORG="wayline"
TF_ROOT="$ROOT/infisical/terraform"
TF_STATE_DIR="$LOCAL_DIR/terraform/infisical"
RESTORED="${INFISICAL_RESTORED:-}"
PLAN_ONLY="${PLAN_ONLY:-}"
[[ "$RESTORED" != yes || "$PLAN_ONLY" != yes ]] || die "choose INFISICAL_RESTORED=yes or PLAN_ONLY=yes, not both: restored mode checks its own saved plan before it applies"

# Fixed by helm/plane/overlays/*/infisical.yaml and infisical/manifests/token-reviewer.yaml, and for an app
# beside Wayline by its own folder, gitops/clusters/plane-prod/platform/<namespace>/, and
# gitops/clusters/plane-prod/platform/infisical/token-reviewer.yaml.
IDENTITY_SECRET=plane-infisical-identity
IDENTITY_KEY=identityId
AUTH_SERVICE_ACCOUNT=plane-infisical-auth

# PLAN_ONLY=yes binds nothing, so there a mismatch is only reported, and the plan still shows what would be bound.
overlay_problem() {
  if [[ "$PLAN_ONLY" == yes ]]; then warn "$1"; else die "$1"; fi
}

# What an app's folder syncs, as its Application reads it: the kustomization's build, or each file.
app_manifests() { # directory
  local file
  if [[ -f "$1/kustomization.yaml" ]]; then
    need_commands kustomize
    kustomize build "$1"
  else
    while read -r file; do
      printf -- '---\n'
      cat "$file"
    done < <(find "$1" -maxdepth 1 -type f -name '*.yaml' | LC_ALL=C sort)
  fi
}

# Terraform would bind Kubernetes Auth to the wrong account and login would fail with a 401 long
# after this script finished, so a rename in the overlay stops here instead.
check_overlay() {
  local env file actual ns
  for env in ${WAYLINE_ENVIRONMENTS:-dev prod-sim}; do
    case "$env" in
      dev | prod-sim | prod)
        file="$ROOT/gitops/environments/$env/manifests.yaml"
        [[ -f "$file" ]] || die "$file is missing. Run: make render"
        actual="$(yq -N 'select(.kind == "InfisicalAuth") | [.spec.kubernetes.identityIdRef.name, .spec.kubernetes.identityIdRef.key, .spec.kubernetes.serviceAccountRef.name] | join(" ")' "$file" \
          | awk 'NF && !found { found = $0 } END { print found }')"
        [[ "$actual" == "$IDENTITY_SECRET $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT" ]] \
          || overlay_problem "$file references '$actual', this script publishes '$IDENTITY_SECRET $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT'. Align them."
        ;;
      *)
        # An app's own folder, with no render: each object there names its namespace, so the references must name
        # this one, the namespace Terraform binds the identity to and this publishes its id in.
        ns="$(env_namespace "$env")"
        file="$ROOT/gitops/clusters/plane-prod/platform/$ns"
        # An app's secrets come before its manifests: this runs from the merge that holds the scripts, and the folder
        # lands in the next one. Until then nothing in $ns logs in, and there is nothing here to compare with.
        if [[ ! -d "$file" ]]; then
          warn "$file is not in this checkout yet, so nothing here says what InfisicalAuth in $ns references. This binds and publishes Secret $IDENTITY_SECRET, key $IDENTITY_KEY, and ServiceAccount $AUTH_SERVICE_ACCOUNT, both in $ns, and the folder must reference those"
          continue
        fi
        actual="$(app_manifests "$file" | yq -N 'select(.kind == "InfisicalAuth") | [.spec.kubernetes.identityIdRef.name, .spec.kubernetes.identityIdRef.namespace, .spec.kubernetes.identityIdRef.key, .spec.kubernetes.serviceAccountRef.name, .spec.kubernetes.serviceAccountRef.namespace] | join(" ")' \
          | awk 'NF && !found { found = $0 } END { print found }')"
        [[ "$actual" == "$IDENTITY_SECRET $ns $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT $ns" ]] \
          || overlay_problem "$file references '$actual', this script publishes '$IDENTITY_SECRET $ns $IDENTITY_KEY $AUTH_SERVICE_ACCOUNT $ns'. Align them."
        ;;
    esac
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

# A restore may only update what is stored about the old cluster, which is the CA in Kubernetes Auth.
# Saved plan, so what is applied is exactly what was checked.
apply_restored() {
  local rc=0 plan unexpected
  [[ -s "$TF_STATE_DIR/terraform.tfstate" ]] \
    || die "no Terraform state at $TF_STATE_DIR, and creating what the restored database already holds would fail. Restore it with: scripts/restore.sh infisical <backup-id> CONFIRM=yes"
  tf plan -lock-timeout=10m -input=false -detailed-exitcode -out="$IA_TMP/restored.tfplan" || rc=$?
  case "$rc" in
    0)
      ok "Terraform has nothing to change: the CA is already this cluster's"
      return 0
      ;;
    2) ;;
    *) die "terraform plan failed against the restored instance" ;;
  esac
  plan="$(tf show -json "$IA_TMP/restored.tfplan")"
  unexpected="$(jq -r '[.resource_changes[]?
      | select(.change.actions != ["no-op"] and .change.actions != ["read"] and .change.actions != ["update"])
      | "\(.address) (\(.change.actions | join("+")))"] | join(", ")' <<<"$plan")"
  [[ -z "$unexpected" ]] \
    || die "Terraform wants to change more than an update in place: $unexpected. The state and the restored database are not a pair, so nothing was applied. Restore them together with: scripts/restore.sh infisical <backup-id> CONFIRM=yes"
  tf apply -lock-timeout=10m -input=false "$IA_TMP/restored.tfplan"
}

# The plan, printed, and for each environment what it would make and what it would change of what exists, which
# for one that exists already should be nothing. Saved, so what is summed up is what was printed.
plan_only() {
  local rc=0 plan env made changes
  tf plan -lock-timeout=10m -input=false -detailed-exitcode -out="$IA_TMP/preview.tfplan" || rc=$?
  case "$rc" in
    0)
      ok "PLAN_ONLY=yes: Terraform has nothing to change"
      return 0
      ;;
    2) ;;
    *) die "terraform plan failed" ;;
  esac
  plan="$(tf show -json "$IA_TMP/preview.tfplan")"
  for env in ${WAYLINE_ENVIRONMENTS:-dev prod-sim}; do
    made="$(jq -r --arg env "$env" '[.resource_changes[]? | select(.index == $env and .change.actions == ["create"])] | length' <<<"$plan")"
    changes="$(jq -r --arg env "$env" '[.resource_changes[]?
        | select(.index == $env and .change.actions != ["no-op"] and .change.actions != ["read"] and .change.actions != ["create"])
        | "\(.address) (\(.change.actions | join("+")))"] | join(", ")' <<<"$plan")"
    if [[ -n "$changes" ]]; then
      warn "PLAN_ONLY=yes: $env: would change what exists: $changes"
    elif [[ "$made" -gt 0 ]]; then
      ok "PLAN_ONLY=yes: $env: would make $made resources, and change nothing that exists"
    else
      ok "PLAN_ONLY=yes: $env: no change"
    fi
  done
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
    [[ "$PLAN_ONLY" != yes ]] \
      || die "Infisical is uninitialized, so there is nothing to plan against: the first run bootstraps it, and PLAN_ONLY=yes writes nothing"
    [[ "$RESTORED" != yes ]] \
      || die "Infisical is uninitialized, so the restore did not take. Refusing to bootstrap: that would generate new credentials and new secrets."
    if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then
      die "a clean restore is under way ($RESTORE_CLEAN_MARKER), and bootstrapping this fresh instance would create new secrets that do not match the backup. Finish it with: make restore-clean BACKUP=latest. To give up on it and start an empty platform, remove that file and run this again."
    fi
    archive_stale_state
    bootstrap_instance
    ;;
  true)
    # PLAN_ONLY=yes mints no token: ia_load_admin below says if the one here cannot be used.
    if [[ "$PLAN_ONLY" != yes ]]; then
      ensure_rc=0
      ia_ensure_admin "$(jq -r '.organization.id // empty' "$MACHINE_FILE" 2>/dev/null || true)" || ensure_rc=$?
      if [[ "$ensure_rc" -ne 0 ]]; then
        ia_print_sign_in_steps "scripts/infisical-bootstrap.sh"
        die "Infisical is initialized, bootstrap works only once, and nothing here could replace the admin token. $(ia_admin_problem)."
      fi
    fi
    ok "Infisical already bootstrapped"
    ;;
  *) die "GET /api/v1/admin/config answered without config.initialized" ;;
esac

ia_load_admin
ORG_ID="$(jq -er '.organization.id' "$ADMIN_FILE")"
if [[ "$RESTORED" == yes ]]; then
  ia_request GET "/api/v2/organizations/$ORG_ID/identity-memberships?limit=1"
  [[ "$IA_STATUS" == 200 ]] \
    || die "the restored instance answers HTTP $IA_STATUS to the admin token in $ADMIN_FILE: $(ia_error). The token, AUTH_SECRET and the database must come from the same set. See infisical/README.md, section Recovery."
  ok "the restored instance accepts the admin token"
fi
# Public. Stored in Kubernetes Auth, and it changes whenever the cluster is recreated.
KUBE_CA="$(kc -n infisical get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"
[[ -n "$KUBE_CA" ]] || die "could not read the cluster CA from ConfigMap infisical/kube-root-ca.crt"

mkdir -p "$TF_STATE_DIR"
chmod 700 "$TF_STATE_DIR"
if [[ "$PLAN_ONLY" == yes ]]; then log "Planning infisical/terraform, and applying nothing"; else log "Applying infisical/terraform"; fi
tf init -input=false -lockfile=readonly ${HOSTED_INFISICAL_TF_BACKEND:+-backend-config="$HOSTED_INFISICAL_TF_BACKEND"} >/dev/null
if [[ "$RESTORED" == yes ]]; then
  apply_restored
elif [[ "$PLAN_ONLY" == yes ]]; then
  plan_only
  ok "PLAN_ONLY=yes: nothing was applied, seeded or published"
  exit 0
else
  tf apply -lock-timeout=10m -input=false -auto-approve
fi

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

if [[ "$RESTORED" == yes ]]; then
  SEED_VERIFY_ONLY=yes "$(dirname "$0")/infisical-seed.sh"
else
  "$(dirname "$0")/infisical-seed.sh"
fi

for env_name in ${WAYLINE_ENVIRONMENTS:-dev prod-sim}; do
  publish_identity "$env_name"
done
ok "Infisical is ready. InfisicalAuth turns Ready within seconds, and a Plane sync already in backoff moves on at its next retry, up to 5 minutes later."
