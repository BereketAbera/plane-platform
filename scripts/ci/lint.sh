#!/usr/bin/env bash
# Static checks on the code in this repository. CI and make ci both run this script.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" shellcheck actionlint zizmor conftest terraform tflint hadolint >/dev/null
cd "$ROOT"

failed=0
run() { # run <label> <command...>
  local label="$1"; shift
  log "$label"
  if "$@"; then ok "$label"; else warn "$label FAILED"; failed=$((failed + 1)); fi
}

# Tracked files and new ones Git would pick up, so CI and make ci see the same set, and something
# gitignored, such as a fetched upstream source tree, is never linted as if it were ours.
files_matching() { # files_matching <pathspec...>
  local file
  while read -r file; do
    if [[ -f "$file" ]]; then printf '%s\n' "$file"; fi
  done < <(git ls-files --cached --others --exclude-standard -- "$@" ':(exclude)helm/plane/vendor/**')
}
scripts_to_check() { files_matching '*.sh'; }
python_files() { files_matching '*.py'; }
dockerfiles() { files_matching '*Dockerfile' '*Dockerfile.*' ':(exclude)*.dockerignore'; }
terraform_dirs() { find infrastructure/terraform infisical -type f -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; 2>/dev/null | sort -u; }
terraform_roots() { terraform_dirs | grep -v '/modules/' || true; }

shellcheck_all() { scripts_to_check | xargs shellcheck --external-sources --source-path=SCRIPTDIR --severity=warning; }

hadolint_all() {
  local file status=0
  while read -r file; do hadolint --failure-threshold warning "$file" || status=1; done < <(dockerfiles)
  return "$status"
}

terraform_validate_all() {
  local dir status=0
  while read -r dir; do
    [[ -n "$dir" ]] || continue
    # -backend=false: CI holds no state and never talks to a cluster. Provider schemas are enough.
    if ! terraform -chdir="$dir" init -backend=false -input=false -no-color >/dev/null ||
      ! terraform -chdir="$dir" validate -no-color; then
      warn "terraform validate failed in $dir"
      status=1
    fi
  done < <(terraform_roots)
  return "$status"
}

tflint_all() {
  local dir status=0
  while read -r dir; do
    [[ -n "$dir" ]] || continue
    tflint --chdir="$dir" --no-color || status=1
  done < <(terraform_dirs)
  return "$status"
}

python_compile_all() {
  # PYTHONPYCACHEPREFIX keeps __pycache__ out of the tree.
  python_files | PYTHONPYCACHEPREFIX="$(mktemp -d)" xargs python3 -m py_compile
}

smoke_self_check() {
  python3 -B tests/e2e/smoke.py --help >/dev/null &&
    python3 -B tests/e2e/smoke.py --selftest
}

run "shellcheck" shellcheck_all
run "actionlint" actionlint -color=false
# --offline: no GitHub token here, and the online audits add little for pinned actions.
run "zizmor" zizmor --offline --no-progress --strict-collection .github/workflows
run "terraform fmt" terraform fmt -check -recursive -diff infrastructure/terraform infisical/terraform
run "terraform validate" terraform_validate_all
run "tflint" tflint_all
run "hadolint" hadolint_all
run "conftest verify" conftest verify --policy policy --no-color
run "python compile" python_compile_all
run "smoke.py self check" smoke_self_check

[[ "$failed" -eq 0 ]] || die "$failed lint check(s) failed"
ok "lint passed"
