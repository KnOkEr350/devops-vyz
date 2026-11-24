#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${NEXUS_HOST:?Set the GitHub secret NEXUS_HOST}"
: "${NEXUS_USER:?Set the GitHub secret NEXUS_USER}"
: "${NEXUS_PASSWORD:?Set the GitHub secret NEXUS_PASSWORD}"
deb=${1:?Expected .deb filename}
repo="https://${NEXUS_HOST}:18443/repository/syspulse"

curl --silent --show-error --fail --connect-timeout 10 --max-time 180 \
  --cacert keys/nexus-ca.crt --user "$NEXUS_USER:$NEXUS_PASSWORD" \
  --header 'Content-Type: multipart/form-data' --data-binary "@dist/$deb" "$repo/" \
  --output /dev/null
printf 'Nexus accepted %s via HTTP POST.\n' "$deb"
curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
  --cacert keys/nexus-ca.crt --retry 5 --retry-all-errors \
  "$repo/dists/stable/InRelease" --output dist/InRelease
grep -q '^-----BEGIN PGP SIGNED MESSAGE-----' dist/InRelease
echo 'Nexus generated signed InRelease metadata.'
