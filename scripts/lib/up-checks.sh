#!/usr/bin/env bash
# What scripts/up.sh refuses or stops on, in one place, so scripts/restore.sh and the clean-restore drill ask
# the same questions before they delete or change anything. Source after scripts/lib/common.sh. Bash 3.2.
#
# What a new cluster costs the host, measured on 2026-11-05 with both Plane environments, Infisical and
# monitoring up. Evidence: .local/evidence-raw/dr-disk-1.txt.
#   kind /var volume   12.94 GiB by du in the node (images 10.51, volumes 1.53), 11.50 GiB by docker system df
#   local services      3.62 GiB in Docker volumes (mirrors 2.76, registry 0.86). They survive make destroy
#   kindest/node        1.19 GiB in Docker's store. It survives make destroy too
#   first install      17.8 GiB in all, so the "about 20 GiB" this guard started from was a fair estimate
#
# UP_NEW_CLUSTER_GIB is what up.sh asks for: a cluster's regrowth, 12.94, plus the 10 GiB floor that every later
# script in the same run checks through guard_disk, plus about 2. A first install from exactly 25 ends near 7.2,
# below that floor but past every guard inside make up.
# CLUSTER_UP_NEW_CLUSTER_GIB is what cluster-up.sh asks for when it runs alone: the node's volume, 12.94, plus about 2.
UP_NEW_CLUSTER_GIB=25
# shellcheck disable=SC2034 # scripts/cluster-up.sh reads it.
CLUSTER_UP_NEW_CLUSTER_GIB=15
# Of a kind volume's size, how much reached the host within 15s of removing it. Measured on a 273 MB volume:
# 254 MB back within 15s, and 15s was the first reading. A 12 GB volume has not been measured.
KIND_RECLAIM_PERCENT=93
LOW_DISK_LOG="$LOCAL_DIR/evidence-raw/low-disk-overrides.log"

# ------ Uncommitted changes -------------------------------------------------------------------------------

# Prints git's short status of what up.sh refuses. Every Application source sits under these paths, and
# Argo CD reads only commits.
up_uncommitted() { git -C "$ROOT" status --porcelain -- gitops helm monitoring infisical; }

# ------ Images only the local registry holds --------------------------------------------------------------

