#!/usr/bin/env bash
# image_platform, from tests/drills/lib.sh, against a stand-in for docker buildx imagetools, so it needs no registry and no
# cluster. failed-migrator.sh needs kind, so CI cannot run the drill itself, and scripts/ci/lint.sh runs this instead.
# Each answer has the shape imagetools gave on 2026-11-07: an index's raw JSON, or a plain manifest's config as .Image.
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

RAW=""
CONFIG=""
# A function takes the place of the command. --raw answers RAW, --format answers CONFIG, and an empty one fails, as an image
# the registry does not serve does.
docker() {
  case " $* " in
    *" --raw "*) [[ -n "$RAW" ]] && printf '%s\n' "$RAW" ;;
    *" --format "*) [[ -n "$CONFIG" ]] && printf '%s\n' "$CONFIG" ;;
    *) return 1 ;;
  esac
}

failures=0
expect() { # expect <case> <what it must print, or fails> <the node's os/architecture>
  local got status=0
  got="$(image_platform example.test/drill/backend@sha256:0123 "$3")" || status=$?
  if [[ "$2" == fails && "$status" -ne 0 && -z "$got" ]] || [[ "$2" != fails && "$status" -eq 0 && "$got" == "$2" ]]; then
    ok "$1"
  else
    warn "$1: wanted $2, and it printed '$got' and exited $status"
    failures=$((failures + 1))
  fi
}

RAW='{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"unknown","architecture":"unknown"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}'
expect "an index gives its child for the node" linux/arm64 linux/arm64
expect "an index gives its child for an amd64 node" linux/amd64 linux/amd64
expect "an index with no child for the node fails" fails linux/riscv64
expect "an index fails when the node could not be read" fails ""
RAW='{"manifests":[{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}'
expect "an index with two children for the node fails, since nothing says which it runs" fails linux/arm64

RAW='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
CONFIG='{"os":"linux","architecture":"amd64"}'
expect "a plain manifest is what its config says, whatever the node" linux/amd64 linux/arm64
expect "a plain manifest needs no node" linux/amd64 ""
CONFIG='{"os":"linux","architecture":"arm64","variant":"v8"}'
expect "a plain manifest keeps its variant" linux/arm64/v8 linux/arm64
CONFIG='{"os":"unknown","architecture":"unknown"}'
expect "an attestation manifest fails, because no node runs unknown/unknown" fails linux/arm64
CONFIG='{"os":"linux","architecture":"unknown"}'
expect "an architecture of unknown fails" fails linux/arm64
CONFIG='{"os":"linux","architecture":""}'
expect "a config that names no architecture fails" fails linux/arm64
CONFIG='{"architecture":"amd64"}'
expect "a config that names no OS fails" fails linux/arm64
CONFIG=""
expect "a plain manifest whose config cannot be read fails" fails linux/arm64
RAW=""
expect "an image the registry does not serve fails" fails linux/arm64

[[ "$failures" -eq 0 ]] || die "$failures image_platform case(s) were wrong"
ok "image_platform read every case as it should"
