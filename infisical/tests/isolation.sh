#!/usr/bin/env bash
# Prove the isolation the free tier allows, with real API calls and the same ServiceAccount tokens
# the operators use: one project per environment, a viewer identity per project, nothing across.
#
#   infisical/tests/isolation.sh            host path through Traefik, then in-cluster from a probe pod
#   ISOLATION_IN_CLUSTER=no infisical/tests/isolation.sh    host path only
#
# Exit status as in scripts/test.sh: 0 everything passed, 1 something failed, 2 nothing failed but
# something could not run. Prints statuses and the server's error messages, never a token or a value.
# Every 403 is checked against a positive control with the same token, so a wrong project id or a dead
# token cannot pass as isolation.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=../lib/api.sh
source "$ROOT/infisical/lib/api.sh"

need_commands curl jq kubectl
ia_init
PROBE_PODS=""
cleanup() {
  local pod
  for pod in $PROBE_PODS; do
    kc -n "${pod%%/*}" delete pod "${pod#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  ia_cleanup
}
trap cleanup EXIT

SERVICE_ACCOUNT=plane-infisical-auth
# curlimages/curl 8.17.0, the image scripts/test-netpol.sh already pins.
CURL_IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"

FAILED=0
BLOCKED=0
# The service reports wrong identity and wrong namespace as 401, and both are a refusal.
DENIED_LOGIN='401|403'

row() { # verdict case expected got [detail]
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
  esac
  printf '%-8s %-62s expected=%-8s got=%-4s %s\n' "$1" "$2" "$3" "$4" "${5:-}"
}

check() { # case expected(regex) [detail]. Reads IA_STATUS.
  local detail="${3:-}"
  if [[ "$IA_STATUS" =~ ^($2)$ ]]; then
    row PASS "$1" "$2" "$IA_STATUS" "$detail"
  elif [[ "$IA_STATUS" == 000 ]]; then
    row BLOCKED "$1" "$2" "$IA_STATUS" "no answer"
  else
    row FAIL "$1" "$2" "$IA_STATUS" "$detail"
  fi
}

check_denied() { # case expected(regex). A refusal's message is safe to print; a 200's body is not.
  local message=""
  if [[ ! "$IA_STATUS" =~ ^2 ]]; then message="$(ia_error)"; fi
  check "$1" "$2" "$message"
}

use_token() { # env, or "" for an anonymous request
  if [[ -n "$1" ]]; then
    printf 'Authorization: Bearer %s\n' "$(cat "$IA_TMP/access-$1")" > "$IA_TMP/auth"
  else
    : > "$IA_TMP/auth"
  fi
}

mint() { # namespace serviceaccount: prints a 10-minute token, the lifetime the operator asks for
  kc -n "$1" create token "$2" --duration=10m 2>/dev/null
}

login() { # identity id, token file. Sets IA_STATUS and IA_BODY.
  local body
  body="$(jq -Rs --arg id "$1" '{identityId: $id, jwt: .}' < "$2")"
  use_token ""
  ia_request POST /api/v1/auth/kubernetes-auth/login "$body"
}

secrets_path() { # project id [extra query]
  printf '/api/v4/secrets?projectId=%s&environment=%s&secretPath=%%2F&recursive=false%s' "$1" "$ENV_SLUG" "${2:-}"
}

[[ -s "$MACHINE_FILE" ]] || { row BLOCKED "machine details" present missing "$MACHINE_FILE"; exit 2; }
ENV_SLUG="$(jq -er '.environment_slug' "$MACHINE_FILE")"
ORG_ID="$(jq -er '.organization.id' "$MACHINE_FILE")"
DEV_ID="$(machine_value identity_ids dev)"
SIM_ID="$(machine_value identity_ids prod-sim)"
DEV_PROJECT="$(machine_value project_ids dev)"
SIM_PROJECT="$(machine_value project_ids prod-sim)"
DEV_SLUG="$(machine_value project_slugs dev)"
SIM_SLUG="$(machine_value project_slugs prod-sim)"

log "Logins, through $INFISICAL_URL"
if mint plane-dev "$SERVICE_ACCOUNT" > "$IA_TMP/sa-dev"; then :; else
  row BLOCKED "mint token for plane-dev/$SERVICE_ACCOUNT" token none "ServiceAccount missing?"
  exit 2
fi
if mint plane-prod-sim "$SERVICE_ACCOUNT" > "$IA_TMP/sa-sim"; then :; else
  row BLOCKED "mint token for plane-prod-sim/$SERVICE_ACCOUNT" token none "ServiceAccount missing?"
  exit 2
fi

