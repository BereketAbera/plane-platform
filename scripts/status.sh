#!/usr/bin/env bash
# One screen of truth about the platform. Reads only; changes nothing.
source "$(dirname "$0")/lib/common.sh"

if ! cluster_exists; then echo "Cluster: not created. Run 'make up'."; exit 0; fi
state="$(docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || echo missing)"
if [[ "$state" != "running" ]]; then echo "Cluster: $state. Data is intact. Run 'make up' to resume."; exit 0; fi

log "Node"
kc get nodes --no-headers | awk '{printf "    %s %s %s\n",$1,$2,$5}'

log "GitOps (Argo CD applications)"
if kc get crd applications.argoproj.io >/dev/null 2>&1; then
  kc -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' --sort-by=.metadata.name 2>/dev/null \
    | awk 'NR==1{print "    "$0;next}{printf "    %-30s %-10s %-12s %.8s\n",$1,$2,$3,$4}'
else
  echo "    Argo CD not installed yet"
fi

log "Pods not ready"
not_ready="$(kc get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4!="Completed" && a[1]!=a[2]) print "    "$1"/"$2" "$3" "$4}')"
echo "${not_ready:-    none}"

log "Endpoints"
for url in http://plane.dev.localhost/ http://plane.prod-sim.localhost/ http://argocd.localhost/ http://grafana.localhost/ http://prometheus.localhost/ http://alertmanager.localhost/ http://infisical.localhost/; do
  printf '    %-40s %s\n' "$url" "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || echo unreachable)"
done

log "Resources"
docker stats --no-stream --format '    {{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}' "$NODE_CONTAINER"
kc top pods -A --no-headers 2>/dev/null | awk '{split($4,m,"M"); t[$1]+=m[1]} END{for(n in t) printf "    %-22s %6d MiB\n",n,t[n]}' | sort || true
free="$(free_disk_gib)"
echo "    Host disk free: ${free} GiB"
