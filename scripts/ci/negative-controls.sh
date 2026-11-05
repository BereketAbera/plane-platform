#!/usr/bin/env bash
# Proves the CI checks can fail. A green run proves little on its own, so this plants one defect at
# a time in a throwaway clone of HEAD, runs the script that should catch it, and requires a non-zero
# exit plus the failure line of the check that exists for that defect.
#
#   scripts/ci/negative-controls.sh           every control, several minutes
#   scripts/ci/negative-controls.sh trivy     only the controls whose name contains "trivy"
#
# Nothing is committed to this repository and nothing is pushed: the clone has no remote and is
# deleted at the end. Every fake token is generated here, at run time, and never printed. make ci
# does not run this, because each control re-runs a whole script. Needs a full clone of history.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" shellcheck actionlint zizmor conftest terraform tflint hadolint \
  helm kustomize kubeconform yq gitleaks trivy >/dev/null

FILTER="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CLONE="$WORK/repo"
git clone --quiet "$ROOT" "$CLONE"
git -C "$CLONE" remote remove origin
BASE="$(git -C "$CLONE" rev-parse HEAD)"

# Tools and caches are gitignored. Share them, so no control fetches them again. KUBECONFIG belongs to
# the clone and does not exist, so nothing run here can reach a cluster.
mkdir -p "$CLONE/.tools" "$CLONE/.local" "$LOCAL_DIR/kubeconform-schemas" "$LOCAL_DIR/trivy-cache"
ln -s "$ROOT/.tools/bin" "$CLONE/.tools/bin"
ln -s "$LOCAL_DIR/kubeconform-schemas" "$CLONE/.local/kubeconform-schemas"
ln -s "$LOCAL_DIR/trivy-cache" "$CLONE/.local/trivy-cache"

DEV_RENDERED=gitops/environments/dev/manifests.yaml
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
PROD_SIM_OVERLAY=helm/plane/overlays/prod-sim/kustomization.yaml
TERRAFORM_ROOT=infrastructure/terraform/environments/local
total=0
missed=0

# A Python one-liner, because sed differs between macOS and the Linux runners.
replace_first() { # replace_first <file> <regex> <replacement>
  python3 -B -c 'import re,sys; p,r,n=sys.argv[1:4]; s=open(p).read(); t,c=re.subn(r,n,s,count=1); assert c==1,"no match for "+r; open(p,"w").write(t)' "$@"
}

replace_every() { # replace_every <file> <text> <replacement>
  python3 -B -c 'import sys; p,o,n=sys.argv[1:4]; s=open(p).read(); assert o in s,"no match for "+o; open(p,"w").write(s.replace(o,n))' "$@"
}

fake_token() {
  python3 -B -c 'import secrets,string; print("ghp_"+"".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(36)))'
}

