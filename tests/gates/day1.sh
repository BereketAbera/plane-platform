#!/usr/bin/env bash
# Day-1 gates: cheap runtime checks for assumptions that source reading cannot settle.
# Each one blocks what follows, so they run before the platform is deployed. They keep working after
# it is deployed: everything runs in the throwaway namespace gate-checks, the only NetworkPolicies
# applied are in there, and no platform policy selects that namespace or CoreDNS. The stamp at the top
# of the output says which NetworkPolicies were already loaded.
#
# Results go to stdout, with the UTC date and the exact command first (contract section 12). Capture
# them with a redirect, not a pipe, so the exit status stays this script's:
#   tests/gates/day1.sh > .local/evidence-raw/day1-gates.txt 2>&1
#
# Exit status: 0 only if every check ran and passed. 1 if a check failed or did not run, the cluster was not
# reachable, or the script stopped on an error. A signal ends it with 129 (HUP), 130 (INT) or 143 (TERM).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

# The closing line of the EXIT trap goes here. A trap runs under the redirections of the shell function
# it interrupted, and `kc ... >/dev/null` is one, so the trap's own stdout can be /dev/null.
exec 3>&1

NS=gate-checks
PROBE_IMAGE="docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"
QUAY_IMAGE="quay.io/prometheus/busybox:latest@sha256:7379672d53c28113469275f2eb48adffa19954f39f8ef20c1e2992278f658e6c"
GIT_IMAGE="docker.io/alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26"
# The same digest as scripts/test-netpol.sh. curl's exit codes separate a timeout (28) from a DNS
# failure (6) and a refused connection (7). Busybox wget exits 1 for all three.
CURL_IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
LOCAL_PROBE="localhost:5001/gate/probe"
READY_TIMEOUT=180s
SERVER_URL="http://g2-server.$NS.svc.cluster.local:8080/index.html"
# The server as the node asks for it, set once its Service exists. The node cannot resolve Service names.
WITNESS_URL=""
# No policy selects this server, so a client that cannot reach it has a problem no policy explains.
REFERENCE_URL="http://g2-reference.$NS.svc.cluster.local:8080/index.html"
CONNECT_TIMEOUT=5
# How long a NetworkPolicy change gets to reach kindnet before a probe counts against it.
POLICY_SETTLE_SECONDS=30
# Fast teardown, and a pod that outlives a killed run still ends by itself.
POD_OVERRIDES='{"apiVersion":"v1","spec":{"terminationGracePeriodSeconds":0,"activeDeadlineSeconds":900,"automountServiceAccountToken":false,"enableServiceLinks":false}}'

pass=0; failed=0; not_run=0
CLAIMED=no; CLAIMING=no; CLEANED=no; SUMMARY_DONE=no
result() { # <PASS|FAIL|NOT RUN> <what>
  case "$1" in
    PASS) pass=$((pass + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    *) not_run=$((not_run + 1)) ;;
  esac
  printf '%-5s %s\n' "$1" "$2"
}

# Only the run that holds the namespace cleans up, so a run refused below leaves the other's things alone.
# While the create is running CLAIMED is still no. A signal there gets here with the create done, and the
# owner's pid on the namespace says whether it is this run's. A failed get says no, and so leaves it alone.
holds_namespace() {
  [[ "$CLAIMED" == yes ]] && return 0
  [[ "$CLAIMING" == yes ]] || return 1
  [[ "$(kc get namespace "$NS" --ignore-not-found --request-timeout=10s -o jsonpath='{.metadata.annotations.plane-platform/gates-pid}' 2>/dev/null)" == "$$" ]] || return 1
  CLAIMED=yes
}

cleanup() {
  [[ "$CLEANED" == no ]] || return 0
  holds_namespace || return 0
  rm -rf "$LOCAL_DIR/git/gate.git"
  # The tag only. The source image stays cached, and the registry keeps the manifest this run pushed.
  docker image rm "$LOCAL_PROBE:v1" >/dev/null 2>&1 || true
  kc delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  # Only now. A signal during the work above exits through on_exit, which has to run all of it again.
  CLEANED=yes
}

