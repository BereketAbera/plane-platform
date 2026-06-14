#!/usr/bin/env bash
# Back up an environment into .local/backups/<env>/<id>/ on the host, through a Job that mounts the
# environment's `backups` PVC. Nothing is written outside /backups.
#
#   scripts/backup.sh dev | prod-sim | infisical | all
#   ENV=dev scripts/backup.sh, or scripts/backup.sh ENV=dev
#
# Postgres: pg_dump -Fc with the same image as the server, then a restore of that dump into a scratch
# database, so the row counts come from the dump itself and every backup is proven restorable.
# Objects: rclone copy plus a downloading check. Plane only. The manifest records how many rows the dump marks as
# uploaded and how many of those have no object in this backup, which is what a restore's GATE2 refuses, so a plan
# can say so before a delete.
# Keys: only a truncated hash of SECRET_KEY or ENCRYPTION_KEY goes in the manifest, never the key.
# Dumps hold password hashes and plaintext API tokens, so the backup root is kept at 0700.
# Recovery set: after the Job, this script adds recovery/ to the backup from the host, because that is
# where those files live. See infisical/lib/recovery.sh. Infisical exits non-zero if its set is not
# whole, and keeps the dump: an in-place restore can use it, a clean restore cannot.
# Retention: Plane's runs in the Job, and it never removes the newest backup that holds users, so backups of an
# empty environment cannot push out the last real one. Infisical's runs from here, once its set is complete, and
# only a complete set counts toward KEEP, so a run of failures cannot remove the backup a clean restore needs.
# While a clean restore is under way an environment it has not finished is empty or partly restored, and a backup of
# that is worse than none, so this refuses it unless ALLOW_BACKUP_DURING_RESTORE=yes. One it has finished goes ahead.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../monitoring/ops/lib.sh
source "$ROOT/monitoring/ops/lib.sh"
# shellcheck source=../infisical/lib/api.sh
source "$ROOT/infisical/lib/api.sh"
# shellcheck source=../infisical/lib/recovery.sh
source "$ROOT/infisical/lib/recovery.sh"
trap ia_cleanup EXIT

accept_assignments "ENV KEEP ALLOW_BACKUP_DURING_RESTORE" "$@"
target="${ENV:-}"
for arg in "$@"; do case "$arg" in *=*) ;; *) target="$arg" ;; esac; done
[[ -n "$target" ]] || die "usage: $0 dev|prod-sim|infisical|all"

if [[ "$target" == all ]]; then
  # A child process each, because errexit is ignored inside a function called from `||`.
  failed=""
  for env_name in infisical dev prod-sim; do
    "$0" "$env_name" || failed="$failed $env_name"
  done
  [[ -z "$failed" ]] || die "backup failed for:$failed"
  ok "all environments backed up"
  exit 0
fi

select_env "$target"

if [[ -f "$RESTORE_CLEAN_MARKER" ]]; then
  if grep -qx "done $ENV_NAME" "$RESTORE_CLEAN_MARKER"; then
    warn "a clean restore is still marked as under way ($RESTORE_CLEAN_MARKER), and it has finished $ENV_NAME, so this backup goes ahead. A newer complete set stops BACKUP=latest from resuming that restore, and the refusal says what to run."
  elif [[ "${ALLOW_BACKUP_DURING_RESTORE:-}" == yes ]]; then
    warn "a clean restore is under way ($RESTORE_CLEAN_MARKER), and it has not finished $ENV_NAME. Backing it up anyway, because ALLOW_BACKUP_DURING_RESTORE=yes."
  else
    die "a clean restore is under way ($RESTORE_CLEAN_MARKER), and it has not finished $ENV_NAME, which is empty or partly restored. A backup of that would become the newest, and could push out the one that holds the data. Nothing was changed. Finish the restore, with the same make restore-clean. If this is before make destroy, pass SKIP_BACKUP=yes to that. To back up what is there anyway: ALLOW_BACKUP_DURING_RESTORE=yes."
  fi
fi

guard_disk
need_cluster

