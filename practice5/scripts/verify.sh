#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?Expected package version}
docker run --rm --platform linux/amd64 --network devops-practice5 \
  --mount "type=bind,src=$PWD/keys,dst=/keys,readonly" \
  ubuntu:22.04 bash -euo pipefail -s -- "$version" <<'CONTAINER' | tee dist/apt-verification.txt
test "$(dpkg --print-architecture)" = amd64
if dpkg-query --status syspulse >/dev/null 2>&1; then
  echo 'The verification container already contains syspulse.' >&2
  exit 1
fi

install -d -m 755 /etc/apt/keyrings
install -m 644 /keys/syspulse-archive.asc /etc/apt/keyrings/syspulse.asc
printf 'Acquire::https::CAInfo "/keys/nexus-ca.crt";\n' >/etc/apt/apt.conf.d/99syspulse-ca
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/syspulse.asc] https://nexus.syspulse.test:18443/repository/syspulse/ stable main' >/etc/apt/sources.list.d/syspulse.list
apt_get() {
  apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/syspulse.list \
    -o Dir::Etc::sourceparts=- "$@"
}
apt_get -o APT::Update::Error-Mode=any update
apt-cache policy syspulse
apt_get install -y --no-install-recommends "syspulse=$1"
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' syspulse
test "$(dpkg-query -W -f='${Version} ${Architecture}' syspulse)" = "$1 amd64"
actual=$(syspulse --version)
printf '%s\n' "$actual"
test "$actual" = "syspulse $1"
snapshot=$(syspulse)
printf '%s\n' "$snapshot" | sed -n '1,11p'
printf '%s\n' "$snapshot" | grep -Eq '^uptime: [0-9]'
printf '%s\n' "$snapshot" | grep -Eq '^loadavg: [0-9]'
printf '%s\n' "$snapshot" | grep -Eq '^meminfo: MemTotal: +[0-9]'
CONTAINER
