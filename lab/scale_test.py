"""How the one database behaves as designs pile up: the same work timed with 1 design and with N, each a copy of a
production-size MySQL snapshot, on our PostgreSQL (sf-store), with the locked design loaded as the dump loads it
(decision work-from-memory: opening a design and catching up from the log are what the app does most).

  opening a design      every row of one design read and written out by the server (COPY to /dev/null), each table
                        reaching its design the way the schema lets it
  an import             one more design loaded into the store, as sf_service
  deleting a design     that design deleted, as sf_service: its rows go by cascade
  an edit               one row changed in a turn, the log recording it (lab/design/repo_versioning.sql)
  catching up           the log's changes of the last 1 and the last 100 turns of a design
  a branch switch       back 100 turns and forward again

Every time is the median of three runs, in milliseconds, measured by psql on the server's side of the connection.

  python3 lab/scale_test.py <snapshot.json> [N ...]      default N: 1 10
"""
import json
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import repo_store as R  # noqa: E402

NOT_A_DESIGN = {"cortex.designs", "cortex.engine_versions", "cortex.engine_features", "cortex.catalog_sources", "cortex.object_kinds",
                "cortex.schema_migrations", "cortex.option_declarations", "cortex.engine_flavors", "cortex.flavor_limits", "cortex.reference_kinds", "cortex.privilege_declarations"}
HISTORY = {"cortex.branches", "cortex.turns", "cortex.operations", "cortex.row_changes", "cortex.savepoints", "cortex.locked_versions",
           "cortex.source_reads"}


def psql(db, sql):
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-X", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{db}: {r.stderr.strip()[-600:]}")
    return r.stdout


def timed(db, sql):
    """The statements' own times, as psql's \\timing reports them, summed."""
    out = psql(db, "\\timing on\n" + sql)
    return sum(float(m) for m in re.findall(r"^Time: ([0-9.]+) ms", out, re.M))


def median(db, sql, runs=3):
    return statistics.median(timed(db, sql) for _ in range(runs))


def open_queries(db, design):
    """Every table holding a design's rows, each with the joins that reach its design."""
    tables = psql(db, "SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                      "WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'engine_mysql', 'engine_postgresql') ORDER BY 1").split()
    has_design = set(psql(db, "SELECT n.nspname || '.' || c.relname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
                              "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE a.attname = 'design' AND c.relkind = 'r'").split())
    fks = {}
    for line in psql(db, "SELECT c.conrelid::regclass, a.attname, c.confrelid::regclass, a.attnotnull FROM pg_constraint c "
                         "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] WHERE c.contype = 'f' "
                         "AND array_length(c.conkey, 1) = 1 ORDER BY a.attnotnull DESC, a.attnum").splitlines():
        t, col, ref, notnull = line.split("|")
        fks.setdefault(t, []).append((col, ref, notnull == "t"))
    out = {}
    for t in tables:
        if t in NOT_A_DESIGN or t in HISTORY or t.startswith("cortex.workspace_"):
            continue
        # the shortest chain of NOT NULL references from t to a table with a design column
        path, seen, frontier = None, {t}, [(t, [])]
        while frontier and path is None:
            nxt = []
            for cur, chain in frontier:
                if cur in has_design:
                    path = chain
                    break
                for col, ref, notnull in fks.get(cur, []):
                    if notnull and ref not in seen and ref not in NOT_A_DESIGN:
                        seen.add(ref)
                        nxt.append((ref, chain + [(cur, col, ref)]))
            frontier = nxt
        if path is None:
            raise SystemExit(f"{t} reaches no design")
        joins, alias = "", "t0"
        for i, (_, col, ref) in enumerate(path):
            joins += f' JOIN {ref} t{i + 1} ON t{i + 1}.id = {alias}."{col}"'
            alias = f"t{i + 1}"
        out[t] = f"SELECT t0.* FROM {t} t0{joins} WHERE {alias}.design = '{design}'"
    return out