plant_secret_in_rendered() {
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: planted\n  namespace: plane-dev\nstringData:\n  note: planted\n' >>"$DEV_RENDERED"
}
plant_image_without_digest() { replace_first "$DEV_RENDERED" '@sha256:[a-f0-9]{64}' ''; }
plant_render_drift() { printf '# planted\n' >>"$DEV_RENDERED"; }
plant_unknown_field() { replace_first "$DEV_RENDERED" '(?m)^(\s+)replicas:' '\1replicaz:'; }
plant_digest_never_in_dev() {
  local digest fake
  digest="$(yq -r '.images[0].digest' "$PROD_SIM_OVERLAY")"
  fake="sha256:$(printf 'a%.0s' {1..64})"
  replace_every "$PROD_SIM_OVERLAY" "$digest" "$fake"
  replace_every "$PROD_SIM_RENDERED" "$digest" "$fake"
}
plant_digest_under_another_image() {
  local web admin
  web="$(yq -r '.images[] | select(.name | test("plane-frontend$")) | .digest' "$PROD_SIM_OVERLAY")"
  admin="$(yq -r '.images[] | select(.name | test("plane-admin$")) | .digest' "$PROD_SIM_OVERLAY")"
  replace_every "$PROD_SIM_OVERLAY" "$web" "$admin"
  replace_every "$PROD_SIM_RENDERED" "$web" "$admin"
}
plant_plane_application_in_platform() { replace_first gitops/applications/plane-dev.yaml 'project: plane-dev' 'project: platform'; }
plant_application_in_default() { replace_first gitops/applications/loki.yaml 'project: platform' 'project: default'; }
plant_dev_route_on_prod_sim_host() { replace_first "$DEV_RENDERED" 'Host\(`plane\.dev\.localhost`\)' 'Host(`plane.prod-sim.localhost`)'; }
plant_route_with_no_host() { replace_first "$DEV_RENDERED" 'Host\(`plane\.dev\.localhost`\) && PathPrefix\(`/`\)' 'PathPrefix(`/`)'; }
plant_bitnami_image() {
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: planted\n  namespace: monitoring\nspec:\n  containers:\n    - name: planted\n      image: docker.io/bitnami/postgresql:17\n' >gitops/platform/network-policies/planted.yaml
}
plant_bitnami_chart_in_terraform() {
  printf 'locals {\n  planted = "oci://registry-1.docker.io/bitnamicharts/postgresql"\n}\n' >"$TERRAFORM_ROOT/planted.tf"
}
plant_chart_image_without_digest() { yq -i 'del(.image.digest)' helm/values/traefik.yaml; }
# Infisical's chart really does bundle these, turned off in our values. This is what turning one on does.
plant_bitnami_subchart_enabled() { yq -i '.postgresql.enabled = true' helm/values/infisical.yaml; }
plant_thanos_default_without_digest() { yq -i 'del(.prometheusOperator.thanosImage.sha)' helm/values/kube-prometheus-stack.yaml; }
plant_internal_route_without_allow_list() {
  replace_first monitoring/manifests/shared/ingress-routes.yaml '(match: Host\(`prometheus\.localhost`\)\n\s+kind: Rule\n)\s+middlewares:\n\s+- name: node-network-only\n' '\1'
}
plant_ui_route_under_another_host() {
  replace_first monitoring/manifests/shared/ingress-routes.yaml '(match: )Host\(`prometheus\.localhost`\)(\n\s+kind: Rule\n)\s+middlewares:\n\s+- name: node-network-only\n' '\1Host(`metrics.localhost`)\2'
}
plant_ui_route_under_host_regexp() {
  replace_first infisical/manifests/ingressroute.yaml '(match: )Host\(`infisical\.localhost`\)(\n\s+)middlewares:\n\s+- name: node-network-only\n\s+' '\1HostRegexp(`^infisical[.]localhost$`)\2'
}
plant_tcp_route_to_a_ui() {
  printf 'apiVersion: traefik.io/v1alpha1\nkind: IngressRouteTCP\nmetadata:\n  name: planted\n  namespace: monitoring\nspec:\n  entryPoints: [web]\n  routes:\n    - match: HostSNI(`*`)\n      services:\n        - { name: kps-prometheus, port: 9090 }\n' >gitops/platform/network-policies/planted.yaml
}
# Argo CD fills in its Application's destination for a blank namespace, and that can be beside a UI.
plant_route_with_a_blank_namespace() {
  printf 'apiVersion: traefik.io/v1alpha1\nkind: IngressRoute\nmetadata:\n  name: planted\n  namespace: ""\nspec:\n  entryPoints: [web]\n  routes:\n    - match: Host(`logs.localhost`)\n      kind: Rule\n      services:\n        - { name: loki, port: 3100 }\n' >gitops/platform/network-policies/planted.yaml
}
# Argo CD applies what is inside these and drops the outer document, and conftest reads only the outer one.
plant_ui_route_in_a_list() {
  printf 'apiVersion: v1\nkind: List\nitems:\n  - apiVersion: traefik.io/v1alpha1\n    kind: IngressRoute\n    metadata:\n      name: planted\n      namespace: monitoring\n    spec:\n      entryPoints: [web]\n      routes:\n        - match: Host(`prometheus.localhost`)\n          kind: Rule\n          services:\n            - { name: kps-prometheus, port: 9090 }\n' >gitops/platform/network-policies/planted.yaml
}
plant_ui_route_in_items_of_a_good_route() {
  printf 'apiVersion: traefik.io/v1alpha1\nkind: IngressRoute\nmetadata:\n  name: planted\n  namespace: monitoring\nspec:\n  entryPoints: [web]\n  routes:\n    - match: Host(`prometheus.localhost`)\n      kind: Rule\n      middlewares:\n        - name: node-network-only\n      services:\n        - { name: kps-prometheus, port: 9090 }\nitems:\n  - apiVersion: traefik.io/v1alpha1\n    kind: IngressRoute\n    metadata:\n      name: planted-inside\n      namespace: monitoring\n    spec:\n      entryPoints: [web]\n      routes:\n        - match: Host(`prometheus.localhost`)\n          kind: Rule\n          services:\n            - { name: kps-prometheus, port: 9090 }\n' >gitops/platform/network-policies/planted.yaml
}
# Argo CD reads the whole directory, and every check here reads manifests.yaml by name.
plant_secret_beside_the_render() {
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: planted\n  namespace: plane-prod-sim\nstringData:\n  note: planted\n' >gitops/environments/prod-sim/planted.yaml
}
plant_secret_beside_the_render_as_yml() {
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: planted\n  namespace: plane-prod-sim\nstringData:\n  note: planted\n' >gitops/environments/prod-sim/planted.yml
}
# Argo CD starts a document at each of these, and conftest would read one document and none of the route.
plant_ui_route_after_a_separator() { # plant_ui_route_after_a_separator <the separator line> <line end>
  printf 'apiVersion: v1%bkind: ConfigMap%bmetadata:%b  name: planted%b  namespace: monitoring%b%b%bapiVersion: traefik.io/v1alpha1%bkind: IngressRoute%bmetadata:%b  name: planted-route%b  namespace: monitoring%bspec:%b  entryPoints: [web]%b  routes:%b    - match: Host(`prometheus.localhost`)%b      kind: Rule%b      services:%b        - { name: kps-prometheus, port: 9090 }%b' \
    "$2" "$2" "$2" "$2" "$2" "$1" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" "$2" >gitops/platform/network-policies/planted.yaml
}
plant_ui_route_after_a_commented_separator() { plant_ui_route_after_a_separator '--- # a comment' '\n'; }
plant_ui_route_after_a_separator_with_a_space() { plant_ui_route_after_a_separator '--- ' '\n'; }
plant_ui_route_in_a_file_with_crlf() { plant_ui_route_after_a_separator '---' '\r\n'; }
# A chart's values reach a render through extraObjects, and Argo CD flattens a List there as it does anywhere.
plant_ui_route_in_a_list_through_chart_values() {
  yq -i '.extraObjects = [{"apiVersion": "v1", "kind": "List", "items": [{"apiVersion": "traefik.io/v1alpha1", "kind": "IngressRoute", "metadata": {"name": "planted", "namespace": "monitoring"}, "spec": {"entryPoints": ["web"], "routes": [{"match": "Host(`prometheus.localhost`)", "kind": "Rule", "services": [{"name": "kps-prometheus", "port": 9090}]}]}}]}]' helm/values/traefik.yaml
}
plant_allow_list_opened() { replace_first gitops/bootstrap/argocd-route/ingressroute.yaml '172\.16\.0\.0/12' '0.0.0.0/0'; }
plant_thanos_base_image_without_digest() { yq -i '.prometheus.prometheusSpec.thanos.baseImage = "quay.io/thanos/thanos"' helm/values/kube-prometheus-stack.yaml; }
# The expression before this one read nearly 2 on one restart, at an offset the 30s tests did not reach.
plant_pod_restarting_that_extrapolates() {
  python3 -B -c 'import re; p="monitoring/manifests/shared/rules-platform.yaml"; s=open(p).read(); t,c=re.subn(r"(alert: PodRestarting\n\s+)expr: \|\n\s+max_over_time\(([^\n]*)\[15m\]\)\n[^\n]*\n\s+>= 2\n", r"\1expr: increase(\2[15m]) > 1.5\n", s); assert c==1; open(p,"w").write(t)'
}
# It states its namespaces on both sides, and the two sides match on labels, so one side narrowed loses those with no error.
plant_pod_restarting_with_one_side_narrowed() {
  replace_first monitoring/manifests/shared/rules-platform.yaml '(- min_over_time\(kube_pod_container_status_restarts_total\{namespace=~")[^"]*' '\1plane-.*|monitoring'
}
plant_invalid_alert_expression() {
  replace_first monitoring/manifests/shared/rules-plane.yaml 'expr: probe_success\{probe="api-instance"\} == 0' 'expr: probe_success{probe="api-instance"} ==== 0'
}
plant_alert_that_fires_late() {
  python3 -B -c 'import re; p="monitoring/manifests/shared/rules-plane.yaml"; s=open(p).read(); t,c=re.subn(r"(alert: PlaneApiDown\n\s+expr: [^\n]+\n\s+for: )1m", r"\g<1>30m", s); assert c==1; open(p,"w").write(t)'
}
plant_chart_version_missing() {
  yq -i '(.spec.sources[] | select(.chart != null) | .targetRevision) = "0.0.0-planted"' gitops/applications/kube-prometheus-stack.yaml
}
plant_unlintable_chart() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: Planted_Name\n' >gitops/bootstrap/chart/templates/planted.yaml
}
plant_namespace_in_gitops() {
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: planted\n' >gitops/platform/network-policies/planted.yaml
}
plant_bad_workflow_expression() { replace_first .github/workflows/ci.yml 'runs-on: ubuntu-24\.04' 'runs-on: ${{ github.planted }}'; }
plant_unpinned_action() { replace_first .github/workflows/ci.yml 'actions/checkout@[0-9a-f]{40}' 'actions/checkout@v7'; }
plant_shell_warning() { printf '#!/usr/bin/env bash\ncd /tmp\necho planted\n' >monitoring/ops/planted.sh; }
plant_python_syntax_error() { printf 'def planted(:\n' >scripts/tools/planted.py; }
plant_floating_base_image() {
  mkdir -p apps/planted
  printf 'FROM alpine:latest\n' >apps/planted/Dockerfile
}
plant_unformatted_terraform() { printf 'locals {\n    planted   =    1\n}\n' >"$TERRAFORM_ROOT/planted.tf"; }
plant_invalid_terraform() { printf 'output "planted" {\n  value = var.planted_undeclared\n}\n' >"$TERRAFORM_ROOT/planted.tf"; }
plant_unused_terraform_variable() { printf 'variable "planted_unused" {}\n' >"$TERRAFORM_ROOT/planted.tf"; }
plant_weakened_policy() { replace_first policy/gitops.rego 'input\.kind == "Secret"' 'input.kind == "Planted"'; }
plant_token_in_tree() { printf 'token: %s\n' "$(fake_token)" >docs/planted.txt; }
plant_token_in_history() {
  plant_token_in_tree
  git add docs/planted.txt
  git -c user.name=negative-control -c user.email=negative-control@invalid -c commit.gpgsign=false commit --quiet -m planted
  git rm --quiet docs/planted.txt
  git -c user.name=negative-control -c user.email=negative-control@invalid -c commit.gpgsign=false commit --quiet -m 'remove planted'
}
plant_privileged_pod() {
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: planted\n  namespace: plane-dev\nspec:\n  containers:\n    - name: planted\n      image: docker.io/library/alpine:3.20\n      securityContext:\n        privileged: true\n' >gitops/platform/network-policies/planted.yaml
}
plant_vulnerable_lockfile() {
  mkdir -p apps/planted
  printf '{"name":"planted","version":"1.0.0","lockfileVersion":1,"requires":true,"dependencies":{"lodash":{"version":"4.17.4","resolved":"https://registry.npmjs.org/lodash/-/lodash-4.17.4.tgz"}}}\n' >apps/planted/package-lock.json
}

