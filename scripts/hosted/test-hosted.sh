#!/usr/bin/env bash
# What can be proved about hosted production from outside it and through the tunnel, and what cannot be yet, said plainly.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/test-hosted.sh
#   ONLY="outside backups"   sections to run, of: outside argo netpol routes psa secrets smoke alerts backups
#   scripts/hosted/test-hosted.sh --selftest   the verdicts on the public consoles' rows, from tables, and the tries at Infisical's limits
#                                              against a stand-in on this machine, with no cluster, so CI can run it
#
# CONFIRM, because it starts short-lived probe pods, mints 10-minute tokens, signs in, and sends one synthetic alert, which reaches
# the owner's phone if Telegram is set. It also spends this machine's login tries at Grafana's and Infisical's public routes, and its
# session calls at Infisical's, so a login or a page of Infisical's from here within a minute of it may read 429. At Infisical's it spends
# no real credential: the tries are a made-up address, and one more comes from the api's pod, which spends that pod's own.
#
# Exit, as scripts/test.sh: 0 every row passed, 1 something failed, 2 nothing failed and something could not say yes:
#   BLOCKED     it could not run, and that says nothing about the platform.
#   INCOMPLETE  it ran, and the thing is not there yet: a staging certificate, nobody paged, no off-VPS restore, no nightly so far.
# Neither is a pass, and neither is ever reported as one. The restore test is separate: scripts/hosted/restore-test.sh.
set -euo pipefail

# ------ Verdicts on Grafana's and Infisical's rows, as verdict|detail, from what came back. Ahead of lib.sh, so --selftest needs no cluster

# The held login, posted to the form.
grafana_form_verdict() { # <status>
  case "$1" in
    200) printf 'PASS|%s' "$1" ;;
    429) printf 'BLOCKED|429, because this machine spent its tries in the last minute. Run this again' ;;
    000 | "") printf 'BLOCKED|no answer' ;;
    *) printf 'FAIL|%s. Five failed logins from this address lock it for five minutes, and a running pod keeps the admin it started with: scripts/hosted/README.md, and scripts/hosted/grafana-admin.sh' "$1" ;;
  esac
}

# The same login by basic auth, asked only after the form took it in this run. A 401 then can only mean basic auth is off, and not a stale
# password or this address's five failures, which the form would have shown.
grafana_basic_auth_verdict() { # <the form's status> <basic auth's status, or nothing if it was not asked>
  if [[ "$1" != 200 ]]; then
    printf 'BLOCKED|not asked, because the held login did not open Grafana at the form, so a 401 would prove nothing'
    return 0
  fi
  case "$2" in
    401) printf 'PASS|%s' "$2" ;;
    000 | "") printf 'BLOCKED|no answer' ;;
    *) printf "FAIL|%s, and each failed try there writes to its database, past the login's limit" "$2" ;;
  esac
}

# What kubectl auth can-i said for Grafana's ServiceAccount: yes, or no with or without a reason, and nothing when the API server did not
# answer. Each question on Secrets is scope:verb=answer, and every one must be a no, because one that did not come back proves nothing.
grafana_token_verdict() { # <the answer for list configmaps> <scope:verb=answer>...
  local configmaps="$1" pair allowed="" unanswered=0
  shift
  case "$configmaps" in
    yes) ;;
    no*)
      printf 'FAIL|it cannot read ConfigMaps, so its sidecar has nothing to write, and a no to Secrets would prove nothing'
      return 0
      ;;
    *)
      printf 'BLOCKED|the API server did not answer'
      return 0
      ;;
  esac
  [[ "$#" -gt 0 ]] || { printf 'BLOCKED|nothing was asked about Secrets'; return 0; }
  for pair in "$@"; do
    case "${pair#*=}" in
      yes) allowed="$allowed ${pair%%=*}" ;;
      no*) ;;
      *) unanswered=$((unanswered + 1)) ;;
    esac
  done
  if [[ -n "$allowed" ]]; then
    printf 'FAIL|on Secrets it may:%s' "$allowed"
  elif [[ "$unanswered" -gt 0 ]]; then
    printf 'BLOCKED|the API server did not answer %s of the %s questions on Secrets' "$unanswered" "$#"
  else
    printf 'PASS|Secrets: no get, list or watch, in monitoring or in every namespace'
  fi
}

# hide_version takes the version and the commit out of /api/health. One field of /login keeps the version: the values file says so.
grafana_health_verdict() { # <status> <body>
  case "$1" in
    000 | "") printf 'BLOCKED|no answer' ;;
    200)
      if [[ "$2" == *'"version"'* || "$2" == *'"commit"'* ]]; then
        printf 'FAIL|%s, so [auth.anonymous] hide_version is not on' "$(printf '%s' "$2" | tr -d ' \n' | cut -c1-120)"
      else
        printf 'PASS|%s' "$(printf '%s' "$2" | tr -d ' \n' | cut -c1-120)"
      fi
      ;;
    *) printf 'FAIL|%s' "$1" ;;
  esac
}

# Infisical's own answer to a call it refuses with no session: 401, with helmet's X-Download-Options, which it puts on all it sends and
# Traefik never does. The rows that read Traefik's 404 below lean on one of these, because with no route at all they would read 404 too.
infisical_reached_verdict() { # <status> <helmet or none>
  case "$1 $2" in
    "401 helmet") printf 'PASS|%s from Infisical' "$1" ;;
    "000 "* | " "*) printf 'BLOCKED|no answer' ;;
    *" helmet") printf 'FAIL|%s from Infisical, where its login should have refused it 401' "$1" ;;
    *) printf 'FAIL|%s, and not from Infisical, so the route does not pass what a browser asks' "$1" ;;
  esac
}

