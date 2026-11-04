#!/usr/bin/env bash
# Everything Argo CD will be asked to apply, checked without a cluster: render drift, Kubernetes
# schemas, project policy, and the promotion invariant.
# SKIP_CHARTS=yes leaves out the third-party platform charts, which need network and take minutes.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

"$ROOT/scripts/install-tools.sh" helm kustomize kubeconform conftest yq >/dev/null
cd "$ROOT"

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

collect_in_repo "$WORK/in-repo"

fetch_schemas "${ENVIRONMENT_FILES[@]}" "$WORK"/in-repo/*.yaml

check "render is up to date" "$ROOT/scripts/render.sh" --check
check "helm lint: bootstrap chart" helm lint --strict --quiet gitops/bootstrap/chart
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


# Third-party charts are configured here but not authored here, so a missing memory limit is reported
# as a warning. Their values are ours, so the chart must still render and validate, and every image it
# runs must be pinned. Kinds from CRDs the catalog lacks are skipped, not failed, for this group only.
if [[ "${SKIP_CHARTS:-}" == yes ]]; then
  warn "SKIP_CHARTS=yes: third-party platform charts were not rendered"
else
  check "helm template: platform charts" render_platform_charts "$WORK/charts"
  fetch_schemas "$WORK"/charts/*.yaml
  check "kubeconform: platform charts" "${KUBECONFORM[@]}" -ignore-missing-schemas "$WORK/charts"
  check "conftest: platform charts" conftest_run charts,plane "$WORK"/charts/*.yaml
fi

[[ "$failed" -eq 0 ]] || die "$failed manifest check(s) failed"
ok "manifests valid"
