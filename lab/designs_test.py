"""Many designs in the one database, schema_forge: each a row of cortex.designs (a UUIDv7) and the rows under it, never a
database, a namespace or a table of its own; every table of a design carries its design, and every reference within a
design is (design, column) -> (design, id) (decision database-per-schema). Proves on our PostgreSQL (sf-store), with the
locked design loaded exactly as the dump loads it:

  every foreign key between two tables of a design is led by design, and has its index;
  two designs with the very same names live side by side, each whole;
  every reference that could reach from one design into another is refused by the database's own foreign keys;
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


def refused(what, change):
    """The change made as the app, in one transaction: the database refuses it by a foreign key."""
    ok, _, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\n{change}\nCOMMIT;")
    check(not ok and "violates foreign key constraint" in err, f"{what}: {'refused' if not ok else 'ACCEPTED'}" + (f" ({err[8:110]})" if err else ""))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out", "mysql-8.4.json")
    snap = json.load(open(path))
    a_rows, _ = R.rows_of(snap, 0, "shop")
    b_rows, _ = R.rows_of(snap, OFF, "shop-copy")
    a, b = a_rows["cortex.designs"][0]["id"], b_rows["cortex.designs"][0]["id"]
    R.build(DB)

    print("== the shape, read from the database's catalog")
    design_tables = q("SELECT string_agg(n.nspname || '.' || c.relname, ' ') FROM pg_attribute x JOIN pg_class c ON c.oid = x.attrelid "
                      "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE x.attname = 'design' AND c.relkind = 'r' "
                      "AND NOT (n.nspname = 'cortex' AND c.relname LIKE 'workspace\\_%')").split()
    fks = q("SELECT string_agg(format('%s %s %s', c.conrelid::regclass, c.confrelid::regclass, "
            "(SELECT string_agg(attname, ',' ORDER BY k.n) FROM unnest(c.conkey) WITH ORDINALITY k(a, n) JOIN pg_attribute ON attrelid = c.conrelid AND attnum = k.a)), ';') "
            "FROM pg_constraint c WHERE c.contype = 'f'").split(";")
    within = [f.split() for f in fks if f.split()[0] in design_tables and f.split()[1] in design_tables]
    alone = [f for f in within if not f[2].startswith("design,")]
    check(not alone, f"{len(design_tables)} tables carry their design; {len(within)} foreign keys within a design, every one led by design"
          + (f": NOT {alone}" if alone else ""))
    unindexed = q("SELECT string_agg(c.conrelid::regclass || ' (' || array_to_string(c.conkey, ',') || ')', ', ') FROM pg_constraint c "
                  "WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 2 AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid "
                  "AND (i.indkey::int2[])[0:1] = c.conkey)")
    check(not unindexed, "every one has an index led by its own columns" + (f": NOT {unindexed}" if unindexed else ""))

    print(f"== two designs in {DB}, loaded as sf_service")
    R.load(DB, a_rows)
    R.load(DB, {k: v for k, v in b_rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")})
    OBJ = "SELECT o.id, o.namespace, o.kind, o.name, o.signature, o.parent, o.position, o.comment FROM cortex.objects o WHERE o.design = '{d}'"
    NAMES = "SELECT n.name, o.kind, o.name, o.signature FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.design = '{d}'"
    na, nb = q(f"SELECT count(*) FROM ({OBJ.format(d=a)}) x"), q(f"SELECT count(*) FROM ({OBJ.format(d=b)}) x")
    same = q(f"SELECT count(*) FROM (({NAMES.format(d=a)} EXCEPT {NAMES.format(d=b)}) UNION ALL ({NAMES.format(d=b)} EXCEPT {NAMES.format(d=a)})) x")
    check(na == nb and same == "0", f"shop and shop-copy hold the very same names side by side: {na} and {nb} objects, {same} names differ")
    before = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")

    print("== a reference from one design into another, refused by the foreign keys")
    trig = q(f"SELECT id FROM cortex.objects WHERE design = '{a}' AND parent IS NOT NULL LIMIT 1")
    refused("a trigger's table in the other design", f"UPDATE cortex.objects SET parent = parent + {OFF} WHERE id = {trig};")
    fk = q(f"SELECT id FROM cortex.constraints WHERE design = '{a}' AND to_object IS NOT NULL LIMIT 1")
    refused("a link to a table of the other design", f"UPDATE cortex.constraints SET to_object = to_object + {OFF} WHERE id = {fk};\n"
                                                    f"UPDATE cortex.constraint_columns SET to_column = to_column + {OFF} WHERE \"constraint\" = {fk};")
    ki = q(f"SELECT id FROM cortex.constraints WHERE design = '{a}' AND \"index\" IS NOT NULL LIMIT 1")
    refused("a key's index in the other design", f"UPDATE cortex.constraints SET \"index\" = \"index\" + {OFF} WHERE id = {ki};")
    dep = q(f"SELECT id FROM cortex.dependencies WHERE design = '{a}' LIMIT 1")
    refused("a view using an object of the other design", f"UPDATE cortex.dependencies SET uses = uses + {OFF} WHERE id = {dep};")
    ns_a = q(f"SELECT min(id) FROM cortex.namespaces WHERE design = '{a}'")
    tab = q(f"SELECT min(id) FROM cortex.objects WHERE design = '{a}' AND kind = 'table'")
    col = q(f"SELECT min(id) FROM cortex.columns WHERE object = {tab}")
    seq = f"INSERT INTO cortex.objects (id, design, namespace, kind, name, position) VALUES ({NEW}, '{a}', {ns_a}, 'sequence', 's_new', {NEW});\n"
    refused("a sequence owned by a column of the other design",
            seq + f"INSERT INTO cortex.sequences (id, design, owned_by) VALUES ({NEW}, '{a}', {int(col) + OFF});")
    plain = q(f"SELECT min(c.id) FROM cortex.columns c WHERE c.design = '{a}' AND NOT EXISTS (SELECT 1 FROM cortex.column_identities i WHERE i.id = c.id)")
    refused("an identity drawing on a sequence of the other design",
            f"INSERT INTO cortex.column_identities (id, design, sequence) VALUES ({plain}, '{a}', {int(tab) + OFF});")
    part = q(f"SELECT id FROM cortex.partitions WHERE design = '{a}' LIMIT 1")
    if part:
        refused("a partition whose table is in the other design", f"UPDATE cortex.partitions SET table_object = partitioning + {OFF} WHERE id = {part};")
    refused("a verbatim statement placed after an object of the other design",
            f"INSERT INTO cortex.verbatim_statements (design, position, kind, text, after_object) VALUES ('{a}', 1, 'grant', 'GRANT ...', {int(tab) + OFF});")
    refused("a namespace inside a namespace of the other design", f"UPDATE cortex.namespaces SET parent = {int(ns_a) + OFF} WHERE id = {int(ns_a) + 1};")
    refused("a table placed in a subject area of the other design",
            f"INSERT INTO ui.subject_areas (id, design, name, position) VALUES ({NEW}, '{b}', 'orders', 1);\n"
            f"INSERT INTO ui.object_places (id, design, area) VALUES ({tab}, '{a}', {NEW});")
    refused("a choice of what to read listing a kind under the other design's choice",
            f"INSERT INTO cortex.read_scopes (id, design, everything, made_by) VALUES ({NEW}, '{b}', false, 'lab');\n"
            f"INSERT INTO cortex.read_scope_kinds (design, scope, kind) VALUES ('{a}', {NEW}, 'table');")
    refused("an inherited parent in the other design",
            f"INSERT INTO engine_postgresql.inheritance (design, object, parent, position) VALUES ('{a}', {tab}, {int(tab) + OFF}, 1);")
    refused("a row of one design claiming the other's design",
            f"UPDATE engine_mysql.tables SET design = '{b}' WHERE id = {tab};")

    print("== deleting a design")
    tables = q("SELECT string_agg(n.nspname || '.' || c.relname, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
               "WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'usage', 'engine_mysql', 'engine_postgresql')").split()
    count = " + ".join(f"(SELECT count(*) FROM {t})" for t in tables)
    total = int(q(f"SELECT {count}"))
    ok, _, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\nDELETE FROM cortex.designs WHERE id = '{b}';\nCOMMIT;")
    left = int(q(f"SELECT {count}"))
    after = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")
    b_had = sum(len(v) for k, v in b_rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds"))
    stray = sum(int(q(f"SELECT count(*) FROM {t} WHERE design = '{b}'")) for t in design_tables)
    check(ok and total - left == b_had and stray == 0 and after == before,
          f"shop-copy deleted as sf_service, one row: {total - left} rows went of the {b_had} it had, {stray} left anywhere; "
          f"shop untouched: {'exact' if after == before else 'CHANGED'}" + (f" ({err})" if err else ""))
    print(f"{'pass' if not failures else 'FAIL'}  designs as rows: {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
