#!/usr/bin/env bash
# Replay the archive's package inventory with the same freshly updated Trivy DB as remote scans.
set -euo pipefail
image="$1" result="$2" cache="$3"
root="$(git rev-parse --show-toplevel)"
[[ "$image" =~ ^docker\.io/library/snake-production-(web|arena)@sha256:([a-f0-9]{64})$ ]] || exit 1
stem="$root/policy/node-images/${BASH_REMATCH[2]}"
proof="$stem.json"
inventory="$stem.cdx.json.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# These fields come from hashing the exact OCI manifest/config and opening the release archive.
jq -e --arg image "$image" '.image==$image and .platform=="linux/amd64" and (.config|test("^sha256:[a-f0-9]{64}$"))' "$proof" >/dev/null
python3 - "$inventory" "$proof" <<'PY'
import hashlib, json, sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(data).hexdigest() != json.loads(Path(sys.argv[2]).read_text())['inventory_sha256']:
    raise SystemExit("Release SBOM checksum mismatch")
PY
gzip -dc "$inventory" >"$tmp/inventory.json"
trivy sbom --cache-dir "$cache" --skip-db-update --ignorefile "" --scanners vuln --format json \
  --output "$tmp/scan.json" --timeout "${SCAN_TIMEOUT:-30m}" --no-progress "$tmp/inventory.json"
# Trivy retains the scanned image ID in an SBOM result; only the archive records its platform.
# Annotate that provenance explicitly instead of mistaking a package inventory for a remote pull.
jq -e --slurpfile proof "$proof" '
  if .ArtifactType=="cyclonedx" and .Metadata.ImageID==$proof[0].config and (.Results|length)>0
  then . + {NodeImport: $proof[0]}
  else error("SBOM is not the verified archive inventory") end' "$tmp/scan.json" >"$result"
