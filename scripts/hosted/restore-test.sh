#!/usr/bin/env bash
# Restore the newest backup into an isolated namespace, prove it came back whole, show it had no way to live data, and remove it.
# A backup nobody has restored from is a hope, and a restore in place is the thing this exists to avoid having to find out about.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/restore-test.sh   on the VPS, from the node's own repositories
#   TARGET=plane-prod RESTORE_ON=kind scripts/hosted/restore-test.sh      in the local cluster, from this machine's off-VPS copy, which
#                                                                         is what makes off-VPS status complete. Touches no VPS
#   ONLY=plane-prod or ONLY=infisical    one of them, in place of both
#   KEEP=yes                             leave the namespace, to look at it. Then delete it by hand
#
# What it proves, from infrastructure/hosted/plane-prod/restore-test/prove.sh, in a pod of the isolated namespace:
#   every file against the hashes sealed with it, the objects among them,
#   the dump restores into an empty Postgres, on a socket in that pod and with no TCP at all,
#   row counts equal what the backup recorded, Plane's content hashes too, and every row marked uploaded has its object.
# And from here:
#   the namespace is default deny, and a pod in it times out on live data, on the API and on DNS, while the node reaches each,
#   the keys' fingerprints match the live ones, so this backup and its keys are a pair,
#   live workloads, volumes, Secrets and the list of live databases are the same after as before.
#
# Exit 0 proved, 1 not, 2 could not run: no backup yet, or no copy to read. A proof that did not run is never reported as passed.
#
# It refuses any namespace but restore-test-<14 digits>, because a restore's statements drop what they reach.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESTORE_ON="${RESTORE_ON:-vps}"
case "$RESTORE_ON" in
  vps | kind) ;;
  *)
    printf 'fail RESTORE_ON takes vps or kind, and got "%s"\n' "$RESTORE_ON" >&2
    exit 1
    ;;
esac

# Read before lib.sh re-roots them, because in kind they are the cluster this works on.
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
LOCAL_CLUSTER_KUBECONFIG="$KUBECONFIG"
LOCAL_CLUSTER_CONTEXT="$KUBE_CONTEXT"
LOCAL_CLUSTER_NODE="$NODE_CONTAINER"

HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=lib-restic.sh
source "$SCRIPT_DIR/lib-restic.sh"
# shellcheck source=../../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"

need_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name not found. Run: make setup"
  done
}
need_commands jq yq

TEMPLATES="$ROOT/infrastructure/hosted/plane-prod/restore-test"
# Pinned where the nightly pins them, read from there, so this restores with what sealed it.
BACKUP_MANIFESTS="$ROOT/gitops/clusters/plane-prod/platform/backup"
CURL_IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
RESTIC_IMAGE="$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "seal") | .image' "$BACKUP_MANIFESTS/plane-prod.yaml")"
SCRATCH="${RESTORE_SCRATCH:-40Gi}"
SETTLE="${RESTORE_SETTLE_SECONDS:-15}"

STAMP="$(date -u +%Y%m%d%H%M%S)"
NS="${RESTORE_NAMESPACE:-restore-test-$STAMP}"
# Nothing below runs against any other name, whatever this was given.
[[ "$NS" =~ ^restore-test-[0-9]{14}$ ]] || die "refusing namespace '$NS': only restore-test-<14 digits> may hold a restore"

if [[ "$RESTORE_ON" == kind ]]; then
  kc() { "$ROOT/.tools/bin/kubectl" --kubeconfig "$LOCAL_CLUSTER_KUBECONFIG" --context "$LOCAL_CLUSTER_CONTEXT" "$@"; }
  LIVE_NAMESPACES="plane-dev plane-prod-sim infisical"
  kc get --raw /readyz >/dev/null 2>&1 || die "the local cluster is not reachable. Run: make up"
  restic_need_local
else
  hosted_verify
  hosted_require_confirm "this restores a backup into a temporary namespace"
  LIVE_NAMESPACES="plane-prod infisical"
  [[ -s "$RESTIC_PASSWORD_LOCAL" ]] || die "${RESTIC_PASSWORD_LOCAL#"$ROOT"/} is missing. The recovery bundle holds a copy."
fi

FAILED=0
BLOCKED=0
EVIDENCE="$HOSTED_EVIDENCE_DIR/restore-test-plane-prod-$STAMP.json"
RESULTS='[]'
WORK="$(mktemp -d "$LOCAL_DIR/.restore-test.XXXXXX")"
PV_NAMES=""

