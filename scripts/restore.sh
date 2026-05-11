#!/usr/bin/env bash
# Restore a backup taken by scripts/backup.sh into the environment it came from.
#
#   scripts/restore.sh dev <backup-id|latest>
#   ENV=dev BACKUP=<backup-id|latest> CONFIRM=yes scripts/restore.sh
#
# CONFIRM=yes                    needed to overwrite an environment that already holds data
# ALLOW_SECRET_KEY_MISMATCH=yes  proceed although the live key differs from the backup's. Encrypted
#                                rows then decrypt silently to "", so the proofs fail and the script
#                                exits non-zero even though the data is back.
#
# Every refusal comes before anything is touched. Order for a Plane environment:
#   verify checksums and fingerprint, refuse, pause auto-sync (root first), stop the apps, restore
#   Postgres and check its counts, sync objects, flush Valkey, purge RabbitMQ, run the migrator,
#   start the apps, prove. Auto-sync comes back at the end, including on failure.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"

accept_assignments "ENV BACKUP CONFIRM ALLOW_SECRET_KEY_MISMATCH" "$@"
positional=()
for arg in "$@"; do case "$arg" in *=*) ;; *) positional+=("$arg") ;; esac; done
if [[ ${#positional[@]} -ge 1 && -n "${positional[0]}" ]]; then ENV="${positional[0]}"; fi
if [[ ${#positional[@]} -ge 2 && -n "${positional[1]}" ]]; then BACKUP="${positional[1]}"; fi
[[ -n "${ENV:-}" && -n "${BACKUP:-}" ]] || die "usage: $0 dev|prod-sim|infisical <backup-id|latest> [CONFIRM=yes]"

select_env "$ENV"
guard_disk
need_cluster
umask 077

backups_dir="$LOCAL_DIR/backups/$ENV_NAME"
if [[ "$BACKUP" == latest ]]; then
  # Names are UTC timestamps and globs sort, so the last finished one is the newest.
  BACKUP=""
  for candidate in "$backups_dir"/[0-9]*T[0-9]*Z; do
    if [[ -f "$candidate/manifest.json" ]]; then BACKUP="${candidate##*/}"; fi
  done
  [[ -n "$BACKUP" ]] || die "no finished backups in $backups_dir"
fi
BACKUP_ID="$(basename "$BACKUP")"
backup_dir="$backups_dir/$BACKUP_ID"
manifest="$backup_dir/manifest.json"
[[ -f "$manifest" ]] || die "no manifest at $manifest. Each environment's PVC mounts only its own folder, so a backup restores only into the environment that took it."

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JOB_SUFFIX="$(printf '%s' "$STAMP" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$LOCAL_DIR/evidence-raw"
evidence="$LOCAL_DIR/evidence-raw/restore-$ENV_NAME-$STAMP.json"
steps_file="$(mktemp "$LOCAL_DIR/.restore-steps.XXXXXX")"
secret_tmp=""
sentinel_tmp=""

record() { # step status detail. Status is PASS, FAIL or NOT RUN, as the contract requires.
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$steps_file"
  case "$2" in
    PASS) ok "$1: ${3:-}" ;;
    FAIL) warn "$1 FAILED: ${3:-}" ;;
    *) warn "$1 $2: ${3:-}" ;;
  esac
}

on_exit() {
  local rc=$?
  trap - EXIT
  argo_resume
  [[ -z "$secret_tmp" ]] || rm -f "$secret_tmp"
  [[ -z "$sentinel_tmp" ]] || rm -f "$sentinel_tmp"
  jq -Rn --arg env "$ENV_NAME" --arg backup "$BACKUP_ID" --arg at "$STAMP" --argjson rc "$rc" '
    { environment: $env, backup: $backup, started_at: $at,
      result: (if $rc == 0 then "PASS" else "FAIL" end),
      steps: [inputs | split("\t") | {step: .[0], status: .[1], detail: .[2]}] }' \
    < "$steps_file" > "$evidence" || true
  rm -f "$steps_file"
  if [[ $rc -eq 0 ]]; then
    ok "restore of $BACKUP_ID into $ENV_NAME complete. Evidence: $evidence"
  else
    warn "restore of $BACKUP_ID into $ENV_NAME FAILED. Auto-sync is back on, so Argo CD restarts the apps against whatever was restored. Evidence: $evidence"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ----- Refusals. Nothing below this block runs until all of them pass. ------------------------

log "Verifying $BACKUP_ID"
(cd "$backup_dir" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "checksum verification failed for $backup_dir: refusing to restore"
record checksums PASS "$(wc -l < "$backup_dir/SHA256SUMS" | tr -d ' ') files match"

[[ "$(jq -r .env "$manifest")" == "$ENV_NAME" ]] || die "manifest says env $(jq -r .env "$manifest"), not $ENV_NAME"

live_key_fp() { # secret key. Byte-exact: no shell variable holds the value and no newline is added.
  kc -n "$NS" get secret "$1" -o json | jq -je --arg k "$2" '.data[$k] | @base64d' | shasum -a 256 | cut -c1-16
}

check_fingerprint() { # manifest-field secret key
  local want have
  want="$(jq -r ".$1" "$manifest")"
  have="$(live_key_fp "$2" "$3")" || die "cannot read $3 from Secret $2 in $NS"
  if [[ "$want" == "$have" ]]; then
    record key-fingerprint PASS "$3 matches the backup"
  elif [[ "${ALLOW_SECRET_KEY_MISMATCH:-}" == yes ]]; then
    record key-fingerprint FAIL "$3 differs from the backup, proceeding on ALLOW_SECRET_KEY_MISMATCH=yes"
  else
    die "$3 differs from the one this backup was taken with (live $have, backup $want). Encrypted data would decrypt silently to nothing. Restore the right key, or pass ALLOW_SECRET_KEY_MISMATCH=yes to accept the loss."
  fi
}

# Reports whether the target holds data. A Job rather than exec, for the same network path a backup
# uses. A failed listing stops the restore: it must not read as "empty" and skip the guard.
inspect_target() { # pg-image db-service db-secret
  local job="plane-restore-guard-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "PG_IMAGE=$1" "DB_SERVICE=$2" "DB_SECRET=$3" <<'YAML' | run_job "$NS" "$job" 300
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: database
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: PGHOST, value: __DB_SERVICE__ }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: __DB_SECRET__, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 64Mi }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              if [ "$(psql -XAt -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$POSTGRES_DB'")" = 0 ]; then
                echo USERS=0
              elif [ "$(psql -XAt -d "$POSTGRES_DB" -c "SELECT to_regclass('public.users') IS NOT NULL")" = t ]; then
                echo "USERS=$(psql -XAt -d "$POSTGRES_DB" -c 'SELECT count(*) FROM users')"
              else
                echo USERS=0
              fi
YAML
}

inspect_bucket() {
  local job="plane-restore-guard-objects-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "RCLONE_IMAGE=$RCLONE_IMAGE" <<'YAML' | run_job "$NS" "$job" 300
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 64Mi }
      containers:
        - name: bucket
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: HOME, value: /tmp }
            - { name: RCLONE_CONFIG, value: /tmp/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
          command: [/bin/sh, -c]
          args:
            - |
              set -u
              rclone lsf -R --files-only "dst:$BUCKET" > /tmp/objects
              rc=$?
              case "$rc" in
                0) echo "OBJECTS=$(wc -l < /tmp/objects | tr -d ' ')" ;;
                3) echo OBJECTS=0 ;; # rclone's exit code for "directory not found": no bucket yet
                *) exit "$rc" ;;
              esac
