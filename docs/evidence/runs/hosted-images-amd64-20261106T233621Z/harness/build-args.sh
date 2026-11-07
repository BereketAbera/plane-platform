#!/usr/bin/env bash
# Scratch harness: build-images.sh with docker, curl and python3 stubbed, to read exactly what it would run. Nothing is built.
set -uo pipefail
S="$1"; R=/Users/bek/dev/pr/plane-platform
mk() { # mk <tree> <script source: HEAD or WORK>
  local T="$1"
  rm -rf "$T"; mkdir -p "$T/scripts/ci" "$T/scripts/lib" "$T/apps/wayline/scripts" "$T/apps/wayline/backend" "$T/apps/wayline/runtime" "$T/.tools/bin" "$T/stubs" "$T/.build/wayline-dist"
  if [[ "$2" == HEAD ]]; then git -C "$R" show HEAD:scripts/ci/build-images.sh >"$T/scripts/ci/build-images.sh"; else cp "$R/scripts/ci/build-images.sh" "$T/scripts/ci/"; fi
  chmod +x "$T/scripts/ci/build-images.sh"
  cp "$R/scripts/lib/common.sh" "$T/scripts/lib/"
  cp "$R/apps/wayline/scripts/lib.sh" "$R/apps/wayline/scripts/publish-gate.sh" "$T/apps/wayline/scripts/"
  cp "$R/apps/wayline/UPSTREAM" "$R/apps/wayline/images.txt" "$T/apps/wayline/"
  cp "$R/apps/wayline/backend/email-py-decision.txt" "$T/apps/wayline/backend/"
  cp "$R/.tools/bin/yq" "$T/.tools/bin/"
  touch "$T/LICENSE" "$T/COPYRIGHT.txt" "$T/NOTICE.md"
  printf '.build\n.tools\nstubs\ncalls.log\n' >"$T/.gitignore"
  git -C "$T" init -q; git -C "$T" -c user.name=x -c user.email=x@x add -A; git -C "$T" -c user.name=x -c user.email=x@x commit -qm x
  local c; c="$(git -C "$T" rev-parse HEAD)"
  for n in web admin space backend; do mkdir -p "$T/.build/wayline-dist/$n"; printf 'commit=%s\ndirty=no\n' "$c" >"$T/.build/wayline-dist/SOURCE.$n"; done
  cat >"$T/stubs/docker" <<STUB
#!/bin/bash
echo "docker \$*" | sed -E 's#$T#<tree>#g; s#wayline-staging-[0-9]+#wayline-staging-N#g; s#[0-9a-f]{40}#<commit>#g; s#SOURCE_DATE_EPOCH=[0-9]+#SOURCE_DATE_EPOCH=N#; s#/tmp[^ ]*/#<tmp>/#g; s#/private/tmp[^ ]*/#<tmp>/#g; s#/var/folders[^ ]*/#<tmp>/#g' >>"$T/calls.log"
if [[ "\$1 \$2" == "buildx build" ]]; then
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == --metadata-file ]]; then printf '{"containerimage.digest":"sha256:%064d"}\n' 1 >"\$2"; fi
    shift
  done
fi
exit 0
STUB
  printf '#!/bin/bash\nprintf 200\n' >"$T/stubs/curl"
  cat >"$T/stubs/python3" <<STUB
#!/bin/bash
echo "python3 \$*" >>"$T/calls.log"
exit 0
STUB
  chmod +x "$T/stubs/docker" "$T/stubs/curl" "$T/stubs/python3"
}
run() { # run <tree> [env...]
  local T="$1"; shift
  : >"$T/calls.log"
  ( cd "$T" && env -i HOME="$HOME" PATH="$T/stubs:/usr/bin:/bin" MIN_FREE_DISK_GIB=5 SKIP_NATIVE_BUILD=yes "$@" ./scripts/ci/build-images.sh localhost:5001/wayline ) >"$T/out.txt" 2>&1
  echo "exit $?"
}
mk "$S/build-old" HEAD
mk "$S/build-new" WORK
echo "old script, default: $(run "$S/build-old")"
echo "new script, default: $(run "$S/build-new")"
cp "$S/build-old/calls.log" "$S/calls-old.log"; cp "$S/build-new/calls.log" "$S/calls-new.log"
echo "--- calls, old against new, with the default platform (a difference here is what make images would do differently)"
diff "$S/calls-old.log" "$S/calls-new.log" | cut -c1-200
echo "--- new script with PLATFORM=linux/amd64: $(run "$S/build-new" PLATFORM=linux/amd64)"
grep -E 'buildx build|layer-check|flatten-config' "$S/build-new/calls.log" | sed -E 's/--build-arg [^ ]+ //g; s/(sha256:0{8})0+1/\1.../' | cut -c1-170
echo "--- new script with a wrong PLATFORM: $(run "$S/build-new" PLATFORM=linux/x86_64)"; tail -1 "$S/build-new/out.txt" | sed -E 's/\x1b\[[0-9;]*m//g'; wc -l <"$S/build-new/calls.log"
echo "--- PUSH=no: $(run "$S/build-new" PUSH=no PLATFORM=linux/amd64)"
grep -E 'buildx build' "$S/build-new/calls.log" | sed -E 's/--build-arg [^ ]+ //g' | cut -c1-170 | head -2; echo "walks with PUSH=no: $(grep -cE 'layer-check|flatten-config' "$S/build-new/calls.log" || true)"
