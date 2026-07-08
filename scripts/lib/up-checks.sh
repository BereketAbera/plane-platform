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
# What a cluster with nothing in it yet still has to pull, for a plan that has more to do after make up, because
# the restores that follow check the floor too. So the plan asks for this plus the floor: 12.94 for a cluster when
# the registry and mirror volumes are there, and 17.75, the first install, when they are not.
UP_PULL_CLUSTER_GIB=12.94
UP_PULL_FIRST_INSTALL_GIB=17.75
UP_LOCAL_VOLUMES="plane-platform-local_registry-data plane-platform-local_mirror-docker-data plane-platform-local_mirror-quay-data plane-platform-local_mirror-k8s-data"
# Of a kind volume's size, how much reached the host within 15s of removing it. Measured on a 273 MB volume:
# 254 MB back within 15s, and 15s was the first reading. A 12 GB volume has not been measured.
KIND_RECLAIM_PERCENT=93

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
# why, and yes or a few spaces answer nothing. Call this before anything else, so a bad value stops the run while
# nothing has been deleted, whatever the disk looks like today.
low_disk_check_value() {
  local words=()
  [[ -n "${ALLOW_LOW_DISK:-}" ]] || return 0
  read -r -a words <<<"$ALLOW_LOW_DISK"
  [[ "${#words[@]}" -lt 2 ]] || return 0
  die "ALLOW_LOW_DISK takes a reason in words, which is logged, as in ALLOW_LOW_DISK=\"short by 1 GiB, and I am watching this run\". It got '$ALLOW_LOW_DISK'."
}

low_disk_log() { # who what-it-went-past
  mkdir -p "${LOW_DISK_LOG%/*}"
  printf '%s %s: %s. Reason: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$ALLOW_LOW_DISK" >>"$LOW_DISK_LOG"
  warn "$1: $2. Going on, because ALLOW_LOW_DISK says: $ALLOW_LOW_DISK. Logged in ${LOW_DISK_LOG#"$ROOT"/}."
}

# guard_disk for a cluster about to be created. ALLOW_LOW_DISK does not go past guard_disk itself, the floor every
# script checks. Only MIN_FREE_DISK_GIB lowers that, and guard_disk logs it.
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

# For a number set beside a limit. Two decimals, like the limits, and rounded down, so what is under a limit cannot
# print as that limit, as "about 25.0 GiB ... and up.sh asks for 25 GiB" did on a plan that then refused.
kib_as_gib_down() { awk -v k="$1" 'BEGIN { printf "%.2f", int(k * 100 / 1048576) / 100 }'; }

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

# True if the registry and every mirror have their volumes, so what they hold need not be pulled again.
up_local_volumes_present() {
  # shellcheck disable=SC2086 # One word per volume, on purpose.
  docker volume inspect $UP_LOCAL_VOLUMES >/dev/null 2>&1
}

up_gib_as_kib() { awk -v g="$1" 'BEGIN { printf "%d", g * 1048576 }'; }

up_pull_plus_floor_gib() { # gib-to-pull
  awk -v p="$1" -v f="$MIN_FREE_DISK_GIB" 'BEGIN { printf "%g", p + f }'
}

# What a plan asks for when a new cluster is to be created, in GiB, whole or not. up.sh's own limit, unless this
# machine has no registry or mirror volumes yet, as on a first install: that ends past every guard in make up, and
# below the floor the restores after it check.
up_new_cluster_need_gib() {
  if up_local_volumes_present; then
    printf '%s' "$UP_NEW_CLUSTER_GIB"
  else
    awk -v n="$(up_pull_plus_floor_gib "$UP_PULL_FIRST_INSTALL_GIB")" -v u="$UP_NEW_CLUSTER_GIB" 'BEGIN { printf "%g", (n > u ? n : u) }'
  fi
}

# How a plan says why it asks for that.
up_new_cluster_need_words() {
  if up_local_volumes_present; then
    printf 'up.sh asks for %s GiB' "$UP_NEW_CLUSTER_GIB"
  else
    printf 'with no registry or mirror volumes a new cluster still has %s GiB to pull, and the restores after it check the %s GiB floor, so this asks for %s GiB' \
      "$UP_PULL_FIRST_INSTALL_GIB" "$MIN_FREE_DISK_GIB" "$(up_new_cluster_need_gib)"
  fi
}