# Traefik's refusal counts only beside a row above that showed the route reaching Infisical, because with no route at all it is the same 404.
infisical_refusal_verdict() { # <PASS if the route was shown to reach Infisical> <what traefik_refused said>
  if [[ "$1" != PASS ]]; then
    printf 'BLOCKED|the route did not reach Infisical above, so a 404 here would say nothing'
    return 0
  fi
  case "$2" in
    refused) printf 'PASS|Traefik answered 404' ;;
    "no answer") printf 'BLOCKED|no answer' ;;
    *) printf 'FAIL|it reached Infisical: %s' "$2" ;;
  esac
}

# A run of tries at one of the route's limits, from limit_tries below, held to route.yaml's numbers from both sides. Every try before the 429
# must have reached Infisical, which gives this call the status named, and the 429 must be Traefik's. Infisical must have answered at least
# the burst, and no more than the burst and what the bucket refills in the time the tries took, with the half second that Traefik holds a try
# for a token. So a limit of 5 or of 44, or Infisical's own, reads FAIL. Traefik forgets an address it has not seen for 1 + 60 / <per minute>
# seconds, and then starts it full again, so a pause that long reads BLOCKED. So do tries too slow to empty the bucket, which cannot show it.
infisical_limit_verdict() { # <burst> <per minute> <Infisical's status> <ms the tries took> <longest pause between two, in ms> <status/who>...
  local burst="$1" per_minute="$2" status="$3" took="${4:-}" pause="${5:-}" answer served=0 met=no forget most seconds
  [[ "$#" -gt 5 && "$took" =~ ^[0-9]+$ && "$pause" =~ ^[0-9]+$ ]] || { printf 'BLOCKED|no answer'; return 0; }
  shift 5
  for answer in "$@"; do
    case "$answer" in
      "$status/helmet") served=$((served + 1)) ;;
      429/none)
        met=yes
        break
        ;;
      000/*) printf 'BLOCKED|no answer to try %s, after %s from Infisical' "$((served + 1))" "$served"; return 0 ;;
      429/helmet) printf "FAIL|try %s met Infisical's own limit, and not the route's" "$((served + 1))"; return 0 ;;
      */helmet) printf 'FAIL|try %s answered %s from Infisical, which gives this call %s' "$((served + 1))" "${answer%/*}" "$status"; return 0 ;;
      *) printf 'FAIL|try %s answered %s, and not from Infisical, so the route does not pass this call' "$((served + 1))" "${answer%/*}"; return 0 ;;
    esac
  done
  forget=$((1 + 60 / per_minute))
  most=$((burst + per_minute * (took + 500) / 60000))
  seconds="$((took / 1000)).$((took % 1000 / 100))"
  # Too few comes first, because no pause can explain it: a bucket that Traefik forgot starts full again, and lets more through, not fewer.
  if [[ "$met" == yes && "$served" -lt "$burst" ]]; then
    printf "FAIL|Traefik's 429 at try %s, after %s from Infisical, where the limit lets %s through at once. So it is lower than route.yaml's, or this address used it in the %s s before" \
      "$((served + 1))" "$served" "$burst" "$forget"
  elif [[ "$pause" -ge $((forget * 1000)) ]]; then
    printf 'BLOCKED|a pause of %s.%s s between two tries, and Traefik forgets an address after %s s, so the count says nothing. Run this again' \
      "$((pause / 1000))" "$((pause % 1000 / 100))" "$forget"
  elif [[ "$met" == yes && "$served" -gt "$most" ]]; then
    printf "FAIL|Traefik's 429 at try %s, after %s from Infisical in %s s, where the limit lets at most %s through in that time. So it is wider than route.yaml's" \
      "$((served + 1))" "$served" "$seconds" "$most"
  elif [[ "$met" == yes ]]; then
    printf "PASS|Traefik's 429 at try %s, after %s from Infisical in %s s, where the limit lets %s to %s through" "$((served + 1))" "$served" "$seconds" "$burst" "$most"
  elif [[ "$served" -gt "$most" ]]; then
    printf 'FAIL|no 429 in %s tries in %s s, where the limit lets at most %s through in that time' "$served" "$seconds" "$most"
  else
    printf 'BLOCKED|no 429 in %s tries in %s s, which the limit lets through at that pace, so they could not reach it' "$served" "$seconds"
  fi
}

# The tries at one of the route's limits, one after another over one kept-alive connection, until the first 429 or <most> of them. A curl for
# each try opened a connection of its own, three round trips from this Mac to the VPS, and at that pace the bucket refilled about as fast as
# the tries emptied it, so a working limit read FAIL. Over one connection a try costs one round trip. Each try sends a new X-Forwarded-For,
# which the limit must not read, and the certificate is not checked here, because it has its own row. Prints the milliseconds from the start of
# the first try to the last answer, the longest pause from the start of one try to the start of the next, and each answer as its status and
# helmet, when Infisical sent it, or none. A try with no answer reads 000/none, and is the last.
limit_tries() { # address port host method path most [JSON body]
  python3 -I -c '
import http.client, socket, ssl, sys, time
address, port, host, method, path, most = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
body = sys.argv[7] if len(sys.argv) > 7 else None
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

# To the node by its address, with the host in the handshake and in Host, as curl --resolve asks.
class Pinned(http.client.HTTPSConnection):
    def connect(self):
        self.sock = context.wrap_socket(socket.create_connection((address, self.port), self.timeout), server_hostname=host)

connection = Pinned(host, port, timeout=15)
try:
    connection.connect()
except OSError:
    print(0, 0, "000/none")
    sys.exit()
answers, starts = [], []
for attempt in range(1, most + 1):
    headers = {"User-Agent": "test-hosted", "X-Forwarded-For": "203.0.113.%d" % attempt}
    if body is not None:
        headers["Content-Type"] = "application/json"
    starts.append(time.monotonic())
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        response.read()
    except (OSError, http.client.HTTPException):
        answers.append("000/none")
        break
    answers.append("%d/%s" % (response.status, "helmet" if response.getheader("X-Download-Options") else "none"))
    if response.status == 429:
        break
took = time.monotonic() - starts[0]
pause = max([later - earlier for earlier, later in zip(starts, starts[1:])] or [0])
print(int(took * 1000), int(pause * 1000), " ".join(answers))
' "$@"
}

