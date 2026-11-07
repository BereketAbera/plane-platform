#!/usr/bin/env bash
set -uo pipefail
S="$1"; C="$S/scan-tree/.local/trivy-cache"; T=/Users/bek/dev/pr/plane-platform/.tools/bin/trivy
cat >"$S/trivy-mirror.yaml" <<'YAML'
registry:
  mirrors:
    index.docker.io:
      - mirror.gcr.io
YAML
for img in docker.io/library/nginx:1.31-alpine@sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606 docker.io/makeplane/plane-space:v1.4.3@sha256:af9b955874a2ea44f5121bc669200074428081301f950a8e4eeaf1a140e98a88 docker.io/makeplane/plane-backend:v1.4.3@sha256:9b75bf46cf4ffa94272a337450ab96a4577f2b81ceff00def11f5c71eb8dd743; do
  for p in linux/amd64 linux/arm64; do
    out="$S/base-$(basename "${img%%:*}")-${p#*/}.json"
    "$T" image --config "$S/trivy-mirror.yaml" --cache-dir "$C" --skip-db-update --ignorefile "" --image-src remote --platform "$p" --scanners vuln --parallel 2 --severity CRITICAL --exit-code 0 --format json --output "$out" --timeout 20m --no-progress --quiet "$img" >>"$S/trivy-bases.log" 2>&1 || echo "trivy failed $img $p"
  done
done
python3 - "$S" <<'PY'
import glob,json,sys,os,re
S=sys.argv[1]
sets={}
for f in sorted(glob.glob(S+'/base-*.json')):
    r=json.load(open(f))
    arch=r['Metadata']['ImageConfig']['architecture']
    name=os.path.basename(f).split('-',1)[1].rsplit('-',1)[0]
    found=set()
    for res in r.get('Results') or []:
        for v in res.get('Vulnerabilities') or []:
            if v.get('FixedVersion'):
                found.add((v['VulnerabilityID'],v['PkgName'],v['InstalledVersion'],v['FixedVersion']))
    sets[(name,arch)]=found
    print(name,arch,len(found),'CRITICAL with a fix')
for name in {k[0] for k in sets}:
    a,b=sets.get((name,'amd64'),set()),sets.get((name,'arm64'),set())
    print('==',name,'only on amd64:',sorted(a-b),'only on arm64:',sorted(b-a))
    print('   on both:',sorted(a&b))
PY
