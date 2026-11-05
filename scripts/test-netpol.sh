#!/usr/bin/env bash
# Execute tests/network-policy-matrix.yaml against the running cluster.
#
#   scripts/test-netpol.sh
#   FROM_NS=plane-dev scripts/test-netpol.sh       only rows starting in one namespace
#   MATRIX=<file> scripts/test-netpol.sh           another matrix, to try a verdict on a target of your own
#   scripts/test-netpol.sh --selftest              the verdict table, with no cluster
#
# kindnet fails open and silently: when its setup breaks it logs one line and lets everything
# through. So nothing here is believed until a sentinel has shown, in a throwaway namespace, that a
# policy really blocks and that this script can tell a block from every other failure.
#
# Rows sharing a source run in one short-lived pod, each as its own new connection. kindnet evaluates
# only the first packet of a new connection, and that is what NetworkPolicy semantics depend on.
# One pod per row would take about an hour for this matrix (estimate).
#
# Verdicts:
#   allow  passes on a completed connection or on connection refused: the packet arrived.
#   deny   passes ONLY on a timeout. Refused means the packet arrived, so that is a failure.
#   INCONCLUSIVE is never a pass. It says the row could not prove anything, and why.
#
# A timeout alone cannot tell a policy from a target that is down or a probe pod with no network. So each probe pod
# has two references at the same moment, kept in the note column:
#   the node    dials each target as root, with a bare connect, in the moment before the pod starts and again after it
#               ends. kindnet's postrouting chain accepts root sockets ahead of its policy queue, so no policy governs
#               this, and an answer shows the target was up and listening. A target that does not answer leaves its row
#               INCONCLUSIVE. A row that says it has no reference proves less, and says so. That means the node had no
#               address to dial. If the node was asked and the witness itself failed, the row reads NO_READING, which is
#               INCONCLUSIVE too, and the sentinel first shows the witness works and can tell silence from an answer.
#   the pod     looks up a cluster name first and last. A pod that cannot resolve anything has no working network, so
#               its timeouts prove nothing, including on a row that dials an address and so needs no lookup of its own.
# Neither can catch loss only on the path from this pod to that target, which reads the same as the policy under test.
# EndpointSlices, read before and after the rows, catch a Service with no ready endpoint: a timeout or a refusal
# there comes from the Service, not from a policy or a listener.
#
# Exit status, as in scripts/test.sh: 0 every row passed, 1 a row failed or the sentinel did, 2 nothing failed but a row
# was INCONCLUSIVE. Except that a target outside the cluster proves nothing offline, and must not make an offline run
# non-zero. Such a row still reads INCONCLUSIVE, and the summary counts it apart. It is free only while the node's own
# readings show the same lack of internet: if the node reached the name in either of its two readings, or could not be
# asked, the row counts.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SELFTEST=no
if [[ "${1:-}" == --selftest ]]; then
  SELFTEST=yes
elif [[ $# -gt 0 ]]; then
  die "usage: $0 [--selftest]. FROM_NS and MATRIX are read from the environment"
fi

if [[ "$SELFTEST" == no ]]; then
  guard_disk 1
  "$ROOT/scripts/install-tools.sh" yq kubectl >/dev/null
fi

MATRIX="${MATRIX:-$ROOT/tests/network-policy-matrix.yaml}"
[[ -f "$MATRIX" ]] || die "$MATRIX does not exist"

# curlimages/curl 8.17.0, 9.7 MiB compressed on arm64. curl's exit codes separate refused (7) from
# timeout (28) and DNS (6), where busybox nc and wget do not reliably. Verified by imagetools inspect.
CURL_IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
# Same digest as tests/gates/day1.sh, so its pull is already cached. Only for the sentinel's server.
SERVER_IMAGE="docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

CONNECT_TIMEOUT=4
WITNESS_TIMEOUT=3
PARALLEL_PODS="${PARALLEL_PODS:-4}"
# What every probe pod looks up. Every namespace may reach DNS, or no row anywhere means anything.
POD_REFERENCE_HOST="kube-dns.kube-system.svc.cluster.local"
# TEST-NET-1, RFC 5737: nothing is there, so the sentinel can show the node's witness does not answer yes to everything.
WITNESS_NOBODY="192.0.2.1"
RUN_ID="$(date -u +%H%M%S)"
SENTINEL_NS="netpol-sentinel-$RUN_ID"
PROBE_LABEL="plane-platform/netpol-probe"
WORK="$(mktemp -d)"
mkdir -p "$LOCAL_DIR/evidence-raw"
EVIDENCE="$LOCAL_DIR/evidence-raw/netpol-$(date -u +%Y%m%dT%H%M%SZ).tsv"

cleanup() {
  if [[ "$SELFTEST" == no ]]; then
    kc delete namespace "$SENTINEL_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete pod --all-namespaces -l "$PROBE_LABEL=$RUN_ID" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Runs inside the pod. Each line of PROBES is a new connection. http:// only because curl needs a
# scheme: once TCP connects, whatever the service answers, time_connect is above zero.
# The sleep gives kindnet's informer time to learn this pod's IP and labels before the first packet.
# shellcheck disable=SC2016  # expanded by the pod's shell, not this one
IN_POD_SCRIPT='sleep 3
n=0
{
  while read -r id host port; do
    [ -n "$id" ] || continue
    (
      out=$(curl -sS -o /dev/null --connect-timeout '"$CONNECT_TIMEOUT"' --max-time '"$((CONNECT_TIMEOUT + 2))"' -w "%{time_namelookup} %{time_connect} %{errormsg}" "http://$host:$port/" 2>/dev/null)
      code=$?
      echo "RESULT $id $code $out"
    ) &
    n=$((n + 1))
    if [ $((n % 6)) -eq 0 ]; then wait; fi
  done
  wait
} <<EOF
$PROBES
EOF
echo DONE'

# Runs on the node, as root. A bare connect, closed at once, so nothing is sent to a port that would log it, as Valkey
# does an HTTP request. Refused counts as an answer: the target's kernel said so, which a policy's drop never does.
# shellcheck disable=SC2016  # expanded by the node's shell, not this one
NODE_WITNESS='n=0
while read -r id address port; do
  (
    if out=$(timeout '"$WITNESS_TIMEOUT"' bash -c "exec 3<>/dev/tcp/$address/$port" 2>&1); then
      echo "$id ANSWERED"
    else
      case "$out" in
        *refused*) echo "$id ANSWERED" ;;
        *"not known"* | *"Temporary failure"* | *"No address"*) echo "$id UNRESOLVED" ;;
        *) echo "$id SILENT" ;;
      esac
    fi
  ) &
  n=$((n + 1))
  if [ $((n % 16)) -eq 0 ]; then wait; fi
