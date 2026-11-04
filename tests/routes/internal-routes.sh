#!/usr/bin/env bash
# Who can reach the internal UIs through Traefik. The Traefik NetworkPolicy has to let each Plane api
# in, for the CoreDNS self-dial, and Traefik routes by Host header, so without the middleware a
# compromised api could read every metric and silence alerts. These checks prove the middleware from
# both sides: the host still gets each UI, and a real pod the policy admits gets 403.
#
#   tests/routes/internal-routes.sh
#
# Exit status as in scripts/test.sh: 0 everything passed, 1 something failed, 2 nothing failed but
# something could not run. The pod side runs Python in the running api, GET only, so it needs both
# environments up, changes nothing, and prints statuses rather than response bodies.
#
# GAP rows state what this middleware does not close. They are not failures: a dev api can still reach
# plane.prod-sim.localhost, exactly as any browser could. The host.docker.internal row depends on
# NetworkPolicy alone: a scratch pod with no egress policy did read Prometheus that way, because it leaves
# through the Mac and comes back as the host. monitoring/README.md says more.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

guard_disk 2

FAILED=0
BLOCKED=0
row() { # verdict case expected got [detail]
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
  esac
  printf '%-8s %-66s expected=%-9s got=%-11s %s\n' "$1" "$2" "$3" "$4" "${5:-}"
}
finish() {
  printf 'SUMMARY failed=%s blocked=%s\n' "$FAILED" "$BLOCKED"
  if [[ "$FAILED" -gt 0 ]]; then exit 1; fi
  if [[ "$BLOCKED" -gt 0 ]]; then exit 2; fi
  exit 0
}

printf 'date: %s\ncommand: tests/routes/internal-routes.sh\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! kc get --raw /readyz >/dev/null 2>&1; then
  row BLOCKED "cluster reachable" yes no
  finish
fi

# Paths that answer without a login, so a 200 means the route and the backend both work.
for item in argocd.localhost/healthz grafana.localhost/api/health prometheus.localhost/-/ready \
  alertmanager.localhost/-/ready infisical.localhost/api/status; do
  status="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "http://$item" 2>/dev/null)" || status=000
  if [[ "$status" == 200 ]]; then
    row PASS "host: http://$item" 200 "$status"
  else
    row FAIL "host: http://$item" 200 "$status" "the allow list must admit the host"
  fi
done

NODE_IP="$(kc get node "$NODE_CONTAINER" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)" || NODE_IP=""
GATEWAY=""
gateways="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null)" || gateways=""
for address in $gateways; do
  case "$address" in *.*) GATEWAY="$address" ;; esac
done
if [[ -z "$NODE_IP" || -z "$GATEWAY" ]]; then
  row BLOCKED "node address and kind gateway known" yes "node=${NODE_IP:-none},gw=${GATEWAY:-none}"
  finish
fi
# The range in the Middlewares, and the one scripts/cluster-up.sh enforces. Both of these octets decide it.
first_two="${GATEWAY%.*.*}"
case "$first_two" in
  172.1[6-9] | 172.2[0-9] | 172.3[01]) row PASS "kind gateway is inside 172.16.0.0/12, so the host is admitted" yes "$GATEWAY" ;;
  *) row FAIL "kind gateway is inside 172.16.0.0/12, so the host is admitted" yes "$GATEWAY" ;;
esac

# Runs inside the api. Verdicts are decided here so each row can name what it dialled. Only 403 with
# Traefik's own body counts as the middleware, and an unanswered dial on the normal path proves nothing.
PROBE="$(
  cat <<'PY'
import http.client
import socket
import sys

own_host, other_host, node_ip, gateway = sys.argv[1:5]
SERVICE = ("traefik.traefik.svc.cluster.local", 80)
UIS = [
    ("argocd.localhost", "/api/version"),
    ("grafana.localhost", "/api/health"),
    ("prometheus.localhost", "/api/v1/query?query=up"),
    ("alertmanager.localhost", "/api/v2/silences"),
    ("infisical.localhost", "/api/status"),
]


def ask(dial, host, path, headers=None):
    conn = http.client.HTTPConnection(dial[0], dial[1], timeout=4)
    try:
        conn.request("GET", path, headers=dict({"Host": host}, **(headers or {})))
        response = conn.getresponse()
        return str(response.status), response.read(64).strip() == b"Forbidden"
    except socket.timeout:
        return "timeout", False
    except (OSError, http.client.HTTPException) as err:
        return type(err).__name__, False
    finally:
        conn.close()


def row(verdict, case, expected, got, detail=""):
    print("%-8s %-66s expected=%-9s got=%-11s %s" % (verdict, case, expected, got, detail))


def must_be_refused(case, dial, host, path, headers=None):
    status, forbidden = ask(dial, host, path, headers)
    if status == "403" and forbidden:
        row("PASS", case, "403", status)
    elif status.isdigit():
        row("FAIL", case, "403", status, "answered, and not by the allow list")
    else:
        row("BLOCKED", case, "403", status, "no answer, so this proves nothing")


