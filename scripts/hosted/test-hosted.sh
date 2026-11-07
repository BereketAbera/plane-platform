#!/usr/bin/env bash
# What can be proved about hosted production from outside it and through the tunnel, and what cannot be yet, said plainly.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/test-hosted.sh
#   ONLY="outside backups"   sections to run, of: outside argo netpol routes psa secrets smoke alerts backups
#
# CONFIRM, because it starts short-lived probe pods, mints 10-minute tokens, signs in, and sends one synthetic alert, which reaches
# the owner's phone if Telegram is set.
#
# Exit, as scripts/test.sh: 0 every row passed, 1 something failed, 2 nothing failed and something could not say yes:
#   BLOCKED     it could not run, and that says nothing about the platform.
#   INCOMPLETE  it ran, and the thing is not there yet: a staging certificate, nobody paged, no off-VPS restore, no nightly so far.
# Neither is a pass, and neither is ever reported as one. The restore test is separate: scripts/hosted/restore-test.sh.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this starts probe pods and sends a synthetic alert"

for tool in curl jq openssl python3 nc; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Run: make setup"
done

STAMP="$(hosted_stamp)"
EVIDENCE="$HOSTED_EVIDENCE_DIR/test-hosted-$STAMP.txt"
exec > >(tee "$EVIDENCE") 2>&1

FAILED=0
UNSURE=0
row() { # verdict what [detail]
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED | INCOMPLETE) UNSURE=$((UNSURE + 1)) ;;
  esac
  printf '%-11s %-58s %s\n' "$1" "$2" "${3:-}"
}

