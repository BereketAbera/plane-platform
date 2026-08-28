#!/usr/bin/env bash
# Scratch harness: the real script with real buildx on this arm64 Mac, copying plain amd64 manifests between two throwaway registries.
# The script's destination prefix is the only thing changed, because plane-registry on 5001 is the local platform's and is left alone.
set -uo pipefail
S="$1"; R=/Users/bek/dev/pr/plane-platform; T="$S/copy-real-tree"
rm -rf "$T"; mkdir -p "$T/scripts/ci" "$T/scripts/lib" "$T/.tools/bin" "$T/helm/plane/overlays/dev"
sed 's/localhost:5001/localhost:5074/g' "$R/scripts/ci/copy-to-local-registry.sh" >"$T/scripts/ci/copy-to-local-registry.sh"; chmod +x "$T/scripts/ci/copy-to-local-registry.sh"
cp "$R/scripts/lib/common.sh" "$T/scripts/lib/"; cp "$R/.tools/bin/yq" "$T/.tools/bin/"
: >"$T/helm/plane/overlays/dev/kustomization.yaml"
echo 'images:' >>"$T/helm/plane/overlays/dev/kustomization.yaml"
declare -a names=(web admin space backend) digests=()
for n in "${names[@]}"; do
  ref="$(python3 -B "$S/push_case.py" localhost:5073 wayline/$n amd64 "content of $n
")"
  d="${ref#*@}"; digests+=("$d")
  printf -- '- digest: %s\n  name: artifacts.plane.so/makeplane/plane-%s\n  newName: localhost:5074/wayline/%s\n' "$d" "$n" "$n" >>"$T/helm/plane/overlays/dev/kustomization.yaml"
done
"$T/scripts/ci/copy-to-local-registry.sh" localhost:5073/wayline dev; echo "script exit $?"
i=0
for n in "${names[@]}"; do
  d="${digests[$i]}"; i=$((i+1))
  accept='Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json'
  by_digest="$(curl -s -D - -o "$S/m.json" -H "$accept" "http://localhost:5074/v2/wayline/$n/manifests/$d" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')"
  body="sha256:$(shasum -a 256 "$S/m.json" | cut -d' ' -f1)"
  by_tag="$(curl -s -D - -o /dev/null -H "$accept" "http://localhost:5074/v2/wayline/$n/manifests/${d:7:12}" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')"
  mt="$(python3 -c "import json;m=json.load(open('$S/m.json'));print(m.get('mediaType'))")"
  cfg="$(python3 -c "import json;m=json.load(open('$S/m.json'));print(m['config']['digest'])")"
  arch="$(curl -s "http://localhost:5074/v2/wayline/$n/blobs/$cfg" | python3 -c "import json,sys;c=json.load(sys.stdin);print(c['os']+'/'+c['architecture'])")"
  if [[ "$by_digest" == "$d" && "$body" == "$d" && "$by_tag" == "$d" && "$arch" == linux/amd64 ]]; then r=PASS; else r=FAIL; fi
  echo "$r $n: wanted $d; by digest ${by_digest:0:19}, body ${body:0:19}, tag ${d:7:12} answers ${by_tag:0:19}; $mt; $arch"
done
