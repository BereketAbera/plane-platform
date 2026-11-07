#!/usr/bin/env bash
# scripts/hosted/grafana-admin.sh against a stub cluster: whether the password file here, Secret monitoring/grafana-admin and the admin that
# a running Grafana pod holds agree after each verb, and after a step of one fails. The script runs in a throwaway copy of this repository's
# scripts, whose kubectl, tunnel and install-tools are stubs, so nothing here can reach a cluster. Every password is made here, by the script
# under test, and none is printed: they are compared in base64, as the Secret holds them.
#
#   scripts/ci/test-grafana-admin.sh
#
# It runs what is on disk. It says nothing about a real cluster or about Grafana itself. Grafana keeps the admin its database was made with,
# whatever the Secret says later, which was read on Grafana 13.3.0 in Docker, and the stub's pod does the same.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" yq >/dev/null
for tool in jq openssl base64; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/repo"
STUB="$WORK/stub"
STATE="$COPY/.local/hosted/plane-prod"
mkdir -p "$COPY/scripts" "$COPY/infrastructure/hosted/plane-prod" "$COPY/.tools/bin" "$STATE" "$STUB"
cp -R "$ROOT/scripts/lib" "$ROOT/scripts/hosted" "$COPY/scripts/"
cp "$ROOT/infrastructure/hosted/plane-prod/target.yaml" "$COPY/infrastructure/hosted/plane-prod/"
ln -s "$ROOT/.tools/bin/yq" "$COPY/.tools/bin/yq"
printf '#!/usr/bin/env bash\nexit 0\n' >"$COPY/scripts/install-tools.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$COPY/scripts/hosted/tunnel.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$COPY/.tools/bin/pbcopy"
printf 'stub\n' >"$STATE/kubeconfig"
STUB_UID="$(yq -r '.kube_system_uid' "$COPY/infrastructure/hosted/plane-prod/target.yaml")"
STUB_NODE="$(yq -r '.node_name' "$COPY/infrastructure/hosted/plane-prod/target.yaml")"
STUB_PORT="$(yq -r '.tunnel_port' "$COPY/infrastructure/hosted/plane-prod/target.yaml")"
export STUB STUB_UID STUB_NODE STUB_PORT

# The cluster, in $STUB:
#   secret.json      Secret monitoring/grafana-admin as the API returns it, absent until written
#   pod              the admin password, in base64, that the running pod's database was made with. A new pod takes the Secret's
#   deployment       there while Deployment monitoring/kps-grafana exists and reads that Secret
#   fault-<step>     that step fails as an unreachable API does: delete, apply, deployment. fault-namespace: monitoring is not there
#   deletes          one line for each pod delete that went through
cat >"$COPY/.tools/bin/kubectl" <<'STUB_KUBECTL'
#!/usr/bin/env bash
set -uo pipefail
ns="" args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig | --context) shift 2 ;;
    --request-timeout=*) shift ;;
    -n) ns="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