# True only if the path is known to be absent. `-e` is also false for a dangling symlink, and when a parent
# cannot be searched, where macOS `rm -rf` even exits 0.
gone() { # <path>
  local out
  if out="$(LC_ALL=C ls -d "$1" 2>&1)"; then
    return 1
  fi
  [[ "$out" == *"No such file or directory" ]]
}

# One line for each thing this run has to remove and has not confirmed gone, and nothing if both are.
# Checks the state instead of trusting cleanup, which ignores a failed rm. A failed get prints nothing on
# stdout, so its exit code counts as well as its output.
leftovers() {
  local left newline=$'\n'
  if ! left="$(kc get namespace "$NS" --ignore-not-found --request-timeout=10s -o name 2>&1)" || [[ -n "$left" ]]; then
    printf 'namespace %s is not confirmed gone: %s. Delete it by hand: KUBECONFIG=.local/kubeconfig .tools/bin/kubectl delete namespace %s\n' "$NS" "${left//$newline/ }" "$NS"
  fi
  if ! gone "$LOCAL_DIR/git/gate.git"; then
    printf 'the throwaway .local/git/gate.git is not confirmed gone. Delete it by hand: rm -rf .local/git/gate.git\n'
  fi
}

on_exit() {
  local status=$? left line
  # A second signal must not cut this short. Bash holds a trap until the foreground command returns, so the
  # first can show nothing for minutes, and a second is likely.
  trap '' INT TERM HUP
  cleanup || true
  if [[ "$SUMMARY_DONE" == no ]]; then
    printf -- '--- Stopped before the summary, exit %s: %s passed, %s failed, %s not run\n' "$status" "$pass" "$failed" "$not_run" >&3
    if [[ "$CLAIMED" == yes ]]; then
      left="$(leftovers)"
      while IFS= read -r line; do
        [[ -z "$line" ]] || printf -- '--- Left behind: %s\n' "$line" >&3
      done <<<"$left"
    fi
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stamp_run() {
  local commit changes
  printf '# Day-1 gates\n'
  printf '# date (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# command: %s\n' "$0${*:+ $*}"
  commit="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  changes="$(git -C "$ROOT" status --porcelain -- tests/gates/day1.sh 2>/dev/null || true)"
  printf '# commit: %s%s\n' "$commit" "${changes:+, with uncommitted changes to this script}"
  printf '# context: %s\n' "$KUBE_CONTEXT"
}

stamp_loaded_policies() {
  local listed total deny_namespaces
  if ! listed="$(kc get networkpolicy --all-namespaces --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>&1)"; then
    printf '# NetworkPolicies already loaded: could not list them: %s\n' "$listed"
  elif [[ -z "$listed" ]]; then
    printf '# NetworkPolicies already loaded: none\n'
  else
    total="$(awk 'END { print NR }' <<<"$listed")"
    deny_namespaces="$(awk '$2 == "default-deny" { printf " %s", $1 }' <<<"$listed")"
    printf '# NetworkPolicies already loaded: %s, default-deny in:%s\n' "$total" "${deny_namespaces:- no namespace}"
  fi
}

# Takes the namespace atomically, so two runs cannot share it and fail each other. One left behind by
# a killed run is removed first. An annotation holds the owner's pid to tell those two cases apart.
claim_namespace() {
  local owner
  if [[ -n "$(kc get namespace "$NS" --ignore-not-found -o name)" ]]; then
    owner="$(kc get namespace "$NS" -o jsonpath='{.metadata.annotations.plane-platform/gates-pid}')"
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
      die "pid $owner is already running the gates in namespace $NS. Wait for it to finish."
    fi
    kc delete namespace "$NS" --wait=true --timeout=120s >/dev/null
  fi
  CLAIMING=yes
  kc create -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: baseline
    plane-platform/purpose: day1-gates
  annotations:
    plane-platform/gates-pid: "$$"
YAML
  CLAIMED=yes
}

run_pod() { # <name> [kubectl run flags...] [-- command...]
  local name="$1"; shift
  kc -n "$NS" run "$name" --restart=Never --overrides="$POD_OVERRIDES" "$@" >/dev/null
}

pod_state() { # <name>: why a pod did not get where it should have, for a result line
  kc -n "$NS" get pod "$1" -o jsonpath='phase {.status.phase} {.status.containerStatuses[0].state.waiting.reason} {.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true
}

pod_succeeded() { # <name> <timeout>
  kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout="$2" >/dev/null 2>&1
}

pod_log_tail() { # <name>: the last two lines on one line, for a result line
  local logs
  logs="$(kc -n "$NS" logs "$1" 2>&1 || true)"
  tail -2 <<<"$logs" | tr '\n' ' '
}

# ------ Gate 1 ------------------------------------------------------------------------------------

# With the default pull policy, an image a previous run left on the node satisfies a digest without
# any pull, and the check would pass with the path broken. Always makes containerd go through the path.
pull_check() { # <pod> <image> <what> <timeout>
  if run_pod "$1" --image="$2" --image-pull-policy=Always --command -- sh -c 'echo pulled' && pod_succeeded "$1" "$4"; then
    result PASS "$3"
  else
    result FAIL "$3: $(pod_state "$1")"
  fi
}

# Push an image from the host, then pull it by digest from the node.
local_registry_check() {
  local upstream="${PROBE_IMAGE#docker.io/}" output headers digest
  if ! output="$(docker pull -q "$upstream" 2>&1 && docker tag "$upstream" "$LOCAL_PROBE:v1" 2>&1 && docker push -q "$LOCAL_PROBE:v1" 2>&1)"; then
    result FAIL "localhost:5001 digest pull: could not push from the host: $(tail -1 <<<"$output")"
    return 0
  fi
  if ! headers="$(curl -fsSI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' http://localhost:5001/v2/gate/probe/manifests/v1 2>&1)"; then
    result FAIL "localhost:5001 digest pull: could not read the manifest: $headers"
    return 0
  fi
  digest="$(awk 'tolower($1) == "docker-content-digest:" { sub(/\r$/, "", $2); print $2 }' <<<"$headers")"
  if [[ "$digest" != sha256:* ]]; then
    result FAIL "localhost:5001 digest pull: the registry returned no digest"
    return 0
  fi
  pull_check g1-local "$LOCAL_PROBE@$digest" "localhost:5001 digest pull ($digest)" 120s
}

# Asks the mirror whether this run's pull reached it. A pull that worked cannot say, as containerd goes
# on to `server` in hosts.toml when the mirror fails. The blob store cannot say, as blobs stay from any
# earlier pull. The registry's access log can, with one line per request, like this:
#   172.24.0.2 - - [date] "HEAD /v2/library/busybox/manifests/sha256:... HTTP/1.1" 200 0 "" "containerd/v2.3.4"
# A node that already has the layers only resolves the manifest, so this shows the route containerd
# took. It does not show that layers came through the mirror.
mirror_check() { # <mirror container> <image> <what>
  local mirror="$1" digest="${2##*@}" logs answers
  if ! logs="$(docker logs --since "$RUN_START" "$mirror" 2>&1)"; then
    result FAIL "$3 through $mirror: could not read its logs: $(tail -1 <<<"$logs")"
    return 0
  fi
  answers="$(awk -v path="/manifests/$digest" '$6 ~ /^"(HEAD|GET)$/ && index($7, path) && $NF ~ /^"containerd\// { printf " %s", $9 }' <<<"$logs")"
  if [[ "$answers " == *" 200 "* ]]; then
    result PASS "$3 through $mirror: containerd asked it for $digest in this run, and it answered 200"
  elif [[ -n "$answers" ]]; then
    result FAIL "$3 through $mirror: it answered$answers for $digest, not 200, so containerd went on without it"
  else
    result FAIL "$3 through $mirror: it got no request for $digest in this run, so containerd bypassed it"
  fi
}

gate1() {
  echo "--- Gate 1: digest pulls through each path"
  pull_check g1-hub "$PROBE_IMAGE" "docker.io digest pull" 180s
  mirror_check plane-mirror-docker "$PROBE_IMAGE" "docker.io digest pull"
  pull_check g1-quay "$QUAY_IMAGE" "quay.io digest pull" 180s
  mirror_check plane-mirror-quay "$QUAY_IMAGE" "quay.io digest pull"
  local_registry_check
}

# ------ Gate 2 ------------------------------------------------------------------------------------

DENY_POLICY='apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-to-server }
spec:
  podSelector: { matchLabels: { app: g2-server } }
  policyTypes: [Ingress]'

ALLOW_POLICY='apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-labelled }
spec:
  podSelector: { matchLabels: { app: g2-server } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { allowed: "yes" } } }]
      ports: [{ port: 8080 }]'