# One try from another address, once this machine's tries have met the limit: anything but 429 from Infisical shows the count is this
# machine's alone.
infisical_other_client_verdict() { # <this machine's last answer> <the other client's status> <helmet or none>
  if [[ "$1" != 429 ]]; then
    printf 'BLOCKED|this machine did not meet the limit above, so another address would show nothing'
    return 0
  fi
  case "$2 $3" in
    "429 "*) printf 'FAIL|429, so every client shares one count, and a stranger'"'"'s guesses hold off the admin' ;;
    *" helmet") printf 'PASS|%s from Infisical' "$2" ;;
    *) printf 'BLOCKED|%s, not from Infisical, so it says nothing of the limit' "${2:-no answer}" ;;
  esac
}

if [[ "${1:-}" == --selftest ]]; then
  failures=0
  check_verdict() { # check_verdict <want> <function> <argument>...
    local want="$1" got
    shift
    got="$("$@")"
    if [[ "${got%%|*}" != "$want" ]]; then
      printf 'FAIL %s: got %s, want %s\n' "$*" "${got%%|*}" "$want"
      failures=$((failures + 1))
    fi
  }
  # The form's status, then basic auth's, if it was asked. A dash is nothing.
  while read -r want form basic; do
    [[ "$form" != - ]] || form=""
    [[ "$basic" != - ]] || basic=""
    check_verdict "$want" grafana_basic_auth_verdict "$form" "$basic"
  done <<'TABLE'
PASS 200 401
FAIL 200 200
FAIL 200 302
BLOCKED 200 000
BLOCKED 200 -
BLOCKED 401 -
BLOCKED 401 401
BLOCKED 429 -
BLOCKED 000 -
BLOCKED - -
TABLE
  while read -r want form; do
    [[ "$form" != - ]] || form=""
    check_verdict "$want" grafana_form_verdict "$form"
  done <<'TABLE'
