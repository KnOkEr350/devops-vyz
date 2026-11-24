#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -e .env ]]; then
  echo '.env already exists.'
  exit 0
fi
umask 077
{
  printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)"
  printf 'DJANGO_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
} >.env
echo 'Created .env.'
