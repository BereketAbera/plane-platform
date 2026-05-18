#!/usr/bin/env bash
# Scan the images this platform runs for known vulnerabilities, and report all of it.
#
#   scripts/ci/scan-images.sh                  everything: rendered Plane, platform manifests and
#                                              charts including Argo CD, and Wayline builds if any exist
#   SCAN_ONLY=built scripts/ci/scan-images.sh  only what .build/digests.tsv names, for CI after a push
#
# Trivy reads each image directly from its registry for linux/arm64, so nothing is loaded into Docker.
# Docker Hub images come through mirror.gcr.io where it has them, so a full scan spends no Hub quota
# while the cluster may need it. Digests make any mirror safe. Expect a few GiB of transfer.
#
# The web, admin and space clients are bundled into static files with no package metadata, so no image
# scan can see their dependencies. So the lockfiles of the Wayline source in .build/plane-src are scanned
# too, when it exists, and reported as one more row. They are upstream's, so they only ever report.
#
# Failure policy, in scan-images-report.py: exit 1 if
# - an image we build, under .../wayline/, has a CRITICAL finding with a fix available, or
# - an image could not be scanned, because a missing result must not read as a clean one.
# Everything else is reported and does not fail. An upstream image can only be fixed upstream, so its
# findings would hold CI red over something no commit here can change, and a check that stays red gets
# ignored. They are not hidden: .trivyignore is not read here, and the raw JSON keeps every finding.
#
# Raw results go to .local/evidence-raw/scan-images-<UTC start>/. Copying them to docs/evidence is a
# deliberate step, as for all evidence. Stops, reporting the rest as not scanned, once the host has
# less than SCAN_MIN_FREE_GIB free (15). SCAN_TIMEOUT limits each image (30m), SCAN_OUTPUT_DIR moves
# the results.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

MIN_FREE="${SCAN_MIN_FREE_GIB:-15}"
SCAN_ONLY="${SCAN_ONLY:-}"
[[ -z "$SCAN_ONLY" || "$SCAN_ONLY" == built ]] || die "SCAN_ONLY may only be built, got '$SCAN_ONLY'"
guard_disk "$MIN_FREE"
cd "$ROOT"

if [[ "$SCAN_ONLY" == built ]]; then
  "$ROOT/scripts/install-tools.sh" trivy >/dev/null
else
  "$ROOT/scripts/install-tools.sh" trivy helm kustomize yq >/dev/null
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="${SCAN_OUTPUT_DIR:-$LOCAL_DIR/evidence-raw/scan-images-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT/images"
RAW_LIST="$WORK/images"
: >"$RAW_LIST"