done
wait'

# classify <curl exit code> <time_namelookup> <time_connect> <error message...>
# Prints CONNECTED, REFUSED, TIMEOUT, DNS or OTHER:<code>.
classify() {
  local code="$1" lookup="$2" connect="$3"; shift 3
  local message="$*"
  if awk -v t="${connect:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then echo CONNECTED; return; fi
  case "$code" in
    0) echo CONNECTED ;;
    6) echo DNS ;;
    7) echo REFUSED ;;
    28)
      # curl uses 28 for a resolver timeout too. That must never read as a policy block.
      if [[ "$message" == Resolving* ]] || ! awk -v t="${lookup:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then
        echo DNS
      else
        echo TIMEOUT
      fi
      ;;
    *) echo "OTHER:$code" ;;
  esac
}

# start_probe_pod <pod> <namespace> <labels as JSON> <probes, one per line>
# shellcheck disable=SC2001  # sed indents every line of a multi-line value, which ${var//} cannot do
start_probe_pod() {
  local pod="$1" namespace="$2" labels="$3" probes="$4"
  # The merged labels stay valid JSON, which is valid YAML. A readiness gate that nothing satisfies
  # keeps the pod out of every Service whose selector its labels happen to match, so a probe wearing
  # a real workload's labels can never be sent real traffic.
  kc create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $namespace
  labels: ${labels%\}},"$PROBE_LABEL":"$RUN_ID"}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: 300
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
        - name: PROBES
          value: |
$(sed 's/^/            /' <<<"$probes")
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 200m, memory: 64Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
YAML
}

# Wait for a probe pod and print its logs. Non-zero if it never ran to completion.
collect_probe_pod() {
  local pod="$1" namespace="$2"
  if ! kc -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=280s >/dev/null 2>&1; then
    warn "probe pod $namespace/$pod did not complete: $(kc -n "$namespace" get pod "$pod" -o jsonpath='{.status.phase} {.status.reason} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
    return 1
  fi
  kc -n "$namespace" logs "$pod"
}

# ask_witness <rows, as id address port> <where the readings go>: non-zero if the node could not be asked at all.
ask_witness() {
  docker exec -i "$NODE_CONTAINER" bash -c "$NODE_WITNESS" <"$1" >"$2" 2>"$2.err"
}

# --- Sentinel ------------------------------------------------------------------------------------

# probe_once <name> <labels JSON> <host> <port>: prints the class of one new connection.
probe_once() {
  local name="$1" labels="$2" host="$3" port="$4" pod="sentinel-$1-$RUN_ID" line code lookup connect message
  start_probe_pod "$pod" "$SENTINEL_NS" "$labels" "1 $host $port"
  line="$(collect_probe_pod "$pod" "$SENTINEL_NS" | grep '^RESULT ' | head -1)" || die "sentinel probe $name produced no result"
  [[ -n "$line" ]] || die "sentinel probe $name produced no result"
  read -r _ _ code lookup connect message <<<"$line"
  # shellcheck disable=SC2086  # the message is deliberately split back into words
  classify "$code" "$lookup" "$connect" $message
}

