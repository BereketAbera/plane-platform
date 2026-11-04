#!/usr/bin/env bash
# Execute tests/network-policy-matrix.yaml against the running cluster.
#
#   scripts/test-netpol.sh
#   FROM_NS=plane-dev scripts/test-netpol.sh       only rows starting in one namespace
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
#   A DNS failure is INCONCLUSIVE, never a pass. It fails the run as well.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

guard_disk 1
"$ROOT/scripts/install-tools.sh" yq kubectl >/dev/null

MATRIX="$ROOT/tests/network-policy-matrix.yaml"
[[ -f "$MATRIX" ]] || die "$MATRIX does not exist"

# curlimages/curl 8.17.0, 9.7 MiB compressed on arm64. curl's exit codes separate refused (7) from
# timeout (28) and DNS (6), where busybox nc and wget do not reliably. Verified by imagetools inspect.
CURL_IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
# Same digest as tests/gates/day1.sh, so its pull is already cached. Only for the sentinel's server.
SERVER_IMAGE="docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

CONNECT_TIMEOUT=4
PARALLEL_PODS="${PARALLEL_PODS:-4}"
RUN_ID="$(date -u +%H%M%S)"
SENTINEL_NS="netpol-sentinel-$RUN_ID"
PROBE_LABEL="plane-platform/netpol-probe"
WORK="$(mktemp -d)"
mkdir -p "$LOCAL_DIR/evidence-raw"
EVIDENCE="$LOCAL_DIR/evidence-raw/netpol-$(date -u +%Y%m%dT%H%M%SZ).tsv"

cleanup() {
  kc delete namespace "$SENTINEL_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc delete pod --all-namespaces -l "$PROBE_LABEL=$RUN_ID" --ignore-not-found --wait=false >/dev/null 2>&1 || true
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

run_group() { # run_group <group number> <namespace> <labels>
  local number="$1" namespace="$2" labels="$3" pod="netpol-$RUN_ID-$1" probes
  probes="$(awk -v ns="$namespace" -v l="$labels" '$2 == ns && $3 == l { print $1, $4, $5 }' "$WORK/cases")"
  if ! kc -n "$namespace" get namespace "$namespace" >/dev/null 2>&1; then
    warn "namespace $namespace does not exist"
    return 1
  fi
  start_probe_pod "$pod" "$namespace" "$labels" "$probes" || return 1
  collect_probe_pod "$pod" "$namespace" >"$WORK/group-$number.log" || return 1
  kc -n "$namespace" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
}

verdict_for() { # verdict_for <expect> <class> <protocol>
  local expect="$1" class="$2" protocol="$3"
  if [[ "$protocol" == udp ]]; then
    # For a DNS row, reaching any answer at all from the resolver is the point: the name resolved,
    # and only the lookup needs to pass. Connecting to port 53 afterwards is not under test.
    if [[ "$class" == DNS ]]; then
      if [[ "$expect" == deny ]]; then echo PASS; else echo FAIL; fi
    else
      if [[ "$expect" == allow ]]; then echo PASS; else echo FAIL; fi
    fi
    return
  fi
  case "$class" in
    DNS) echo INCONCLUSIVE ;;
    OTHER:*) echo FAIL ;;
    CONNECTED | REFUSED) if [[ "$expect" == allow ]]; then echo PASS; else echo FAIL; fi ;;
    TIMEOUT) if [[ "$expect" == deny ]]; then echo PASS; else echo FAIL; fi ;;
    *) echo FAIL ;;
  esac
}

run_matrix() {
  load_cases
  awk '{ print $2, $3 }' "$WORK/cases" | sort -u >"$WORK/groups"
  log "Running $(wc -l <"$WORK/cases" | tr -d ' ') rows from $(wc -l <"$WORK/groups" | tr -d ' ') source identities"

  local number=0 namespace labels
  while read -r namespace labels; do
    number=$((number + 1))
    run_group "$number" "$namespace" "$labels" &
    # Bash 3.2 has no wait -n, so run in fixed batches. Few enough to respect the namespace quotas.
    if [[ $((number % PARALLEL_PODS)) -eq 0 ]]; then wait; fi
  done <"$WORK/groups"
  wait

  cat "$WORK"/group-*.log 2>/dev/null | grep '^RESULT ' >"$WORK/results" || true

  printf 'verdict\texpect\tobserved\tfrom\tlabels\tto\tport\tnote\n' >"$EVIDENCE"
  local passed=0 failed=0 inconclusive=0
  local index from from_labels host port protocol expect note line code lookup connect message class verdict
  while read -r index from from_labels host port protocol expect note; do
    line="$(grep "^RESULT $index " "$WORK/results" | head -1 || true)"
    if [[ -z "$line" ]]; then
      class=NOT_RUN
      verdict=INCONCLUSIVE
    else
      read -r _ _ code lookup connect message <<<"$line"
      # shellcheck disable=SC2086  # the message is deliberately split back into words
      class="$(classify "$code" "$lookup" "$connect" $message)"
      verdict="$(verdict_for "$expect" "$class" "$protocol")"
    fi
    case "$verdict" in
      PASS) passed=$((passed + 1)) ;;
      FAIL) failed=$((failed + 1)) ;;
      *) inconclusive=$((inconclusive + 1)) ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$expect" "$class" "$from" "$from_labels" "$host" "$port" "$note" >>"$EVIDENCE"
    printf '%-13s %-6s %-10s %s %s -> %s:%s\n' "$verdict" "$expect" "$class" "$from" "$from_labels" "$host" "$port"
  done <"$WORK/cases"

  log "PASS $passed, FAIL $failed, INCONCLUSIVE $inconclusive. Evidence: $EVIDENCE"
  [[ "$failed" -eq 0 && "$inconclusive" -eq 0 ]]
}

run_sentinel
run_matrix || die "network policy matrix did not pass"
ok "network policy matrix passed"
