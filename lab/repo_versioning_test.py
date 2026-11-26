"""The locked design's log at work: a snapshot imported as a turn, hundreds of turns of edits across the cortex and
engine_mysql and ui, savepoints, a locked version, a branch, switches, opens, a restore and a compare, every state checked
against its hash, the ui's rows among the design's; then what the coding agent's role may and may not do; then every
object written from the design.

  python3 lab/repo_versioning_test.py <snapshot.json> [turns]
"""
import json
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C  # noqa: E402
import repo_store as R  # noqa: E402

PLAIN = ("o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM cortex.partitionings p WHERE p.id = o.id) "
         "AND NOT EXISTS (SELECT 1 FROM cortex.constraints k WHERE k.kind = 'foreign' AND (k.object = o.id OR k.to_object = o.id)) "
         "AND NOT EXISTS (SELECT 1 FROM cortex.indexes i JOIN cortex.index_parts x ON x.\"index\" = i.id WHERE i.object = o.id AND x.expression IS NOT NULL) "
         "AND NOT EXISTS (SELECT 1 FROM cortex.dependencies d WHERE d.uses = o.id OR d.object = o.id)")
UNUSED = ("o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM cortex.constraints k WHERE k.to_object = o.id) "
          "AND NOT EXISTS (SELECT 1 FROM cortex.dependencies d WHERE d.uses = o.id) "
          "AND NOT EXISTS (SELECT 1 FROM cortex.objects t WHERE t.parent = o.id)")


def one(sql, db):
    return C.psql(sql, db).strip()


def attempt(sql, db):
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    return r.returncode == 0, next((l for l in r.stderr.splitlines() if l.startswith("ERROR")), "")[:110]


