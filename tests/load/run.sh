#!/usr/bin/env bash
# Run the k6 load test (5, 10 then 20 VUs, 3 minutes each) in the cluster and record CPU, memory and
# disk through it into .local/evidence-raw/load-<run>/results.json.
#
#   tests/load/run.sh dev               realistic pass, with think time
#   THINK=0 tests/load/run.sh dev       saturation pass
#
# Dev only: tests/e2e/smoke.py must have run, because the test signs in with the account it created.
# In the cluster, so the Docker port-mapping layer is not part of the measurement; the NetworkPolicy
# in gitops/platform/network-policies/plane-dev-loadtest.yaml allows the pod labelled k6 to reach Traefik.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=../../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"

K6_IMAGE="docker.io/grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8"
SAMPLE_SECONDS=15
# k6 runs three 3-minute steps with up to 20s of grace each, plus sign-in.
RUN_TIMEOUT=780

accept_assignments "ENV THINK" "$@"
for arg in "$@"; do case "$arg" in *=*) ;; *) ENV="$arg" ;; esac; done
ENV="${ENV:-dev}"
select_env "$ENV"
[[ "$ENV_NAME" == dev ]] || die "the load test runs in dev only: it creates work items, and only dev has its NetworkPolicy"
THINK="${THINK:-1}"
[[ "$THINK" =~ ^[0-9]+$ ]] || die "THINK must be a whole number of seconds, got '$THINK'"

guard_disk
need_cluster
umask 077

accounts="$LOCAL_DIR/test-accounts.env"
account_value() { # key. grep rather than source: the file is data.
  { grep -E "^$1=" "$accounts" 2>/dev/null || true; } | head -1 | cut -d= -f2-
}
plane_email="$(account_value PLANE_DEV_ADMIN_EMAIL)"
plane_password="$(account_value PLANE_DEV_ADMIN_PASSWORD)"
[[ -n "$plane_email" && -n "$plane_password" ]] || die "no dev account in $accounts. Run 'make test-e2e ENV=dev' first."

RUN="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOWER="$(printf '%s' "$RUN" | tr '[:upper:]' '[:lower:]')"
JOB="k6-$RUN_LOWER"
OUT="$LOCAL_DIR/evidence-raw/load-$RUN"
mkdir -p "$OUT"
samples="$OUT/samples.jsonl"
sampler_pid=""

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$sampler_pid" ]]; then kill "$sampler_pid" 2>/dev/null || true; fi
  # These two exist only for this run. The Secret holds the password, so it goes first.
  kc -n "$NS" delete secret k6-auth --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$NS" delete configmap k6-script --ignore-not-found >/dev/null 2>&1 || true
  [[ $rc -eq 0 ]] || warn "load test did not finish cleanly. What was captured is in $OUT"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One JSON line per sample. docker stats is the VM's view of the node, top is per container, df -k
# on /var is the VM's real growth, and free_disk_gib is the host, which the VM cannot see.
sample() {
  local node vm_used host_free pods
  node="$(docker stats --no-stream --format '{{json .}}' "$NODE_CONTAINER" 2>/dev/null || true)"
  [[ -n "$node" ]] || node='{}'
  vm_used="$(docker exec "$NODE_CONTAINER" df -k /var 2>/dev/null | awk 'NR==2{print $3}' || true)"
  host_free="$(free_disk_gib)"
  pods="$(kc top pods -n "$NS" --containers --no-headers 2>/dev/null \
    | awk '{printf "%s{\"pod\":\"%s\",\"container\":\"%s\",\"cpu\":\"%s\",\"memory\":\"%s\"}", (NR>1?",":""), $1, $2, $3, $4}' || true)"
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson node "$node" \
    --arg vm_used "${vm_used:-0}" --arg host_free "${host_free:-0}" --argjson pods "[${pods}]" \
    '{at: $at, node_cpu: $node.CPUPerc, node_memory: $node.MemUsage, vm_var_used_kib: ($vm_used | tonumber),
      host_free_gib: ($host_free | tonumber), containers: $pods}'
}

