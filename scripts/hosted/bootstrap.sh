#!/usr/bin/env bash
# Take a provisioned node to the point where production only needs its first promotion. Each step can run again, and says what it
# does. Run it after scripts/hosted/provision-node.sh, scripts/hosted/kubeconfig.sh and scripts/hosted/owner-inputs.sh.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/bootstrap.sh
#
# In this order, because each needs the one before:
#   1. A read-only deploy key on GitHub, generated here and held here.
#   2. Namespaces, then Secret argocd-repo-plane-platform in argocd, so Argo CD's first look at the repository works. It cannot
#      come from Infisical, because Argo CD deploys Infisical.
#   3. The rest of Terraform: Argo CD, its projects, and the root Application. Argo CD starts deploying the platform here.
#   4. The backup folders on the node, the read-only pull user, and a restic password generated once.
#   5. Secret zero, which scripts/secret-zero.sh generates only with FIRST_BOOT=yes.
#   6. Infisical: first admin, project plane-prod, identity bound to namespace plane-prod, seeded values with ghcr-pull's token.
#   7. Alert delivery.
#   8. The recovery bundle, if the owner has made the identity.
#
# Secret zero, the restic password, the deploy key and alert credentials live in .local/hosted/plane-prod and never in Infisical,
# so nothing here is circular. No value reaches an argv: Secrets come from files, through --from-file.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this bootstraps the platform"

"$ROOT/scripts/install-tools.sh" terraform >/dev/null
for tool in gh openssl jq curl ssh-keygen terraform; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Run: make setup"
done
guard_disk

TF_ROOT="$ROOT/infrastructure/terraform/environments/prod"
DEPLOY_KEY="$LOCAL_DIR/argocd-deploy-key"
RESTIC_PASSWORD_LOCAL="$LOCAL_DIR/restic-password"
DEPLOY_KEY_TITLE="plane-prod-argocd"

trap hosted_forward_stop EXIT

step() { log "Step $*"; }

tf() {
  TF_IN_AUTOMATION=1 TF_INPUT=0 terraform -chdir="$TF_ROOT" "$@"
}

# The namespace's Secret from a file, or its key names from the caller's arguments. Client-side first, so the file's path is
# all an argv ever holds.
apply_secret_files() { # namespace name --from-file=... | --from-literal=non-secret...
  local namespace="$1" name="$2"
  shift 2
  kc -n "$namespace" create secret generic "$name" "$@" --dry-run=client -o yaml |
    yq '.metadata.labels."plane-platform/managed-by" = "hosted-bootstrap"' |
    kc apply --server-side --field-manager=hosted-bootstrap --force-conflicts -f - >/dev/null
}

# ------ 1. Deploy key --------------------------------------------------------------------------------------------------

deploy_key() {
  step "1 of 8: a read-only deploy key for Argo CD"
  gh api "repos/$HOSTED_GITHUB_REPO" --jq .full_name >/dev/null 2>&1 ||
    die "gh cannot read $HOSTED_GITHUB_REPO. Check gh auth status, and which account is active"
  if [[ ! -s "$DEPLOY_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$DEPLOY_KEY_TITLE" -f "$DEPLOY_KEY"
    ok "made the key ${DEPLOY_KEY#"$ROOT"/}"
  fi
  local public listed state
  public="$(cut -d' ' -f1,2 "$DEPLOY_KEY.pub")"
  key_state() {
    gh api "repos/$HOSTED_GITHUB_REPO/keys" --paginate | jq -rs --arg key "$public" \
      '[(add // [])[] | select(.key == $key)][0] | if . == null then "absent" else (.read_only | tostring) end'
  }
  state="$(key_state)" || die "gh cannot list this repository's deploy keys"
  if [[ "$state" == absent ]]; then
    # No --allow-write. A deploy key added with gh's token is removed if that token's app is de-authorized. The web UI avoids
    # that, and a removed key shows at once as Argo CD failing to fetch.
    gh repo deploy-key add "$DEPLOY_KEY.pub" --title "$DEPLOY_KEY_TITLE" --repo "$HOSTED_GITHUB_REPO" >/dev/null
    state="$(key_state)" || die "gh cannot list this repository's deploy keys"
  fi
  [[ "$state" == true ]] || die "the deploy key on GitHub is not read-only (read_only: $state). Remove it there, and run this again."
  listed="$(gh api "repos/$HOSTED_GITHUB_REPO/keys" --paginate | jq -rs '(add // []) | length')"
  ok "deploy key is on GitHub, read-only. The repository has $listed deploy key(s)."
}

# ------ 2. Namespaces and the repository Secret ------------------------------------------------------------------------

repo_secret() {
  step "2 of 8: namespaces, and Secret argocd-repo-plane-platform"
  tf init -input=false -lockfile=readonly >/dev/null
  # Terraform creates the namespace, and owns it, so nothing may make it first. A targeted apply gets the Secret in ahead of
  # Argo CD, so its first read of the repository works, and the full apply follows at once.
  tf apply -input=false -auto-approve -lock-timeout=10m -target=module.foundation
  apply_secret_files argocd argocd-repo-plane-platform \
    --from-literal=type=git --from-literal=url="$HOSTED_REPO_URL" --from-file=sshPrivateKey="$DEPLOY_KEY"
  kc -n argocd label secret argocd-repo-plane-platform argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  ok "Secret argocd/argocd-repo-plane-platform in place, for $HOSTED_REPO_URL"
}

# ------ 3. The rest of Terraform ---------------------------------------------------------------------------------------

terraform_all() {
  step "3 of 8: Terraform: Argo CD, projects and the root Application"
  tf apply -input=false -auto-approve -lock-timeout=10m
  ok "Argo CD is reading branch deploy/plane-prod"
}

# ------ 4. Backup folders, pull user, restic password ------------------------------------------------------------------

backup_prerequisites() {
  step "4 of 8: backup folders, the read-only pull user, and the restic password"
  # Owned by UID 70, which the Jobs run as, because hostPath ignores fsGroup. Group 70 is how the read-only pull user reads
  # restic's files. predeploy is made by its Job at 0700 and stays out of that group's reach.
  node_root <<EOF
set -euo pipefail
owner="\$(getent group 70 | cut -d: -f1 || true)"
case "\$owner" in
  "") groupadd --gid 70 wayline-backup ;;
  wayline-backup) ;;
  *) echo "group 70 already belongs to \$owner" >&2; exit 1 ;;