def edit(db, rnd, n, version):
    int_type = "int(11)" if version.startswith("5.") else "int"
    sql = [f"BEGIN; SELECT sf_log.begin_turn('edit {n}');"]
    for _ in range(rnd.randint(1, 5)):
        k, off = rnd.random(), rnd.randint(0, 40)
        if k < 0.2:
            sql.append(f"UPDATE cortex.objects SET comment = 'note {n}' WHERE id = (SELECT id FROM cortex.objects WHERE kind = 'table' ORDER BY id OFFSET {off} LIMIT 1);")
        elif k < 0.35:
            sql.append(f"UPDATE cortex.columns SET default_value = '''{rnd.randint(0, 99)}''' WHERE id = (SELECT id FROM cortex.columns "
                       f"WHERE type LIKE 'int%' AND generated_expression IS NULL AND id NOT IN (SELECT id FROM cortex.column_identities) ORDER BY id OFFSET {off} LIMIT 1);")
        elif k < 0.5:
            engine, row_format = rnd.choice(['InnoDB', 'MyISAM']), rnd.choice(['NULL', chr(39) + 'DYNAMIC' + chr(39)])
            where = f"WHERE id = (SELECT o.id FROM cortex.objects o WHERE {PLAIN} ORDER BY o.id OFFSET {off} LIMIT 1);"
            if R.LAYOUT == "options":  # layout B: the same facts, as the table's options
                sql.append(f"UPDATE cortex.objects SET options = options || jsonb_build_object('engine', '{engine}', 'row_format', {row_format}::text) {where}")
            else:
                sql.append(f"UPDATE engine_mysql.tables SET engine = '{engine}', row_format = {row_format} {where}")
        elif k < 0.65:
            sql.append(f"UPDATE cortex.columns SET name = name || '_{n}' WHERE id = (SELECT c.id FROM cortex.columns c JOIN cortex.objects o ON o.id = c.object "
                       f"WHERE o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM cortex.dependencies d WHERE d.uses = o.id) ORDER BY c.id OFFSET {off * 7} LIMIT 1);")
        elif k < 0.85:
            cols = rnd.randint(1, 4)
            name = f"lab_t{n}_{rnd.randint(0, 10**6)}"
            if R.LAYOUT == "options":  # layout B: the table's engine and collation are its options, from its database's
                head = f"""WITH t AS (INSERT INTO cortex.objects (design, namespace, kind, name, position, options)
                 SELECT (SELECT id FROM cortex.designs LIMIT 1), min(id::text)::uuid, 'table', '{name}', (SELECT max(position) + 1 FROM cortex.objects),
                        jsonb_build_object('engine', 'InnoDB', 'collation', (SELECT options->>'collation' FROM cortex.namespaces
                                           WHERE id = (SELECT min(id::text)::uuid FROM cortex.namespaces)))
                 FROM cortex.namespaces RETURNING id),"""
            else:
                head = f"""WITH t AS (INSERT INTO cortex.objects (design, namespace, kind, name, position)
                 SELECT (SELECT id FROM cortex.designs LIMIT 1), min(id::text)::uuid, 'table', '{name}', (SELECT max(position) + 1 FROM cortex.objects) FROM cortex.namespaces RETURNING id),
               m AS (INSERT INTO engine_mysql.tables (id, design, engine, "collation") SELECT t.id, (SELECT id FROM cortex.designs LIMIT 1), 'InnoDB', d."collation" FROM t, engine_mysql.databases d
                 WHERE d.id = (SELECT min(id::text)::uuid FROM cortex.namespaces) RETURNING id),"""
            sql.append(head + f"""
               c AS (INSERT INTO cortex.columns (design, object, position, name, type, nullable)
                 SELECT (SELECT id FROM cortex.designs LIMIT 1), t.id, g, 'c' || g, '{int_type}', g > 1 FROM t, generate_series(1, {cols}) g RETURNING id, position),
               i AS (INSERT INTO cortex.indexes (design, object, position, name, "unique", method) SELECT (SELECT id FROM cortex.designs LIMIT 1), t.id, 1, 'PRIMARY', true, 'BTREE' FROM t RETURNING id),
               p AS (INSERT INTO cortex.index_parts (design, "index", position, "column") SELECT (SELECT id FROM cortex.designs LIMIT 1), i.id, 1, c.id FROM i, c WHERE c.position = 1 RETURNING id),
               k AS (INSERT INTO cortex.constraints (design, object, name, kind, "index", position) SELECT (SELECT id FROM cortex.designs LIMIT 1), t.id, 'PRIMARY', 'primary', i.id, 1 FROM t, i RETURNING id)
               INSERT INTO cortex.constraint_columns (design, "constraint", position, "column") SELECT (SELECT id FROM cortex.designs LIMIT 1), k.id, 1, c.id FROM k, c WHERE c.position = 1;""")
        elif k < 0.93:
            # the ui, versioned like the design: an area and its objects, a perspective, pins, a note; names unique in the run
            tag = f"{n}_{rnd.randint(0, 10**9)}"
            sql.append(f"""WITH d AS (SELECT id FROM cortex.designs LIMIT 1),
                 a AS (INSERT INTO ui.subject_areas (design, name, position) SELECT d.id, 'area {tag}', (SELECT coalesce(max(position), 0) + 1 FROM ui.subject_areas) FROM d RETURNING id),
                 o AS (SELECT id FROM cortex.objects WHERE kind = 'table' AND id NOT IN (SELECT id FROM ui.object_places) ORDER BY id OFFSET {off} LIMIT 3),
                 pl AS (INSERT INTO ui.object_places (id, design, area) SELECT o.id, d.id, a.id FROM o, a, d RETURNING id),
                 p AS (INSERT INTO ui.custom_perspectives (design, name, position, made_by) SELECT d.id, 'view {tag}', (SELECT coalesce(max(position), 0) + 1 FROM ui.custom_perspectives), 'lab' FROM d RETURNING id),
                 m AS (INSERT INTO ui.perspective_members (design, perspective, object, position) SELECT d.id, p.id, o.id, row_number() OVER () FROM p, o, d RETURNING id),
                 pin AS (INSERT INTO ui.layout_pins (design, view, object, x, y) SELECT d.id, 'map/{tag}', o.id, {off}, {n} FROM o, d RETURNING id),
                 ppin AS (INSERT INTO ui.layout_pins (design, perspective, object, x, y) SELECT d.id, p.id, o.id, {n}, {off} FROM p, o, d RETURNING id)
               INSERT INTO ui.pinned_notes (design, object, position, text, written_by)
               SELECT d.id, o.id, (SELECT coalesce(max(position), 0) FROM ui.pinned_notes) + row_number() OVER (), 'check {n}', 'lab' FROM o, d;""")
        elif k < 0.95:
            # a perspective deleted: its members and its pins go with it
            sql.append(f"DELETE FROM ui.custom_perspectives WHERE id = (SELECT id FROM ui.custom_perspectives ORDER BY id OFFSET {off % 3} LIMIT 1);")
        else:
            sql.append(f"DELETE FROM cortex.objects WHERE id = (SELECT o.id FROM cortex.objects o WHERE {UNUSED} ORDER BY o.id OFFSET {off} LIMIT 1);")
    sql.append("SELECT sf_log.end_turn(); COMMIT;")
    C.psql("\n".join(sql), db)