row() { # verdict what [detail]
  case "$1" in
    FAIL) FAILED=$((FAILED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
  esac
  printf '%-8s %-64s %s\n' "$1" "$2" "${3:-}"
  RESULTS="$(jq -c --arg verdict "$1" --arg what "$2" --arg detail "${3:-}" '. + [{verdict: $verdict, what: $what, detail: $detail}]' <<<"$RESULTS")"
}

cleanup() {
  local rc=$? pv
  rm -rf "$WORK"
  if [[ "${KEEP:-}" == yes ]]; then
    warn "KEEP=yes, so namespace $NS and its volumes stay. Nothing but this run made them: delete them when done."
    return "$rc"
  fi
  # The namespace first: a PV stays until its claim is gone. Retain, so its folder is not touched by either.
  kc delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || warn "could not ask to delete namespace $NS. Delete it by hand."
  for pv in $PV_NAMES; do
    kc delete pv "$pv" --ignore-not-found --wait=false >/dev/null 2>&1 || warn "could not ask to delete PersistentVolume $pv. Delete it by hand."
  done
  return "$rc"
}
trap cleanup EXIT

# ------ What is live ---------------------------------------------------------------------------------------------------

# Everything that would change if this touched live data, and nothing that changes by itself: status and restarts are left out.
live_fingerprint() {
  local namespace
  for namespace in $LIVE_NAMESPACES; do
    kc -n "$namespace" get statefulsets,deployments,persistentvolumeclaims -o json 2>/dev/null |
      jq -r --arg ns "$namespace" '.items[] | "\($ns) \(.kind)/\(.metadata.name) uid=\(.metadata.uid) generation=\(.metadata.generation // "-")"' || true
    kc -n "$namespace" get secrets -o json 2>/dev/null |
      jq -r --arg ns "$namespace" '.items[] | "\($ns) Secret/\(.metadata.name) uid=\(.metadata.uid) version=\(.metadata.resourceVersion)"' || true
    live_databases "$namespace"
  done
}

live_postgres_pod() { # namespace: StatefulSet pod and container, if this namespace has one
  case "$1" in
    infisical) printf 'infisical-postgres-0 postgres' ;;
    *) printf 'plane-pgdb-wl-0 plane-pgdb' ;;
  esac
}

# The list of databases, from inside the live pod, read-only. The nightly's own scratch database comes and goes, so it does not count.
live_databases() { # namespace
  local pod container
  read -r pod container <<<"$(live_postgres_pod "$1")"
  kc -n "$1" get pod "$pod" >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2016  # expanded in the pod
  printf '%s databases: %s\n' "$1" "$(kc -n "$1" exec "$pod" -c "$container" -- sh -c 'psql -XAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT datname FROM pg_database ORDER BY 1"' 2>/dev/null |
    { grep -v '^scratch_' || true; } | tr '\n' ' ')"
}

# Rows a person could change while this runs, so a difference warns and does not fail. Recorded either way.
live_counts() {
  local namespace pod container
  for namespace in $LIVE_NAMESPACES; do
    [[ "$namespace" != infisical ]] || continue
    read -r pod container <<<"$(live_postgres_pod "$namespace")"
    kc -n "$namespace" get pod "$pod" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # expanded in the pod
    kc -n "$namespace" exec "$pod" -c "$container" -- sh -c 'psql -XAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM projects), (SELECT count(*) FROM issues), (SELECT count(*) FROM file_assets)"' 2>/dev/null |
      sed "s|^|$namespace users,projects,issues,file_assets: |" || true
  done
}

# Addresses a pod in the isolated namespace must not reach: each live database and Silo, the API, and DNS. Addresses, because it has
# no DNS, and a pod's own, because a headless Service has no other.
live_targets() {
  local namespace service port address
  while read -r namespace service port; do
    [[ -n "$namespace" ]] || continue
    address="$(kc -n "$namespace" get endpointslices -l "kubernetes.io/service-name=$service" -o json 2>/dev/null | jq -r '[.items[].endpoints[]?.addresses[0]][0] // ""' || true)"
    if [[ -n "$address" ]]; then printf '%s:%s\n' "$address" "$port"; fi
  done <<EOF
plane-prod plane-pgdb 5432
plane-prod plane-minio 9000
plane-dev plane-pgdb 5432
plane-prod-sim plane-pgdb 5432
infisical infisical-postgres 5432
EOF
  printf '%s:443\n' "$(kc -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
  printf '%s:53\n' "$(kc -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
}

