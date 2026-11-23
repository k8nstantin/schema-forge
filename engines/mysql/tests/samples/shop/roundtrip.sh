#!/bin/sh
# Proves the canonical samples load: each shop<version>.sql, as this engine writes it, is loaded into a throwaway
# MySQL of that version in Docker and dumped again with that server's own mysqldump, into roundtrip<version>.sql. The
# tests read each one and compare it with the dump of the original shop (schema<version>.sql): the same schema.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
roundtrip() {
    version=$1
    name=schema-forge-mysql-roundtrip-$(echo "$version" | tr . -)
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" -e MYSQL_ROOT_PASSWORD=samples "mysql:$version" >/dev/null
    trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
    until docker exec "$name" mysql -uroot -psamples -e 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
    docker exec -i "$name" mysql -uroot -psamples < "$here/shop$version.sql"
    docker exec "$name" mysqldump -uroot -psamples --no-data --routines --triggers --events --databases shop \
        > "$here/roundtrip$version.sql" 2>/dev/null
    echo "$version: loaded and dumped"
    docker rm -f "$name" >/dev/null
}
for v in 8.0 8.4 9.7 26.10; do roundtrip "$v"; done
