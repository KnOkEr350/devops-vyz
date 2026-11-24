#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

state="${MM_STATE_DIR:-$HOME/.local/share/devops-practice4-mattermost}"
run_key="${GITHUB_RUN_ID:-local}_${GITHUB_RUN_ATTEMPT:-1}"
fixture="$state/legacy-fixture.json"
flag="$state/.migration_completed"
run_dir="$state/runs/$run_key"
backup="$state/backups/mattermost_mysql_$run_key.sql"
network=devops-practice4-mattermost_mattermost
pgloader_image=mattermost/mattermost-pgloader:latest@sha256:6d513290a8e38c663b0e411c03098a74796c18b46dce6b64a4f538c68f20e41f

legacy=(docker compose -f legacy/docker-compose.yml)
prod=(docker compose -f docker-compose.prod.yml)
if [[ -n "${MM_ENV_FILE:-}" ]]; then
  set -a
  source "$MM_ENV_FILE"
  set +a
fi

mkdir -p "$run_dir" "$state/backups" evidence
[[ -s "$fixture" ]] || { echo 'Legacy fixture is missing on this runner.' >&2; exit 1; }
for variable in DB_MYSQL_ROOT_PASSWORD DB_MYSQL_PASSWORD DB_POSTGRES_PASSWORD MM_DEMO_PASSWORD; do
  [[ "${!variable:-}" =~ ^[[:xdigit:]]{48}$ ]] || {
    echo "$variable must be supplied as 48 hexadecimal characters." >&2
    exit 1
  }
done

sha256() { LC_ALL=C shasum -a 256 "$1" | awk '{print $1}'; }

pg_sql() {
  local database=$1
  shift
  "${prod[@]}" exec -T db-postgres psql -v ON_ERROR_STOP=1 -U mmuser -d "$database" "$@"
}

mysql_sql() {
  "${legacy[@]}" exec -T db-mysql sh -c \
    'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql --batch --skip-column-names -u "$MYSQL_USER" "$MYSQL_DATABASE"'
}

wait_http() {
  for _ in $(seq 1 75); do
    if curl -fsS --max-time 4 http://127.0.0.1:8065/api/v4/system/ping >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  echo 'Mattermost API did not become ready.' >&2
  return 1
}

mysql_counts() {
  mysql_sql <<'SQL'
SELECT 'channels', count(*) FROM Channels UNION ALL
SELECT 'fileinfo', count(*) FROM FileInfo UNION ALL
SELECT 'posts', count(*) FROM Posts UNION ALL
SELECT 'teams', count(*) FROM Teams UNION ALL
SELECT 'users', count(*) FROM Users ORDER BY 1;
SQL
}

postgres_counts() {
  local database=$1 schema=$2
  pg_sql "$database" -At -F $'\t' <<SQL
SELECT 'channels', count(*) FROM $schema.channels UNION ALL
SELECT 'fileinfo', count(*) FROM $schema.fileinfo UNION ALL
SELECT 'posts', count(*) FROM $schema.posts UNION ALL
SELECT 'teams', count(*) FROM $schema.teams UNION ALL
SELECT 'users', count(*) FROM $schema.users ORDER BY 1;
SQL
}

run_pgloader() {
  local load_file=$1 log_file="$run_dir/$1.log"
  if ! docker run --rm -i --platform linux/amd64 --network "$network" "$pgloader_image" \
      sh -ec 'umask 077; cat > /tmp/mattermost.load; exec pgloader --on-error-stop /tmp/mattermost.load' \
      <"$run_dir/$load_file" >"$log_file" 2>&1; then
    echo "pgloader failed. Private diagnostic log: $log_file" >&2
    return 1
  fi
  if grep -Eq ' (ERROR|FATAL) ' "$log_file"; then
    echo "pgloader reported data errors. Private diagnostic log: $log_file" >&2
    return 1
  fi
}

prepare_schema() {
  local version=$1
  if ! MM_IMAGE_TAG="$version" "${prod[@]}" run --rm --no-deps -T \
    --entrypoint /mattermost/bin/mattermost mattermost db migrate \
    >"$run_dir/schema-$version.log" 2>&1; then
    echo "Mattermost $version schema migration failed. Private diagnostic log: $run_dir/schema-$version.log" >&2
    return 1
  fi
}

