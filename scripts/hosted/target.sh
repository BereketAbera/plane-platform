#!/usr/bin/env bash
# The opt-in for scripts shared with the local platform. They carry one line,
#   if [[ -n "${WAYLINE_TARGET:-}" ]]; then source "$ROOT/scripts/hosted/target.sh"; fi
# and without the variable they do exactly what they always did. With it, this re-roots LOCAL_DIR, KUBECONFIG and KUBE_CONTEXT
# through scripts/hosted/lib.sh, and verifies the target, before they read any of those.
#
# The variable alone aims nothing. It could leak into a shell, and make up and scripts/test.sh call these same scripts, so it needs
# CONFIRM=plane-prod too, and the CONFIRM=yes those scripts take from a person does not count. That goes for the one that only reads:
# a leak must not read production's Secrets through a local test either. Before lib.sh, so a leak does not even open the tunnel.
#
# What the shared scripts read from here, each with a default of their own that keeps the local behaviour:
#   WAYLINE_ENVIRONMENTS                 the environments to act on, in place of "dev prod-sim": Plane's, and each app's with secrets
#   TF_VAR_environments                  the projects and namespaces infisical/terraform makes, in place of its default. Each
#                                        environment's namespace is read from here (env_namespace in infisical/lib/api.sh)
#   HOSTED_INFISICAL_ADMIN_EMAIL         the first admin's address
#   HOSTED_INFISICAL_TF_BACKEND          Terraform state for the Infisical root, under LOCAL_DIR
#   HOSTED_NETPOL_MATRIX                 what scripts/test-netpol.sh runs
#   HOSTED_SEED_FROM_FILES               what scripts/infisical-seed.sh takes from a file here, and does not generate, as
#                                        <environment>:<key>, because each environment's project holds its own copy
#   HOSTED_EVIDENCE_DIR                  where evidence goes, from lib.sh
if [[ "${WAYLINE_TARGET:-}" != plane-prod ]]; then
  printf 'fail WAYLINE_TARGET is "%s", and the only target there is is plane-prod\n' "${WAYLINE_TARGET:-}" >&2
  exit 1
fi
if [[ "${CONFIRM:-}" != plane-prod ]]; then
  printf 'fail WAYLINE_TARGET=plane-prod aims this script at hosted production, so it needs CONFIRM=plane-prod. CONFIRM=yes does not count. If you did not mean hosted production: unset WAYLINE_TARGET\n' >&2
  exit 1
fi
# HOSTED_RESTORE_WITHOUT_APPS=yes leaves every app's environment out, and only beside INFISICAL_RESTORED=yes. Restored mode stops when
# Terraform would make anything, so a database restored from before an app's project would stop it there, before prod's CA and identity,
# and Wayline's secrets must not wait on an app's. A plain run after it makes the app's again, as a first bootstrap does. Anywhere else,
# Terraform would destroy the project of each environment left out, and every secret in it.
case "${HOSTED_RESTORE_WITHOUT_APPS:-}" in
  "") ;;
  yes)
    if [[ "${INFISICAL_RESTORED:-}" != yes ]]; then
      printf 'fail HOSTED_RESTORE_WITHOUT_APPS=yes is for INFISICAL_RESTORED=yes alone: anywhere else, Terraform would destroy the project of every app it leaves out\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'fail HOSTED_RESTORE_WITHOUT_APPS takes yes or nothing, and got "%s"\n' "$HOSTED_RESTORE_WITHOUT_APPS" >&2
    exit 1
    ;;
esac
export TARGET=plane-prod
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Plane's environment, then Frameflow's: a project of its own, with a reader bound to its own namespace, because a viewer reads every key
# in its project. Never rename the prod key or its project. Terraform's resources are keyed by them, so it would destroy plane-prod's
# project and every secret in it, and a destroyed slug stays taken for 14 days.
if [[ "${HOSTED_RESTORE_WITHOUT_APPS:-}" == yes ]]; then
  export WAYLINE_ENVIRONMENTS="prod"
  export TF_VAR_environments='{"prod":{"project":"plane-prod","namespace":"plane-prod"}}'
else
  export WAYLINE_ENVIRONMENTS="prod frameflow"
  export TF_VAR_environments='{"prod":{"project":"plane-prod","namespace":"plane-prod"},"frameflow":{"project":"frameflow-prod","namespace":"frameflow"}}'
fi
export HOSTED_INFISICAL_ADMIN_EMAIL="admin@$HOSTED_DOMAIN"
export HOSTED_INFISICAL_TF_BACKEND="path=$LOCAL_DIR/terraform/infisical/terraform.tfstate"
export HOSTED_NETPOL_MATRIX="$ROOT/tests/network-policy-matrix-plane-prod.yaml"
# The GHCR token, which GitHub issues, for each project's ghcr-pull. And what scripts/hosted/frameflow-inputs.sh made once for Frameflow:
# the sha256 of the owner's access key, and Hatchet's keysets, which must stay the ones its database was encrypted with.
export HOSTED_SEED_FROM_FILES="prod:GHCR_PULL_TOKEN frameflow:GHCR_PULL_TOKEN frameflow:OWNER_TOKEN_SHA256 frameflow:HATCHET_MASTER_KEYSET frameflow:HATCHET_JWT_PRIVATE_KEYSET frameflow:HATCHET_JWT_PUBLIC_KEYSET"
