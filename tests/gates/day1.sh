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
# Exit status: 0 only if every check ran and passed, otherwise 1.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

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
CONNECT_TIMEOUT=5
# How long a NetworkPolicy change gets to reach kindnet before a probe counts against it.
POLICY_SETTLE_SECONDS=30
# Fast teardown, and a pod that outlives a killed run still ends by itself.
POD_OVERRIDES='{"apiVersion":"v1","spec":{"terminationGracePeriodSeconds":0,"activeDeadlineSeconds":900,"automountServiceAccountToken":false,"enableServiceLinks":false}}'

pass=0; failed=0; not_run=0
CLAIMED=no; CLEANED=no; SUMMARY_DONE=no
result() { # <PASS|FAIL|NOT RUN> <what>
  case "$1" in
    PASS) pass=$((pass + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    *) not_run=$((not_run + 1)) ;;
  esac
  printf '%-5s %s\n' "$1" "$2"
}

# Only the run that holds the namespace cleans up. A run refused below leaves the other's things alone.
cleanup() {
  [[ "$CLAIMED" == yes && "$CLEANED" == no ]] || return 0
  CLEANED=yes
  rm -rf "$LOCAL_DIR/git/gate.git"
  # The tag only. The source image stays cached, and the registry keeps the manifest this run pushed.
  docker image rm "$LOCAL_PROBE:v1" >/dev/null 2>&1 || true
  kc delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
}
on_exit() {
  local status=$?
  cleanup || true
  if [[ "$SUMMARY_DONE" == no ]]; then
    printf -- '--- Stopped before the summary, exit %s: %s passed, %s failed, %s not run\n' "$status" "$pass" "$failed" "$not_run"
  fi
}
trap on_exit EXIT
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