add_images() { # add_images <source label>: one image per line on stdin
  local image
  while read -r image; do
    # A resource can have an image key that holds something else. A reference has a / or a : in it.
    [[ "$image" == */* || "$image" == *:* ]] || continue
    printf '%s\t%s\n' "$image" "$1" >>"$RAW_LIST"
  done
}

images_in() { # images_in <manifest...>: the image keys at any depth, and the operator's reloader flag
  yq -N -r 'select(. != null) | .. | select(tag == "!!map") | select(has("image")) | .image | select(tag == "!!str")' "$@"
  yq -N -r 'select(. != null) | .. | select(tag == "!!str") | select(test("^--prometheus-config-reloader=")) | sub("^--prometheus-config-reloader=", "")' "$@"
}

built_images() { [[ ! -s .build/digests.tsv ]] || awk -F'\t' 'NF >= 3 { print $2 "@" $3 }' .build/digests.tsv; }

# What the local registry holds, when this machine has no record of its last build.
registry_wayline_images() {
  local catalog repo tag digest
  catalog="$(curl -fsS --max-time 5 http://localhost:5001/v2/_catalog 2>/dev/null || true)"
  for repo in $(printf '%s' "$catalog" | tr -c 'a-zA-Z0-9_./-' '\n' | grep '^wayline/' || true); do
    for tag in $(curl -fsS --max-time 5 "http://localhost:5001/v2/$repo/tags/list" | tr -c 'a-zA-Z0-9_.-' '\n' | grep -vxE 'name|tags|wayline|null|' || true); do
      digest="$(curl -fsSI --max-time 5 \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "http://localhost:5001/v2/$repo/manifests/$tag" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }' || true)"
      [[ -z "$digest" ]] || echo "localhost:5001/$repo@$digest"
    done
  done
}

if [[ "$SCAN_ONLY" == built ]]; then
  built_images | add_images built
else
  log "Listing what this platform runs"
  images_in gitops/environments/dev/manifests.yaml gitops/environments/prod-sim/manifests.yaml | add_images plane
  collect_in_repo "$WORK/in-repo"
  images_in "$WORK"/in-repo/*.yaml | add_images platform
  render_platform_charts "$WORK/charts" || die "a platform chart did not render, so the image list would be incomplete"
  for chart in "$WORK"/charts/*.yaml; do
    images_in "$chart" | add_images "chart:$(basename "$chart" .yaml)"
  done
  if [[ -s .build/digests.tsv ]]; then
    built_images | add_images wayline
  else
    registry_wayline_images | add_images wayline
  fi
  grep -q 'wayline/' "$RAW_LIST" || warn "no Wayline image exists yet in the manifests, .build/digests.tsv or the local registry, so none is scanned"
fi

WAYLINE_SOURCE=.build/plane-src
[[ ! -s "$RAW_LIST" || ! -d "$WAYLINE_SOURCE" ]] || printf 'wayline-source-lockfiles\twayline\n' >>"$RAW_LIST"

if [[ ! -s "$RAW_LIST" ]]; then
  [[ "$SCAN_ONLY" == built ]] || die "found no images at all, which cannot be right"
  warn "nothing was built, so there is nothing to scan"
  exit 0
fi

# One line per image: image, every source that names it, and the file its result goes to.
INVENTORY="$OUT/inventory.tsv"
sort -u "$RAW_LIST" | awk -F'\t' '
  $1 != image { if (image != "") print image "\t" sources; image = $1; sources = $2; next }
  { sources = sources "," $2 }
  END { print image "\t" sources }' |
  while IFS=$'\t' read -r image sources; do
    # Name the file after the image, with the digest cut to 12 characters to keep it readable.
    file="$(printf '%s' "$image" | sed -E 's/@sha256:([a-f0-9]{12})[a-f0-9]*$/_\1/; s/[\/:@]/_/g').json"
    printf '%s\t%s\t%s\n' "$image" "$sources" "$file"
  done >"$INVENTORY"
total="$(wc -l <"$INVENTORY" | tr -d ' ')"
ok "$total image(s) to scan, listed in ${INVENTORY#"$ROOT"/}"

# Docker Hub through a mirror, and nothing else redirected. Trivy falls back to Hub if the mirror lacks one.
cat >"$WORK/trivy.yaml" <<'YAML'
registry:
  mirrors:
    index.docker.io:
      - mirror.gcr.io
YAML

log "Making sure the vulnerability database is current"
trivy image --cache-dir "$LOCAL_DIR/trivy-cache" --download-db-only --no-progress >"$OUT/db-update.log" 2>&1 ||
  { cat "$OUT/db-update.log" >&2; die "could not update the vulnerability database, so nothing was scanned"; }

scan_one() { # scan_one <image> <json>
  local insecure=()
  # The local registry is plain HTTP on loopback.
  [[ "$1" != localhost:5001/* ]] || insecure=(--insecure)
  # shellcheck disable=SC2054  # the commas belong to the values
  trivy image --config "$WORK/trivy.yaml" --cache-dir "$LOCAL_DIR/trivy-cache" --skip-db-update \
    --ignorefile "" --image-src remote --platform linux/arm64 --scanners vuln --parallel 2 \
    --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --list-all-pkgs=false --exit-code 0 \
    --format json --output "$2" --timeout "${SCAN_TIMEOUT:-30m}" --no-progress \
    ${insecure[@]+"${insecure[@]}"} "$1"
}

scan_source() { # scan_source <json>
  trivy fs --cache-dir "$LOCAL_DIR/trivy-cache" --skip-db-update --ignorefile "" --scanners vuln --skip-dirs '**/node_modules' \
    --list-all-pkgs=false --exit-code 0 --format json --output "$1" --timeout "${SCAN_TIMEOUT:-30m}" --no-progress "$WAYLINE_SOURCE"
}

scan() { # scan <image> <json>
  if [[ "$1" == wayline-source-lockfiles ]]; then scan_source "$2"; else scan_one "$1" "$2"; fi
}

: >"$OUT/not-scanned.txt"
count=0
stop=no
while IFS=$'\t' read -r image _ file; do
  count=$((count + 1))
  json="$OUT/images/$file"
  if [[ "$stop" == no && "$(free_disk_gib)" -lt "$MIN_FREE" ]]; then
    warn "the host is below ${MIN_FREE} GiB free, so stopping here"
    stop=yes
  fi
  if [[ "$stop" == yes ]]; then
    printf '%s\tstopped, below %s GiB free\n' "$image" "$MIN_FREE" >>"$OUT/not-scanned.txt"
    continue
  fi
  log "[$count/$total] $image"
  # One retry, for a dropped connection. What it reports on each try stays in scan.log.
  if ! scan "$image" "$json" </dev/null >>"$OUT/scan.log" 2>&1 && ! scan "$image" "$json" </dev/null >>"$OUT/scan.log" 2>&1; then
    warn "could not scan $image. See ${OUT#"$ROOT"/}/scan.log"
    rm -f "$json"
    printf '%s\ttrivy failed twice\n' "$image" >>"$OUT/not-scanned.txt"
  fi
done <"$INVENTORY"

python3 -B "$ROOT/scripts/ci/scan-images-report.py" "$OUT"
