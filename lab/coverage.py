"""What the proofs leave unvetted: every capture the lab has, loaded side by side as designs of one schema_forge (MySQL
5.7 to 9.7, production and samples; PostgreSQL 15 to 18, the fixture and our own schema), then, for every table of the
locked design, how many rows the captures gave it; for every option an engine declares, how often it is set; for every
value an option may take, whether any capture took it; and for every kind an engine declares, how many objects are of it.
A table, option, value or kind no capture reaches is one no proof has vetted: it needs a scenario, or a reason to be.

  python3 lab/coverage.py
"""
import glob
import json
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import pg_store as P  # noqa: E402
import repo_pg_store as RP  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_coverage"
PRIVATE = os.path.expanduser("~/schema-forge-lab-private/out")


def main():
    R.build(DB)
    loaded = []
    for path in sorted(glob.glob(f"{HERE}/out/mysql-*.json")) + sorted(glob.glob(f"{PRIVATE}/mysql-*.json")):
        snap = json.load(open(path))
        rows, _ = R.rows_of(snap, f"{'production' if PRIVATE in path else 'sample'}-mysql-{snap['version']}")
        R.load(DB, rows)
        loaded.append(rows["cortex.designs"][0]["name"])
    for path in sorted(glob.glob(f"{HERE}/out/postgresql-*.json")) + sorted(glob.glob(f"{HERE}/out/self-postgresql-*.json")):
        snap = json.load(open(path))
        rows, _ = RP.to_locked(P.rows_of(snap), snap["version"], snap["parts"])
        rows["cortex.designs"][0]["name"] = f"{'ours' if 'self-' in path else 'fixture'}-postgresql-{snap['version']}"
        rows = RP.jsonish(R.OL.to_options(rows))
        C.psql("BEGIN;\nSET ROLE sf_service;\n" + "".join(R.copy_sql(k, rows[k]) for k in RP.ORDER if rows.get(k)) + "COMMIT;\n", DB)
        loaded.append(rows["cortex.designs"][0]["name"])
    print(f"== {len(loaded)} designs in one schema_forge: {', '.join(loaded)}")

    tables = C.psql("SELECT string_agg(n.nspname || '.' || c.relname, ' ' ORDER BY 1) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                    "WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'engine_mysql', 'engine_postgresql')", DB).split()
    counts = {t: int(C.psql(f"SELECT count(*) FROM {t}", DB)) for t in tables}
    workspace = [t for t in tables if t.startswith("cortex.workspace_")]
    log = {"cortex.branches", "cortex.turns", "cortex.operations", "cortex.row_changes", "cortex.savepoints", "cortex.locked_versions",
           "cortex.source_reads", "cortex.read_scopes", "cortex.read_scope_kinds", "cortex.read_scope_objects", "cortex.schema_migrations"}
    design = [t for t in tables if t not in workspace and t not in log and not t.startswith("ui.")]
    print("== the design's tables, by the rows the captures gave them")
    for t in design:
        print(f"  {'      ' if counts[t] else 'EMPTY '}{t}: {counts[t]}")
    print("  (the workspace's, the log's, the reads' and ui's tables are filled by the app, the versioning proof and the canvas, not by a capture)")

    print("== every declared option: how often set, per engine")
    decl = json.loads(C.psql("SELECT json_agg(d) FROM cortex.option_declarations d", DB))
    used = Counter()
    values = {}
    for part in sorted({d["part"] for d in decl}):
        for line in C.psql(f"SELECT e.engine || '|' || k.key || '|' || coalesce(k.value::text, 'null') FROM cortex.{part} p "
                           f"JOIN cortex.designs e ON e.id = p.design CROSS JOIN LATERAL jsonb_each(p.options) k", DB).splitlines():
            engine, key, value = line.split("|", 2)
            used[(engine, part, key)] += 1
            values.setdefault((engine, part, key), Counter())[value] += 1
    never = [d for d in decl if not used[(d["engine"], d["part"], d["name"])]]
    for engine in ("mysql", "postgresql"):
        ds = [d for d in decl if d["engine"] == engine]
        print(f"  {engine}: {sum(1 for d in ds if used[(engine, d['part'], d['name'])])} of {len(ds)} options set at least once")
    for d in never:
        print(f"  NEVER SET  {d['id']}: {d['about']}")
    print("== every declared value of an option with a list of values: taken or not")
    for d in decl:
        for c in d["choices"] or []:
            if not values.get((d["engine"], d["part"], d["name"]), {}).get(json.dumps(c)):
                print(f"  NEVER TAKEN  {d['id']} = {c}")
    print("== every declared kind of object: how many objects are of it")
    for line in C.psql("SELECT k.engine || '|' || k.kind || '|' || (SELECT count(*) FROM cortex.objects o JOIN cortex.designs d ON d.id = o.design "
                       "WHERE d.engine = k.engine AND o.kind = k.kind) FROM cortex.object_kinds k ORDER BY k.engine, k.position", DB).splitlines():
        engine, kind, n = line.split("|")
        print(f"  {'      ' if n != '0' else 'NONE  '}{engine}/{kind}: {n}")
    C.psql(f"DROP DATABASE {DB} WITH (FORCE);", "postgres")


if __name__ == "__main__":
    main()