check() {
  if [[ -f "$flag" ]]; then
    echo 'Migration flag present. Backup and pgloader will be skipped.'
    printf 'already_migrated=true\n'
  else
    echo 'No migration flag. Backup and pgloader are required.'
    printf 'already_migrated=false\n'
  fi
}

backup_mysql() {
  [[ ! -e "$flag" ]] || { echo 'A completed migration prevents another backup.' >&2; return 1; }
  "${legacy[@]}" up -d --wait --wait-timeout 160
  wait_http
  python3 scripts/demo.py verify "$fixture"
  "${legacy[@]}" stop mattermost
  "${legacy[@]}" exec -T db-mysql sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF -u root "$MYSQL_DATABASE"' \
    >"$backup.tmp" 2>"$run_dir/mysqldump.log"
  grep -q '^-- Dump completed' "$backup.tmp"
  mv "$backup.tmp" "$backup"
  mysql_counts >"$run_dir/mysql-counts.tsv"
  printf 'MySQL backup %s (%s bytes) SHA-256 %s\n' \
    "$(basename "$backup")" "$(wc -c <"$backup" | tr -d ' ')" "$(sha256 "$backup")"
}

migrate_db() {
  [[ ! -e "$flag" && -s "$backup" ]] || { echo 'Migration requires this run’s backup and no completion flag.' >&2; return 1; }
  "${prod[@]}" up -d --wait --wait-timeout 160 db-postgres
  pg_sql postgres -q <<'SQL'
SELECT 'CREATE DATABASE mattermost_landing OWNER mmuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mattermost_landing') \gexec
SQL
  if [[ "$(pg_sql mattermost_landing -Atc "SELECT to_regclass('mattermost.posts') IS NOT NULL")" == t ]]; then
    echo 'A previous landing table exists. pgloader include drop will replace it.'
  fi

  cat >"$run_dir/landing.load" <<LOAD
LOAD DATABASE
  FROM mysql://mmuser:${DB_MYSQL_PASSWORD}@db-mysql:3306/mattermost
  INTO pgsql://mmuser:${DB_POSTGRES_PASSWORD}@db-postgres:5432/mattermost_landing

 WITH include drop, create tables, create no indexes, no foreign keys,
      downcase identifiers, workers = 2, concurrency = 1

 CAST type tinyint when (<= precision 4) to boolean using tinyint-to-boolean;
LOAD
  run_pgloader landing.load
  postgres_counts mattermost_landing mattermost >"$run_dir/landing-counts.tsv"
  diff -u "$run_dir/mysql-counts.tsv" "$run_dir/landing-counts.tsv"
  echo 'pgloader include drop completed in the landing database. All five source row counts match.'

  # This reset is limited to the uncommitted destination of this isolated lab.
  # Mattermost creates its native PostgreSQL types, constraints and indexes.
  pg_sql postgres -q >"$run_dir/reset-target.log" 2>&1 <<'SQL'
DROP DATABASE IF EXISTS mattermost WITH (FORCE);
CREATE DATABASE mattermost OWNER mmuser;
SQL
  prepare_schema 9.5.2
  pg_sql mattermost -q -c 'ALTER SCHEMA public RENAME TO mattermost; TRUNCATE mattermost.systems;' \
    >"$run_dir/prepare-load.log" 2>&1
  cat >"$run_dir/native.load" <<LOAD
LOAD DATABASE
  FROM mysql://mmuser:${DB_MYSQL_PASSWORD}@db-mysql:3306/mattermost
  INTO pgsql://mmuser:${DB_POSTGRES_PASSWORD}@db-postgres:5432/mattermost

 WITH data only, create no tables, create no indexes, preserve index names,
      workers = 2, concurrency = 1

 CAST column Channels.Type to "channel_type" drop typemod,
      column Teams.Type to "team_type" drop typemod,
      column UploadSessions.Type to "upload_session_type" drop typemod,
      type int when (= precision 11) to integer drop typemod,
      type bigint when (= precision 20) to bigint drop typemod,
      type text to varchar drop typemod using remove-null-characters,
      type tinyint when (<= precision 4) to boolean using tinyint-to-boolean,
      type json to jsonb drop typemod using remove-null-characters

 EXCLUDING TABLE NAMES MATCHING 'schema_migrations', 'db_migrations', 'db_lock',
    'configurations', 'configurationfiles', 'db_config_migrations';
