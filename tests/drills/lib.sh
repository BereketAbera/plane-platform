#!/usr/bin/env bash
# Shared by the drills. Source this after scripts/lib/common.sh.
# Every drill line is PASS, FAIL or a stage heading, and the whole run is copied to evidence-raw.

DRILL_FAILURES=0

drill_start() { # drill_start <name>: start the evidence log
  mkdir -p "$LOCAL_DIR/evidence-raw"
  DRILL_EVIDENCE="$LOCAL_DIR/evidence-raw/drill-$1-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "$DRILL_EVIDENCE") 2>&1
  printf 'drill %s started %s by: %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$0"
}

stage() { printf '\n--- %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; DRILL_FAILURES=$((DRILL_FAILURES + 1)); }
# abort stops the drill. Its exit trap still restores the environment.
abort() { fail "$*"; exit 1; }

# For the exit trap, so a drill that aborted still ends with a RESULT line after restoring.
drill_result_on_abort() {
  [[ "${DRILL_REPORTED:-}" == yes ]] || printf '\nRESULT FAIL   aborted, %s failure(s). evidence: %s\n' "$DRILL_FAILURES" "$DRILL_EVIDENCE"
}

drill_finish() {
  DRILL_REPORTED=yes
  printf '\n'
  if [[ "$DRILL_FAILURES" -eq 0 ]]; then
    printf 'RESULT PASS   evidence: %s\n' "$DRILL_EVIDENCE"
    return 0
  fi
  printf 'RESULT FAIL   %s failure(s). evidence: %s\n' "$DRILL_FAILURES" "$DRILL_EVIDENCE"
  return 1
}

app_field() { kc -n argocd get application "$1" -o jsonpath="{$2}" 2>/dev/null || true; }

# Argo CD polls Git every three minutes or so. Ask it to look now, so a drill measures behaviour
# rather than the poll interval. A metadata nudge only, nothing in the spec changes.
refresh_app() { kc -n argocd annotate application "$1" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; }

poll() { # poll <seconds> <command...>: true as soon as the command succeeds
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || return 1
    sleep 5
  done
}

app_is() { # app_is <application> <sync status> <health status>
  [[ "$(app_field "$1" .status.sync.status)" == "$2" && "$(app_field "$1" .status.health.status)" == "$3" ]]
}

# The platform the node runs of an image, as the image's registry states it. A plain manifest is one platform, which only its
# config states, and the node runs it whatever that is: dev's backend is a plain linux/amd64 manifest, which the arm64 node runs
# under Rosetta. Of an index the node runs the child for its own platform, so the index must hold exactly one. Prints
# <os>/<architecture>, with /<variant> where the config names one, and fails having printed nothing if the registry cannot say.
# A buildx attestation manifest's config says unknown/unknown, which is no platform a node runs, so that fails too.
# tests/drills/image-platform-cases.sh tests this against a stand-in for imagetools.
image_platform() { # image_platform <reference> <the node's os/architecture>
  local raw
  raw="$(docker buildx imagetools inspect --raw "$1" 2>/dev/null)" || return 1
  if jq -e 'has("manifests")' <<<"$raw" >/dev/null 2>&1; then
    jq -e --arg os "${2%%/*}" --arg architecture "${2#*/}" \
      '[.manifests[] | select(.platform.os == $os and .platform.architecture == $architecture)] | length == 1' <<<"$raw" >/dev/null || return 1
    printf '%s\n' "$2"
  else
    docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null |
      jq -er 'select(all(.os, .architecture; . != null and . != "" and . != "unknown")) | [.os, .architecture, (.variant // empty)] | join("/")' 2>/dev/null
  fi
}

# A real request through Traefik, on the Host the environment serves. Prints the status code.
http_status() { # http_status <host> [path]
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1" "http://127.0.0.1${2:-/}" 2>/dev/null || true
}

accept_args() { # accept_args <allowed name...> -- "$@"
  local allowed=" " arg
  while [[ "$1" != -- ]]; do allowed+="$1 "; shift; done
  shift
  for arg in "$@"; do
    case "$arg" in
      dev | prod-sim) export ENV="$arg" ;;
      *=*)
        [[ "$allowed" == *" ${arg%%=*} "* ]] || die "unknown option: $arg"
        export "${arg?}"
        ;;
      *) die "unknown argument: $arg" ;;
    esac
  done
}