# The node dials each address. No policy governs its own traffic, so an answer shows the target was up when the pod timed out on it.
node_dials() { # addresses as address:port, on stdin. Prints address:port ANSWERED or SILENT.
  local dial='
while IFS=: read -r address port; do
  [ -n "$address" ] || continue
  if out=$(timeout 3 bash -c "exec 3<>/dev/tcp/$address/$port" 2>&1); then echo "$address:$port ANSWERED"
  else case "$out" in *refused*) echo "$address:$port ANSWERED" ;; *) echo "$address:$port SILENT" ;; esac; fi
done'
  if [[ "$RESTORE_ON" == kind ]]; then
    docker exec -i "$LOCAL_CLUSTER_NODE" bash -c "$dial"
  else
    node_script "$dial"
  fi
}

# ------ The namespace --------------------------------------------------------------------------------------------------

make_namespace() {
  fill "NS=$NS" <"$TEMPLATES/namespace.yaml.tmpl" | kc apply -f - >/dev/null
  kc -n "$NS" create configmap prove --from-file=prove.sh="$TEMPLATES/prove.sh" >/dev/null
  if [[ "$RESTORE_ON" == vps ]]; then
    kc -n "$NS" create secret generic restic-password --from-file=password="$RESTIC_PASSWORD_LOCAL" >/dev/null
  fi
  # A policy needs a moment before it holds, and every pod after this must start under it.
  sleep "$SETTLE"
  row PASS "namespace $NS is default deny, with a quota" "PSA restricted, no route, no Application"
}

# Every line must time out from inside, while the node reaches it.
probe_no_route() {
  local targets
  targets="$(live_targets | tr '\n' ' ')"
  log "Can this namespace reach live data? Trying: $targets"
  printf '%s' "$targets" | tr ' ' '\n' >"$WORK/targets"
  node_dials <"$WORK/targets" >"$WORK/node-before" || warn "the node's dial failed, so a timeout below has no reference"
  fill "NS=$NS" "CURL_IMAGE=$CURL_IMAGE" "TARGETS=$targets" "SETTLE=$SETTLE" <"$TEMPLATES/probe-pod.yaml.tmpl" | kc apply -f - >/dev/null
  if ! kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=200s >/dev/null 2>&1; then
    row BLOCKED "a pod here cannot reach live data" "the probe did not finish: $(kc -n "$NS" get pod probe -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    return 0
  fi
  kc -n "$NS" logs probe >"$WORK/probe" 2>/dev/null || true
  node_dials <"$WORK/targets" >"$WORK/node-after" || true
  grep -q '^DONE' "$WORK/probe" || {
    row BLOCKED "a pod here cannot reach live data" "the probe gave no result"
    return 0
  }
  local address port code connect reference
  while read -r _ address port code connect; do
    reference="$(awk -v t="$address:$port" '$1 == t { print $2 }' "$WORK/node-before" "$WORK/node-after" | sort -u | tr '\n' ' ')"
    if awk -v t="${connect:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then
      row FAIL "$address:$port" "CONNECTED from the isolated namespace, so it has a route to live data"
    elif [[ "$code" == 7 ]]; then
      row FAIL "$address:$port" "refused, so the packet arrived: the isolated namespace has a route to it"
    elif [[ "$code" != 28 ]]; then
      row BLOCKED "$address:$port" "curl exited $code, which says nothing about the path"
    elif [[ "$reference" == "ANSWERED " ]]; then
      row PASS "no route to $address:$port" "timed out from here, while the node reached it"
    else
      row BLOCKED "no route to $address:$port" "timed out from here, and the node read '$reference', so it may just be down"
    fi
  done < <(grep '^RESULT ' "$WORK/probe")
}

# ------ One restore ----------------------------------------------------------------------------------------------------

postgres_image_of() { # source
  yq -r '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "postgres") | .image' "$BACKUP_MANIFESTS/$1.yaml"
}

