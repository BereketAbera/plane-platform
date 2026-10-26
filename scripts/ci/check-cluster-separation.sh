#!/usr/bin/env bash
# Two clusters share this repository, and nothing of one may reach into the other. A local marker in the hosted tree is a
# copy that was not adapted, which fails at sync or, worse, works by accident. A hosted name in a local tree would let kind's
# root or a local script see production. Run by scripts/ci/lint.sh, so by make ci and CI alike.
#
#   no plane-git, localhost:5001, *.localhost, kind-<name> or kind's address pool in the hosted trees and scripts
#   no gitops/clusters, no plane-prod, no grafana.bereket.dev, no infisical.bereket.dev and no app's host in the local trees
#     (plane-prod-sim is a local name)
#   no kubectl in scripts/hosted except through the kubeconfig and context lib.sh sets
#
# Reads what Git would track, so CI and make ci see the same files. Markdown is left out, because prose may say why not.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
cd "$ROOT"

problems=0
problem() { warn "$*"; problems=$((problems + 1)); }

files_under() { # files_under <path...>: tracked and new files, not ignored ones
  local file
  while read -r file; do
    if [[ -f "$file" ]]; then printf '%s\n' "$file"; fi
  done < <(git ls-files --cached --others --exclude-standard -- "$@" ':(exclude)*.md')
}

matches() { # matches <extended regex> <path...>: file:line:text of each hit
  local regex="$1"
  shift
  files_under "$@" | tr '\n' '\0' | xargs -0 grep -nIE "$regex" /dev/null || true
}

report() { # report <what is wrong> <hits>
  local hit
  while read -r hit; do
    [[ -z "$hit" ]] || problem "$1: $hit"
  done <<<"$2"
}

# Hosted production's own. scripts/hosted is the only way to reach it.
HOSTED_PATHS=(gitops/clusters/plane-prod gitops/environments/prod helm/plane/overlays/prod scripts/hosted
  infrastructure/hosted infrastructure/terraform/environments/prod infrastructure/terraform/environments/prod-host)

# What kind reads, or what stands up the local platform. The hosted cluster has its own copy of whatever it needs from these.
# Shared with it on purpose, so left out: policy/, scripts/ci/, the Terraform modules and infisical/terraform, each of
# which knows both clusters by name or takes the difference as an input.
LOCAL_PATHS=(gitops/applications gitops/platform gitops/bootstrap gitops/environments/dev gitops/environments/prod-sim
  helm/plane/overlays/dev helm/plane/overlays/prod-sim helm/plane/components helm/values
  infrastructure/kind infrastructure/local-services infrastructure/terraform/environments/local
  monitoring/manifests infisical/manifests
  scripts/lib/common.sh scripts/up.sh scripts/cluster-up.sh scripts/down.sh scripts/destroy.sh scripts/status.sh
  scripts/gitops-publish.sh scripts/promote.sh scripts/rollback.sh scripts/backup.sh scripts/restore.sh
  scripts/test.sh scripts/logs.sh scripts/rotate.sh monitoring/ops/lib.sh)

report "a local marker in the hosted trees" "$(matches 'plane-git|localhost:5001|[[:alnum:]-]\.localhost([^[:alnum:]-]|$)|(^|[^[:alnum:]_-])kind-[[:alnum:]]' "${HOSTED_PATHS[@]}")"

# Docker's default pool, which means kind's gateway and nothing on the VPS. An except list may name it, as private space.
report "kind's address pool allowed in the hosted trees" "$(matches '172\.16\.0\.0/12' "${HOSTED_PATHS[@]}" | { grep -v 'except:' || true; })"

report "a hosted path in a local tree" "$(matches 'gitops/clusters' "${LOCAL_PATHS[@]}")"

# plane-prod-sim is the one name that may start this way, and ERE has no lookahead.
report "the hosted cluster's name in a local tree" "$(matches 'plane-prod($|[^-]|-($|[^s])|-s($|[^i])|-si($|[^m]))' "${LOCAL_PATHS[@]}")"

# policy/plane.rego lets that one route go without the allow list, and only this keeps a copy of it off the local cluster's Traefik.
report "the hosted Grafana host in a local tree" "$(matches 'grafana\.bereket\.dev' "${LOCAL_PATHS[@]}")"

# The same for Infisical's four routes, which hold the secret store's own login.
report "the hosted Infisical host in a local tree" "$(matches 'infisical\.bereket\.dev' "${LOCAL_PATHS[@]}")"

# The apps' public hosts, which policy/hosted.rego binds to their namespaces on the hosted trees alone. A local script that dials one
# reaches production, and a local route on one answers for it on the laptop.
report "a hosted app's host in a local tree" "$(matches '(frameflow|rillmark|devops)\.bereket\.dev' "${LOCAL_PATHS[@]}")"

# A kubectl of its own would follow whatever KUBECONFIG and current context this shell has, which may be kind's. On the node
# it is `k3s kubectl`, which reaches only that node. Installing the tool is not running it.
bare_kubectl() {
  local hit text
  while read -r hit; do
    [[ -n "$hit" ]] || continue
    text="${hit#*:*:}"
    case "$text" in
      *'--kubeconfig'*'--context'*) continue ;;
      *'k3s kubectl'*) continue ;;
      *install-tools.sh*) continue ;;
    esac
    if [[ "$text" =~ ^[[:space:]]*# ]]; then continue; fi
    printf '%s\n' "$hit"
  done < <(matches '(^|[^-_.[:alnum:]])kubectl($|[^-_.[:alnum:]])' scripts/hosted)
}
report "kubectl with no --kubeconfig and --context, so use kc from scripts/hosted/lib.sh" "$(bare_kubectl)"

[[ "$problems" -eq 0 ]] || die "$problems separation problem(s) between the two clusters"
ok "the local and hosted trees name nothing of each other"
