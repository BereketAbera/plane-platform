Local checks for the move of the Wayline images to linux/amd64, run 2026-11-06/07 UTC on the owner's arm64 Mac, Docker Desktop 29.6.1 with Rosetta.
No image was built, nothing was pushed, and GHCR was not read or written. Harnesses are in harness/, and made-up images were used wherever an image was needed.

01      layer-check-cases.py, in process and through a real distribution registry on loopback
02      scan-images-report.py --selftest
03      trivy 0.76.1 asked for each platform on hand-made plain manifests: it exits 0 and reads what the manifest is
04      scan-images.sh with real trivy on those, in a copy of the scripts
05      smoke-images.sh's platform check, with real docker pulls of those
06      copy-to-local-registry.sh with stub docker and gh: what it logs in with and prints
07      copy-to-local-registry.sh with real buildx on this arm64 Mac: plain amd64 manifests between two throwaway registries, the destination prefix changed by sed
08      build-images.sh with stubs: what it would run, old script against new
09      why smoke-images.sh changed: printf into head -1 and grep -vq under pipefail, on Linux bash, in a container
10      negative controls on scratch copies
11      the published scan of 2026-11-05 through the new report
12      smoke-images.sh, final, web and admin only, under Ubuntu 24.04 userland, against the real nginx base with the last local build's contexts copied in by docker cp. arm64, not amd64. harness/docker-wrapper says how
13      layer-check-cases.py and the report's self test on Python 3.12.3, with and without a zstd binary, and the smoke's web part five times
14      the same web part with the script as it was before this work: exit 141 on all eight runs, with no FAIL line
15-19   read-only preflights of the amd64 children of the pinned bases: the layer walk, CRITICAL findings with a fix against arm64, and the RUN steps of Dockerfile.space and Dockerfile.backend in throwaway containers under Rosetta

Not covered here, and only a runner can say: a real linux/amd64 build, the walks and the scan on built amd64 images, and the smoke on them natively.