# Stream a restored copy from this machine into the pod's receive container. It waits for the marker, then prove runs.
stream_from_copy() { # source job
  local source="$1" job="$2" pod="" deadline=$((SECONDS + 600)) tmp backup snapshot
  tmp="$WORK/$source"
  mkdir -p "$tmp"
  restic -r "$OFFSITE_DIR/$source" --password-file "$RESTIC_PASSWORD_LOCAL" restore latest --host "$source" --tag wayline --target "$tmp" --verify >/dev/null
  backup="$(dirname "$(find "$tmp" -type f -name SHA256SUMS | head -1)")"
  snapshot="$(restic -r "$OFFSITE_DIR/$source" --password-file "$RESTIC_PASSWORD_LOCAL" snapshots --host "$source" --tag wayline --latest 1 --json | jq -r '.[0].short_id')"
  printf '%s' "$snapshot" >"$WORK/$source.snapshot"
  until [[ -n "$pod" ]]; do
    pod="$(kc -n "$NS" get pods -l "job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ $SECONDS -lt $deadline ]] || die "no pod for Job $job"
    if [[ -z "$pod" ]]; then sleep 2; fi
  done
  until [[ "$(kc -n "$NS" get pod "$pod" -o json | jq -r '.status.initContainerStatuses[0].state.running != null')" == true ]]; do
    [[ $SECONDS -lt $deadline ]] || die "the receive container did not start: $(kc -n "$NS" get pod "$pod" -o jsonpath='{.status.initContainerStatuses[0].state}')"
    sleep 2
  done
  COPYFILE_DISABLE=1 tar -C "$backup" -cf - . | kc -n "$NS" exec -i "$pod" -c receive -- tar -xf - -C /scratch/restored ||
    die "could not stream the restored copy into $pod"
  kc -n "$NS" exec "$pod" -c receive -- touch /scratch/.received
  rm -rf "$tmp"
}

# Reads the fingerprints a proof printed against the keys this backup must pair with.
check_fingerprints() { # source
  local source="$1" line plane_fp infisical_fp live
  line="$(grep -E 'PROOF fingerprint' "$WORK/$source.log" | head -1 || true)"
  plane_fp="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "fingerprint") print $(i + 1) }' <<<"$line")"
  infisical_fp="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "fingerprint") print $(i + 2) }' <<<"$line")"
  case "$source" in
    infisical)
      if [[ ! -s "$LOCAL_DIR/secret-zero/ENCRYPTION_KEY" ]]; then
        row BLOCKED "infisical: backup and ENCRYPTION_KEY are a pair" "no secret zero on this machine to compare with"
      elif [[ "$(hosted_sha256 <"$LOCAL_DIR/secret-zero/ENCRYPTION_KEY" | cut -c1-16)" == "${plane_fp:-$infisical_fp}" ]]; then
        row PASS "infisical: backup and ENCRYPTION_KEY are a pair" "the fingerprints match"
      else
        row FAIL "infisical: backup and ENCRYPTION_KEY are a pair" "the fingerprints differ, so this machine's key cannot read this dump"
      fi
      ;;
    plane-prod)
      if [[ "$RESTORE_ON" == kind ]]; then
        # Not what this run is for, which is the copy, so it says so and does not count.
        row SKIP "plane-prod: backup and SECRET_KEY are a pair" "only the VPS holds the live key, and a run there checks this"
        return 0
      fi
      live="$(kc -n plane-prod get secret plane-app-keys -o json 2>/dev/null | jq -j '.data.SECRET_KEY // empty | @base64d' | hosted_sha256 | cut -c1-16 || true)"
      if [[ "$live" == "$plane_fp" ]]; then
        row PASS "plane-prod: backup and SECRET_KEY are a pair" "the fingerprints match"
      else
        row FAIL "plane-prod: backup and SECRET_KEY are a pair" "the fingerprints differ, so encrypted rows in this dump would not decrypt"
      fi
      ;;
  esac
}

