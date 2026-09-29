#!/usr/bin/env bash
# What Infisical's public route refuses, in every spelling. Starts the Traefik image hosted production pins, in Docker, with the flags its chart
# renders and with gitops/clusters/plane-prod/platform/infisical/route.yaml as it stands, read into Traefik's file provider, which applies the same rule
# and middleware code to the same words. Then tests/routes/infisical-public-route.py asks it.
#
#   tests/routes/infisical-public-route.sh                                                    an echo server behind Traefik, which shows what would arrive
#   INFISICAL_BACKEND=http://host.docker.internal:18110 tests/routes/infisical-public-route.sh   a real Infisical behind it, which shows what Fastify's router does with it
#   INFISICAL_ROUTE_TEST_SERVE=yes INFISICAL_BACKEND=... tests/routes/infisical-public-route.sh  no questions: leaves it up, for a browser mapped to that port, until Ctrl-C
#   INFISICAL_ROUTE_TEST_NETWORK=<docker network> ...                                         Traefik joins that network too, so the backend sees it as a
#                                                                                              proxy of its own range, as Infisical sees Traefik's pod
#
# Exit, as scripts/test.sh: 0 every row passed, 1 something got through, 2 it could not run. No cluster and no credential: it asks nothing of production.
# It listens on this machine's loopback alone. CI has no Docker to spare for this, so it runs by hand, and policy/hosted.rego holds the route to the words it proved.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"

cd "$ROOT"
"$ROOT/scripts/install-tools.sh" yq helm >/dev/null
command -v docker >/dev/null 2>&1 || { warn "docker not found"; exit 2; }
docker info >/dev/null 2>&1 || { warn "Docker does not answer"; exit 2; }

VALUES=gitops/clusters/plane-prod/values/traefik.yaml
ROUTE=gitops/clusters/plane-prod/platform/infisical/route.yaml
APPLICATION=gitops/clusters/plane-prod/applications/traefik.yaml
# A name of its own and a port no other test here uses, because other wayline-test-* containers may be running on this machine.
NAME=wayline-test-inf-route-traefik
TLS_PORT="${INFISICAL_ROUTE_TEST_PORT:-18543}"
ECHO_PORT="${INFISICAL_ROUTE_TEST_ECHO_PORT:-18111}"
BACKEND="${INFISICAL_BACKEND:-}"
HOST=infisical.bereket.dev

WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

digest="$(yq -r .image.digest "$VALUES")"
image="traefik@$digest"
chart_version="$(yq -r '.spec.sources[] | select(.chart == "traefik") | .targetRevision' "$APPLICATION")"
chart_repo="$(yq -r '.spec.sources[] | select(.chart == "traefik") | .repoURL' "$APPLICATION")"
rendered=no
for attempt in 1 2 3 4; do
  if helm template traefik traefik --repo "$chart_repo" --version "$chart_version" --namespace traefik -f "$VALUES" >"$WORK/chart.yaml"; then
    rendered=yes
    break
  fi
  sleep $((attempt * 5))
done
[[ "$rendered" == yes ]] || { warn "could not render Traefik's chart"; exit 2; }

# The chart's flags, but for the providers, which need a cluster.
yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$WORK/chart.yaml" |
  grep -v '^--providers\.' >"$WORK/flags"
[[ -s "$WORK/flags" ]] || { warn "the chart rendered no flags"; exit 2; }
grep -q -- '--entryPoints.websecure.address=:8443/tcp' "$WORK/flags" || { warn "the chart no longer listens on 8443"; exit 2; }

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" \
  -keyout "$WORK/tls.key" -out "$WORK/tls.crt" >/dev/null 2>&1

if [[ -n "$BACKEND" ]]; then
  backend_url="$BACKEND"
  mode="real"
else
  backend_url="http://host.docker.internal:$ECHO_PORT"
  mode="echo"
fi

