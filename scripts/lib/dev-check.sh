#!/usr/bin/env bash
# Has plane-dev proven what is about to reach prod-sim? A recorded digest proves dev was told to run
# it, and this asks whether dev did. promote.sh asks before a local promotion, and gitops-publish.sh
# before a publish that changes a prod-sim digest, which is how a promotion merged on GitHub arrives.
# Source this after scripts/lib/common.sh.

DEV_CHECK_LOG="$LOCAL_DIR/evidence-raw/promotion-overrides.log"
DEV_CHECK=""
PROD_SIM_MANIFESTS=gitops/environments/prod-sim/manifests.yaml

# Does a publish from <old> to <new> move an image in prod-sim? It reads the render, because that is
# what Argo CD reads. An <old> that is empty or unknown here, as on the first publish, moves nothing.
# grep reads to the end, not -q. With -q it stops at the first match, git dies of SIGPIPE on a large
# diff, and under pipefail the pipeline reads as no match.
prod_sim_digests_move() { # prod_sim_digests_move <old> <new>
  [[ -n "$1" ]] && git cat-file -e "$1" 2>/dev/null &&
    git diff "$1" "$2" -- "$PROD_SIM_MANIFESTS" | grep -E '^[-+].*@sha256:' >/dev/null
}

# The digests on added lines. An image that was only removed brings nothing to prove.
prod_sim_digests_added() { # prod_sim_digests_added <old> <new>
  git diff "$1" "$2" -- "$PROD_SIM_MANIFESTS" | sed -n 's/^+.*@\(sha256:[a-f0-9]\{64\}\).*/\1/p' | sort -u
}

# The commits behind that move, newest first, to name in a message. A merge shows no diff of its own.
commits_moving_prod_sim() { # commits_moving_prod_sim <old> <new>
  local commits
  commits="$(git log -G'@sha256:' --format='%h %s' "$1..$2" -- "$PROD_SIM_MANIFESTS")"
  printf '%s\n' "${commits:-a merge since ${1:0:12}}"
}

override_reason() { # override_reason <reason>: on one line, for the log and a commit message
  local reason
  reason="$(tr -s '[:space:]' ' ' <<<"$1")"
  printf '%s' "${reason% }"
}

refuse_unproven_dev() { # refuse_unproven_dev <what did not happen>
  die "plane-dev has not proven these digests, so prod-sim may not take them. Fix dev, or set OVERRIDE_DEV_CHECK=\"<reason>\", which is logged. $1"
}

# One problem per line, so an empty answer means dev is fine.
dev_problems() { # dev_problems <digest...>
  local status pods digest
  status="$(kc --request-timeout=10s -n argocd get application plane-dev -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [[ "$status" == Synced/Healthy ]] || echo "Application plane-dev is ${status:-unknown}, not Synced/Healthy"
  # Ready containers in pods that are not on their way out. Synced and Healthy say a rollout finished,
  # and this says it finished on this digest. The image names the digest because the overlay pins it.
  if ! pods="$(kc --request-timeout=10s -n plane-dev get pods -o json 2>/dev/null | jq -r '
    .items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")
    | (.status.containerStatuses // []) as $statuses
    | .spec.containers[] | . as $container
    | select(any($statuses[]; .name == $container.name and .ready == true))
    | $container.image')"; then
    echo "could not read the pods in namespace plane-dev"
    return 0
  fi
  for digest in "$@"; do
    grep -qF "@$digest" <<<"$pods" || echo "no ready container in namespace plane-dev runs $digest"
  done
}

record_dev_check() { # record_dev_check <overridden|not-run> <reason> <detail> <item...>
  local kind="$1" reason="$2" detail="$3" items
  shift 3
  items="$(IFS=,; printf '%s' "$*")"
  mkdir -p "$(dirname "$DEV_CHECK_LOG")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git config user.name || echo unknown)" \
    "$(basename "$0")" "$kind" "$items" "$reason" "$detail" >>"$DEV_CHECK_LOG"
}

# check_dev_proven <item...>, where an item is a digest or <image name>=<digest>. Returns 1 if the
# caller must refuse. Otherwise DEV_CHECK says what happened, for the caller to keep.
check_dev_proven() {
  local item problem problems reason digests=()
  for item in "$@"; do digests+=("${item##*=}"); done

  if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "$KUBECONFIG" ]] || ! kc --request-timeout=5s get --raw /readyz >/dev/null 2>&1; then
    # Saying so is the point. A green pull request must not read as dev having been checked.
    DEV_CHECK="skipped: no cluster in reach, so nothing checked that plane-dev is healthy or runs these digests"
    warn "plane-dev check $DEV_CHECK"
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '%s\n' "**The plane-dev check was skipped.** No cluster is in reach from here, so \`make gitops-publish\` checks dev after the merge." >>"$GITHUB_STEP_SUMMARY"
    return 0
  fi

  problems="$(dev_problems "${digests[@]}")"
  if [[ -z "$problems" ]]; then
    DEV_CHECK="passed: plane-dev was Synced and Healthy and running every digest here"
    ok "$DEV_CHECK"
    return 0
  fi

  while read -r problem; do warn "$problem"; done <<<"$problems"
  [[ -n "${OVERRIDE_DEV_CHECK:-}" ]] || return 1
  reason="$(override_reason "$OVERRIDE_DEV_CHECK")"
  record_dev_check overridden "$reason" "$(tr '\n' ';' <<<"$problems")" "$@"
  DEV_CHECK="overridden: $reason"
  warn "OVERRIDE_DEV_CHECK: going ahead anyway. Logged in ${DEV_CHECK_LOG#"$ROOT"/}: $reason"
}
