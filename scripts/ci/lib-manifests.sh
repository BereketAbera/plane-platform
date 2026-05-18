#!/usr/bin/env bash
# What this platform asks Kubernetes to run, gathered without a cluster. validate-manifests.sh and
# scan-images.sh both read it, so they cannot disagree. Source this after scripts/lib/common.sh, from
# the repository root, with yq, helm and kustomize installed.

K8S_VERSION=1.36.4

# Plain directories are copied as they are, and anything with a kustomization.yaml is built.
# ConfigMaps of raw config (blackbox.yml and the like) stay out because only *.yaml is read.
collect() { # collect <directory> <output file>
  local dir="$1" target="$2"
  [[ -d "$dir" ]] || { warn "$dir does not exist, skipping"; return 0; }
  if [[ -f "$dir/kustomization.yaml" ]]; then
    kustomize build "$dir" >"$target"
  else
    local file
    while read -r file; do
      printf -- '---\n'
      cat "$file"
    done < <(find "$dir" -type f -name '*.yaml' | sort) >"$target"
  fi
}

collect_in_repo() { # collect_in_repo <directory>: one file per source, everything this repository authors
  local out="$1" platform_dir
  mkdir -p "$out"
  collect gitops/applications "$out/applications.yaml"
  for platform_dir in gitops/platform/*/; do
    collect "${platform_dir%/}" "$out/platform-$(basename "$platform_dir").yaml"
  done
  collect gitops/bootstrap/argocd-route "$out/argocd-route.yaml"
  collect monitoring/manifests "$out/monitoring.yaml"
  collect infisical/manifests "$out/infisical.yaml"
  # A real Helm chart applied by Terraform: its templates are only meaningful once rendered.
  helm template bootstrap gitops/bootstrap/chart --namespace argocd >"$out/bootstrap.yaml"
}

render_chart() { # render_chart <output directory> <release> <namespace> <repository> <chart> <version> <values file...>
  local out="$1" release="$2" namespace="$3" repo="$4" chart="$5" version="$6" value
  shift 6
  local args=(--repo "$repo" --version "$version" --kube-version "$K8S_VERSION" --namespace "$namespace")
  for value in "$@"; do args+=(--values "$value"); done
  if ! helm template "$release" "$chart" "${args[@]}" >"$out/$release.yaml" 2>"$out/$release.err"; then
    cat "$out/$release.err" >&2
    warn "$release: helm template failed"
    return 1
  fi
}

# Every third-party chart this platform installs: one for each Application with a chart source, plus
# Argo CD, the one chart Terraform installs. The .err files stay beside the renders, so read *.yaml.
render_platform_charts() { # render_platform_charts <directory>
  local out="$1" application name repo chart version values value count=0 status=0
  mkdir -p "$out"
  while read -r application; do
    name="$(yq -r '.metadata.name' "$application")"
    while IFS=$'\t' read -r repo chart version values; do
      [[ -n "$chart" ]] || continue
      local files=()
      for value in $values; do files+=("${value#\$values/}"); done
      if render_chart "$out" "$name" "$(yq -r '.spec.destination.namespace' "$application")" "$repo" "$chart" "$version" ${files[@]+"${files[@]}"}; then
        count=$((count + 1))
      else
        status=1
      fi
    done < <(yq -r '
      (.spec.sources // [.spec.source])[] | select(.chart != null)
      | [.repoURL, .chart, .targetRevision, ((.helm.valueFiles // []) | join(" "))] | @tsv' "$application")
  done < <(find gitops/applications -type f -name '*.yaml' | sort)

  local release=infrastructure/terraform/modules/argocd/main.tf
  terraform_field() { awk -v field="$1" '/^resource "helm_release" "argocd"/ { inside = 1 } inside && $1 == field { gsub(/"/, "", $3); print $3; exit } inside && /^}/ { exit }' "$release"; }
  if render_chart "$out" "$(terraform_field name)" argocd "$(terraform_field repository)" "$(terraform_field chart)" "$(terraform_field version)" helm/values/argocd.yaml; then
    count=$((count + 1))
  else
    status=1
  fi

  ok "$count platform chart(s) rendered"
  return "$status"
}