reset_clone() {
  git -C "$CLONE" reset --quiet --hard "$BASE"
  git -C "$CLONE" clean --quiet -fd
}

plant_nothing() { :; }

# The script promotions go through, asked for the admin digest under the web image.
promote_admin_digest_as_web() {
  local admin
  admin="$(yq -r '.images[] | select(.name | test("plane-admin$")) | .digest' "$PROD_SIM_OVERLAY")"
  COMMIT=no CONFIRM=yes SKIP_BACKUP=yes SKIP_REGISTRY_CHECK=yes ./scripts/promote.sh prod-sim IMAGE=web DIGEST="$admin"
}

control() { # control <name> <script in scripts/ci, or a function> <line a failure must print> <planting function>
  local name="$1" script="$2" expected="$3" plant="$4" output="$WORK/$1.log" status=0
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
  total=$((total + 1))
  log "$name"
  if ! (cd "$CLONE" && "$plant"); then
    warn "$name: could not plant the defect"
    missed=$((missed + 1))
    reset_clone
    return 0
  fi
  [[ "$script" != *.sh ]] || script="./scripts/ci/$script"
  (cd "$CLONE" && SKIP_FLOWS=yes SKIP_CHARTS="${CONTROL_SKIP_CHARTS:-yes}" "$script") >"$output" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]] && grep -qF -- "$expected" "$output"; then
    ok "$name: $script exited $status and printed: $expected"
  else
    warn "$name: NOT CAUGHT. $script exited $status, and the line to find was: $expected"
    tail -n 25 "$output" >&2
    missed=$((missed + 1))
  fi
  reset_clone
}