LOAD
  run_pgloader native.load
  pg_sql mattermost -q -c 'ALTER SCHEMA mattermost RENAME TO public;'
  postgres_counts mattermost public >"$run_dir/native-counts.tsv"
  diff -u "$run_dir/mysql-counts.tsv" "$run_dir/native-counts.tsv"
  printf 'Counts copied into the native PostgreSQL schema:\n'
  cat "$run_dir/native-counts.tsv"

  for version in 10.11.20 11.7.8 12.0.1; do
    prepare_schema "$version"
    printf 'Mattermost database schema upgraded with %s.\n' "$version"
  done
}

deploy() {
  if [[ ! -f "$flag" && ! -s "$backup" ]]; then
    echo 'Deployment requires the completion flag or this run’s backup.' >&2
    return 1
  fi
  # Keep the source container until verification has passed.
  "${prod[@]}" up -d --wait --wait-timeout 190
  wait_http
  python3 scripts/demo.py verify "$fixture"
  if [[ ! -f "$flag" ]]; then
    printf '%s\t%s\n' "$backup" "$(sha256 "$backup")" >"$flag.tmp"
    mv "$flag.tmp" "$flag"
    echo 'Wrote the persistent migration flag after checking data and HTTP.'
  fi
  "${prod[@]}" up -d --wait --wait-timeout 190 --remove-orphans
  wait_http

  local old_backup old_hash app db volume
  IFS=$'\t' read -r old_backup old_hash <"$flag"
  [[ -s "$old_backup" && "$(sha256 "$old_backup")" == "$old_hash" ]]
  app=$("${prod[@]}" ps -q mattermost)
  db=$("${prod[@]}" ps -q db-postgres)
  volume=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/mattermost/data"}}{{.Name}}{{end}}{{end}}' "$app")
  [[ "$volume" == devops-practice4-mattermost_mattermost_data ]]
  [[ "$(docker inspect -f '{{.Config.Image}}' "$app")" == mattermost/mattermost-team-edition:12.0.1 ]]
  [[ "$(docker network inspect -f '{{.Driver}}' "$network")" == bridge ]]
  [[ -z "$(docker ps -aq --filter 'label=com.docker.compose.project=devops-practice4-mattermost' --filter 'label=com.docker.compose.service=db-mysql')" ]]
  docker volume inspect devops-practice4-mattermost_mysql_data >/dev/null
  printf 'Mattermost 12.0.1 data volume %s\n' "$volume"
  printf 'PostgreSQL version %s\n' "$(pg_sql mattermost -Atc 'SHOW server_version')"
  printf 'MySQL container removed. Original MySQL volume and backup %s retained.\n' "$(basename "$old_backup")"
  printf 'Original backup SHA-256 %s\n' "$old_hash"
  curl -fsS http://127.0.0.1:8065/api/v4/system/ping
  printf '\n'
  docker inspect -f '{{.Config.Image}} {{.State.Status}}' "$db"
  "${prod[@]}" ps
  cp "$fixture" evidence/legacy-fixture.json
}

restore_legacy() {
  if [[ -e "$flag" ]]; then
    echo 'The verified PostgreSQL deployment is active.'
    return
  fi
  echo 'Restarting the source stack after the incomplete migration.'
  "${legacy[@]}" up -d --wait --wait-timeout 160
  wait_http
}

case "${1:-}" in
  check) check ;;
  backup) backup_mysql ;;
  migrate) migrate_db ;;
  deploy) deploy ;;
  restore-legacy) restore_legacy ;;
  *) echo 'Usage: migration.sh {check|backup|migrate|deploy|restore-legacy}' >&2; exit 2 ;;
esac
