#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends docker.io curl perl python3 ca-certificates gawk >/dev/null 2>&1 || { echo "apt failed"; exit 9; }
python3 --version
cd /repo
echo "--- the cases on this Python, with no zstd installed"
python3 -B apps/wayline/checks/layer-check-cases.py | tail -1
echo "cases exit ${PIPESTATUS[0]}"
python3 -B scripts/ci/scan-images-report.py --selftest
apt-get install -y -qq --no-install-recommends zstd >/dev/null 2>&1
echo "--- the cases on this Python, with zstd"
python3 -B apps/wayline/checks/layer-check-cases.py | tail -1
echo "cases exit ${PIPESTATUS[0]}"
mv /usr/bin/docker /usr/bin/docker.real; cp /harness/docker-wrapper /usr/bin/docker; chmod +x /usr/bin/docker
printf 'web\tlocalhost:1/wayline-test/web\tsha256:%064d\n' 1 >/tmp/digests.tsv
echo "--- the script before this change, web only, five runs"
cd /old
for i in 1 2 3 4 5; do
  apps/wayline/checks/smoke-images.sh /tmp/digests.tsv >/tmp/old.txt 2>&1
  echo "run $i: exit $?, $(grep -c '^PASS' /tmp/old.txt) PASS, $(grep -c '^FAIL' /tmp/old.txt) FAIL, last line: $(tail -1 /tmp/old.txt | cut -c1-90)"
done
echo "--- the script after this change, web only, five runs"
cd /repo
for i in 1 2 3 4 5; do
  apps/wayline/checks/smoke-images.sh /tmp/digests.tsv >/tmp/new.txt 2>&1
  echo "run $i: exit $?, $(grep -c '^PASS' /tmp/new.txt) PASS, $(grep -c '^FAIL' /tmp/new.txt) FAIL, last line: $(tail -1 /tmp/new.txt | cut -c1-90)"
done