# The same for an empty cluster that stays, which creates nothing and still has everything to pull.
up_empty_cluster_pull_gib() {
  if up_local_volumes_present; then printf '%s' "$UP_PULL_CLUSTER_GIB"; else printf '%s' "$UP_PULL_FIRST_INSTALL_GIB"; fi
}

up_empty_cluster_words() {
  printf 'this empty cluster still has %s GiB to pull, and the restores after it check the %s GiB floor, so this asks for %s GiB' \
    "$(up_empty_cluster_pull_gib)" "$MIN_FREE_DISK_GIB" "$(up_pull_plus_floor_gib "$(up_empty_cluster_pull_gib)")"
}

# One line for a plan: what is free, what a delete should bring back, and what is asked for.
up_disk_report() {
  local after
  if ! cluster_exists; then
    printf '%s GiB free, no cluster to delete, %s' "$(kib_as_gib_down "$(free_disk_kib)")" "$(up_new_cluster_need_words)"
    return 0
  fi
  after="$(disk_after_delete_kib)"
  if [[ -z "$after" ]]; then
    printf '%s GiB free, the kind volume could not be measured, %s' "$(kib_as_gib_down "$(free_disk_kib)")" "$(up_new_cluster_need_words)"
    return 0
  fi
  printf '%s GiB free, kind volume %s GiB, about %s GiB after a delete at %s%%, %s' \
    "$(kib_as_gib_down "$(free_disk_kib)")" "$(kib_as_gib_down "$(kind_volume_kib)")" "$(kib_as_gib_down "$after")" "$KIND_RECLAIM_PERCENT" "$(up_new_cluster_need_words)"
}

up_disk_report_empty_cluster() {
  printf '%s GiB free, %s' "$(kib_as_gib_down "$(free_disk_kib)")" "$(up_empty_cluster_words)"
}

# Prints why a new cluster should not be created, counting a delete first if a cluster exists, and nothing if it
# can go on. No lower than up.sh's limit, and the same rounding as guard_new_cluster: free_disk_gib rounds down, and
# this compares whole KiB against that limit, so an answer of nothing here cannot be a refusal there for rounding.
up_disk_problem() {
  local need_kib free after
  need_kib="$(up_gib_as_kib "$(up_new_cluster_need_gib)")"
  free="$(free_disk_kib)"
  if ! cluster_exists; then
    if [[ "$free" -lt "$need_kib" ]]; then
      printf 'only %s GiB free on the host, and %s to create a cluster' "$(kib_as_gib_down "$free")" "$(up_new_cluster_need_words)"
    fi
    return 0
  fi
  after="$(disk_after_delete_kib)"
  if [[ -z "$after" ]]; then
    printf 'the kind volume could not be measured, so what a delete brings back is unknown, with %s GiB free, and %s' "$(kib_as_gib_down "$free")" "$(up_new_cluster_need_words)"
  elif [[ "$after" -lt "$need_kib" ]]; then
    printf 'about %s GiB would be free after the delete: %s GiB now plus %s%% of the %s GiB kind volume, and %s to create a cluster' \
      "$(kib_as_gib_down "$after")" "$(kib_as_gib_down "$free")" "$KIND_RECLAIM_PERCENT" "$(kib_as_gib_down "$(kind_volume_kib)")" "$(up_new_cluster_need_words)"
  fi
}

# Prints why an empty cluster that stays has too little room for what is still to come, and nothing if it has enough.
up_disk_problem_empty_cluster() {
  local free
  free="$(free_disk_kib)"
  if [[ "$free" -lt "$(up_gib_as_kib "$(up_pull_plus_floor_gib "$(up_empty_cluster_pull_gib)")")" ]]; then
    printf 'only %s GiB free on the host, and %s' "$(kib_as_gib_down "$free")" "$(up_empty_cluster_words)"
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