assert_class() { # assert_class <expected> <what> <name> <labels> <host> <port>
  local expected="$1" what="$2" got
  got="$(probe_once "$3" "$4" "$5" "$6")"
  if [[ "$got" != "$expected" ]]; then
    die "sentinel: $what: expected $expected, got $got. Nothing below this point can be trusted."
  fi
  ok "sentinel: $what -> $got"
}

# assert_witness <the server's Service address>: the node's reference, on known cases. Run under the policy that blocks
# a pod, because a witness that policy governed could not vouch for a target behind one.
assert_witness() {
  local rows="$WORK/witness-rows-sentinel" readings="$WORK/witness-sentinel" got
  printf 'open %s 8080\nclosed %s 8081\nnobody %s 443\n' "$1" "$1" "$WITNESS_NOBODY" >"$rows"
  ask_witness "$rows" "$readings" ||
    die "sentinel: the node's witness could not run, so every row would lose its reference: $(head -1 "$readings.err")"
  got="$(sort "$readings" | tr '\n' ' ')"
  if [[ "$got" != "closed ANSWERED nobody SILENT open ANSWERED " ]]; then
    die "sentinel: the node's witness read: $got. Want an open and a closed port to answer it and $WITNESS_NOBODY not to. Nothing below this point can be trusted."
  fi
  ok "sentinel: the node's witness -> a blocked server answers it on an open and a closed port, and $WITNESS_NOBODY does not"
}

run_sentinel() {
  log "Sentinel: is NetworkPolicy really enforced?"
  kc -n kube-system rollout status ds/kindnet --timeout=30s >/dev/null ||
    die "kindnet is not healthy, and it fails open"
  # grep reads to the end, not -q. With -q it stops at the first match, the writer dies of SIGPIPE, and
  # under pipefail the pipeline reads as no match. In a large log that would hide this very line.
  if kc -n kube-system logs ds/kindnet --tail=-1 2>/dev/null | grep 'skipping network policies' >/dev/null; then
    die "kindnet logged 'skipping network policies': it is failing open"
  fi
  # Informational. The table name was inferred from source, and the behaviour below is the real proof.
  if ! docker exec "$NODE_CONTAINER" nft list tables 2>/dev/null | grep 'kube-network-policies\|kindnet-network-policies' >/dev/null; then
    warn "no network policy table found by name in nftables on the node. Continuing, the behaviour test decides."
  fi

  # A throwaway namespace, so the positive control runs before any policy applies and nothing here
  # can touch a Plane environment. Deleted by the exit trap.
  kc create namespace "$SENTINEL_NS" >/dev/null
  kc label namespace "$SENTINEL_NS" plane-platform/purpose=netpol-sentinel pod-security.kubernetes.io/enforce=baseline >/dev/null
  kc -n "$SENTINEL_NS" create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels: {app: sentinel-server}
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: server
      image: $SERVER_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, 'mkdir -p /tmp/www && echo ok > /tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www']
      ports: [{containerPort: 8080}]
      readinessProbe:
        httpGet: {path: /, port: 8080}
        periodSeconds: 2
      livenessProbe:
        httpGet: {path: /, port: 8080}
        periodSeconds: 10
      resources:
        requests: {cpu: 10m, memory: 8Mi}
        limits: {cpu: 100m, memory: 32Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
---
apiVersion: v1
kind: Service
metadata:
  name: server
spec:
  selector: {app: sentinel-server}
  ports:
    - {name: open, port: 8080, targetPort: 8080}
    - {name: closed, port: 8081, targetPort: 8081}
YAML
  kc -n "$SENTINEL_NS" wait --for=condition=Ready pod/server --timeout=180s >/dev/null ||
    die "sentinel server never became Ready"
  local server="server.$SENTINEL_NS.svc.cluster.local"
  local client='{"role":"client"}'

  # Each class this script relies on has to come out right on a known case first.
  assert_class CONNECTED "no policy, open port" open "$client" "$server" 8080
  assert_class REFUSED "no policy, closed port" closed "$client" "$server" 8081
  assert_class DNS "name that does not exist" nxdomain "$client" "nonexistent.$SENTINEL_NS.svc.cluster.local" 8080

  kc -n "$SENTINEL_NS" apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-to-server
spec:
  podSelector: {matchLabels: {app: sentinel-server}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {role: allowed}}}]
      ports: [{port: 8080}]
YAML
  sleep 5
  assert_class TIMEOUT "default-deny blocks a new connection" blocked "$client" "$server" 8080
  assert_class CONNECTED "allow rule admits only the labelled client" allowed '{"role":"allowed"}' "$server" 8080
  local server_address
  server_address="$(kc -n "$SENTINEL_NS" get service server -o jsonpath='{.spec.clusterIP}')" ||
    die "sentinel: could not read the server's Service address"
  assert_witness "$server_address"
  kc delete namespace "$SENTINEL_NS" --wait=false >/dev/null
  ok "enforcement is on, and timeouts, refusals and DNS failures are told apart"
}

