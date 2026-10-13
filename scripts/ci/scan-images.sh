#!/usr/bin/env bash
# Scan the images this platform runs for known vulnerabilities, and report all of it.
#
#   scripts/ci/scan-images.sh                   everything: rendered Plane, platform manifests and
#                                               charts including Argo CD, and Wayline builds if any exist
#   SCAN_ONLY=built scripts/ci/scan-images.sh   only what .build/digests.tsv names, for CI after a push
#   SCAN_ONLY=hosted scripts/ci/scan-images.sh  what hosted production runs, as this checkout says: every line of
#                                               policy/hosted-images.txt and policy/hosted-system-images.txt, and every
#                                               image in its render, gitops/environments/prod/manifests.yaml
#
# Trivy reads each image directly from its registry for PLATFORM, so nothing is loaded into Docker. The default is
# linux/arm64, what the laptop's kind node runs. images.yml sets linux/amd64, what the VPS runs. --platform only chooses a child
# of an index, and on a plain manifest trivy exits 0 and reads whatever it is, so the report holds each result to PLATFORM.
# After a digest bump dev runs linux/amd64 digests under Rosetta beside prod-sim's arm64 ones, so a full scan on the laptop then
# needs SCAN_ALSO_PLATFORM=linux/amd64, to say those plain manifests are meant. SCAN_ONLY=built takes no such thing.
# Docker Hub images come through mirror.gcr.io where it has them, so a full scan spends no Hub quota
# while the cluster may need it. Digests make any mirror safe. Expect a few GiB of transfer.
#
# SCAN_ONLY=hosted reads registries alone and never the cluster, so it scans what this checkout says hosted production runs.
# validate-manifests.sh holds policy/hosted-images.txt to what the hosted tree and its charts name, and
# policy/hosted-system-images.txt to K3s's own images and those of the probe pods the remote tests start, which no manifest
# names. The render holds the rest, Wayline's own among them. Hosted Argo CD syncs deploy/plane-prod, which a refused or pending
# release leaves behind main, so SCAN_HOSTED_RELEASE=<its ref>, as scan-hosted.yml sets, reads that branch's render too, and the
# report says whether its two trees differ from this checkout's. The lists are this checkout's alone, so a note says when the
# branch's tree may name an image this did not read. The VPS is one x86-64 node, so each image is read for
# linux/amd64 and an index for its linux/amd64 child: PLATFORM may only be that, and SCAN_ALSO_PLATFORM does not apply.
# Wayline's images there are private packages on GHCR, which trivy reads with Docker's login, as it does after a push in
# images.yml. So this needs docker login ghcr.io with a token holding read:packages, which is the login
# scripts/ci/copy-to-local-registry.sh makes, and scan-hosted.yml logs in with its own GITHUB_TOKEN under packages: read.
# There is no lockfile row, because .build/plane-src is whatever this machine last built, and production runs what CI built.
#
# The web, admin and space clients are bundled into static files with no package metadata, so no image
# scan can see their dependencies. So the lockfiles of the Wayline source in .build/plane-src are scanned
# too, when it exists, and reported as one more row. They are upstream's, so they only ever report.
#
# Failure policy, in scan-images-report.py: exit 1 if
# - an image we build, under .../wayline/, has a CRITICAL finding with a fix available, or
# - an image could not be scanned, because a missing result must not read as a clean one, or
# - a result is of another platform, because it says nothing about the image that runs.
# Everything else is reported and does not fail. An upstream image can only be fixed upstream, so its
# findings would hold CI red over something no commit here can change, and a check that stays red gets
# ignored. They are not hidden: .trivyignore is not read here, and the raw JSON keeps every finding.
#
# Raw results go to .local/evidence-raw/scan-images-<UTC start>/, or scan-images-hosted-<UTC start>/ for SCAN_ONLY=hosted,
# with the report this prints in report.txt. Copying them to docs/evidence is a deliberate step, as for all evidence.
# It refuses to start with less than SCAN_MIN_FREE_GIB free (15). Between images it stops, reporting the rest as not
# scanned, below SCAN_FLOOR_GIB (the same unless set). Each image's temp space comes back after that image, so the floor
# may sensibly be lower. SCAN_TIMEOUT limits each image (30m), and SCAN_OUTPUT_DIR moves the results.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

MIN_FREE="${SCAN_MIN_FREE_GIB:-15}"
FLOOR="${SCAN_FLOOR_GIB:-$MIN_FREE}"
SCAN_ONLY="${SCAN_ONLY:-}"
[[ -z "$SCAN_ONLY" || "$SCAN_ONLY" == built || "$SCAN_ONLY" == hosted ]] || die "SCAN_ONLY may only be built or hosted, got '$SCAN_ONLY'"
if [[ "$SCAN_ONLY" == hosted ]]; then
  [[ -z "${PLATFORM:-}" || "$PLATFORM" == linux/amd64 ]] || die "SCAN_ONLY=hosted reads what the VPS runs, which is linux/amd64, so PLATFORM cannot be '$PLATFORM'"
  PLATFORM=linux/amd64
