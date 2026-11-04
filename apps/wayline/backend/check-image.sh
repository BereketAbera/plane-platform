#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs check_image.py and manage.py check inside the image, with no network and dummy settings, and
# compares its templates with those of the pinned base image. Exits non-zero on any failure.
#
#   apps/wayline/backend/check-image.sh <image> [render-dir]
set -uo pipefail
image="${1:?usage: check-image.sh <image> [render-dir]}"
render_dir="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
base="$(sed -n 's/^FROM \(makeplane[^ ]*\).*/\1/p' "$here/../runtime/Dockerfile.backend")"

# Throwaway values: nothing connects anywhere, the settings module only needs them to be present.
env_args=(
  -e DJANGO_SETTINGS_MODULE=plane.settings.production -e SECRET_KEY=check-only-not-a-secret
  -e DATABASE_URL=postgres://check:check@127.0.0.1:1/check -e REDIS_URL=redis://127.0.0.1:1/
  -e AMQP_URL=amqp://check:check@127.0.0.1:1// -e WEB_URL=http://check.invalid
)

status=0
echo "== docker image inspect"
docker image inspect "$image" --format 'id={{.Id}} arch={{.Architecture}} user={{.Config.User}} workdir={{.Config.WorkingDir}} cmd={{.Config.Cmd}}' || status=1
echo "== base image: $base"

echo
echo "== manage.py check"
docker run --rm --network none "${env_args[@]}" "$image" python manage.py check 2>&1 || status=1

echo
echo "== check_image.py"
mounts=()
[[ -z "$render_dir" ]] || { mkdir -p "$render_dir"; chmod 777 "$render_dir"; mounts=(-v "$render_dir:/rendered"); }
docker run --rm --entrypoint tar "$base" -C /code/templates/emails -cf - . \
  | docker run --rm -i --network none "${env_args[@]}" ${mounts[@]+"${mounts[@]}"} "$image" sh -c '
      mkdir /tmp/upstream && tar -xf - -C /tmp/upstream &&
      python /opt/wayline/check_image.py --upstream /tmp/upstream '"${render_dir:+--render-dir /rendered}"
[[ ${PIPESTATUS[1]} -eq 0 ]] || status=1

exit "$status"
