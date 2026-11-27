#!/usr/bin/env python3
"""The model every engine shares, proven on real schemas: each sample is loaded into its own server in a container,
read from that server's catalog, stored in the cortex as one import turn, read back from the cortex and compared
field by field: every namespace, object, column, key and index must come back as the server gave it.

  the old SchemaForge schema   PostgreSQL 18, read from git history (36a953b:schema/dump/schema_forge.sql), never copied
  the old MySQL schema         MySQL 8.0, the private file ~/schema-forge-lab-private/mysql-baseline.sql where it exists
                               (it holds private names: it is never committed, and only counts are printed)

  python3 tools/cortex/samples.py
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.catalog import PRIVATE, count, cortex_model, differences, drop_outside_keys, mysql_model, postgresql_model, store_model  # noqa: E402
from sf.fixture import installed, new_design  # noqa: E402
from sf.schema import ROOT  # noqa: E402
from sf.servers import MySQL, PostgreSQL  # noqa: E402

OLD_SCHEMA_FORGE = "36a953b:schema/dump/schema_forge.sql"


def prove(store, label, engine, version, flavor, objs, bad):
    objs = drop_outside_keys(objs)
    d, b = new_design(store, label.replace(" ", "_"), engine, version, flavor)
    rows = store_model(store, d, b, engine, objs)
    back = cortex_model(store, d)
    diff = differences(objs, back)
    n = count(objs)
    print(f"  {label}: {n[0]} objects, {n[1]} columns, {n[2]} keys, {n[3]} indexes; {rows} rows stored in one turn")
    if diff:
        bad.append(f"{label}: read back differs")
        for line in diff:
            print(f"    differs  {line}")
    else:
        print(f"  pass  {label}: read back from the cortex identical, field by field")


def main():
    bad = []
    store = installed("sf-cortex-samples")
    try:
        old = subprocess.run(["git", "show", OLD_SCHEMA_FORGE], cwd=ROOT, capture_output=True, text=True)
        if old.returncode:
            bad.append(f"the old SchemaForge schema is not in this checkout's history ({OLD_SCHEMA_FORGE}): fetch the full history")
        else:
            with PostgreSQL() as pg:
                # the old schema's own roles, as its dump names them: a sample, not ours
                pg.sql("CREATE ROLE sf_owner NOLOGIN; CREATE ROLE sf_service LOGIN; CREATE ROLE sf_agent LOGIN; CREATE ROLE sf_reader LOGIN; CREATE DATABASE schema_forge OWNER sf_owner;")
                pg.sql(old.stdout, db="schema_forge")
                prove(store, "the old SchemaForge schema", "postgresql", "18", "postgresql", postgresql_model(pg, "schema_forge"), bad)
        private = os.path.join(PRIVATE, "mysql-baseline.sql")
        if os.path.exists(private):
            # the schema was written for servers running with InnoDB's strict mode off: its sample server does too
            with MySQL("mysql:8.0", options=["--innodb-strict-mode=OFF"]) as my:
                my.load(private)
                prove(store, "the old MySQL schema", "mysql", "8.0", "mysql", mysql_model(my), bad)
        else:
            print("  note  the old MySQL schema is private and not on this machine: not run here")
    finally:
        store.__exit__(None, None, None)
    print(f"{'pass' if not bad else 'FAIL'}  cortex samples: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
