#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

base="http://$(docker compose port web 8000)"
before_db=$(docker compose ps -q db)
label="docker-persistence-$(date +%s)-$(openssl rand -hex 4)"
cookies=$(mktemp)
trap 'rm -f "$cookies"' EXIT
curl -fsS "$base/health/" | python3 -c 'import json, sys; assert json.load(sys.stdin) == {"status": "ok", "database": "postgresql"}'
curl -fsS -c "$cookies" "$base/" >/dev/null
csrf=$(awk '$6 == "csrftoken" {print $7}' "$cookies")
test -n "$csrf"
test "$(curl -fsS -o /dev/null -w '%{http_code}' -b "$cookies" --data-urlencode "csrfmiddlewaretoken=$csrf" --data-urlencode "text=$label" "$base/")" = 302
curl -fsS "$base/" | awk -v marker="$label" 'index($0, marker) { found = 1 } END { exit !found }'
echo "Note visible before recreation ($label)."

docker compose up -d --wait --force-recreate --wait-timeout 120
test "$(docker compose ps -q db)" != "$before_db"
base="http://$(docker compose port web 8000)"
curl -fsS "$base/" | awk -v marker="$label" 'index($0, marker) { found = 1 } END { exit !found }'
test "$(docker compose exec -T web id -u)" != 0
docker compose ps
echo 'PASS: new PostgreSQL container reads the same data from its named volume.'
