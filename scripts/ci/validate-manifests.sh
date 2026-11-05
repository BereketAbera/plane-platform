#!/usr/bin/env bash
# Everything Argo CD will be asked to apply, checked without a cluster: render drift, Kubernetes
# schemas, project policy, Prometheus rules, and the promotion invariant.
# SKIP_CHARTS=yes leaves out the third-party platform charts, which need network and take minutes.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

"$ROOT/scripts/install-tools.sh" helm kustomize kubeconform conftest yq promtool >/dev/null
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

# Prometheus refuses a bad rule file at reload, and the operator's admission webhook is off to save its
# certificate Job (helm/values/kube-prometheus-stack.yaml), so nothing else checks rules before that.
rule_files() { # rule_files <directory> <manifest...>: each PrometheusRule's spec, as promtool reads it
  local out="$1" name
  shift
  mkdir -p "$out"
  while read -r name; do
    NAME="$name" yq -N 'select(.kind == "PrometheusRule" and .metadata.name == strenv(NAME)) | .spec' "$@" >"$out/rules-$name.yaml"
  done < <(yq -N -r 'select(.kind == "PrometheusRule") | .metadata.name' "$@" | sort -u)
}

promtool_check() { # promtool_check <directory> [promtool flag...]: quiet unless it fails
  local dir="$1" output
  shift
  if output="$(promtool check rules "$@" "$dir"/*.yaml 2>&1)"; then
    ok "$(grep -c SUCCESS <<<"$output") rule file(s) valid"
  else
    printf '%s\n' "$output" >&2
    return 1
  fi
}

promtool_test() { # promtool_test <directory holding the rule files>
  cp tests/rules/*.test.yaml "$1/"
  (cd "$1" && promtool test rules ./*.test.yaml)
}

rule_files "$WORK/rules" "$WORK"/in-repo/*.yaml
check "promtool: platform rules" promtool_check "$WORK/rules" --lint-fatal
check "promtool: rule unit tests" promtool_test "$WORK/rules"

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
  rule_files "$WORK/chart-rules" "$WORK"/charts/*.yaml
  check "promtool: chart rules" promtool_check "$WORK/chart-rules"
  # Last, and only in the full run: it re-renders the overlays many times, so it takes some minutes.
  # negative-controls.sh sets SKIP_FLOWS, because none of its defects are in those scripts' paths.
  if [[ "${SKIP_FLOWS:-}" != yes ]]; then
    check "promotion flows with a stub cluster" "$ROOT/scripts/ci/test-promotion-flows.sh"
  fi
fi

[[ "$failed" -eq 0 ]] || die "$failed manifest check(s) failed"
ok "manifests valid"
