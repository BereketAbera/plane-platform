#!/usr/bin/env bash
# What can be proved about hosted production from outside it and through the tunnel, and what cannot be yet, said plainly.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/test-hosted.sh
#   ONLY="outside backups"   sections to run, of: outside argo netpol routes psa secrets smoke alerts backups
#
# CONFIRM, because it starts short-lived probe pods, mints 10-minute tokens, signs in, and sends one synthetic alert, which reaches
# the owner's phone if Telegram is set. It also spends this machine's login tries at Grafana's public route, so a login from here within
# a minute of it may read 429.
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

# Every console's name under the two zones, except Grafana's one public host. grafana under Wayline's domain stays in the list, because
# that route is one host and this is any other.
PARENT_DOMAIN="${HOSTED_GRAFANA_DOMAIN#*.}"
ADMIN_HOSTS="argocd.$HOSTED_DOMAIN grafana.$HOSTED_DOMAIN prometheus.$HOSTED_DOMAIN alertmanager.$HOSTED_DOMAIN infisical.$HOSTED_DOMAIN argocd.$PARENT_DOMAIN prometheus.$PARENT_DOMAIN alertmanager.$PARENT_DOMAIN infisical.$PARENT_DOMAIN"

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

# Each of these asks the node itself, by --resolve, so a resolver that has not caught up cannot answer for it. This row says what DNS says.
resolves_to_the_node() { # host
  local addresses
  addresses="$(python3 -I -c 'import socket, sys; print(" ".join(sorted(set(socket.gethostbyname_ex(sys.argv[1])[2]))))' "$1" 2>/dev/null || true)"
  if [[ "$addresses" == "$HOSTED_HOST" ]]; then
    row PASS "$1 resolves to the node, and only there"
  else
    row FAIL "$1 resolves to the node, and only there" "it answers: ${addresses:-nothing}. Terraform owns its record: scripts/hosted/host-terraform.sh"
  fi
}

redirects_to_https() { # host
  local answer code where
  answer="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 --resolve "$1:80:$HOSTED_HOST" "http://$1/" 2>&1 || true)"
  code="${answer%% *}"
  where="${answer#* }"
  if [[ "$code" =~ ^(301|308)$ && "$where" == "https://$1/" ]]; then row PASS "http://$1 redirects to https" "$code"; else row FAIL "http://$1 redirects to https" "$answer"; fi
}

served_certificate() { # host, and the Certificate that serves it
  local chain issuer end_date days
  chain="$(openssl s_client -connect "$HOSTED_HOST:443" -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null || true)"
  issuer="$(sed -n 's/^issuer=//p' <<<"$chain")"
  end_date="$(sed -n 's/^notAfter=//p' <<<"$chain")"
  if [[ -z "$end_date" ]]; then
    row FAIL "a certificate is served for $1" "no certificate came back. Read: make remote-status TARGET=plane-prod"
    return 0
  fi
  days="$(python3 -I -c 'import ssl, sys, time; print(int((ssl.cert_time_to_seconds(sys.argv[1]) - time.time()) // 86400))' "$end_date")"
  if [[ "$issuer" == *STAGING* || "$issuer" == *"(STAGING)"* ]]; then
    # Only Plane's matters to the smoke, and the smoke is what reads this.
    if [[ "$1" == "$HOSTED_DOMAIN" ]]; then STAGING=yes; fi
    row INCOMPLETE "a publicly trusted certificate for $1" "Let's Encrypt staging, $days days left. Move $2's issuerRef to letsencrypt-production"
  elif curl -sS -o /dev/null --max-time 15 --resolve "$1:443:$HOSTED_HOST" "https://$1/" 2>/dev/null; then
    if [[ "$days" -lt 14 ]]; then row FAIL "a publicly trusted certificate for $1" "$days days left, and it renews well before 14"; else row PASS "a publicly trusted certificate for $1" "$days days left, $issuer"; fi
  else
    row FAIL "a publicly trusted certificate for $1" "curl refused it: $issuer"
  fi
}