case "$ENV_NAME" in
  dev) KEEP="${KEEP:-3}" ;;
  *) KEEP="${KEEP:-5}" ;;
esac
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a positive integer, got '$KEEP'"

ID="$(date -u +%Y%m%dT%H%M%SZ)"
JOB="plane-backup-$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')"

# The Job runs as the postgres UID, and hostPath ignores fsGroup, so the environment folder must be
# writable by anyone. The parent at 0700 is what keeps other host users out. Measured on VirtioFS
# (fakeowner): a Job as UID 70 writes here, and on the host the files belong to the Docker Desktop
# user, mode 0600 from the Job's umask.
mkdir -p "$LOCAL_DIR/backups/$ENV_NAME"
chmod 0700 "$LOCAL_DIR/backups"
chmod 0777 "$LOCAL_DIR/backups/$ENV_NAME"

kc -n "$NS" get pvc backups >/dev/null 2>&1 || die "PVC backups is missing in $NS. Is the backup-storage Application synced?"
active="$(kc -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup -o json \
  | jq -r '[.items[] | select((.status.active // 0) > 0) | .metadata.name] | join(" ")')"
[[ -z "$active" ]] || die "backup already running in $NS: $active"

# Same image as the server: pg_dump refuses to dump a server newer than itself.
live_image() { # kind name container
  kc -n "$NS" get "$1" "$2" -o json \
    | jq -r --arg c "$3" '.spec.template.spec.containers[] | select(.name == $c) | .image'
}

seed_encrypted_sentinel() {
  # get_or_create, so a later backup keeps the row a restore will read. Empty encrypted rows are the
  # default on a fresh instance, which is why a decrypt check without this row proves nothing.
  plane_python "
from plane.license.models import InstanceConfiguration as C
from plane.license.utils.encryption import encrypt_data, decrypt_data
row, _ = C.objects.get_or_create(key='$ENCRYPTED_SENTINEL_KEY', defaults={'value': encrypt_data('$ENCRYPTED_SENTINEL_VALUE'), 'category': 'WAYLINE', 'is_encrypted': True})
print('@@' + ('ok' if decrypt_data(row.value) == '$ENCRYPTED_SENTINEL_VALUE' else 'mismatch'))
" | tail -1
}

