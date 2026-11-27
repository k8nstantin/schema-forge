#!/usr/bin/env python3
"""Plugs engine_mysql into a fresh store holding the cortex, the five steps every plugin takes, and checks what the
database then holds: every table of engines/mysql/owner.toml made and a plug (cortex.plug_in refuses one that is not),
every table and column commented, every id a UUIDv7 or its cortex row's, history and the fence on every table, its
roles named after its namespace, its seeds declared (versions, flavors with their sources, kinds with their tables).

  python3 tools/mysql/load.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.plugin import plug_folder  # noqa: E402
from sf.schema import cortex_sql, script  # noqa: E402
from sf.store import Failed, Store  # noqa: E402


def check(store, card):
    bad, lines = [], []
    ns = card["namespace"]
    tables = store.value(f"SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class WHERE relnamespace = '{ns}'::regnamespace AND relkind = 'r'").split()
    lines.append(f"tables: {len(tables)} made, {len(card['tables'])} in owner.toml")
    if sorted(tables) != sorted(card["tables"]):
        bad.append(f"tables differ: missing {sorted(set(card['tables']) - set(tables))}, extra {sorted(set(tables) - set(card['tables']))}")
    nocomment = store.value(f"""SELECT coalesce(string_agg(c.relname || coalesce('.' || a.attname, ''), ' '), '')
        FROM pg_class c LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE c.relnamespace = '{ns}'::regnamespace AND c.relkind = 'r'
          AND (obj_description(c.oid, 'pg_class') IS NULL OR (a.attnum IS NOT NULL AND col_description(c.oid, a.attnum) IS NULL))""")
    cols = store.value(f"SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relnamespace = '{ns}'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped")
    lines.append(f"columns: {cols}" + (", every one commented" if not nocomment else ""))
    if nocomment:
        bad.append(f"without a comment: {nocomment}")
    wide = store.value(f"""SELECT coalesce(string_agg(c.relname || '.' || a.attname, ' '), '') FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        WHERE c.relnamespace = '{ns}'::regnamespace AND c.relkind = 'r' AND a.attname IN ('id', 'design') AND a.atttypid <> 'uuid'::regtype""")
    if wide:
        bad.append(f"ids not UUID: {wide}")
    logged = store.value(f"SELECT count(*) FROM pg_trigger WHERE tgname = 'log_row' AND tgrelid::regclass::text LIKE '{ns}.%'")
    fenced = store.value(f"SELECT count(*) FROM pg_class WHERE relnamespace = '{ns}'::regnamespace AND relkind = 'r' AND relrowsecurity")
    lines.append(f"plugged in: history on {logged} tables, the fence on {fenced}")
    if logged != str(len(tables)) or fenced != str(len(tables)):
        bad.append(f"plug-in incomplete: history on {logged}, fence on {fenced}, of {len(tables)}")
    roles = store.value(f"SELECT string_agg(rolname || ':' || rolcanlogin, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('{ns}_owner', '{ns}_service')")
    lines.append(f"roles: {roles}")
    if roles != f"{ns}_owner:false {ns}_service:true":
        bad.append(f"roles not named after the namespace: {roles}")
    owner = store.value(f"SELECT nspowner::regrole FROM pg_namespace WHERE nspname = '{ns}'")
    if owner != f"{ns}_owner":
        bad.append(f"{ns} is owned by {owner}")
    seeds = store.value(f"""SELECT (SELECT count(*) FROM cortex.engine_versions WHERE engine = '{card['id']}') || ' versions, '
        || (SELECT count(*) FROM cortex.engine_flavors WHERE engine = '{card['id']}') || ' flavors ('
        || (SELECT count(*) FROM cortex.engine_flavors WHERE engine = '{card['id']}' AND jsonb_array_length(sources) > 0) || ' with their sources), '
        || (SELECT count(*) FROM cortex.object_kinds WHERE engine = '{card['id']}') || ' kinds ('
        || (SELECT count(*) FROM cortex.object_kinds WHERE engine = '{card['id']}' AND details IS NOT NULL) || ' with their table)'""")
    lines.append(f"declared: {seeds}")
    return bad, lines


def main():
    with Store("sf-mysql-load") as store:
        try:
            store.sql(script(cortex_sql()))
            card = plug_folder(store, "engines/mysql")
        except Failed as e:
            print(f"FAIL  engine_mysql does not plug in: {e}")
            return 1
        bad, lines = check(store, card)
    for line in lines:
        print(f"  {line}")
    for b in bad:
        print(f"  FAIL  {b}")
    print(f"{'pass' if not bad else 'FAIL'}  engine_mysql load: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
