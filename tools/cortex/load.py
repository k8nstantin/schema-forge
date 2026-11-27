#!/usr/bin/env python3
"""Loads the cortex into a fresh PostgreSQL 18 store and checks what the database holds: every table of
schema/cortex/owner.toml made, every table and column commented, every function there, the cortex plugged in.

  python3 tools/cortex/load.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.schema import cortex_sql, owner, script  # noqa: E402
from sf.store import Failed, Store  # noqa: E402


def check(store):
    """(findings, lines): what the loaded cortex lacks."""
    o = owner("schema/cortex")
    bad, lines = [], []
    tables = store.value("SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class WHERE relnamespace = 'cortex'::regnamespace AND relkind = 'r'").split()
    want = sorted(o["tables"])
    lines.append(f"tables: {len(tables)} made, {len(want)} in owner.toml")
    if sorted(tables) != want:
        bad.append(f"tables differ: missing {sorted(set(want) - set(tables))}, extra {sorted(set(tables) - set(want))}")
    nocomment = store.value("""SELECT coalesce(string_agg(c.relname || coalesce('.' || a.attname, ''), ' '), '')
        FROM pg_class c LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE c.relnamespace = 'cortex'::regnamespace AND c.relkind = 'r'
          AND (obj_description(c.oid, 'pg_class') IS NULL OR (a.attnum IS NOT NULL AND col_description(c.oid, a.attnum) IS NULL))""")
    cols = store.value("SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relnamespace = 'cortex'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped")
    lines.append(f"columns: {cols}, every one commented" if not nocomment else f"columns: {cols}")
    if nocomment:
        bad.append(f"without a comment: {nocomment}")
    fns = store.value("SELECT string_agg(proname, ' ' ORDER BY proname) FROM pg_proc WHERE pronamespace = 'cortex'::regnamespace").split()
    # every function file's main function is there (plug_in.sql brings its helpers with it)
    lines.append(f"functions: {' '.join(fns)}")
    for f in o["functions"]:
        if f not in fns:
            bad.append(f"function {f} missing")
    plugged = store.value("SELECT count(*) FROM pg_trigger WHERE tgname = 'log_row' AND tgrelid::regclass::text LIKE 'cortex.%'")
    fenced = store.value("SELECT count(*) FROM pg_class WHERE relnamespace = 'cortex'::regnamespace AND relrowsecurity")
    lines.append(f"plugged in: history on {plugged} tables, the fence on {fenced}")
    if plugged != "8" or fenced != "14":
        bad.append(f"plug-in incomplete: history on {plugged} of 8, fence on {fenced} of 14")
    return bad, lines


def main():
    with Store("sf-cortex-load") as store:
        try:
            store.sql(script(cortex_sql()))
        except Failed as e:
            print(f"FAIL  the cortex does not load: {e}")
            return 1
        bad, lines = check(store)
    for line in lines:
        print(f"  {line}")
    for b in bad:
        print(f"  FAIL  {b}")
    print(f"{'pass' if not bad else 'FAIL'}  cortex load: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