unreachable() { echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2; exit 1; }
fault() { [[ -e "$STUB/fault-$1" ]]; }
case "$*" in
  "config get-contexts -o name") echo plane-prod ;;
  "config view --minify -o jsonpath={.clusters[0].cluster.server}") printf 'https://127.0.0.1:%s' "$STUB_PORT" ;;
  "get namespace kube-system -o jsonpath={.metadata.uid}") printf '%s' "$STUB_UID" ;;
  "get nodes -o jsonpath={.items[*].metadata.name}") printf '%s' "$STUB_NODE" ;;
  "get namespace monitoring")
    if fault namespace; then echo 'Error from server (NotFound): namespaces "monitoring" not found' >&2; exit 1; fi
    echo "namespace/monitoring" ;;
  "get secret grafana-admin -o json")
    [[ "$ns" == monitoring && -s "$STUB/secret.json" ]] || { echo 'Error from server (NotFound): secrets "grafana-admin" not found' >&2; exit 1; }
    cat "$STUB/secret.json" ;;
  "get secrets -o json")
    if [[ "$ns" == monitoring && -s "$STUB/secret.json" ]]; then jq -c '{items: [.]}' "$STUB/secret.json"; else echo '{"items": []}'; fi ;;
  "create secret generic grafana-admin "*"--dry-run=client -o yaml")
    user="" password=""
    for arg in "$@"; do
      case "$arg" in
        --from-file=admin-user=*) user="${arg#--from-file=admin-user=}" ;;
        --from-file=admin-password=*) password="${arg#--from-file=admin-password=}" ;;
      esac
    done
    printf 'apiVersion: v1\ndata:\n  admin-password: %s\n  admin-user: %s\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: %s\n' \
      "$(base64 <"$password" | tr -d '\n')" "$(base64 <"$user" | tr -d '\n')" "$ns" ;;
  "apply --server-side --field-manager=hosted-grafana-admin --force-conflicts -f -")
    fault apply && unreachable
    yq -o json '{"apiVersion": .apiVersion, "kind": .kind, "metadata": .metadata, "data": .data}' - >"$STUB/secret.json.new" || exit 1
    mv "$STUB/secret.json.new" "$STUB/secret.json"
    echo "secret/grafana-admin serverside-applied" ;;
  "get deployment kps-grafana -o json" | "get deployment kps-grafana -o json --ignore-not-found")
    fault deployment && unreachable
    if [[ -e "$STUB/deployment" ]]; then
      echo '{"spec":{"template":{"spec":{"containers":[{"name":"grafana","env":[{"name":"GF_SECURITY_ADMIN_PASSWORD","valueFrom":{"secretKeyRef":{"name":"grafana-admin","key":"admin-password"}}}]}]}}}}'
    elif [[ "$*" != *--ignore-not-found ]]; then
      echo 'Error from server (NotFound): deployments.apps "kps-grafana" not found' >&2
      exit 1
    fi ;;
  "delete pod -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack --timeout=120s")
    fault delete && unreachable
    jq -j '.data["admin-password"]' "$STUB/secret.json" >"$STUB/pod"
    echo deleted >>"$STUB/deletes"
    echo 'pod "kps-grafana-stub" deleted' ;;
  "wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack --timeout=5s")
    echo "pod/kps-grafana-stub condition met" ;;
  *) echo "stub kubectl: not expected: $*" >&2; exit 97 ;;
esac
STUB_KUBECTL
chmod +x "$COPY/.tools/bin/kubectl" "$COPY/.tools/bin/pbcopy" "$COPY/scripts/install-tools.sh" "$COPY/scripts/hosted/tunnel.sh"

# The values compared, in base64. None is printed.
file_value() { if [[ -s "$STATE/grafana-admin-password" ]]; then base64 <"$STATE/grafana-admin-password" | tr -d '\n'; fi; }
secret_value() { if [[ -s "$STUB/secret.json" ]]; then jq -j '.data["admin-password"]' "$STUB/secret.json"; fi; }
pod_value() { cat "$STUB/pod" 2>/dev/null || true; }
deletes() { if [[ -f "$STUB/deletes" ]]; then wc -l <"$STUB/deletes" | tr -d ' '; else echo 0; fi; }

# Every password rotate has replaced, to be found among what the evidence scrub knows.
: >"$WORK/rotated-out"
STATUS=0
OUTPUT="$WORK/last-output"
verb() { # verb <apply|rotate|login> [VAR=value...]: the script in the copy, with CONFIRM=plane-prod unless the arguments say CONFIRM=
  local name="$1"
  shift
  if [[ "$name" == rotate ]]; then file_value >>"$WORK/rotated-out" && printf '\n' >>"$WORK/rotated-out"; fi
  STATUS=0
  (cd "$COPY" && env -u HOSTED_NO_CLUSTER -u KUBECONFIG TARGET=plane-prod CONFIRM=plane-prod "$@" ./scripts/hosted/grafana-admin.sh "$name") >"$OUTPUT" 2>&1 || STATUS=$?
}

passed=0
failed=0
expect() { # expect <what> <test...>
  local what="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    ok "$what"
  else
    failed=$((failed + 1))
    warn "FAILED: $what. The script exited $STATUS and said:"
    sed -E 's/[0-9a-f]{64}/<64 hex>/g; s/^/    /' "$OUTPUT" >&2
  fi
}
same() { [[ -n "$1" && "$1" == "$2" ]]; }
differ() { [[ -n "$1" && -n "$2" && "$1" != "$2" ]]; }
said() { grep -qF -- "$1" "$OUTPUT"; }
pending() { [[ -e "$STATE/grafana-admin-pending" ]]; }
not() { ! "$@"; }