# The one console on the internet: its login page answers, its login is all that opens it, and the rest of it stays shut. -k, because the
# certificate has its own row above and a staging one is enough to ask these.
grafana_public() {
  local host="$HOSTED_GRAFANA_DOMAIN" url code page attempt path
  url="https://$host"
  local -a ask=(curl -k -sS --max-time 15 --resolve "$host:443:$HOSTED_HOST")

  page="$("${ask[@]}" -w '\n%{http_code}' "$url/login" 2>/dev/null || true)"
  code="${page##*$'\n'}"
  if [[ "$code" == 000 || -z "$code" ]]; then
    row BLOCKED "Grafana's login page answers" "no answer"
  elif [[ "$code" == 200 && "$page" == *"<title>Grafana</title>"* ]]; then
    row PASS "Grafana's login page answers" "$code"
    if [[ "$page" == *'"disableUserSignUp":true'* ]]; then
      row PASS "Grafana's login page offers no sign-up"
    else
      row FAIL "Grafana's login page offers no sign-up" "disableUserSignUp is not true in what it served"
    fi
  else
    row FAIL "Grafana's login page answers" "$code, and not Grafana's page"
  fi

  for path in /api/org /api/datasources; do
    code="$("${ask[@]}" -o /dev/null -w '%{http_code}' "$url$path" 2>/dev/null || true)"
    case "$code" in
      401) row PASS "an anonymous read of Grafana's $path is refused" "$code" ;;
      000 | "") row BLOCKED "an anonymous read of Grafana's $path is refused" "no answer" ;;
      *) row FAIL "an anonymous read of Grafana's $path is refused" "$code" ;;
    esac
  done

  # Traefik's own 404, from no route. Grafana answers any path it does not know by sending it to the login page.
  code="$("${ask[@]}" -o /dev/null -w '%{http_code}' "$url/metrics" 2>/dev/null || true)"
  case "$code" in
    404) row PASS "Grafana's /metrics is not public" "$code" ;;
    000 | "") row BLOCKED "Grafana's /metrics is not public" "no answer" ;;
    *) row FAIL "Grafana's /metrics is not public" "$code" ;;
  esac

  # A made-up user, so Grafana's own count of failures for the admin stays where it is, and a new X-Forwarded-For with each try, which the
  # limit must not read.
  local answers=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    code="$("${ask[@]}" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "X-Forwarded-For: 203.0.113.$attempt" \
      --data-binary '{"user":"test-hosted-rate-limit","password":"not-a-password"}' "$url/login" 2>/dev/null || true)"
    answers="$answers $code"
    [[ "$code" != 429 ]] || break
  done
  case "$code" in
    429) row PASS "guessing at Grafana's login hits a limit per client" "answers:$answers" ;;
    000 | "") row BLOCKED "guessing at Grafana's login hits a limit per client" "no answer" ;;
    *) row FAIL "guessing at Grafana's login hits a limit per client" "answers:$answers" ;;
  esac

  # "Per client" rests on Traefik seeing each client's own address, which hostPort's portmap should leave alone and nothing above shows.
  # These tries are what it logged last, so what it read for them is this machine's address, as Traefik saw it.
  if cluster_or_blocked "Traefik sees a client's own address"; then
    local seen
    seen="$(kc -n traefik logs deploy/traefik --tail=500 2>/dev/null |
      jq -Rr --arg host "$host" 'fromjson? | select(.RequestHost == $host and .RequestPath == "/login" and .RequestMethod == "POST") | .ClientHost' |
      LC_ALL=C sort -u | tr '\n' ' ' || true)"
    if [[ -z "${seen// /}" ]]; then
      row BLOCKED "Traefik sees a client's own address" "its log shows none of those tries"
    elif [[ "$seen" =~ (^|\ )(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
      row FAIL "Traefik sees a client's own address" "it read $seen, so every client shares one count at the login's limit"
    else
      row PASS "Traefik sees a client's own address" "$seen"
    fi
  fi

  # Through curl's config on stdin, so neither value reaches a process list, and only the status reaches this run's evidence.
  if [[ -s "$LOCAL_DIR/grafana-admin-user" && -s "$LOCAL_DIR/grafana-admin-password" ]]; then
    code="$(printf 'user = "%s:%s"\n' "$(cat "$LOCAL_DIR/grafana-admin-user")" "$(cat "$LOCAL_DIR/grafana-admin-password")" |
      "${ask[@]}" -K - -o /dev/null -w '%{http_code}' "$url/api/org" 2>/dev/null || true)"
    case "$code" in
      200) row PASS "the login held here opens Grafana" "$code" ;;
      000 | "") row BLOCKED "the login held here opens Grafana" "no answer" ;;
      *) row FAIL "the login held here opens Grafana" "$code. A running pod keeps the admin it started with: make remote-grafana-admin TARGET=plane-prod CONFIRM=plane-prod VERB=apply, and read scripts/hosted/grafana-admin.sh" ;;
    esac
  else
    row BLOCKED "the login held here opens Grafana" "no login in .local/hosted/plane-prod. Run: make remote-grafana-admin TARGET=plane-prod CONFIRM=plane-prod VERB=apply"
  fi
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

  local host
  for host in "$HOSTED_DOMAIN" "$HOSTED_GRAFANA_DOMAIN"; do resolves_to_the_node "$host"; done

  if [[ " $open " != *" 80 "* ]]; then
    row BLOCKED "http redirects to https" "port 80 is closed. Move the firewall on: scripts/hosted/edge.sh"
  else
    for host in "$HOSTED_DOMAIN" "$HOSTED_GRAFANA_DOMAIN"; do redirects_to_https "$host"; done
  fi

  if [[ " $open " != *" 443 "* ]]; then
    row BLOCKED "the certificates and the routes" "port 443 is closed from here. Move the firewall on: scripts/hosted/edge.sh"
    return 0
  fi

  served_certificate "$HOSTED_DOMAIN" wayline-tls
  served_certificate "$HOSTED_GRAFANA_DOMAIN" grafana-tls
  grafana_public

  # Asked by the public name's handshake, so sniStrict lets it through and only the Host decides. A route would answer anything else.
  local code
  for host in $ADMIN_HOSTS; do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $host" "https://$HOSTED_DOMAIN/" 2>/dev/null || true)"
    case "$code" in
      404 | 421) row PASS "no public route for $host" "$code" ;;
      000 | "") row BLOCKED "no public route for $host" "no answer" ;;
      *) row FAIL "no public route for $host" "$code" ;;
    esac
  done

  # The first POST to the admin sign-up owns an instance with no admin, and ENABLE_SIGNUP does not govern it. So that with 443 open to
  # anyone is the one state here that is not just unfinished. -k, because a staging certificate is enough to ask this.
  local setup stage
  setup="$(curl -k -sS --max-time 15 "https://$HOSTED_DOMAIN/api/instances/" 2>/dev/null | jq -r '(.instance // .).is_setup_done | tostring' 2>/dev/null || true)"
  case "$setup" in
    true) row PASS "the instance has its first admin" ;;
    false)
      stage="$("$ROOT/scripts/hosted/edge.sh" status 2>/dev/null || true)"
      if [[ "$stage" == *"ip saddr"*"dport 443 accept"* ]]; then
        row INCOMPLETE "the instance has its first admin" "not yet, and 443 answers only the owner's address. Create it now"
      else
        row FAIL "the instance has its first admin" "not yet, and 443 is open, so whoever posts first owns this instance. Close it now: scripts/hosted/edge.sh owner <your ipv4>"
      fi
      ;;
    *) row BLOCKED "the instance has its first admin" "/api/instances/ did not say, so Plane may not be deployed yet" ;;
  esac
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
for host in '$HOSTED_DOMAIN $ADMIN_HOSTS'.split():
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
  telegram_token_in_loki
}

# Alertmanager logs a failed send to Telegram with its URL, and the bot's token is in that URL. Alloy scrubs that on the way to Loki
# (values/alloy.yaml), so a line here means the scrub failed and the token is exposed. A count, so no value reaches this run's evidence.
telegram_token_in_loki() {
  local port count
  port="$(hosted_free_port 19196)"
  if ! hosted_forward_start monitoring svc/loki "$port" 3100; then
    row BLOCKED "Loki holds no Telegram bot token" "could not port-forward to Loki"
    return 0
  fi
  count="$(curl -fsS --max-time 60 -G "http://127.0.0.1:$port/loki/api/v1/query" --data-urlencode 'query=sum(count_over_time({namespace="monitoring"} |~ "bot[0-9]+:[A-Za-z0-9_-]+" [7d]))' |
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)" || count=""
  case "$count" in
    "") row BLOCKED "Loki holds no Telegram bot token" "could not ask Loki" ;;
    0) row PASS "Loki holds no Telegram bot token" ;;
    *) row FAIL "Loki holds no Telegram bot token" "$count lines hold one, so treat it as exposed: revoke it with BotFather, then run scripts/hosted/owner-inputs.sh telegram" ;;
  esac
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