login "$DEV_ID" "$IA_TMP/sa-dev"
check_denied "plane-dev SA logs in as the dev reader" 200
[[ "$IA_STATUS" == 200 ]] || { row BLOCKED "cannot continue without a dev access token" 200 "$IA_STATUS"; exit 2; }
printf '%s' "$IA_BODY" | jq -er '.accessToken' > "$IA_TMP/access-dev"

login "$SIM_ID" "$IA_TMP/sa-sim"
check_denied "plane-prod-sim SA logs in as the prod-sim reader" 200
[[ "$IA_STATUS" == 200 ]] || { row BLOCKED "cannot continue without a prod-sim access token" 200 "$IA_STATUS"; exit 2; }
printf '%s' "$IA_BODY" | jq -er '.accessToken' > "$IA_TMP/access-sim"

login "$SIM_ID" "$IA_TMP/sa-dev"
check_denied "plane-dev SA refused as the prod-sim reader" "$DENIED_LOGIN"
login "$DEV_ID" "$IA_TMP/sa-sim"
check_denied "plane-prod-sim SA refused as the dev reader" "$DENIED_LOGIN"

# Same namespace, wrong account. default fails earlier, at its own token review. The operator's account
# may run reviews, so only allowed_service_account_names can refuse it, which is the check wanted here.
for account in default iso-dev-controller-manager; do
  if mint plane-dev "$account" > "$IA_TMP/sa-other"; then
    login "$DEV_ID" "$IA_TMP/sa-other"
    check_denied "plane-dev/$account SA refused as the dev reader" "$DENIED_LOGIN"
  else
    row BLOCKED "mint token for plane-dev/$account" token none
  fi
done
printf 'not.a.jwt' > "$IA_TMP/garbage"
login "$DEV_ID" "$IA_TMP/garbage"
check_denied "a forged token is refused" "$DENIED_LOGIN"

log "Reads: each reader against its own project, then the other one"
use_token dev
ia_request GET "$(secrets_path "$DEV_PROJECT")"
check "dev reader lists $DEV_SLUG" 200 "$(printf '%s' "$IA_BODY" | jq -r '"\(.secrets | length) keys"' 2>/dev/null)"
use_token sim
ia_request GET "$(secrets_path "$SIM_PROJECT")"
check "prod-sim reader lists $SIM_SLUG" 200 "$(printf '%s' "$IA_BODY" | jq -r '"\(.secrets | length) keys"' 2>/dev/null)"

use_token dev
ia_request GET "$(secrets_path "$SIM_PROJECT")"
check_denied "dev reader lists $SIM_SLUG" 403
ia_request GET "/api/v4/secrets/PG_PASSWORD?projectId=$SIM_PROJECT&environment=$ENV_SLUG&secretPath=%2F"
check_denied "dev reader reads $SIM_SLUG PG_PASSWORD" 403
ia_request GET "/api/v1/projects/slug/$SIM_SLUG"
check_denied "dev reader resolves slug $SIM_SLUG (operator's first call)" 403

use_token sim
ia_request GET "$(secrets_path "$DEV_PROJECT")"
check_denied "prod-sim reader lists $DEV_SLUG" 403
ia_request GET "/api/v4/secrets/PG_PASSWORD?projectId=$DEV_PROJECT&environment=$ENV_SLUG&secretPath=%2F"
check_denied "prod-sim reader reads $DEV_SLUG PG_PASSWORD" 403
ia_request GET "/api/v1/projects/slug/$DEV_SLUG"
check_denied "prod-sim reader resolves slug $DEV_SLUG" 403

log "Role limits on the reader's own project and organization"
PROBE_KEY="ISOLATION_PROBE_MUST_NOT_EXIST"
use_token dev
ia_request POST "/api/v4/secrets/$PROBE_KEY" \
  "$(jq -n --arg p "$DEV_PROJECT" --arg e "$ENV_SLUG" '{projectId: $p, environment: $e, secretPath: "/", secretValue: "x"}')"
check_denied "dev reader cannot write to its own project" 403
if [[ "$IA_STATUS" =~ ^2 ]]; then
  ia_load_admin
  ia_request DELETE "/api/v4/secrets/$PROBE_KEY" \
    "$(jq -n --arg p "$DEV_PROJECT" --arg e "$ENV_SLUG" '{projectId: $p, environment: $e, secretPath: "/"}')"
  warn "removed $PROBE_KEY, which the write above should not have created: HTTP $IA_STATUS"
fi
use_token dev
ia_request GET "/api/v2/organizations/$ORG_ID/identity-memberships"
check_denied "dev reader cannot list the organization's identities" 403

