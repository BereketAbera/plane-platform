#!/usr/bin/env bash
# What this platform asks Kubernetes to run, gathered without a cluster. validate-manifests.sh and
# scan-images.sh both read it, so they cannot disagree. Source this after scripts/lib/common.sh, from
# the repository root, with yq, helm and kustomize installed.

K8S_VERSION=1.36.4

# Hosted production, which is a second cluster with its own tree. deploy/plane-prod holds only these two paths, and the
# render, so nothing hosted may read anything else.
HOSTED_TREE=gitops/clusters/plane-prod
HOSTED_ENVIRONMENT=gitops/environments/prod
HOSTED_APPLICATION_TEMPLATE="$HOSTED_TREE/plane-prod-application.yaml.tmpl"

hosted_k8s_version() { # What K3s runs on the VPS, so a chart renders and a schema reads for that and not for kind's version.
  local version
  version="$(yq -r '.k3s_version // ""' infrastructure/hosted/plane-prod/target.yaml)"
  version="${version#v}"
  version="${version%%+*}"
  [[ -n "$version" ]] || die "infrastructure/hosted/plane-prod/target.yaml states no k3s_version"
  printf '%s\n' "$version"
}

# Argo CD reads *.yaml, *.yml, *.json and *.jsonnet in a directory it has no Kustomize or chart for, and
# everything here, this file, scan-images.sh and the ownership check, reads *.yaml. So one of the others
# in such a directory would reach the cluster with no check at all, and CI would stay green.
refuse_files_only_argocd_reads() { # refuse_files_only_argocd_reads <directory>
  local found
  found="$(find "$1" -type f \( -name '*.yml' -o -name '*.json' -o -name '*.jsonnet' \) | LC_ALL=C sort)"
  [[ -z "$found" ]] || die "Argo CD would read these and no check here does, so name them *.yaml: ${found//$'\n'/, }"
}

# Plain directories are copied as they are, and anything with a kustomization.yaml is built. Kustomize
# reads only what it lists, so raw config beside it (blackbox.yml, the dashboards) is not a manifest.
collect() { # collect <directory> <output file>
  local dir="$1" target="$2"
  [[ -d "$dir" ]] || { warn "$dir does not exist, skipping"; return 0; }
  if [[ -f "$dir/kustomization.yaml" ]]; then
    kustomize build "$dir" >"$target"
  else
    refuse_files_only_argocd_reads "$dir"
    local file
    # Argo CD starts a document at any line beginning with ---, and drops the rest of that line. conftest
    # splits only at a line that is exactly that, and one CRLF anywhere makes it look for that form with
    # CRLF around it, and to it the rest is then one document, of which it reads the first. So this hands on what Argo CD reads.
    while read -r file; do
      printf -- '---\n'
      tr -d '\r' <"$file" | sed -E 's/^---.*$/---/'
    done < <(find "$dir" -type f -name '*.yaml' | sort) >"$target"
  fi
}

