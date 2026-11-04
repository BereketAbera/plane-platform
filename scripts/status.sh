#!/usr/bin/env bash
# One screen of truth about the platform. Reads only; changes nothing.
source "$(dirname "$0")/lib/common.sh"

if ! cluster_exists; then echo "Cluster: not created. Run 'make up'."; exit 0; fi
state="$(docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || echo missing)"
if [[ "$state" != "running" ]]; then echo "Cluster: $state. Data is intact. Run 'make up' to resume."; exit 0; fi

log "Node"
kc get nodes --no-headers | awk '{printf "    %s %s %s\n",$1,$2,$5}'

published="$(git --git-dir="$LOCAL_DIR/git/plane-platform.git" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"
published="${published:0:8}"
log "GitOps (Argo CD applications, published main: ${published:-none})"
if kc get crd applications.argoproj.io >/dev/null 2>&1; then
  printf '    %-30s %-10s %-12s %s\n' NAME SYNC HEALTH REVISION
  # A multi-source Application has no .status.sync.revision, and lists one revision per source. A chart
  # source's is a chart version, so show the Git commit, which is the same thing in every row.
  kc -n argocd get applications -o json 2>/dev/null | jq -r '
    .items | sort_by(.metadata.name)[]
    | ((.status.sync.revisions // []) + [.status.sync.revision // empty]) as $revisions
    | [.metadata.name, (.status.sync.status // "-"), (.status.health.status // "-"),
       (($revisions | map(select(test("^[0-9a-f]{40}$"))) | .[0]) // $revisions[0] // "-")]
    | @tsv' | awk -F'\t' '{printf "    %-30s %-10s %-12s %.8s\n",$1,$2,$3,$4}' || warn "could not read the Applications"
else
  echo "    Argo CD not installed yet"
fi

log "Pods not ready"
not_ready="$(kc get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4!="Completed" && a[1]!=a[2]) print "    "$1"/"$2" "$3" "$4}')"
echo "${not_ready:-    none}"

log "Endpoints"
for url in http://plane.dev.localhost/ http://plane.prod-sim.localhost/ http://argocd.localhost/ http://grafana.localhost/ http://prometheus.localhost/ http://alertmanager.localhost/ http://infisical.localhost/; do
  # On a failed connection curl prints 000 and exits non-zero.
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)"
  if [[ -z "$code" || "$code" == 000 ]]; then code=unreachable; fi
  printf '    %-40s %s\n' "$url" "$code"
done

log "Resources"
# Docker trims leading spaces from a --format string, so the indent goes here.
printf '    %s\n' "$(docker stats --no-stream --format '{{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}' "$NODE_CONTAINER")"
kc top pods -A --no-headers 2>/dev/null | awk '{split($4,m,"M"); t[$1]+=m[1]} END{for(n in t) printf "    %-22s %6d MiB\n",n,t[n]}' | sort || true
free="$(free_disk_gib)"
echo "    Host disk free: ${free} GiB"