wanted() { [[ -z "${ONLY:-}" || " $ONLY " == *" $1 "* ]]; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

trap hosted_forward_stop EXIT

# ------ Which cluster --------------------------------------------------------------------------------------------------

section "Context and node"
CLUSTER=yes
problem="$(hosted_problem)"
if [[ -n "$problem" ]]; then
  row BLOCKED "this is plane-prod" "$problem"
  CLUSTER=no
else
  row PASS "this is plane-prod" "kube-system UID and node name match target.yaml, one context, through the tunnel"
fi

cluster_or_blocked() { # section name
  if [[ "$CLUSTER" == yes ]]; then return 0; fi
  row BLOCKED "$1" "the cluster is out of reach, so this did not run"
  return 1
}

# ------ From outside ---------------------------------------------------------------------------------------------------

STAGING=no

# Every privileged port, the NodePort range and what K3s and this platform listen on. Threads, because a drop only times out.
scan_ports() { # host
  python3 -I -c '
import concurrent.futures, socket, sys
host = sys.argv[1]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
known = [2379, 2380, 3000, 5001, 5432, 5672, 6379, 6443, 6444, 8000, 8080, 8443, 8472, 9000, 9090, 9093, 9100, 10010, 10248, 10249, 10250, 10256, 10257, 10259, 15672, 16443]
ports = sorted(set(list(range(1, 1025)) + known + list(range(30000, 32768))))
def probe(port):
    with socket.socket(family, socket.SOCK_STREAM) as s:
        s.settimeout(2)
        try:
            return port if s.connect_ex((host, port)) == 0 else None
        except OSError:
            return None
with concurrent.futures.ThreadPoolExecutor(200) as pool:
    print(" ".join(str(p) for p in pool.map(probe, ports) if p))
' "$1"
}

outside() {
  section "From outside: this machine is not on the VPS"
  local open extra
  log "Scanning $HOSTED_HOST, about 40 seconds"
  open="$(scan_ports "$HOSTED_HOST")" || {
    row BLOCKED "port scan" "the scan itself failed"
    return 0
  }
  extra="$(tr ' ' '\n' <<<"$open" | grep -Ev '^(22|80|443)$' | tr '\n' ' ' || true)"
  if [[ -n "${extra// /}" ]]; then row FAIL "only 22, 80 and 443 answer from outside" "also open: $extra"; else row PASS "only 22, 80 and 443 answer from outside" "open: $open"; fi
  [[ " $open " == *" 22 "* ]] || row FAIL "SSH answers" "22 is closed, and this run got here some other way"
  if [[ -n "$HOSTED_HOST6" ]]; then
    local open6
    open6="$(scan_ports "$HOSTED_HOST6")" || open6=""
    extra="$(tr ' ' '\n' <<<"$open6" | grep -Ev '^(22|80|443)$' | tr '\n' ' ' || true)"
    if [[ -n "${extra// /}" ]]; then row FAIL "only 22, 80 and 443 answer on IPv6" "also open: $extra"; else row PASS "nothing extra answers on IPv6" "open: ${open6:-none, or this machine has no IPv6}"; fi
  fi

  if [[ " $open " != *" 80 "* ]]; then
    row BLOCKED "http redirects to https" "port 80 is closed. Move the firewall on: scripts/hosted/edge.sh"
  else
    local answer code where
    answer="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "http://$HOSTED_DOMAIN/" 2>&1 || true)"
    code="${answer%% *}"
    where="${answer#* }"
    if [[ "$code" =~ ^(301|308)$ && "$where" == "https://$HOSTED_DOMAIN/" ]]; then row PASS "http redirects to https" "$code"; else row FAIL "http redirects to https" "$answer"; fi
  fi

  if [[ " $open " != *" 443 "* ]]; then
    row BLOCKED "the certificate and the routes" "port 443 is closed from here. Move the firewall on: scripts/hosted/edge.sh"
    return 0
  fi

  local chain issuer end_date days
  chain="$(openssl s_client -connect "$HOSTED_HOST:443" -servername "$HOSTED_DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null || true)"
  issuer="$(sed -n 's/^issuer=//p' <<<"$chain")"
  end_date="$(sed -n 's/^notAfter=//p' <<<"$chain")"
  if [[ -z "$end_date" ]]; then
    row FAIL "a certificate is served for $HOSTED_DOMAIN" "no certificate came back. Read: make remote-status TARGET=plane-prod"
  else
    days="$(python3 -I -c 'import ssl, sys, time; print(int((ssl.cert_time_to_seconds(sys.argv[1]) - time.time()) // 86400))' "$end_date")"
    if [[ "$issuer" == *STAGING* || "$issuer" == *"(STAGING)"* ]]; then
      STAGING=yes
      row INCOMPLETE "a publicly trusted certificate" "Let's Encrypt staging, $days days left. Move wayline-tls's issuerRef to letsencrypt-production"
    elif curl -sS -o /dev/null --max-time 15 "https://$HOSTED_DOMAIN/" 2>/dev/null; then
      if [[ "$days" -lt 14 ]]; then row FAIL "a publicly trusted certificate" "$days days left, and it renews well before 14"; else row PASS "a publicly trusted certificate" "$days days left, $issuer"; fi
    else
      row FAIL "a publicly trusted certificate" "curl refused it: $issuer"
    fi
  fi

  # Asked by the public name's handshake, so sniStrict lets it through and only the Host decides. A route would answer anything else.
  local ui code
  for ui in argocd grafana prometheus alertmanager infisical; do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $ui.$HOSTED_DOMAIN" "https://$HOSTED_DOMAIN/" 2>/dev/null || true)"
    case "$code" in
      404 | 421) row PASS "no public route for $ui" "Host $ui.$HOSTED_DOMAIN answers $code" ;;
      000 | "") row BLOCKED "no public route for $ui" "no answer" ;;
      *) row FAIL "no public route for $ui" "Host $ui.$HOSTED_DOMAIN answers $code" ;;
    esac
  done
}

# ------ Argo CD --------------------------------------------------------------------------------------------------------