collect_in_repo() { # collect_in_repo <directory>: one file per source, everything this repository authors
  local out="$1" platform_dir environment_dir stray
  mkdir -p "$out"
  # Their manifests.yaml is read by name, and Argo CD reads the whole directory.
  for environment_dir in gitops/environments/*/; do
    refuse_files_only_argocd_reads "${environment_dir%/}"
    stray="$(find "${environment_dir%/}" -type f -name '*.yaml' ! -name manifests.yaml | LC_ALL=C sort)"
    [[ -z "$stray" ]] || die "Argo CD reads the whole directory and every check reads only manifests.yaml, so these would reach the cluster unchecked: ${stray//$'\n'/, }"
  done
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

# What Argo CD would act on in the two hosted trees and nothing here would read, so it would reach the cluster past every check.
# scripts/ci/check-prod-evidence.sh refuses the same in the commit it gates, and this says so to a pull request as well:
#   a symlink or a submodule: every reader here looks for regular files, and Argo CD follows a link that stays in the repository
#   .argocd-source*: Argo CD merges it into the Application's source
#   kustomization.yml, Kustomization: Argo CD builds such a directory, and collect reads it as plain files
#   a manifest outside applications/, a directory of platform/ and bootstrap-chart/: no reader looks there
#   anything but an Application in applications/: root applies it, under a project that allows every kind and namespace
refuse_what_hosted_checks_cannot_read() {
  local found file kinds
  found="$({ find "$HOSTED_TREE" "$HOSTED_ENVIRONMENT" \( -type l -o -name '.argocd-source*' -o -name kustomization.yml -o -name Kustomization \) 2>/dev/null || true; } | LC_ALL=C sort)"
  [[ -z "$found" ]] || die "Argo CD acts on these and no check here reads them, so they cannot be in the hosted trees. A symlink or an override goes, and a kustomization is named kustomization.yaml: ${found//$'\n'/, }"
  # A submodule is a plain directory on disk, so only Git can say.
  found="$(git ls-files -s -- "$HOSTED_TREE" "$HOSTED_ENVIRONMENT" | awk '$1 != "100644" && $1 != "100755"')"
  [[ -z "$found" ]] || die "these are symlinks or submodules in Git, and no check here reads them: ${found//$'\n'/, }"
  while read -r file; do
    case "$file" in
      "$HOSTED_TREE"/applications/* | "$HOSTED_TREE"/platform/*/* | "$HOSTED_TREE"/bootstrap-chart/*) continue ;;
      *.jsonnet) die "$file: nothing here reads jsonnet, and an Application could" ;;
    esac
    # values/ holds Helm values, which say nothing about what they are. A document that does is a manifest in the wrong place.
    kinds="$(yq -N -r 'select(.apiVersion != null and .kind != null) | .kind' "$file")" || die "$file is not YAML, so nothing can say it is no manifest"
    [[ -z "$kinds" ]] || die "$file is a ${kinds//$'\n'/, } outside applications/, platform/<directory> and bootstrap-chart/, which are all that anything here reads"
  done < <(find "$HOSTED_TREE" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.jsonnet' \) 2>/dev/null | LC_ALL=C sort)
  while read -r file; do
    kinds="$(yq -N -r 'select(. != null) | .kind // "no kind"' "$file" | { grep -vx Application || true; })" || die "$file is not YAML"
    [[ -z "$kinds" ]] || die "$file holds ${kinds//$'\n'/, }. Root applies whatever applications/ holds, under a project that allows every kind and namespace, so it may hold only Applications"
  done < <(hosted_applications)
}

# The hosted tree, as the hosted Argo CD reads it: the root reads applications/, and each child a directory of platform/.
# values/ holds Helm values and no manifests. Writes nothing for a part that does not exist yet, so an empty tree passes.
collect_hosted() { # collect_hosted <directory>: one file per source
  local out="$1" platform_dir target
  mkdir -p "$out"
  refuse_what_hosted_checks_cannot_read
  [[ ! -d "$HOSTED_TREE/applications" ]] || collect "$HOSTED_TREE/applications" "$out/applications.yaml"
  # Copied to applications/ by the first promotion, so it must already pass everything an Application there does.
  [[ ! -f "$HOSTED_APPLICATION_TEMPLATE" ]] || tr -d '\r' <"$HOSTED_APPLICATION_TEMPLATE" >"$out/plane-prod-application.yaml"
  for platform_dir in "$HOSTED_TREE"/platform/*/; do
    [[ -d "$platform_dir" ]] || continue
    target="$out/platform-$(basename "$platform_dir").yaml"
    collect "${platform_dir%/}" "$target"
  done
  # Terraform applies this, and the root and the projects only mean anything once rendered.
  if [[ -f "$HOSTED_TREE/bootstrap-chart/Chart.yaml" ]]; then
    helm template bootstrap "$HOSTED_TREE/bootstrap-chart" --namespace argocd >"$out/bootstrap.yaml"
  fi
  # A directory with no manifests yet leaves an empty file, and that should not read as a tree to check.
  find "$out" -type f -name '*.yaml' -size 0 -delete
}

hosted_applications() { # Every hosted Application, one to a line, including the one the first promotion adds.
  [[ ! -d "$HOSTED_TREE/applications" ]] || find "$HOSTED_TREE/applications" -type f -name '*.yaml' | LC_ALL=C sort
  [[ ! -f "$HOSTED_APPLICATION_TEMPLATE" ]] || printf '%s\n' "$HOSTED_APPLICATION_TEMPLATE"
}

