#!/usr/bin/env bash
# Check the machine can carry the platform before doing anything expensive.
# Exits non-zero on hard failures. Numbers come from docs/resource-utilization.md.
source "$(dirname "$0")/lib/common.sh"

fail=0
need_cmd() { command -v "$1" >/dev/null 2>&1 && ok "$1 found" || { printf 'fail %s not found: %s\n' "$1" "$2" >&2; fail=1; }; }

log "Required host commands"
need_cmd docker "install Docker Desktop or Docker Engine"
need_cmd git "install git"
need_cmd make "install make"
need_cmd curl "install curl"
need_cmd jq "brew install jq"
need_cmd python3 "install Python 3"

log "Docker daemon"
docker info >/dev/null 2>&1 || die "Docker is not running"
mem_gib=$(docker info --format '{{.MemTotal}}' | awk '{printf "%.1f", $1/1073741824}')
cpus=$(docker info --format '{{.NCPU}}')
echo "    Docker VM: ${mem_gib} GiB memory, ${cpus} CPUs"
awk -v m="$mem_gib" 'BEGIN{exit !(m>=13)}' || {
  printf 'fail Docker has %s GiB. The full platform needs 14 GiB (Docker Desktop: Settings, Resources, Memory).\n' "$mem_gib" >&2; fail=1; }
[[ "$cpus" -ge 4 ]] || { printf 'fail %s CPUs is below the minimum of 4\n' "$cpus" >&2; fail=1; }

log "Host disk"
free=$(free_disk_gib)
echo "    ${free} GiB free on the host"
if [[ "$free" -lt 25 ]]; then
  printf 'fail %s GiB free. A first install grows Docker storage by about 20 GiB; 25 GiB is the minimum.\n' "$free" >&2; fail=1
elif [[ "$free" -lt 35 ]]; then
  warn "${free} GiB free works, but 35 GiB is recommended"
fi

log "Host ports"
for p in 80 443 5001; do
  # lsof exits 1 when nothing is listening, which is the good case.
  holder=$( { lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2{print $1}')
  if [[ -n "$holder" && "$holder" != com.docke* && "$holder" != docker* ]]; then
    printf 'fail port %s is in use by %s\n' "$p" "$holder" >&2; fail=1
  else
    ok "port $p available or held by this platform"
  fi
done

log "Name resolution for *.localhost"
for h in plane.dev.localhost plane.prod-sim.localhost; do
  if python3 -c "import socket,sys; sys.exit(0 if socket.gethostbyname(sys.argv[1])=='127.0.0.1' else 1)" "$h" 2>/dev/null; then
    ok "$h resolves to 127.0.0.1"
  else
    warn "$h does not resolve here; add it to /etc/hosts"
  fi
done

[[ "$fail" -eq 0 ]] || die "prerequisite checks failed"
ok "prerequisites satisfied"
