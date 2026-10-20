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
mkdir -p "$CLONE/.tools" "$CLONE/.local" "$LOCAL_DIR/kubeconform-schemas" "$LOCAL_DIR/trivy-cache" "$LOCAL_DIR/k3s-images"
ln -s "$ROOT/.tools/bin" "$CLONE/.tools/bin"
ln -s "$LOCAL_DIR/kubeconform-schemas" "$CLONE/.local/kubeconform-schemas"
ln -s "$LOCAL_DIR/trivy-cache" "$CLONE/.local/trivy-cache"
ln -s "$LOCAL_DIR/k3s-images" "$CLONE/.local/k3s-images"

DEV_RENDERED=gitops/environments/dev/manifests.yaml
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
PROD_SIM_OVERLAY=helm/plane/overlays/prod-sim/kustomization.yaml
TERRAFORM_ROOT=infrastructure/terraform/environments/local
PROD_RENDERED=gitops/environments/prod/manifests.yaml
HOSTED_PLANTED=gitops/clusters/plane-prod/platform/planted
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

# Hosted production. What policy/hosted.rego exists to refuse, on the render, on the hosted tree and on what its charts render.
plant_hosted_http_web_url() { replace_first "$PROD_RENDERED" 'WEB_URL: https://wayline\.bereket\.dev' 'WEB_URL: http://wayline.bereket.dev'; }
plant_hosted_http_origin() { replace_first "$PROD_RENDERED" 'CORS_ALLOWED_ORIGINS: https://wayline\.bereket\.dev' 'CORS_ALLOWED_ORIGINS: http://wayline.bereket.dev,https://wayline.bereket.dev'; }
plant_hosted_localhost_image() { replace_first "$PROD_RENDERED" 'image: ghcr\.io/bereketabera/wayline/web@' 'image: localhost:5001/wayline/web@'; }
plant_hosted_web_entry_point() { replace_first "$PROD_RENDERED" '(entryPoints:\n\s+- )websecure' '\1web'; }
plant_hosted_route_without_tls() { replace_first "$PROD_RENDERED" '\n  tls:\n    secretName: wayline-tls' ''; }
plant_hosted_silo_console_route() { replace_first "$PROD_RENDERED" '(- name: plane-minio\n\s+port: )9000' '\g<1>9090'; }
plant_hosted_render_drift() { printf '# planted\n' >>"$PROD_RENDERED"; }
plant_hosted_dump_after_the_migrator() { replace_first helm/plane/overlays/prod/predeploy-dump.yaml 'sync-wave: "1"' 'sync-wave: "3"'; }
plant_in_hosted_tree() { # plant_in_hosted_tree <file>, with the content on stdin
  mkdir -p "$HOSTED_PLANTED"
  cat >"$HOSTED_PLANTED/$1"
}
plant_hosted_console_route() {
  plant_in_hosted_tree route.yaml <<'YAML'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: planted
  namespace: plane-prod
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`wayline.bereket.dev`) && PathPrefix(`/grafana`)
      kind: Rule
      services:
        - { name: kps-grafana, port: 80 }
  tls:
    secretName: wayline-tls
YAML
}
# Grafana's real route, with each thing policy/hosted.rego exists to refuse on it.
GRAFANA_ROUTE=gitops/clusters/plane-prod/platform/monitoring-extras/shared/grafana-route.yaml
plant_hosted_grafana_on_another_host() { replace_every "$GRAFANA_ROUTE" 'Host(`grafana.bereket.dev`)' 'Host(`metrics.bereket.dev`)'; }
plant_hosted_grafana_on_web() { replace_first "$GRAFANA_ROUTE" 'entryPoints: \[websecure\]' 'entryPoints: [web]'; }
plant_hosted_grafana_without_tls() { replace_first "$GRAFANA_ROUTE" '\n  tls:\n    secretName: grafana-tls' ''; }
plant_hosted_prometheus_under_the_grafana_host() { replace_first "$GRAFANA_ROUTE" '- name: kps-grafana\n(\s+)port: 80' '- name: kps-prometheus\n\1port: 9090'; }
plant_hosted_grafana_metrics_public() { replace_first "$GRAFANA_ROUTE" ' && !PathPrefix\(`/metrics`\)' ''; }
plant_hosted_grafana_login_without_its_limit() { replace_first "$GRAFANA_ROUTE" '\n\s+middlewares:\n\s+- name: grafana-login-limit' ''; }
plant_hosted_grafana_limit_on_a_header() { replace_first "$GRAFANA_ROUTE" '(sourceCriterion:\n\s+)ipStrategy:\n\s+depth: 0' '\1requestHeaderName: X-Forwarded-For'; }
plant_hosted_alertmanager_route_beside_grafana() {
  plant_in_hosted_tree route.yaml <<'YAML'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: planted
  namespace: monitoring
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`grafana.bereket.dev`) && PathPrefix(`/alertmanager`)
      kind: Rule
      services:
        - { name: kps-alertmanager, port: 9093 }
  tls:
    secretName: grafana-tls