YAML
}

refuse_if_not_empty() { # users objects
  if [[ "$1" -eq 0 && "$2" -eq 0 ]]; then
    record overwrite-guard PASS "target is empty"
  elif [[ "${CONFIRM:-}" == yes ]]; then
    record overwrite-guard PASS "target holds $1 users and $2 objects, overwriting on CONFIRM=yes"
  else
    die "$NS already holds data ($1 users, $2 objects). Re-run with CONFIRM=yes to overwrite it."
  fi
}

live_image() { # kind name container
  kc -n "$NS" get "$1" "$2" -o json \
    | jq -r --arg c "$3" '.spec.template.spec.containers[] | select(.name == $c) | .image'
}

# ----- Plane ------------------------------------------------------------------------------------

APP_DEPLOYMENTS="plane-api-wl plane-worker-wl plane-beat-worker-wl plane-live-wl"

no_app_pods() {
  [[ -z "$(kc -n "$NS" get pods -l 'app.kubernetes.io/component in (api,worker,beat,live)' -o name 2>/dev/null)" ]]
}

desired_replicas() { # deployment. From Git, so a run that died at zero cannot make zero the target.
  D="$1" yq -N 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.replicas // 1' \
    "$ROOT/gitops/environments/$ENV_NAME/manifests.yaml"
}