PASS 200
FAIL 401
FAIL 302
BLOCKED 429
BLOCKED 000
BLOCKED -
TABLE
  # The answer for list configmaps, then those for get, list and watch on Secrets in monitoring and in every namespace, joined by commas,
  # or none if they were not asked. A dash is nothing, and an underscore a space.
  questions=(monitoring:get monitoring:list monitoring:watch all:get all:list all:watch)
  while read -r want configmaps secrets; do
    [[ "$configmaps" != - ]] || configmaps=""
    configmaps="${configmaps//_/ }"
    pairs=()
    if [[ "$secrets" != none ]]; then
      i=0
      for answer in ${secrets//,/ }; do
        [[ "$answer" != - ]] || answer=""
        pairs+=("${questions[$i]}=${answer//_/ }")
        i=$((i + 1))
      done
    fi
    check_verdict "$want" grafana_token_verdict "$configmaps" ${pairs[@]+"${pairs[@]}"}
  done <<'TABLE'
PASS yes no,no,no,no,no,no
PASS yes no_-_RBAC:_denied,no,no,no,no,no
FAIL yes yes,no,no,no,no,no
FAIL yes no,no,no,no,no,yes
FAIL yes yes,-,-,-,-,-
BLOCKED yes no,no,-,no,no,no
BLOCKED yes -,-,-,-,-,-
BLOCKED yes Unable_to_connect,no,no,no,no,no
BLOCKED yes none
FAIL no none
FAIL no_-_RBAC none
BLOCKED - none
TABLE
  while read -r want code body; do
    [[ "$code" != - ]] || code=""
    [[ "$body" != - ]] || body=""
    check_verdict "$want" grafana_health_verdict "$code" "${body//_/ }"
  done <<'TABLE'
PASS 200 {"database":"ok"}
PASS 200 {_"database":_"ok"_}
FAIL 200 {"commit":"6f8ce3c","database":"ok","version":"13.3.0"}
FAIL 200 {"database":"ok","version":"13.3.0"}
FAIL 503 {"database":"failing"}
BLOCKED 000 -
BLOCKED - -
TABLE
  # The status, then helmet or none. A dash is nothing.
  while read -r want code who; do
    [[ "$code" != - ]] || code=""
    check_verdict "$want" infisical_reached_verdict "$code" "$who"
  done <<'TABLE'
PASS 401 helmet
FAIL 404 none
FAIL 200 helmet
FAIL 401 none
BLOCKED 000 none
BLOCKED - none
TABLE
  while read -r want reached answer; do
    check_verdict "$want" infisical_refusal_verdict "$reached" "${answer//_/ }"
  done <<'TABLE'
PASS PASS refused
FAIL PASS HTTP/2_401
BLOCKED PASS no_answer
BLOCKED FAIL refused
BLOCKED BLOCKED refused
BLOCKED FAIL HTTP/2_401
TABLE
  # The burst, the limit a minute, the status Infisical gives the call, the milliseconds the tries took, the longest pause between two, then
  # the answers, where 30x401/helmet is thirty of those. Dashes for the two times are a run that printed nothing.
  while read -r want burst per_minute status took pause answers; do
    expanded=()
    for answer in $answers; do
      if [[ "$answer" == [0-9]*x* ]]; then
        count="${answer%%x*}"
        while [[ "$count" -gt 0 ]]; do
          expanded+=("${answer#*x}")
          count=$((count - 1))
        done
      else
        expanded+=("$answer")
      fi
    done
    if [[ "$took" == - ]]; then
      check_verdict "$want" infisical_limit_verdict "$burst" "$per_minute" "$status"
    else
      check_verdict "$want" infisical_limit_verdict "$burst" "$per_minute" "$status" "$took" "$pause" ${expanded[@]+"${expanded[@]}"}
    fi
  done <<'TABLE'
PASS 30 30 401 9000 400 30x401/helmet 429/none
PASS 30 30 401 9000 2900 34x401/helmet 429/none
PASS 30 30 401 29000 900 44x401/helmet 429/none
PASS 10 10 400 3000 400 10x400/helmet 429/none
PASS 10 10 400 12000 1300 12x400/helmet 429/none
FAIL 30 30 401 9000 400 35x401/helmet 429/none
FAIL 30 30 401 12000 400 44x401/helmet 429/none
FAIL 10 10 400 3000 400 11x400/helmet 429/none
FAIL 30 30 401 9000 400 5x401/helmet 429/none
FAIL 30 30 401 300 0 429/none
FAIL 30 30 401 9000 3500 5x401/helmet 429/none
FAIL 30 30 401 9000 400 30x401/helmet 429/helmet
FAIL 30 30 401 9000 400 29x401/helmet 401/none 429/none
FAIL 10 10 400 3000 400 3x401/helmet 429/none
FAIL 30 30 401 9000 400 404/none
FAIL 30 30 401 12000 400 60x401/helmet
BLOCKED 30 30 401 100000 1700 60x401/helmet
BLOCKED 30 30 401 9000 3000 34x401/helmet 429/none
BLOCKED 10 10 400 9000 7000 10x400/helmet 429/none
BLOCKED 30 30 401 9000 400 12x401/helmet 000/none
BLOCKED 30 30 401 0 0 000/none
BLOCKED 30 30 401 x 0 401/helmet
BLOCKED 30 30 401 - -
TABLE
  # limit_tries itself, against a stand-in on this machine for Traefik in front of Infisical: TLS, and a bucket of 30 that refills one every 2 s,
  # as route.yaml's session limit, answering 401 with helmet's header until it is empty and 429 without it after. The run must read PASS, end at
  # the first 429, and keep to one connection, because a connection for each try is what let the bucket refill as fast as the tries emptied it.
  limit_tries_problem() ( # prints what is wrong, or nothing
    folder="$(mktemp -d)"
    pid=""
    # The wait as well, and its notice thrown away, because bash reports a job that a signal ended.
    trap '[[ -z "$pid" ]] || { kill "$pid" && wait "$pid"; } 2>/dev/null; rm -rf "$folder"' EXIT
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout "$folder/key.pem" -out "$folder/cert.pem" >/dev/null 2>&1 || {
      printf 'openssl could not make a certificate for the stand-in'
      exit 0
    }
    python3 -I -c '
import http.server, os, ssl, sys, threading, time
folder, burst, per_minute = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rate = per_minute / 60
lock = threading.Lock()
bucket = {"tokens": float(burst), "last": time.monotonic()}

def note(line):
    with lock, open(os.path.join(folder, "log"), "a") as log:
        log.write(line + "\n")

# Traefik serves a try that has to wait half a second or less for its token, as golang.org/x/time/rate reserves it, and refuses the rest.
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        note("connection")

    def answer(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        note("request")
        with lock:
            now = time.monotonic()
            bucket["tokens"] = min(burst, bucket["tokens"] + (now - bucket["last"]) * rate)
            bucket["last"] = now
            served = bucket["tokens"] >= 1 - rate / 2
            if served:
                bucket["tokens"] -= 1
        body = b"{}" if served else b"Too Many Requests"
        self.send_response(401 if served else 429)
        if served:
            self.send_header("X-Download-Options", "noopen")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = answer

    def log_message(self, *arguments):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(os.path.join(folder, "cert.pem"), os.path.join(folder, "key.pem"))
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(os.path.join(folder, "port.new"), "w") as out:
    out.write(str(server.server_address[1]))
os.replace(os.path.join(folder, "port.new"), os.path.join(folder, "port"))
server.serve_forever()
' "$folder" 30 30 >"$folder/out" 2>&1 &
    pid=$!
    waited=0
    while [[ ! -s "$folder/port" && "$waited" -lt 100 ]]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    [[ -s "$folder/port" ]] || {
      printf 'the stand-in did not start: %s' "$(head -c 300 "$folder/out")"
      exit 0
    }
    tries="$(limit_tries 127.0.0.1 "$(cat "$folder/port")" localhost GET /api/v2/auth/mfa/check/totp 60 || true)"
    # shellcheck disable=SC2086  # the two times and each answer are arguments of their own
    got="$(infisical_limit_verdict 30 30 401 $tries)"
    connections="$(grep -c '^connection$' "$folder/log" || true)"
    requests="$(grep -c '^request$' "$folder/log" || true)"
    # After the first 429 the stand-in answers 429 again, so a run that went on would still end in one: it is the count of them that tells.
    limited="$(tr ' ' '\n' <<<"$tries" | grep -c '^429/' || true)"
    if [[ "${got%%|*}" != PASS ]]; then
      printf 'it read %s, from %s' "$got" "$tries"
    elif [[ "$connections" != 1 ]]; then
      printf 'it made %s connections for %s tries, where the point is one' "$connections" "$requests"
    elif [[ "$limited" != 1 || "$tries" != *" 429/none" || "$requests" -ne $(($(wc -w <<<"$tries") - 2)) ]]; then
      printf 'it did not end at the first 429: the stand-in saw %s tries, and it read %s' "$requests" "$tries"
    fi
  )
  problem="$(limit_tries_problem)"
  if [[ -n "$problem" ]]; then
    printf 'FAIL limit_tries against a stand-in for Traefik: %s\n' "$problem"
    failures=$((failures + 1))
  fi
  while read -r want mine code who; do
    [[ "$code" != - ]] || code=""
    check_verdict "$want" infisical_other_client_verdict "$mine" "$code" "$who"
  done <<'TABLE'
PASS 429 400 helmet
FAIL 429 429 none
FAIL 429 429 helmet
BLOCKED 429 404 none
BLOCKED 429 - none
BLOCKED 400 400 helmet
BLOCKED 000 400 helmet
TABLE
  if [[ "$failures" -ne 0 ]]; then
    printf 'fail selftest: %s failed\n' "$failures" >&2
    exit 1
  fi
  printf ' ok selftest passed\n'
  exit 0
fi

HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-infisical-claim.sh
source "$(dirname "$0")/lib-infisical-claim.sh"
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

verdict_row() { row "${2%%|*}" "$1" "${2#*|}"; } # what verdict|detail

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

# Every console's name under the two zones, except the two public hosts, Grafana's and Infisical's. grafana and infisical under Wayline's
# domain stay in the list, because each of those routes is one host and this is any other.
PARENT_DOMAIN="${HOSTED_GRAFANA_DOMAIN#*.}"
ADMIN_HOSTS="argocd.$HOSTED_DOMAIN grafana.$HOSTED_DOMAIN prometheus.$HOSTED_DOMAIN alertmanager.$HOSTED_DOMAIN infisical.$HOSTED_DOMAIN argocd.$PARENT_DOMAIN prometheus.$PARENT_DOMAIN alertmanager.$PARENT_DOMAIN"

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

# One of the two consoles on the internet: its login page answers, its login is all that opens it, and the rest of it stays shut. -k,
# because the certificate has its own row above and a staging one is enough to ask these.
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

  page="$("${ask[@]}" -w '\n%{http_code}' "$url/api/health" 2>/dev/null || true)"
  verdict_row "Grafana's /api/health names no version" "$(grafana_health_verdict "${page##*$'\n'}" "${page%$'\n'*}")"

  # Traefik's own 404, from no route. Grafana answers any path it does not know by sending it to the login page.
  code="$("${ask[@]}" -o /dev/null -w '%{http_code}' "$url/metrics" 2>/dev/null || true)"
  case "$code" in
    404) row PASS "Grafana's /metrics is not public" "$code" ;;
    000 | "") row BLOCKED "Grafana's /metrics is not public" "no answer" ;;
    *) row FAIL "Grafana's /metrics is not public" "$code" ;;
  esac

  # By the form, and ahead of the limit below, which spends this machine's tries. Both values reach curl on stdin, so neither reaches a process
  # list, and only the status reaches this run's evidence.
  if [[ -s "$LOCAL_DIR/grafana-admin-user" && -s "$LOCAL_DIR/grafana-admin-password" ]]; then
    local form basic=""
    form="$(jq -n --rawfile user "$LOCAL_DIR/grafana-admin-user" --rawfile password "$LOCAL_DIR/grafana-admin-password" '{$user, $password}' |
      "${ask[@]}" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$url/login" 2>/dev/null || true)"
    verdict_row "the login held here opens Grafana" "$(grafana_form_verdict "$form")"
    # Only once the form has taken the same login, in this run. After anything else a 401 here would prove nothing, and with basic auth on
    # a wrong password here would be one more failure for this address.
    if [[ "$form" == 200 ]]; then
      basic="$(printf 'user = "%s:%s"\n' "$(cat "$LOCAL_DIR/grafana-admin-user")" "$(cat "$LOCAL_DIR/grafana-admin-password")" |
        "${ask[@]}" -K - -o /dev/null -w '%{http_code}' "$url/api/org" 2>/dev/null || true)"
    fi
    verdict_row "Grafana refuses basic auth, even with the right login" "$(grafana_basic_auth_verdict "$form" "$basic")"
  else
    row BLOCKED "the login held here opens Grafana" "no login in .local/hosted/plane-prod. Run: make remote-grafana-admin TARGET=plane-prod CONFIRM=plane-prod VERB=apply"
  fi

  # An empty form, which Grafana answers with 400 and does not count as a failed login, so this run leaves its count alone. A new X-Forwarded-For
  # with each try, which the limit must not read.
  local answers=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    code="$("${ask[@]}" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "X-Forwarded-For: 203.0.113.$attempt" \
      --data-binary '{}' "$url/login" 2>/dev/null || true)"
    answers="$answers $code"
    [[ "$code" != 429 ]] || break
  done
  case "$code" in
    429) row PASS "guessing at Grafana's login hits a limit per client" "answers:$answers" ;;
    000 | "") row BLOCKED "guessing at Grafana's login hits a limit per client" "no answer" ;;
    *) row FAIL "guessing at Grafana's login hits a limit per client" "answers:$answers" ;;
  esac

  # "Per client", here and in Grafana's count of failed logins, rests on Traefik seeing each client's own address, which hostPort's portmap should
  # leave alone and nothing above shows. These tries are what it logged last, so what it read for them is this machine's address, as Traefik saw it.
  if cluster_or_blocked "Traefik sees a client's own address"; then
    local seen
    seen="$(kc -n traefik logs deploy/traefik --tail=500 2>/dev/null |
      jq -Rr --arg host "$host" 'fromjson? | select(.RequestHost == $host and .RequestPath == "/login" and .RequestMethod == "POST") | .ClientHost' |
      LC_ALL=C sort -u | tr '\n' ' ' || true)"
    if [[ -z "${seen// /}" ]]; then
      row BLOCKED "Traefik sees a client's own address" "its log shows none of those tries"
    elif [[ "$seen" =~ (^|\ )(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
      row FAIL "Traefik sees a client's own address" "it read $seen, so every client shares one count, at the login's limit and at Grafana's five failures"
    else
      row PASS "Traefik sees a client's own address" "$seen"
    fi
  fi
}

# Traefik's own refusal: its 404 page, with none of the headers Infisical puts on everything it sends.
traefik_refused() { # method path [header]
  local answer
  local -a extra=()
  [[ -z "${3:-}" ]] || extra=(-H "$3")
  answer="$("${INFISICAL_ASK[@]}" -X "$1" -D - -o - -H 'Content-Type: application/json' ${extra[@]+"${extra[@]}"} --data-binary '{}' \
    "https://$HOSTED_INFISICAL_DOMAIN$2" 2>/dev/null || true)"
  if [[ -z "$answer" ]]; then
    printf 'no answer'
  elif [[ "$answer" == *"404 page not found"* && "$answer" != *[Xx]-[Dd]ownload-[Oo]ptions* ]]; then
    printf 'refused'
  else
    printf '%s' "$(head -1 <<<"$answer" | tr -d '\r')"
  fi
}

# Who answered a call: its status, and helmet when it was Infisical, because helmet puts X-Download-Options on all it sends.
infisical_answer() { # method path [header]
  local headers code
  local -a extra=()
  [[ -z "${3:-}" ]] || extra=(-H "$3")
  headers="$("${INFISICAL_ASK[@]}" -X "$1" -D - -o /dev/null ${extra[@]+"${extra[@]}"} "https://$HOSTED_INFISICAL_DOMAIN$2" 2>/dev/null || true)"
  code="$(head -1 <<<"$headers" | awk '{print $2}')"
  if [[ "$headers" == *[Xx]-[Dd]ownload-[Oo]ptions* ]]; then printf '%s helmet' "${code:-000}"; else printf '%s none' "${code:-000}"; fi
}

# The other console on the internet, and the secret store: its sign-in page answers, it reads claimed and closed to sign-up, what it refuses
# is refused by Traefik before it gets there, and guessing at its sign-in meets a limit that is this address's own. Every try here is a
# made-up address and password, so no real credential is spent and the admin's own count of failures does not move.
infisical_public() {
  local host="$HOSTED_INFISICAL_DOMAIN" url code page verdict method path got reached=FAIL bare=FAIL page_ok=FAIL
  url="https://$host"
  INFISICAL_ASK=(curl -k -sS --path-as-is --max-time 15 --resolve "$host:443:$HOSTED_HOST")

  page="$("${INFISICAL_ASK[@]}" -w '\n%{http_code}' "$url/login" 2>/dev/null || true)"
  code="${page##*$'\n'}"
  if [[ "$code" == 000 || -z "$code" ]]; then
    row BLOCKED "Infisical's sign-in page answers" "no answer"
  elif [[ "$code" == 200 && "$page" == *'<title id="initial-document-title">Infisical</title>'* ]]; then
    row PASS "Infisical's sign-in page answers" "$code"
    page_ok=PASS
  else
    row FAIL "Infisical's sign-in page answers" "$code, and not Infisical's page"
  fi

  verdict="$("${INFISICAL_ASK[@]}" "$url/api/v1/admin/config" 2>/dev/null | infisical_claim_verdict)"
  case "$verdict" in
    claimed) row PASS "Infisical has its admin and is closed to sign-up" ;;
    unreadable) row BLOCKED "Infisical has its admin and is closed to sign-up" "its config did not answer" ;;
    *) row FAIL "Infisical has its admin and is closed to sign-up" "it reads $verdict: scripts/hosted/README.md, section Infisical reads open" ;;
  esac

  # Reaches Infisical, which wants a session: the route passes what a browser asks, and Infisical's own login stands behind it. The rows of
  # Traefik's 404 below count only with this and the page above, because with no route at all they would read the same.
  # shellcheck disable=SC2046  # the status and who answered are two words
  got="$(infisical_reached_verdict $(infisical_answer GET '/api/v4/secrets?projectId=x&environment=prod'))"
  verdict_row "an anonymous read of Infisical's secrets is refused by Infisical" "$got"
  [[ "$page_ok" == PASS && "${got%%|*}" == PASS ]] && reached=PASS

  # A few of each kind the route refuses, by name and by another spelling, each of which Traefik itself refuses. An encoded slash is not one
  # of those: Traefik passes it on encoded, and Fastify's router finds no route for it. tests/routes/infisical-public-route.sh asks every one,
  # in every spelling, against the pinned Traefik, and with Infisical behind it.
  while read -r method path; do
    verdict_row "Traefik refuses $method $path" "$(infisical_refusal_verdict "$reached" "$(traefik_refused "$method" "$path")")"
  done <<'PATHS'