restore_one() { # source
  local source="$1" job="prove-$1" pv="" state pg_image
  pg_image="$(postgres_image_of "$source")"
  [[ -n "$pg_image" ]] || die "could not read the Postgres image from $BACKUP_MANIFESTS/$source.yaml"

  if [[ "$RESTORE_ON" == vps ]]; then
    if ! node_ssh_quiet "sudo -n test -e $HOSTED_BACKUP_ROOT/$source/restic/config"; then
      row BLOCKED "$source: restore" "no repository on the node yet. Run: make remote-backup TARGET=plane-prod CONFIRM=plane-prod"
      return 0
    fi
    pv="$NS-$source"
    PV_NAMES="$PV_NAMES $pv"
    fill "PV=$pv" "NS=$NS" "REPO_PATH=$HOSTED_BACKUP_ROOT/$source/restic" <"$TEMPLATES/repo-volume.yaml.tmpl" | kc apply -f - >/dev/null
    fill "NS=$NS" "SOURCE=$source" "SCRATCH=$SCRATCH" "RESTIC_IMAGE=$RESTIC_IMAGE" "PG_IMAGE=$pg_image" <"$TEMPLATES/prove-job.yaml.tmpl" |
      yq 'del(.spec.template.spec.initContainers[] | select(.name == "receive"))' |
      kc apply -f - >/dev/null
  else
    if [[ ! -d "$OFFSITE_DIR/$source" ]]; then
      row BLOCKED "$source: restore" "no off-VPS copy on this machine. Run: make remote-pull-backups TARGET=plane-prod"
      return 0
    fi
    fill "NS=$NS" "SOURCE=$source" "SCRATCH=$SCRATCH" "RESTIC_IMAGE=$RESTIC_IMAGE" "PG_IMAGE=$pg_image" <"$TEMPLATES/prove-job.yaml.tmpl" |
      yq 'del(.spec.template.spec.initContainers[] | select(.name == "fetch"))
        | del(.spec.template.spec.volumes[] | select(.name == "repo" or .name == "restic-password"))' |
      kc apply -f - >/dev/null
    stream_from_copy "$source" "$job"
  fi

  log "Proving $source in $NS"
  state="$(hosted_wait_job "$NS" "$job" 7200)"
  kc -n "$NS" logs "job/$job" --all-containers --prefix --tail=-1 >"$WORK/$source.log" 2>/dev/null || true
  grep -E 'PROOF|BLOCKED' "$WORK/$source.log" | sed 's/^\[[^]]*\] //' || true
  if grep -q 'BLOCKED no snapshot' "$WORK/$source.log"; then
    row BLOCKED "$source: restore" "the repository holds no snapshot of it yet"
    return 0
  fi
  if [[ "$state" != ok ]]; then
    row FAIL "$source: restore" "Job $job is $state: $(grep -E 'PROOF-FAIL' "$WORK/$source.log" | sed 's/^.*PROOF-FAIL //' | head -1)"
    grep -v PROOF "$WORK/$source.log" | tail -15 || true
    return 0
  fi
  local files tables
  read -r files tables <<<"$(sed -n 's/^.*PROOF-RESULT pass //p' "$WORK/$source.log" | head -1)"
  row PASS "$source: restored, and proved" "$files files match their hashes, $tables tables match their recorded counts"
  check_fingerprints "$source"
  if [[ "$RESTORE_ON" == kind && -s "$WORK/$source.snapshot" ]]; then
    offsite_record "$source" laptop "$(cat "$WORK/$source.snapshot")" "$files" "$(sed -n 's/^.*PROOF manifest id=[^ ]* created_at=//p' "$WORK/$source.log" | head -1)" "restore-test in the local cluster"
    ok "recorded: $source restored from this machine's off-VPS copy"
  fi
}

# ------ The run --------------------------------------------------------------------------------------------------------

SOURCES="${ONLY:-infisical plane-prod}"
for source in $SOURCES; do
  case "$source" in
    infisical | plane-prod) ;;
    *) die "ONLY takes infisical or plane-prod, and got '$source'" ;;
  esac
done

log "Restore test in $NS, on $RESTORE_ON"
live_fingerprint | sort >"$WORK/live-before"
live_counts | sort >"$WORK/counts-before"

make_namespace
probe_no_route
for source in $SOURCES; do
  restore_one "$source"
done

live_fingerprint | sort >"$WORK/live-after"
live_counts | sort >"$WORK/counts-after"
if diff "$WORK/live-before" "$WORK/live-after" >"$WORK/live-diff"; then
  row PASS "live data untouched" "$(grep -c '' "$WORK/live-after" | tr -d ' ') live objects and database lists read the same after as before"
else
  row FAIL "live data untouched" "something live changed while this ran. It may be a rollout, or not this: read the diff"
  sed 's/^/    /' "$WORK/live-diff"
fi
if ! diff "$WORK/counts-before" "$WORK/counts-after" >/dev/null; then
  warn "live row counts moved while this ran. This namespace had no route to them, so a person or a job did that."
fi

jq -n --arg ns "$NS" --arg on "$RESTORE_ON" --arg sources "$SOURCES" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson failed "$FAILED" --argjson blocked "$BLOCKED" --argjson rows "$RESULTS" \
  '{namespace: $ns, on: $on, sources: ($sources | split(" ")), finished_at: $at, failed: $failed, blocked: $blocked, rows: $rows}' >"$EVIDENCE"
log "Evidence: ${EVIDENCE#"$ROOT"/}"

if [[ "$FAILED" -gt 0 ]]; then
  warn "restore test: $FAILED FAILED, $BLOCKED BLOCKED"
  exit 1
elif [[ "$BLOCKED" -gt 0 ]]; then
  warn "restore test BLOCKED: $BLOCKED could not run, and none failed. That is not a pass."
  exit 2
fi
ok "restore test passed"