restore_data() { # pg-image
  local job="plane-restore-$JOB_SUFFIX"
  log "Restoring Postgres and objects from $BACKUP_ID"
  fill "JOB=$job" "NS=$NS" "ID=$BACKUP_ID" "PG_IMAGE=$1" "RCLONE_IMAGE=$RCLONE_IMAGE" <<'YAML' | run_job "$NS" "$job" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: backups, readOnly: true }
        - name: work
          emptyDir: { sizeLimit: 64Mi }
      initContainers:
        - name: postgres
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: PGHOST, value: plane-pgdb }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: plane-pgdb, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              B="/backups/$BACKUP_ID"
              TAB="$(printf '\t')"
              # dropdb and not pg_restore --clean, so tables newer than the dump cannot survive.
              # --force, because the exporter holds a connection. --single-transaction makes the
              # restore all or nothing, and rules out --jobs.
              dropdb --maintenance-db=postgres --force --if-exists "$POSTGRES_DB"
              createdb --maintenance-db=postgres "$POSTGRES_DB"
              pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d "$POSTGRES_DB" "$B/postgres/plane.dump"
              vacuumdb --analyze-only "$POSTGRES_DB"

              # The apps are down, so this must equal the scratch restore exactly.
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" -f "$B/postgres/rowcounts.sql" > /work/rowcounts.tsv
              diff "$B/postgres/rowcounts.tsv" /work/rowcounts.tsv
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" -f "$B/postgres/content.sql" > /work/content.tsv
              diff "$B/postgres/content.tsv" /work/content.tsv
              echo "GATE1 ok: $(wc -l < /work/rowcounts.tsv) tables equal the backup"

              # For the gate below: a row the app believes is uploaded must have its object.
              psql -XAt -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" \
                -c "SELECT asset FROM file_assets WHERE is_uploaded AND NOT is_deleted AND deleted_at IS NULL" \
                | LC_ALL=C sort > /work/keys.txt
        - name: objects
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: HOME, value: /work }
            - { name: RCLONE_CONFIG, value: /work/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 500m, memory: 192Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              # sync and not copy: objects that are not in the backup must go.
              rclone sync "/backups/$BACKUP_ID/objects" "dst:$BUCKET" --metadata --checksum --transfers 4 --stats 0
              rclone check "/backups/$BACKUP_ID/objects" "dst:$BUCKET" --one-way --download
              echo "objects: sync and downloading check ok"
      containers:
        # Catches a database and a bucket that came from different backups.
        - name: gate
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: HOME, value: /work }
            - { name: RCLONE_CONFIG, value: /work/rclone.conf }
            - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_DST_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              rclone lsf -R --files-only "dst:$BUCKET" | LC_ALL=C sort > /work/objects.txt
              missing="$(LC_ALL=C comm -23 /work/keys.txt /work/objects.txt)"
              if [ -n "$missing" ]; then
                echo "GATE2 failed: rows marked uploaded with no object:" >&2
                echo "$missing" >&2
                exit 1
              fi
              echo "GATE2 ok: $(wc -l < /work/keys.txt) uploaded assets all have an object"
YAML
}

# wait_for_migrations blocks the API, worker and beat forever on an unapplied migration, and the
# Argo hook does not run again here. The rendered Job is the template, so this cannot differ from
# what Argo CD runs, except that it uses the image the API is running now.
run_migrator() {
  local job="plane-restore-migrate-$JOB_SUFFIX" api_image
  api_image="$(live_image deployment plane-api-wl plane-api)"
  log "Running the migrator"
  JOB_NAME="$job" API_IMAGE="$api_image" yq '
      select(.kind == "Job" and (.metadata.name | test("^plane-api-migrate")))
      | .metadata.name = strenv(JOB_NAME)
      | del(.metadata.annotations)
      | .spec.ttlSecondsAfterFinished = 86400
      | .spec.template.spec.containers[0].image = strenv(API_IMAGE)
    ' "$ROOT/gitops/environments/$ENV_NAME/manifests.yaml" | run_job "$NS" "$job" 900
}