above_zero() { awk -v t="${1:-0}" 'BEGIN { exit !(t + 0 > 0) }'; }

# classify <curl exit code> <time_namelookup> <time_connect> <error message>
# Prints CONNECTED, TIMEOUT, DNS, REFUSED or OTHER:<code>. Only TIMEOUT means the packets vanished.
classify() {
  if above_zero "$3"; then echo CONNECTED; return 0; fi
  case "$1" in
    0) echo CONNECTED ;;
    6) echo DNS ;;
    7) echo REFUSED ;;
    28)
      # curl also uses 28 for a resolver timeout, which must never read as a policy block.
      if [[ "$4" == Resolving* ]] || ! above_zero "$2"; then echo DNS; else echo TIMEOUT; fi
      ;;
    *) echo "OTHER:$1" ;;
  esac
}

# The exit code is printed rather than returned, so a kubectl failure can never be read as a curl result.
# shellcheck disable=SC2016  # expanded by the shell it runs in, not this one
FETCH='fetch() {
  out=$(curl -sS -o /dev/null --connect-timeout '"$CONNECT_TIMEOUT"' --max-time '"$((CONNECT_TIMEOUT + 2))"' -w "%{http_code} %{time_namelookup} %{time_connect} %{errormsg}" "$2" 2>/dev/null)
  code=$?
  echo "RESULT $1 $code $out"
}'
# Runs inside the client. Every run is a new connection, the only thing kindnet evaluates. The two
# fetches start together, so the reference speaks for the same client at the same moment as the target.
# shellcheck disable=SC2016  # expanded by the pod's shell, not this one
IN_POD_PROBE="$FETCH"'
fetch target "$1" &
fetch reference "$2" &
wait'
# Runs on the node, as root, at the same moment. kindnet's postrouting chain accepts `meta skuid 0` ahead of
# its policy queue, so no policy governs this fetch, and an answer shows the target is up and listening. If a
# later kindnet applied policy to it, the deny rows would fail, not pass.
# shellcheck disable=SC2016  # expanded by the node's shell, not this one
NODE_PROBE="$FETCH"'
fetch witness "$1"'