fi
PLATFORM="${PLATFORM:-linux/arm64}"
[[ "$PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || die "PLATFORM must be linux/amd64 or linux/arm64, got '$PLATFORM'"
SCAN_ALSO_PLATFORM="${SCAN_ALSO_PLATFORM:-}"
[[ -z "$SCAN_ALSO_PLATFORM" || "$SCAN_ALSO_PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || die "SCAN_ALSO_PLATFORM must be linux/amd64 or linux/arm64, got '$SCAN_ALSO_PLATFORM'"
[[ -z "$SCAN_ALSO_PLATFORM" || "$SCAN_ONLY" != built ]] || die "SCAN_ONLY=built reads what was just built, which must be $PLATFORM, so SCAN_ALSO_PLATFORM does not apply"
[[ -z "$SCAN_ALSO_PLATFORM" || "$SCAN_ONLY" != hosted ]] || die "SCAN_ONLY=hosted reads what the VPS runs, which is linux/amd64 alone, so SCAN_ALSO_PLATFORM does not apply"
HOSTED_RELEASE="${SCAN_HOSTED_RELEASE:-}"
[[ -z "$HOSTED_RELEASE" || "$SCAN_ONLY" == hosted ]] || die "SCAN_HOSTED_RELEASE names what hosted production runs, so it is for SCAN_ONLY=hosted alone"
guard_disk "$MIN_FREE"
log "Disk limits for this run: ${MIN_FREE} GiB free to start, ${FLOOR} GiB free to keep going. $(free_disk_gib) GiB free now."
log "Reading each image for $PLATFORM${SCAN_ALSO_PLATFORM:+, and allowing a plain manifest of $SCAN_ALSO_PLATFORM}"
cd "$ROOT"

case "$SCAN_ONLY" in
  built) "$ROOT/scripts/install-tools.sh" trivy >/dev/null ;;
  hosted) "$ROOT/scripts/install-tools.sh" trivy yq >/dev/null ;;
  *) "$ROOT/scripts/install-tools.sh" trivy helm kustomize yq >/dev/null ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULTS_NAME=scan-images
[[ "$SCAN_ONLY" != hosted ]] || RESULTS_NAME=scan-images-hosted
OUT="${SCAN_OUTPUT_DIR:-$LOCAL_DIR/evidence-raw/$RESULTS_NAME-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT/images"
printf '%s\n' "$PLATFORM" ${SCAN_ALSO_PLATFORM:+"$SCAN_ALSO_PLATFORM"} >"$OUT/platform.txt"
# What the report advises on a result of another platform depends on the kind of scan, because only a full one takes
# SCAN_ALSO_PLATFORM.
printf '%s\n' "${SCAN_ONLY:-full}" >"$OUT/mode.txt"
# What the listing finds that a reader of the report needs, which the report prints as it is.
: >"$OUT/notes.txt"
note() { printf '%s\n' "$*" >>"$OUT/notes.txt"; }
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

# The branch hosted Argo CD syncs: its render is read too, and a note says how its two trees compare with this checkout's.
read_release() {
  local release from differ where
  release="$(git rev-parse --verify --quiet "${HOSTED_RELEASE}^{commit}")" ||
    die "SCAN_HOSTED_RELEASE is $HOSTED_RELEASE, which this checkout cannot read. Fetch it first: git fetch origin deploy/plane-prod"
  from="$(git show "$release:RELEASE.json" 2>/dev/null | yq -p json -r '.main_commit // ""' 2>/dev/null || true)"
  [[ "$from" =~ ^[a-f0-9]{40}$ ]] || die "$HOSTED_RELEASE has no RELEASE.json naming a main commit, so it is no release, and nothing says it is what production runs"
  git show "$release:$HOSTED_ENVIRONMENT/manifests.yaml" >"$WORK/release-render.yaml" 2>/dev/null ||
    die "$HOSTED_RELEASE has no $HOSTED_ENVIRONMENT/manifests.yaml"
  images_named_in "$WORK/release-render.yaml" | add_images hosted-release
  # Against the working tree, so a run on uncommitted changes compares what it read.
  differ="$(git diff --name-only "$release" -- "$HOSTED_TREE" "$HOSTED_ENVIRONMENT")"
  where="$HOSTED_RELEASE at ${release:0:12}, released from main ${from:0:12}, is what hosted Argo CD syncs, and it"
  if [[ -z "$differ" ]]; then
    note "$where holds the same two hosted trees as this checkout."
  elif ! grep -q "^$HOSTED_TREE/" <<<"$differ"; then
    note "$where has another render than this checkout. Both were read."
  else
    note "$where differs from this checkout under $HOSTED_TREE. Its render was read as well, but $HOSTED_IMAGE_LIST holds what this checkout's tree and charts name, so production may run an image this did not read. Read: git diff ${release:0:12} -- $HOSTED_TREE"
    warn "$HOSTED_RELEASE differs from this checkout under $HOSTED_TREE, so production may run an image this does not read"
  fi
}

if [[ "$SCAN_ONLY" == built ]]; then
  built_images | add_images built
elif [[ "$SCAN_ONLY" == hosted ]]; then
  log "Listing what hosted production runs, as this checkout says"
  # A list of comments alone lists nothing, and the render would then stand for all of it. So each must name an image as
  # add_images reads one: a line that is no comment, with a / or a : in it.
  for list in "$HOSTED_IMAGE_LIST" "$HOSTED_SYSTEM_IMAGE_LIST"; do
    grep -qE '^[^#].*[/:]' "$list" 2>/dev/null || die "$list is missing or lists no image"
  done
  [[ -s "$HOSTED_ENVIRONMENT/manifests.yaml" ]] || die "$HOSTED_ENVIRONMENT/manifests.yaml is missing or empty: run make render"
  { grep -vE '^(#|$)' "$HOSTED_IMAGE_LIST" || true; } | add_images hosted-list
  # K3s's own images and the probes', which no manifest names.
  { grep -vE '^(#|$)' "$HOSTED_SYSTEM_IMAGE_LIST" || true; } | add_images hosted-system
  # The same reading of the render as the list's own check, so the two cannot disagree on what an image is.
  images_named_in "$HOSTED_ENVIRONMENT/manifests.yaml" | add_images hosted-render
  if [[ -n "$HOSTED_RELEASE" ]]; then
    read_release
  else
    note "This read the hosted trees as this checkout holds them, and hosted Argo CD syncs deploy/plane-prod. SCAN_HOSTED_RELEASE=origin/deploy/plane-prod reads that branch's render too, and says whether the two differ."
  fi
  grep -q '/wayline/' "$RAW_LIST" || warn "the hosted render names no Wayline image, so none is scanned"
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
[[ "$SCAN_ONLY" == hosted || ! -s "$RAW_LIST" || ! -d "$WAYLINE_SOURCE" ]] || printf 'wayline-source-lockfiles\twayline\n' >>"$RAW_LIST"

if [[ ! -s "$RAW_LIST" ]]; then
  [[ "$SCAN_ONLY" == built ]] || die "found no images at all, which cannot be right"
  warn "nothing was built, so there is nothing to scan"
  exit 0
fi

# One line per image: image, every source that names it, and the file its result goes to. Ours first:
# only they can fail the policy, and they need the least transfer, so a run that stops early has them.
INVENTORY="$OUT/inventory.tsv"
sort -u "$RAW_LIST" | awk -F'\t' '
  $1 != image { if (image != "") print image "\t" sources; image = $1; sources = $2; next }
  { sources = sources "," $2 }
  END { print image "\t" sources }' |
  awk -F'\t' '{ print ($1 ~ /wayline/ ? 0 : 1) "\t" $0 }' | sort -s -t $'\t' -k1,1n | cut -f2- |
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
# Infisical's image holds JARs, so trivy would otherwise fetch this, about 950 MiB, in the middle of
# that image's scan and against its timeout. It keeps it for three days.
if [[ "$SCAN_ONLY" != built ]]; then
  trivy image --cache-dir "$LOCAL_DIR/trivy-cache" --download-java-db-only --no-progress >>"$OUT/db-update.log" 2>&1 ||
    { cat "$OUT/db-update.log" >&2; die "could not update the Java database, so nothing was scanned"; }
fi

scan_one() { # scan_one <image> <json>
  local insecure=()
  # The local registry is plain HTTP on loopback.
  [[ "$1" != localhost:5001/* ]] || insecure=(--insecure)
  # shellcheck disable=SC2054  # the commas belong to the values
  trivy image --config "$WORK/trivy.yaml" --cache-dir "$LOCAL_DIR/trivy-cache" --skip-db-update \
    --ignorefile "" --image-src remote --platform "$PLATFORM" --scanners vuln --parallel 2 \
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
  if [[ "$stop" == no && "$(free_disk_gib)" -lt "$FLOOR" ]]; then
    warn "the host is below ${FLOOR} GiB free, so stopping here"
    stop=yes
  fi
  if [[ "$stop" == yes ]]; then
    printf '%s\tstopped, below %s GiB free\n' "$image" "$FLOOR" >>"$OUT/not-scanned.txt"
    continue
  fi
  log "[$count/$total] $image"
  # One retry, for a dropped connection. What it reports on each try stays in scan.log.
  if ! scan "$image" "$json" </dev/null >>"$OUT/scan.log" 2>&1 && ! scan "$image" "$json" </dev/null >>"$OUT/scan.log" 2>&1; then
    warn "could not scan $image. See ${OUT#"$ROOT"/}/scan.log"
    # Wayline's packages on GHCR are private, and trivy has nothing but Docker's login to read them with.
    [[ "$image" != ghcr.io/* ]] || warn "trivy reads GHCR with Docker's login, which needs docker login ghcr.io with a token holding read:packages"
    rm -f "$json"
    printf '%s\ttrivy failed twice\n' "$image" >>"$OUT/not-scanned.txt"
  fi
done <"$INVENTORY"

python3 -B "$ROOT/scripts/ci/scan-images-report.py" "$OUT"