up_referenced_local_images() { # Each localhost:5001 reference Git deploys, once.
  grep -hoE 'localhost:5001/[^[:space:]"@]+@sha256:[a-f0-9]{64}' "$ROOT"/gitops/environments/*/manifests.yaml | sort -u || true
}

up_missing_local_images() { # Prints each localhost:5001 reference the registry cannot serve.
  local ref
  for ref in $(up_referenced_local_images); do
    docker buildx imagetools inspect "$ref" >/dev/null 2>&1 || printf '    %s\n' "$ref"
  done
}

# ------ Disk ----------------------------------------------------------------------------------------------

# ALLOW_LOW_DISK="<reason>" is the one way past a guard below. It wants words, so the log can later answer
# why, and yes answers nothing. Call this before anything else, so a bad value stops the run while nothing
# has been deleted, whatever the disk looks like today.
low_disk_check_value() {
  case "${ALLOW_LOW_DISK:-}" in
    "" | *" "*) ;;
    *) die "ALLOW_LOW_DISK takes a reason in words, which is logged, as in ALLOW_LOW_DISK=\"short by 1 GiB, and I am watching this run\". It got '$ALLOW_LOW_DISK'." ;;
  esac
}

low_disk_log() { # who what-it-went-past
  mkdir -p "${LOW_DISK_LOG%/*}"
  printf '%s %s: %s. Reason: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$ALLOW_LOW_DISK" >>"$LOW_DISK_LOG"
  warn "$1: $2. Going on, because ALLOW_LOW_DISK says: $ALLOW_LOW_DISK. Logged in ${LOW_DISK_LOG#"$ROOT"/}."
}

# guard_disk for a cluster about to be created. guard_disk itself has no way past it, and that stays true of
# the 10 GiB floor every script checks.
guard_new_cluster() { # <GiB> <who>
  local need="$1" who="$2" free
  free="$(free_disk_gib)"
  if [[ "$free" -ge "$need" ]]; then return 0; fi
  if [[ -n "${ALLOW_LOW_DISK:-}" ]]; then
    low_disk_log "$who" "only $free GiB free, and a new cluster asks for $need GiB"
    return 0
  fi
  die "only $free GiB free on the host, and a new cluster asks for $need GiB. See scripts/lib/up-checks.sh for why that many. Free space, or say why to go on with ALLOW_LOW_DISK=\"<reason>\", which is logged."
}

free_disk_kib() { df -k "$ROOT" | awk 'NR==2{print $4}'; }

kib_as_gib() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

# The Docker volume at the node's /var, as docker system df measures it. Docker prints decimal units, and the
# number is lower than du in the node, so an estimate built on it errs towards refusing. Prints KiB, or nothing
# if there is no such volume or Docker will not say.
UP_KIND_VOLUME_KIB=""
UP_KIND_VOLUME_ASKED=no
kind_volume_kib() {
  local name json size
  if [[ "$UP_KIND_VOLUME_ASKED" == no ]]; then
    UP_KIND_VOLUME_ASKED=yes
    name="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var"}}{{.Name}}{{end}}{{end}}' "$NODE_CONTAINER" 2>/dev/null || true)"
    if [[ -n "$name" ]]; then
      json="$(docker system df -v --format '{{json .Volumes}}' 2>/dev/null || true)"
      size="$(jq -r --arg n "$name" '.[] | select(.Name == $n) | .Size' <<<"${json:-[]}" 2>/dev/null || true)"
      UP_KIND_VOLUME_KIB="$(printf '%s\n' "$size" | sed -E 's/^([0-9.]+)[[:space:]]*([A-Za-z]+)$/\1 \2/' | awk '
        NF == 2 {
          unit = $2
          scale = 0
          if (unit == "B") scale = 1
          if (unit == "kB" || unit == "KB") scale = 1000
          if (unit == "MB") scale = 1000000
          if (unit == "GB") scale = 1000000000
          if (unit == "TB") scale = 1000000000000
          if (scale > 0) printf "%d", $1 * scale / 1024
        }')"
    fi
  fi
  printf '%s' "$UP_KIND_VOLUME_KIB"
}

# Free space once the existing cluster is gone: what is free now, plus the measured share of its volume. Prints
# KiB, or nothing if the volume could not be measured.
disk_after_delete_kib() {
  local volume
  volume="$(kind_volume_kib)"
  [[ -n "$volume" ]] || return 0
  printf '%s' "$(($(free_disk_kib) + volume * KIND_RECLAIM_PERCENT / 100))"
}

# One line for a plan: what is free, what a delete should bring back, and what up.sh asks for.
up_disk_report() {
  local after
  if ! cluster_exists; then
    printf '%s GiB free, no cluster to delete, up.sh asks for %s GiB' "$(kib_as_gib "$(free_disk_kib)")" "$UP_NEW_CLUSTER_GIB"
    return 0
  fi
  after="$(disk_after_delete_kib)"
  if [[ -z "$after" ]]; then
    printf '%s GiB free, the kind volume could not be measured, up.sh asks for %s GiB' "$(kib_as_gib "$(free_disk_kib)")" "$UP_NEW_CLUSTER_GIB"
    return 0
  fi
  printf '%s GiB free, kind volume %s GiB, about %s GiB after a delete at %s%%, up.sh asks for %s GiB' \
    "$(kib_as_gib "$(free_disk_kib)")" "$(kib_as_gib "$(kind_volume_kib)")" "$(kib_as_gib "$after")" "$KIND_RECLAIM_PERCENT" "$UP_NEW_CLUSTER_GIB"
}

# Prints why up.sh would refuse to create a cluster, counting a delete first if a cluster exists, and nothing if
# it would go on. The same limit and the same rounding as guard_new_cluster: free_disk_gib rounds down, and this
# compares whole KiB against whole GiB, so an answer of nothing here cannot be a refusal there for rounding.
up_disk_problem() {
  local need_kib=$((UP_NEW_CLUSTER_GIB * 1048576)) free after
  free="$(free_disk_kib)"
  if ! cluster_exists; then
    if [[ "$free" -lt "$need_kib" ]]; then
      printf 'only %s GiB free on the host, and up.sh asks for %s GiB to create a cluster' "$(kib_as_gib "$free")" "$UP_NEW_CLUSTER_GIB"
    fi
    return 0
  fi
  after="$(disk_after_delete_kib)"
  if [[ -z "$after" ]]; then
    printf 'the kind volume could not be measured, so what a delete brings back is unknown, with %s GiB free and up.sh asking for %s GiB' "$(kib_as_gib "$free")" "$UP_NEW_CLUSTER_GIB"
  elif [[ "$after" -lt "$need_kib" ]]; then
    printf 'about %s GiB would be free after the delete: %s GiB now plus %s%% of the %s GiB kind volume. up.sh asks for %s GiB to create a cluster' \
      "$(kib_as_gib "$after")" "$(kib_as_gib "$free")" "$KIND_RECLAIM_PERCENT" "$(kib_as_gib "$(kind_volume_kib)")" "$UP_NEW_CLUSTER_GIB"
  fi
}

# ------ State from a cluster that is gone -----------------------------------------------------------------

# Call only with no cluster. .local/terraform/local describes the cluster it was applied to, and destroy.sh removes
# it for that reason, but a cluster lost any other way leaves it behind. Moved aside, not deleted: it holds nothing
# a new cluster needs, and someone may want to see what the old one held.
up_move_stale_local_state() {
  local dir="$LOCAL_DIR/terraform/local" aside
  [[ -e "$dir/terraform.tfstate" ]] || return 0
  aside="$dir.stale-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$dir" "$aside"
  chmod 700 "$aside"
  warn "no cluster exists, so ${dir#"$ROOT"/} described one that is gone. Moved it to ${aside#"$ROOT"/}, and Terraform starts from an empty state."
}