read_result() { # <exec output> <target, reference or witness>. Sets RESULT_CLASS, RESULT_HTTP and RESULT_DETAIL.
  local line code lookup connect message
  line="$(grep "^RESULT $2 " <<<"$1" || true)"
  if [[ -z "$line" ]]; then
    RESULT_CLASS=NO_RESULT; RESULT_HTTP=none
    message="$(grep -v '^RESULT ' <<<"$1" | tail -1 || true)"
    RESULT_DETAIL="no result${message:+: $message}"
    return 0
  fi
  read -r _ _ code RESULT_HTTP lookup connect message <<<"$line"
  RESULT_CLASS="$(classify "$code" "$lookup" "$connect" "$message")"
  RESULT_DETAIL="curl exit $code, HTTP $RESULT_HTTP${message:+, $message}"
}

# <client pod> <url>. Sets PROBE_* for the url, REFERENCE_* for the reference and WITNESS_* for the node's
# fetch of the server. All three start together. Only the deny rows read the witness.
probe() {
  local raw
  raw="$(
    kc -n "$NS" exec "$1" -- sh -c "$IN_POD_PROBE" probe "$2" "$REFERENCE_URL" 2>&1 &
    docker exec "$NODE_CONTAINER" sh -c "$NODE_PROBE" probe "$WITNESS_URL" 2>&1 &
    wait
  )" || true
  read_result "$raw" target
  PROBE_CLASS="$RESULT_CLASS"; PROBE_HTTP="$RESULT_HTTP"; PROBE_DETAIL="$RESULT_DETAIL"
  read_result "$raw" reference
  REFERENCE_CLASS="$RESULT_CLASS"; REFERENCE_HTTP="$RESULT_HTTP"; REFERENCE_DETAIL="$RESULT_DETAIL"
  read_result "$raw" witness
  WITNESS_CLASS="$RESULT_CLASS"; WITNESS_HTTP="$RESULT_HTTP"; WITNESS_DETAIL="$RESULT_DETAIL"
}