backup_plane() {
  local pg_image backend_image plane_version encrypted sentinel_file slug project work_item name asset sha
  pg_image="$(live_image statefulset plane-pgdb-wl plane-pgdb)"
  backend_image="$(live_image deployment plane-api-wl plane-api)"
  [[ -n "$pg_image" && -n "$backend_image" ]] || die "cannot read workloads in $NS. Is the Plane Application synced?"
  plane_version="$(kc -n "$NS" get deployment plane-api-wl -o json \
    | jq -r '.spec.template.metadata.labels["app.kubernetes.io/version"] // "unknown"')"

  # Best effort: an API that is down must not stop a backup taken before make destroy.
  encrypted="$(seed_encrypted_sentinel || true)"
  case "$encrypted" in
    ok) ok "encrypted sentinel row present" ;;
    mismatch) warn "encrypted sentinel row does not decrypt with the live SECRET_KEY: this database has lost its key" ;;
    *) warn "could not reach the API to seed the encrypted sentinel; restore will report that proof as NOT RUN"; encrypted="none" ;;
  esac

  # tests/e2e/smoke.py owns the work item and attachment sentinel. The record holds ids and a hash,
  # no secrets, and travels in the manifest so a restore reads the values that belong to this dump.
  slug="" project="" work_item="" name="" asset="" sha=""
  sentinel_file="$LOCAL_DIR/test-sentinel-$ENV_NAME.json"
  if [[ -f "$sentinel_file" ]]; then
    slug="$(jq -r '.slug // ""' "$sentinel_file")"
    project="$(jq -r '.project_id // ""' "$sentinel_file")"
    work_item="$(jq -r '.work_item_id // ""' "$sentinel_file")"
    name="$(jq -r '.name // ""' "$sentinel_file")"
    asset="$(jq -r '.asset_id // ""' "$sentinel_file")"
    sha="$(jq -r '.sha256 // ""' "$sentinel_file")"
  else
    warn "no $sentinel_file: run 'make test-e2e ENV=$ENV_NAME' first, or restore reports the sentinel proofs as NOT RUN"
  fi

  log "Backing up $NS to .local/backups/$ENV_NAME/$ID"
  fill "JOB=$JOB" "NS=$NS" "ID=$ID" "ENV_NAME=$ENV_NAME" "KEEP=$KEEP" "PG_IMAGE=$pg_image" \
    "RCLONE_IMAGE=$RCLONE_IMAGE" "BACKEND_IMAGE=$backend_image" "PLANE_VERSION=$plane_version" \
    "ENCRYPTED=$encrypted" "S_SLUG=$slug" "S_PROJECT=$project" "S_WORK_ITEM=$work_item" \
    "S_NAME=$name" "S_ASSET=$asset" "S_SHA=$sha" <<'YAML' | run_job "$NS" "$JOB" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-backup
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0 # never retry into a half-written folder
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 604800 # kube_job_* metrics feed the dashboards and PlaneBackupFailed
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-backup
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      # One UID for every container: postgres creates the .partial folder with umask 077 and the
      # others must write into it, and hostPath ignores fsGroup.
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: backups }
        - name: tmp
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
            - { name: backups, mountPath: /backups }
            - { name: tmp, mountPath: /tmp }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              umask 077
              D="/backups/$BACKUP_ID.partial"
              TAB="$(printf '\t')"
              [ ! -e "/backups/$BACKUP_ID" ] || { echo "refusing to overwrite /backups/$BACKUP_ID" >&2; exit 1; }
              mkdir "$D" "$D/postgres"

              # These tables hold request and response bodies and grow fast under API-key traffic.
              # Their schema is kept; their rows are not worth restoring.
              pg_dump -Fc -Z 6 \
                --exclude-table-data=api_activity_logs \
                --exclude-table-data=webhook_logs \
                --exclude-table-data=email_notification_logs \
                -f "$D/postgres/plane.dump" "$POSTGRES_DB"
              pg_restore -l "$D/postgres/plane.dump" > "$D/postgres/plane.toc.txt"

              # The queries ship with the dump, so a restore checks itself with exactly these.
              cat > "$D/postgres/rowcounts.sql" <<'SQL'
              SELECT string_agg(format('SELECT %L AS t, count(*) AS c FROM public.%I', tablename, tablename), ' UNION ALL ' ORDER BY tablename) AS q FROM pg_tables WHERE schemaname = 'public' \gset
              SELECT * FROM (:q) s ORDER BY t;
              SQL
              cat > "$D/postgres/content.sql" <<'SQL'
              SELECT 'issues', md5(coalesce(string_agg(id::text || ':' || coalesce(name, ''), ',' ORDER BY id), '')) FROM issues
              UNION ALL SELECT 'projects', md5(coalesce(string_agg(id::text || ':' || coalesce(name, ''), ',' ORDER BY id), '')) FROM projects
              UNION ALL SELECT 'file_assets', md5(coalesce(string_agg(id::text || ':' || coalesce(asset, ''), ',' ORDER BY id), '')) FROM file_assets;
              SQL

              # Prove the dump restores, and count from it rather than from a moving live database.
              V="scratch_$(printf '%s' "$BACKUP_ID" | tr '[:upper:]' '[:lower:]')"
              trap 'dropdb --if-exists --force "$V" || true' EXIT
              createdb "$V"
              pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d "$V" "$D/postgres/plane.dump"
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$V" -f "$D/postgres/rowcounts.sql" > "$D/postgres/rowcounts.tsv"
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$V" -f "$D/postgres/content.sql" > "$D/postgres/content.tsv"
              psql -XAt -d "$POSTGRES_DB" -c 'SHOW server_version' > "$D/postgres/server_version.txt"
              pg_dump --version > "$D/postgres/pg_dump_version.txt"
              echo "postgres: $(wc -l < "$D/postgres/rowcounts.tsv") tables counted from a scratch restore"
              # For the comparison below, from the same query as a restore's GATE2, on what this dump holds. If the
              # query fails on a later schema, this backup records no result: better that than no backup.
              if psql -XAt -v ON_ERROR_STOP=1 -d "$V" \
                -c "SELECT asset FROM file_assets WHERE is_uploaded AND NOT is_deleted AND deleted_at IS NULL" \
                > "$D/postgres/uploaded-keys.unsorted"; then
                LC_ALL=C sort "$D/postgres/uploaded-keys.unsorted" > "$D/postgres/uploaded-keys.txt"
              else
                echo "postgres: could not list the uploaded assets, so this backup records no result for them" >&2
              fi
              rm -f "$D/postgres/uploaded-keys.unsorted"
        # After the dump, so every asset row has its object. Extra objects are harmless.
        - name: objects
          image: __RCLONE_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: HOME, value: /tmp }
            - { name: RCLONE_CONFIG, value: /tmp/rclone.conf }
            - { name: RCLONE_CONFIG_SRC_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_SRC_PROVIDER, value: Minio }
            - { name: RCLONE_CONFIG_SRC_ENDPOINT, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_ENDPOINT_URL } } }
            - { name: RCLONE_CONFIG_SRC_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_ACCESS_KEY_ID } } }
            - { name: RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: BUCKET, valueFrom: { secretKeyRef: { name: plane-doc-store, key: AWS_S3_BUCKET_NAME } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 500m, memory: 192Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups }
            - { name: tmp, mountPath: /tmp }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              umask 077
              D="/backups/$BACKUP_ID.partial"
              mkdir -p "$D/objects"
              # Plane's presigned GET serves Content-Type as stored. Local storage could keep it only
              # in xattrs, which VirtioFS refuses (measured), so lsjson records it and restore replays it.
              rclone copy "src:$BUCKET" "$D/objects" --checksum --transfers 4 --stats 0
              rclone check "src:$BUCKET" "$D/objects" --one-way --download --combined "$D/objects.check"
              rclone lsjson -R --metadata "src:$BUCKET" > "$D/objects.lsjson"
              echo "objects: $(wc -l < "$D/objects.check") checked"
              # GATE2 begin. A restore's GATE2, made here on what a restore would have: the rows in this dump and the
              # objects in this backup. It stays a record and not a failure, because a backup with one dangling row
              # still holds everything else, and is better than none. The manifest carries the count for a plan. If
              # the comparison itself cannot run, this backup records no result, and that does not cost the backup.
              if [ -f "$D/postgres/uploaded-keys.txt" ]; then
                if rclone lsf -R --files-only "$D/objects" > "$D/.objects.list" \
                  && LC_ALL=C sort "$D/.objects.list" > "$D/.objects.sorted" \
                  && LC_ALL=C comm -23 "$D/postgres/uploaded-keys.txt" "$D/.objects.sorted" > "$D/.objects.missing"; then
                  mv "$D/.objects.missing" "$D/postgres/uploaded-missing.txt"
                  echo "GATE2: $(wc -l < "$D/postgres/uploaded-keys.txt") rows marked uploaded, $(wc -l < "$D/postgres/uploaded-missing.txt") with no object in this backup"
                else
                  echo "objects: could not compare the uploaded rows with the objects, so this backup records no result for them" >&2
                fi
                rm -f "$D/.objects.list" "$D/.objects.sorted" "$D/.objects.missing"
              fi
              # GATE2 end
      containers:
        - name: finalize
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: ENV_NAME, value: "__ENV_NAME__" }
            - { name: KEEP, value: "__KEEP__" }
            - { name: PLANE_VERSION, value: "__PLANE_VERSION__" }
            - { name: BACKEND_IMAGE, value: "__BACKEND_IMAGE__" }
            - { name: PG_IMAGE, value: "__PG_IMAGE__" }
            - { name: ENCRYPTED, value: "__ENCRYPTED__" }
            - { name: S_SLUG, value: "__S_SLUG__" }
            - { name: S_PROJECT, value: "__S_PROJECT__" }
            - { name: S_WORK_ITEM, value: "__S_WORK_ITEM__" }
            - { name: S_NAME, value: "__S_NAME__" }
            - { name: S_ASSET, value: "__S_ASSET__" }
            - { name: S_SHA, value: "__S_SHA__" }
            - { name: SECRET_KEY, valueFrom: { secretKeyRef: { name: plane-app-keys, key: SECRET_KEY } } }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 64Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              umask 077
              D="/backups/$BACKUP_ID.partial"
              F="/backups/$BACKUP_ID"
              cd "$D"
              # A truncated hash of a high-entropy key is safe beside the dump. The key is not.
              FP="$(printf %s "$SECRET_KEY" | sha256sum | cut -c1-16)"
              unset SECRET_KEY
              entry() { printf '{"path":"%s","bytes":%s,"sha256":"%s"}' "$1" "$(wc -c < "$1" | tr -d ' ')" "$(sha256sum "$1" | cut -d' ' -f1)"; }
              FILES=""
              for f in postgres/plane.dump postgres/plane.toc.txt postgres/rowcounts.tsv postgres/content.tsv objects.lsjson; do
                FILES="$FILES${FILES:+,}$(entry "$f")"
              done
              OBJECTS="$(find objects -type f | wc -l | tr -d ' ')"
              OBJECT_BYTES="$(find objects -type f -exec stat -c %s {} + | awk '{s += $1} END {print s + 0}')"
              if [ -n "$S_SLUG" ]; then
                SENTINEL="{\"environment\":\"$ENV_NAME\",\"slug\":\"$S_SLUG\",\"project_id\":\"$S_PROJECT\",\"work_item_id\":\"$S_WORK_ITEM\",\"name\":\"$S_NAME\",\"asset_id\":\"$S_ASSET\",\"sha256\":\"$S_SHA\"}"
              else
                SENTINEL=null
              fi
              # UPLOADED begin
              if [ -f postgres/uploaded-missing.txt ]; then
                UPLOADED="{\"rows\": $(wc -l < postgres/uploaded-keys.txt | tr -d ' '), \"missing\": $(wc -l < postgres/uploaded-missing.txt | tr -d ' ')}"
              else
                UPLOADED=null
              fi
              # UPLOADED end
              cat > manifest.json <<JSON
              {
                "schema": 1,
                "kind": "plane",
                "env": "$ENV_NAME",
                "id": "$BACKUP_ID",
                "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
                "plane_version": "$PLANE_VERSION",
                "backend_image": "$BACKEND_IMAGE",
                "pg_image": "$PG_IMAGE",
                "pg_server_version": "$(cat postgres/server_version.txt)",
                "pg_dump_version": "$(cat postgres/pg_dump_version.txt)",
                "secret_key_fp": "$FP",
                "excluded_table_data": ["api_activity_logs", "webhook_logs", "email_notification_logs"],
                "objects": {"count": $OBJECTS, "bytes": $OBJECT_BYTES},
                "uploaded_objects": $UPLOADED,
                "encrypted_sentinel": "$ENCRYPTED",
                "sentinel": $SENTINEL,
                "files": [$FILES]
              }
              JSON
              find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS
              sha256sum -c SHA256SUMS > /dev/null
              cd /backups
              mv "$D" "$F" # the final name appears only after everything above succeeded

              # Keep the newest $KEEP finished backups, never touching anything else in this folder, and never the
              # newest one that holds users: a run of backups of an empty environment must not push that one out.
              # RETENTION begin
              HOLDS_USERS=""
              for old in $(ls -1 | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r); do
                if [ -f "$old/manifest.json" ] && awk -F '\t' '$1 == "users" && $2 + 0 > 0 { found = 1 } END { exit !found }' "$old/postgres/rowcounts.tsv"; then
                  HOLDS_USERS="$old"
                  break
                fi
              done
              ls -1 | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | awk -v k="$KEEP" 'NR > k' | while read -r old; do
                if [ "$old" = "$HOLDS_USERS" ]; then
                  echo "retention: kept $old past KEEP=$KEEP, the newest backup that holds users"
                elif [ -f "$old/manifest.json" ]; then
                  rm -rf -- "/backups/$old"
                  echo "retention: removed $old"
                fi
              done
              # RETENTION end
              find /backups -maxdepth 1 -type d -name '*.partial' -mtime +1 -exec rm -rf {} +
              echo "finalize: $BACKUP_ID complete"
