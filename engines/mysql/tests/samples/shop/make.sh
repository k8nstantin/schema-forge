#!/bin/sh
# Makes the MySQL samples: loads source.sql (and, from 9.7, source97.sql) into a throwaway MySQL in Docker for each
# version and dumps the shop with that server's own mysqldump, schema only and whole, with routines, triggers and
# events. Run from anywhere; writes next to itself.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dump() {
    version=$1
    name=schema-forge-mysql-samples-$(echo "$version" | tr . -)
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" -e MYSQL_ROOT_PASSWORD=samples "mysql:$version" >/dev/null
    trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
    until docker exec "$name" mysql -uroot -psamples -e 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
    docker exec -i "$name" mysql -uroot -psamples < "$here/source.sql"
    case "$version" in 8.*) ;; *) docker exec -i "$name" mysql -uroot -psamples < "$here/source97.sql" ;; esac
    flags="--routines --triggers --events --databases shop"
    docker exec "$name" mysqldump -uroot -psamples --no-data $flags > "$here/schema$version.sql" 2>/dev/null
    docker exec "$name" mysqldump -uroot -psamples $flags > "$here/full$version.sql" 2>/dev/null
    echo "$version: $(docker exec "$name" mysqldump --version)"
    docker rm -f "$name" >/dev/null
}
for v in 8.0 8.4 9.7 26.10; do dump "$v"; done