# --- Matrix --------------------------------------------------------------------------------------

load_cases() {
  # One line per row: index namespace labels host port protocol expect note...
  yq -r '.cases | to_entries | .[] |
    [(.key | tostring), .value.from.ns, (.value.from.labels | to_json(0)), .value.to.host,
     (.value.to.port | tostring), (.value.to.protocol // "tcp"), .value.expect, (.value.note // "")] | join(" ")' \
    "$MATRIX" >"$WORK/cases"
  if [[ -n "${FROM_NS:-}" ]]; then
    awk -v ns="$FROM_NS" '$2 == ns' "$WORK/cases" >"$WORK/cases.filtered"
    mv "$WORK/cases.filtered" "$WORK/cases"
  fi
  [[ -s "$WORK/cases" ]] || die "no matrix rows to run"
  # A malformed row would otherwise be skipped silently. Check every field before starting anything.
  local bad
  bad="$(awk '$7 != "allow" && $7 != "deny" || $5 !~ /^[0-9]+$/' "$WORK/cases")"
  [[ -z "$bad" ]] || die "malformed matrix rows: $bad"
}

# scope_of <host>: cluster for a Service name, outside for what is not this platform's and may not be there at all
# (a public name or address, or Docker Desktop's own host address), and local for the rest (the node, the Git remote,
# and the .localhost hosts, which CoreDNS rewrites to Traefik).
#
# A row to a .svc or .localhost name cannot pass yet. Only .cluster.local names get an address in witness_targets, and a name in
# ready_of, so the node is asked for a name it cannot resolve, and a deny row ends INCONCLUSIVE and counted on a healthy policy.
# That fails safe, and no row in the matrix has one: name a Service in full, as <name>.<namespace>.svc.cluster.local.
scope_of() {
  case "$1" in
    *.cluster.local | *.svc) echo cluster ;;
    *.localhost) echo local ;;
    192.168.65.*) echo outside ;;
    10.* | 127.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) echo local ;;
    *.*) echo outside ;;
    *) echo local ;;
  esac
}

