#!/usr/bin/env bash
# shellcheck disable=SC2034  # what is set here is read by the scripts that source this
# What publish-release.sh and check-deploy-branch.sh share about deploy/plane-prod. Source after scripts/lib/common.sh; do not execute.

BRANCH=deploy/plane-prod
CLUSTER_TREE=gitops/clusters/plane-prod
ENVIRONMENT_TREE=gitops/environments/prod

# GITHUB_TOKEN from the job's environment, read when git asks, so it is never on a command line or in .git/config.
remote_git() { # remote_git <git arguments...>
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # shellcheck disable=SC2016  # git's credential helper expands this, not this shell
    git -c credential.helper= -c 'credential.helper=!f() { test "$1" = get || return 0; printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f' "$@"
  else
    git "$@"
  fi
}

# A release copies each hosted tree from the main commit its RELEASE.json names, so the two are the same tree, object for object.
# Prints each tree that is not, or nothing. So a difference means someone pushed the branch by hand, or a release went wrong.
release_trees_that_differ() { # release_trees_that_differ <the branch's tip> <the main commit its RELEASE.json names>
  local tree
  for tree in "$CLUSTER_TREE" "$ENVIRONMENT_TREE"; do
    if [[ "$(git rev-parse --verify --quiet "$1:$tree" || true)" != "$(git rev-parse --verify --quiet "$2:$tree" || true)" ]]; then
      printf '%s\n' "$tree"
    fi
  done
}