# deploy/plane-prod holds only the two hosted trees and RELEASE.json, so a reference to anything else works here and fails
# at sync, after the merge. So this reads a copy holding only those: each kustomization builds there, and each path and
# values file an Application names is there.
hosted_tree_stands_alone() { # hosted_tree_stands_alone <scratch directory>
  local copy="$1" application reference kustomization status=0
  mkdir -p "$copy/gitops/clusters" "$copy/gitops/environments"
  [[ ! -d "$HOSTED_TREE" ]] || cp -R "$HOSTED_TREE" "$copy/gitops/clusters/"
  [[ ! -d "$HOSTED_ENVIRONMENT" ]] || cp -R "$HOSTED_ENVIRONMENT" "$copy/gitops/environments/"
  while read -r kustomization; do
    if ! kustomize build "$(dirname "$kustomization")" >/dev/null; then
      warn "${kustomization#"$copy"/} does not build from the two hosted trees alone"
      status=1
    fi
  done < <(find "$copy/gitops" -type f -name kustomization.yaml | LC_ALL=C sort)
  while read -r application; do
    while read -r reference; do
      [[ -n "$reference" && ! -d "$copy/$reference" ]] || continue
      warn "$application: path $reference is not in the two hosted trees"
      status=1
    done < <(yq -r '(.spec.sources // [.spec.source])[] | .path // ""' "$application")
    while read -r reference; do
      reference="${reference#\$values/}"
      [[ -n "$reference" && ! -f "$copy/$reference" ]] || continue
      warn "$application: values file $reference is not in the two hosted trees"
      status=1
    done < <(yq -r '(.spec.sources // [.spec.source])[] | (.helm.valueFiles // [])[]' "$application")
  done < <(hosted_applications)
  return "$status"
}

# Only the render has to be evidenced, so this is what makes a new or renamed image anywhere else at least a diff someone reads.
# Wayline's own move with each promotion, in the render, and are not listed.
HOSTED_IMAGE_LIST=policy/hosted-images.txt

images_named_in() { # images_named_in <manifest...>: the image keys at any depth, and anything pinned by digest in any other string
  {
    yq -N -r 'select(. != null) | .. | select(tag == "!!map") | select(has("image")) | .image | select(tag == "!!str")' "$@"
    yq -N -r 'select(. != null) | .. | select(tag == "!!map") | select(has("baseImage")) | .baseImage | select(tag == "!!str")' "$@"
    yq -N -r 'select(. != null) | .. | select(tag == "!!str")' "$@" | { grep -oE '[[:alnum:]][[:alnum:]._/:-]*@sha256:[a-f0-9]{64}' || true; }
  } | { grep -E '[/:]' || true; } | LC_ALL=C sort -u
}

# hosted_images_listed <all|some> <manifest...>: every image these name is in the list. all when these are everything the list covers,
# so an entry nothing names fails too. SKIP_CHARTS leaves out the charts, and then only what is here can be compared.
hosted_images_listed() {
  local scope="$1" named listed unlisted stale status=0
  shift
  [[ -f "$HOSTED_IMAGE_LIST" ]] || { warn "$HOSTED_IMAGE_LIST is missing"; return 1; }
  named="$(images_named_in "$@")"
  listed="$(grep -vE '^(#|$)' "$HOSTED_IMAGE_LIST" | LC_ALL=C sort -u)"
  unlisted="$(LC_ALL=C comm -23 <(printf '%s\n' "$named") <(printf '%s\n' "$listed"))"
  if [[ -n "$unlisted" ]]; then
    warn "hosted production would run these, and they are not in $HOSTED_IMAGE_LIST. If each is meant, add it, so a person reads that diff: ${unlisted//$'\n'/, }"
    status=1
  fi
  if [[ "$scope" == all ]]; then
    stale="$(LC_ALL=C comm -13 <(printf '%s\n' "$named") <(printf '%s\n' "$listed"))"
    if [[ -n "$stale" ]]; then
      warn "$HOSTED_IMAGE_LIST lists these, and nothing hosted runs them, so take them out: ${stale//$'\n'/, }"
      status=1
    fi
  fi
  return "$status"
}

# Production runs these as well, and no manifest here names them: K3s's own images, and those of the probe pods that make
# remote-netpol, make remote-test and the restore test start on the VPS. scan-images.sh reads the list beside the other.
HOSTED_SYSTEM_IMAGE_LIST=policy/hosted-system-images.txt
HOSTED_PROBE_SCRIPTS=(scripts/test-netpol.sh scripts/hosted/restore-test.sh)