argo() {
  section "Argo CD"
  cluster_or_blocked "Applications" || return 0
  local applications bad
  applications="$(kc -n argocd get applications -o json 2>/dev/null)" || {
    row BLOCKED "Applications" "could not read them"
    return 0
  }
  bad="$(jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"' <<<"$applications" | tr '\n' ' ')"
  if [[ -n "$bad" ]]; then row FAIL "every Application is Synced and Healthy" "$bad"; else row PASS "every Application is Synced and Healthy" "$(jq -r '.items | length' <<<"$applications") of them"; fi
  if jq -e '.items | any(.metadata.name == "plane-prod")' <<<"$applications" >/dev/null; then
    row PASS "Plane is deployed"
  else
    row INCOMPLETE "Plane is deployed" "Application plane-prod does not exist until the first promotion, so rows about Plane read BLOCKED"
  fi
  local repositories
  repositories="$(jq -r '[.items[] | (.spec.source.repoURL // empty), (.spec.sources[]?.repoURL // empty)] | unique | .[]' <<<"$applications" | grep -E '^(ssh|git|https://github)' | sort -u | tr '\n' ' ' || true)"
  if [[ "$repositories" == "$HOSTED_REPO_URL " ]]; then row PASS "Git source is only $HOSTED_REPO_URL"; else row FAIL "Git source is only $HOSTED_REPO_URL" "got: $repositories"; fi
}

# ------ NetworkPolicy --------------------------------------------------------------------------------------------------

netpol() {
  section "NetworkPolicy: sentinel, then the matrix"
  cluster_or_blocked "NetworkPolicy matrix" || return 0
  local rc=0
  WAYLINE_TARGET=plane-prod "$ROOT/scripts/test-netpol.sh" || rc=$?
  case "$rc" in
    0) row PASS "the sentinel and every row of the matrix" ;;
    2) row INCOMPLETE "the sentinel and every row of the matrix" "the sentinel passed, and rows read INCONCLUSIVE, above. Rows on Plane do until it is deployed" ;;
    *) row FAIL "the sentinel and every row of the matrix" "exit $rc, above" ;;
  esac
}

# ------ Routes, from inside --------------------------------------------------------------------------------------------

routes() {
  section "What the api can ask Traefik for"
  cluster_or_blocked "routes from the api" || return 0
  if ! kc -n plane-prod get deployment plane-api-wl >/dev/null 2>&1; then
    row BLOCKED "routes from the api" "Plane is not deployed"
    return 0
  fi
  local answers
  # The public name, which CoreDNS rewrites to Traefik's Service, so the SNI matches. Code passed as an argument and carrying nothing secret.
  answers="$(kc -n plane-prod exec deploy/plane-api-wl -c plane-api -- python -c "
import http.client, ssl
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
for host in ['$HOSTED_DOMAIN', 'argocd.$HOSTED_DOMAIN', 'grafana.$HOSTED_DOMAIN', 'prometheus.$HOSTED_DOMAIN', 'alertmanager.$HOSTED_DOMAIN', 'infisical.$HOSTED_DOMAIN']:
    connection = http.client.HTTPSConnection('$HOSTED_DOMAIN', 443, context=context, timeout=10)
    connection.request('GET', '/api/instances/', headers={'Host': host})
    print('ANSWER', host, connection.getresponse().status)
" 2>/dev/null | grep '^ANSWER' || true)"
  if [[ -z "$answers" ]]; then
    row BLOCKED "routes from the api" "the api pod gave no answer"
    return 0
  fi
  local _word host code
  while read -r _word host code; do
    if [[ "$host" == "$HOSTED_DOMAIN" ]]; then
      if [[ "$code" == 200 ]]; then row PASS "the api reaches its own public host" "$code, so the 404s below mean something"; else row FAIL "the api reaches its own public host" "$code"; fi
    elif [[ "$code" == 404 || "$code" == 421 ]]; then
      row PASS "the api gets no $host" "$code"
    else
      row FAIL "the api gets no $host" "$code"
    fi
  done <<<"$answers"
}

# ------ Pod Security ---------------------------------------------------------------------------------------------------

psa() {
  section "Pod Security"
  cluster_or_blocked "Pod Security" || return 0
  local namespace answer
  for namespace in plane-prod infisical monitoring; do
    # A server-side dry run, so nothing is created, and admission still has to say yes.
    answer="$(kc apply --dry-run=server -f - 2>&1 <<YAML || true
apiVersion: v1
kind: Pod
metadata:
  name: test-hosted-host-network
  namespace: $namespace
spec:
  hostNetwork: true
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 32Mi}}
YAML
)"
    if [[ "$answer" == *hostNetwork* && "$answer" == *PodSecurity* ]]; then
      row PASS "$namespace refuses hostNetwork" "admission said no"
    elif [[ "$answer" == *created* ]]; then
      row FAIL "$namespace refuses hostNetwork" "admission allowed it, on a dry run, so nothing was made"
    else
      row BLOCKED "$namespace refuses hostNetwork" "$(tr '\n' ' ' <<<"$answer" | cut -c1-160)"
    fi
  done
}

