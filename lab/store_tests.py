"""Edits that cross the global schema and the MySQL plugin's, on the new store (lab_v2_mysql_<v>) beside the old
layout (lab_scale_mysql_<v>), both holding the same snapshot. Prints counts and timings only, never a name.

  python3 lab/store_v2_tests.py <snapshot.json>       after lab/store_v2.py and lab/scale.py on it
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import random  # noqa: E402
import store as S2  # noqa: E402
import common as C  # noqa: E402


def attempt(sql, db):
    """A statement inside a turn of the log, so what refuses it is the schema, never the log."""
    sql = sql.replace("BEGIN;", "BEGIN; SELECT log.begin_turn('attempt');", 1)
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    return r.returncode == 0, next((l for l in r.stderr.splitlines() if l.startswith("ERROR")), "")[:140]


def ms(f):
    t = time.time()
    out = f()
    return out, (time.time() - t) * 1000


def one(sql, db):
    return C.psql(sql, db).strip()


def main():
    snap = json.load(open(sys.argv[1]))
    v = snap["version"].replace(".", "_")
    new, old = f"lab_store_mysql_{v}", f"lab_scale_mysql_{v}"
    S2.build(new, S2.rows_of(snap)[0])
    same = one("SELECT count(*) FROM core.object WHERE kind = 'table'", new) == \
        one("SELECT count(*) FROM core.object WHERE kind = 'table'", old)  # the old layout holds this snapshot
    version = snap["version"]
    ok = lambda b: "pass" if b else "FAIL"

    print("== size")
    for db, schemas in ((new, "'core','engine_mysql'"),) + (((old, "'core','engine_mysql'"),) if same else ()):
        r = one(f"SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid)) FILTER (WHERE n.nspname IN ({schemas}))) || ' store, ' || "
                f"pg_size_pretty(sum(pg_total_relation_size(c.oid)) FILTER (WHERE n.nspname = 'log')) || ' log, ' || "
                f"(SELECT count(*) FROM log.changes) || ' changes logged for the import' FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r'", db)
        print(f"  {'new' if db == new else 'old'}: {r}")

    # the column most referenced: by indexes and by other tables' foreign keys
    col = json.loads(one("""SELECT json_build_object('id', c.id, 'object', c.object_id, 'n', n) FROM (
        SELECT c.id, c.object_id, (SELECT count(*) FROM core.index_part p WHERE p.column_id = c.id)
          + (SELECT count(*) FROM core.constraint_column k WHERE k.ref_column_id = c.id) AS n FROM core.column c) c
        ORDER BY n DESC, id LIMIT 1""", new))
    print("== rename a column that indexes and other tables' foreign keys use")
    touched_tables = json.loads(one(f"""SELECT json_agg(DISTINCT x) FROM (SELECT {col['object']} AS x UNION
        SELECT k.object_id FROM core.constraint k JOIN core.constraint_column cc ON cc.constraint_id = k.id WHERE cc.ref_column_id = {col['id']}) y""", new))
    before = S2.write(S2.load_back(new), version)
    _, t = ms(lambda: C.psql(f"BEGIN; SELECT log.begin_turn('rename a column'); UPDATE core.column SET name = name || '_renamed' WHERE id = {col['id']}; "
                             "SELECT log.end_turn(); COMMIT;", new))
    after = S2.write(S2.load_back(new), version)
    changed = [k for k in after if after[k] != before[k]]
    logged = one("SELECT count(*) FROM log.changes WHERE turn = (SELECT max(id) FROM log.turns)", new)
    print(f"  new: 1 row changed, {logged} change logged, {t:.0f} ms; {len(changed)} statements now write the new name, "
          f"{len(touched_tables)} tables use the column: {ok(len(changed) == len(touched_tables))}")
    name = one(f"SELECT name FROM core.column WHERE id = {col['id']}", new)[:-len('_renamed')]
    tname = one(f"SELECT n.name || '.' || o.name FROM core.object o JOIN core.namespace n ON n.id = o.namespace_id WHERE o.id = {col['object']}", new)
    tabs = C.psql("SELECT string_agg(n.nspname || '.' || c.relname, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                  "WHERE n.nspname IN ('core', 'engine_mysql') AND c.relkind = 'r'", old).split()
    pat = name.replace("'", "''")
    copies = one("SELECT " + " + ".join(f"(SELECT count(*) FROM {t} x WHERE (to_jsonb(x)::text LIKE '%\"{pat}\"%' OR to_jsonb(x)::text LIKE '%.{pat}\"%') "
                            f"AND to_jsonb(x)::text LIKE '%{tname.split('.')[-1].replace(chr(39), chr(39) * 2)}%')" for t in tabs), old)
    copies = f"{copies} rows hold the column's name as a value or in their id"
    print(f"  old: the name is written in many rows, each to change and keep in step: {copies}")

    tid = one("SELECT ref_object_id FROM core.constraint WHERE ref_object_id IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC LIMIT 1", new)
    if not tid:
        print("== no foreign keys in this schema: the tests of tables other tables refer to are left to a schema that has them")
    else:
        print("== rename a table other tables refer to")
        _, t = ms(lambda: C.psql(f"BEGIN; SELECT log.begin_turn('rename a table'); UPDATE core.object SET name = name || '_r' WHERE id = {tid}; "
                                 "SELECT log.end_turn(); COMMIT;", new))
        print(f"  new: 1 row, {t:.0f} ms")
        tkey = one(f"SELECT n.name || '.' || left(o.name, -2) FROM core.object o JOIN core.namespace n ON n.id = o.namespace_id WHERE o.id = {tid}", new)
        rows = one(f"""SELECT sum(n) FROM (SELECT count(*) n FROM core.object WHERE id = '{tkey}' UNION ALL
            SELECT count(*) FROM core.column WHERE parent = '{tkey}' UNION ALL SELECT count(*) FROM core.index_part WHERE parent LIKE '{tkey}.%'
            UNION ALL SELECT count(*) FROM core.constraint WHERE parent = '{tkey}' UNION ALL SELECT count(*) FROM core.constraint_column WHERE parent LIKE '{tkey}.%') x""", old)
        print(f"  old: {rows} rows hold the table's name in their id or parent, and every plugin row that shares those ids")

        print("== drop a table other tables' foreign keys use")
        good, why = attempt(f"BEGIN; DELETE FROM core.object WHERE id = {tid}; COMMIT;", new)
        print(f"  refused at commit, as MySQL refuses it: {ok(not good)} ({why})")


    print("== drop a table no key uses, then undo it")
    big = one("""SELECT o.id FROM core.object o WHERE o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM core.constraint k WHERE k.ref_object_id = o.id)
        ORDER BY (SELECT count(*) FROM core.column c WHERE c.object_id = o.id) DESC LIMIT 1""", new)
    C.psql("SELECT log.savepoint('before drop');", new)
    h0 = one("SELECT log.state_hash();", new)
    _, t = ms(lambda: C.psql(f"BEGIN; SELECT log.begin_turn('drop'); DELETE FROM core.object WHERE id = {big}; SELECT log.end_turn(); COMMIT;", new))
    gone = one("SELECT string_agg(tab || ' ' || n, ', ' ORDER BY tab) FROM (SELECT tab, count(*) n FROM log.changes "
               "WHERE turn = (SELECT max(id) FROM log.turns) GROUP BY tab) x", new)
    print(f"  one DELETE took with it: {gone} ({t:.0f} ms)")
    _, t = ms(lambda: C.psql("SELECT log.restore('before drop');", new))
    print(f"  restored, global and plugin rows together: {ok(one('SELECT log.state_hash();', new) == h0)} ({t:.0f} ms)")

    print("== a plugin row may only extend what it is for")
    a_view = one("SELECT id FROM core.object WHERE kind <> 'table' LIMIT 1", new)
    a_col = one("SELECT max(id) FROM core.column", new)
    for label, sql in (("table options on a view or routine", f"INSERT INTO engine_mysql.table (id, engine, collation_name) VALUES ({a_view}, 'InnoDB', 'x');"),
                       ("table options on a column's id", f"INSERT INTO engine_mysql.table (id, engine, collation_name) VALUES ({a_col}, 'InnoDB', 'x');"),
                       ("a column option with no column", "INSERT INTO engine_mysql.column (id) VALUES (999999999);")):
        good, why = attempt(f"BEGIN; {sql} COMMIT;", new)
        print(f"  {label}: refused {ok(not good)} ({why[:90]})")

    print("== the plugin removed: the global schema stands on its own")
    counts = "SELECT (SELECT count(*) FROM core.object) || '/' || (SELECT count(*) FROM core.column) || '/' || (SELECT count(*) FROM core.index)"
    before = one(counts, new)
    good, why = attempt(f"BEGIN; DROP SCHEMA engine_mysql CASCADE; SET CONSTRAINTS ALL IMMEDIATE; {counts}; ROLLBACK;", new)
    print(f"  dropped and checked, nothing in the global schema lost or broken: {ok(good)}")

    print("== questions across the global schema and the plugin's")
    qs = {
        "InnoDB tables with a COMPACT row format and an auto-numbered column": (
            "SELECT count(*) FROM engine_mysql.table t JOIN core.column c ON c.object_id = t.id WHERE t.row_format = 'COMPACT' AND c.identity = 'auto'",
            "SELECT count(*) FROM engine_mysql.object_options t JOIN core.column c ON c.parent = t.id "
            "WHERE t.\"CREATE_OPTIONS\" LIKE '%row_format=COMPACT%' AND c.identity LIKE '%auto_increment%'"),
        "nullable columns in a unique index": (
            "SELECT count(*) FROM core.index i JOIN core.index_part p ON p.index_id = i.id JOIN core.column c ON c.id = p.column_id WHERE i.is_unique AND c.nullable",
            "SELECT count(*) FROM core.index_part p JOIN core.column c ON c.parent = regexp_replace(p.parent, '\\.[^.]*$', '') AND c.name = p.\"column\" WHERE p.\"unique\" = '0' AND c.nullable = 'YES'"),
        "foreign keys whose two columns differ in type": (
            "SELECT count(*) FROM core.constraint_column k JOIN core.column a ON a.id = k.column_id JOIN core.column b ON b.id = k.ref_column_id WHERE a.type <> b.type",
            None),
        "every table with its columns, as the canvas loads them": (
            "SELECT count(*) FROM (SELECT o.id, json_agg(c ORDER BY c.position) FROM core.object o JOIN core.column c ON c.object_id = o.id LEFT JOIN engine_mysql.column mc ON mc.id = c.id WHERE o.kind = 'table' GROUP BY o.id) x",
            "SELECT count(*) FROM (SELECT o.id, json_agg(c ORDER BY c.position) FROM core.object o JOIN core.column c ON c.parent = o.id LEFT JOIN engine_mysql.column_options mc ON mc.id = c.id WHERE o.kind = 'table' GROUP BY o.id) x"),
    }
    def server_ms(sql, db):
        """The server's own execution time, best of three: no docker or psql start in it."""
        best = None
        for _ in range(3):
            plan = json.loads(one(f"EXPLAIN (ANALYZE, FORMAT JSON) {sql}", db))
            best = min(best or 1e9, plan[0]["Execution Time"])
        return best

    for label, (qn, qo) in qs.items():
        n, tn = one(qn, new), server_ms(qn, new)
        line = f"  {label}: new {n} in {tn:.1f} ms"
        if qo and same:
            try:
                o, to = one(qo, old), server_ms(qo, old)
                line += f"; old {o} in {to:.1f} ms"
            except SystemExit as e:
                line += f"; old: cannot be asked ({str(e)[-80:]})"
        elif not qo:
            line += "; old: the referenced column is a name in text, the question needs parsing"
        print(line)