# Each image the probe scripts pin, one to a line. A script that pins none fails, because nothing would then say what it runs.
hosted_probe_images() {
  local script found
  for script in "${HOSTED_PROBE_SCRIPTS[@]}"; do
    found="$(grep -oE '[[:alnum:]][[:alnum:]._/:-]*@sha256:[a-f0-9]{64}' "$script")" ||
      { warn "$script pins no image, so nothing here says what its probe pods run"; return 1; }
    printf '%s\n' "$found"
  done
}

# Offline: every line names a tag and a digest, and every probe image is listed. K3s's lines are read against its release below.
hosted_probe_images_listed() {
  local listed unpinned probes unlisted status=0
  [[ -f "$HOSTED_SYSTEM_IMAGE_LIST" ]] || { warn "$HOSTED_SYSTEM_IMAGE_LIST is missing"; return 1; }
  listed="$(grep -vE '^(#|$)' "$HOSTED_SYSTEM_IMAGE_LIST" | LC_ALL=C sort -u || true)"
  # The tag is what K3s's release names and its pull uses, and the digest is what the scan reads.
  unpinned="$(grep -vE '^[^[:space:]@]+:[^[:space:]@/:]+@sha256:[a-f0-9]{64}$' <<<"$listed" || true)"
  if [[ -n "$unpinned" ]]; then
    warn "$HOSTED_SYSTEM_IMAGE_LIST names each image as name:tag@sha256:<digest>, and these are not: ${unpinned//$'\n'/, }"
    status=1
  fi
  probes="$(hosted_probe_images | LC_ALL=C sort -u)" || return 1
  unlisted="$(LC_ALL=C comm -23 <(printf '%s\n' "$probes") <(printf '%s\n' "$listed"))"
  if [[ -n "$unlisted" ]]; then
    warn "the probe pods on the VPS run these, and they are not in $HOSTED_SYSTEM_IMAGE_LIST, so the hosted scan would miss them: ${unlisted//$'\n'/, }"
    status=1
  fi
  return "$status"
}

# What each component k3s-config.yaml can disable runs, as K3s's own manifests name it at v1.36.6+k3s1, so the images of one
# turned off are not expected. Its pause image is every pod's sandbox, and nothing turns it off.
k3s_component_repositories() { # k3s_component_repositories <component>
  case "$1" in
    coredns) echo docker.io/rancher/mirrored-coredns-coredns ;;
    local-storage) echo docker.io/rancher/local-path-provisioner docker.io/rancher/mirrored-library-busybox ;;
    metrics-server) echo docker.io/rancher/mirrored-metrics-server ;;
    servicelb) echo docker.io/rancher/klipper-lb ;;
    # The helm-controller runs klipper-helm for each HelmChart, and Traefik's are the only ones K3s ships.
    traefik) echo docker.io/rancher/mirrored-library-traefik docker.io/rancher/klipper-helm ;;
    *) return 1 ;;
  esac
}

# K3s's own images for target.yaml's k3s_version, one to a line, less what k3s-config.yaml turns off. It needs the network once.
hosted_k3s_images() {
  local version cache component repositories="" image
  version="$(yq -r '.k3s_version // ""' infrastructure/hosted/plane-prod/target.yaml)"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || { warn "infrastructure/hosted/plane-prod/target.yaml states no k3s_version such as v1.36.6+k3s1"; return 1; }
  # A release's files never change, so one fetch serves every later run here.
  cache="$LOCAL_DIR/k3s-images/$version.txt"
  if [[ ! -s "$cache" ]]; then
    mkdir -p "${cache%/*}"
    if ! curl -fsSL --retry 8 --retry-connrefused -o "$cache.part" "https://github.com/k3s-io/k3s/releases/download/${version//+/%2B}/k3s-images.txt"; then
      rm -f "$cache.part"
      warn "could not read k3s-images.txt from K3s $version's release"
      return 1
    fi
    mv "$cache.part" "$cache"
  fi
  for component in $(yq -r '[.disable // []] | flatten | .[] | split(",") | .[]' infrastructure/hosted/plane-prod/k3s-config.yaml); do
    repositories+=" $(k3s_component_repositories "$component")" ||
      { warn "k3s-config.yaml disables $component, and nothing here says which images that leaves out"; return 1; }
  done
  while read -r image; do
    [[ -n "$image" ]] || continue
    case "$repositories " in *" ${image%:*} "*) continue ;; esac
    printf '%s\n' "$image"
  done <"$cache"
}

