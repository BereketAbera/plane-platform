#!/usr/bin/env bash
# Contract section 4: one owner per resource. Fails if Terraform and Argo CD both claim the same
# kind/namespace/name, if either owner holds a kind the contract gives to the other, or if two
# Argo CD sources declare the same object. Static, so a name Terraform computes at plan time is
# covered only by the rules that work per kind.
#
# Per cluster, because a resource has one owner in each. Hosted production's tree holds its own copies of local objects
# on purpose, each Application and policy under the same name, and those are two resources on two clusters. So nothing
# found in one cluster's sources is compared with the other's, and Terraform's shared modules count for both.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" yq >/dev/null
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
problems=0
problem() { warn "$CLUSTER_NAME_HERE: $*"; problems=$((problems + 1)); }

# Kinds that only Terraform may own, per the contract. Argo CD also never creates Namespaces.
TERRAFORM_ONLY_KINDS='^(Namespace|ResourceQuota|LimitRange|AppProject|StorageClass)$'
# Provider resources for kinds that only Argo CD may own.
ARGO_ONLY_RESOURCES='kubernetes_(deployment|stateful_set|daemon_?set|service|ingress|network_policy|job|cron_job|persistent_volume_claim|service_account|cluster_role|cluster_role_binding|role|role_binding)(_v[0-9]+)?'

inventory() { # inventory <file>: kind/namespace/name for each object, tolerating non-Kubernetes YAML
  yq -N -r 'select(.kind != null and .metadata.name != null) | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1"
}

yaml_under() { [[ -d "$1" ]] && find "$1" -type f -name '*.yaml' -not -name 'kustomization.yaml' | sort; }

# --- Argo CD's side: every path an Application syncs from Git.
add_argo() { # add_argo <file> [default-namespace]
  local file="$1" default_namespace="${2:--}" entry kind namespace name
  while read -r entry; do
    kind="${entry%%/*}"; name="${entry##*/}"; namespace="${entry#*/}"; namespace="${namespace%/*}"
    [[ "$namespace" != - ]] || namespace="$default_namespace"
    printf '%s/%s/%s %s\n' "$kind" "$namespace" "$name" "$file" >>"$ARGO_FILE"
  done < <(inventory "$file")
}

argo_sources_local() {
  local file
  while read -r file; do add_argo "$file" argocd; done < <(yaml_under gitops/applications)
  while read -r file; do add_argo "$file"; done < <(yaml_under gitops/platform)
  while read -r file; do add_argo "$file"; done < <(yaml_under gitops/bootstrap/argocd-route)
  while read -r file; do add_argo "$file"; done < <(yaml_under infisical/manifests)
  add_argo gitops/environments/dev/manifests.yaml plane-dev
  add_argo gitops/environments/prod-sim/manifests.yaml plane-prod-sim
  # Built, because bases under monitoring/manifests are stamped per environment by Kustomize.
  if [[ -f monitoring/manifests/kustomization.yaml ]]; then
    "$ROOT/scripts/install-tools.sh" kustomize >/dev/null
    kustomize build monitoring/manifests >"$WORK/monitoring.yaml"
    add_argo "$WORK/monitoring.yaml" monitoring
  fi
}