# ------ Secrets --------------------------------------------------------------------------------------------------------

secrets() {
  section "Rendered Secrets, and who can read them"
  cluster_or_blocked "Rendered Secrets" || return 0
  if ! kc -n plane-prod get secret plane-pgdb >/dev/null 2>&1; then
    row BLOCKED "Rendered Secrets" "Plane is not deployed, so no Secret has rendered"
    return 0
  fi
  local rc=0
  WAYLINE_TARGET=plane-prod "$ROOT/infisical/tests/rendered-secrets.sh" prod || rc=$?
  case "$rc" in
    0) row PASS "rendered Secrets match the contract" ;;
    2) row BLOCKED "rendered Secrets match the contract" "a namespace could not be read, above" ;;
    *) row FAIL "rendered Secrets match the contract" "exit $rc, above" ;;
  esac
  local kind
  kind="$(kc -n plane-prod get secret ghcr-pull -o json 2>/dev/null |
    jq -r 'if .type == "kubernetes.io/dockerconfigjson" and ((.data[".dockerconfigjson"] | @base64d | fromjson).auths["ghcr.io"].password | length) > 0 then "ok" else "wrong" end' 2>/dev/null || true)"
  if [[ "$kind" == ok ]]; then row PASS "Secret ghcr-pull holds a credential for ghcr.io"; else row FAIL "Secret ghcr-pull holds a credential for ghcr.io" "${kind:-missing}"; fi
  identity_refusal
}

# Only plane-prod's ServiceAccount may log in as plane-prod's identity. The right one first, so a dead route cannot pass as a refusal.
# Tokens stay in memory, and reach curl on stdin.
identity_refusal() {
  local port identity right wrong code_right code_wrong
  identity="$(kc -n plane-prod get secret plane-infisical-identity -o json 2>/dev/null | jq -r '.data.identityId // empty | @base64d' || true)"
  if [[ -z "$identity" ]]; then
    row BLOCKED "only namespace plane-prod logs in as its identity" "Secret plane-infisical-identity is not there"
    return 0
  fi
  port="$(hosted_free_port 18110)"
  if ! hosted_forward_start infisical svc/infisical "$port" 8080; then
    row BLOCKED "only namespace plane-prod logs in as its identity" "could not port-forward to Infisical"
    return 0
  fi
  right="$(kc -n plane-prod create token plane-infisical-auth --duration=10m 2>/dev/null || true)"
  wrong="$(kc -n monitoring create token default --duration=10m 2>/dev/null || true)"
  try_login() { # jwt on stdin
    jq -Rs --arg id "$identity" '{identityId: $id, jwt: (. | rtrimstr("\n"))}' |
      curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$port/api/v1/auth/kubernetes-auth/login" || true
  }
  code_right="$(printf '%s' "$right" | try_login)"
  code_wrong="$(printf '%s' "$wrong" | try_login)"
  right=""
  wrong=""
  if [[ "$code_right" != 200 ]]; then
    row FAIL "plane-prod's ServiceAccount logs in as its identity" "HTTP $code_right"
  elif [[ "$code_wrong" == 401 || "$code_wrong" == 403 ]]; then
    row PASS "only namespace plane-prod logs in as its identity" "plane-prod 200, monitoring $code_wrong"
  else
    row FAIL "only namespace plane-prod logs in as its identity" "a token from monitoring answered $code_wrong"
  fi
}

# ------ Smoke ----------------------------------------------------------------------------------------------------------

