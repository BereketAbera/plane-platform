#!/usr/bin/env bash
# Frameflow's Hatchet client token. The running Hatchet mints it, this writes it to Infisical project frameflow-prod as
# HATCHET_CLIENT_TOKEN, and InfisicalStaticSecret hatchet-client-token syncs it into Secret frameflow/hatchet-client-token, which the
# api, the worker and the reconcile CronJob read. No seed can make it, because only a running Hatchet can sign one.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/frameflow-hatchet-token.sh
#
# Run it once Frameflow's first release has Hatchet up, and before the second, which adds that InfisicalStaticSecret and what reads it.
# Run it again to replace the token: it mints another, overwrites the value in Infisical, and the workloads that carry
# secrets.infisical.com/auto-reload restart on the new Secret. The old token stays valid until it is revoked in Hatchet's dashboard,
# under Settings, API Tokens, by the name this prints.
#
# The token lasts 87600h, ten years, and names Hatchet's default tenant and its SERVER_URL, http://localhost:18888. Hatchet signs it with
# the JWT keyset Infisical holds, so it outlives every restart, though /config is an emptyDir.
#
# No value reaches an argv, stdout or a log. kubectl exec writes the token into a 0600 file in a 0700 folder, jq reads it from there into
# the request body, curl sends that through stdin, and the folder goes when this ends. What is printed is names, the token's expiry, and
# whether a sha256 matched, never the sha256.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this mints a Hatchet client token and writes it to Infisical"
# shellcheck source=../../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"

need_commands curl jq nc

NAMESPACE=frameflow
# Its key in infisical-machine.json, which scripts/hosted/target.sh names.
ENVIRONMENT=frameflow
DEPLOYMENT=hatchet
# By name, because the pod has an init container too.
CONTAINER=hatchet
SECRET_NAME=HATCHET_CLIENT_TOKEN
# The InfisicalStaticSecret, and the Secret it makes, by the platform's rule of one name for both.
TARGET_SECRET=hatchet-client-token
# The tenant Hatchet's seed makes, and the only one: tenants cannot be created there.
TENANT_ID=707d0855-80ab-4e1f-a156-f1c4546cbf52
TOKEN_SHA=""

ia_init
trap 'ia_cleanup; hosted_forward_stop' EXIT
TOKEN_FILE="$IA_TMP/token"

# ---- Before anything is minted: Infisical answers, and Hatchet runs. A token minted and never written would only need revoking.
[[ -s "$MACHINE_FILE" ]] || die "$MACHINE_FILE is missing. Run: make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod"
PROJECT_ID="$(machine_value project_ids "$ENVIRONMENT")"
ENV_SLUG="$(jq -er '.environment_slug' "$MACHINE_FILE")"

port="$(hosted_free_port 18100)"
hosted_forward_start infisical svc/infisical "$port" 8080 || die "could not port-forward to Infisical"
INFISICAL_URL="http://127.0.0.1:$port"
wait_for 60 "Infisical at $INFISICAL_URL/api/status" curl -fsS --max-time 5 "$INFISICAL_URL/api/status"
ia_load_admin

# Names only: the values stay on the server.
ia_request GET "/api/v4/secrets?projectId=$PROJECT_ID&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=false&expandSecretReferences=false&includeImports=false&recursive=false"
[[ "$IA_STATUS" == 200 ]] || die "listing the secrets of project frameflow-prod returned HTTP $IA_STATUS: $(ia_error)"
if printf '%s' "$IA_BODY" | jq -e --arg name "$SECRET_NAME" 'any(.secrets[]; .secretKey == $name)' >/dev/null; then
  METHOD=PATCH
else
  METHOD=POST
fi

hatchet_ready() {
  kc -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json 2>/dev/null |
    jq -e '(.status.readyReplicas // 0) >= 1 and (.status.readyReplicas // 0) == (.spec.replicas // 1)' >/dev/null
}
hatchet_ready || die "Deployment $NAMESPACE/$DEPLOYMENT is not Ready, so no Hatchet is there to sign a token. Read: make remote-status TARGET=plane-prod"

# ---- Mint it, into a file.
NAME="frameflow-$(hosted_stamp)"
log "Minting $NAME in $NAMESPACE/$DEPLOYMENT"
if ! kc -n "$NAMESPACE" exec "deployment/$DEPLOYMENT" -c "$CONTAINER" -- /hatchet-admin token create --config /config \
  --tenant-id "$TENANT_ID" --name "$NAME" --expiresIn 87600h >"$IA_TMP/token.out" 2>"$IA_TMP/token.err"; then
  tail -n 5 "$IA_TMP/token.err" | cut -c1-300 >&2
  die "hatchet-admin token create failed, as it says above, so nothing was written to Infisical"
