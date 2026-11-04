#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs the backend image against real services it starts itself: migrations, makemigrations --check, instance
# registration, then backend/check_db.py for the telemetry defaults, both invitation views and a mail read back
# from an SMTP server. Everything sits on an internal Docker network with no route out, under the chart's UID and
# security settings, with the database on tmpfs, and all of it is removed on exit. It needs no cluster and touches none.
#
# With WAYLINE_BASE_CONTROL=yes it also runs check_db.py on the upstream base image, on its own database. That run
# must fail on the telemetry and text-part checks, which shows they can fail. Exits non-zero if the image's run
# fails, or if the control does not.
#
#   apps/wayline/checks/backend-db.sh [image]     default: the backend in .build/digests.tsv
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

# The images already on this machine. Digests from `docker buildx imagetools inspect`, 2026-11-05.
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15.6@sha256:1ebd963e5c598f944a4e9ba27de4c95289d663dcc73731025aa53c5254094d8f}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8@sha256:de1068af6f552240dfab67bcc9bfef99bfc60f776bb4580ef077ea4c8c97e848}"
MAILPIT_IMAGE="${MAILPIT_IMAGE:-axllent/mailpit@sha256:9b3a463be15354c0f0eba91697d80e3e0d8a5623ef0e627cacc836bc17fd5231}"

image="${1:-$(awk -F'\t' '$1 == "backend" { print $2 "@" $3 }' "$BUILD_DIR/digests.tsv")}"
[[ -n "$image" ]] || die "no image given and no backend in $BUILD_DIR/digests.tsv"
base="$(sed -n 's/^FROM \(makeplane[^ ]*\).*/\1/p' "$WAYLINE/runtime/Dockerfile.backend")"

run_id="wayline-dbcheck-$$"
network="$run_id"
containers=("$run_id-postgres" "$run_id-redis" "$run_id-mail")
cleanup() {
  docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

password="$(openssl rand -hex 16)"
secret_key="$(openssl rand -hex 24)" # The format scripts/secret-zero.sh generates.
docker network create --internal "$network" >/dev/null
docker run -d --name "$run_id-postgres" --network "$network" --network-alias postgres --memory 512m \
  --tmpfs /var/lib/postgresql/data -e POSTGRES_USER=plane -e POSTGRES_PASSWORD="$password" -e POSTGRES_DB=plane \
  "$POSTGRES_IMAGE" >/dev/null
docker run -d --name "$run_id-redis" --network "$network" --network-alias redis --memory 64m \
  "$REDIS_IMAGE" redis-server --save '' --appendonly no >/dev/null
docker run -d --name "$run_id-mail" --network "$network" --network-alias mail --memory 64m "$MAILPIT_IMAGE" >/dev/null

log "Waiting for Postgres"
for _ in $(seq 1 120); do
  docker exec "$run_id-postgres" pg_isready -q -U plane -d plane && break
  sleep 1
done
docker exec "$run_id-postgres" pg_isready -U plane -d plane || { docker logs --tail 30 "$run_id-postgres" 2>&1; die "Postgres did not start"; }

# in_app <image> <database> <command...>. Tasks that views queue stay in an in-memory broker with no worker, so
# mail goes out only where check_db.py calls the task itself.
in_app() {
  local app_image="$1" database="$2"
  shift 2
  docker run --rm -i --network "$network" --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --memory 768m \
    -e DJANGO_SETTINGS_MODULE=plane.settings.production -e SECRET_KEY="$secret_key" \
    -e DATABASE_URL="postgres://plane:$password@postgres:5432/$database" -e REDIS_URL=redis://redis:6379/ \
    -e AMQP_URL=memory:// -e WEB_URL=https://x.test -e SKIP_ENV_VAR=0 \
    -e EMAIL_HOST=mail -e EMAIL_PORT=1025 -e EMAIL_USE_TLS=0 -e EMAIL_USE_SSL=0 \
    --entrypoint "$1" "$app_image" "${@:2}"
}

status=0
log "manage.py migrate, on $image"
in_app "$image" plane python manage.py migrate --noinput >"$BUILD_DIR/tmp/$run_id-migrate.log" 2>&1 \
  || { cat "$BUILD_DIR/tmp/$run_id-migrate.log"; die "migrate failed"; }
applied="$(grep -c ' Applying ' "$BUILD_DIR/tmp/$run_id-migrate.log" || true)"
rm -f "$BUILD_DIR/tmp/$run_id-migrate.log"
ok "$applied migrations applied"

log "manage.py makemigrations --check, against that database"
in_app "$image" plane python manage.py makemigrations --check --dry-run || status=1

if [[ "${WAYLINE_BASE_CONTROL:-no}" == yes ]]; then
  docker exec "$run_id-postgres" psql -q -U plane -d postgres -c 'CREATE DATABASE control TEMPLATE plane'
fi

log "manage.py register_instance, on $image, with no route to GitHub"
in_app "$image" plane python manage.py register_instance proof-machine || status=1

log "check_db.py, on $image"
in_app "$image" plane python /opt/wayline/check_db.py || status=1

if [[ "${WAYLINE_BASE_CONTROL:-no}" == yes ]]; then
  # The mail server must be empty for its one-message check.
  docker rm -f "$run_id-mail" >/dev/null
  docker run -d --name "$run_id-mail" --network "$network" --network-alias mail --memory 64m "$MAILPIT_IMAGE" >/dev/null
  sleep 2
  log "Control: the same on the upstream base image, $base, which must fail"
  in_app "$base" control python manage.py register_instance proof-machine
  control_rc=0
  in_app "$base" control python - <"$WAYLINE/backend/check_db.py" >"$BUILD_DIR/tmp/$run_id-control.log" 2>&1 || control_rc=$?
  cat "$BUILD_DIR/tmp/$run_id-control.log"
  control_problems=0
  for expected in 'FAIL telemetry is off' 'FAIL a request that leaves the field out leaves it off' 'FAIL the text part holds the invitation link whole'; do
    grep -qF "$expected" "$BUILD_DIR/tmp/$run_id-control.log" || { warn "the control did not report: $expected"; control_problems=1; }
  done
  rm -f "$BUILD_DIR/tmp/$run_id-control.log"
  if [[ "$control_rc" -ne 0 && "$control_problems" -eq 0 ]]; then
    ok "the control failed where it should, exit $control_rc"
  else
    warn "the control exited $control_rc without the failures it must show, so these checks prove nothing"
    status=1
  fi
fi

[[ "$status" -eq 0 ]] && ok "backend-db: passed"
exit "$status"
