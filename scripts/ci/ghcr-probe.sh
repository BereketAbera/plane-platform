#!/usr/bin/env bash
# TEMPORARY, with .github/workflows/ci-probe.yml. Runs only on a GitHub runner, where GITHUB_TOKEN
# exists. Reports what this job's token may do on GHCR without publishing anything: it asks for a
# push token, opens one blob upload session, cancels it, and reads tag lists. It writes no layer,
# no manifest and no tag. It prints status codes and registry error bodies, never a token.
set -euo pipefail

: "${TOKEN:?}" "${OWNER:?}" "${ACTOR:?}"
owner="$(tr '[:upper:]' '[:lower:]' <<<"$OWNER")"
name="$owner/wayline/ci-probe"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "--- runner"
echo "architecture: $(uname -m)"
echo "cores: $(nproc)"
free -h
df -h / /mnt 2>/dev/null || df -h /
echo "avail on the workspace, the number guard_disk reads: $(df -BG --output=avail "$PWD" | tail -1 | tr -dc 0-9) GiB"
docker version --format 'docker server {{.Server.Version}}, {{.Server.Arch}}'
docker buildx version
echo "size of preinstalled trees a build could reclaim:"
du -sh /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /usr/local/share/boost /opt/hostedtoolcache 2>/dev/null || true

echo "--- GHCR: may this token start a push to ghcr.io/$name?"
status="$(curl -sS -o "$work/token.json" -w '%{http_code}' -u "$ACTOR:$TOKEN" \
  "https://ghcr.io/token?service=ghcr.io&scope=repository:$name:pull,push")"
echo "GET /token, scope pull,push: HTTP $status"
bearer="$(jq -r '.token // empty' "$work/token.json" 2>/dev/null || true)"
if [[ -z "$bearer" ]]; then
  echo "no token issued. Response: $(cat "$work/token.json")"
else
  echo "::add-mask::$bearer"
  status="$(curl -sS -o "$work/upload.json" -D "$work/upload.headers" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $bearer" "https://ghcr.io/v2/$name/blobs/uploads/")"
  echo "POST blobs/uploads/, opens an upload session: HTTP $status"
  if [[ "$status" == 202 ]]; then
    location="$(tr -d '\r' <"$work/upload.headers" | awk 'tolower($1) == "location:" { print $2 }')"
    [[ "$location" == http* ]] || location="https://ghcr.io$location"
    status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $bearer" "$location")"
    echo "DELETE the session, nothing was uploaded: HTTP $status"
  else
    echo "response: $(cat "$work/upload.json")"
  fi
  status="$(curl -sS -o "$work/tags.json" -w '%{http_code}' -H "Authorization: Bearer $bearer" "https://ghcr.io/v2/$name/tags/list")"
  echo "GET tags/list on the probe name: HTTP $status, $(cat "$work/tags.json")"
fi

echo "--- GHCR: does an image already exist under the real names?"
for image in web admin space backend; do
  status="$(curl -sS -o "$work/read.json" -w '%{http_code}' -u "$ACTOR:$TOKEN" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:$owner/wayline/$image:pull")"
  bearer="$(jq -r '.token // empty' "$work/read.json" 2>/dev/null || true)"
  if [[ -z "$bearer" ]]; then
    echo "$image: GET /token, scope pull: HTTP $status, no token issued"
    continue
  fi
  echo "::add-mask::$bearer"
  status="$(curl -sS -o "$work/tags.json" -w '%{http_code}' -H "Authorization: Bearer $bearer" "https://ghcr.io/v2/$owner/wayline/$image/tags/list")"
  echo "$image: GET tags/list: HTTP $status, $(cat "$work/tags.json")"
done

echo "--- REST: can this token list the owner's container packages?"
status="$(curl -sS -o "$work/packages.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json' "https://api.github.com/users/$owner/packages?package_type=container")"
echo "GET /users/$owner/packages: HTTP $status"
if [[ "$status" == 200 ]]; then
  echo "package names: $(jq -c '[.[].name]' "$work/packages.json")"
else
  echo "response: $(cat "$work/packages.json")"
fi