YAML
}

backup_infisical() {
  local pg_image server_image
  pg_image="$(live_image statefulset infisical-postgres postgres)"
  server_image="$(live_image deployment infisical infisical-standalone-infisical)"
  [[ -n "$pg_image" && -n "$server_image" ]] || die "cannot read the Infisical workloads. Is the infisical Application synced?"

  log "Backing up $NS to .local/backups/$ENV_NAME/$ID"
  fill "JOB=$JOB" "NS=$NS" "ID=$ID" "ENV_NAME=$ENV_NAME" "PG_IMAGE=$pg_image" "SERVER_IMAGE=$server_image" <<'YAML' | run_job "$NS" "$JOB" 1800
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/name: plane-backup
    app.kubernetes.io/component: backup
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 604800
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plane-backup
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
        - name: backups
          persistentVolumeClaim: { claimName: backups }
        - name: tmp
          emptyDir: { sizeLimit: 64Mi }
      containers:
        - name: postgres
          image: __PG_IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          env:
            - { name: BACKUP_ID, value: "__ID__" }
            - { name: ENV_NAME, value: "__ENV_NAME__" }
            - { name: PG_IMAGE, value: "__PG_IMAGE__" }
            - { name: SERVER_IMAGE, value: "__SERVER_IMAGE__" }
            - { name: PGHOST, value: infisical-postgres }
            - { name: PGUSER, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_USER } } }
            - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB, valueFrom: { secretKeyRef: { name: infisical-db, key: POSTGRES_DB } } }
            # Hashed below and unset at once. The key itself never reaches the backup: a dump is
            # useless without it, and it lives only in .local/secret-zero/.
            - { name: ENCRYPTION_KEY, valueFrom: { secretKeyRef: { name: infisical-secrets, key: ENCRYPTION_KEY } } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups }
            - { name: tmp, mountPath: /tmp }
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              umask 077
              FP="$(printf %s "$ENCRYPTION_KEY" | sha256sum | cut -c1-16)"
              unset ENCRYPTION_KEY
              D="/backups/$BACKUP_ID.partial"
              F="/backups/$BACKUP_ID"
              TAB="$(printf '\t')"
              [ ! -e "$F" ] || { echo "refusing to overwrite $F" >&2; exit 1; }
              mkdir "$D" "$D/postgres"
              pg_dump -Fc -Z 6 -f "$D/postgres/infisical.dump" "$POSTGRES_DB"
              pg_restore -l "$D/postgres/infisical.dump" > "$D/postgres/infisical.toc.txt"
              # One statement per table, because a UNION over 785 partitions runs out of shared
              # memory here, as --single-transaction does below (measured, with max_connections=30).
              cat > "$D/postgres/rowcounts.sql" <<'SQL'
              SELECT format('SELECT %L AS t, count(*) AS c FROM public.%I', tablename, tablename) FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename \gexec
              SQL
              V="scratch_$(printf '%s' "$BACKUP_ID" | tr '[:upper:]' '[:lower:]')"
              trap 'dropdb --if-exists --force "$V" || true' EXIT
              createdb "$V"
              # Never --single-transaction: 3,000 partition indexes need more locks in one transaction
              # than this server has. scripts/restore.sh gets its atomicity from a rename instead.
              pg_restore --no-owner --no-privileges --exit-on-error -d "$V" "$D/postgres/infisical.dump"
              psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d "$V" -f "$D/postgres/rowcounts.sql" > "$D/postgres/rowcounts.tsv"
              cd "$D"
              entry() { printf '{"path":"%s","bytes":%s,"sha256":"%s"}' "$1" "$(wc -c < "$1" | tr -d ' ')" "$(sha256sum "$1" | cut -d' ' -f1)"; }
              FILES="$(entry postgres/infisical.dump),$(entry postgres/infisical.toc.txt),$(entry postgres/rowcounts.tsv)"
              cat > manifest.json <<JSON
              {
                "schema": 1,
                "kind": "infisical",
                "env": "$ENV_NAME",
                "id": "$BACKUP_ID",
                "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
                "pg_image": "$PG_IMAGE",
                "server_image": "$SERVER_IMAGE",
                "pg_server_version": "$(psql -XAt -d "$POSTGRES_DB" -c 'SHOW server_version')",
                "pg_dump_version": "$(pg_dump --version)",
                "encryption_key_fp": "$FP",
                "files": [$FILES]
              }
              JSON
              find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS
              sha256sum -c SHA256SUMS > /dev/null
              cd /backups
              mv "$D" "$F"
              find /backups -maxdepth 1 -type d -name '*.partial' -mtime +1 -exec rm -rf {} +
              echo "postgres: $BACKUP_ID complete, $(wc -l < "$F/postgres/rowcounts.tsv") tables counted from a scratch restore"