use_token ""
ia_request GET "$(secrets_path "$DEV_PROJECT")"
check_denied "no token at all" 401

# The in-pod half: the real Service address, the real NetworkPolicy path, and a pod-mounted token.
# The operator's own label is what the infisical policy admits, and the readiness gate keeps this pod
# out of every Service. The pod prints status codes only.
IN_POD_SCRIPT='
token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
call() { curl -sS --max-time 20 -o /tmp/body -w "%{http_code}" "$@" 2>/dev/null || printf 000; }
code="$(printf "{\"identityId\":\"%s\",\"jwt\":\"%s\"}" "$IDENTITY" "$token" | call -X POST -H "Content-Type: application/json" --data-binary @- "$API/api/v1/auth/kubernetes-auth/login")"
echo "RESULT login-own-identity $code"
access="$(sed -n "s/.*\"accessToken\":\"\([^\"]*\)\".*/\1/p" /tmp/body)"
echo "Authorization: Bearer $access" > /tmp/auth
rm -f /tmp/body
echo "RESULT list-own-project $(call -H @/tmp/auth "$API/api/v4/secrets?projectId=$OWN&environment=$ENV_SLUG&secretPath=%2F&viewSecretValue=false")"
echo "RESULT list-other-project $(call -H @/tmp/auth "$API/api/v4/secrets?projectId=$OTHER&environment=$ENV_SLUG&secretPath=%2F")"
echo "RESULT read-other-secret $(call -H @/tmp/auth "$API/api/v4/secrets/PG_PASSWORD?projectId=$OTHER&environment=$ENV_SLUG&secretPath=%2F")"
echo "RESULT other-project-slug $(call -H @/tmp/auth "$API/api/v1/projects/slug/$OTHER_SLUG")"
rm -f /tmp/auth /tmp/body
'

in_cluster() { # env identity own other other-slug
  local env="$1" ns pod name code
  ns="$(env_namespace "$env")"
  pod="isolation-probe-$(date +%s)"
  PROBE_PODS="$PROBE_PODS $ns/$pod"
  kc create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
  labels:
    app.kubernetes.io/name: secrets-operator
    plane-platform/probe: isolation
spec:
  serviceAccountName: $SERVICE_ACCOUNT
  automountServiceAccountToken: true
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: 240
  enableServiceLinks: false
  readinessGates:
    - conditionType: plane-platform/never-ready
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: $CURL_IMAGE
      imagePullPolicy: IfNotPresent
      command: [/bin/sh, -c]
      args:
        - |
$(sed 's/^/          /' <<<"$IN_POD_SCRIPT")
      env:
        - {name: API, value: "http://infisical.infisical.svc.cluster.local:8080"}
        - {name: ENV_SLUG, value: "$ENV_SLUG"}
        - {name: IDENTITY, value: "$2"}
        - {name: OWN, value: "$3"}
        - {name: OTHER, value: "$4"}
        - {name: OTHER_SLUG, value: "$5"}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 200m, memory: 64Mi}
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
  volumes:
    - name: tmp
      emptyDir: {medium: Memory, sizeLimit: 1Mi}
YAML
  if ! kc -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=200s >/dev/null 2>&1; then
    row BLOCKED "$env probe pod did not finish" Succeeded "-" \
      "$(kc -n "$ns" get pod "$pod" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
    return 0
  fi
  while read -r _ name code; do
    case "$name" in
      login-own-identity | list-own-project) IA_STATUS="$code"; IA_BODY=""; check "$env, in-cluster: $name" 200 ;;
      *) IA_STATUS="$code"; IA_BODY=""; check "$env, in-cluster: $name" 403 ;;
    esac
  done < <(kc -n "$ns" logs "$pod" | grep '^RESULT ')
}

if [[ "${ISOLATION_IN_CLUSTER:-yes}" != no ]]; then
  log "The same checks from inside each namespace, over the Service, with a pod-mounted token"
  in_cluster dev "$DEV_ID" "$DEV_PROJECT" "$SIM_PROJECT" "$SIM_SLUG"
  in_cluster prod-sim "$SIM_ID" "$SIM_PROJECT" "$DEV_PROJECT" "$DEV_SLUG"
fi

if [[ "$FAILED" -gt 0 ]]; then
  log "isolation: $FAILED FAILED, $BLOCKED BLOCKED"
  exit 1
elif [[ "$BLOCKED" -gt 0 ]]; then
  log "isolation: $BLOCKED BLOCKED, none failed. BLOCKED is not a pass."
  exit 2
fi
ok "isolation: every row passed"