POST /api/v1/auth/universal-auth/login
POST /api/v1/auth/kubernetes-auth/login
POST /api/v1/auth/token/renew
GET /api/v1/identities/details
POST /api/v2/gateways
GET /api/v2/service-token
POST /api/v1/admin/bootstrap
POST /api/v1/admin/signup
POST /api/v3/signup/email/signup
POST /api/v1/account-recovery/send-email
POST /api/v1/shared-secrets/public
GET /api/docs
GET /api/docs/json
GET /api/v1/scim/Users
GET /api/v3/secrets/raw
GET /signup
GET /admin/signup
POST /api/v1/auth/universal-auth/login/
POST //api/v1/admin/bootstrap
GET /API/docs
GET /%61pi/docs
POST /api/v1/organization/../admin/bootstrap
GET /assets/../api/v1/scim/Users
PATHS

  # A machine's credential is refused on the calls a browser makes too. These are its shape and not a credential: a token whose payload
  # begins as a machine identity's does, a service token's prefix, and an API key's header. None is signed, and Traefik reads only the header.
  # The token is made here, so no token-shaped string sits in the repository for a secret scanner to flag. The same call with no header
  # comes first, and must reach Infisical, so that a 404 with the header is the header's doing.
  local kind header token
  # shellcheck disable=SC2046  # the status and who answered are two words
  got="$(infisical_reached_verdict $(infisical_answer GET /api/v1/organization))"
  verdict_row "GET /api/v1/organization with no credential reaches Infisical, which refuses it" "$got"
  bare="${got%%|*}"
  token="$(for part in '{"alg":"HS256","typ":"JWT"}' '{"identityId":"00000000-0000-4000-8000-000000000000"}' 'not-signed'; do
    printf '%s' "$part" | openssl base64 -A | tr '+/' '-_' | tr -d '='
    printf '.'
  done)"
  while IFS='|' read -r kind header; do
    verdict_row "Traefik refuses $kind on a browser's call" "$(infisical_refusal_verdict "$bare" "$(traefik_refused GET /api/v1/organization "$header")")"
  done <<HEADERS