log "baseline: an untouched clone must pass, or the failures below prove nothing"
for script in lint.sh validate-manifests.sh ownership.sh security.sh; do
  if (cd "$CLONE" && SKIP_CHARTS=yes "./scripts/ci/$script") >"$WORK/baseline-$script.log" 2>&1; then
    ok "$script passes on $BASE"
  else
    tail -n 40 "$WORK/baseline-$script.log" >&2
    die "$script fails on the untouched clone, so no control would mean anything"
  fi
done

control secret-in-rendered-manifests validate-manifests.sh "conftest: rendered Plane FAILED" plant_secret_in_rendered
control image-without-digest validate-manifests.sh "conftest: rendered Plane FAILED" plant_image_without_digest
control render-drift validate-manifests.sh "render is up to date FAILED" plant_render_drift
control unknown-field-in-manifest validate-manifests.sh "kubeconform: rendered Plane FAILED" plant_unknown_field
control digest-never-recorded-for-dev validate-manifests.sh "promotion invariant FAILED" plant_digest_never_in_dev
control unlintable-chart validate-manifests.sh "helm lint: bootstrap chart FAILED" plant_unlintable_chart
CONTROL_SKIP_CHARTS=no control chart-version-missing validate-manifests.sh "helm template: platform charts FAILED" plant_chart_version_missing
control digest-under-another-image validate-manifests.sh "under another image" plant_digest_under_another_image
control promote-digest-under-another-image promote_admin_digest_as_web "under another image" plant_nothing
control plane-application-in-platform-project validate-manifests.sh "a Plane Application must use its own project" plant_plane_application_in_platform
control application-in-default-project validate-manifests.sh "is not allowed, use platform" plant_application_in_default
control dev-route-on-the-prod-sim-host validate-manifests.sh "which only namespace plane-prod-sim may serve" plant_dev_route_on_prod_sim_host
control route-with-no-host validate-manifests.sh "must be limited to Host" plant_route_with_no_host
control bitnami-image-in-a-manifest validate-manifests.sh "nothing from Bitnami" plant_bitnami_image
control bitnami-chart-in-terraform lint.sh "no Bitnami reference FAILED" plant_bitnami_chart_in_terraform
CONTROL_SKIP_CHARTS=no control chart-image-without-digest validate-manifests.sh "a platform chart image must be pinned" plant_chart_image_without_digest
CONTROL_SKIP_CHARTS=no control bitnami-subchart-turned-on validate-manifests.sh "nothing from Bitnami" plant_bitnami_subchart_enabled
CONTROL_SKIP_CHARTS=no control thanos-default-without-digest validate-manifests.sh "--thanos-default-base-image=" plant_thanos_default_without_digest
CONTROL_SKIP_CHARTS=no control thanos-base-image-without-digest validate-manifests.sh "spec.thanos.baseImage is" plant_thanos_base_image_without_digest
control internal-route-without-allow-list validate-manifests.sh "so it must name the node-network-only middleware" plant_internal_route_without_allow_list
control ui-route-under-another-host validate-manifests.sh "so it must name the node-network-only middleware" plant_ui_route_under_another_host
control ui-route-under-a-host-regexp validate-manifests.sh "so it must name the node-network-only middleware" plant_ui_route_under_host_regexp
control tcp-route-to-a-ui validate-manifests.sh "is not allowed beside an internal UI" plant_tcp_route_to_a_ui
control route-with-a-blank-namespace validate-manifests.sh "so it must name the node-network-only middleware" plant_route_with_a_blank_namespace
control ui-route-in-a-list validate-manifests.sh "wraps other objects" plant_ui_route_in_a_list
control ui-route-in-items-of-a-good-route validate-manifests.sh "wraps other objects" plant_ui_route_in_items_of_a_good_route
control secret-beside-the-render validate-manifests.sh "every check reads only manifests.yaml" plant_secret_beside_the_render
control secret-beside-the-render-as-yml validate-manifests.sh "Argo CD would read these and no check here does" plant_secret_beside_the_render_as_yml
control ui-route-after-a-commented-separator validate-manifests.sh "so it must name the node-network-only middleware" plant_ui_route_after_a_commented_separator
control ui-route-after-a-separator-with-a-space validate-manifests.sh "so it must name the node-network-only middleware" plant_ui_route_after_a_separator_with_a_space
control ui-route-in-a-file-with-crlf validate-manifests.sh "so it must name the node-network-only middleware" plant_ui_route_in_a_file_with_crlf
CONTROL_SKIP_CHARTS=no control ui-route-in-a-list-through-chart-values validate-manifests.sh "wraps other objects" plant_ui_route_in_a_list_through_chart_values
control allow-list-opened-to-everyone validate-manifests.sh "must be an ipAllowList of exactly" plant_allow_list_opened
control invalid-alert-expression validate-manifests.sh "promtool: platform rules FAILED" plant_invalid_alert_expression
control alert-that-fires-late validate-manifests.sh "promtool: rule unit tests FAILED" plant_alert_that_fires_late
control pod-restarting-that-extrapolates validate-manifests.sh "promtool: rule unit tests FAILED" plant_pod_restarting_that_extrapolates
control pod-restarting-with-one-side-narrowed validate-manifests.sh "promtool: rule unit tests FAILED" plant_pod_restarting_with_one_side_narrowed
control namespace-in-gitops ownership.sh "is owned by Terraform, not Argo CD" plant_namespace_in_gitops
control bad-workflow-expression lint.sh "actionlint FAILED" plant_bad_workflow_expression
control unpinned-action lint.sh "zizmor FAILED" plant_unpinned_action
control shell-warning-outside-scripts lint.sh "shellcheck FAILED" plant_shell_warning
control python-syntax-error lint.sh "python compile FAILED" plant_python_syntax_error
control floating-base-image lint.sh "hadolint FAILED" plant_floating_base_image
control unformatted-terraform lint.sh "terraform fmt FAILED" plant_unformatted_terraform
control invalid-terraform lint.sh "terraform validate FAILED" plant_invalid_terraform
control unused-terraform-variable lint.sh "tflint FAILED" plant_unused_terraform_variable
control weakened-policy lint.sh "conftest verify FAILED" plant_weakened_policy
control token-in-working-tree security.sh "gitleaks working tree FAILED" plant_token_in_tree
control token-only-in-history security.sh "gitleaks history FAILED" plant_token_in_history
control privileged-pod-trivy-config security.sh "trivy config FAILED" plant_privileged_pod
control vulnerable-lockfile-trivy-fs security.sh "trivy fs FAILED" plant_vulnerable_lockfile

[[ "$total" -gt 0 ]] || die "no control matches '$FILTER'"
[[ "$missed" -eq 0 ]] || die "$missed of $total planted defects were not caught"
ok "$total of $total planted defects were caught, on $BASE"
