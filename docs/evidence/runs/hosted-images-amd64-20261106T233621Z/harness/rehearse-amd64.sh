#!/usr/bin/env bash
# Scratch: the RUN steps of Dockerfile.space and Dockerfile.backend, in throwaway containers on the amd64 children of the pinned bases,
# under Rosetta, with the last local build's contexts mounted read-only. No image is built or kept.
set -uo pipefail
S="$1"; R=/Users/bek/dev/pr/plane-platform
SPACE=mirror.gcr.io/makeplane/plane-space@sha256:af9b955874a2ea44f5121bc669200074428081301f950a8e4eeaf1a140e98a88
BACKEND=mirror.gcr.io/makeplane/plane-backend@sha256:9b75bf46cf4ffa94272a337450ab96a4577f2b81ceff00def11f5c71eb8dd743
echo "== space: $SPACE"
docker run --rm --platform linux/amd64 --entrypoint sh -v "$R/.build/wayline-dist/space:/ctx:ro" -v "$R/apps/wayline/runtime/space-deps.mjs:/deps/space-deps.mjs:ro" "$SPACE" -c '
set -e
uname -m
node -p "process.arch"
rm -rf /app/apps/space/build
cp -R /ctx/build /app/apps/space/build
mkdir -p /opt/wayline /usr/share/licenses/wayline
cp -R /ctx/licenses/. /usr/share/licenses/wayline/
cp /deps/space-deps.mjs /opt/wayline/
node --experimental-vm-modules --disable-warning=ExperimentalWarning /opt/wayline/space-deps.mjs apply
node --experimental-vm-modules --disable-warning=ExperimentalWarning /opt/wayline/space-deps.mjs check
' >"$S/rehearse-space.txt" 2>&1
echo "space steps exit $?"
tail -12 "$S/rehearse-space.txt" | cut -c1-170
echo "== backend: $BACKEND"
docker run --rm --platform linux/amd64 --entrypoint sh -v "$R/.build/wayline-dist/backend:/ctx:ro" \
  -e DJANGO_SETTINGS_MODULE=plane.settings.production -e SECRET_KEY=check-only-not-a-secret -e DATABASE_URL=postgres://check:check@127.0.0.1:1/check -e REDIS_URL=redis://127.0.0.1:1/ -e AMQP_URL=amqp://check:check@127.0.0.1:1// -e WEB_URL=http://check.invalid \
  "$BACKEND" -c '
set -e
uname -m
cp -R /ctx/templates/. /code/templates/
mkdir -p /opt/wayline /usr/share/licenses/wayline
cp -R /ctx/wayline/. /opt/wayline/
cp /ctx/wayline/Logo.png /code/plane/static/logos/Logo.png
cp /ctx/wayline/vendor/email.py /code/plane/utils/email.py
chmod 0644 /code/plane/utils/email.py
cp -R /ctx/licenses/. /usr/share/licenses/wayline/
python /opt/wayline/edit_strings.py --root /code --manifest /opt/wayline/edited-files.txt
pip install --no-deps --require-hashes --only-binary=:all: --no-cache-dir --disable-pip-version-check --root-user-action=ignore --requirement /opt/wayline/pyjwt-requirements.txt
python /opt/wayline/check_image.py --build-time
cd /code
python manage.py check
python manage.py makemigrations --check --dry-run
' >"$S/rehearse-backend.txt" 2>&1
echo "backend steps exit $?"
tail -12 "$S/rehearse-backend.txt" | cut -c1-170