# The list's lines, each without its digest, hold K3s's own images, no more and no fewer, beside the probes.
hosted_k3s_images_listed() {
  local expected probes listed others missing stale status=0
  expected="$(hosted_k3s_images | LC_ALL=C sort -u)" || return 1
  [[ -n "$expected" ]] || { warn "K3s's release lists no image, which cannot be right"; return 1; }
  probes="$(hosted_probe_images | LC_ALL=C sort -u)" || return 1
  listed="$(grep -vE '^(#|$)' "$HOSTED_SYSTEM_IMAGE_LIST" | LC_ALL=C sort -u || true)"
  others="$(LC_ALL=C comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$probes") | sed -E 's/@sha256:[a-f0-9]{64}$//' | LC_ALL=C sort -u)"
  # A probe could be one of K3s's own too, and then it is listed once, as a probe.
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n%s\n' "$others" "$(sed -E 's/@sha256:[a-f0-9]{64}$//' <<<"$probes")" | LC_ALL=C sort -u))"
  if [[ -n "$missing" ]]; then
    warn "K3s runs these, and they are not in $HOSTED_SYSTEM_IMAGE_LIST. Add each with the digest its tag names: ${missing//$'\n'/, }"
    status=1
  fi
  stale="$(LC_ALL=C comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$others"))"
  if [[ -n "$stale" ]]; then
    warn "$HOSTED_SYSTEM_IMAGE_LIST lists these, and neither K3s nor a probe runs them, so take them out: ${stale//$'\n'/, }"
    status=1
  fi
  return "$status"
}

# The digest of zeros stands for an image that is not built yet, and the list and the manifest agree on it, so hosted_images_listed passes.
# No registry serves it, and nothing after the merge refuses it: publish-release.sh confirms Wayline's digests on GHCR and no others. It
# would show only after the sync, as ImagePullBackOff, with the app's Application Degraded and the root's sync failing with it. The render
# is not read here, because there it means a set not yet promoted, which scripts/ci/check-prod-evidence.sh reads.
HOSTED_PLACEHOLDER_DIGEST="sha256:$(printf '0%.0s' {1..64})"

no_placeholder_digest() { # no_placeholder_digest <file or directory...>: comments too, as the Wayline name check reads them
  local found status=0
  found="$(grep -rnE -- "$HOSTED_PLACEHOLDER_DIGEST([^0-9a-f]|\$)" "$@")" || status=$?
  case "$status" in
    0)
      warn "these name the placeholder digest of zeros, which no registry serves. Promote each built image in its place first, with promote-app.yml or make promote-app: ${found//$'\n'/, }"
      return 1
      ;;
    1) return 0 ;;
    *)
      warn "could not read $*"
      return 1
      ;;
  esac
}

# No Alloy here to run it, so this takes the stage's own expression and does as stage.replace does, on the line Alertmanager logs when
# a send to Telegram fails: each capture group becomes the replacement.
alloy_scrubs_the_telegram_token() { # alloy_scrubs_the_telegram_token <values file>
  yq -r '.alloy.configMap.content' "$1" | python3 -I -c '
import re, sys
config = sys.stdin.read()
stage = re.search(r"stage\.replace\s*\{\s*expression\s*=\s*\"([^\"]+)\"\s*replace\s*=\s*\"([^\"]*)\"", config)
if not stage or config.index("stage.replace") > config.index("forward_to = [loki.write"):
    sys.exit("no stage.replace ahead of what goes to Loki, so a bot token in a log line would reach it")
token = "123456789:" + "AbC-d_E" * 5
line = "msg=\"Notify for alerts failed\" err=\"primary/telegram[0]: notify retry canceled: Post \\\"https://api.telegram.org/bot" + token + "/sendMessage\\\": dial tcp: lookup api.telegram.org: no such host\""
pattern = re.compile(stage.group(1))
found = pattern.search(line)
if not found or not found.groups():
    sys.exit("stage.replace does not capture the token in a line Alertmanager logs")
scrubbed = line
for group in range(found.re.groups, 0, -1):
    scrubbed = scrubbed[:found.start(group)] + stage.group(2) + scrubbed[found.end(group):]
if token in scrubbed or "api.telegram.org" not in scrubbed:
    sys.exit("stage.replace leaves the token in the line, or takes more than the token: " + scrubbed.replace(token, "<the token>"))
'
}