a machine identity's token|Authorization: Bearer ${token%.}
a service token|Authorization: Bearer st.00000000-0000-4000-8000-000000000000.not-a-token
an API key|X-Api-Key: not-a-key
HEADERS

  # Guesses at the sign-in, under the limit route.yaml gives it, 10 a minute with a burst of 10: a made-up account, which Infisical answers
  # 400. A new X-Forwarded-For with each try shows the limit holds whatever the header says, and not whose count it is: the row after it asks that.
  local tries
  tries="$(limit_tries "$HOSTED_HOST" 443 "$host" POST /api/v3/auth/login 20 '{"email":"test-hosted-rate-limit@invalid.example","password":"not-a-password"}' 2>/dev/null || true)"
  # shellcheck disable=SC2086  # the two times and each answer are arguments of their own
  verdict_row "guessing at Infisical's sign-in meets its limit, whatever X-Forwarded-For says" "$(infisical_limit_verdict 10 10 400 $tries)"
  # This machine's last answer, for the row after it.
  code="${tries##* }"
  code="${code%%/*}"

  # Per client: once this machine has met the limit, one try from another address must still reach Infisical. The api's pod is that address,
  # through the CoreDNS rewrite to Traefik's Service, as in the routes section. Code passed as an argument and carrying nothing secret.
  if cluster_or_blocked "another address is not under this machine's limit"; then
    local other
    if ! kc -n plane-prod get deployment plane-api-wl >/dev/null 2>&1; then
      row BLOCKED "another address is not under this machine's limit" "Plane is not deployed, so its api pod cannot ask"
    else
      other="$(kc -n plane-prod exec deploy/plane-api-wl -c plane-api -- python -c "
