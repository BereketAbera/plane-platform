#!/usr/bin/env bash
# Check the machine can carry the platform before doing anything expensive.
# Exits non-zero on hard failures. Numbers come from docs/resource-utilization.md.
#
# The pinned CLIs are not checked here: scripts/install-tools.sh puts them in .tools/bin. To find what
# else the scripts run, grep the shell scripts for words at command position, then read each hit,
# because much of it runs inside a pod or a container (psql, pg_dump, sha256sum, stat -c).
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

fail=0
missing() { printf 'fail %s not found: %s\n' "$1" "$2" >&2; fail=1; }
need_cmd() { if command -v "$1" >/dev/null 2>&1; then ok "$1 found"; else missing "$1" "$2"; fi; }
need_docker_plugin() { if docker "$1" version >/dev/null 2>&1; then ok "docker $1 found"; else missing "docker $1" "$2"; fi; }
want_cmd() { if command -v "$1" >/dev/null 2>&1; then ok "$1 found"; else warn "$1 not found: $2"; fi; }

log "Required host commands"
need_cmd docker "install Docker Desktop or Docker Engine"
need_docker_plugin compose "install the Docker Compose plugin (Docker Desktop includes it)"
need_docker_plugin buildx "install the Docker Buildx plugin (Docker Desktop includes it)"
need_cmd git "install git"
need_cmd make "install make"
need_cmd curl "install curl"
need_cmd jq "brew install jq"
need_cmd python3 "install Python 3"
need_cmd openssl "install OpenSSL"
need_cmd lsof "install lsof"
need_cmd tar "install tar"
need_cmd unzip "install unzip"
need_cmd shasum "it comes with Perl (Debian and Ubuntu: perl, Fedora: perl-Digest-SHA)"

# These ship with every system this runs on, so one line is enough unless one really is missing.
base_utilities="awk basename cat chmod cp cut date df diff dirname du env find grep head install ln mkdir mktemp mv rm sed sleep sort tail tee touch tr uname uniq wc xargs"
missing_utilities=""
for utility in $base_utilities; do
  command -v "$utility" >/dev/null 2>&1 || missing_utilities="$missing_utilities $utility"
done
if [[ -z "$missing_utilities" ]]; then
  ok "base utilities found ($(wc -w <<<"$base_utilities" | tr -d ' ') checked)"
else
  missing "base utilities:$missing_utilities" "install your system's coreutils, diffutils, findutils, grep, sed and gawk packages"
fi

log "Host commands only 'make images' needs (a warning here does not stop the platform)"
# apps/wayline/scripts/build.sh switches to Node 22 through nvm by itself, and corepack comes with Node.
if [[ "$(node -v 2>/dev/null || true)" == v22.* ]] && command -v corepack >/dev/null 2>&1; then
  ok "Node 22 and corepack found"
elif [[ -s "$HOME/.nvm/nvm.sh" ]] && compgen -G "$HOME/.nvm/versions/node/v22.*" >/dev/null; then
  ok "Node 22 found through nvm"
else
  warn "Node 22 with corepack not found: install it with nvm install 22"
fi
want_cmd rsync "install rsync"
want_cmd perl "install Perl"

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
# Without lsof the check below would see no holder and report every port as free.
if ! command -v lsof >/dev/null 2>&1; then
  printf 'fail ports 80, 443 and 5001 were not checked, because lsof is missing\n' >&2; fail=1
else
  for p in 80 443 5001; do
    # lsof exits 1 when nothing is listening, which is the good case.
    holder=$( { lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2{print $1}')
    if [[ -n "$holder" && "$holder" != com.docke* && "$holder" != docker* ]]; then
      printf 'fail port %s is in use by %s\n' "$p" "$holder" >&2; fail=1
    else
      ok "port $p available or held by this platform"
    fi
  done
fi

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