# snapshot_services <before|after>: ready endpoints per Service name, and an address the node can dial for it.
# The node cannot resolve Service names. A headless Service has no address but its pods'.
snapshot_services() {
  local label="$1"
  kc get endpointslices --all-namespaces -o json >"$WORK/slices-$label.json" || return 1
  kc get services --all-namespaces -o json >"$WORK/services-$label.json" || return 1
  yq -p json -oy -r '.items[] | ((.endpoints // []) | map(select(.conditions.ready != false))) as $ready |
    [.metadata.namespace, .metadata.labels["kubernetes.io/service-name"], ($ready | length | tostring), ($ready[0].addresses[0] // "-")] | join(" ")' \
    "$WORK/slices-$label.json" >"$WORK/slices-$label" || return 1
  yq -p json -oy -r '.items[] | [.metadata.namespace, .metadata.name, .spec.clusterIP] | join(" ")' \
    "$WORK/services-$label.json" >"$WORK/services-$label" || return 1
  awk -v suffix=.svc.cluster.local '
    FILENAME ~ /slices-/ { ready[$1 " " $2] += $3; if ($4 != "-" && !(($1 " " $2) in first)) first[$1 " " $2] = $4; next }
    {
      key = $1 " " $2
      address = ($3 == "None" || $3 == "") ? ((key in first) ? first[key] : "-") : $3
      print $2 "." $1 suffix, ((key in ready) ? ready[key] : 0), address
    }' "$WORK/slices-$label" "$WORK/services-$label" >"$WORK/service-state-$label"
}

# Rows with something to dial, as index, address, port. A Service the node has no address for gets no reference.
witness_targets() {
  awk -v names="$WORK/service-state-before" '
    BEGIN { while ((getline line < names) > 0) { split(line, f, " "); address[f[1]] = f[3] } }
    $6 == "udp" { next }
    $4 ~ /\.cluster\.local$/ { if (($4 in address) && address[$4] != "-") print $1, address[$4], $5; next }
    { print $1, $4, $5 }' "$WORK/cases" >"$WORK/witness-targets"
}

witness_group() { # witness_group <group number> <namespace> <labels> <before|after>
  local rows="$WORK/witness-rows-$1"
  awk -v ns="$2" -v l="$3" -v targets="$WORK/witness-targets" '
    BEGIN { while ((getline line < targets) > 0) { split(line, f, " "); target[f[1]] = line } }
    $2 == ns && $3 == l && ($1 in target) { print target[$1] }' "$WORK/cases" >"$rows"
  if ! ask_witness "$rows" "$WORK/witness-$1-$4"; then
    warn "the node's witness could not run for group $1, $4 the probes, so its rows have no reading: $(head -1 "$WORK/witness-$1-$4.err")"
  fi
}

run_group() { # run_group <group number> <namespace> <labels>
  local number="$1" namespace="$2" labels="$3" pod="netpol-$RUN_ID-$1" probes
  probes="$(awk -v ns="$namespace" -v l="$labels" '$2 == ns && $3 == l { print $1, $4, $5 }' "$WORK/cases")"
  probes="R$number-first $POD_REFERENCE_HOST 53
$probes
R$number-last $POD_REFERENCE_HOST 53"
  if ! kc -n "$namespace" get namespace "$namespace" >/dev/null 2>&1; then
    warn "namespace $namespace does not exist"
    return 1
  fi
  witness_group "$number" "$namespace" "$labels" before
  start_probe_pod "$pod" "$namespace" "$labels" "$probes" || return 1
  collect_probe_pod "$pod" "$namespace" >"$WORK/group-$number.log" || return 1
  witness_group "$number" "$namespace" "$labels" after
  kc -n "$namespace" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
}

# witness_of <group number> <row index>: what the node saw of this row's target.
#   NONE        it was not asked, because it had no address to dial.
#   NO_READING  it was asked and a reading is missing, because the witness failed. That is not the same as not asked,
#               and it is not the same as a target that stayed silent, which on a row outside the cluster costs nothing.
#   ANSWERED    the target answered both before and after the probes, so it was up across them.
#   ANSWERED_ONCE  it answered one of those and not the other. So the node reached it, and it was not up across them.
#   otherwise   neither reading was an answer, and this is the first of them: SILENT or UNRESOLVED.
witness_of() {
  local asked before after
  asked="$(awk -v id="$2" '$1 == id { print $1; exit }' "$WORK/witness-rows-$1" 2>/dev/null || true)"
  if [[ -z "$asked" ]]; then
    echo NONE
    return
  fi
  before="$(awk -v id="$2" '$1 == id { print $2 }' "$WORK/witness-$1-before" 2>/dev/null || true)"
  after="$(awk -v id="$2" '$1 == id { print $2 }' "$WORK/witness-$1-after" 2>/dev/null || true)"
  if [[ -z "$before" || -z "$after" ]]; then echo NO_READING
  elif [[ "$before" == ANSWERED && "$after" == ANSWERED ]]; then echo ANSWERED
  elif [[ "$before" == ANSWERED || "$after" == ANSWERED ]]; then echo ANSWERED_ONCE
  else echo "$before"
  fi
}

# ready_of <host>: the fewest ready endpoints either snapshot saw, or - if this is not a Service that exists.
ready_of() {
  awk -v host="$1" '$1 == host { n = (seen == "" || $2 + 0 < n + 0) ? $2 : n; seen = 1 } END { print (seen ? n : "-") }' \
    "$WORK/service-state-before" "$WORK/service-state-after" 2>/dev/null || echo -
}

# reference_of <group number>: yes if the pod's own name lookups, first and last, both got an answer. Any class but DNS
# means the resolver answered, whatever then happened on port 53.
reference_of() {
  local which line code lookup connect message class answer=yes
  for which in first last; do
    line="$(grep "^RESULT R$1-$which " "$WORK/results" | head -1 || true)"
    [[ -n "$line" ]] || { answer=no; continue; }
    read -r _ _ code lookup connect message <<<"$line"
    # shellcheck disable=SC2086  # the message is deliberately split back into words
    class="$(classify "$code" "$lookup" "$connect" $message)"
    case "$class" in
      DNS | OTHER:*) answer=no ;;
    esac
  done
  echo "$answer"
}

# decide <expect> <class> <protocol> <scope> <ready endpoints or -> <witness> <pod reference yes|no>
# Prints verdict|counts or free|what the row shows. free means an INCONCLUSIVE that does not count against the run.
decide() {
  local expect="$1" class="$2" protocol="$3" scope="$4" ready="$5" witness="$6" reference="$7"
  if [[ "$protocol" == udp ]]; then
    # For a DNS row, reaching any answer at all from the resolver is the point: the name resolved,
    # and only the lookup needs to pass. Connecting to port 53 afterwards is not under test.
    if [[ "$class" == DNS ]]; then
      if [[ "$expect" == deny ]]; then echo "PASS|counts|"; else echo "FAIL|counts|"; fi
    else
      if [[ "$expect" == allow ]]; then echo "PASS|counts|"; else echo "FAIL|counts|"; fi
    fi
    return
  fi
  local no_endpoint="the Service had no ready endpoint, so this came from the Service and proves nothing about a policy"
  local outside="nothing outside the cluster answered the node at this moment, so this proves nothing. Not counted against the run"
  local down="the target did not answer the node either, so this proves nothing about a policy"
  local no_reading="the node's witness gave no reading for this target, so nothing shows it was up. That is this test failing, not the target"
  local once="the target answered the node in only one of its two readings, so it was not up across this attempt, and this proves nothing about a policy"
  case "$class" in
    NOT_RUN) echo "INCONCLUSIVE|counts|the probe gave no result" ;;
    OTHER:*) echo "FAIL|counts|curl failed in a way that says nothing about the path" ;;
    DNS)
      if [[ "$scope" == outside && ("$witness" == ANSWERED || "$witness" == ANSWERED_ONCE) ]]; then
        echo "INCONCLUSIVE|counts|the node reached this name in at least one of its two readings, so this run had internet DNS and this pod's lookup is what failed"
      elif [[ "$scope" == outside && ("$witness" == UNRESOLVED || "$witness" == SILENT) ]]; then
        echo "INCONCLUSIVE|free|this name needs internet DNS, which this run did not have, so this proves nothing. Not counted against the run"
      else
        echo "INCONCLUSIVE|counts|the lookup failed, so nothing was dialled"
      fi
      ;;
    CONNECTED) if [[ "$expect" == allow ]]; then echo "PASS|counts|"; else echo "FAIL|counts|a deny row connected"; fi ;;
    REFUSED)
      if [[ "$ready" == 0 ]]; then echo "INCONCLUSIVE|counts|$no_endpoint"
      elif [[ "$expect" == allow ]]; then echo "PASS|counts|"
      else echo "FAIL|counts|refused means the packet arrived"
      fi
      ;;
    TIMEOUT)
      if [[ "$ready" == 0 ]]; then echo "INCONCLUSIVE|counts|$no_endpoint"
      elif [[ "$reference" != yes ]]; then echo "INCONCLUSIVE|counts|this pod could not resolve a name at the same moment, so it may have had no network at all"
      elif [[ "$witness" == ANSWERED ]]; then
        if [[ "$expect" == deny ]]; then
          echo "PASS|counts|reference: the target answered the node and this pod's DNS answered, at the same moment"
        else
          echo "FAIL|counts|the target answered the node at the same moment, so the path to it is blocked"
        fi
      elif [[ "$witness" == NONE ]]; then
        if [[ "$expect" == deny ]]; then
          echo "PASS|counts|no reference for the target: a timeout alone, which does not show the target was up"
        else
          echo "FAIL|counts|no reference for the target, so this may be the target and not the path"
        fi
      elif [[ "$witness" == NO_READING ]]; then echo "INCONCLUSIVE|counts|$no_reading"
      elif [[ "$witness" == ANSWERED_ONCE ]]; then echo "INCONCLUSIVE|counts|$once"
      elif [[ "$scope" == outside ]]; then echo "INCONCLUSIVE|free|$outside"
      else echo "INCONCLUSIVE|counts|$down"
      fi
      ;;
    *) echo "FAIL|counts|unknown class $class" ;;
  esac
}

