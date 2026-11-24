#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p dist
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -buildvcs=false -o dist/syspulse .
file dist/syspulse | tee dist/binary-info.txt
grep -q 'x86-64.*statically linked' dist/binary-info.txt