# Traefik's provider for IngressRoutes hands each route's match and each Middleware's spec to the same code as this file's, so the words stay the words.
yq -o=json -I=0 . "$ROUTE" >"$WORK/route.json"
python3 -I - "$WORK" "$backend_url" <<'PY'
import json
import sys

work, backend = sys.argv[1:3]
routers, middlewares = {}, {}
for line in open(f"{work}/route.json"):
    document = json.loads(line)
    if document["kind"] == "Middleware":
        middlewares[document["metadata"]["name"]] = document["spec"]
    elif document["kind"] == "IngressRoute":
        assert document["spec"]["entryPoints"] == ["websecure"]
        for index, route in enumerate(document["spec"]["routes"]):
            routers[f"route-{index}"] = {
                "entryPoints": ["websecure"],
                "rule": route["match"],
                "service": "infisical",
                "tls": {},
                "middlewares": [m["name"] for m in route.get("middlewares", [])],
            }
            if "priority" in route:
                routers[f"route-{index}"]["priority"] = route["priority"]
config = {
    "http": {"routers": routers, "middlewares": middlewares, "services": {"infisical": {"loadBalancer": {"servers": [{"url": backend}]}}}},
    "tls": {
        "options": {"default": {"minVersion": "VersionTLS12", "sniStrict": True}},
        "certificates": [{"certFile": "/conf/tls.crt", "keyFile": "/conf/tls.key"}],
        "stores": {"default": {"defaultCertificate": {"certFile": "/conf/tls.crt", "keyFile": "/conf/tls.key"}}},
    },
}
json.dump(config, open(f"{work}/dynamic.json", "w"))
PY
# Traefik's file provider reads YAML, and JSON is YAML, under a name it accepts.
mv "$WORK/dynamic.json" "$WORK/dynamic.yaml"

docker rm -f "$NAME" >/dev/null 2>&1 || true
flags=()
while IFS= read -r flag; do flags+=("$flag"); done <"$WORK/flags"
# Loopback only, so this test never answers anyone else, and the configuration is copied in, because Docker Desktop will not mount a temporary folder by default.
network=()
[[ -z "${INFISICAL_ROUTE_TEST_NETWORK:-}" ]] || network=(--network "$INFISICAL_ROUTE_TEST_NETWORK")
docker create --name "$NAME" ${network[@]+"${network[@]}"} -p "127.0.0.1:$TLS_PORT:8443" "$image" "${flags[@]}" --providers.file.filename=/conf/dynamic.yaml >/dev/null
docker cp "$WORK/." "$NAME:/conf" >/dev/null 2>&1
docker start "$NAME" >/dev/null

deadline=$((SECONDS + 30))
until curl -k -s -o /dev/null --max-time 2 --resolve "$HOST:$TLS_PORT:127.0.0.1" "https://$HOST:$TLS_PORT/login"; do
  if [[ $SECONDS -ge $deadline ]]; then
    docker logs "$NAME" 2>&1 | tail -20 >&2
    warn "Traefik did not start"
    exit 2
  fi
  sleep 1
done
docker logs "$NAME" 2>&1 | grep -iE '"level":"(error|warn)"|level=(error|warn)| ERR | WRN ' | head -20 || true

if [[ "${INFISICAL_ROUTE_TEST_SERVE:-}" == yes ]]; then
  log "Traefik ${digest:0:19}, chart $chart_version, behind https://$HOST:$TLS_PORT on this machine's loopback. Ctrl-C ends it"
  docker wait "$NAME" >/dev/null
  exit 0
fi

log "Traefik ${digest:0:19}, chart $chart_version, $mode backend. Asking"
mkdir -p "$LOCAL_DIR/evidence-raw"
evidence="$LOCAL_DIR/evidence-raw/infisical-public-route-$mode-$(date -u +%Y%m%dT%H%M%SZ).log"
python3 -I "$ROOT/tests/routes/infisical-public-route.py" --port "$TLS_PORT" --echo-port "$ECHO_PORT" --backend "$mode" --log "$evidence"
