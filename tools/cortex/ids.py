#!/usr/bin/env python3
"""Every id of the cortex is a UUIDv7 made with its row: no BIGINT, serial or identity column anywhere (read from the
catalog), every id column UUID with uuidv7() as its default and a version-7 check, and ids made one after another sort
in the order they were made.

  python3 tools/cortex/ids.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.fixture import in_turn, installed, new_design  # noqa: E402


def main():
    bad = []
    store = installed("sf-cortex-ids")
    try:
        wide = store.value("""SELECT coalesce(string_agg(c.relname || '.' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '), '')
            FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
            WHERE c.relnamespace = 'cortex'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
              AND (a.atttypid IN ('int8'::regtype, 'int2'::regtype) OR a.attidentity <> '' OR pg_get_expr((SELECT adbin FROM pg_attrdef d WHERE d.adrelid = c.oid AND d.adnum = a.attnum), c.oid) LIKE 'nextval%')""")
        print(f"  BIGINT, smallint, identity or serial columns: {wide or 'none'}")
        if wide:
            bad.append(f"not UUIDv7: {wide}")
        ids = store.value("""SELECT count(*) || ' ' || count(*) FILTER (WHERE a.atttypid = 'uuid'::regtype
                   AND pg_get_expr(d.adbin, c.oid) = 'uuidv7()'
                   AND EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c' AND pg_get_constraintdef(k.oid) LIKE '%uuid_extract_version(id) = 7%'))
            FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
            WHERE c.relnamespace = 'cortex'::regnamespace AND c.relkind = 'r' AND a.attname = 'id'
              AND c.relname NOT IN ('plugins', 'engines', 'engine_versions', 'engine_flavors', 'object_kinds')""").split()
        print(f"  id columns of designs' tables: {ids[0]}, UUID DEFAULT uuidv7() with a version-7 check: {ids[1]}")
        if ids[0] != ids[1]:
            bad.append(f"{int(ids[0]) - int(ids[1])} id columns are not UUIDv7 made with their row")
        design, branch = new_design(store, "ids", "mysql", "8.4", "mysql")
        body = "\n".join(f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{design}', 'n{i:03}', {i + 1});" for i in range(200))
        store.sql(in_turn(design, branch, body))
        rows = store.value(f"SELECT count(*) || ' ' || count(*) FILTER (WHERE uuid_extract_version(id) = 7) || ' ' || "
                           f"(array_agg(name ORDER BY id) = array_agg(name ORDER BY name)) FROM cortex.namespaces WHERE design = '{design}'").split()
        print(f"  200 rows made one after another: {rows[1]} of {rows[0]} version 7, in the order made: {rows[2]}")
        if rows != ["200", "200", "true"]:
            bad.append(f"ids made in order: {rows}")
        log = store.value(f"SELECT count(*) FROM cortex.row_changes WHERE design = '{design}' AND uuid_extract_version(id) = 7")
        print(f"  their log rows, version 7: {log}")
        if log != "200":
            bad.append(f"log rows version 7: {log} of 200")
    finally:
        store.__exit__(None, None, None)
    for b in bad:
        print(f"  FAIL  {b}")
    print(f"{'pass' if not bad else 'FAIL'}  cortex ids: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
