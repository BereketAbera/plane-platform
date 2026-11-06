#!/usr/bin/env bash
# The opt-in for scripts shared with the local platform. They carry one line,
#   if [[ -n "${WAYLINE_TARGET:-}" ]]; then source "$ROOT/scripts/hosted/target.sh"; fi
# and without the variable they do exactly what they always did. With it, this re-roots LOCAL_DIR, KUBECONFIG and KUBE_CONTEXT
# through scripts/hosted/lib.sh, and verifies the target, before they read any of those.
#
# What the shared scripts read from here, each with a default of their own that keeps the local behaviour:
#   WAYLINE_ENVIRONMENTS                 the environments to act on, in place of "dev prod-sim"
#   TF_VAR_environments                  the projects and namespaces infisical/terraform makes, in place of its default
#   HOSTED_INFISICAL_ADMIN_EMAIL         the first admin's address
#   HOSTED_INFISICAL_TF_BACKEND          Terraform state for the Infisical root, under LOCAL_DIR
#   HOSTED_NETPOL_MATRIX                 what scripts/test-netpol.sh runs
#   HOSTED_SEED_FROM_FILES               what scripts/infisical-seed.sh takes from a file here, and does not generate
#   HOSTED_EVIDENCE_DIR                  where evidence goes, from lib.sh
if [[ "${WAYLINE_TARGET:-}" != plane-prod ]]; then
  printf 'fail WAYLINE_TARGET is "%s", and the only target there is is plane-prod\n' "${WAYLINE_TARGET:-}" >&2
  exit 1
fi
export TARGET=plane-prod
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export WAYLINE_ENVIRONMENTS="prod"
export TF_VAR_environments='{"prod":{"project":"plane-prod","namespace":"plane-prod"}}'
export HOSTED_INFISICAL_ADMIN_EMAIL="admin@$HOSTED_DOMAIN"
export HOSTED_INFISICAL_TF_BACKEND="path=$LOCAL_DIR/terraform/infisical/terraform.tfstate"
export HOSTED_NETPOL_MATRIX="$ROOT/tests/network-policy-matrix-plane-prod.yaml"
export HOSTED_SEED_FROM_FILES="GHCR_PULL_TOKEN"