prove_decrypt() {
  local expected out sentinel undecryptable rows
  expected="$(jq -r '.encrypted_sentinel // "none"' "$manifest")"
  out="$(plane_python "
from plane.license.models import InstanceConfiguration as C
from plane.license.utils.encryption import decrypt_data as d
row = C.objects.filter(key='$ENCRYPTED_SENTINEL_KEY').first()
print('@@SENTINEL=' + ('missing' if row is None else ('ok' if d(row.value) == '$ENCRYPTED_SENTINEL_VALUE' else 'wrong')))
rows = C.objects.filter(is_encrypted=True).exclude(value__isnull=True).exclude(value='')
print('@@ROWS=%d' % rows.count())
print('@@UNDECRYPTABLE=' + ','.join(c.key for c in rows if not d(c.value)))
")" || true
  sentinel="$(printf '%s\n' "$out" | sed -n 's/^SENTINEL=//p')"
  rows="$(printf '%s\n' "$out" | sed -n 's/^ROWS=//p')"
  undecryptable="$(printf '%s\n' "$out" | sed -n 's/^UNDECRYPTABLE=//p')"

  [[ -n "$rows" ]] || { record proof-decrypt FAIL "could not run the check in the API pod"; return 1; }
  if [[ "$expected" != ok ]]; then
    record proof-encrypted-sentinel "NOT RUN" "this backup was taken with no encrypted sentinel"
  elif [[ "$sentinel" == ok ]]; then
    record proof-encrypted-sentinel PASS "sentinel row decrypts to its seeded value"
  else
    record proof-encrypted-sentinel FAIL "sentinel row is $sentinel"
    return 1
  fi
  if [[ -n "$undecryptable" ]]; then
    record proof-no-empty-decrypt FAIL "these rows decrypt to nothing: $undecryptable"
    return 1
  fi
  record proof-no-empty-decrypt PASS "$rows encrypted rows all decrypt"
}

# tests/e2e/smoke.py owns these checks, so a restore proves exactly what the smoke test proves: the
# sentinel work item through the API, the attachment's checksum through a presigned URL, and a
# worker finishing a new job. The token comes from the restored database, which also proves the
# tokens survived, and it stays in a 0600 file for the length of the call.
prove_sentinel() {
  local slug token prefix rc=0
  slug="$(jq -r '.sentinel.slug // ""' "$manifest")"
  if [[ -z "$slug" ]]; then
    record proof-sentinel "NOT RUN" "this backup was taken before tests/e2e/smoke.py created a sentinel"
    return 0
  fi
  token="$(plane_python "
from plane.db.models import APIToken, Workspace
w = Workspace.objects.filter(slug='$slug').first()
t = APIToken.objects.filter(user=w.owner, is_active=True).order_by('-created_at').first() if w else None
print('@@' + (t.token if t else ''))
" | tail -1)" || true
  if [[ -z "$token" ]]; then
    record proof-sentinel FAIL "workspace $slug or its owner's API token is not in the restored database"
    return 1
  fi
  secret_tmp="$(mktemp "$LOCAL_DIR/.restore-accounts.XXXXXX")"
  sentinel_tmp="$(mktemp "$LOCAL_DIR/.restore-sentinel.XXXXXX")"
  prefix="PLANE_$(printf '%s' "$ENV_NAME" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s_API_TOKEN=%s\n' "$prefix" "$token" > "$secret_tmp"
  jq '.sentinel' "$manifest" > "$sentinel_tmp"
  python3 "$ROOT/tests/e2e/smoke.py" --env "$ENV_NAME" --mode verify --job-probe \
    --accounts "$secret_tmp" --sentinel "$sentinel_tmp" \
    --evidence "$LOCAL_DIR/evidence-raw/restore-smoke-$ENV_NAME-$STAMP.json" || rc=$?
  if [[ $rc -eq 0 ]]; then
    record proof-sentinel PASS "work item read through the API, attachment checksum matches, a worker ran a new job"
  else
    record proof-sentinel FAIL "tests/e2e/smoke.py exited $rc, see restore-smoke-$ENV_NAME-$STAMP.json"
    return 1
  fi
}