snapshot() { # name. What sampling does not cover, kept verbatim for the write-up.
  kc top pods -A --containers > "$OUT/top-$1.txt" 2>&1 || true
  docker exec "$NODE_CONTAINER" sh -c 'du -sh /var/local-path-provisioner/* 2>/dev/null' > "$OUT/pv-$1.txt" 2>&1 || true
  docker system df > "$OUT/docker-df-$1.txt" 2>&1 || true
  du -sh "$LOCAL_DIR"/backups/* > "$OUT/backups-$1.txt" 2>/dev/null || true
}

log "Recording the starting state in $OUT"
snapshot before
sample >> "$samples"

kc -n "$NS" create configmap k6-script --from-file=plane.js="$ROOT/tests/load/plane.js" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
# Through stdin, so the password is never an argument that ps could show.
{
  printf 'PLANE_EMAIL=%s\n' "$plane_email"
  printf 'PLANE_PASSWORD=%s\n' "$plane_password"
} | kc -n "$NS" create secret generic k6-auth --from-env-file=/dev/stdin --dry-run=client -o yaml | kc apply -f - >/dev/null

# A sample that fails is a gap in the record, not a reason to stop the test.
( while :; do sleep "$SAMPLE_SECONDS"; sample >> "$samples" || true; done ) &
sampler_pid=$!

log "Running k6: 5, 10 then 20 VUs at THINK=$THINK. About 10 minutes."
T_START="$(date -u +%s)"
k6_rc=0
fill "JOB=$JOB" "NS=$NS" "K6_IMAGE=$K6_IMAGE" "PLANE_HOST=$PLANE_HOST" "RUN=$RUN_LOWER" "THINK=$THINK" <<'YAML' > "$OUT/job.yaml"
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: k6
spec:
  backoffLimit: 0 # a retry would double the load and the work items
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345 # the image's own user
        runAsGroup: 12345
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: script
          configMap: { name: k6-script }
        - name: tmp
          emptyDir: { sizeLimit: 16Mi }
      containers:
        - name: k6
          image: __K6_IMAGE__
          imagePullPolicy: IfNotPresent
          args: [run, --quiet, --no-color, /scripts/plane.js]
          env:
            - { name: BASE_URL, value: "http://traefik.traefik.svc.cluster.local" }
            - { name: PLANE_HOST, value: "__PLANE_HOST__" }
            - { name: RUN_ID, value: "__RUN__" }
            - { name: THINK, value: "__THINK__" }
            - { name: K6_NO_USAGE_REPORT, value: "true" } # no route out, and it would only delay the exit
            - { name: PLANE_EMAIL, valueFrom: { secretKeyRef: { name: k6-auth, key: PLANE_EMAIL } } }
            - { name: PLANE_PASSWORD, valueFrom: { secretKeyRef: { name: k6-auth, key: PLANE_PASSWORD } } }
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: script, mountPath: /scripts, readOnly: true }
            - { name: tmp, mountPath: /tmp }
YAML
run_job "$NS" "$JOB" "$RUN_TIMEOUT" < "$OUT/job.yaml" > "$OUT/k6.log" 2>&1 || k6_rc=$?
T_END="$(date -u +%s)"

kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""
sample >> "$samples"
snapshot after

# The summary sits between markers in the log; --prefix put the pod name in front of each line.
sed -n '/@@K6-SUMMARY-BEGIN@@/,/@@K6-SUMMARY-END@@/p' "$OUT/k6.log" \
  | sed -e '1d' -e '$d' -e 's/^\[[^]]*\] //' > "$OUT/k6-summary.json" || true
# A run killed mid-write leaves a partial line, which must not cost the rest of the results.
jq empty "$OUT/k6-summary.json" 2>/dev/null || : > "$OUT/k6-summary.json"

log "Reading what Prometheus saw"
window="$((T_END - T_START + 60))s"
at="$T_END"
query() { # name promql. A failed query records null rather than losing the whole results file.
  local value
  value="$(curl -fsS -m 30 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$2" --data-urlencode "time=$at" 2>/dev/null \
    | jq -c '.data.result' 2>/dev/null || echo null)"
  jq -cn --arg name "$1" --argjson value "${value:-null}" '{($name): $value}'
}
CONTAINERS="namespace=\"$NS\",container!=\"\",container!=\"POD\""
# Traefik's service label for an IngressRoute is <namespace>-<route>-<sha256 of match, 20 hex>@kubernetescrd,
# so it never names the backend (measured: monitoring-prometheus-fee5881c234c340f00a9@kubernetescrd).
# Hash each match that reaches plane-api, or these three queries come back empty and look like no traffic.
api_services="$(kc -n "$NS" get ingressroute plane-ingress -o json \
  | jq -r '.spec.routes[] | select(.services[0].name == "plane-api") | .match' \
  | while IFS= read -r match; do
      printf '%s-plane-ingress-%s@kubernetescrd\n' "$NS" "$(printf '%s' "$match" | shasum -a 256 | cut -c1-20)"
    done | paste -sd '|' -)"
API="service=~\"$api_services\""
{
  query peak_memory_bytes_by_pod "max_over_time(sum by (pod) (container_memory_working_set_bytes{$CONTAINERS})[$window:15s])"
  query avg_cpu_cores_by_pod "avg_over_time(sum by (pod) (rate(container_cpu_usage_seconds_total{$CONTAINERS}[1m]))[$window:15s])"
  query peak_cpu_cores_by_pod "max_over_time(sum by (pod) (rate(container_cpu_usage_seconds_total{$CONTAINERS}[1m]))[$window:15s])"
  query throttled_share_by_pod "sum by (pod) (increase(container_cpu_cfs_throttled_periods_total{namespace=\"$NS\"}[$window])) / sum by (pod) (increase(container_cpu_cfs_periods_total{namespace=\"$NS\"}[$window]))"
  query restarts_by_pod "sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace=\"$NS\"}[$window]))"
  query api_requests_per_second "sum(rate(traefik_service_requests_total{$API}[$window]))"
  query api_p95_seconds "histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket{$API}[$window])))"
  query api_5xx_total "sum(increase(traefik_service_requests_total{$API,code=~\"5..\"}[$window]))"
  query celery_ready_peak "max_over_time(rabbitmq_detailed_queue_messages_ready{namespace=\"$NS\",queue=\"celery\"}[$window])"
  query database_growth_bytes "delta(pg_database_size_bytes{namespace=\"$NS\",datname!~\"template.*|postgres\"}[$window])"
  query vm_memory_peak_bytes "max_over_time((node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)[$window:15s])"
  query monitoring_peak_memory_bytes "sum(max_over_time(container_memory_working_set_bytes{namespace=\"monitoring\",container!=\"\",container!=\"POD\"}[$window]))"
} | jq -cs 'add' > "$OUT/prometheus.json"

k6_status=PASS
[[ $k6_rc -eq 0 ]] || k6_status=FAIL
jq -n --arg run "$RUN" --arg ns "$NS" --arg status "$k6_status" --argjson think "$THINK" \
  --argjson started "$T_START" --argjson ended "$T_END" \
  --slurpfile samples "$samples" --slurpfile prometheus "$OUT/prometheus.json" \
  --slurpfile summary "$OUT/k6-summary.json" \
  '{run: $run, namespace: $ns, k6_thresholds: $status, think_seconds: $think, started_epoch: $started, ended_epoch: $ended,
    k6: ($summary[0] // null | if . then {metrics: .metrics} else null end),
    prometheus: ($prometheus[0] // null),
    disk: {vm_var_used_kib: {before: ($samples[0].vm_var_used_kib), after: ($samples[-1].vm_var_used_kib)},
           host_free_gib: {before: ($samples[0].host_free_gib), after: ($samples[-1].host_free_gib)}},
    samples: $samples}' > "$OUT/results.json"

ok "results: $OUT/results.json"
if [[ $k6_rc -ne 0 ]]; then
  grep -v '@@K6-SUMMARY\|^{' "$OUT/k6.log" | tail -20 >&2 || true
  die "k6 failed a threshold or did not finish. Numbers above are still valid as a measurement."
fi