render_chart() { # render_chart <output directory> <release> <namespace> <repository> <chart> <version> <values file...>
  local out="$1" release="$2" namespace="$3" repo="$4" chart="$5" version="$6" value
  shift 6
  # Argo CD names an OCI repository with no scheme, and Helm wants one and the chart in the same reference.
  local reference=("$chart" --repo "$repo")
  [[ "$repo" == http://* || "$repo" == https://* ]] || reference=("oci://${repo#oci://}/$chart")
  local args=("${reference[@]}" --version "$version" --kube-version "${CHART_KUBE_VERSION:-$K8S_VERSION}" --namespace "$namespace")
  for value in "$@"; do args+=(--values "$value"); done
  if ! helm template "$release" "${args[@]}" >"$out/$release.yaml" 2>"$out/$release.err"; then
    cat "$out/$release.err" >&2
    warn "$release: helm template failed"
    return 1
  fi
}

# Each chart source of each Application named on stdin, one to a line. CHARTS_RENDERED counts them.
render_application_charts() { # render_application_charts <directory>
  local out="$1" application name repo chart version values value status=0
  while read -r application; do
    name="$(yq -r '.metadata.name' "$application")"
    while IFS=$'\t' read -r repo chart version values; do
      [[ -n "$chart" ]] || continue
      local files=()
      for value in $values; do files+=("${value#\$values/}"); done
      if render_chart "$out" "$name" "$(yq -r '.spec.destination.namespace' "$application")" "$repo" "$chart" "$version" ${files[@]+"${files[@]}"}; then
        CHARTS_RENDERED=$((CHARTS_RENDERED + 1))
      else
        status=1
      fi
    done < <(yq -r '
      (.spec.sources // [.spec.source])[] | select(.chart != null)
      | [.repoURL, .chart, .targetRevision, ((.helm.valueFiles // []) | join(" "))] | @tsv' "$application")
  done
  return "$status"
}

render_argocd_chart() { # render_argocd_chart <directory> <values file>: the one chart Terraform installs
  local out="$1" values="$2" release=infrastructure/terraform/modules/argocd/main.tf
  terraform_field() { awk -v field="$1" '/^resource "helm_release" "argocd"/ { inside = 1 } inside && $1 == field { gsub(/"/, "", $3); print $3; exit } inside && /^}/ { exit }' "$release"; }
  render_chart "$out" "$(terraform_field name)" argocd "$(terraform_field repository)" "$(terraform_field chart)" "$(terraform_field version)" "$values" || return 1
  CHARTS_RENDERED=$((CHARTS_RENDERED + 1))
}

# Every third-party chart this platform installs: one for each Application with a chart source, plus
# Argo CD, the one chart Terraform installs. The .err files stay beside the renders, so read *.yaml.
render_platform_charts() { # render_platform_charts <directory>
  local out="$1" status=0
  mkdir -p "$out"
  CHARTS_RENDERED=0
  render_application_charts "$out" < <(find gitops/applications -type f -name '*.yaml' | sort) || status=1
  render_argocd_chart "$out" helm/values/argocd.yaml || status=1
  ok "$CHARTS_RENDERED platform chart(s) rendered"
  return "$status"
}

# The same for hosted production: its own Applications, values and Kubernetes version. Nothing here if the tree is empty.
render_hosted_charts() { # render_hosted_charts <directory>
  local out="$1" status=0 CHART_KUBE_VERSION
  mkdir -p "$out"
  CHART_KUBE_VERSION="$(hosted_k8s_version)"
  CHARTS_RENDERED=0
  render_application_charts "$out" < <(hosted_applications) || status=1
  if [[ -f "$HOSTED_TREE/values/argocd.yaml" ]]; then
    render_argocd_chart "$out" "$HOSTED_TREE/values/argocd.yaml" || status=1
  fi
  ok "$CHARTS_RENDERED hosted chart(s) rendered"
  return "$status"
}