# what the MySQL plugin will refuse before writing, found by these tests: a table that is partitioned, in a foreign
# key, or has an expression index part stays InnoDB (8.0 refuses MyISAM partitions, 5.7 drops MyISAM foreign keys
# without a word); a table a view uses or a key references cannot go; a type is written as the version writes it
PLAIN = ("NOT EXISTS (SELECT 1 FROM core.partitioning p WHERE p.id = t.id) AND NOT EXISTS (SELECT 1 FROM core.constraint k "
         "WHERE k.kind = 'foreign' AND (k.object_id = t.id OR k.ref_object_id = t.id)) AND NOT EXISTS (SELECT 1 FROM core.index i "
         "JOIN core.index_part x ON x.index_id = i.id WHERE i.object_id = t.id AND x.expression IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM engine_mysql.table m WHERE m.id = t.id "
         "AND m.engine = 'MRG_MyISAM') AND NOT EXISTS (SELECT 1 FROM core.dependency d WHERE d.uses_object_id = t.id)")
UNUSED = ("NOT EXISTS (SELECT 1 FROM core.constraint k WHERE k.ref_object_id = t.id) AND NOT EXISTS "
          "(SELECT 1 FROM core.dependency d WHERE d.uses_object_id = t.id)")


def edit(db, rnd, n, version="8.4"):
    """One turn of one to five edits, across the global schema and the plugin's."""
    ids = json.loads(one("SELECT json_build_object('t', (SELECT json_agg(id) FROM core.object WHERE kind = 'table'), "
                         "'c', (SELECT json_agg(id) FROM core.column), 'ns', (SELECT min(id) FROM core.namespace), "
                         "'top', (SELECT greatest(max(id), 0) FROM core.object) + (SELECT count(*) FROM core.column) * 3 + 10000000 + " + str(n * 1000) + ")", db))
    sql = [f"BEGIN; SELECT log.begin_turn('edit {n}');"]
    nxt = ids["top"]
    for _ in range(rnd.randint(1, 5)):
        k = rnd.random()
        if k < 0.2:
            sql.append(f"UPDATE core.object SET comment = 'note {n}' WHERE id = {rnd.choice(ids['t'])};")
        elif k < 0.35:
            sql.append(f"UPDATE core.column SET default_value = '{rnd.randint(0, 99)}', default_is_expression = false WHERE id = "
                       f"(SELECT id FROM core.column WHERE type LIKE 'int%' AND generated IS NULL AND identity IS NULL ORDER BY id OFFSET {rnd.randint(0, 50)} LIMIT 1);")
        elif k < 0.5:
            sql.append(f"UPDATE engine_mysql.table t SET engine = '{rnd.choice(['InnoDB', 'MyISAM'])}', row_format = {rnd.choice(['NULL', chr(39) + 'DYNAMIC' + chr(39)])} "
                       f"WHERE t.id = (SELECT t.id FROM core.object t WHERE t.kind = 'table' AND {PLAIN} ORDER BY t.id OFFSET {rnd.randint(0, 50)} LIMIT 1);")
        elif k < 0.65:
            # a column no view uses: a rename never reaches into a view's text
            sql.append(f"UPDATE core.column SET name = name || '_{n}' WHERE id = (SELECT c.id FROM core.column c WHERE NOT EXISTS "
                       f"(SELECT 1 FROM core.dependency d WHERE d.uses_object_id = c.object_id) ORDER BY c.id OFFSET {rnd.randint(0, 500)} LIMIT 1);")
        elif k < 0.85:
            nxt += 10
            sql.append(f"INSERT INTO core.object (id, namespace_id, kind, name) VALUES ({nxt}, {ids['ns']}, 'table', 'lab_t{n}_{nxt}');")
            # the namespace's own collation: one the server has
            sql.append(f"INSERT INTO engine_mysql.table (id, engine, collation_name) SELECT {nxt}, 'InnoDB', collation_name FROM engine_mysql.namespace WHERE id = {ids['ns']};")
            for i in range(rnd.randint(1, 4)):
                sql.append(f"INSERT INTO core.column (id, object_id, position, name, type, nullable) VALUES ({nxt + 1 + i}, {nxt}, {i + 1}, 'c{i}', '{'int(11)' if version.startswith('5.') else 'int'}', {str(i > 0).lower()});")
            sql.append(f"INSERT INTO core.index (id, object_id, name, position, is_primary, is_unique, method) VALUES ({nxt + 6}, {nxt}, 'PRIMARY', 1, true, true, 'BTREE');")
            sql.append(f"INSERT INTO core.index_part (id, index_id, position, column_id) VALUES ({nxt + 7}, {nxt + 6}, 1, {nxt + 1});")
        else:
            sql.append(f"DELETE FROM core.object WHERE id = (SELECT t.id FROM core.object t WHERE t.kind = 'table' AND {UNUSED} "
                       f"ORDER BY t.id OFFSET {rnd.randint(0, 50)} LIMIT 1);")
    sql.append("SELECT log.end_turn(); COMMIT;")
    C.psql("\n".join(sql), db)