run_matrix() {
  load_cases
  awk '{ print $2, $3 }' "$WORK/cases" | sort -u >"$WORK/groups"
  log "Running $(wc -l <"$WORK/cases" | tr -d ' ') rows from $(wc -l <"$WORK/groups" | tr -d ' ') source identities"
  snapshot_services before || die "could not read the cluster's Services and EndpointSlices"
  witness_targets

  local number=0 namespace labels
  while read -r namespace labels; do
    number=$((number + 1))
    run_group "$number" "$namespace" "$labels" &
    # Bash 3.2 has no wait -n, so run in fixed batches. Few enough to respect the namespace quotas.
    if [[ $((number % PARALLEL_PODS)) -eq 0 ]]; then wait; fi
  done <"$WORK/groups"
  wait
  if ! snapshot_services after; then
    warn "could not read the Services again, so only the first reading of their endpoints counts"
    cp "$WORK/service-state-before" "$WORK/service-state-after"
  fi

  cat "$WORK"/group-*.log 2>/dev/null | grep '^RESULT ' >"$WORK/results" || true

  printf 'verdict\texpect\tobserved\tfrom\tlabels\tto\tport\tnote\n' >"$EVIDENCE"
  local passed=0 failed=0 inconclusive=0 free=0 unreferenced=0
  local index from from_labels host port protocol expect note line code lookup connect message class verdict counts shows
  local group_number decided
  while read -r index from from_labels host port protocol expect note; do
    line="$(grep "^RESULT $index " "$WORK/results" | head -1 || true)"
    if [[ -z "$line" ]]; then
      class=NOT_RUN
    else
      read -r _ _ code lookup connect message <<<"$line"
      # shellcheck disable=SC2086  # the message is deliberately split back into words
      class="$(classify "$code" "$lookup" "$connect" $message)"
    fi
    group_number="$(awk -v ns="$from" -v l="$from_labels" '$1 == ns && $2 == l { print NR; exit }' "$WORK/groups")"
    # Not inside the here-string: bash 3.2 expands that with IFS already set, and the functions would inherit it.
    decided="$(decide "$expect" "$class" "$protocol" "$(scope_of "$host")" "$(ready_of "$host")" \
      "$(witness_of "$group_number" "$index")" "$(reference_of "$group_number")")"
    IFS='|' read -r verdict counts shows <<<"$decided"
    case "$verdict" in
      PASS) passed=$((passed + 1)) ;;
      FAIL) failed=$((failed + 1)) ;;
      *) if [[ "$counts" == free ]]; then free=$((free + 1)); else inconclusive=$((inconclusive + 1)); fi ;;
    esac
    [[ "$verdict" != PASS || "$shows" != "no reference"* ]] || unreferenced=$((unreferenced + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$expect" "$class" "$from" "$from_labels" "$host" "$port" "$note${note:+${shows:+; }}$shows" >>"$EVIDENCE"
    printf '%-13s %-6s %-10s %s %s -> %s:%s%s\n' "$verdict" "$expect" "$class" "$from" "$from_labels" "$host" "$port" "${shows:+  # $shows}"
  done <"$WORK/cases"

  log "PASS $passed, FAIL $failed, INCONCLUSIVE $((inconclusive + free)), of which $free need something outside the cluster and do not count against the run. Deny rows that pass with no reference for the target: $unreferenced. Evidence: $EVIDENCE"
  if [[ "$unreferenced" -eq 0 ]]; then
    log "A deny PASS is a timeout while both references answered. It cannot rule out loss only on that pod's path to that target."
  else
    log "A deny PASS is a timeout. For $unreferenced of them nothing shows the target was up, as each says. The rest had both references, and none of them can rule out loss only on that pod's path to that target."
  fi
  if [[ "$failed" -ne 0 ]]; then return 1; fi
  if [[ "$inconclusive" -ne 0 ]]; then return 2; fi
  return 0
}

# Every verdict decide can give, on the case that should give it. Needs no cluster, so CI can run it.
selftest() {
  local failures=0 expect class scope ready witness reference want got asked before after
  # expect class scope ready witness reference wanted verdict and whether it counts
  while read -r expect class scope ready witness reference want; do
    got="$(decide "$expect" "$class" tcp "$scope" "$ready" "$witness" "$reference")"
    got="${got%%|*}|$(cut -d'|' -f2 <<<"$got")"
    if [[ "$got" != "$want" ]]; then
      printf 'FAIL decide %s %s %s ready=%s witness=%s reference=%s: got %s, want %s\n' "$expect" "$class" "$scope" "$ready" "$witness" "$reference" "$got" "$want"
      failures=$((failures + 1))
    fi
  done <<'TABLE'
deny TIMEOUT cluster 1 ANSWERED yes PASS|counts
deny TIMEOUT cluster 1 NONE yes PASS|counts
deny TIMEOUT cluster 1 SILENT yes INCONCLUSIVE|counts
deny TIMEOUT cluster 1 NO_READING yes INCONCLUSIVE|counts
deny TIMEOUT cluster 1 ANSWERED_ONCE yes INCONCLUSIVE|counts
deny TIMEOUT cluster 0 ANSWERED yes INCONCLUSIVE|counts
deny TIMEOUT cluster 1 ANSWERED no INCONCLUSIVE|counts
deny TIMEOUT outside - ANSWERED yes PASS|counts
deny TIMEOUT outside - SILENT yes INCONCLUSIVE|free
deny TIMEOUT outside - UNRESOLVED yes INCONCLUSIVE|free
deny TIMEOUT outside - NO_READING yes INCONCLUSIVE|counts
deny TIMEOUT outside - ANSWERED_ONCE yes INCONCLUSIVE|counts
deny DNS outside - UNRESOLVED yes INCONCLUSIVE|free
deny DNS outside - SILENT yes INCONCLUSIVE|free
deny DNS outside - ANSWERED yes INCONCLUSIVE|counts
deny DNS outside - ANSWERED_ONCE yes INCONCLUSIVE|counts
deny DNS outside - NO_READING yes INCONCLUSIVE|counts
deny DNS cluster - NONE yes INCONCLUSIVE|counts
deny CONNECTED cluster 1 ANSWERED yes FAIL|counts
deny REFUSED cluster 1 ANSWERED yes FAIL|counts
deny REFUSED cluster 0 ANSWERED yes INCONCLUSIVE|counts
allow CONNECTED cluster 1 ANSWERED yes PASS|counts
allow REFUSED cluster 1 ANSWERED yes PASS|counts
allow REFUSED cluster 0 ANSWERED yes INCONCLUSIVE|counts
allow TIMEOUT cluster 0 ANSWERED yes INCONCLUSIVE|counts
allow TIMEOUT cluster 1 ANSWERED yes FAIL|counts
allow TIMEOUT cluster 1 NONE yes FAIL|counts
allow TIMEOUT cluster 1 SILENT yes INCONCLUSIVE|counts
allow TIMEOUT cluster 1 NO_READING yes INCONCLUSIVE|counts
allow TIMEOUT outside - SILENT yes INCONCLUSIVE|free
allow TIMEOUT outside - ANSWERED_ONCE yes INCONCLUSIVE|counts
allow DNS outside - UNRESOLVED yes INCONCLUSIVE|free
allow DNS outside - ANSWERED yes INCONCLUSIVE|counts
allow DNS outside - ANSWERED_ONCE yes INCONCLUSIVE|counts
allow NOT_RUN cluster 1 NONE yes INCONCLUSIVE|counts
allow OTHER:35 cluster 1 ANSWERED yes FAIL|counts
TABLE
  readings() { # readings <whether the row was asked> <before> <after>. A dash is no reading.
    : >"$WORK/witness-rows-0"
    : >"$WORK/witness-0-before"
    : >"$WORK/witness-0-after"
    [[ "$1" == no ]] || echo "7 198.51.100.1 80" >"$WORK/witness-rows-0"
    [[ "$2" == - ]] || echo "7 $2" >"$WORK/witness-0-before"
    [[ "$3" == - ]] || echo "7 $3" >"$WORK/witness-0-after"
  }
  # wanted witness, whether the row was asked, and the readings before and after.
  while read -r want asked before after; do
    readings "$asked" "$before" "$after"
    got="$(witness_of 0 7)"
    if [[ "$got" != "$want" ]]; then
      printf 'FAIL witness_of asked=%s before=%s after=%s: got %s, want %s\n' "$asked" "$before" "$after" "$got" "$want"
      failures=$((failures + 1))
    fi
  done <<'TABLE'
NONE no - -
NO_READING yes - -
NO_READING yes ANSWERED -
NO_READING yes - ANSWERED
ANSWERED yes ANSWERED ANSWERED
ANSWERED_ONCE yes ANSWERED SILENT
ANSWERED_ONCE yes SILENT ANSWERED
ANSWERED_ONCE yes UNRESOLVED ANSWERED
ANSWERED_ONCE yes ANSWERED UNRESOLVED
SILENT yes SILENT SILENT
SILENT yes SILENT UNRESOLVED
UNRESOLVED yes UNRESOLVED SILENT
UNRESOLVED yes UNRESOLVED UNRESOLVED
TABLE
  # A failed lookup on an outside row, from the node's two readings to the verdict: free only if neither reached the name.
  while read -r before after want; do
    readings yes "$before" "$after"
    got="$(decide deny DNS tcp outside - "$(witness_of 0 7)" yes)"
    got="${got%%|*}|$(cut -d'|' -f2 <<<"$got")"
    if [[ "$got" != "$want" ]]; then
      printf 'FAIL a failed lookup with the node reading before=%s after=%s: got %s, want %s\n' "$before" "$after" "$got" "$want"
      failures=$((failures + 1))
    fi
  done <<'TABLE'
ANSWERED ANSWERED INCONCLUSIVE|counts
ANSWERED SILENT INCONCLUSIVE|counts
SILENT ANSWERED INCONCLUSIVE|counts
UNRESOLVED ANSWERED INCONCLUSIVE|counts
ANSWERED UNRESOLVED INCONCLUSIVE|counts
SILENT SILENT INCONCLUSIVE|free
UNRESOLVED UNRESOLVED INCONCLUSIVE|free
SILENT UNRESOLVED INCONCLUSIVE|free
UNRESOLVED SILENT INCONCLUSIVE|free
TABLE
  [[ "$(scope_of telemetry.plane.so)" == outside && "$(scope_of 1.1.1.1)" == outside && "$(scope_of 192.168.65.254)" == outside ]] || { echo "FAIL scope_of outside"; failures=$((failures + 1)); }
  [[ "$(scope_of plane-git)" == local && "$(scope_of 172.24.0.2)" == local && "$(scope_of 10.96.0.1)" == local && "$(scope_of plane.dev.localhost)" == local ]] || { echo "FAIL scope_of local"; failures=$((failures + 1)); }
  [[ "$(scope_of plane-api.plane-dev.svc.cluster.local)" == cluster && "$(scope_of kubernetes.default.svc)" == cluster ]] || { echo "FAIL scope_of cluster"; failures=$((failures + 1)); }
  [[ "$failures" -eq 0 ]] || die "selftest: $failures failed"
  ok "selftest passed"
}

if [[ "$SELFTEST" == yes ]]; then
  selftest
  exit 0
fi

run_sentinel
status=0
run_matrix || status=$?
case "$status" in
  0) ok "network policy matrix passed" ;;
  2)
    warn "nothing failed, but a row could not prove anything. That is not a pass."
    exit 2
    ;;
  *) die "network policy matrix did not pass" ;;
esac
