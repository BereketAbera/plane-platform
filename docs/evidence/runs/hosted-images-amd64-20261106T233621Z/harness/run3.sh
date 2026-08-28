#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends docker.io curl perl ca-certificates gawk >/dev/null 2>&1 || { echo "apt failed"; exit 9; }
mv /usr/bin/docker /usr/bin/docker.real; cp /harness/docker-wrapper /usr/bin/docker; chmod +x /usr/bin/docker
printf 'web\tlocalhost:1/wayline-test/web\tsha256:%064d\n' 1 >/tmp/digests.tsv
echo "--- the script before this change, web only, eight runs"
cd /old
for i in 1 2 3 4 5 6 7 8; do
  apps/wayline/checks/smoke-images.sh /tmp/digests.tsv >/tmp/old.txt 2>&1
  echo "run $i: exit $?, $(grep -c '^PASS' /tmp/old.txt) PASS, $(grep -c '^FAIL' /tmp/old.txt) FAIL, last line: $(tail -1 /tmp/old.txt | cut -c1-90)"
done
