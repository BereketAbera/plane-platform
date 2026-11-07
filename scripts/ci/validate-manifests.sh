#!/usr/bin/env bash
# Everything Argo CD will be asked to apply, on either cluster, checked without one: render drift, Kubernetes
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
HOSTED_K8S_VERSION="$(hosted_k8s_version)"
mkdir -p "$WORK/in-repo" "$WORK/charts" "$WORK/hosted"

failed=0
check() { # check <label> <command...>
  local label="$1"; shift
  log "$label"
  if "$@"; then ok "$label"; else warn "$label FAILED"; failed=$((failed + 1)); fi
}

schema_dir() { printf '%s/kubeconform-schemas/%s' "$LOCAL_DIR" "$1"; }
KUBECONFORM=(kubeconform -strict -summary -output text -kubernetes-version "$K8S_VERSION"
  -schema-location "$(schema_dir "$K8S_VERSION")/native/{{.ResourceKind}}{{.KindSuffix}}.json"
  -schema-location "$(schema_dir "$K8S_VERSION")/crds/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
# The same for what K3s runs, because hosted production is not on kind's version.
HOSTED_KUBECONFORM=(kubeconform -strict -summary -output text -kubernetes-version "$HOSTED_K8S_VERSION"
  -schema-location "$(schema_dir "$HOSTED_K8S_VERSION")/native/{{.ResourceKind}}{{.KindSuffix}}.json"
  -schema-location "$(schema_dir "$HOSTED_K8S_VERSION")/crds/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

# kubeconform is built with Go's own DNS resolver, which finds no usable address on a network whose
# router mangles A records, as this host's does for raw.githubusercontent.com. curl uses the system
# resolver, so schemas are fetched here and kubeconform reads them from disk. A kind neither source
# has stays missing, and kubeconform reports it.
fetch_schemas() { # fetch_schemas <kubernetes version> <file...>
  local kubernetes="$1" directory api_version kind group version lower suffix native crd
  shift
  directory="$(schema_dir "$kubernetes")"
  while read -r api_version kind; do
    lower="$(tr '[:upper:]' '[:lower:]' <<<"$kind")"
    group="${api_version%/*}"
    version="${api_version##*/}"
    if [[ "$api_version" == */* ]]; then suffix="${group%%.*}-$version"; else suffix="$version"; fi
    suffix="$(tr '[:upper:]' '[:lower:]' <<<"$suffix")"
    native="$directory/native/$lower-$suffix.json"
    crd="$directory/crds/$group/${lower}_$version.json"
    [[ ! -s "$native" && ! -s "$crd" ]] || continue
    mkdir -p "$(dirname "$native")" "$(dirname "$crd")"
    curl -fsSL --retry 2 -o "$native" "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v$kubernetes-standalone-strict/$lower-$suffix.json" 2>/dev/null ||
      curl -fsSL --retry 2 -o "$crd" "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/$group/${lower}_$version.json" 2>/dev/null ||
      rm -f "$native" "$crd"
  done < <(yq -N -r 'select(.apiVersion != null and .kind != null) | .apiVersion + " " + .kind' "$@" | sort -u)
}

ENVIRONMENT_FILES=(gitops/environments/dev/manifests.yaml gitops/environments/prod-sim/manifests.yaml)
HOSTED_RENDER="$HOSTED_ENVIRONMENT/manifests.yaml"
for file in "${ENVIRONMENT_FILES[@]}" "$HOSTED_RENDER"; do
  [[ -s "$file" ]] || die "$file is missing or empty: run make render"
done

collect_in_repo "$WORK/in-repo"
collect_hosted "$WORK/hosted"
has_yaml() { compgen -G "$1/*.yaml" >/dev/null; }

fetch_schemas "$K8S_VERSION" "${ENVIRONMENT_FILES[@]}" "$WORK"/in-repo/*.yaml
fetch_schemas "$HOSTED_K8S_VERSION" "$HOSTED_RENDER"
if has_yaml "$WORK/hosted"; then fetch_schemas "$HOSTED_K8S_VERSION" "$WORK"/hosted/*.yaml; fi

check "render is up to date" "$ROOT/scripts/render.sh" --check
check "render is up to date: hosted" "$ROOT/scripts/render.sh" --env prod --check
check "helm lint: bootstrap chart" helm lint --strict --quiet gitops/bootstrap/chart
check "kubeconform: rendered Plane" "${KUBECONFORM[@]}" "${ENVIRONMENT_FILES[@]}"
check "kubeconform: platform manifests" "${KUBECONFORM[@]}" "$WORK/in-repo"
check "kubeconform: hosted render" "${HOSTED_KUBECONFORM[@]}" "$HOSTED_RENDER"

conftest_run() { # conftest_run <namespaces, comma-separated> <files...>
  local namespaces="$1"; shift
  local args=() namespace
  for namespace in ${namespaces//,/ }; do args+=(--namespace "$namespace"); done
  conftest test --policy policy --no-color "${args[@]}" "$@"
}

# Everything Argo CD applies to hosted production, read at once, so policy/hosted_combined.rego can say an object is there at all, which no
# rule reading one object at a time can.
conftest_hosted_together() {
  local files=("$WORK"/hosted-charts/*.yaml)
  if has_yaml "$WORK/hosted"; then files+=("$WORK"/hosted/*.yaml); fi
  conftest test --combine --policy policy --no-color --namespace hosted_combined "${files[@]}"
}

check "conftest: rendered Plane" conftest_run environments,gitops,workloads,plane "${ENVIRONMENT_FILES[@]}"
check "conftest: platform manifests" conftest_run gitops,workloads,plane "$WORK"/in-repo/*.yaml
check "conftest: hosted render" conftest_run environments,gitops,workloads,plane,hosted "$HOSTED_RENDER"
check "promotion invariant" "$ROOT/scripts/ci/check-promoted-digests.sh"

# The hosted tree, once it holds anything. Its copies of local manifests are read here and not as local ones, so the local
# checks above stay as they are and neither cluster's result depends on the other's files.
if has_yaml "$WORK/hosted"; then
  if [[ -f "$HOSTED_TREE/bootstrap-chart/Chart.yaml" ]]; then
    check "helm lint: hosted bootstrap chart" helm lint --strict --quiet "$HOSTED_TREE/bootstrap-chart"
  fi
  check "kubeconform: hosted tree" "${HOSTED_KUBECONFORM[@]}" "$WORK/hosted"
  check "conftest: hosted tree" conftest_run gitops,workloads,plane,hosted "$WORK"/hosted/*.yaml
  check "hosted tree stands alone" hosted_tree_stands_alone "$WORK/hosted-alone"
  check "hosted tree: every image is listed" hosted_images_listed some "$WORK"/hosted/*.yaml
  check "hosted Alloy scrubs a Telegram bot token" alloy_scrubs_the_telegram_token "$HOSTED_TREE/values/alloy.yaml"
fi

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

promtool_test() { # promtool_test <directory holding the rule files> <test file...>
  local dir="$1"
  shift
  cp "$@" "$dir/"
  (cd "$dir" && promtool test rules ./*.test.yaml)
}

# Each set of tests next to the rules of its own cluster: tests/rules/hosted*.test.yaml names rule files only that tree renders.
LOCAL_RULE_TESTS=()
HOSTED_RULE_TESTS=()
for file in tests/rules/*.test.yaml; do
  case "${file##*/}" in
    hosted*) HOSTED_RULE_TESTS+=("$file") ;;
    *) LOCAL_RULE_TESTS+=("$file") ;;
  esac
done

rule_files "$WORK/rules" "$WORK"/in-repo/*.yaml
check "promtool: platform rules" promtool_check "$WORK/rules" --lint-fatal
check "promtool: rule unit tests" promtool_test "$WORK/rules" "${LOCAL_RULE_TESTS[@]}"

if has_yaml "$WORK/hosted"; then rule_files "$WORK/hosted-rules" "$WORK"/hosted/*.yaml; fi
if [[ -d "$WORK/hosted-rules" ]] && has_yaml "$WORK/hosted-rules"; then
  check "promtool: hosted rules" promtool_check "$WORK/hosted-rules" --lint-fatal
fi
if [[ ${#HOSTED_RULE_TESTS[@]} -gt 0 ]]; then
  # No guard on the rules here: a test for rules that did not render must fail, not pass with nothing to read.
  mkdir -p "$WORK/hosted-rules"
  check "promtool: hosted rule unit tests" promtool_test "$WORK/hosted-rules" "${HOSTED_RULE_TESTS[@]}"
fi

# Third-party charts are configured here but not authored here, so a missing memory limit is reported
# as a warning. Their values are ours, so the chart must still render and validate, and every image it
# runs must be pinned. Kinds from CRDs the catalog lacks are skipped, not failed, for this group only.
if [[ "${SKIP_CHARTS:-}" == yes ]]; then
  warn "SKIP_CHARTS=yes: third-party platform charts were not rendered"
else
  check "helm template: platform charts" render_platform_charts "$WORK/charts"
  fetch_schemas "$K8S_VERSION" "$WORK"/charts/*.yaml
  check "kubeconform: platform charts" "${KUBECONFORM[@]}" -ignore-missing-schemas "$WORK/charts"
  check "conftest: platform charts" conftest_run charts,plane "$WORK"/charts/*.yaml
  rule_files "$WORK/chart-rules" "$WORK"/charts/*.yaml
  check "promtool: chart rules" promtool_check "$WORK/chart-rules"

  check "helm template: hosted charts" render_hosted_charts "$WORK/hosted-charts"
  if has_yaml "$WORK/hosted-charts"; then
    fetch_schemas "$HOSTED_K8S_VERSION" "$WORK"/hosted-charts/*.yaml
    check "kubeconform: hosted charts" "${HOSTED_KUBECONFORM[@]}" -ignore-missing-schemas "$WORK/hosted-charts"
    check "conftest: hosted charts" conftest_run charts,plane,hosted "$WORK"/hosted-charts/*.yaml
    check "conftest: hosted tree and charts together" conftest_hosted_together
    check "hosted tree and charts: the images are what the list says" hosted_images_listed all "$WORK"/hosted/*.yaml "$WORK"/hosted-charts/*.yaml
    rule_files "$WORK/hosted-chart-rules" "$WORK"/hosted-charts/*.yaml
    if has_yaml "$WORK/hosted-chart-rules"; then
      check "promtool: hosted chart rules" promtool_check "$WORK/hosted-chart-rules"
    fi
  fi
  # Last, and only in the full run: it re-renders the overlays many times, so it takes some minutes.
  # negative-controls.sh sets SKIP_FLOWS, because none of its defects are in those scripts' paths.
  if [[ "${SKIP_FLOWS:-}" != yes ]]; then
    check "promotion flows with a stub cluster" "$ROOT/scripts/ci/test-promotion-flows.sh"
  fi
fi

[[ "$failed" -eq 0 ]] || die "$failed manifest check(s) failed"
ok "manifests valid"
