#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends docker.io curl perl python3 ca-certificates gawk >/dev/null 2>&1 || { echo "apt failed"; exit 9; }
docker --version; bash --version | head -1; head -1 /etc/os-release; awk --version | head -1; curl --version | head -1; which shasum
mv /usr/bin/docker /usr/bin/docker.real; cp /harness/docker-wrapper /usr/bin/docker; chmod +x /usr/bin/docker
printf 'web\tlocalhost:1/wayline-test/web\tsha256:%064d\nadmin\tlocalhost:1/wayline-test/admin\tsha256:%064d\n' 1 2 >/tmp/digests.tsv
cd /repo
export WAYLINE_EXPECT_REF=0123456789abcdef0123456789abcdef01234567
time apps/wayline/checks/smoke-images.sh /tmp/digests.tsv
echo "smoke exit $?"