# probe_until <client> <wanted class> <class worth retrying, or any, or none> [url, the server if left out]
# Retries only what a policy change that has not reached kindnet yet can explain.
probe_until() {
  local client="$1" wanted="$2" retry_on="$3" url="${4:-$SERVER_URL}" deadline=$((SECONDS + POLICY_SETTLE_SECONDS))
  PROBE_TRIES=0
  while :; do
    probe "$client" "$url"
    PROBE_TRIES=$((PROBE_TRIES + 1))
    [[ "$PROBE_CLASS" != "$wanted" ]] || return 0
    [[ "$retry_on" == any || "$PROBE_CLASS" == "$retry_on" ]] || return 1
    [[ $SECONDS -lt $deadline ]] || return 1
    sleep 2
  done
}

# A deny passes only on a real timeout while two things answer at the same moment: the reference, a server
# no policy selects, answers the same client, and the target answers the node's root curl. DNS trouble, a
# refused connection, a kubectl failure, or either of those not answering says nothing about the policy, so
# each of those fails instead of reading as blocked. This rules out loss on the client's side, across the
# network, and at the target itself. It cannot catch loss only on the path from this client to the target,
# for example an egress policy on the client that lets through DNS and the reference: that reads the same as
# the ingress policy under test. So a PASS states what was seen, not that the policy caused it. The controls
# before and after the policies are all that bound that.
expect_blocked() { # <client> <what> [CONNECTED, to retry until the policy has reached kindnet]
  local seen
  if probe_until "$1" TIMEOUT "${3:-none}"; then
    seen="target: $PROBE_DETAIL; reference: $REFERENCE_DETAIL; node: $WITNESS_DETAIL"
    if [[ "$REFERENCE_CLASS" != CONNECTED || "$REFERENCE_HTTP" != 200 ]]; then
      result FAIL "$2: the target timed out but the reference did not answer this client, so this says nothing about the policy ($seen)"
    elif [[ "$WITNESS_CLASS" != CONNECTED || "$WITNESS_HTTP" != 200 ]]; then
      result FAIL "$2: the target timed out but it did not answer the node's root curl either, so this says nothing about the policy ($seen)"
    else
      result PASS "$2: a new connection to the target timed out, while at the same moment the reference answered this client and the target answered the node's root curl (try $PROBE_TRIES, $seen)"
    fi
  elif [[ "$PROBE_CLASS" == CONNECTED ]]; then
    result FAIL "$2: the connection got through, so the policy was not enforced ($PROBE_DETAIL)"
  else
    result FAIL "$2: $PROBE_CLASS is not a timeout, so this says nothing about the policy ($PROBE_DETAIL)"
  fi
}