gate1() {
  local blobs
  echo "--- Gate 1: digest pulls through each path"
  pull_check g1-hub "$PROBE_IMAGE" "docker.io digest pull" 180s
  pull_check g1-quay "$QUAY_IMAGE" "quay.io digest pull" 180s
  # The cache really was used: blobs must now be stored in the mirror.
  if blobs="$(docker exec plane-mirror-docker sh -c 'ls /var/lib/registry/docker/registry/v2/blobs/sha256 2>/dev/null | wc -l' 2>&1)" && [[ "$blobs" -gt 0 ]]; then
    result PASS "pull-through cache holds blobs (not bypassed)"
  else
    result FAIL "pull-through cache is empty, containerd bypassed it: $blobs"
  fi
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

# Runs inside the client. Every run is a new connection, the only thing kindnet evaluates. The exit
# code is printed rather than returned, so a kubectl failure can never be read as a curl result.
# shellcheck disable=SC2016  # expanded by the pod's shell, not this one
IN_POD_PROBE='out=$(curl -sS -o /dev/null --connect-timeout '"$CONNECT_TIMEOUT"' --max-time '"$((CONNECT_TIMEOUT + 2))"' -w "%{http_code} %{time_namelookup} %{time_connect} %{errormsg}" "$1" 2>/dev/null)
code=$?
echo "RESULT $code $out"'

probe() { # <client pod>. Sets PROBE_CLASS, PROBE_HTTP and PROBE_DETAIL.
  local raw line code lookup connect message
  raw="$(kc -n "$NS" exec "$1" -- sh -c "$IN_POD_PROBE" probe "$SERVER_URL" 2>&1 || true)"
  line="$(grep '^RESULT ' <<<"$raw" || true)"
  if [[ -z "$line" ]]; then
    PROBE_CLASS=NO_RESULT; PROBE_HTTP=none
    PROBE_DETAIL="kubectl exec gave no result: $(tail -1 <<<"$raw")"
    return 0
  fi
  read -r _ code PROBE_HTTP lookup connect message <<<"$line"
  PROBE_CLASS="$(classify "$code" "$lookup" "$connect" "$message")"
  PROBE_DETAIL="curl exit $code, HTTP $PROBE_HTTP${message:+, $message}"
}

# probe_until <client> <wanted class> <class worth retrying, or any, or none>
# Retries only what a policy change that has not reached kindnet yet can explain.
probe_until() {
  local client="$1" wanted="$2" retry_on="$3" deadline=$((SECONDS + POLICY_SETTLE_SECONDS))
  PROBE_TRIES=0
  while :; do
    probe "$client"
    PROBE_TRIES=$((PROBE_TRIES + 1))
    [[ "$PROBE_CLASS" != "$wanted" ]] || return 0
    [[ "$retry_on" == any || "$PROBE_CLASS" == "$retry_on" ]] || return 1
    [[ $SECONDS -lt $deadline ]] || return 1
    sleep 2
  done
}

# A deny passes only on a real timeout. DNS trouble, a refused connection, or a kubectl failure says
# nothing about the policy, so each of those fails instead of reading as blocked.
expect_blocked() { # <client> <what> [CONNECTED, to retry until the policy has reached kindnet]
  if probe_until "$1" TIMEOUT "${3:-none}"; then
    result PASS "$2 (try $PROBE_TRIES, client saw: $PROBE_DETAIL)"
  elif [[ "$PROBE_CLASS" == CONNECTED ]]; then
    result FAIL "$2: the connection got through, so the policy was not enforced ($PROBE_DETAIL)"
  else
    result FAIL "$2: $PROBE_CLASS is not a timeout, so this says nothing about the policy ($PROBE_DETAIL)"
  fi
}

expect_admitted() { # <client> <what> <class worth retrying, or any>
  if probe_until "$1" CONNECTED "$3" && [[ "$PROBE_HTTP" == 200 ]]; then
    result PASS "$2 (try $PROBE_TRIES, HTTP 200)"
  else
    result FAIL "$2: $PROBE_CLASS ($PROBE_DETAIL)"
  fi
}

start_gate2_pods() {
  run_pod g2-server --image="$PROBE_IMAGE" --labels=app=g2-server --port=8080 --command -- \
    sh -c 'mkdir -p /www && echo ok > /www/index.html && exec httpd -f -p 8080 -h /www' &&
    kc -n "$NS" expose pod g2-server --port=8080 >/dev/null &&
    run_pod g2-plain --image="$CURL_IMAGE" --command -- sleep 900 &&
    run_pod g2-labelled --image="$CURL_IMAGE" --labels=allowed=yes --command -- sleep 900
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
  for pod in g2-server g2-plain g2-labelled; do
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
  if [[ "$failed" -ne "$failed_before" ]]; then
    result "NOT RUN" "default-deny and allow rule, because a block would mean nothing with the positive control failing"
    return 0
  fi

  if ! kc -n "$NS" apply -f - >/dev/null <<<"$DENY_POLICY"; then
    result FAIL "could not apply the default-deny policy in $NS"
    result "NOT RUN" "default-deny and allow rule, because no policy was applied"
    return 0
  fi
  expect_blocked g2-plain "default-deny blocked a new connection from the unlabelled client" CONNECTED
  expect_blocked g2-labelled "default-deny blocked a new connection from the labelled client"

  if ! kc -n "$NS" apply -f - >/dev/null <<<"$ALLOW_POLICY"; then
    result FAIL "could not apply the allow policy in $NS"
    result "NOT RUN" "allow rule, because no policy was applied"
    return 0
  fi
  # In this order: while the rule has not reached kindnet, the unlabelled client would time out anyway.
  failed_before="$failed"
  expect_admitted g2-labelled "allow rule admits the labelled client" TIMEOUT
  if [[ "$failed" -eq "$failed_before" ]]; then
    expect_blocked g2-plain "allow rule admits only the labelled client: the unlabelled client is still blocked"
  else
    result "NOT RUN" "unlabelled client under the allow rule, because a timeout proves nothing until the rule has been seen working"
  fi

  # The same client, the same server, no policy: this ties the timeouts above to the policies, and
  # rules out a network or a server that simply stopped working.
  if kc -n "$NS" delete networkpolicy deny-to-server allow-labelled >/dev/null; then
    expect_admitted g2-plain "control: with both policies deleted the unlabelled client connects again, so the policies caused those timeouts" TIMEOUT
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

stamp_run "$@"
if ! kc get --raw /readyz >/dev/null 2>&1; then
  result "BLOCKED" "the cluster is not reachable, so no gate ran. Run 'make up' first."
  exit 1
fi
guard_disk 2
claim_namespace
stamp_loaded_policies

gate1
gate2
gate5

echo "--- Cleanup"
if cleanup && [[ -z "$(kc get namespace "$NS" --ignore-not-found -o name)" ]]; then
  result PASS "namespace $NS and the throwaway gate.git are gone"
else
  result FAIL "namespace $NS is still there. Delete it by hand: kubectl delete namespace $NS"
fi

SUMMARY_DONE=yes
if [[ "$not_run" -eq 0 ]]; then
  echo "--- Summary: $pass passed, $failed failed"
else
  echo "--- Summary: $pass passed, $failed failed, $not_run not run"
fi
[[ "$failed" -eq 0 && "$not_run" -eq 0 ]]
