#!/usr/bin/env bash
# Grafana's one admin login, for its public route. Made once, kept in .local/hosted/plane-prod at mode 0600, and given to the cluster as
# Secret monitoring/grafana-admin.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/grafana-admin.sh apply   make the login if there is none, and write the Secret
#   TARGET=plane-prod scripts/hosted/grafana-admin.sh login                      print the URL and username, and copy the password to the clipboard
#
# Grafana's containers read this Secret at every start, so with it missing they stay in CreateContainerConfigError, and root's sync waits
# on them. That is why scripts/hosted/bootstrap.sh runs apply before Argo CD starts.
#
# Grafana's database is an emptyDir, so each new pod makes its admin from the Secret, whatever was changed in the UI since. A container
# restart keeps the emptyDir, and with it the old admin. So when apply changes the Secret, it replaces the pod.
#
# To change the password, delete .local/hosted/plane-prod/grafana-admin-password, and run apply. Then run scripts/hosted/bundle.sh, which
# holds a copy of both files.
#
# No value reaches an argv or stdout: the Secret comes from files, through --from-file, and the clipboard from a file, through stdin.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SECRET=grafana-admin
USER_FILE="$LOCAL_DIR/grafana-admin-user"
PASSWORD_FILE="$LOCAL_DIR/grafana-admin-password"
USERNAME=grafana-admin

write_file() { # write_file <file>: stdin to it at 0600, all at once
  local tmp
  tmp="$(mktemp "$LOCAL_DIR/.grafana-admin.XXXXXX")"
  cat >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$1"
}

secret_field() { # secret_field <key>: its value on stdout, for a pipe into a file. Nothing if the Secret or the key is not there.
  kc -n monitoring get secret "$SECRET" -o json 2>/dev/null | jq -j --arg key "$1" '.data[$key] // empty | @base64d' || true
}

# A file gone from here while the Secret still holds the value is a new machine or a lost folder, and not a reason for a new password.
make_or_restore() {
  if [[ ! -s "$USER_FILE" ]]; then
    secret_field admin-user | write_file "$USER_FILE"
    if [[ -s "$USER_FILE" ]]; then
      warn "${USER_FILE#"$ROOT"/} was missing here: restored it from Secret monitoring/$SECRET"
    else
      printf '%s' "$USERNAME" | write_file "$USER_FILE"
      ok "wrote ${USER_FILE#"$ROOT"/}"
    fi
  fi
  if [[ ! -s "$PASSWORD_FILE" ]]; then
    secret_field admin-password | write_file "$PASSWORD_FILE"
    if [[ -s "$PASSWORD_FILE" ]]; then
      warn "${PASSWORD_FILE#"$ROOT"/} was missing here: restored it from Secret monitoring/$SECRET"
    else
      openssl rand -hex 32 | tr -d '\n' | write_file "$PASSWORD_FILE"
      ok "generated ${PASSWORD_FILE#"$ROOT"/}. It is made once, and the recovery bundle holds a copy."
    fi
  fi
}

# A trailing newline would become part of the password Grafana makes its admin with, and the login would fail with no hint why.
require_one_line() { # require_one_line <file>
  [[ -s "$1" ]] || die "${1#"$ROOT"/} is empty"
  [[ "$(tr -d '\r\n' <"$1" | wc -c)" == "$(wc -c <"$1")" ]] || die "${1#"$ROOT"/} holds a line break, which would become part of the value. Write it again with no newline"
}

secret_checksum() {
  kc -n monitoring get secret "$SECRET" -o json 2>/dev/null | jq -cS '.data // {}' | hosted_sha256 || true
}

grafana_reads_this_secret() {
  kc -n monitoring get deployment kps-grafana -o json 2>/dev/null | jq -e --arg secret "$SECRET" '
    any(.spec.template.spec.containers[] | select(.name == "grafana") | .env[]?;
      .name == "GF_SECURITY_ADMIN_PASSWORD" and .valueFrom.secretKeyRef.name == $secret)' >/dev/null
}

# Both labels, because scripts/test-netpol.sh starts probe pods with the first alone.
GRAFANA_POD="app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack"

grafana_ready() { kc -n monitoring wait --for=condition=Ready pod -l "$GRAFANA_POD" --timeout=5s; }

apply() {
  for tool in jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Run: make setup"
  done
  hosted_require_confirm "this writes Secret monitoring/$SECRET"
  hosted_verify
  kc get namespace monitoring >/dev/null 2>&1 || die "namespace monitoring does not exist yet. Terraform creates it."
  make_or_restore
  require_one_line "$USER_FILE"
  require_one_line "$PASSWORD_FILE"

  local before after
  before="$(secret_checksum)"
  kc -n monitoring create secret generic "$SECRET" --from-file=admin-user="$USER_FILE" --from-file=admin-password="$PASSWORD_FILE" --dry-run=client -o yaml |
    yq '.metadata.labels."plane-platform/managed-by" = "hosted-bootstrap"' |
    kc apply --server-side --field-manager=hosted-grafana-admin --force-conflicts -f - >/dev/null
  after="$(secret_checksum)"
  if [[ "$before" == "$after" ]]; then
    ok "Secret monitoring/$SECRET already holds this login"
    return 0
  fi
  ok "Secret monitoring/$SECRET written"

  # A pod and not the Deployment, so nothing here differs from what Argo CD holds. With no Deployment, or one still on the old Secret,
  # the next start reads this one by itself.
  if grafana_reads_this_secret; then
    log "Replacing Grafana's pod, because a running one keeps the admin it started with"
    kc -n monitoring delete pod -l "$GRAFANA_POD" --timeout=120s >/dev/null
    wait_for 300 "Grafana's new pod Ready. Read: make remote-status TARGET=plane-prod" grafana_ready
    ok "Grafana is back, with this login"
  fi
}

login() {
  [[ -s "$USER_FILE" && -s "$PASSWORD_FILE" ]] ||
    die "no login here yet. Make it: make remote-grafana-admin TARGET=plane-prod CONFIRM=plane-prod VERB=apply"
  command -v pbcopy >/dev/null 2>&1 || die "pbcopy not found, because this copies to the macOS clipboard. The password is in ${PASSWORD_FILE#"$ROOT"/}"
  printf 'URL       https://%s\n' "$HOSTED_GRAFANA_DOMAIN"
  printf 'Username  %s\n' "$(cat "$USER_FILE")"
  pbcopy <"$PASSWORD_FILE"
  ok "the password is on the clipboard, and was not printed. Copy something else once you have pasted it."
}

case "${1:-}" in
  apply) apply ;;
  login) login ;;
  *) die "usage: $0 apply|login" ;;
esac