# The hosted tree may be empty, and every part of it may not exist yet.
HOSTED_TREE=gitops/clusters/plane-prod
HOSTED_APPLICATION_TEMPLATE="$HOSTED_TREE/plane-prod-application.yaml.tmpl"
argo_sources_plane_prod() {
  local file platform_dir
  while read -r file; do add_argo "$file" argocd; done < <(yaml_under "$HOSTED_TREE/applications")
  # The first promotion copies this to applications/, when it must already fit, and it stays here as the source of that copy.
  if [[ -f "$HOSTED_APPLICATION_TEMPLATE" && ! -f "$HOSTED_TREE/applications/plane-prod.yaml" ]]; then
    add_argo "$HOSTED_APPLICATION_TEMPLATE" argocd
  fi
  for platform_dir in "$HOSTED_TREE"/platform/*/; do
    [[ -d "$platform_dir" ]] || continue
    if [[ -f "$platform_dir/kustomization.yaml" ]]; then
      "$ROOT/scripts/install-tools.sh" kustomize >/dev/null
      kustomize build "$platform_dir" >"$WORK/hosted-$(basename "$platform_dir").yaml"
      add_argo "$WORK/hosted-$(basename "$platform_dir").yaml"
    else
      while read -r file; do add_argo "$file"; done < <(yaml_under "${platform_dir%/}")
    fi
  done
  add_argo gitops/environments/prod/manifests.yaml plane-prod
}

# --- Terraform's side: the charts it installs and the objects its resources name.
# The modules and Infisical's root serve both clusters. Each environment root belongs to one.
HOSTED_ROOTS='^infrastructure/terraform/environments/prod(-host)?/'
all_terraform_files() { find infrastructure/terraform infisical/terraform -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | sort; }
terraform_files_local() { all_terraform_files | { grep -Ev "$HOSTED_ROOTS" || true; }; }
terraform_files_plane_prod() { all_terraform_files | { grep -Ev '^infrastructure/terraform/environments/' || true; }; all_terraform_files | { grep -E "$HOSTED_ROOTS" || true; }; }

bootstrap_chart_local() { printf '%s\n' gitops/bootstrap/chart/templates; }
bootstrap_chart_plane_prod() { printf '%s\n' "$HOSTED_TREE/bootstrap-chart/templates"; }
applications_local() { yaml_under gitops/applications; }
applications_plane_prod() {
  yaml_under "$HOSTED_TREE/applications" || true
  if [[ -f "$HOSTED_APPLICATION_TEMPLATE" ]]; then printf '%s\n' "$HOSTED_APPLICATION_TEMPLATE"; fi
}

check_cluster() { # check_cluster <local|plane_prod> <the name to report it under>
  local cluster="$1" file entry key kind name namespace argo_key argo_file argo_namespace chart type
  CLUSTER_NAME_HERE="$2"
  ARGO_FILE="$WORK/argo-$cluster"
  TF_FILE="$WORK/terraform-$cluster"
  : >"$ARGO_FILE"
  : >"$TF_FILE"
  : >"$WORK/tf-resources"

  "argo_sources_$cluster"

  while read -r file; do
    # The bootstrap chart is applied by helm_release.bootstrap. It is valid YAML by design, but a
    # templated namespace has no literal value, so treat it as matching any.
    while read -r entry; do
      printf '%s %s\n' "$(sed 's|/{{[^/]*}}/|/-/|' <<<"$entry")" "$file" >>"$TF_FILE"
    done < <(inventory "$file")
  done < <(yaml_under "$("bootstrap_chart_$cluster")" || true)

  while read -r file; do
    # One line per resource block: type, then the first literal kind, name and namespace inside it.
    awk -v file="$file" '
      function blank(v) { return v == "" ? "-" : v }
      function flush() { if (type != "") printf "%s\t%s\t%s\t%s\t%s\n", type, blank(kind), blank(ns), blank(nm), file }
      /^resource "/ { flush(); split($0, part, "\""); type = part[2]; kind = ""; ns = ""; nm = ""; next }
      /^}/ { flush(); type = "" ; next }
      type != "" && nm == "" && match($0, /^[ \t]*name[ \t]*=[ \t]*"[^"$]+"/) { s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s); nm = s }
      type != "" && ns == "" && match($0, /^[ \t]*namespace[ \t]*=[ \t]*"[^"$]+"/) { s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s); ns = s }
      type != "" && kind == "" && match($0, /^[ \t]*kind[ \t]*=[ \t]*"[^"$]+"/) { s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s); kind = s }
      END { flush() }
    ' "$file" >>"$WORK/tf-resources"
  done < <("terraform_files_$cluster")

  while IFS=$'\t' read -r type kind namespace name file; do
    if [[ "$type" =~ ^$ARGO_ONLY_RESOURCES$ ]]; then
      problem "$file: Terraform resource $type belongs to Argo CD under the contract"
    fi
    case "$type" in
      kubernetes_namespace*) kind=Namespace ;;
      kubernetes_resource_quota*) kind=ResourceQuota ;;
      kubernetes_limit_range*) kind=LimitRange ;;
      kubernetes_config_map*) kind=ConfigMap ;;
      kubernetes_secret*) kind=Secret ;;
      kubernetes_storage_class*) kind=StorageClass ;;
      kubernetes_manifest) ;;
      *) continue ;;
    esac
    # A computed name cannot be matched here. The per-kind rules still cover it.
    [[ "$kind" != - && "$name" != - ]] || continue
    printf '%s/%s/%s %s\n' "$kind" "$namespace" "$name" "$file" >>"$TF_FILE"
  done <"$WORK/tf-resources"

  # --- The rules.

  # 1. A kind Terraform owns must not appear in any Argo CD source.
  while read -r key file; do
    kind="${key%%/*}"
    if [[ "$kind" =~ $TERRAFORM_ONLY_KINDS ]]; then
      problem "$file: $key is owned by Terraform, not Argo CD"
    fi
  done <"$ARGO_FILE"

  # 2. The same object under both owners. A Terraform name with no literal namespace matches any.
  while read -r key file; do
    kind="${key%%/*}"; name="${key##*/}"; namespace="${key#*/}"; namespace="${namespace%/*}"
    while read -r argo_key argo_file; do
      [[ -n "$argo_key" ]] || continue
      argo_namespace="${argo_key#*/}"; argo_namespace="${argo_namespace%/*}"
      if [[ "$namespace" == - || "$argo_namespace" == - || "$namespace" == "$argo_namespace" ]]; then
        problem "$key is owned twice: Terraform in $file, Argo CD in $argo_file"
      fi
    done < <(awk -v kind="$kind" -v name="$name" '{ c = split($1, p, "/"); if (p[1] == kind && p[c] == name) print }' "$ARGO_FILE")
  done <"$TF_FILE"

  # 3. CoreDNS is rewritten by Terraform. An Argo CD copy would fight it on every sync. K3s reads its rewrites from a
  # second ConfigMap, and that one is Terraform's in the same way.
  if grep -qE '^ConfigMap/kube-system/coredns(-custom)? ' "$ARGO_FILE"; then
    problem "$(grep -E '^ConfigMap/kube-system/coredns(-custom)? ' "$ARGO_FILE" | cut -d' ' -f1 | head -1) is owned by Terraform, not Argo CD"
  fi

  # 4. Two Argo CD sources declaring one object would have Applications fight over it.
  cut -d' ' -f1 "$ARGO_FILE" | sort | uniq -d >"$WORK/duplicates"
  while read -r key; do
    problem "$key is declared by more than one Argo CD source: $(grep -F "$key " "$ARGO_FILE" | cut -d' ' -f2 | sort -u | tr '\n' ' ')"
  done <"$WORK/duplicates"

  # 5. Argo CD never creates namespaces and never manages itself.
  while read -r file; do
    if yq -r '.spec.syncPolicy.syncOptions[]?' "$file" | grep -qx 'CreateNamespace=true'; then
      problem "$file: CreateNamespace=true, but Terraform creates every namespace"
    fi
    while read -r chart; do
      if "terraform_files_$cluster" | xargs grep -q "chart[[:space:]]*=[[:space:]]*\"$chart\"" /dev/null; then
        problem "$file: chart $chart is installed by both Argo CD and Terraform"
      fi
    done < <(yq -r '(.spec.sources // [.spec.source])[] | select(.chart != null) | .chart' "$file")
  done < <("applications_$cluster" || true)
}

check_cluster local kind
ok "kind: $(wc -l <"$WORK/argo-local" | tr -d ' ') Argo CD objects and $(wc -l <"$WORK/terraform-local" | tr -d ' ') Terraform objects"
check_cluster plane_prod plane-prod
ok "plane-prod: $(wc -l <"$WORK/argo-plane_prod" | tr -d ' ') Argo CD objects and $(wc -l <"$WORK/terraform-plane_prod" | tr -d ' ') Terraform objects"

[[ "$problems" -eq 0 ]] || die "$problems ownership problem(s)"
ok "no resource has two owners on either cluster"