import http.client, ssl
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
connection = http.client.HTTPSConnection('$host', 443, context=context, timeout=10)
connection.request('POST', '/api/v3/auth/login', body='{\"email\":\"test-hosted-rate-limit@invalid.example\",\"password\":\"not-a-password\"}', headers={'Content-Type': 'application/json', 'User-Agent': 'test-hosted'})
response = connection.getresponse()
print('ANSWER', response.status, 'helmet' if response.getheader('X-Download-Options') else 'none')
" 2>/dev/null | grep '^ANSWER' || true)"
      other="${other#ANSWER }"
      # shellcheck disable=SC2086  # the status and who answered are two words
      verdict_row "another address is not under this machine's limit" "$(infisical_other_client_verdict "$code" ${other:-000 none})"
    fi
  fi

  # The session part's own limit, which route.yaml gives as 30 a minute with a burst of 30: a token refresh with no refresh cookie, which
  # Infisical answers 404 AuthTokenNotFound before any account is read, until Traefik answers 429. The infisical-session Probe asks the same.
  # Not the two-factor checks beside it under the same router: v0.167.6's MFA router answers a call with no token from its own hook, in a body
  # its route's 401 schema refuses, so the server answers 500 and logs a ResponseValidationError for every try.
  tries="$(limit_tries "$HOSTED_HOST" 443 "$host" POST /api/v1/auth/token 60 2>/dev/null || true)"
  # shellcheck disable=SC2086  # the two times and each answer are arguments of their own
  verdict_row "the session part meets its wider limit, after its burst of 30" "$(infisical_limit_verdict 30 30 404 $tries)"
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

  # Frameflow's host passes these two before Frameflow is deployed, because Terraform owns its record and port 80 redirects every host.
  # Its certificate comes with Frameflow's first release, and until then its row below fails.
  local host
  for host in "$HOSTED_DOMAIN" "$HOSTED_GRAFANA_DOMAIN" "$HOSTED_INFISICAL_DOMAIN" "$HOSTED_RILLMARK_DOMAIN" "$HOSTED_CLOUDGARDEN_DOMAIN" "$HOSTED_FRAMEFLOW_DOMAIN"; do resolves_to_the_node "$host"; done

  if [[ " $open " != *" 80 "* ]]; then
    row BLOCKED "http redirects to https" "port 80 is closed. Move the firewall on: scripts/hosted/edge.sh"
  else
    for host in "$HOSTED_DOMAIN" "$HOSTED_GRAFANA_DOMAIN" "$HOSTED_INFISICAL_DOMAIN" "$HOSTED_RILLMARK_DOMAIN" "$HOSTED_CLOUDGARDEN_DOMAIN" "$HOSTED_FRAMEFLOW_DOMAIN"; do redirects_to_https "$host"; done
  fi

  if [[ " $open " != *" 443 "* ]]; then
    row BLOCKED "the certificates and the routes" "port 443 is closed from here. Move the firewall on: scripts/hosted/edge.sh"
    return 0
  fi

  served_certificate "$HOSTED_DOMAIN" wayline-tls
  served_certificate "$HOSTED_GRAFANA_DOMAIN" grafana-tls
  served_certificate "$HOSTED_INFISICAL_DOMAIN" infisical-tls
  served_certificate "$HOSTED_RILLMARK_DOMAIN" rillmark-tls
  served_certificate "$HOSTED_CLOUDGARDEN_DOMAIN" devops-tls
  served_certificate "$HOSTED_FRAMEFLOW_DOMAIN" frameflow-tls
  grafana_public
  infisical_public

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

