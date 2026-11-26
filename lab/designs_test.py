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
import uuid
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import pg_store as P  # noqa: E402
import repo_pg_store as RP  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_designs"
NEW = [str(uuid.uuid7()) for _ in range(3)]  # ids of rows a case makes
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
    a_rows, _ = R.rows_of(snap, "shop")
    b_rows, twin_ids = R.twin(a_rows, "shop-copy")

    def T(x):
        """The twin in shop-copy of a part of shop."""
        return f"'{twin_ids[x]}'"
    TW = "(SELECT b FROM public.lab_twin WHERE a = {})"  # the same, inside a statement
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
    # and a PostgreSQL design with its twin: sequences, identities and inheritance are PostgreSQL's alone
    pg_snap = json.load(open(os.path.join(HERE, "out", "postgresql-18.json")))
    p_rows, _ = RP.to_locked(P.rows_of(pg_snap), "18", pg_snap["parts"])
    p_rows["cortex.designs"][0]["name"] = "pg"
    p_copy, pg_twin = R.twin(p_rows, "pg-copy")
    for rows in (p_rows, p_copy):
        rows = RP.jsonish(R.OL.to_options({k: v for k, v in rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")}))
        C.psql("BEGIN;\nSET ROLE sf_service;\n" + "".join(R.copy_sql(k, rows[k]) for k in RP.ORDER if rows.get(k)) + "COMMIT;\n", DB)
    pa = p_rows["cortex.designs"][0]["id"]
    PT = lambda x: f"'{pg_twin[x]}'"  # noqa: E731  the twin in pg-copy of a part of pg
    q("CREATE TABLE public.lab_twin (a uuid PRIMARY KEY, b uuid NOT NULL); GRANT SELECT ON public.lab_twin TO sf_service;")
    q("INSERT INTO public.lab_twin VALUES " + ", ".join(f"('{k}', '{v}')" for k, v in twin_ids.items() if len(k) == 36) + ";")
    OBJ = "SELECT o.id, o.namespace, o.kind, o.name, o.signature, o.parent, o.position, o.comment FROM cortex.objects o WHERE o.design = '{d}'"
    NAMES = "SELECT n.name, o.kind, o.name, o.signature FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.design = '{d}'"
    na, nb = q(f"SELECT count(*) FROM ({OBJ.format(d=a)}) x"), q(f"SELECT count(*) FROM ({OBJ.format(d=b)}) x")
    same = q(f"SELECT count(*) FROM (({NAMES.format(d=a)} EXCEPT {NAMES.format(d=b)}) UNION ALL ({NAMES.format(d=b)} EXCEPT {NAMES.format(d=a)})) x")
    check(na == nb and same == "0", f"shop and shop-copy hold the very same names side by side: {na} and {nb} objects, {same} names differ")
    before = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")

    print("== a reference from one design into another, refused by the foreign keys")
    trig = q(f"SELECT id FROM cortex.objects WHERE design = '{a}' AND parent IS NOT NULL LIMIT 1")
    refused("a trigger's table in the other design", f"UPDATE cortex.objects SET parent = {TW.format('parent')} WHERE id = '{trig}';")
    fk = q(f"SELECT id FROM cortex.constraints WHERE design = '{a}' AND to_object IS NOT NULL LIMIT 1")
    refused("a link to a table of the other design", f"UPDATE cortex.constraints SET to_object = {TW.format('to_object')} WHERE id = '{fk}';\n"
                                                    f"UPDATE cortex.constraint_columns SET to_column = {TW.format('to_column')} WHERE \"constraint\" = '{fk}';")
    ki = q(f"SELECT id FROM cortex.constraints WHERE design = '{a}' AND \"index\" IS NOT NULL LIMIT 1")
    refused("a key's index in the other design", f"UPDATE cortex.constraints SET \"index\" = {TW.format(chr(34) + 'index' + chr(34))} WHERE id = '{ki}';")
    dep = q(f"SELECT id FROM cortex.dependencies WHERE design = '{a}' LIMIT 1")
    refused("a view using an object of the other design", f"UPDATE cortex.dependencies SET uses = {TW.format('uses')} WHERE id = '{dep}';")
    ns_a, ns_a2 = q(f"SELECT id FROM cortex.namespaces WHERE design = '{a}' ORDER BY position LIMIT 2").split()
    tab = q(f"SELECT id FROM cortex.objects WHERE design = '{a}' AND kind = 'table' ORDER BY position LIMIT 1")
    col = q(f"SELECT id FROM cortex.columns WHERE object = '{tab}' ORDER BY position LIMIT 1")
    # sequences and identities are PostgreSQL's: the PostgreSQL pair proves them, each a real row pointed at its twin
    pseq, pcol = q(f"SELECT s.id || ' ' || c.id FROM cortex.sequences s, cortex.columns c WHERE s.design = '{pa}' AND c.design = '{pa}' LIMIT 1").split()
    refused("a sequence owned by a column of the other design", f"UPDATE cortex.sequences SET owned_by = {PT(pcol)} WHERE id = '{pseq}';")
    pid = q(f"SELECT id || ' ' || sequence FROM cortex.column_identities WHERE design = '{pa}' AND sequence IS NOT NULL LIMIT 1").split()
    refused("an identity drawing on a sequence of the other design", f"UPDATE cortex.column_identities SET sequence = {PT(pid[1])} WHERE id = '{pid[0]}';")
    part = q(f"SELECT id FROM cortex.partitions WHERE design = '{a}' LIMIT 1")
    if part:
        refused("a partition whose table is in the other design", f"UPDATE cortex.partitions SET table_object = {TW.format('partitioning')} WHERE id = '{part}';")
    refused("a verbatim statement placed after an object of the other design",
            f"INSERT INTO cortex.verbatim_statements (design, position, kind, text, after_object) VALUES ('{a}', 1, 'grant', 'GRANT ...', {T(tab)});")
    refused("a namespace inside a namespace of the other design", f"UPDATE cortex.namespaces SET parent = {T(ns_a)} WHERE id = '{ns_a2}';")
    refused("a table placed in a subject area of the other design",
            f"INSERT INTO ui.subject_areas (id, design, name, position) VALUES ('{NEW[1]}', '{b}', 'orders', 1);\n"
            f"INSERT INTO ui.object_places (id, design, area) VALUES ('{tab}', '{a}', '{NEW[1]}');")
    refused("a choice of what to read listing a kind under the other design's choice",
            f"INSERT INTO cortex.read_scopes (id, design, everything, made_by) VALUES ('{NEW[2]}', '{b}', false, 'lab');\n"
            f"INSERT INTO cortex.read_scope_kinds (design, scope, kind) VALUES ('{a}', '{NEW[2]}', 'table');")
    inh = q(f"SELECT id || ' ' || parent FROM engine_postgresql.inheritance WHERE design = '{pa}' LIMIT 1").split()
    refused("an inherited parent in the other design", f"UPDATE engine_postgresql.inheritance SET parent = {PT(inh[1])} WHERE id = '{inh[0]}';")
    refused("a row of one design claiming the other's design",
            f"UPDATE cortex.views SET design = '{b}' WHERE id = (SELECT id FROM cortex.views WHERE design = '{a}' LIMIT 1);")

    print("== deleting a design")
    tables = q("SELECT string_agg(n.nspname || '.' || c.relname, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
               "WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'usage', 'engine_mysql', 'engine_postgresql')").split()
    count = " + ".join(f"(SELECT count(*) FROM {t})" for t in tables)
    total = int(q(f"SELECT {count}"))
    ok, _, err = run(f"BEGIN;\nSET LOCAL ROLE sf_service;\nDELETE FROM cortex.designs WHERE id = '{b}';\nCOMMIT;")
    left = int(q(f"SELECT {count}"))
    after = q(f"SELECT md5(string_agg(x::text, '|' ORDER BY x.id)) FROM ({OBJ.format(d=a)}) x")
    b_had = sum(len(v) for k, v in R.OL.to_options(b_rows).items())
    stray = sum(int(q(f"SELECT count(*) FROM {t} WHERE design = '{b}'")) for t in design_tables)
    check(ok and total - left == b_had and stray == 0 and after == before,
          f"shop-copy deleted as sf_service, one row: {total - left} rows went of the {b_had} it had, {stray} left anywhere; "
          f"shop untouched: {'exact' if after == before else 'CHANGED'}" + (f" ({err})" if err else ""))
    print(f"{'pass' if not failures else 'FAIL'}  designs as rows: {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