esac
install -d -m 755 $HOSTED_BACKUP_ROOT
install -d -m 750 -o 70 -g 70 $HOSTED_BACKUP_ROOT/plane-prod $HOSTED_BACKUP_ROOT/infisical
EOF
  ok "folders under $HOSTED_BACKUP_ROOT are ready"
  "$ROOT/scripts/hosted/pull-backups.sh" setup

  if [[ ! -s "$RESTIC_PASSWORD_LOCAL" ]]; then
    local live=""
    live="$(kc -n plane-prod get secret restic-password -o json 2>/dev/null | jq -r '.data.password // empty | @base64d' || true)"
    if [[ -n "$live" ]]; then
      printf '%s' "$live" >"$RESTIC_PASSWORD_LOCAL"
      warn "${RESTIC_PASSWORD_LOCAL#"$ROOT"/} was missing here: restored it from Secret plane-prod/restic-password"
    elif node_ssh_quiet "sudo -n test -e $HOSTED_BACKUP_ROOT/plane-prod/restic/config -o -e $HOSTED_BACKUP_ROOT/infisical/restic/config"; then
      die "a restic repository exists on the node and this machine has no password for it. A new one could never read it. Get restic-password from the recovery bundle."
    else
      openssl rand -hex 32 | tr -d '\n' >"$RESTIC_PASSWORD_LOCAL"
      ok "generated ${RESTIC_PASSWORD_LOCAL#"$ROOT"/}. It is made once, and the recovery bundle holds a copy."
    fi
    live=""
    chmod 600 "$RESTIC_PASSWORD_LOCAL"
  fi
  local namespace
  for namespace in plane-prod infisical; do
    apply_secret_files "$namespace" restic-password --from-file=password="$RESTIC_PASSWORD_LOCAL"
  done
  ok "Secret restic-password in plane-prod and infisical"
}

# ------ 5. Secret zero -------------------------------------------------------------------------------------------------

secret_zero() {
  step "5 of 8: secret zero"
  # Files or a Secret are reused, and only with neither does this generate. A database running with neither is the one case a
  # new key would destroy, so that stops here, for a person.
  if [[ ! -s "$LOCAL_DIR/secret-zero/ENCRYPTION_KEY" ]] && ! kc -n infisical get secret infisical-secrets >/dev/null 2>&1; then
    local ready
    ready="$(kc -n infisical get statefulset infisical-postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ -n "$ready" && "$ready" != 0 ]]; then
      die "Infisical's database is running and neither this machine nor the cluster has ENCRYPTION_KEY. A new key could not read that database. Bring secret-zero back from the recovery bundle."
    fi
  fi
  WAYLINE_TARGET=plane-prod FIRST_BOOT=yes "$ROOT/scripts/secret-zero.sh"
}

# ------ 6. Infisical ---------------------------------------------------------------------------------------------------

infisical_available() { kc -n infisical wait --for=condition=Available deployment/infisical --timeout=5s; }

infisical() {
  step "6 of 8: Infisical: first admin, project, identity and seeded values, through a port-forward"
  [[ -s "$LOCAL_DIR/ghcr-pull-token" ]] || die ".local/hosted/plane-prod/ghcr-pull-token is missing. Run: scripts/hosted/owner-inputs.sh ghcr"
  # The earlier waves come first, so this can be the longest wait of a first boot. A wave that fails holds it back.
  log "Waiting for Infisical. Progress: make remote-status TARGET=plane-prod"
  wait_for "${BOOTSTRAP_WAIT_INFISICAL_SECONDS:-2400}" "Deployment infisical/infisical Available. Read: make remote-status TARGET=plane-prod" infisical_available
  local port
  port="$(hosted_free_port 18100)"
  hosted_forward_start infisical svc/infisical "$port" 8080 || die "could not port-forward to Infisical"
  WAYLINE_TARGET=plane-prod INFISICAL_URL="http://127.0.0.1:$port" "$ROOT/scripts/infisical-bootstrap.sh"
  hosted_forward_stop
}

# ------ 7, 8 -----------------------------------------------------------------------------------------------------------

alerts() {
  step "7 of 8: alert delivery"
  "$ROOT/scripts/hosted/alerts.sh"
}

bundle() {
  step "8 of 8: the recovery bundle"
  if [[ ! -s "$ROOT/scripts/hosted/recovery-recipient.txt" ]]; then
    warn "recovery bundle INCOMPLETE: no recipient yet. Run scripts/hosted/bundle.sh init, then scripts/hosted/bundle.sh. Until then, this machine holds the only copy of secret zero."
    return 0
  fi
  local rc=0
  "$ROOT/scripts/hosted/bundle.sh" || rc=$?
  [[ "$rc" -ne 1 ]] || die "the recovery bundle failed"
}

deploy_key
repo_secret
terraform_all
backup_prerequisites
secret_zero
infisical
alerts
bundle
ok "bootstrap finished. Read: make remote-status TARGET=plane-prod. Next: the first promotion, then make remote-test TARGET=plane-prod CONFIRM=plane-prod"