# Ties the restore to monitoring. Only a warning if Prometheus is unreachable: the data is proven
# above, and a broken dashboard path should not fail a restore.
prove_probes() {
  local deadline=$((SECONDS + 180)) value
  while [[ $SECONDS -lt $deadline ]]; do
    value="$(prom_query "min(probe_success{namespace=\"$NS\",probe=~\"api-instance|api-db\"})" 2>/dev/null \
      | jq -r '.data.result[0].value[1] // "none"' 2>/dev/null || echo none)"
    if [[ "$value" == 1 ]]; then
      record proof-probes PASS "API and database probes are green"
      return 0
    fi
    sleep 10
  done
  record proof-probes "NOT RUN" "probes did not report green within 180s (last value: ${value:-none})"
}

restore_plane() {
  local pg_image plane_version live_version newest users objects deployment replicas failed=0 inspect
  pg_image="$(live_image statefulset plane-pgdb-wl plane-pgdb)"
  [[ -n "$pg_image" ]] || die "cannot read plane-pgdb-wl in $NS. Is the Plane Application synced?"

  # Django cannot migrate backwards, so a dump from a newer release cannot run on this image.
  plane_version="$(jq -r .plane_version "$manifest")"
  live_version="$(kc -n "$NS" get deployment plane-api-wl -o json | jq -r '.spec.template.metadata.labels["app.kubernetes.io/version"] // "unknown"')"
  newest="$(printf '%s\n%s\n' "${plane_version#v}" "${live_version#v}" | sort -V | tail -1)"
  [[ "$newest" == "${live_version#v}" ]] || die "backup is from Plane $plane_version but $NS runs $live_version. Migrations do not run backwards."
  record version PASS "backup $plane_version, running $live_version"

  check_fingerprint secret_key_fp plane-app-keys SECRET_KEY

  log "Waiting for the data services"
  for deployment in plane-pgdb-wl plane-minio-wl plane-redis-wl plane-rabbitmq-wl; do
    kc -n "$NS" rollout status "statefulset/$deployment" --timeout=300s >/dev/null || die "$deployment is not ready"
  done

  inspect="$(inspect_target "$pg_image" plane-pgdb plane-pgdb)" || { printf '%s\n' "$inspect" >&2; die "could not inspect the database"; }
  users="$(printf '%s\n' "$inspect" | sed -n 's/.*USERS=//p' | tail -1)"
  inspect="$(inspect_bucket)" || { printf '%s\n' "$inspect" >&2; die "could not list the bucket"; }
  objects="$(printf '%s\n' "$inspect" | sed -n 's/.*OBJECTS=//p' | tail -1)"
  [[ -n "$users" && -n "$objects" ]] || die "could not read the state of $NS"
  refuse_if_not_empty "$users" "$objects"

  # ----- Past this line the environment is being changed. -----
  argo_pause "$APP"
  log "Stopping the apps"
  for deployment in $APP_DEPLOYMENTS; do
    kc -n "$NS" scale "deployment/$deployment" --replicas=0 >/dev/null
  done
  wait_for 180 "app pods to exit" no_app_pods
  record apps-stopped PASS "api, worker, beat and live at zero with auto-sync paused"

  restore_data "$pg_image"
  record postgres PASS "dump restored in one transaction, row counts and content hashes equal the backup"
  record objects PASS "synced and checked by download, every uploaded asset has its object"

  # Old cache entries and queued tasks describe rows from before the restore.
  kc -n "$NS" exec plane-redis-wl-0 -c plane-redis -- valkey-cli FLUSHALL >/dev/null
  record valkey PASS "flushed"
  # No grep -q: it exits at the first match, kubectl takes SIGPIPE, and pipefail reads that as absent.
  if kc -n "$NS" exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q list_queues name | grep -x celery >/dev/null; then
    kc -n "$NS" exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q purge_queue celery >/dev/null
    record rabbitmq PASS "queue celery purged"
  else
    record rabbitmq PASS "no celery queue to purge"
  fi

  run_migrator
  record migrator PASS "completed"

  # API first: its boot clears the cache and re-registers, and worker and live want it up.
  log "Starting the apps"
  for deployment in $APP_DEPLOYMENTS; do
    replicas="$(desired_replicas "$deployment")"
    kc -n "$NS" scale "deployment/$deployment" --replicas="$replicas" >/dev/null
    kc -n "$NS" rollout status "deployment/$deployment" --timeout=600s >/dev/null || die "$deployment did not become ready"
  done
  record apps-started PASS "api, worker, beat and live are ready"

  log "Proving the restore"
  prove_decrypt || failed=1
  prove_sentinel || failed=1
  prove_probes
  [[ $failed -eq 0 ]] || die "the data is back, but at least one proof failed"
}

# ----- Infisical --------------------------------------------------------------------------------

restore_infisical_db() { # pg-image
  local job="plane-restore-$JOB_SUFFIX"
  fill "JOB=$job" "NS=$NS" "ID=$BACKUP_ID" "PG_IMAGE=$1" <<'YAML' | run_job "$NS" "$job" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-restore
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-restore
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: backups, readOnly: true }
        - name: work
          emptyDir: { sizeLimit: 64Mi }
      containers:
        - name: postgres
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: PGHOST, value: infisical-postgres }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_DB } } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              B="/backups/$BACKUP_ID"
              TAB="$(printf '\t')"
              dropdb --maintenance-db=postgres --force --if-exists "$POSTGRES_DB"
              createdb --maintenance-db=postgres "$POSTGRES_DB"
              pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d "$POSTGRES_DB" "$B/postgres/infisical.dump"
              vacuumdb --analyze-only "$POSTGRES_DB"
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" -f "$B/postgres/rowcounts.sql" > /work/rowcounts.tsv
              diff "$B/postgres/rowcounts.tsv" /work/rowcounts.tsv
              echo "GATE1 ok: $(wc -l < /work/rowcounts.tsv) tables equal the backup"