def measure(snap, n):
    db = f"lab_scale_{n}"
    base, _ = R.rows_of(snap, "design-1")
    designs = [(base, None)] + [(R.twin(base, f"design-{i + 1}")[0], None) for i in range(1, n + 1)]
    R.build(db)
    t_import = []
    for i, (rows, _) in enumerate(designs[:n]):
        keep = rows if i == 0 else {k: v for k, v in rows.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")}
        t_import.append(R.load(db, keep) * 1000)
    first, last = designs[0][0]["cortex.designs"][0]["id"], designs[n - 1][0]["cortex.designs"][0]["id"]
    q = open_queries(db, first)
    loaded = sum(len(v) for k, v in designs[0][0].items() if k in q)
    got = int(psql(db, "SELECT " + " + ".join(f"(SELECT count(*) FROM ({s}) x)" for s in q.values()) + ";").strip())
    if got != loaded:
        raise SystemExit(f"opening read {got} rows of the {loaded} the design has")
    copy = lambda d: "".join(f"COPY ({s.replace(first, d)}) TO '/dev/null';\n" for s in q.values())  # noqa: E731
    res = {"designs": n, "rows of one design": loaded, "tables read to open one": len(q)}
    res["open the first design"] = median(db, copy(first))
    res["open the newest design"] = median(db, copy(last))

    # one more design imported, then deleted: as the store grows, before the log is attached
    extra = designs[n][0]
    extra = {k: v for k, v in extra.items() if k not in ("cortex.engine_versions", "cortex.object_kinds")}
    res["import one more design"] = R.load(db, extra) * 1000
    res["delete that design"] = timed(db, f"BEGIN;\nSET LOCAL ROLE sf_service;\nDELETE FROM cortex.designs WHERE id = '{extra['cortex.designs'][0]['id']}';\nCOMMIT;")

    # the log on the first design: 100 turns of one row each, then the edit, catching up and a switch timed
    psql(db, open(os.path.join(HERE, "design", "repo_versioning.sql")).read() + f"\nSELECT sf_log.attach('{first}');\n"
         "BEGIN; SELECT sf_log.begin_turn('start'); SELECT sf_log.end_turn(); COMMIT;\nSELECT sf_log.savepoint('start');")
    cols = psql(db, f"SELECT c.id FROM cortex.columns c JOIN cortex.objects o ON o.id = c.object JOIN cortex.namespaces s ON s.id = o.namespace "
                    f"WHERE s.design = '{first}' ORDER BY c.id LIMIT 101;").split()
    psql(db, "".join(f"BEGIN; SELECT sf_log.begin_turn('edit {k}'); UPDATE cortex.columns SET comment = 'edit {k}' WHERE id = '{c}'; "
                     f"SELECT sf_log.end_turn(); COMMIT;\n" for k, c in ((k, cols[k % len(cols)]) for k in range(100))))
    res["an edit: one row, one turn, logged"] = statistics.median(
        timed(db, f"BEGIN; SELECT sf_log.begin_turn('timed'); UPDATE cortex.columns SET comment = 'timed {k}' WHERE id = '{cols[-1]}'; "
                  f"SELECT sf_log.end_turn(); COMMIT;") for k in range(3))
    # catching up: the log's rows of the turns after the number the copy holds (decision work-from-memory)
    log = ("SELECT rc.* FROM cortex.turns t JOIN cortex.operations o ON o.design = t.design AND o.turn = t.id "
           "JOIN cortex.row_changes rc ON rc.design = o.design AND rc.operation = o.id "
           f"WHERE t.design = '{first}' AND t.seq > (SELECT max(seq) - {{k}} FROM cortex.turns WHERE design = '{first}')")
    res["catch up 1 turn from the log"] = median(db, f"COPY ({log.format(k=1)}) TO '/dev/null';")
    res["catch up 100 turns from the log"] = median(db, f"COPY ({log.format(k=100)}) TO '/dev/null';")
    res["branch switch across 100 turns"] = timed(db, "SELECT sf_log.branch('back', 'start');") / 2 + timed(db, "SELECT sf_log.switch('main');") / 2
    res["database size, MB"] = int(psql(db, "SELECT pg_database_size(current_database()) / 1048576;"))
    res["import times, ms"] = [round(x) for x in t_import]
    psql("postgres", f"DROP DATABASE {db} WITH (FORCE);")
    return res


def main():
    args = sys.argv[1:]
    snap = json.load(open(args[0]))
    sizes = [int(a) for a in args[1:]] or [1, 10]
    results = [measure(snap, n) for n in sizes]
    keys = [k for k in results[0] if k != "import times, ms"]
    w = max(len(k) for k in keys)
    print(f"{'':{w}}  " + "  ".join(f"{r['designs']:>10} design" + ("s" if r["designs"] > 1 else " ") for r in results))
    for k in keys[1:]:
        print(f"{k:{w}}  " + "  ".join(f"{r[k]:>17,.0f}" if isinstance(r[k], (int, float)) else f"{r[k]:>17}" for r in results))
    for r in results:
        print(f"imports into a store of {r['designs']}: {r['import times, ms']} ms")


if __name__ == "__main__":
    main()