touch "$STUB/deployment"

log "apply on a cluster with no Secret yet"
verb apply
expect "it exits 0" test "$STATUS" -eq 0
expect "the Secret holds the password made here" same "$(secret_value)" "$(file_value)"
expect "the pod was replaced, and holds it too" same "$(pod_value)" "$(file_value)"
expect "nothing is left pending" not pending

log "apply again"
verb apply
expect "it exits 0, and replaces no pod" test "$STATUS" -eq 0 -a "$(deletes)" -eq 1

log "rotate without CONFIRM=plane-prod"
before="$(file_value)"
verb rotate CONFIRM=
expect "it is refused" test "$STATUS" -ne 0
expect "the password is as it was" same "$(file_value)" "$before"

log "rotate, with namespace monitoring gone after the identity check"
touch "$STUB/fault-namespace"
verb rotate
rm "$STUB/fault-namespace"
expect "it is refused" test "$STATUS" -ne 0
expect "the password is as it was, because every check comes before it" same "$(file_value)" "$before"

log "rotate, with the pod delete failing"
touch "$STUB/fault-delete"
verb rotate
rm "$STUB/fault-delete"
expect "it fails" test "$STATUS" -ne 0
expect "the Secret holds the new password" same "$(secret_value)" "$(file_value)"
expect "the running pod still holds the old one" same "$(pod_value)" "$before"
expect "a pod is left pending" pending
expect "it says how to finish" said "VERB=apply"
verb login
expect "login warns that the pod may still take the old password" said "may still take the old one"

log "apply, to finish it"
deletes_before="$(deletes)"
verb apply
expect "it exits 0" test "$STATUS" -eq 0
expect "it replaced the pod, though the Secret already held the login" test "$(deletes)" -eq $((deletes_before + 1))
expect "the pod holds the new password" same "$(pod_value)" "$(file_value)"
expect "nothing is left pending" not pending
verb login
expect "login no longer warns" not said "may still take the old one"

log "rotate, with the Secret's write failing"
before="$(file_value)"
touch "$STUB/fault-apply"
verb rotate
rm "$STUB/fault-apply"
expect "it fails" test "$STATUS" -ne 0
expect "the Secret and the pod still hold the old password" test "$(secret_value)" = "$before" -a "$(pod_value)" = "$before"
expect "the file holds the new one" differ "$(file_value)" "$before"
verb apply
expect "apply finishes it" same "$(pod_value)" "$(file_value)"
expect "and the Secret agrees" same "$(secret_value)" "$(file_value)"
expect "nothing is left pending" not pending

log "rotate, with the Deployment unreadable after the Secret's write"
touch "$STUB/fault-deployment"
verb rotate
rm "$STUB/fault-deployment"
expect "it fails" test "$STATUS" -ne 0
expect "a pod is left pending" pending
verb apply
expect "apply then replaces the pod" same "$(pod_value)" "$(file_value)"
expect "nothing is left pending" not pending

log "apply with no Deployment yet, as bootstrap.sh runs it"
rm "$STUB/deployment" "$STUB/secret.json" "$STATE/grafana-admin-password" "$STATE/grafana-admin-user"
deletes_before="$(deletes)"
verb apply
expect "it exits 0" test "$STATUS" -eq 0
expect "the Secret holds a new password made here" same "$(secret_value)" "$(file_value)"
expect "no pod was replaced, and nothing is left pending" test "$(deletes)" -eq "$deletes_before" -a ! -e "$STATE/grafana-admin-pending"

log "what the evidence scrub knows"
kept=0
missing=0
while read -r value; do
  [[ -n "$value" ]] || continue
  if grep -qxF -- "$value" "$STATE/evidence-scrub-values" 2>/dev/null; then kept=$((kept + 1)); else missing=$((missing + 1)); fi
done <"$WORK/rotated-out"
expect "every password a rotate replaced, $kept of them, is in evidence-scrub-values" test "$missing" -eq 0 -a "$kept" -ge 2

[[ "$failed" -eq 0 ]] || die "$failed of $((passed + failed)) checks on grafana-admin.sh failed"
ok "grafana-admin.sh: $passed checks passed against a stub cluster"
