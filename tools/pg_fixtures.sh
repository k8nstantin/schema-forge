#!/bin/sh
# Builds a throwaway PostgreSQL from the fixture source and writes its real pg_dump output.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dir="$here/crates/dialects/tests/fixtures/postgres"
name=schema-forge-pg-fixtures
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e POSTGRES_PASSWORD=fixtures -e POSTGRES_DB=shop postgres:17-alpine >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
until docker exec "$name" pg_isready -U postgres -d shop >/dev/null 2>&1; do sleep 1; done
sleep 2
docker exec -i "$name" psql -q -v ON_ERROR_STOP=1 -U postgres -d shop < "$dir/source.sql"
docker exec "$name" pg_dump -U postgres --schema-only shop > "$dir/schema.sql"
docker exec "$name" pg_dump -U postgres shop > "$dir/full.sql"
docker exec "$name" pg_dump --version
