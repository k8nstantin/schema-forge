"""The installed schema put to work through its service accounts, on this machine's PostgreSQL (127.0.0.1:5432,
schema_forge), as the app and the coding agent will use it.

  sf_service, the app: captures designs (loads them, as the store will), and asks what the app will ask, timed.
  sf_agent, the coding agent: makes the edits it may make, and tries what it must not.
  Gaps: rows well formed but wrong, which the schema should refuse; each tried inside a transaction rolled back.

The designs it loads stay, as data (named service-test-*); --clean deletes them. Passwords come from the accounts file.

  python3 lab/service_accounts_test.py [--clean] [--private ~/schema-forge-lab-private] [--port 5432] [--accounts-file FILE]
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import pg_store as P  # noqa: E402
import repo_pg_store as RP  # noqa: E402
import repo_store as R  # noqa: E402

PSQL = "/opt/homebrew/opt/postgresql@18/bin/psql"
PRIVATE = os.path.expanduser(sys.argv[sys.argv.index("--private") + 1] if "--private" in sys.argv else "~/schema-forge-lab-private")
PORT = sys.argv[sys.argv.index("--port") + 1] if "--port" in sys.argv else "5432"
ACCOUNTS = os.path.expanduser(sys.argv[sys.argv.index("--accounts-file") + 1]) if "--accounts-file" in sys.argv else os.path.join(PRIVATE, "local-accounts.env")
SECRET = {}
for line in open(ACCOUNTS):
    m = re.match(r"^\s*(?:export\s+)?([A-Z_]+)=(.*)$", line.strip())
    if m:
        SECRET[m.group(1)] = m.group(2).strip("'\"")


def sql(role, text, rollback=False):
    """psql as a service account; (ok, out, first error)."""
    body = ("BEGIN;\n" + text + "\nROLLBACK;\n") if rollback else text
    r = subprocess.run([PSQL, "-h", "127.0.0.1", "-p", PORT, "-U", role, "-d", "schema_forge", "-At", "-v", "ON_ERROR_STOP=1", "-q"], input=body,
                       capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=SECRET[f"{role.upper()}_PASSWORD"]))
    return r.returncode == 0, r.stdout.strip(), next((x for x in r.stderr.splitlines() if x.startswith("ERROR")), r.stderr.strip()[:200])


def timed(role, text):
    t = time.time()
    ok, out, err = sql(role, text)
    return (time.time() - t) * 1000, ok, out, err


def load(rows):
    ok, out, err = sql("sf_service", "BEGIN;\n" + "".join(R.copy_sql(k, rows[k]) for k in ORDER if rows.get(k)) + "COMMIT;\n")
    if not ok:
        raise SystemExit(f"loading as sf_service: {err}")


ORDER = list(dict.fromkeys(R.ORDER + RP.ORDER))


def main():
    if "--clean" in sys.argv:
        ok, out, err = sql("sf_service", "DELETE FROM cortex.designs WHERE name LIKE 'service-test-%' RETURNING name;")
        print(f"deleted: {out.replace(chr(10), ', ') or 'nothing'}" if ok else f"FAIL {err}")
        return 0
    sql("sf_service", "DELETE FROM cortex.designs WHERE name LIKE 'service-test-%';")
    print("== sf_service, the app: captures")
    designs = {}
    for name, path, engine in (("service-test-production-mysql-8.4", os.path.join(PRIVATE, "out", "mysql-8.4.json"), "mysql"),
                               ("service-test-mysql-9.7", os.path.join(HERE, "out", "mysql-9.7.json"), "mysql"),
                               ("service-test-postgresql-18", os.path.join(HERE, "out", "postgresql-18.json"), "postgresql")):
        snap = json.load(open(path))
        if engine == "mysql":
            rows, _ = R.rows_of(snap, name)
            rows = R.OL.to_options(rows)
        else:
            rows, _ = RP.to_locked(P.rows_of(snap), snap["version"], snap["parts"])
            rows["cortex.designs"][0]["name"] = name
            rows = RP.jsonish(R.OL.to_options(rows))
        rows = {k: v for k, v in rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")}
        t = time.time()
        load(rows)
        designs[name] = rows["cortex.designs"][0]["id"]
        print(f"  {name}: {sum(len(v) for v in rows.values())} rows loaded in {(time.time() - t) * 1000:,.0f} ms")

    print("== sf_service, the app: what it asks, timed (ms)")
    prod, pg = designs["service-test-production-mysql-8.4"], designs["service-test-postgresql-18"]
    tab = sql("sf_service", f"SELECT o.id FROM cortex.objects o WHERE o.design = '{prod}' AND o.kind = 'table' "
                            f"ORDER BY (SELECT count(*) FROM cortex.columns c WHERE c.object = o.id) DESC LIMIT 1")[1]
    asks = [
        ("open a design: every object, column, index and constraint", f"""SELECT count(*) FROM (
            SELECT id FROM cortex.objects WHERE design = '{prod}' UNION ALL SELECT id FROM cortex.columns WHERE design = '{prod}'
            UNION ALL SELECT id FROM cortex.indexes WHERE design = '{prod}' UNION ALL SELECT id FROM cortex.index_parts WHERE design = '{prod}'
            UNION ALL SELECT id FROM cortex.constraints WHERE design = '{prod}' UNION ALL SELECT id FROM cortex.constraint_columns WHERE design = '{prod}') x"""),
        ("the canvas: every table with its column count", f"""SELECT count(*) FROM (SELECT o.id, count(c.id) FROM cortex.objects o
            LEFT JOIN cortex.columns c ON c.design = o.design AND c.object = o.id WHERE o.design = '{prod}' AND o.kind = 'table' GROUP BY o.id) x"""),
        ("one table's whole definition", f"""SELECT json_build_object('columns', (SELECT json_agg(c ORDER BY c.position) FROM cortex.columns c WHERE c.design = '{prod}' AND c.object = '{tab}'),
            'indexes', (SELECT json_agg(json_build_object('i', i, 'parts', (SELECT json_agg(p ORDER BY p.position) FROM cortex.index_parts p WHERE p.design = i.design AND p.index = i.id)))
                        FROM cortex.indexes i WHERE i.design = '{prod}' AND i.object = '{tab}'),
            'constraints', (SELECT json_agg(k) FROM cortex.constraints k WHERE k.design = '{prod}' AND k.object = '{tab}'))::text IS NOT NULL"""),
        ("every foreign key of the design, as the diagram draws it", f"""SELECT count(*) FROM cortex.constraints k JOIN cortex.objects a ON a.id = k.object
            LEFT JOIN cortex.objects b ON b.id = k.to_object WHERE k.design = '{prod}' AND k.kind = 'foreign'"""),
        ("search: objects and columns by name", f"""SELECT count(*) FROM (SELECT name FROM cortex.objects WHERE design = '{prod}' AND name ILIKE '%client%'
            UNION ALL SELECT name FROM cortex.columns WHERE design = '{prod}' AND name ILIKE '%client%') x"""),
        ("what a table's routines and views use it", f"""SELECT count(*) FROM cortex.dependencies d JOIN cortex.objects o ON o.id = d.object WHERE d.design = '{prod}' AND d.uses = '{tab}'"""),
        ("who may read a PostgreSQL table", f"""SELECT count(*) FROM cortex.privileges g LEFT JOIN cortex.objects r ON r.id = g.grantee
            WHERE g.design = '{pg}' AND g.privilege = 'SELECT' AND g.object IS NOT NULL"""),
        ("the design's tables by engine option (MyISAM)", f"""SELECT count(*) FROM cortex.objects WHERE design = '{prod}' AND options ->> 'engine' = 'MyISAM'"""),
        ("can the production design move to Cloud SQL?", f"""SELECT count(*) FROM cortex.misfits('{prod}', '8.4', 'mysql/cloudsql')"""),
        ("can it upgrade to 9.7?", f"""SELECT count(*) FROM cortex.misfits('{prod}', '9.7')"""),
    ]
    for what, q in asks:
        ms, ok, out, err = timed("sf_service", q)
        print(f"  {'pass' if ok else 'FAIL'}  {ms:7,.0f}  {what}: {out if ok else err}")

    print("== sf_agent, the coding agent")
    col = sql("sf_agent", f"SELECT id FROM cortex.columns WHERE design = '{prod}' AND object = '{tab}' ORDER BY position LIMIT 1")[1]
    agent = [
        ("renames a column", f"UPDATE cortex.columns SET name = name || '_x' WHERE id = '{col}';", True),
        ("adds an index", f"INSERT INTO cortex.indexes (design, object, position, name, \"unique\", method) VALUES ('{prod}', '{tab}', 999, 'ix_agent', false, 'BTREE');", True),
        ("changes a table's row format", f"""UPDATE cortex.objects SET options = options || '{{"row_format": "COMPRESSED"}}' WHERE id = '{tab}';""", True),
        ("gives a table an option no engine declares", f"""UPDATE cortex.objects SET options = options || '{{"colour": "red"}}' WHERE id = '{tab}';""", False),
        ("changes what an engine declares", "DELETE FROM cortex.flavor_limits;", False),
        ("makes a design", "INSERT INTO cortex.designs (name, engine, engine_version) VALUES ('agent-made', 'mysql', '8.4');", False),
        ("deletes a design", f"DELETE FROM cortex.designs WHERE id = '{prod}';", False),
        ("creates a table", "CREATE TABLE cortex.agent_table (id int);", False),
    ]
    for what, q, want in agent:
        ok, out, err = sql("sf_agent", q, rollback=True)
        print(f"  {'pass' if ok == want else 'FAIL'}  {what}: {'allowed' if ok else 'refused (' + err[7:110] + ')'}")

    print("== gaps: well formed but wrong; each should be refused")
    obj = lambda kind, d=prod: sql("sf_service", f"SELECT id FROM cortex.objects WHERE design = '{d}' AND kind = '{kind}' LIMIT 1")[1]  # noqa: E731
    view, routine, account = obj("view"), obj("procedure"), obj("account", designs["service-test-mysql-9.7"])
    d97 = designs["service-test-mysql-9.7"]
    gaps = [
        ("a grant whose grantee is a table, not an account", f"INSERT INTO cortex.privileges (design, grantee, privilege, position) VALUES ('{prod}', '{tab}', 'SELECT', 999);"),
        ("an owner (DEFINER) that is a view", f"UPDATE cortex.objects SET owner = '{view}', owner_name = NULL WHERE id = '{routine}';"),
        ("a role membership between two tables", f"INSERT INTO cortex.memberships (design, role, member, position) VALUES ('{prod}', '{tab}', '{view}', 999);"),
        ("a routine body on a table", f"INSERT INTO cortex.routines (id, design, body) VALUES ('{tab}', '{prod}', 'SELECT 1');"),
        ("a view's query on a procedure", f"INSERT INTO cortex.views (id, design, query) VALUES ('{routine}', '{prod}', 'SELECT 1');"),
        ("a column on a procedure", f"INSERT INTO cortex.columns (design, object, position, name, type, nullable) VALUES ('{prod}', '{routine}', 1, 'c', 'int', true);"),
        ("an index on a view", f"INSERT INTO cortex.indexes (design, object, position, name, \"unique\", method) VALUES ('{prod}', '{view}', 998, 'ix_view', false, 'BTREE');"),
        ("a privilege no engine has", f"INSERT INTO cortex.privileges (design, grantee, privilege, position) VALUES ('{d97}', '{account}', 'FLY', 999);"),
        ("a grant on a column and a table at once", f"INSERT INTO cortex.privileges (design, grantee, object, \"column\", privilege, position) VALUES ('{d97}', '{account}', '{obj('table', d97)}', (SELECT id FROM cortex.columns WHERE design = '{d97}' LIMIT 1), 'SELECT', 999);"),
        ("a table in no namespace", f"UPDATE cortex.objects SET namespace = NULL WHERE id = '{tab}';"),
        # parts that point at two things that must agree
        ("an index part on a column of another table", f"""UPDATE cortex.index_parts SET "column" = (SELECT c.id FROM cortex.columns c WHERE c.design = '{prod}'
            AND c.object <> '{tab}' LIMIT 1) WHERE id = (SELECT p.id FROM cortex.index_parts p JOIN cortex.indexes i ON i.id = p.index WHERE i.object = '{tab}' AND p."column" IS NOT NULL LIMIT 1);"""),
        ("a key's column from another table", f"""UPDATE cortex.constraint_columns SET "column" = (SELECT c.id FROM cortex.columns c WHERE c.design = '{prod}'
            AND c.object <> '{tab}' LIMIT 1) WHERE id = (SELECT x.id FROM cortex.constraint_columns x JOIN cortex.constraints k ON k.id = x."constraint" WHERE k.object = '{tab}' LIMIT 1);"""),
        ("a trigger whose parent is a procedure", f"UPDATE cortex.objects SET parent = '{routine}' WHERE id = (SELECT id FROM cortex.objects WHERE design = '{prod}' AND kind = 'trigger' LIMIT 1);"),
        ("a sequence's identity on a table", f"""UPDATE cortex.column_identities SET sequence = '{tab}' WHERE id = (SELECT id FROM cortex.column_identities WHERE design = '{prod}' LIMIT 1);"""),
        ("a foreign table's server that is a table (uses as server)", f"""UPDATE cortex.dependencies SET uses = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'table' LIMIT 1)
            WHERE id = (SELECT d.id FROM cortex.dependencies d JOIN cortex.objects o ON o.id = d.object WHERE o.design = '{pg}' AND o.kind = 'foreign_table' LIMIT 1);"""),
        ("a schema owned by a table", f"UPDATE cortex.namespace_owners SET owner = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'table' LIMIT 1), owner_name = NULL WHERE design = '{pg}';"),
        ("a user mapping for a table", f"UPDATE engine_postgresql.user_mappings SET role = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'table' LIMIT 1), role_name = NULL WHERE design = '{pg}';"),
        ("a publication that publishes a function", f"UPDATE engine_postgresql.publication_tables SET \"table\" = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'function' LIMIT 1), table_name = NULL WHERE design = '{pg}';"),
        ("a text search mapping to a table as its dictionary", f"UPDATE engine_postgresql.ts_config_mappings SET dictionary = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'table' LIMIT 1), dictionary_name = NULL WHERE design = '{pg}';"),
        ("statistics over a column of another table", f"""UPDATE engine_postgresql.statistics_parts SET "column" = (SELECT c.id FROM cortex.columns c JOIN cortex.objects o ON o.id = c.object
            WHERE o.design = '{pg}' AND o.name = 'kinds' LIMIT 1) WHERE design = '{pg}' AND "column" IS NOT NULL;"""),
        ("a sequence row on a MySQL table", f"INSERT INTO cortex.sequences (id, design) VALUES ('{tab}', '{prod}');"),
        ("a dependency in a role PostgreSQL does not declare", f"""UPDATE cortex.dependencies SET options = '{{"as": "flying"}}'
            WHERE id = (SELECT d.id FROM cortex.dependencies d JOIN cortex.objects o ON o.id = d.object WHERE o.design = '{pg}' AND o.kind = 'foreign_table' LIMIT 1);"""),
        ("a partition that is a view", f"""UPDATE cortex.partitions SET table_object = (SELECT id FROM cortex.objects WHERE design = '{pg}' AND kind = 'view' LIMIT 1)
            WHERE id = (SELECT id FROM cortex.partitions WHERE design = '{pg}' AND table_object IS NOT NULL LIMIT 1);"""),
    ]
    held = 0
    for what, q in gaps:
        ok, out, err = sql("sf_service", q, rollback=True)
        held += not ok
        print(f"  {'held' if not ok else 'GAP '}  {what}: {'refused (' + err[7:100] + ')' if not ok else 'TAKEN'}")
    print(f"== {held} of {len(gaps)} held; designs left as data (service-test-*): --clean deletes them")
    return 0 if held == len(gaps) else 1


if __name__ == "__main__":
    sys.exit(main())