YAML
}

restore_infisical() {
  local pg_image inspect users status
  pg_image="$(live_image statefulset infisical-postgres postgres)"
  [[ -n "$pg_image" ]] || die "cannot read infisical-postgres. Is the infisical Application synced?"
  # The dump is useless without the key that encrypted its root key. Infisical cannot run on a wrong
  # one, so unlike Plane this mismatch is fatal to the secret store, not just to a few rows.
  check_fingerprint encryption_key_fp infisical-secrets ENCRYPTION_KEY

  kc -n "$NS" rollout status statefulset/infisical-postgres --timeout=300s >/dev/null || die "infisical-postgres is not ready"
  inspect="$(inspect_target "$pg_image" infisical-postgres infisical-db)" || { printf '%s\n' "$inspect" >&2; die "could not inspect the database"; }
  users="$(printf '%s\n' "$inspect" | sed -n 's/.*USERS=//p' | tail -1)"
  [[ -n "$users" ]] || die "could not read the state of $NS"
  refuse_if_not_empty "$users" 0

  argo_pause "$APP"
  kc -n "$NS" scale deployment/infisical --replicas=0 >/dev/null
  kc -n "$NS" rollout status deployment/infisical --timeout=180s >/dev/null || die "infisical did not stop"
  record app-stopped PASS "infisical at zero with auto-sync paused"

  restore_infisical_db "$pg_image"
  record postgres PASS "dump restored in one transaction, row counts equal the backup"

  kc -n "$NS" scale deployment/infisical --replicas=1 >/dev/null
  kc -n "$NS" rollout status deployment/infisical --timeout=600s >/dev/null || die "infisical did not become ready"
  status="$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://infisical.localhost/api/status || true)"
  if [[ "$status" == 200 ]]; then
    record proof-status PASS "/api/status answers 200 through Traefik"
  else
    record proof-status FAIL "/api/status answered $status"
    die "Infisical did not answer after the restore"
  fi
  warn "On a new cluster, re-run Terraform in infisical/terraform: Kubernetes Auth stores the cluster CA."
}

if [[ "$ENV_NAME" == infisical ]]; then restore_infisical; else restore_plane; fi