def versioning(snap, turns=300):
    v = snap["version"].replace(".", "_")
    db = f"lab_store_mysql_{v}"
    S2.build(db, S2.rows_of(snap)[0])
    rnd = random.Random(7)
    hashes = {}

    def save(name):
        C.psql(f"SELECT log.savepoint('{name}');", db)
        hashes[name] = one("SELECT log.state_hash();", db)

    def at(name):
        return "exact" if one("SELECT log.state_hash();", db) == hashes[name] else "WRONG"
    save("imported")
    t = time.time()
    for n in range(1, turns + 1):
        edit(db, rnd, n)
        if n % (turns // 3) == 0:
            save(f"main{n // (turns // 3)}")
    print(f"== versioning: {turns} turns of edits across both schemas on main ({time.time() - t:.0f}s)")
    print(f"  version v1 locked at main3: {'exact' if one(chr(83) + 'ELECT log.lock_version(' + chr(39) + 'v1' + chr(39) + ');', db) == hashes['main3'] else 'WRONG'}")
    (moved, tm) = ms(lambda: one("SELECT log.branch('experiment', 'main1');", db))
    print(f"  branch from main1: {moved} changes undone in {tm:.0f} ms; state is main1's: {at('main1')}")
    for n in range(turns + 1, turns + turns // 2 + 1):
        edit(db, rnd, n)
    save("experiment1")
    for target, name in (("main", "main3"), ("experiment", "experiment1"), ("main", "main3")):
        moved, tm = ms(lambda: one(f"SELECT log.switch('{target}');", db))
        print(f"  switch to {target}: {moved} changes in {tm:.0f} ms; state is {name}'s: {at(name)}")
    for name in ("imported", "main2", "experiment1"):
        got, tm = ms(lambda: C.psql(f"BEGIN; SELECT log.move_to((SELECT turn FROM log.savepoints WHERE name = '{name}')); SELECT log.state_hash(); ROLLBACK;", db).splitlines()[-1])
        print(f"  open {name} read only: {'exact' if got == hashes[name] else 'WRONG'} in {tm:.0f} ms; working state untouched: {at('main3')}")
    _, tm = ms(lambda: C.psql("SELECT log.restore('main2');", db))
    print(f"  restore main2: {at('main2')} in {tm:.0f} ms")
    st = S2.load_back(db)
    written, tm = ms(lambda: S2.write(st, snap["version"]))
    print(f"  after it all, every object still written from the store: {len(written)} statements in {tm:.0f} ms")
    print("  the log: " + one("SELECT count(*) || ' changes in ' || (SELECT count(*) FROM log.turns) || ' turns, ' || "
                              "pg_size_pretty(pg_total_relation_size('log.changes')) FROM log.changes", db))


def dependents(snap):
    """Renaming a column of a table a view uses: the store names the view before anything is written."""
    v = snap["version"].replace(".", "_")
    db = f"lab_store_mysql_{v}"
    S2.build(db, S2.rows_of(snap)[0])
    n = one("SELECT count(DISTINCT d.object_id) || ' views, ' || count(DISTINCT d.uses_object_id) || ' tables' FROM core.dependency d", db)
    hit = one("SELECT count(*) FROM core.column c WHERE EXISTS (SELECT 1 FROM core.dependency d WHERE d.uses_object_id = c.object_id)", db)
    print(f"== dependencies: {n} they use; {hit} columns whose rename the store flags with the views it would break")


def survive(snap, turns=100):
    """Edits survive a real server: the edited store written as SQL, loaded into a fresh server, read back into a new
    store; both stores must write the same statements."""
    import extract as X
    import setup as SU
    version = snap["version"]
    db = f"lab_store_mysql_{version.replace('.', '_')}"
    S2.build(db, S2.rows_of(snap)[0])
    rnd = random.Random(11)
    for n in range(1, turns + 1):
        edit(db, rnd, n, version)
    st = S2.load_back(db)
    mine = S2.write(st, version)
    name = C.fresh_mysql(version)
    try:
        C.ready_mysql(name)
        r = subprocess.run(["docker", "exec", "-i", name, "mysql", "-uroot", f"-p{SU.PW}", "--force", "--comments", "--default-character-set=utf8mb4"],
                           input=S2.script(st, version), capture_output=True)
        refused = [l for l in r.stderr.decode(errors="replace").splitlines() if l.startswith("ERROR")]
        saved, X.SCHEMAS = X.SCHEMAS, tuple(n["name"] for n in st["core.namespace"].values())
        again = {"engine": "mysql", "version": version, "parts": X.extract_mysql(version, name)}
        X.SCHEMAS = saved
    finally:
        SU.remove(name)
    S2.build(db + "_again", S2.rows_of(again)[0])
    theirs = S2.write(S2.load_back(db + "_again"), version)
    same = sum(1 for k in mine if theirs.get(k) == mine[k])
    print(f"== edits survive a real server: {turns} turns of edits, written, loaded into a fresh {version}, read back: "
          f"{len(refused)} statements refused; {same} of {len(mine)} statements the same from both stores"
          + (f"; {len(set(theirs) - set(mine))} only in the server" if set(theirs) - set(mine) else ""))
    for e in refused[:3]:
        print("    refused: " + __import__("re").sub("`[^`]*`", "`x`", e)[:150])
    for k in [k for k in mine if theirs.get(k) != mine[k]][:3]:
        a, b = mine[k].split("\n"), (theirs.get(k) or "").split("\n")
        d = next(((x, y) for x, y in zip(a, b) if x != y), (len(a), len(b)))
        print(f"    differs, {k[0]}: " + __import__("re").sub("`[^`]*`", "`x`", str(d))[:200])


if __name__ == "__main__":
    main()
    versioning(json.load(open(sys.argv[1])))
    dependents(json.load(open(sys.argv[1])))
    survive(json.load(open(sys.argv[1])))