fi
# It prints the token and a newline. The newline goes, or it would be part of the value.
lines="$(grep -c '' "$IA_TMP/token.out" || true)"
[[ "$lines" == 1 ]] || die "hatchet-admin printed $lines lines and a token is one, so what it printed is not sent anywhere. Revoke $NAME in Hatchet's dashboard if it was made"
tr -d '\r\n' <"$IA_TMP/token.out" >"$TOKEN_FILE"
rm -f "$IA_TMP/token.out"
grep -Eqx '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$TOKEN_FILE" ||
  die "what hatchet-admin printed is not a JWT in three base64url parts, so it is not sent anywhere. Revoke $NAME in Hatchet's dashboard if it was made"
CLAIMS="$(ia_token_claims <"$TOKEN_FILE")"
[[ "$(jq -r '.sub // ""' <<<"$CLAIMS")" == "$TENANT_ID" ]] ||
  die "the token is not for tenant $TENANT_ID, so it is not sent anywhere. Revoke $NAME in Hatchet's dashboard"
EXPIRES="$(jq -r '.exp // 0' <<<"$CLAIMS")"
TOKEN_SHA="$(hosted_sha256 <"$TOKEN_FILE")"

# ---- Write it, through stdin, as scripts/rotate.sh writes one value: POST makes the key, PATCH replaces its value.
body="$(jq -Rs --arg project "$PROJECT_ID" --arg env_slug "$ENV_SLUG" \
  '{projectId: $project, environment: $env_slug, secretPath: "/", secretValue: .}' <"$TOKEN_FILE")"
ia_request "$METHOD" "/api/v4/secrets/$SECRET_NAME" "$body"
body=""
[[ "$IA_STATUS" == 200 ]] ||
  die "writing $SECRET_NAME to Infisical with $METHOD returned HTTP $IA_STATUS: $(ia_error). $NAME is unused, so revoke it in Hatchet's dashboard, and run this again"
ia_request GET "/api/v4/secrets/$SECRET_NAME?projectId=$PROJECT_ID&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=true&expandSecretReferences=false&includeImports=false"
[[ "$IA_STATUS" == 200 ]] || die "reading $SECRET_NAME back from Infisical returned HTTP $IA_STATUS: $(ia_error)"
[[ "$(printf '%s' "$IA_BODY" | jq -j '.secret.secretValue // ""' | hosted_sha256)" == "$TOKEN_SHA" ]] ||
  die "Infisical does not hold the token just written. Run this again, and revoke $NAME in Hatchet's dashboard"
IA_BODY=""
rm -f "$TOKEN_FILE"
ok "$SECRET_NAME is in Infisical project frameflow-prod, environment $ENV_SLUG ($([[ "$METHOD" == POST ]] && echo made || echo replaced)): $NAME, valid until $(ia_date "$EXPIRES")"

# ---- And in the cluster, once release B's InfisicalStaticSecret is there to sync it.
secret_holds_token() {
  [[ "$(kc -n "$NAMESPACE" get secret "$TARGET_SECRET" -o json 2>/dev/null | jq -j --arg key "$SECRET_NAME" '.data[$key] // "" | @base64d' | hosted_sha256)" == "$TOKEN_SHA" ]]
}
if kc -n "$NAMESPACE" get infisicalstaticsecrets.secrets.infisical.com "$TARGET_SECRET" >/dev/null 2>&1; then
  log "Waiting for the operator to sync Secret $NAMESPACE/$TARGET_SECRET, which it reads every 60s"
  wait_for "${SYNC_TIMEOUT_SECONDS:-180}" "Secret $NAMESPACE/$TARGET_SECRET to hold the token just written" secret_holds_token
  ok "Secret $NAMESPACE/$TARGET_SECRET holds it, and what reads it with auto-reload restarts on it"
else
  ok "InfisicalStaticSecret $NAMESPACE/$TARGET_SECRET does not exist yet. It comes with Frameflow's second release, and syncs the Secret within 60s of its first sync"
fi
log "Until the next Infisical backup, the newest dump holds the token this replaced, or none: make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=infisical"
