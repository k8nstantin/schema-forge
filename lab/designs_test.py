"""Many designs in the one database, schema_forge: each a row of cortex.designs (a UUIDv7) and the rows under it, never a
database, a namespace or a table of its own. Proves on our PostgreSQL (sf-store), with the locked design loaded exactly
as the dump loads it:

  two designs with the very same names live side by side, each whole;
  every reference that could reach from one design into another is refused at commit, by its rule;
  an engine's rules judge its own engine's designs only, and a design must be of a version its engine declares;
  deleting a design takes every row of it, in every namespace, and leaves the other design exactly as it was.

  python3 lab/designs_test.py [snapshot.json]      default: lab/out/mysql-8.4.json
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_designs"
OFF = 10_000_000  # design b's BIGINT ids are design a's plus this: a part and its twin differ by OFF
NEW = 90_000_000  # ids of rows a case makes
failures = 0


def run(sql):
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", DB, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    return r.returncode == 0, r.stdout.strip(), next((l for l in r.stderr.splitlines() if l.startswith("ERROR")), "")


def q(sql):
    return C.psql(sql, DB)


def check(ok, what):
    global failures
    failures += not ok
    print(f"  {'pass' if ok else 'FAIL'}  {what}")


def refused(what, view, change):
    """The change made as the app, inside one transaction: the rule's view lists a row, and the commit is refused."""
    ok, out, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\n{change}\nSELECT count(*) FROM {view};\nCOMMIT;")
    listed = out.splitlines()[-1] if out else "0"
    check(not ok and listed not in ("", "0") and "is broken by" in err,
          f"{what}: {view} lists {listed} row(s); commit {'refused' if not ok else 'ACCEPTED'}" + (f" ({err[7:90]})" if err else ""))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out", "mysql-8.4.json")
    snap = json.load(open(path))
    a_rows, _ = R.rows_of(snap, 0, "shop")
    b_rows, _ = R.rows_of(snap, OFF, "shop-copy")
    a, b = a_rows["cortex.designs"][0]["id"], b_rows["cortex.designs"][0]["id"]
    R.build(DB)
    R.load(DB, a_rows)
    R.load(DB, {k: v for k, v in b_rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")})
    OBJ = "SELECT o.id, o.namespace, o.kind, o.name, o.signature, o.parent, o.position, o.comment FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE n.design = '{d}'"
    NAMES = "SELECT n.name, o.kind, o.name, o.signature FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE n.design = '{d}'"

    print(f"== two designs in {DB}, loaded as sf_service with every rule held at commit")
    na, nb = q(f"SELECT count(*) FROM ({OBJ.format(d=a)}) x"), q(f"SELECT count(*) FROM ({OBJ.format(d=b)}) x")
    same = q(f"SELECT count(*) FROM (({NAMES.format(d=a)} EXCEPT {NAMES.format(d=b)}) UNION ALL ({NAMES.format(d=b)} EXCEPT {NAMES.format(d=a)})) x")
    check(na == nb and same == "0", f"shop and shop-copy hold the very same names side by side: {na} and {nb} objects, {same} names differ")
    broken = q("SELECT string_agg(n.nspname || '.' || c.relname, ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
               "WHERE c.relkind = 'v' AND c.relname LIKE 'broken\\_%'")
    lists = [v for v in broken.split(", ") if q(f"SELECT count(*) FROM {v}") != "0"]
    check(not lists, f"every one of {len(broken.split(', '))} rules holds with both loaded" + (f": BROKEN {', '.join(lists)}" if lists else ""))
    before = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")

    print("== a reference from one design into another, refused")
    trig = q(f"SELECT o.id FROM ({OBJ.format(d=a)}) o WHERE o.parent IS NOT NULL LIMIT 1")
    refused("a trigger's table in the other design", "cortex.broken_references_in_their_design",
            f"UPDATE cortex.objects SET parent = parent + {OFF} WHERE id = {trig};")
    fk = q(f"SELECT k.id FROM cortex.constraints k JOIN ({OBJ.format(d=a)}) o ON o.id = k.object WHERE k.to_object IS NOT NULL LIMIT 1")
    refused("a link to a table of the other design", "cortex.broken_references_in_their_design",
            f"UPDATE cortex.constraints SET to_object = to_object + {OFF} WHERE id = {fk};\n"
            f"UPDATE cortex.constraint_columns SET to_column = to_column + {OFF} WHERE \"constraint\" = {fk};")
    ki = q(f"SELECT k.id FROM cortex.constraints k JOIN ({OBJ.format(d=a)}) o ON o.id = k.object WHERE k.\"index\" IS NOT NULL LIMIT 1")
    if ki:
        refused("a key's index in the other design", "cortex.broken_references_in_their_design",
                f"UPDATE cortex.constraints SET \"index\" = \"index\" + {OFF} WHERE id = {ki};")
    dep = q(f"SELECT x.id FROM cortex.dependencies x JOIN ({OBJ.format(d=a)}) o ON o.id = x.object LIMIT 1")
    refused("a view using an object of the other design", "cortex.broken_references_in_their_design",
            f"UPDATE cortex.dependencies SET uses = uses + {OFF} WHERE id = {dep};")
    ns_a = q(f"SELECT min(id) FROM cortex.namespaces WHERE design = '{a}'")
    tab = q(f"SELECT min(o.id) FROM ({OBJ.format(d=a)}) o WHERE o.kind = 'table'")
    col = q(f"SELECT min(c.id) FROM cortex.columns c WHERE c.object = {tab}")
    seq = f"INSERT INTO cortex.objects (id, namespace, kind, name, position) VALUES ({NEW}, {ns_a}, 'sequence', 's_new', {NEW});\n"
    refused("a sequence owned by a column of the other design", "cortex.broken_references_in_their_design",
            seq + f"INSERT INTO cortex.sequences (id, owned_by) VALUES ({NEW}, {int(col) + OFF});")
    plain = q(f"SELECT min(c.id) FROM cortex.columns c JOIN ({OBJ.format(d=a)}) o ON o.id = c.object "
              "WHERE NOT EXISTS (SELECT 1 FROM cortex.column_identities i WHERE i.id = c.id)")
    refused("an identity drawing on a sequence of the other design", "cortex.broken_references_in_their_design",
            f"INSERT INTO cortex.column_identities (id, sequence) VALUES ({plain}, {int(tab) + OFF});")
    part = q(f"SELECT x.id FROM cortex.partitions x JOIN ({OBJ.format(d=a)}) o ON o.id = x.partitioning LIMIT 1")
    if part:
        refused("a partition whose table is in the other design", "cortex.broken_references_in_their_design",
                f"UPDATE cortex.partitions SET table_object = partitioning + {OFF} WHERE id = {part};")
    refused("a verbatim statement placed after an object of the other design", "cortex.broken_references_in_their_design",
            f"INSERT INTO cortex.verbatim_statements (design, position, kind, text, after_object) VALUES ('{a}', 1, 'grant', 'GRANT ...', {int(tab) + OFF});")
    refused("a namespace inside a namespace of the other design", "cortex.broken_namespaces_in_their_design",
            f"UPDATE cortex.namespaces SET parent = {int(ns_a) + OFF} WHERE id = {int(ns_a) + 1};")
    refused("a table placed in a subject area of the other design", "ui.broken_ui_rows_in_their_design",
            f"INSERT INTO ui.subject_areas (id, design, name, position) VALUES ({NEW}, '{b}', 'orders', 1);\n"
            f"INSERT INTO ui.object_places (id, area) VALUES ({tab}, {NEW});")
    refused("a usage snapshot naming a table of the other design", "usage.broken_usage_in_its_design",
            f"INSERT INTO cortex.source_reads (id, design, connection_name, database_name, scope, server_version, read_as, usage_available, started_at) "
            f"VALUES ('01900000-0000-7000-8000-000000000001', '{a}', 'local', 'shop', '{{}}', '8.4.0', 'reader', true, now());\n"
            f"INSERT INTO usage.snapshots (id, source_read, source, taken_at, server_uptime) VALUES "
            f"('01900000-0000-7000-8000-000000000002', '01900000-0000-7000-8000-000000000001', 'performance_schema', now(), 1);\n"
            f"INSERT INTO usage.object_usage (snapshot, object, object_schema, object_name, source_rows) VALUES "
            f"('01900000-0000-7000-8000-000000000002', {int(tab) + OFF}, 'shop', 'orders', '{{}}');")
    refused("an inherited parent in the other design", "engine_postgresql.broken_references_in_their_design",
            f"INSERT INTO engine_postgresql.inheritance (object, parent, position) VALUES ({tab}, {int(tab) + OFF}, 1);")

    print("== each engine's rules judge its own designs; a design is of a declared version")
    refused("a design of a version MySQL does not declare", "cortex.broken_designs_of_a_declared_version",
            "INSERT INTO cortex.designs (name, engine, engine_version) VALUES ('old', 'mysql', '3.23');")
    pg = ("INSERT INTO cortex.engine_versions (id, engine, version, name, position) VALUES ('postgresql/18', 'postgresql', '18', 'PostgreSQL 18', 1);\n"
          "INSERT INTO cortex.object_kinds (id, engine, kind, name, position) VALUES ('postgresql/table', 'postgresql', 'table', 'Table', 1);\n"
          "INSERT INTO cortex.designs (id, name, engine, engine_version) VALUES ('01900000-0000-7000-8000-0000000000aa', 'pg', 'postgresql', '18');\n"
          f"INSERT INTO cortex.namespaces (id, design, name, position) VALUES ({NEW}, '01900000-0000-7000-8000-0000000000aa', 'public', 1);\n"
          f"INSERT INTO cortex.objects (id, namespace, kind, name, position) VALUES ({NEW + 1}, {NEW}, 'table', 'orders', 1);\n")
    refused("MySQL's table options on a PostgreSQL design's table", "engine_mysql.broken_facts_on_designs_of_the_engine",
            pg +
            f"INSERT INTO engine_mysql.tables SELECT * FROM jsonb_populate_record(NULL::engine_mysql.tables, "
            f"(SELECT to_jsonb(t) || jsonb_build_object('id', {NEW + 1}) FROM engine_mysql.tables t WHERE id = {tab}));")
    refused("PostgreSQL's inheritance on a MySQL design's table", "engine_postgresql.broken_facts_on_designs_of_the_engine",
            f"INSERT INTO engine_postgresql.inheritance (object, parent, position) VALUES ({tab}, {int(tab) + 1}, 1);")
    ok, out, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\n{pg}"
                       f"SELECT (SELECT count(*) FROM engine_postgresql.broken_relations_have_their_facts) || ' ' || "
                       f"(SELECT count(*) FROM engine_mysql.broken_tables_have_their_options);\nCOMMIT;")
    pg_n, my_n = (out.splitlines()[-1].split() + ["?", "?"])[:2]
    check(not ok and pg_n == "1" and my_n == "0",
          f"a PostgreSQL design's table without its facts: PostgreSQL's rule lists {pg_n}, MySQL's lists {my_n}; commit {'refused' if not ok else 'ACCEPTED'}")

    print("== deleting a design")
    tables = q("SELECT string_agg(n.nspname || '.' || c.relname, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
               "WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'usage', 'engine_mysql', 'engine_postgresql')").split()
    count = " + ".join(f"(SELECT count(*) FROM {t})" for t in tables)
    total = int(q(f"SELECT {count}"))
    ok, _, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\nDELETE FROM cortex.designs WHERE id = '{b}';\nCOMMIT;")
    left = int(q(f"SELECT {count}"))
    after = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")
    nb2 = q(f"SELECT count(*) FROM cortex.namespaces WHERE design = '{b}'")
    b_had = sum(len(v) for k, v in b_rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds"))
    check(ok and total - left == b_had and nb2 == "0" and after == before,
          f"shop-copy deleted as sf_service, one row: {total - left} rows went of the {b_had} it had, every rule held; shop untouched: {'exact' if after == before else 'CHANGED'}"
          + (f" ({err})" if err else ""))
    print(f"{'pass' if not failures else 'FAIL'}  designs as rows: {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