smoke() {
  section "Smoke, on an existing account over https"
  local rc=0 options=""
  [[ "$STAGING" != yes ]] || options=yes
  SMOKE_ALLOW_STAGING="${SMOKE_ALLOW_STAGING:-$options}" "$ROOT/scripts/hosted/smoke.sh" || rc=$?
  case "$rc" in
    0) row PASS "smoke: sign-in, Secure cookies, project, upload, wss, job, cleanup" ;;
    2) row BLOCKED "smoke: sign-in, Secure cookies, project, upload, wss, job, cleanup" "above" ;;
    *) row FAIL "smoke: sign-in, Secure cookies, project, upload, wss, job, cleanup" "exit $rc, above" ;;
  esac
}

# ------ Alerts ---------------------------------------------------------------------------------------------------------

alerts() {
  section "Prometheus and Alertmanager"
  local delivery rc=0
  delivery="$("$ROOT/scripts/hosted/alerts.sh" state)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then row PASS "alert delivery" "$delivery"; else row INCOMPLETE "alert delivery" "$delivery"; fi

  cluster_or_blocked "targets and alerts" || return 0
  local prom am
  prom="$(hosted_free_port 19190)"
  am="$(hosted_free_port 19193)"
  if ! hosted_forward_start monitoring svc/kps-prometheus "$prom" 9090 || ! hosted_forward_start monitoring svc/kps-alertmanager "$am" 9093; then
    row BLOCKED "targets and alerts" "could not port-forward to Prometheus and Alertmanager"
    return 0
  fi

  local down firing critical
  down="$(curl -fsS --max-time 20 "http://127.0.0.1:$prom/api/v1/targets?state=active" |
    jq -r '[.data.activeTargets[] | select(.health != "up") | "\(.labels.job // .scrapePool)@\(.labels.instance // "")"] | unique | join(" ")' 2>/dev/null)" || down="unreadable"
  if [[ "$down" == unreadable ]]; then
    row BLOCKED "every scrape target is up" "could not read the targets"
  elif [[ -n "$down" ]]; then
    row FAIL "every scrape target is up" "down: $down"
  else
    row PASS "every scrape target is up"
  fi

  firing="$(curl -fsS --max-time 20 "http://127.0.0.1:$prom/api/v1/alerts" 2>/dev/null)" || firing=""
  if [[ -z "$firing" ]]; then
    row BLOCKED "what is firing" "could not read the alerts"
  else
    critical="$(jq -r '[.data.alerts[] | select(.state == "firing" and .labels.severity == "critical") | .labels.alertname] | unique | join(" ")' <<<"$firing")"
    local others
    others="$(jq -r '[.data.alerts[] | select(.state == "firing" and .labels.severity != "critical" and .labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor") | .labels.alertname] | unique | join(" ")' <<<"$firing")"
    if [[ -n "$critical" ]]; then row FAIL "nothing critical is firing" "$critical"; else row PASS "nothing critical is firing" "${others:+others firing: $others}"; fi
    if jq -e '.data.alerts | any(.labels.alertname == "Watchdog" and .state == "firing")' <<<"$firing" >/dev/null; then
      row PASS "Watchdog fires, so rules evaluate"
    else
      row FAIL "Watchdog fires, so rules evaluate" "it is meant to fire always"
    fi
  fi

  synthetic_alert "$am"
}