expect_admitted() { # <client> <what> <class worth retrying, or any> [url, the server if left out]
  if probe_until "$1" CONNECTED "$3" "${4:-$SERVER_URL}" && [[ "$PROBE_HTTP" == 200 ]]; then
    result PASS "$2 (try $PROBE_TRIES, HTTP 200)"
  else
    result FAIL "$2: $PROBE_CLASS ($PROBE_DETAIL)"
  fi
}

start_gate2_pods() {
  local server server_ip
  for server in g2-server g2-reference; do
    run_pod "$server" --image="$PROBE_IMAGE" --labels="app=$server" --port=8080 --command -- \
      sh -c 'mkdir -p /www && echo ok > /www/index.html && exec httpd -f -p 8080 -h /www' &&
      kc -n "$NS" expose pod "$server" --port=8080 >/dev/null || return 1
  done
  run_pod g2-plain --image="$CURL_IMAGE" --command -- sleep 900 &&
    run_pod g2-labelled --image="$CURL_IMAGE" --labels=allowed=yes --command -- sleep 900 || return 1
  server_ip="$(kc -n "$NS" get service g2-server -o jsonpath='{.spec.clusterIP}')" && [[ -n "$server_ip" ]] || return 1
  WITNESS_URL="${SERVER_URL/g2-server.$NS.svc.cluster.local/$server_ip}"
}

gate2() {
  local tables pod ready=yes failed_before
  echo "--- Gate 2: kindnet enforces NetworkPolicy"
  echo "nftables tables on the node:"
  tables="$(docker exec "$NODE_CONTAINER" nft list tables 2>&1 || true)"
  # shellcheck disable=SC2001  # sed indents every line of a multi-line value, which ${var//} cannot do
  sed 's/^/    /' <<<"$tables"

  # The clients live for the whole gate, so the policy is the only thing that changes between probes.
  # A pod that is not Ready fails the gate here, before any probe could misread it as a block.
  if ! start_gate2_pods; then
    result FAIL "could not create the gate 2 pods"
    ready=no
  fi
  for pod in g2-server g2-reference g2-plain g2-labelled; do
    if [[ "$ready" == yes ]] && ! kc -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout="$READY_TIMEOUT" >/dev/null 2>&1; then
      result FAIL "$pod never became Ready: $(pod_state "$pod")"
      ready=no
    fi
  done
  if [[ "$ready" == no ]]; then
    result "NOT RUN" "positive controls, default-deny and allow rule, because the pods are not there to probe"
    return 0
  fi

  failed_before="$failed"
  expect_admitted g2-plain "positive control: the unlabelled client reaches the server before any policy" any
  expect_admitted g2-labelled "positive control: the labelled client reaches the server before any policy" any
  expect_admitted g2-plain "positive control: the unlabelled client reaches the reference before any policy" any "$REFERENCE_URL"
  expect_admitted g2-labelled "positive control: the labelled client reaches the reference before any policy" any "$REFERENCE_URL"
  if [[ "$failed" -ne "$failed_before" ]]; then
    result "NOT RUN" "default-deny and allow rule, because a block would mean nothing with the positive control failing"
    return 0
  fi

  if ! kc -n "$NS" apply -f - >/dev/null <<<"$DENY_POLICY"; then
    result FAIL "could not apply the default-deny policy in $NS"
    result "NOT RUN" "default-deny and allow rule, because no policy was applied"
    return 0
  fi
  expect_blocked g2-plain "default-deny, unlabelled client" CONNECTED
  expect_blocked g2-labelled "default-deny, labelled client"

  if ! kc -n "$NS" apply -f - >/dev/null <<<"$ALLOW_POLICY"; then
    result FAIL "could not apply the allow policy in $NS"
    result "NOT RUN" "allow rule, because no policy was applied"
    return 0
  fi
  # In this order: while the rule has not reached kindnet, the unlabelled client would time out anyway.
  failed_before="$failed"
  expect_admitted g2-labelled "allow rule admits the labelled client" TIMEOUT
  if [[ "$failed" -eq "$failed_before" ]]; then
    expect_blocked g2-plain "allow rule, unlabelled client"
  else
    result "NOT RUN" "unlabelled client under the allow rule, because a timeout proves nothing until the rule has been seen working"
  fi

  # The same client, the same server, no policy. This shows the network and the server still work. It
  # says nothing on its own about what caused the timeouts above: the reference and the node speak to that.
  if kc -n "$NS" delete networkpolicy deny-to-server allow-labelled >/dev/null; then
    expect_admitted g2-plain "control: with both policies deleted the unlabelled client connects again, so the network and the server still work" TIMEOUT
  else
    result FAIL "could not delete the gate's policies in $NS"
  fi
}

