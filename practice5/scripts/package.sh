#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/^const Version = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' main.go)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
epoch=$(git log -1 --format=%ct -- main.go)
: "${epoch:?Commit main.go before packaging}"
deb="syspulse_${version}_amd64.deb"
export SOURCE_DATE_EPOCH="$epoch"

docker run --rm --platform linux/amd64 \
  --user "$(id -u):$(id -g)" --mount "type=bind,src=$PWD/dist,dst=/dist" \
  --env SOURCE_DATE_EPOCH ubuntu:22.04 bash -euo pipefail -s -- "$version" "$deb" <<'CONTAINER' | tee dist/package-info.txt
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
chmod 755 "$root"
install -d -m 755 "$root/DEBIAN" "$root/usr/bin"
install -m 755 /dist/syspulse "$root/usr/bin/syspulse"
cat >"$root/DEBIAN/control" <<CONTROL
Package: syspulse
Version: $1
Section: utils
Priority: optional
Architecture: amd64
Maintainer: DevOps Team <devops@example.com>
Description: Lightweight CLI tool for a system health snapshot
 Reads /proc and reports uptime, load average and memory info.
CONTROL
dpkg-deb --build --root-owner-group "$root" "/dist/$2"
dpkg -I "/dist/$2"
dpkg -c "/dist/$2"
CONTAINER

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'version=%s\ndeb=%s\n' "$version" "$deb" >>"$GITHUB_OUTPUT"
fi
(
  cd dist
  LC_ALL=C shasum -a 256 "$deb" >SHA256SUMS
)