YAML
}
plant_hosted_grafana_host_in_a_local_tree() { printf '# see https://grafana.bereket.dev\n' >>helm/values/traefik.yaml; }
# Infisical's real route, with each thing policy/hosted.rego exists to refuse on it, the value it is read at, and what alerts on it.
INFISICAL_ROUTE=gitops/clusters/plane-prod/platform/infisical/route.yaml
plant_hosted_infisical_family_more() { replace_first "$INFISICAL_ROUTE" '\|webhooks\|' '|webhooks|scim|'; }
plant_hosted_infisical_refusal_less() { replace_first "$INFISICAL_ROUTE" 'admin/\(bootstrap\|signup\)\|' ''; }
plant_hosted_infisical_login_without_its_limit() { replace_first "$INFISICAL_ROUTE" '\n\s+middlewares:\n\s+- name: infisical-guess-limit' ''; }
plant_hosted_infisical_limit_on_a_header() { replace_first "$INFISICAL_ROUTE" '(sourceCriterion:\n\s+)ipStrategy:\n\s+depth: 0' '\1requestHeaderName: X-Forwarded-For'; }
plant_hosted_infisical_route_to_its_database() { replace_first "$INFISICAL_ROUTE" '- name: infisical\n(\s+)port: 8080' '- name: infisical-postgres\n\1port: 5432'; }
plant_hosted_infisical_host_in_a_local_tree() { printf '# see https://infisical.bereket.dev\n' >>helm/values/traefik.yaml; }
plant_hosted_infisical_upgrade_unread() { replace_first gitops/clusters/plane-prod/values/infisical.yaml 'tag: "v0\.167\.6@' 'tag: "v0.168.0@'; }
plant_hosted_infisical_machine_credential_let_through() { replace_first "$INFISICAL_ROUTE" '\n\s+&& !HeaderRegexp\(`Authorization`[^\n]*' ''; }
plant_hosted_infisical_machine_only_call_let_through() { replace_first "$INFISICAL_ROUTE" '\|identities/details\|' '|'; }
# A body with the field gone is no proof that sign-up is closed, so it must not read claimed.
plant_hosted_infisical_claim_from_a_missing_field() { replace_first scripts/hosted/lib-infisical-claim.sh '\.config\.allowSignUp != false' '.config.allowSignUp == true'; }
plant_hosted_infisical_open_alert_late() { replace_first gitops/clusters/plane-prod/platform/monitoring-extras/shared/rules-hosted.yaml '(- alert: InfisicalOpenToClaim\n\s+expr: [^\n]+\n)' '\1          for: 10m\n'; }
# What watches the route, read as its alerts read it, and what reaches the namespace from Traefik's side and inside it.
INFISICAL_PROBES=gitops/clusters/plane-prod/platform/monitoring-extras/infisical/probes.yaml
INFISICAL_VALUES=gitops/clusters/plane-prod/values/infisical.yaml
plant_hosted_infisical_claim_probe_on_another_module() { replace_first "$INFISICAL_PROBES" 'module: http_infisical_claimed' 'module: http_infisical_login'; }
plant_hosted_infisical_claim_module_reads_no_body() { replace_first gitops/clusters/plane-prod/platform/monitoring-extras/shared/blackbox.yml '\n      fail_if_body_json_not_matches_cel: "body\.config\.initialized[^\n]*' ''; }
# The same module loosened where blackbox reads it, out of sight of the rule on a ConfigMap named blackbox-config: in the generator renamed,
# with the volume, or in a second file of it that the flag names.
MONITORING_SHARED=gitops/clusters/plane-prod/platform/monitoring-extras/shared
CLAIM_CEL='fail_if_body_json_not_matches_cel: "body\.config\.initialized == true && body\.config\.allowSignUp == false"'
plant_hosted_infisical_claim_loosened_in_a_renamed_config() {
  replace_first "$MONITORING_SHARED/kustomization.yaml" '- name: blackbox-config\n' '- name: bb-config\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" 'configMap: \{ name: blackbox-config \}' 'configMap: { name: bb-config }'
  replace_first "$MONITORING_SHARED/blackbox.yml" "$CLAIM_CEL" 'fail_if_body_json_not_matches_cel: "has(body.config)"'
}
plant_hosted_infisical_claim_loosened_in_a_second_file() {
  cp "$MONITORING_SHARED/blackbox.yml" "$MONITORING_SHARED/probes.yml"
  replace_first "$MONITORING_SHARED/probes.yml" "$CLAIM_CEL" 'fail_if_body_json_not_matches_cel: "has(body.config)"'
  replace_first "$MONITORING_SHARED/kustomization.yaml" 'files: \[blackbox\.yml\]' 'files: [blackbox.yml, probes.yml]'
  replace_first "$MONITORING_SHARED/blackbox.yaml" '--config\.file=/config/blackbox\.yml' '--config.file=/config/probes.yml'
}
# Or in a second ConfigMap, mounted by subPath over that file beside the pinned whole-directory mount. The runtime mounts the deeper path
# last, so the exporter reads the second one, and the flag, the pinned ConfigMap and its mount all read as they should.
plant_hosted_infisical_claim_loosened_in_a_subpath_mount() {
  cp "$MONITORING_SHARED/blackbox.yml" "$MONITORING_SHARED/shadow.yml"
  replace_first "$MONITORING_SHARED/shadow.yml" "$CLAIM_CEL" 'fail_if_body_json_not_matches_cel: "has(body.config)"'
  replace_first "$MONITORING_SHARED/kustomization.yaml" 'configMapGenerator:\n' 'configMapGenerator:\n  - name: bb-shadow\n    files: [blackbox.yml=shadow.yml]\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" '(- \{ name: config, mountPath: /config, readOnly: true \}\n)' '\1            - { name: shadow, mountPath: /config/blackbox.yml, subPath: blackbox.yml, readOnly: true }\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" '(configMap: \{ name: blackbox-config \}\n)' '\1        - name: shadow\n          configMap: { name: bb-shadow }\n'
}
# Or behind a flag spelled so that the file the exporter opens is not the one its mount names. Kubernetes expands $(X) in args and not in
# mountPath, so the pinned ConfigMap sits at the path as written, and a second one sits at the path the exporter reads.
plant_hosted_infisical_claim_loosened_behind_an_expanded_flag() {
  cp "$MONITORING_SHARED/blackbox.yml" "$MONITORING_SHARED/shadow.yml"
  replace_first "$MONITORING_SHARED/shadow.yml" "$CLAIM_CEL" 'fail_if_body_json_not_matches_cel: "has(body.config)"'
  replace_first "$MONITORING_SHARED/kustomization.yaml" 'configMapGenerator:\n' 'configMapGenerator:\n  - name: bb-shadow\n    files: [blackbox.yml=shadow.yml]\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" 'args: \[--config\.file=/config/blackbox\.yml\]\n' 'args: ["--config.file=/conf$(X)ig/blackbox.yml"]\n          env: [{ name: X, value: "" }]\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" '- \{ name: config, mountPath: /config, readOnly: true \}\n' '- { name: config, mountPath: "/conf$(X)ig", readOnly: true }\n            - { name: shadow, mountPath: /config, readOnly: true }\n'
  replace_first "$MONITORING_SHARED/blackbox.yaml" '(configMap: \{ name: blackbox-config \}\n)' '\1        - name: shadow\n          configMap: { name: bb-shadow }\n'
}
plant_hosted_infisical_claim_watch_misses_the_module() { replace_first gitops/clusters/plane-prod/platform/monitoring-extras/shared/rules-hosted.yaml '\n\s+or absent\(probe_failed_due_to_cel\{probe="infisical-claimed"\}\)' ''; }
plant_hosted_infisical_guess_limit_gone() { replace_first "$INFISICAL_ROUTE" '(?s)---\n# A person.s guesses, measured per client.*?(?=---\n)' ''; }
plant_hosted_infisical_session_probe_gone() { replace_first "$INFISICAL_PROBES" '(?s)---\n# The route.s session part.*\Z' ''; }
# The route is found by the host target.yaml gives Infisical and not by its name, so a renamed one still needs its limits, and the policy
# and that file must give the same host.
plant_hosted_infisical_route_renamed_and_its_limit_gone() {
  replace_first "$INFISICAL_ROUTE" '(kind: IngressRoute\nmetadata:\n  name: )infisical\n' '\1infisical-public\n'
  plant_hosted_infisical_guess_limit_gone
}
plant_hosted_infisical_host_moved_in_target_alone() { replace_first infrastructure/hosted/plane-prod/target.yaml 'infisical_domain: infisical\.bereket\.dev' 'infisical_domain: vault.bereket.dev'; }
plant_hosted_infisical_postgres_open_to_traefik() { replace_first gitops/clusters/plane-prod/platform/network-policies/infisical.yaml '(        - podSelector: \{ matchLabels: \{ app\.kubernetes\.io/component: backup \} \}\n)' '\1        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: traefik } }\n'; }
plant_hosted_traefik_egress_to_all_of_infisical() { replace_first gitops/clusters/plane-prod/platform/network-policies/traefik.yaml 'podSelector: \{ matchLabels: \{ app: infisical-standalone, component: infisical \} \}\n(\s+)ports:\n(\s+)- \{ protocol: TCP, port: 8080 \}' 'podSelector: {}\n\1ports:\n\2- { protocol: TCP, port: 8080 }\n\2- { protocol: TCP, port: 5432 }'; }
# The way out of namespace infisical, which bounds the server's relaxed SSRF protection: a policy with no ingress rule, and DNS's own rule
# opened to any address on 53.
plant_hosted_infisical_server_egress_opened() {
  printf -- '---\napiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: planted\n  namespace: infisical\nspec:\n  podSelector: { matchLabels: { app: infisical-standalone, component: infisical } }\n  policyTypes: [Egress]\n  egress:\n    - {}\n' >>gitops/clusters/plane-prod/platform/network-policies/infisical.yaml
}
plant_hosted_infisical_dns_egress_widened() { replace_first gitops/clusters/plane-prod/platform/network-policies/infisical.yaml '    - to:\n        - namespaceSelector: \{ matchLabels: \{ kubernetes\.io/metadata\.name: kube-system \} \}\n          podSelector: \{ matchLabels: \{ k8s-app: kube-dns \} \}\n      ports:' '    - ports:'; }
# Argo CD puts an object that states no namespace in its Application's destination, which for platform/infisical is namespace infisical, and
# every rule on what reaches the secret store, and on the route's limits, reads the namespace an object states.
plant_hosted_infisical_policy_with_no_namespace() {
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: planted\nspec:\n  podSelector: { matchLabels: { app.kubernetes.io/name: infisical-postgres } }\n  policyTypes: [Ingress]\n  ingress:\n    - {}\n' >gitops/clusters/plane-prod/platform/infisical/planted.yaml
}
plant_hosted_infisical_limit_with_no_namespace() {
  printf -- '---\napiVersion: traefik.io/v1alpha1\nkind: Middleware\nmetadata:\n  name: infisical-guess-limit\nspec:\n  rateLimit:\n    average: 1000\n    period: 1m\n    burst: 1000\n    sourceCriterion:\n      requestHeaderName: X-Forwarded-For\n' >>"$INFISICAL_ROUTE"
}
plant_hosted_infisical_image_another_digest() { replace_first "$INFISICAL_VALUES" '@sha256:ca5cbd14' '@sha256:1a5cbd14'; }
plant_hosted_infisical_public_sharing_on() { replace_first "$INFISICAL_VALUES" '\n    - name: DISABLE_PUBLIC_SECRET_SHARING\n      value: "true"' ''; }
# The verdicts test-hosted.sh and host-terraform.sh read, which their selftests hold to tables.
plant_hosted_infisical_refusal_read_without_reach() { replace_first scripts/hosted/test-hosted.sh 'if \[\[ "\$1" != PASS \]\]; then' 'if false; then'; }
plant_hosted_terraform_import_unread() { replace_first scripts/hosted/host-terraform.sh '\(if \.change\.importing then "import" else "" end\)' '""'; }
plant_hosted_terraform_without_its_state() { replace_first scripts/hosted/host-terraform.sh 'if \[\[ -s "\$1" \|\| "\$\{HOST_TERRAFORM_FIRST_STATE:-\}" == yes \]\]; then return 0; fi' 'return 0'; }
# What the check adds for a solver, and no more: this is over the operator's surge and under one solver.
plant_hosted_no_quota_room_for_a_solver() { yq -i '.quotas.monitoring."requests.memory" = "1690Mi"' infrastructure/hosted/plane-prod/capacity.yaml; }
plant_hosted_node_port() {
  plant_in_hosted_tree service.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: planted
  namespace: traefik
spec:
  type: NodePort
  selector: { app: planted }
  ports:
    - { port: 80, nodePort: 30080 }
YAML
}
plant_hosted_load_balancer_in_the_render() {
  printf -- '---\napiVersion: v1\nkind: Service\nmetadata:\n  name: planted\n  namespace: plane-prod\nspec:\n  type: LoadBalancer\n  selector:\n    app: planted\n  ports:\n    - port: 80\n' >>"$PROD_RENDERED"
}
plant_hosted_ingress() {
  plant_in_hosted_tree ingress.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: planted
  namespace: plane-prod
spec:
  ingressClassName: traefik
  rules:
    - host: wayline.bereket.dev
YAML
}
plant_hosted_application() { # plant_hosted_application <repository> <revision> <path>
  mkdir -p gitops/clusters/plane-prod/applications
  cat >gitops/clusters/plane-prod/applications/planted.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: planted
  namespace: argocd
spec:
  project: platform
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  source:
    repoURL: $1
    targetRevision: $2
    path: $3
YAML
}
HOSTED_REPO=ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git
plant_hosted_git_source_elsewhere() { plant_hosted_application git://plane-git/plane-platform.git deploy/plane-prod gitops/environments/prod; }
plant_hosted_source_on_main() { plant_hosted_application "$HOSTED_REPO" main gitops/environments/prod; }
plant_hosted_path_outside_the_trees() { plant_hosted_application "$HOSTED_REPO" deploy/plane-prod gitops/applications; }
plant_hosted_application_on_values() { plant_hosted_application "$HOSTED_REPO" deploy/plane-prod gitops/clusters/plane-prod/values; }
plant_hosted_application_on_a_new_folder() { plant_hosted_application "$HOSTED_REPO" deploy/plane-prod gitops/clusters/plane-prod/extras; }
# Nothing checks a folder no Application may read, and this is what would hide there.
plant_hosted_manifest_in_a_new_folder() {
  mkdir -p gitops/clusters/plane-prod/extras
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: monitoring\n' >gitops/clusters/plane-prod/extras/notes.yaml
}
plant_hosted_manifest_among_the_values() { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: monitoring\n' >gitops/clusters/plane-prod/values/notes.yaml; }
plant_hosted_symlink_in_applications() { ln -s ../values/traefik.yaml gitops/clusters/plane-prod/applications/planted.yaml; }
plant_hosted_symlink_in_platform() { ln -s ../../values/traefik.yaml gitops/clusters/plane-prod/platform/network-policies/planted.yaml; }
plant_hosted_applications_as_a_symlink() {
  mv gitops/clusters/plane-prod/applications gitops/clusters/plane-prod/values/elsewhere
  ln -s values/elsewhere gitops/clusters/plane-prod/applications
}
plant_hosted_submodule() { git update-index --add --cacheinfo "160000,$BASE,gitops/clusters/plane-prod/platform/vendored"; }
plant_hosted_argocd_source() {
  printf 'kustomize:\n  images:\n    - docker.io/restic/restic=ghcr.io/attacker/evil:latest\n' >gitops/clusters/plane-prod/platform/backup/.argocd-source-backup.yaml
}
plant_hosted_kustomization_by_another_name() {
  printf 'images:\n  - {name: docker.io/restic/restic, newName: ghcr.io/attacker/evil}\n' >gitops/clusters/plane-prod/platform/network-policies/Kustomization
}
plant_hosted_helm_parameters() { yq -i '.spec.sources[0].helm.parameters = [{"name": "image.registry", "value": "ghcr.io"}]' gitops/clusters/plane-prod/applications/traefik.yaml; }
plant_hosted_helm_values_object() { yq -i '.spec.sources[0].helm.valuesObject = {"extraObjects": []}' gitops/clusters/plane-prod/applications/traefik.yaml; }
plant_hosted_kustomize_images() { yq -i '.spec.source.kustomize.images = ["docker.io/restic/restic=ghcr.io/attacker/evil:latest"]' gitops/clusters/plane-prod/applications/backup.yaml; }
plant_hosted_object_in_applications() { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: monitoring\n' >gitops/clusters/plane-prod/applications/planted.yaml; }
# A Wayline build under a name the evidence check's grep does not know.
plant_hosted_renamed_image() {
  plant_in_hosted_tree pod.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: planted
  namespace: monitoring
spec:
  containers:
    - name: planted
      image: ghcr.io/bereketabera/wl/backend@sha256:$(printf '9%.0s' {1..64})
YAML
}
plant_hosted_image_split_across_chart_values() {
  yq -i '.image.registry = "ghcr.io" | .image.repository = "bereketabera/wl/backend" | .image.digest = "sha256:'"$(printf '9%.0s' {1..64})"'"' gitops/clusters/plane-prod/values/traefik.yaml
}
plant_hosted_image_listed_and_gone() { printf 'docker.io/planted/gone@sha256:%s\n' "$(printf '9%.0s' {1..64})" >>policy/hosted-images.txt; }
plant_hosted_probe_image_unlisted() { replace_first scripts/test-netpol.sh 'curl:8\.17\.0@sha256:[a-f0-9]{64}' "curl:8.17.0@sha256:$(printf '9%.0s' {1..64})"; }
plant_hosted_k3s_image_unlisted() {
  python3 -B -c 'p="policy/hosted-system-images.txt"; s=open(p).read().splitlines(True); t=[l for l in s if "/mirrored-pause:" not in l]; assert len(t) == len(s) - 1; open(p, "w").write("".join(t))'
}
plant_hosted_k3s_image_listed_and_gone() { printf 'docker.io/rancher/klipper-lb:v0.4.17@sha256:%s\n' "$(printf '9%.0s' {1..64})" >>policy/hosted-system-images.txt; }
plant_hosted_alloy_without_the_scrub() {
  python3 -B -c 'import re; p="gitops/clusters/plane-prod/values/alloy.yaml"; s=open(p).read(); t,c=re.subn(r"stage\.replace \{.*?\n\s*\}\n", "", s, count=1, flags=re.S); assert c==1; open(p,"w").write(t)'
}
plant_hosted_alloy_scrub_that_misses() { replace_first gitops/clusters/plane-prod/values/alloy.yaml 'expression = "bot\(\[0-9\]\+:\[A-Za-z0-9_-\]\+\)"' 'expression = "token=([0-9]+)"'; }
plant_hosted_values_outside_the_trees() {
  plant_hosted_application "$HOSTED_REPO" deploy/plane-prod gitops/environments/prod
  yq -i 'del(.spec.source) | .spec.sources = [{"repoURL": "https://traefik.github.io/charts", "chart": "traefik", "targetRevision": "42.3.0", "helm": {"valueFiles": ["$values/helm/values/traefik.yaml"]}}, {"repoURL": strenv(HOSTED_REPO), "targetRevision": "deploy/plane-prod", "ref": "values"}]' gitops/clusters/plane-prod/applications/planted.yaml
}
# Every file here exists in a full checkout, so only a read of the two trees alone can catch this one.
plant_hosted_base_outside_the_trees() {
  plant_in_hosted_tree kustomization.yaml <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../../../gitops/platform/backup-storage
YAML
}
plant_hosted_chart_as_a_node_port() { yq -i '.service.spec.type = "NodePort"' gitops/clusters/plane-prod/values/traefik.yaml; }
plant_hosted_chart_image_without_digest() { yq -i 'del(.image.digest)' gitops/clusters/plane-prod/values/traefik.yaml; }
# What guards Grafana's login and its token, each undone in the chart's values, where a revert would be made.
GRAFANA_VALUES=gitops/clusters/plane-prod/values/kube-prometheus-stack.yaml
plant_hosted_grafana_basic_auth_on() { yq -i '.grafana."grafana.ini"."auth.basic".enabled = true' "$GRAFANA_VALUES"; }
plant_hosted_grafana_count_per_username() { yq -i '.grafana."grafana.ini".security.disable_username_login_protection = false' "$GRAFANA_VALUES"; }
plant_hosted_grafana_version_shown() { yq -i '.grafana."grafana.ini"."auth.anonymous".hide_version = false' "$GRAFANA_VALUES"; }
plant_hosted_grafana_role_reading_secrets() { yq -i '.grafana.extraObjects[0].rules[0].resources += ["secrets"]' "$GRAFANA_VALUES"; }
plant_hosted_grafana_chart_role_back() { yq -i 'del(.grafana.rbac.useExistingRole) | del(.grafana.extraObjects)' "$GRAFANA_VALUES"; }
plant_hosted_grafana_without_its_role() { yq -i 'del(.grafana.extraObjects)' "$GRAFANA_VALUES"; }
plant_hosted_grafana_reload_call() { yq -i '.grafana.sidecar.dashboards.skipReload = false' "$GRAFANA_VALUES"; }
plant_hosted_grafana_datasource_sidecar() { yq -i '.grafana.sidecar.datasources.enabled = true | .grafana.sidecar.datasources.skipReload = true' "$GRAFANA_VALUES"; }
plant_hosted_local_marker() { printf '#!/usr/bin/env bash\n# reads git://plane-git/plane-platform.git\n' >scripts/hosted/planted.sh; }
plant_hosted_marker_in_the_tree() {
  plant_in_hosted_tree config.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: planted
  namespace: monitoring
data:
  url: http://grafana.localhost
YAML
}
plant_hosted_bare_kubectl() { printf '#!/usr/bin/env bash\nkubectl get pods\n' >scripts/hosted/planted.sh; }
plant_hosted_name_in_a_local_tree() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: plane-prod\n' >gitops/platform/network-policies/planted.yaml
}
plant_hosted_path_in_a_local_tree() { printf '# see gitops/clusters/plane-prod/values\n' >>helm/values/traefik.yaml; }
plant_hosted_object_declared_twice() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: monitoring\n' | plant_in_hosted_tree one.yaml
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n  namespace: monitoring\n' | plant_in_hosted_tree two.yaml
}
plant_hosted_namespace_in_the_tree() {
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: planted\n' | plant_in_hosted_tree namespace.yaml
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
export HOSTED_REPO
control hosted-http-web-url validate-manifests.sh 'WEB_URL is "http://wayline.bereket.dev"' plant_hosted_http_web_url
control hosted-http-origin validate-manifests.sh 'CORS_ALLOWED_ORIGINS is "http://wayline.bereket.dev,https://wayline.bereket.dev"' plant_hosted_http_origin
control hosted-localhost-image validate-manifests.sh "is on a local registry" plant_hosted_localhost_image
control hosted-web-entry-point validate-manifests.sh 'entryPoints is ["web"]' plant_hosted_web_entry_point
control hosted-route-without-tls validate-manifests.sh "tls is {} and must name only secretName wayline-tls" plant_hosted_route_without_tls
control hosted-console-route-in-the-tree validate-manifests.sh "Hosted production gives no console a public route" plant_hosted_console_route
control hosted-silo-console-in-the-render validate-manifests.sh "reaches plane-minio:9090" plant_hosted_silo_console_route
control hosted-grafana-on-another-host validate-manifests.sh "is not one of Grafana's two" plant_hosted_grafana_on_another_host
control hosted-grafana-on-web validate-manifests.sh 'entryPoints is ["web"]' plant_hosted_grafana_on_web
control hosted-grafana-without-tls validate-manifests.sh "tls is {} and must name only secretName grafana-tls" plant_hosted_grafana_without_tls
control hosted-prometheus-under-the-grafana-host validate-manifests.sh "is not one of Grafana's two" plant_hosted_prometheus_under_the_grafana_host
control hosted-alertmanager-route-beside-grafana validate-manifests.sh "is not one of Grafana's two" plant_hosted_alertmanager_route_beside_grafana
control hosted-grafana-metrics-public validate-manifests.sh "is not one of Grafana's two" plant_hosted_grafana_metrics_public
control hosted-grafana-login-without-its-limit validate-manifests.sh "is not one of Grafana's two" plant_hosted_grafana_login_without_its_limit
control hosted-grafana-limit-on-a-header validate-manifests.sh "any other source criterion counts something the client chooses" plant_hosted_grafana_limit_on_a_header
control hosted-grafana-host-in-a-local-tree check-cluster-separation.sh "the hosted Grafana host in a local tree" plant_hosted_grafana_host_in_a_local_tree
control hosted-infisical-family-more validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_family_more
control hosted-infisical-refusal-less validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_refusal_less
control hosted-infisical-login-without-its-limit validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_login_without_its_limit
control hosted-infisical-limit-on-a-header validate-manifests.sh "any other source criterion counts something the client chooses" plant_hosted_infisical_limit_on_a_header
control hosted-infisical-route-to-its-database validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_route_to_its_database
control hosted-infisical-host-in-a-local-tree check-cluster-separation.sh "the hosted Infisical host in a local tree" plant_hosted_infisical_host_in_a_local_tree
control hosted-infisical-machine-credential-let-through validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_machine_credential_let_through
control hosted-infisical-machine-only-call-let-through validate-manifests.sh "is not one of Infisical's four" plant_hosted_infisical_machine_only_call_let_through
control hosted-infisical-claim-from-a-missing-field lint.sh "Infisical claim verdict self check FAILED" plant_hosted_infisical_claim_from_a_missing_field
CONTROL_SKIP_CHARTS=no control hosted-infisical-upgrade-unread validate-manifests.sh "Infisical's public route was read from v0.167.6" plant_hosted_infisical_upgrade_unread
control hosted-infisical-open-alert-late validate-manifests.sh "promtool: hosted rule unit tests FAILED" plant_hosted_infisical_open_alert_late
control hosted-infisical-claim-probe-on-another-module validate-manifests.sh "because Infisical's alerts read this Probe's module" plant_hosted_infisical_claim_probe_on_another_module
control hosted-infisical-claim-module-reads-no-body validate-manifests.sh "blackbox module http_infisical_claimed is" plant_hosted_infisical_claim_module_reads_no_body
control hosted-infisical-claim-loosened-in-a-renamed-config validate-manifests.sh "reads /config/blackbox.yml from ConfigMap monitoring/bb-config-" plant_hosted_infisical_claim_loosened_in_a_renamed_config
control hosted-infisical-claim-loosened-in-a-second-file validate-manifests.sh "reads /config/probes.yml from ConfigMap monitoring/blackbox-config-" plant_hosted_infisical_claim_loosened_in_a_second_file
control hosted-infisical-claim-loosened-in-a-subpath-mount validate-manifests.sh 'mounts ["/config", "/config/blackbox.yml"] at or under /config, the directory of /config/blackbox.yml' plant_hosted_infisical_claim_loosened_in_a_subpath_mount
control hosted-infisical-claim-loosened-behind-an-expanded-flag validate-manifests.sh "nothing here can say which file it reads them from" plant_hosted_infisical_claim_loosened_behind_an_expanded_flag
control hosted-infisical-claim-watch-misses-the-module validate-manifests.sh "promtool: hosted rule unit tests FAILED" plant_hosted_infisical_claim_watch_misses_the_module
control hosted-infisical-guess-limit-gone validate-manifests.sh "Middleware infisical/infisical-guess-limit is not" plant_hosted_infisical_guess_limit_gone
control hosted-infisical-session-probe-gone validate-manifests.sh "Probe infisical/infisical-session is not" plant_hosted_infisical_session_probe_gone
control hosted-infisical-route-renamed-and-its-limit-gone validate-manifests.sh "IngressRoute infisical/infisical-public serves infisical.bereket.dev, and Middleware infisical/infisical-guess-limit is not" plant_hosted_infisical_route_renamed_and_its_limit_gone
control hosted-infisical-host-moved-in-target-alone validate-manifests.sh "puts Infisical at vault.bereket.dev" plant_hosted_infisical_host_moved_in_target_alone
control hosted-infisical-postgres-open-to-traefik validate-manifests.sh "so nothing new reaches the secret store or its database" plant_hosted_infisical_postgres_open_to_traefik
control hosted-traefik-egress-to-all-of-infisical validate-manifests.sh "where Traefik reaches only Infisical's server on 8080" plant_hosted_traefik_egress_to_all_of_infisical
control hosted-infisical-server-egress-opened validate-manifests.sh "is not one of the NetworkPolicies in namespace infisical" plant_hosted_infisical_server_egress_opened
control hosted-infisical-dns-egress-widened validate-manifests.sh "and they reach nothing new" plant_hosted_infisical_dns_egress_widened
control hosted-infisical-policy-with-no-namespace validate-manifests.sh "NetworkPolicy -/planted: states no namespace" plant_hosted_infisical_policy_with_no_namespace
control hosted-infisical-limit-with-no-namespace validate-manifests.sh "Middleware -/infisical-guess-limit: states no namespace" plant_hosted_infisical_limit_with_no_namespace
CONTROL_SKIP_CHARTS=no control hosted-infisical-image-another-digest validate-manifests.sh "Infisical's public route was read from v0.167.6" plant_hosted_infisical_image_another_digest
CONTROL_SKIP_CHARTS=no control hosted-infisical-public-sharing-on validate-manifests.sh "sets DISABLE_PUBLIC_SECRET_SHARING to" plant_hosted_infisical_public_sharing_on
control hosted-infisical-refusal-read-without-reach lint.sh "hosted test verdict self check FAILED" plant_hosted_infisical_refusal_read_without_reach
control hosted-terraform-import-unread lint.sh "host Terraform plan check self check FAILED" plant_hosted_terraform_import_unread
control hosted-terraform-without-its-state lint.sh "host Terraform plan check self check FAILED" plant_hosted_terraform_without_its_state
CONTROL_SKIP_CHARTS=no control hosted-no-quota-room-for-a-solver check-capacity.sh "for the largest rollout, Job or solver), and its quota is 1690Mi" plant_hosted_no_quota_room_for_a_solver
control hosted-node-port-in-the-tree validate-manifests.sh "no NodePort Service" plant_hosted_node_port
control hosted-load-balancer-in-the-render validate-manifests.sh "no LoadBalancer Service" plant_hosted_load_balancer_in_the_render
control hosted-ingress-in-the-tree validate-manifests.sh "no Ingress in Git" plant_hosted_ingress
control hosted-git-source-elsewhere validate-manifests.sh "is not the one this cluster reads" plant_hosted_git_source_elsewhere
control hosted-source-on-main validate-manifests.sh "this cluster reads only deploy/plane-prod" plant_hosted_source_on_main
control hosted-path-outside-the-trees validate-manifests.sh "is not one this cluster reads" plant_hosted_path_outside_the_trees
control hosted-application-on-values validate-manifests.sh "is not one this cluster reads" plant_hosted_application_on_values
control hosted-application-on-a-new-folder validate-manifests.sh "is not one this cluster reads" plant_hosted_application_on_a_new_folder
control hosted-manifest-in-a-new-folder validate-manifests.sh "outside applications/, platform/<directory> and bootstrap-chart/" plant_hosted_manifest_in_a_new_folder
control hosted-manifest-among-the-values validate-manifests.sh "outside applications/, platform/<directory> and bootstrap-chart/" plant_hosted_manifest_among_the_values
control hosted-symlink-in-applications validate-manifests.sh "no check here reads them" plant_hosted_symlink_in_applications
control hosted-symlink-in-platform validate-manifests.sh "no check here reads them" plant_hosted_symlink_in_platform
control hosted-applications-as-a-symlink validate-manifests.sh "no check here reads them" plant_hosted_applications_as_a_symlink
control hosted-submodule validate-manifests.sh "symlinks or submodules in Git" plant_hosted_submodule
control hosted-argocd-source-file validate-manifests.sh "no check here reads them" plant_hosted_argocd_source
control hosted-kustomization-by-another-name validate-manifests.sh "no check here reads them" plant_hosted_kustomization_by_another_name
control hosted-helm-parameters validate-manifests.sh "a source sets helm.parameters" plant_hosted_helm_parameters
control hosted-helm-values-object validate-manifests.sh "a source sets helm.valuesObject" plant_hosted_helm_values_object
control hosted-kustomize-images validate-manifests.sh "a source sets kustomize" plant_hosted_kustomize_images
control hosted-object-in-applications validate-manifests.sh "so it may hold only Applications" plant_hosted_object_in_applications
control hosted-renamed-image-in-the-tree validate-manifests.sh "they are not in policy/hosted-images.txt" plant_hosted_renamed_image
CONTROL_SKIP_CHARTS=no control hosted-image-split-across-chart-values validate-manifests.sh "they are not in policy/hosted-images.txt" plant_hosted_image_split_across_chart_values
CONTROL_SKIP_CHARTS=no control hosted-image-listed-and-gone validate-manifests.sh "and nothing hosted runs them" plant_hosted_image_listed_and_gone
control hosted-probe-image-unlisted validate-manifests.sh "they are not in policy/hosted-system-images.txt, so the hosted scan would miss them" plant_hosted_probe_image_unlisted
CONTROL_SKIP_CHARTS=no control hosted-k3s-image-unlisted validate-manifests.sh "K3s runs these, and they are not in policy/hosted-system-images.txt" plant_hosted_k3s_image_unlisted
CONTROL_SKIP_CHARTS=no control hosted-k3s-image-listed-and-gone validate-manifests.sh "and neither K3s nor a probe runs them" plant_hosted_k3s_image_listed_and_gone
control hosted-values-outside-the-trees validate-manifests.sh 'they must come from $values/gitops/clusters/plane-prod' plant_hosted_values_outside_the_trees
control hosted-base-outside-the-trees validate-manifests.sh "does not build from the two hosted trees alone" plant_hosted_base_outside_the_trees
control hosted-alloy-without-the-scrub validate-manifests.sh "no stage.replace ahead of what goes to Loki" plant_hosted_alloy_without_the_scrub
control hosted-alloy-scrub-that-misses validate-manifests.sh "does not capture the token" plant_hosted_alloy_scrub_that_misses
control hosted-render-drift validate-manifests.sh "render is up to date: hosted FAILED" plant_hosted_render_drift
control hosted-dump-after-the-migrator validate-manifests.sh "must run before the migrator" plant_hosted_dump_after_the_migrator
CONTROL_SKIP_CHARTS=no control hosted-chart-as-a-node-port validate-manifests.sh "no NodePort Service" plant_hosted_chart_as_a_node_port
CONTROL_SKIP_CHARTS=no control hosted-chart-image-without-digest validate-manifests.sh "a platform chart image must be pinned" plant_hosted_chart_image_without_digest
CONTROL_SKIP_CHARTS=no control hosted-grafana-basic-auth-on validate-manifests.sh "grafana.ini sets [auth.basic] enabled = true" plant_hosted_grafana_basic_auth_on
CONTROL_SKIP_CHARTS=no control hosted-grafana-count-per-username validate-manifests.sh "disable_username_login_protection = false, and it must be true" plant_hosted_grafana_count_per_username
CONTROL_SKIP_CHARTS=no control hosted-grafana-version-shown validate-manifests.sh "hide_version = false, and it must be true" plant_hosted_grafana_version_shown
CONTROL_SKIP_CHARTS=no control hosted-grafana-role-reading-secrets validate-manifests.sh "so Grafana's token reads no Secret" plant_hosted_grafana_role_reading_secrets
CONTROL_SKIP_CHARTS=no control hosted-grafana-chart-role-back validate-manifests.sh "so Grafana's token reads no Secret" plant_hosted_grafana_chart_role_back
CONTROL_SKIP_CHARTS=no control hosted-grafana-without-its-role validate-manifests.sh "and Role monitoring/kps-grafana is not" plant_hosted_grafana_without_its_role
CONTROL_SKIP_CHARTS=no control hosted-grafana-reload-call validate-manifests.sh "that reload needs basic auth" plant_hosted_grafana_reload_call
CONTROL_SKIP_CHARTS=no control hosted-grafana-datasource-sidecar validate-manifests.sh "writes Grafana's datasources" plant_hosted_grafana_datasource_sidecar
control hosted-local-marker check-cluster-separation.sh "a local marker in the hosted trees" plant_hosted_local_marker
control hosted-marker-in-the-tree check-cluster-separation.sh "a local marker in the hosted trees" plant_hosted_marker_in_the_tree
control hosted-bare-kubectl check-cluster-separation.sh "kubectl with no --kubeconfig and --context" plant_hosted_bare_kubectl
control hosted-name-in-a-local-tree check-cluster-separation.sh "the hosted cluster's name in a local tree" plant_hosted_name_in_a_local_tree
control hosted-path-in-a-local-tree check-cluster-separation.sh "a hosted path in a local tree" plant_hosted_path_in_a_local_tree
control hosted-separation-through-lint lint.sh "cluster separation FAILED" plant_hosted_local_marker
control hosted-object-declared-twice ownership.sh "is declared by more than one Argo CD source" plant_hosted_object_declared_twice
control hosted-namespace-in-the-tree ownership.sh "is owned by Terraform, not Argo CD" plant_hosted_namespace_in_the_tree

[[ "$total" -gt 0 ]] || die "no control matches '$FILTER'"
[[ "$missed" -eq 0 ]] || die "$missed of $total planted defects were not caught"
ok "$total of $total planted defects were caught, on $BASE"
