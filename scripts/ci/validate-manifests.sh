#!/usr/bin/env bash
# Everything Argo CD will be asked to apply, checked without a cluster: render drift, Kubernetes
# schemas, project policy, and the promotion invariant.
# SKIP_CHARTS=yes leaves out the third-party platform charts, which need network and take minutes.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" helm kustomize kubeconform conftest yq >/dev/null
cd "$ROOT"

K8S_VERSION=1.36.4
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCHEMA_DIR="$LOCAL_DIR/kubeconform-schemas/$K8S_VERSION"
mkdir -p "$SCHEMA_DIR" "$WORK/in-repo" "$WORK/charts"

failed=0
check() { # check <label> <command...>
  local label="$1"; shift
  log "$label"
  if "$@"; then ok "$label"; else warn "$label FAILED"; failed=$((failed + 1)); fi
}

KUBECONFORM=(kubeconform -strict -summary -output text -kubernetes-version "$K8S_VERSION"
  -schema-location "$SCHEMA_DIR/native/{{.ResourceKind}}{{.KindSuffix}}.json"
  -schema-location "$SCHEMA_DIR/crds/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

# kubeconform is built with Go's own DNS resolver, which finds no usable address on a network whose
# router mangles A records, as this host's does for raw.githubusercontent.com. curl uses the system
# resolver, so schemas are fetched here and kubeconform reads them from disk. A kind neither source
# has stays missing, and kubeconform reports it.
fetch_schemas() { # fetch_schemas <file...>
  local api_version kind group version lower suffix native crd
  while read -r api_version kind; do
    lower="$(tr '[:upper:]' '[:lower:]' <<<"$kind")"
    group="${api_version%/*}"
    version="${api_version##*/}"
    if [[ "$api_version" == */* ]]; then suffix="${group%%.*}-$version"; else suffix="$version"; fi
    suffix="$(tr '[:upper:]' '[:lower:]' <<<"$suffix")"
    native="$SCHEMA_DIR/native/$lower-$suffix.json"
    crd="$SCHEMA_DIR/crds/$group/${lower}_$version.json"
    [[ ! -s "$native" && ! -s "$crd" ]] || continue
    mkdir -p "$(dirname "$native")" "$(dirname "$crd")"
    curl -fsSL --retry 2 -o "$native" "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v$K8S_VERSION-standalone-strict/$lower-$suffix.json" 2>/dev/null ||
      curl -fsSL --retry 2 -o "$crd" "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/$group/${lower}_$version.json" 2>/dev/null ||
      rm -f "$native" "$crd"
  done < <(yq -N -r 'select(.apiVersion != null and .kind != null) | .apiVersion + " " + .kind' "$@" | sort -u)
}

ENVIRONMENT_FILES=(gitops/environments/dev/manifests.yaml gitops/environments/prod-sim/manifests.yaml)
for file in "${ENVIRONMENT_FILES[@]}"; do
  [[ -s "$file" ]] || die "$file is missing or empty: run make render"
done

# Plain directories are copied as they are, and anything with a kustomization.yaml is built.
# ConfigMaps of raw config (blackbox.yml and the like) stay out because only *.yaml is read.
collect() { # collect <directory> <label>
  local dir="$1" label="$2" target="$WORK/in-repo/$2.yaml"
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

collect gitops/applications applications
for platform_dir in gitops/platform/*/; do
  collect "${platform_dir%/}" "platform-$(basename "$platform_dir")"
done
collect gitops/bootstrap/argocd-route argocd-route
collect monitoring/manifests monitoring
collect infisical/manifests infisical
# A real Helm chart applied by Terraform: its templates are only meaningful once rendered.
helm template bootstrap gitops/bootstrap/chart --namespace argocd >"$WORK/in-repo/bootstrap.yaml"

fetch_schemas "${ENVIRONMENT_FILES[@]}" "$WORK"/in-repo/*.yaml

check "render is up to date" "$ROOT/scripts/render.sh" --check
check "kubeconform: rendered Plane" "${KUBECONFORM[@]}" "${ENVIRONMENT_FILES[@]}"
check "kubeconform: platform manifests" "${KUBECONFORM[@]}" "$WORK/in-repo"

conftest_run() { # conftest_run <namespaces, comma-separated> <files...>
  local namespaces="$1"; shift
  local args=() namespace
  for namespace in ${namespaces//,/ }; do args+=(--namespace "$namespace"); done
  conftest test --policy policy --no-color "${args[@]}" "$@"
}

check "conftest: rendered Plane" conftest_run environments,gitops,workloads,plane "${ENVIRONMENT_FILES[@]}"
check "conftest: platform manifests" conftest_run gitops,workloads,plane "$WORK"/in-repo/*.yaml
check "promotion invariant" "$ROOT/scripts/ci/check-promoted-digests.sh"

# Third-party charts are configured here but not authored here, so a missing memory limit or token
# setting in one is reported as a warning. Their values are ours, so the chart must still render
# and validate. Kinds from CRDs the catalog lacks are skipped, not failed, for this group only.
render_platform_charts() {
  local application name count=0 status=0
  while read -r application; do
    name="$(yq -r '.metadata.name' "$application")"
    while IFS=$'\t' read -r repo chart version values; do
      [[ -n "$chart" ]] || continue
      local args=(--repo "$repo" --version "$version" --kube-version "$K8S_VERSION"
        --namespace "$(yq -r '.spec.destination.namespace' "$application")")
      local value
      for value in $values; do args+=(--values "${value#\$values/}"); done
      if helm template "$name" "$chart" "${args[@]}" >"$WORK/charts/$name.yaml" 2>"$WORK/charts/$name.err"; then
        count=$((count + 1))
      else
        cat "$WORK/charts/$name.err" >&2
        warn "$name: helm template failed"
        status=1
      fi
    done < <(yq -r '
      (.spec.sources // [.spec.source])[] | select(.chart != null)
      | [.repoURL, .chart, .targetRevision, ((.helm.valueFiles // []) | join(" "))] | @tsv' "$application")
  done < <(find gitops/applications -type f -name '*.yaml' | sort)
  ok "$count platform chart(s) rendered"
  return "$status"
}

if [[ "${SKIP_CHARTS:-}" == yes ]]; then
  warn "SKIP_CHARTS=yes: third-party platform charts were not rendered"
else
  check "helm template: platform charts" render_platform_charts
  fetch_schemas "$WORK"/charts/*.yaml
  check "kubeconform: platform charts" "${KUBECONFORM[@]}" -ignore-missing-schemas "$WORK/charts"
  check "conftest: platform charts" conftest_run charts,plane "$WORK"/charts/*.yaml
fi

[[ "$failed" -eq 0 ]] || die "$failed manifest check(s) failed"
ok "manifests valid"