# A server-side dry run of a probe pod, so nothing is created, and admission still has to say yes. Prints what admission answers,
# warnings too. Each argument after the name is one more line of the pod's spec.
dry_run_pod() { # namespace name [spec line...]
  local namespace="$1" name="$2" line spec=""
  shift 2
  for line in "$@"; do spec+="  $line"$'\n'; done
  kc apply --dry-run=server -f - 2>&1 <<YAML || true
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $namespace
spec:
${spec}  automountServiceAccountToken: false
  containers:
    - name: probe
      image: docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 32Mi}}
YAML
}

# Every namespace warns and audits at restricted, whatever it enforces, so an answer that admits the pod can still name Pod Security and
# the very field, in a warning that it "would violate" it. Only a refusal says "violates". The quota is read after Pod Security, so a pod
# the quota refuses got past it.
psa_row() { # what answer reason: the row, from what admission answered, which must refuse for that reason
  local what="$1" answer="$2" reason="$3"
  if [[ "$answer" == *created* || "$answer" == *"exceeded quota"* ]]; then
    row FAIL "$what" "Pod Security let it through, on a dry run, so nothing was made"
  elif [[ "$answer" == *"violates PodSecurity"* && "$answer" == *"$reason"* ]]; then
    row PASS "$what" "admission said no"
  else
    row BLOCKED "$what" "$(tr '\n' ' ' <<<"$answer" | cut -c1-160)"
  fi
}

psa() {
  section "Pod Security"
  cluster_or_blocked "Pod Security" || return 0
  local namespace
  # Every app's namespace, frameflow's too, which answers before Frameflow is deployed: Pod Security refuses a pod before the quota
  # reads it, so a quota of no pods hides no weaker level.
  for namespace in plane-prod infisical monitoring rillmark awushi-cloudgarden frameflow; do
    psa_row "$namespace refuses hostNetwork" "$(dry_run_pod "$namespace" test-hosted-host-network 'hostNetwork: true')" hostNetwork
  done
  # baseline refuses hostNetwork too, so the rows above cannot tell it from restricted, which the apps' namespaces enforce. This pod sets
  # no securityContext at all, so it may escalate, keeps its capabilities and may run as root: baseline admits it, and restricted alone
  # refuses it.
  for namespace in rillmark awushi-cloudgarden frameflow; do
    psa_row "$namespace refuses what only baseline allows" "$(dry_run_pod "$namespace" test-hosted-baseline-only)" 'violates PodSecurity "restricted:'
  done
}

# ------ Secrets --------------------------------------------------------------------------------------------------------

secrets() {
  section "Rendered Secrets, and who can read them"
  cluster_or_blocked "Rendered Secrets" || return 0
  grafana_token
  infisical_token
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

# Grafana's is one of the two pods on the internet, and its token is what a bug in it would hold. That token reads the ConfigMaps its dashboard
# sidecar needs, and no Secret, in monitoring or through a binding for every namespace. The API server's RBAC, asked as that ServiceAccount.
# Each question is its own call, and the tunnel can drop between them, so grafana_token_verdict counts only a no as a no.
grafana_token() {
  local who=system:serviceaccount:monitoring:kps-grafana configmaps scope verb answer
  local -a answers=() where
  configmaps="$(kc -n monitoring auth can-i list configmaps --as="$who" 2>/dev/null || true)"
  if [[ "$configmaps" == yes ]]; then
    for scope in monitoring all; do
      where=(-n monitoring)
      [[ "$scope" == monitoring ]] || where=(--all-namespaces)
      for verb in get list watch; do
        # After the subcommand: kubectl 1.36 refuses a flag before "auth", so with --all-namespaces first this asked nothing at all.
        answer="$(kc auth can-i "$verb" secrets "${where[@]}" --as="$who" 2>/dev/null || true)"
        answers+=("$scope:$verb=$answer")
      done
    done
  fi
  verdict_row "Grafana's token reads ConfigMaps and no Secret" "$(grafana_token_verdict "$configmaps" ${answers[@]+"${answers[@]}"})"
}

# Infisical's is the other, and holds no Kubernetes token at all: its ServiceAccount turns the mount off, because Kubernetes Auth reviews each
# login with the client's own token. A bug in it reaches every secret anyway, which docs/adr/0017-infisical-public-route.md says, and this
# shows it reaches nothing more. Read from the running pods, so a chart that mounted one regardless would show here.
infisical_token() {
  local what="Infisical's pod holds no Kubernetes token" pods mounted
  pods="$(kc -n infisical get pods -l app=infisical-standalone,component=infisical -o json 2>/dev/null || true)"
  if [[ -z "$pods" || "$(jq '.items | length' <<<"$pods" 2>/dev/null || echo 0)" == 0 ]]; then
    row BLOCKED "$what" "no pod of Infisical's server answered"
    return 0
  fi
  mounted="$(jq -r '[.items[] | select([.spec.volumes[]?.projected.sources[]?.serviceAccountToken] | length > 0) | .metadata.name] | join(" ")' <<<"$pods")"
  if [[ -n "$mounted" ]]; then row FAIL "$what" "mounted in: $mounted"; else row PASS "$what" "no token volume in $(jq '.items | length' <<<"$pods") pod(s)"; fi
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