# ------ Gate 5 ------------------------------------------------------------------------------------

make_gate_repo() {
  local tmp status=0
  rm -rf "$LOCAL_DIR/git/gate.git"
  tmp="$(mktemp -d)" || return 1
  git init -q --bare -b main "$LOCAL_DIR/git/gate.git" &&
    git -C "$tmp" init -q -b main &&
    git -C "$tmp" -c user.email=g@g -c user.name=g -c commit.gpgsign=false commit -q --allow-empty -m gate &&
    git -C "$tmp" push -q "$LOCAL_DIR/git/gate.git" main || status=$?
  rm -rf "$tmp"
  return "$status"
}

gate5() {
  local logs
  echo "--- Gate 5: git:// from inside the cluster"
  # The trailing dot skips search domains. Busybox nslookup exits non-zero on the first NXDOMAIN
  # from a search domain, which made an earlier version of this gate report a false failure.
  if run_pod g5-dns --image="$PROBE_IMAGE" --command -- nslookup plane-git. && pod_succeeded g5-dns 30s; then
    result PASS "pods resolve the Docker-network name plane-git"
  else
    result FAIL "pods cannot resolve plane-git: $(pod_log_tail g5-dns)"
  fi
  if ! make_gate_repo; then
    result FAIL "git:// ls-remote: could not create the throwaway repository"
    return 0
  fi
  if run_pod g5-clone --image="$GIT_IMAGE" --command -- git ls-remote git://plane-git/gate.git && pod_succeeded g5-clone 120s; then
    logs="$(kc -n "$NS" logs g5-clone 2>&1 || true)"
    # An empty repository also exits 0, so ask for the commit that was pushed.
    if [[ "$logs" == *refs/heads/main* ]]; then
      result PASS "git:// ls-remote from a pod: $(head -1 <<<"$logs")"
    else
      result FAIL "git:// ls-remote from a pod returned no refs/heads/main: $logs"
    fi
  else
    result FAIL "git:// ls-remote failed: $(pod_state g5-clone) $(pod_log_tail g5-clone)"
  fi
}

# ------ Run ---------------------------------------------------------------------------------------

report_cleanup() {
  local left line
  cleanup || true
  left="$(leftovers)"
  if [[ -z "$left" ]]; then
    result PASS "namespace $NS and the throwaway gate.git are gone"
    return 0
  fi
  while IFS= read -r line; do
    result FAIL "$line"
  done <<<"$left"
}

stamp_run "$@"
if ! kc get --raw /readyz >/dev/null 2>&1; then
  result "BLOCKED" "the cluster is not reachable, so no gate ran. Run 'make up' first."
  exit 1
fi
guard_disk 2
# The clock that stamps docker logs is the Docker VM's, which can drift from the host's across a sleep.
RUN_START="$(docker info --format '{{.SystemTime}}')"
printf '# run start on the Docker clock: %s\n' "$RUN_START"
claim_namespace
stamp_loaded_policies

gate1
gate2
gate5

echo "--- Cleanup"
report_cleanup

SUMMARY_DONE=yes
if [[ "$not_run" -eq 0 ]]; then
  echo "--- Summary: $pass passed, $failed failed"
else
  echo "--- Summary: $pass passed, $failed failed, $not_run not run"
fi
[[ "$failed" -eq 0 && "$not_run" -eq 0 ]]
