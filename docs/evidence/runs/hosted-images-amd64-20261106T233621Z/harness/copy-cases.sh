#!/usr/bin/env bash
# Scratch harness: copy-to-local-registry.sh with stub docker and gh, to see what it logs in with and what it prints.
set -uo pipefail
S="$1"; R=/Users/bek/dev/pr/plane-platform; T="$S/copy-tree"
rm -rf "$T"; mkdir -p "$T/scripts/ci" "$T/scripts/lib" "$T/.tools/bin" "$T/helm/plane/overlays/dev" "$T/state"
cp "$R/scripts/ci/copy-to-local-registry.sh" "$T/scripts/ci/"; cp "$R/scripts/lib/common.sh" "$T/scripts/lib/"; cp "$R/.tools/bin/yq" "$T/.tools/bin/"
cat >"$T/helm/plane/overlays/dev/kustomization.yaml" <<'YAML'
images:
- digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  name: artifacts.plane.so/makeplane/plane-admin
  newName: localhost:5001/wayline/admin
- digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  name: artifacts.plane.so/makeplane/plane-backend
  newName: localhost:5001/wayline/backend
- digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  name: artifacts.plane.so/makeplane/plane-live
- digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  name: artifacts.plane.so/makeplane/plane-frontend
  newName: localhost:5001/wayline/web
YAML
TOKEN=<made-up token>
cat >"$T/.tools/bin/docker" <<STUB
#!/bin/bash
S="$T/state"
echo "docker \$*" >>"\$S/argv.log"
case "\$1 \$2 \$3" in
  "login ghcr.io --username")
    [[ "\$*" == *--password-stdin* ]] || { echo "NOT STDIN" >>"\$S/argv.log"; exit 1; }
    got="\$(cat)"
    [[ "\$got" == "$TOKEN" ]] || { echo "WRONG STDIN" >>"\$S/argv.log"; exit 1; }
    touch "\$S/logged-in"; echo "Login Succeeded"; exit 0 ;;
  "buildx imagetools inspect")
    case "\$4" in
      localhost:*) [[ "\${DEST_READS:-yes}" == yes ]]; exit \$? ;;
      *) if [[ "\${READABLE:-no}" == always ]] || { [[ "\${READABLE:-no}" == after-login ]] && [[ -e "\$S/logged-in" ]]; }; then exit 0; fi
         echo "ERROR: failed to authorize: 403 Forbidden" >&2; exit 1 ;;
    esac ;;
  "buildx imagetools create")
    # Reads stdin, as a command in that loop might. The list must not come through it.
    cat >/dev/null
    echo created >>"\$S/created.log"; exit 0 ;;
esac
echo "unexpected docker call: \$*" >&2; exit 99
STUB
cat >"$T/.tools/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >>"$T/state/argv.log"
case "\$*" in
  "api user --jq .login") echo BereketAbera ;;
  "auth token") [[ "\${GH_TOKEN_FAILS:-no}" == no ]] || { echo "no oauth token" >&2; exit 1; }; echo "$TOKEN" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/.tools/bin/docker" "$T/.tools/bin/gh"
wrong=0
case_() { # case_ <label> <expected exit> <source> <expected logins> <expected creates> <text the output must hold or -> [env...]
  local label="$1" want="$2" source="$3" logins="$4" creates="$5" text="$6"; shift 6
  rm -f "$T/state/"*
  : >"$T/state/argv.log"; : >"$T/state/created.log"
  env -i HOME="$HOME" PATH="/usr/bin:/bin" "$@" "$T/scripts/ci/copy-to-local-registry.sh" "$source" dev >"$T/state/out.txt" 2>&1 </dev/null
  local got=$? good=yes
  [[ "$got" == "$want" ]] || { good="no, exit $got, wanted $want"; }
  local l c; l="$(grep -c '^docker login' "$T/state/argv.log")"; c="$(wc -l <"$T/state/created.log" | tr -d ' ')"
  [[ "$l" == "$logins" ]] || good="no, $l logins, wanted $logins"
  [[ "$c" == "$creates" ]] || good="no, $c copies, wanted $creates"
  if grep -q "$TOKEN" "$T/state/out.txt" "$T/state/argv.log"; then good="no, THE TOKEN WAS PRINTED OR PASSED AS AN ARGUMENT"; fi
  if [[ "$text" != - ]] && ! grep -qF -- "$text" "$T/state/out.txt"; then good="no, the output lacks: $text"; fi
  if [[ "$good" == yes ]]; then echo "PASS $label: exit $got, $l login(s), $c copies"; else echo "FAIL $label: $good"; sed 's/^/   /' "$T/state/out.txt" | cut -c1-220; wrong=$((wrong+1)); fi
}
G=ghcr.io/BereketAbera/wayline
case_ "already readable: no login, three copied" 0 "$G" 0 3 "3 image(s) present" READABLE=always
case_ "not readable, then readable after gh's login" 0 "$G" 1 3 "with gh's token" READABLE=after-login
case_ "still not readable after login: stops, nothing copied" 1 "$G" 1 0 "gh auth refresh -h github.com -s read:packages" READABLE=never
case_ "the registry's own answer is shown" 1 "$G" 1 0 "403 Forbidden" READABLE=never
# The pipe starts docker login either way. It gets nothing on stdin, and the pipeline's failure is what stops the script.
case_ "gh has no token: stops" 1 "$G" 1 0 "docker login ghcr.io as BereketAbera failed" READABLE=never GH_TOKEN_FAILS=yes
case_ "another registry: no gh, no login" 1 quay.io/someone/wayline 0 0 "Log in to that registry" READABLE=never
case_ "the copy cannot be read back by digest: stops at the first" 1 "$G" 0 1 "did not end up with" READABLE=always DEST_READS=no
# No gh at all
mv "$T/.tools/bin/gh" "$T/gh.moved"
case_ "no gh: says what to do" 1 "$G" 0 0 "there is no gh to log in with" READABLE=never
mv "$T/gh.moved" "$T/.tools/bin/gh"
echo "--- what the login path printed, as a person sees it"
rm -f "$T/state/"*; : >"$T/state/argv.log"; : >"$T/state/created.log"
env -i HOME="$HOME" PATH="/usr/bin:/bin" READABLE=after-login "$T/scripts/ci/copy-to-local-registry.sh" "$G" dev </dev/null 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-170
echo "--- argv log"; cut -c1-150 "$T/state/argv.log" | head -12
echo "copy-cases: $wrong wrong"
exit "$wrong"
