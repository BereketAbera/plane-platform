#!/usr/bin/env bash
set -uo pipefail
S="$1"; AMD="$2"; ARM="$3"
cd "$S"
t() {
  rm -f t.json
  /Users/bek/dev/pr/plane-platform/.tools/bin/trivy image --cache-dir "$S/trivy-empty-cache" --ignorefile "" --image-src remote --platform "$2" --scanners secret --insecure --exit-code 0 --format json --output t.json --no-progress --quiet "$1" 2>&1 | tail -3 | cut -c1-300
  echo "trivy exit ${PIPESTATUS[0]}, image ${1##*:} asked $2"
  [[ -s t.json ]] && python3 -c "
import json
r=json.load(open('t.json'))
c=r['Metadata'].get('ImageConfig') or {}
print('  ArtifactType',r.get('ArtifactType'),'config',c.get('os'),c.get('architecture'))"
  rm -f t.json
}
t "$AMD" linux/arm64
t "$AMD" linux/amd64
t "$ARM" linux/amd64
t "$ARM" linux/arm64