YAML
}

if [[ "$ENV_NAME" == infisical ]]; then
  recovery_prepare_admin
  backup_infisical
else
  backup_plane
fi

# Verified again from the host, because that is where a restore will read it.
final="$LOCAL_DIR/backups/$ENV_NAME/$ID"
[[ -f "$final/manifest.json" ]] || die "the Job finished but $final/manifest.json is not on the host: check the kind mount of .local/backups"
(cd "$final" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "checksum verification failed on the host for $final"

recovery_failed=no
if [[ "$ENV_NAME" == infisical ]]; then
  recovery_write_infisical "$final" || recovery_failed=yes
else
  recovery_write_plane "$final" "$ENV_NAME"
fi

# A later success clears the failure that PlaneBackupFailed would otherwise report for 7 days.
kc -n "$NS" get jobs -l app.kubernetes.io/name=plane-backup -o json \
  | jq -r '.items[] | select((.status.failed // 0) > 0) | .metadata.name' \
  | while read -r old_job; do kc -n "$NS" delete job "$old_job" >/dev/null; done

jq -r '"backup \(.id): " + ([.files[] | "\(.path) \(.bytes) B"] | join(", "))' "$final/manifest.json"
if [[ "$ENV_NAME" != infisical ]]; then
  # Both are worth saying at the time, because from here on this backup is what BACKUP=latest names.
  if [[ "$(awk -F '\t' '$1 == "users" { print $2 }' "$final/postgres/rowcounts.tsv")" == 0 ]]; then
    warn "this backup holds 0 users, so it looks like a backup of an empty platform, and BACKUP=latest now names it. Retention keeps the newest backup that holds users."
  fi
  uploaded_missing="$(jq -r '.uploaded_objects.missing // 0' "$final/manifest.json")"
  if [[ "$uploaded_missing" != 0 ]]; then
    warn "this backup has $uploaded_missing rows marked uploaded with no object, listed in .local/backups/$ENV_NAME/$ID/postgres/uploaded-missing.txt. A restore of it would fail its GATE2, so a plan and make restore refuse it. Fix those rows or put the objects back, and back up again."
  fi
fi
[[ "$recovery_failed" == no ]] || die "the dump in .local/backups/$ENV_NAME/$ID is good, but its recovery set is not whole, as the warnings above say. An in-place restore can use it, and make restore-clean will refuse it. Retention did not run, so no older backup was removed."
if [[ "$ENV_NAME" == infisical ]]; then
  recovery_admin_plan "$(recovery_set_file "$final")"
  recovery_warn_token_horizon "$RECOVERY_ADMIN_EXP" "$RECOVERY_ADMIN_PASSWORD_FILE"
  recovery_prune_infisical "$KEEP"
fi
ok "backup complete: .local/backups/$ENV_NAME/$ID"
