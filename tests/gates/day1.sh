#!/usr/bin/env bash
# Day-1 gates: cheap runtime checks for assumptions that source reading cannot settle.
# Each one blocks what follows, so they run before the platform is deployed.
# Results go to stdout; capture them with: tests/gates/day1.sh | tee docs/evidence/...
source "$(dirname "$0")/../../scripts/lib/common.sh"

NS=gate-checks
PROBE_IMAGE="docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"
pass=0; failed=0
result() { if [[ "$1" == PASS ]]; then pass=$((pass+1)); else failed=$((failed+1)); fi; printf '%-5s %s\n' "$1" "$2"; }

cleanup() { kc delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc label namespace "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

run_pod() { # name image [cmd...]
  local name="$1" image="$2"; shift 2
  kc -n "$NS" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kc -n "$NS" run "$name" --image="$image" --restart=Never --command -- "$@" >/dev/null
}

echo "--- Gate 1: digest pulls through each path"
# docker.io through the pull-through cache
run_pod g1-hub "$PROBE_IMAGE" sh -c 'echo pulled; sleep 1'
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g1-hub --timeout=180s >/dev/null 2>&1; then
  result PASS "docker.io digest pull"
else
  result FAIL "docker.io digest pull: $(kc -n "$NS" get pod g1-hub -o jsonpath='{.status.containerStatuses[0].state.waiting.message}')"
fi
# quay.io through the pull-through cache
run_pod g1-quay "quay.io/prometheus/busybox:latest@sha256:7379672d53c28113469275f2eb48adffa19954f39f8ef20c1e2992278f658e6c" sh -c 'echo pulled'
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g1-quay --timeout=180s >/dev/null 2>&1; then
  result PASS "quay.io digest pull"
else
  result FAIL "quay.io digest pull: $(kc -n "$NS" get pod g1-quay -o jsonpath='{.status.containerStatuses[0].state.waiting.message}')"
fi
# The cache really was used: blobs must now be stored in the mirror.
if docker exec plane-mirror-docker sh -c 'ls /var/lib/registry/docker/registry/v2/blobs/sha256 2>/dev/null | wc -l' | awk '{exit !($1>0)}'; then
  result PASS "pull-through cache holds blobs (not bypassed)"
else
  result FAIL "pull-through cache is empty, containerd bypassed it"
fi
# Local registry: push an image from the host, pull it by digest from the node.
docker pull -q "${PROBE_IMAGE#docker.io/}" >/dev/null
SRC="localhost:5001/gate/probe:v1"
docker tag "${PROBE_IMAGE#docker.io/}" "$SRC"
docker push -q "$SRC" >/dev/null
DIGEST="$(curl -fsSI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' http://localhost:5001/v2/gate/probe/manifests/v1 | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r')"
run_pod g1-local "localhost:5001/gate/probe@$DIGEST" sh -c 'echo pulled'
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g1-local --timeout=120s >/dev/null 2>&1; then
  result PASS "localhost:5001 digest pull ($DIGEST)"
else
  result FAIL "localhost:5001 digest pull: $(kc -n "$NS" get pod g1-local -o jsonpath='{.status.containerStatuses[0].state.waiting.message}')"
fi

echo "--- Gate 2: kindnet enforces NetworkPolicy"
echo "nftables tables on the node:"; docker exec "$NODE_CONTAINER" nft list tables 2>/dev/null | sed 's/^/    /'
kc -n "$NS" run g2-server --image="$PROBE_IMAGE" --labels=app=g2-server --port=8080 --command -- sh -c 'mkdir -p /www && echo ok > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
kc -n "$NS" expose pod g2-server --port=8080 >/dev/null
kc -n "$NS" wait --for=condition=Ready pod/g2-server --timeout=120s >/dev/null
probe() { # name : returns 0 if a NEW connection succeeds within the timeout
  local name="$1"; run_pod "$name" "$PROBE_IMAGE" sh -c 'wget -q -T 5 -O - http://g2-server:8080/index.html'
  kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$name" --timeout=20s >/dev/null 2>&1
}
if probe g2-before; then result PASS "positive control: traffic flows before any policy"; else result FAIL "positive control failed, gate is invalid"; fi
cat <<YAML | kc -n "$NS" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-to-server }
spec:
  podSelector: { matchLabels: { app: g2-server } }
  policyTypes: [Ingress]
YAML
sleep 5
if probe g2-after; then
  result FAIL "default-deny did NOT block a new connection: kindnet is not enforcing"
else
  logs="$(kc -n "$NS" logs g2-after 2>/dev/null | tail -1)"
  result PASS "default-deny blocked a new connection (client saw: ${logs:-timeout})"
fi
cat <<YAML | kc -n "$NS" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-labelled }
spec:
  podSelector: { matchLabels: { app: g2-server } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { allowed: "yes" } } }]
      ports: [{ port: 8080 }]
YAML
sleep 5
kc -n "$NS" delete pod g2-allowed --ignore-not-found --wait=true >/dev/null 2>&1 || true
kc -n "$NS" run g2-allowed --image="$PROBE_IMAGE" --labels=allowed=yes --restart=Never --command -- sh -c 'wget -q -T 5 -O - http://g2-server:8080/index.html' >/dev/null
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g2-allowed --timeout=20s >/dev/null 2>&1; then
  result PASS "allow rule admits only the labelled client"
else
  result FAIL "allow rule did not admit the labelled client"
fi

echo "--- Gate 5: git:// from inside the cluster"
if [[ ! -d "$LOCAL_DIR/git/gate.git" ]]; then
  tmp="$(mktemp -d)"; git init -q --bare "$LOCAL_DIR/git/gate.git"
  git -C "$tmp" init -q -b main; git -C "$tmp" -c user.email=g@g -c user.name=g commit -q --allow-empty -m gate
  git -C "$tmp" push -q "$LOCAL_DIR/git/gate.git" main; rm -rf "$tmp"
fi
# The trailing dot skips search domains. Busybox nslookup exits non-zero on the first NXDOMAIN
# from a search domain, which made an earlier version of this gate report a false failure.
run_pod g5-dns "$PROBE_IMAGE" sh -c 'nslookup plane-git.'
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g5-dns --timeout=30s >/dev/null 2>&1; then
  result PASS "pods resolve the Docker-network name plane-git"
else
  result FAIL "pods cannot resolve plane-git: $(kc -n "$NS" logs g5-dns 2>/dev/null | tail -2 | tr '\n' ' ')"
fi
GIT_IMAGE="docker.io/alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26"
kc -n "$NS" delete pod g5-clone --ignore-not-found --wait=true >/dev/null 2>&1 || true
kc -n "$NS" run g5-clone --image="$GIT_IMAGE" --restart=Never --command -- git ls-remote git://plane-git/gate.git >/dev/null
if kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/g5-clone --timeout=120s >/dev/null 2>&1; then
  result PASS "git:// ls-remote from a pod: $(kc -n "$NS" logs g5-clone | head -1)"
else
  result FAIL "git:// ls-remote failed: $(kc -n "$NS" logs g5-clone 2>/dev/null | tail -2 | tr '\n' ' ')"
fi
rm -rf "$LOCAL_DIR/git/gate.git"

echo "--- Summary: $pass passed, $failed failed"
[[ "$failed" -eq 0 ]]