# One alert through Alertmanager, ending by itself in 5 minutes. Watchdog keeps pinging meanwhile, so what shows this one left has to
# be told apart from those: the Telegram counter, which Watchdog never moves, or the sink's own log, which names each alert.
synthetic_alert() { # port
  local port="$1" integration="" sent_before failed_before sent failed now ends deadline=$((SECONDS + 150)) answer
  if [[ -s "$LOCAL_DIR/alert-telegram-bot-token" && -s "$LOCAL_DIR/alert-telegram-chat-id" ]]; then integration=telegram; fi
  counter() { # metric: this integration's series, or all of them if there is none to single out
    curl -fsS --max-time 15 "http://127.0.0.1:$port/metrics" 2>/dev/null |
      awk -v m="$1" -v want="$integration" 'index($0, m "{") == 1 && (want == "" || index($0, "integration=\"" want "\"") > 0) { total += $NF } END { print total + 0 }'
  }
  sent_before="$(counter alertmanager_notifications_total)"
  failed_before="$(counter alertmanager_notifications_failed_total)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ends="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
  answer="$(jq -n --arg now "$now" --arg ends "$ends" --arg stamp "$STAMP" '[{labels: {alertname: "WaylineSyntheticTest", severity: "info", namespace: "test-hosted", run: $stamp},
      annotations: {summary: "make remote-test sent this, to prove alerts leave Alertmanager. Nothing is wrong."}, startsAt: $now, endsAt: $ends}]' |
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$port/api/v2/alerts" || true)"
  if [[ "$answer" != 200 ]]; then
    row FAIL "Alertmanager takes a synthetic alert" "HTTP $answer"
    return 0
  fi
  row PASS "Alertmanager takes a synthetic alert"
  log "Waiting up to 150 s for a notification to leave. group_wait is 30 s."
  while [[ $SECONDS -lt $deadline ]]; do
    sent="$(counter alertmanager_notifications_total)"
    failed="$(counter alertmanager_notifications_failed_total)"
    if [[ "$failed" -gt "$failed_before" ]]; then
      row FAIL "a notification leaves Alertmanager" "alertmanager_notifications_failed_total rose from $failed_before to $failed. Read its log, and the policy on 443"
      return 0
    fi
    if [[ "$integration" == telegram && "$sent" -gt "$sent_before" ]]; then
      row PASS "a notification leaves Alertmanager" "the Telegram counter rose, and the failed one did not. Your phone should show WaylineSyntheticTest"
      return 0
    fi
    if [[ -z "$integration" ]] && kc -n monitoring logs deploy/alert-sink --tail=-1 2>/dev/null | grep "$STAMP" >/dev/null; then
      row PASS "a notification reaches the sink" "the sink logged this run's alert"
      return 0
    fi
    sleep 5
  done
  row FAIL "a notification leaves Alertmanager" "nothing to show it left in 150 s"
}

# ------ Backups --------------------------------------------------------------------------------------------------------

backups() {
  section "Backups"
  if cluster_or_blocked "the nightly backups"; then
    local namespace last age
    for namespace in infisical plane-prod; do
      last="$(kc -n "$namespace" get cronjob plane-backup -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)"
      if [[ -z "$last" ]]; then
        row INCOMPLETE "$namespace: a nightly backup in the last 26 h" "none has succeeded yet. To run one: make remote-backup TARGET=plane-prod CONFIRM=plane-prod"
        continue
      fi
      age="$(python3 -I -c 'import datetime, sys; print(int((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))).total_seconds() // 3600))' "$last")"
      if [[ "$age" -ge 26 ]]; then row FAIL "$namespace: a nightly backup in the last 26 h" "the last was $age hours ago"; else row PASS "$namespace: a nightly backup in the last 26 h" "$age hours ago"; fi
    done
  fi
  local rc=0 said
  said="$("$ROOT/scripts/hosted/backup-dest.sh" status)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then row PASS "a copy off the VPS has been restored" "$said"; else row INCOMPLETE "a copy off the VPS has been restored" "$said"; fi
  if [[ -n "$(find "$LOCAL_DIR/recovery-bundle" -maxdepth 1 -type f -name 'wayline-recovery-*.tar.age' 2>/dev/null | head -1)" ]]; then
    row PASS "a recovery bundle exists here" "copy it off this machine. scripts/hosted/bundle.sh verify says if it is stale"
  else
    row INCOMPLETE "a recovery bundle exists here" "none, so this machine holds the only copy of secret zero. Run: scripts/hosted/bundle.sh"
  fi
}

# ------ The run --------------------------------------------------------------------------------------------------------

for name in outside argo netpol routes psa secrets smoke alerts backups; do
  if wanted "$name"; then "$name"; fi
done

section "Summary"
log "Evidence: ${EVIDENCE#"$ROOT"/}"
if [[ "$FAILED" -gt 0 ]]; then
  warn "$FAILED FAILED, $UNSURE BLOCKED or INCOMPLETE"
  exit 1
fi
if [[ "$UNSURE" -gt 0 ]]; then
  warn "none failed, and $UNSURE read BLOCKED or INCOMPLETE. That is not a pass."
  exit 2
fi
ok "every row passed"