status, _ = ask(SERVICE, own_host, "/api/instances/")
row("PASS" if status == "200" else "BLOCKED", "same moment, this pod reaches Traefik: " + own_host, "200", status)

for host, path in UIS:
    must_be_refused("pod via Service: " + host + path, SERVICE, host, path)

# ipAllowList reads the socket address when no ipStrategy is set, so these headers must change nothing.
for header, value in (("X-Forwarded-For", gateway), ("X-Real-Ip", gateway), ("Forwarded", "for=" + gateway)):
    for host, path in UIS[2:4]:
        must_be_refused("pod spoofs %s: %s" % (header, host), SERVICE, host, path, {header: value})

for spelling in ("PROMETHEUS.LOCALHOST", "prometheus.localhost:80", "prometheus.localhost."):
    status, forbidden = ask(SERVICE, spelling, UIS[2][1])
    refused = (status == "403" and forbidden) or status == "404"
    row("PASS" if refused else "FAIL", "pod respells the host: " + spelling, "403/404", status)

# Doors other than the Service. Being refused or never connecting both mean no data. A pod dialling the
# NodePort must not be rewritten to a node address, or it would pass the allow list as the host does.
for label, dial in (
    ("node NodePort %s:30080" % node_ip, (node_ip, 30080)),
    ("kind gateway %s:80" % gateway, (gateway, 80)),
    ("host.docker.internal:80", ("host.docker.internal", 80)),
    ("Docker Desktop host 192.168.65.254:80", ("192.168.65.254", 80)),
    ("name prometheus.localhost:80", ("prometheus.localhost", 80)),
):
    status, forbidden = ask(dial, "prometheus.localhost", UIS[2][1])
    admitted = status.isdigit() and status[0] in "23"
    row("FAIL" if admitted else "PASS", "pod via other door: " + label, "no data", status)

status, _ = ask(SERVICE, other_host, "/api/instances/")
row("GAP", "this pod reaches the other environment's public host: " + other_host, "unclosed", status, "as any browser could")
print("#END")
PY
)"

for env in dev prod-sim; do
  ns="plane-$env"
  own_host="plane.$env.localhost"
  if [[ "$env" == dev ]]; then other_host=plane.prod-sim.localhost; else other_host=plane.dev.localhost; fi

  # A hostNetwork pod would arrive from the node network and pass the allow list, so this is half the proof.
  host_network="$(kc -n "$ns" get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[*].spec.hostNetwork}' 2>/dev/null)" || host_network=unknown
  if [[ -z "$host_network" ]]; then
    row PASS "$ns: the api pods are not hostNetwork" none none
  else
    row FAIL "$ns: the api pods are not hostNetwork" none "$host_network"
  fi
  refusal="$(kc -n "$ns" apply --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: { name: internal-routes-hostnetwork-check }
spec:
  hostNetwork: true
  containers:
    - { name: c, image: "registry.invalid/none@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
YAML
)" && refused=no || refused=yes
  case "$refused:$refusal" in
    yes:*PodSecurity*) row PASS "$ns: admission refuses a hostNetwork pod (server dry run)" refused refused ;;
    *) row FAIL "$ns: admission refuses a hostNetwork pod (server dry run)" refused "$refused" "${refusal%%$'\n'*}" ;;
  esac

  status=0
  output="$(kc -n "$ns" exec deploy/plane-api-wl -c plane-api -- python -c "$PROBE" "$own_host" "$other_host" "$NODE_IP" "$GATEWAY" 2>&1)" || status=$?
  case "$output" in
    *"#END"*) ;;
    *)
      row BLOCKED "$ns: probe ran inside the api pod" yes "exit$status" "${output%%$'\n'*}"
      continue
      ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      PASS* | GAP*) printf '%s %s\n' "$ns" "$line" ;;
      FAIL*)
        FAILED=$((FAILED + 1))
        printf '%s %s\n' "$ns" "$line"
        ;;
      BLOCKED*)
        BLOCKED=$((BLOCKED + 1))
        printf '%s %s\n' "$ns" "$line"
        ;;
    esac
  done <<<"$output"

  # Operators read Infisical through its in-cluster Service, not this route. Each secret requeues every
  # minute, so a healthy operator has logged a real fetch inside this window, after the check began.
  logs="$(kc -n "$ns" logs -l app.kubernetes.io/name=secrets-operator --since=150s --tail=-1 2>&1)" || logs=""
  count="$(grep -c 'Reconciliation successful' <<<"$logs" || true)"
  bad="$(grep -c 'ERROR' <<<"$logs" || true)"
  if [[ "$count" -gt 0 && "$bad" -eq 0 ]]; then
    row PASS "$ns: operator reconciled in the last 150s, no error lines" ">0,0" "$count,$bad"
  else
    row FAIL "$ns: operator reconciled in the last 150s, no error lines" ">0,0" "$count,$bad"
  fi
done

finish