def main():
    snap = json.load(open(sys.argv[1]))
    turns = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    version = snap["version"]
    db = f"lab_repo_mysql_{version.replace('.', '_')}"
    rows, _ = R.rows_of(snap)
    R.build(db)
    if R.MOVED:  # layout B: the engine tables' facts are options of their cortex rows
        import options_layout as OL
        rows = OL.to_options(rows, R.MOVED)
    # the design is a row of cortex.designs, made before its first turn; its engine's kinds are the engine's declaration
    C.psql("BEGIN;\n" + R.copy_sql("cortex.engine_versions", rows["cortex.engine_versions"]) + R.copy_sql("cortex.designs", rows["cortex.designs"]) + R.copy_sql("cortex.object_kinds", rows["cortex.object_kinds"]) + "COMMIT;", db)
    C.psql(open(os.path.join(HERE, "design", "repo_versioning.sql")).read() + f"\nSELECT sf_log.attach('{rows['cortex.designs'][0]['id']}');", db)
    t = time.time()
    C.psql("BEGIN; SELECT sf_log.begin_turn('import');\n"
           + "".join(R.copy_sql(k, rows[k]) for k in R.ORDER if rows.get(k) and k not in ("cortex.engine_versions", "cortex.designs", "cortex.object_kinds"))
           + "SELECT sf_log.end_turn(); COMMIT;", db)

    print(f"== mysql {version}: imported as one turn, {one('SELECT count(*) FROM cortex.row_changes', db)} rows logged ({time.time() - t:.1f}s)")

    hashes = {}

    def save(name):
        C.psql(f"SELECT sf_log.savepoint('{name}');", db)
        hashes[name] = one("SELECT sf_log.state_hash();", db)

    def at(name):
        return "exact" if one("SELECT sf_log.state_hash();", db) == hashes[name] else "WRONG"
    save("imported")
    rnd = random.Random(5)
    t = time.time()
    for n in range(1, turns + 1):
        edit(db, rnd, n, version)
        if n % (turns // 3) == 0:
            save(f"main{n // (turns // 3)}")
    print(f"  {turns} turns of edits across cortex, engine_mysql and ui ({time.time() - t:.0f}s)")
    h = one("SELECT sf_log.lock_version('v1');", db)
    print(f"  version 1 locked at main3: {'exact' if h == hashes['main3'] else 'WRONG'}")

    def timed(sql):
        t = time.time()
        return one(sql, db), (time.time() - t) * 1000
    moved, ms = timed("SELECT sf_log.branch('experiment', 'main1');")
    print(f"  branch experiment from main1: {moved} changes undone in {ms:.0f} ms; the design is main1's: {at('main1')}")
    for n in range(turns + 1, turns + turns // 2 + 1):
        edit(db, rnd, n, version)
    save("experiment1")
    for target, name in (("main", "main3"), ("experiment", "experiment1"), ("main", "main3")):
        moved, ms = timed(f"SELECT sf_log.switch('{target}');")
        print(f"  switch to {target}: {moved} changes in {ms:.0f} ms; the design is {name}'s: {at(name)}")
    for name in ("imported", "main2", "experiment1"):
        got, ms = timed(f"BEGIN; SELECT sf_log.move_to((SELECT turn FROM cortex.savepoints WHERE name = '{name}')); SELECT sf_log.state_hash(); ROLLBACK;")
        print(f"  open {name}, read only: {'exact' if got.splitlines()[-1] == hashes[name] else 'WRONG'} in {ms:.0f} ms; the design untouched: {at('main3')}")
    _, ms = timed("SELECT sf_log.restore('main2');")
    print(f"  restore main2 as a new turn: {at('main2')} in {ms:.0f} ms; turns kept: {one('SELECT count(*) FROM cortex.turns', db)}")
    C.psql("SELECT sf_log.switch('experiment');", db)
    print(f"  the branch untouched by the restore: {at('experiment1')}")
    C.psql("SELECT sf_log.switch('main');", db)
    diff = one("SELECT string_agg(what || ' ' || n, ', ') FROM (SELECT what, count(*) n FROM sf_log.compare('main1', 'main3') GROUP BY what) x", db)
    print(f"  compare main1 to main3: {diff}")
    forward = ("FROM cortex.row_changes c JOIN cortex.operations o ON o.id = c.operation JOIN cortex.turns t ON t.id = o.turn "
               "WHERE c.table_name LIKE 'ui.%' AND t.summary LIKE 'edit %'")
    print("  the ui's rows in the log: " + one("SELECT count(*) FROM cortex.row_changes WHERE table_name LIKE 'ui.%'", db)
          + "; ui rows removed by edits, with the objects and perspectives they belonged to: " + one(f"SELECT count(*) {forward} AND c.action = 'delete'", db)
          + "; custom perspectives' pins among them: "
          + one(f"SELECT count(*) {forward} AND c.action = 'delete' AND c.table_name = 'ui.layout_pins' AND c.before ->> 'perspective' IS NOT NULL", db))
    print("  the log: " + one("SELECT count(*) || ' row changes, ' || (SELECT count(*) FROM cortex.turns) || ' turns, ' || "
                              "pg_size_pretty(pg_total_relation_size('cortex.row_changes')) FROM cortex.row_changes", db))

    print("== the coding agent's role (sf_agent)")
    agent = [
        ("edits a design row inside a turn", True,
         "BEGIN; SELECT sf_log.begin_turn('agent'); SET LOCAL ROLE sf_agent; UPDATE cortex.objects SET notes = 'agent' "
         "WHERE id = (SELECT min(id::text)::uuid FROM cortex.objects); RESET ROLE; SELECT sf_log.end_turn(); COMMIT;"),
        ("pins a table on the canvas inside a turn", True,
         "BEGIN; SELECT sf_log.begin_turn('agent'); SET LOCAL ROLE sf_agent; INSERT INTO ui.layout_pins (design, view, object, x, y) "
         "VALUES ((SELECT id FROM cortex.designs LIMIT 1), 'map/agent', (SELECT min(id::text)::uuid FROM cortex.objects), 1, 1); RESET ROLE; SELECT sf_log.end_turn(); COMMIT;"),
        ("creates a table in the ui", False, "BEGIN; SET LOCAL ROLE sf_agent; CREATE TABLE ui.agent_attempt (id bigint); COMMIT;"),
        ("creates a table", False, "BEGIN; SET LOCAL ROLE sf_agent; CREATE TABLE cortex.agent_attempt (id bigint); COMMIT;"),
        ("alters a table", False, "BEGIN; SET LOCAL ROLE sf_agent; ALTER TABLE cortex.objects ADD COLUMN x int; COMMIT;"),
        ("drops a table", False, "BEGIN; SET LOCAL ROLE sf_agent; DROP TABLE cortex.views; COMMIT;"),
        ("rewrites the log", False, "BEGIN; SET LOCAL ROLE sf_agent; UPDATE cortex.row_changes SET after = NULL; COMMIT;"),
        ("deletes from the log", False, "BEGIN; SET LOCAL ROLE sf_agent; DELETE FROM cortex.turns WHERE parent IS NULL; COMMIT;"),
        ("changes a locked version", False, "BEGIN; SET LOCAL ROLE sf_agent; UPDATE cortex.locked_versions SET message = 'x'; COMMIT;"),
        ("changes what the engine declares", False, "BEGIN; SET LOCAL ROLE sf_agent; DELETE FROM cortex.object_kinds WHERE id = 'mysql/event'; COMMIT;"),
        ("makes or deletes a design", False, "BEGIN; SET LOCAL ROLE sf_agent; DELETE FROM cortex.designs; COMMIT;"),
        ("changes what a person chose to read", False,
         "BEGIN; SET LOCAL ROLE sf_agent; INSERT INTO cortex.read_scopes (design, everything, made_by) "
         "SELECT id, true, 'agent' FROM cortex.designs LIMIT 1; COMMIT;"),
    ]
    for label, want, sql in agent:
        ok, why = attempt(sql, db)
        # a refusal counts only when the database's own rights gave it: never a mistake in the statement
        right = ok == want and (want or "permission denied" in why or "must be owner" in why)
        print(f"  {'pass' if right else 'FAIL'}  {label}: {'allowed' if ok else 'refused (' + why + ')'}")

    feed(db)

    st = R.read_back(db)
    t = time.time()
    written = R.write(st, version)
    print(f"== after it all, every object written from the design: {len(written)} statements in {(time.time() - t) * 1000:.0f} ms")


def feed(db):
    """The change feed (decision work-from-memory): every ended turn numbered 1, 2, 3 in its design's commit order, a
    bell rung at commit with the design and the number, and two writers that take the same number kept in commit order."""
    print("== the change feed: turns.seq and the bell")
    nums = one("SELECT count(*) || ' ' || min(seq) || ' ' || max(seq) || ' ' || count(DISTINCT seq) || ' ' || "
               "bool_and(seq_order = end_order) FROM (SELECT seq, row_number() OVER (ORDER BY seq) seq_order, "
               "row_number() OVER (ORDER BY ended_at, seq) end_order FROM cortex.turns WHERE seq IS NOT NULL) x", db).split()
    n = int(nums[0])
    print(f"  {'pass' if nums[1:] == ['1', str(n), str(n), 'true'] else 'FAIL'}  {n} ended turns numbered 1 to {nums[2]}, no gap, "
          f"in the order they ended: {nums[4] == 'true'}")
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1"],
                       input="LISTEN schema_forge_turns;\nBEGIN; SELECT sf_log.begin_turn('bell');\n"
                             "UPDATE cortex.objects SET notes = 'bell' WHERE id = (SELECT min(id::text)::uuid FROM cortex.objects);\n"
                             "SELECT sf_log.end_turn(); COMMIT;\nSELECT 'after';\n", capture_output=True, text=True)
    heard = [l for l in (r.stdout + r.stderr).splitlines() if "schema_forge_turns" in l]
    want = one("SELECT design || ' ' || seq FROM cortex.turns WHERE seq = (SELECT max(seq) FROM cortex.turns)", db)
    print(f"  {'pass' if len(heard) == 1 and want in heard[0] else 'FAIL'}  a committed turn rings the bell once, after commit, "
          f"with its design and number: {heard[0].split('payload')[-1].split(' received')[0].strip() if heard else 'NOTHING HEARD'}")
    # two writers end a turn at once: the second takes the same number, waits for the first's commit, and is refused
    first = ("BEGIN; SELECT sf_log.begin_turn('first'); UPDATE cortex.objects SET notes = 'first' WHERE id = (SELECT min(id::text)::uuid FROM cortex.objects);\n"
             "SELECT sf_log.end_turn(); SELECT pg_sleep(2); COMMIT;\n")
    second = ("BEGIN; SELECT sf_log.begin_turn('second'); UPDATE cortex.objects SET notes = 'second' WHERE id = (SELECT max(id::text)::uuid FROM cortex.objects);\n"
              "SELECT sf_log.end_turn(); COMMIT;\n")
    cmd = ["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"]
    before = int(one("SELECT max(seq) FROM cortex.turns", db))
    a = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    a.stdin.write(first)
    a.stdin.close()
    time.sleep(0.7)
    t = time.time()
    b = subprocess.run(cmd, input=second, capture_output=True, text=True)
    waited = time.time() - t
    a.wait()
    again = subprocess.run(cmd, input=second, capture_output=True, text=True)
    order = one(f"SELECT string_agg(summary || '=' || seq, ' ' ORDER BY seq) FROM cortex.turns WHERE seq > {before}", db)
    ok = a.returncode == 0 and b.returncode != 0 and "duplicate key" in b.stderr and waited > 0.8 and again.returncode == 0 \
        and order == f"first={before + 1} second={before + 2}"
    print(f"  {'pass' if ok else 'FAIL'}  two writers ending a turn at once: the second waited {waited:.1f}s for the first's commit, "
          f"was refused ({'duplicate key' if 'duplicate key' in b.stderr else b.stderr.strip()[-80:] or 'NOT REFUSED'}), and took the next number again: {order}")


if __name__ == "__main__":
    main()
