"""The lab's experiment: four ways to store MySQL's and PostgreSQL's schemas, built side by side in one PostgreSQL
database and judged on the same snapshots (lab/out/*.json).

  A  core + per-engine typed tables: shared attributes typed in the core, each engine's own in its own typed tables
  B  one wide table per concept: every attribute of every engine a column, the ones a part lacks left empty
  C  core + JSONB: shared attributes typed, each engine's own in one JSONB document per part
  D  core + property rows: shared attributes typed, each engine's own one row per property

  python3 lab/approaches.py [scale]      scale: how many times the snapshots are copied for the timing runs (200)
"""
import csv
import glob
import io
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from concepts import CONCEPT_OF, SHARED, split  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = "sf-pg-18"
DB = "lab"


def psql(sql, db=DB):
    r = subprocess.run(["docker", "exec", "-i", SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr.strip()[-600:])
    return r.stdout


def text(v):
    return v if isinstance(v, str) else json.dumps(v, sort_keys=True)


def snapshots():
    out = []
    for f in sorted(glob.glob(os.path.join(HERE, "out", "*.json"))):
        s = json.load(open(f))
        snap = f"{s['engine']}-{s['version']}"
        for p in s["parts"]:
            concept = CONCEPT_OF[s["engine"]][p["kind"]]
            shared, own = split(s["engine"], concept, p["props"])
            out.append({"snap": snap, "engine": s["engine"], "concept": concept, "kind": p["kind"], "key": p["key"],
                        "parent": p["parent"], "shared": {k: text(v) for k, v in shared.items() if v is not None},
                        "own": {k: text(v) for k, v in own.items() if v is not None}})
    return out


def q(name):
    return '"' + name.replace('"', '') + '"'


def plan(parts):
    """Per concept: its shared attributes, and each engine's own properties."""
    concepts = sorted({p["concept"] for p in parts})
    shared = {c: sorted(SHARED.get(c, {})) for c in concepts}
    own = {c: {e: sorted({k for p in parts if p["concept"] == c and p["engine"] == e for k in p["own"]}) for e in CONCEPT_OF}
           for c in concepts}
    return concepts, shared, own


CORE_COLS = ["id", "snap", "engine", "kind", "key", "parent"]


def ddl(concepts, shared, own):
    s = ["DROP SCHEMA IF EXISTS a, b, c, d CASCADE; CREATE SCHEMA a; CREATE SCHEMA b; CREATE SCHEMA c; CREATE SCHEMA d;"]
    core = lambda c: (", ".join(["id bigint PRIMARY KEY", "snap text NOT NULL", "engine text NOT NULL", "kind text NOT NULL",
                                  "key text NOT NULL", "parent text"] + [f"{q(a)} text" for a in shared[c]]))
    for c in concepts:
        for sch in "acd":
            extra = ", own jsonb" if sch == "c" else ""
            s.append(f"CREATE TABLE {sch}.{c} ({core(c)}{extra});")
        s.append(f"CREATE TABLE d.{c}_properties (id bigint REFERENCES d.{c} (id), key text NOT NULL, value text, PRIMARY KEY (id, key));")
        for e, props in own[c].items():
            if props:
                cols = ", ".join(f"{q(p)} text" for p in props)
                s.append(f"CREATE TABLE a.{e}_{c} (id bigint PRIMARY KEY REFERENCES a.{c} (id), {cols});")
        wide = [f"{q(e[:2] + '_' + p)} text" for e in own[c] for p in own[c][e]]
        s.append(f"CREATE TABLE b.{c} ({core(c)}" + (", " + ", ".join(wide) if wide else "") + ");")
    return "\n".join(s)


def copy(table, cols, rows):
    """COPY in CSV, a null written as \\N unquoted and every value quoted, so an empty string stays empty."""
    def cell(v):
        return "\\N" if v is None else '"' + str(v).replace('"', '""') + '"'
    body = "".join(",".join(cell(v) for v in r) + "\n" for r in rows)
    return f"COPY {table} ({', '.join(q(c) for c in cols)}) FROM STDIN WITH (FORMAT csv, NULL '\\N');\n{body}\\.\n"


def load(parts, concepts, shared, own):
    sql = []
    for c in concepts:
        rows = [p for p in parts if p["concept"] == c]
        base = lambda p: [p["id"], p["snap"], p["engine"], p["kind"], p["key"], p["parent"]] + [p["shared"].get(a) for a in shared[c]]
        cols = CORE_COLS + shared[c]
        for sch in "ad":
            sql.append(copy(f"{sch}.{c}", cols, [base(p) for p in rows]))
        sql.append(copy(f"c.{c}", cols + ["own"], [base(p) + [json.dumps(p["own"], sort_keys=True)] for p in rows]))
        sql.append(copy(f"d.{c}_properties", ["id", "key", "value"], [[p["id"], k, v] for p in rows for k, v in p["own"].items()]))
        for e, props in own[c].items():
            if props:
                er = [p for p in rows if p["engine"] == e]
                sql.append(copy(f"a.{e}_{c}", ["id"] + props, [[p["id"]] + [p["own"].get(k) for k in props] for p in er]))
        wide = [(e, k) for e in own[c] for k in own[c][e]]
        sql.append(copy(f"b.{c}", cols + [e[:2] + "_" + k for e, k in wide],
                        [base(p) + [p["own"].get(k) if p["engine"] == e else None for e, k in wide] for p in rows]))
    psql("".join(sql))


def back(concepts, shared, own):
    """Every part rebuilt from each approach: {approach: {id: (shared, own)}}."""
    out = {}
    for sch in "abcd":
        got = {}
        for c in concepts:
            attrs = ", ".join("t." + q(a) for a in shared[c]) or "NULL"
            if sch == "a":
                joins = " ".join(f"LEFT JOIN a.{e}_{c} {e[:2]} ON {e[:2]}.id = t.id" for e in own[c] if own[c][e])
                owns = " || ".join(f"coalesce(to_jsonb({e[:2]}) - 'id', '{{}}')" for e in own[c] if own[c][e]) or "'{}'::jsonb"
                sql = f"SELECT json_agg(json_build_object('id', t.id, 's', json_build_array({attrs}), 'o', {owns})) FROM a.{c} t {joins};"
            elif sch == "b":
                sql = f"SELECT json_agg(json_build_object('id', t.id, 's', json_build_array({attrs}), 'o', to_jsonb(t))) FROM b.{c} t;"
            elif sch == "c":
                sql = f"SELECT json_agg(json_build_object('id', t.id, 's', json_build_array({attrs}), 'o', t.own)) FROM c.{c} t;"
            else:
                sql = (f"SELECT json_agg(json_build_object('id', t.id, 's', json_build_array({attrs}), 'o', "
                       f"(SELECT coalesce(jsonb_object_agg(p.key, p.value), '{{}}') FROM d.{c}_properties p WHERE p.id = t.id))) FROM d.{c} t;")
            for r in json.loads(psql(sql) or "null") or []:
                s = {a: v for a, v in zip(shared[c], r["s"]) if v is not None}
                o = r["o"] or {}
                if sch == "b":
                    eng = o.get("engine")
                    o = {k[3:]: v for k, v in o.items() if k[:3] == eng[:2] + "_" and v is not None}
                o = {k: v for k, v in o.items() if v is not None}
                got[r["id"]] = (s, o)
        out[sch] = got
    return out


def main():
    scale = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    psql(f"SELECT 1", db="postgres")
    if psql(f"SELECT 1 FROM pg_database WHERE datname = '{DB}'", db="postgres").strip() != "1":
        psql(f"CREATE DATABASE {DB}", db="postgres")
    parts = snapshots()
    for i, p in enumerate(parts, 1):
        p["id"] = i
    concepts, shared, own = plan(parts)
    psql(ddl(concepts, shared, own))
    load(parts, concepts, shared, own)

    print("== 1. nothing lost: every part rebuilt from each approach")
    rebuilt = back(concepts, shared, own)
    for sch, got in rebuilt.items():
        lost = [p["key"] for p in parts if got.get(p["id"]) != ({k: v for k, v in p["shared"].items()}, p["own"])]
        print(f"  {sch}: {len(parts) - len(lost)} of {len(parts)} parts exact" + (f"; first lost: {lost[0]}" if lost else ""))

    print("== 2. a newer server version adds properties: schema changes each approach needs")
    for e in CONCEPT_OF:
        snaps = sorted({p["snap"] for p in parts if p["engine"] == e}, key=lambda s: [int(x) for x in s.split("-")[1].split(".")])
        seen, added = set(), []
        for s in snaps:
            props = {(p["concept"], k) for p in parts if p["snap"] == s for k in p["own"]}
            if seen:
                added += [(s, c, k) for c, k in sorted(props - seen)]
            seen |= props
        print(f"  {e}: {len(added)} properties appear in a later version ({', '.join(f'{c}.{k} in {s}' for s, c, k in added[:6])}{'…' if len(added) > 6 else ''})")
        print(f"     A and B: {len(added)} ALTER TABLE ADD COLUMN; C and D: none")

    print("== 3. the wide table's empty cells (B)")
    total = filled = 0
    for c in concepts:
        cols = [e[:2] + "_" + k for e in own[c] for k in own[c][e]]
        if not cols:
            continue
        n = int(psql(f"SELECT count(*) FROM b.{c};"))
        f = int(psql("SELECT " + " + ".join(f"count({q(x)})" for x in cols) + f" FROM b.{c};"))
        total += n * len(cols)
        filled += f
    print(f"  {filled} of {total} engine cells hold a value: {100 * (total - filled) / max(total, 1):.0f}% empty")

    print("== 4. undo: what changing one engine-specific option rewrites")
    sizes = json.loads(psql("SELECT json_build_object('avg', avg(pg_column_size(own)), 'max', max(pg_column_size(own))) FROM c.object;"))
    print(f"  A, B: one column value; D: one row's value; C: the part's whole document (objects: {sizes['avg']:.0f} bytes on average, {sizes['max']} at most)")

    print("== 5. a third engine: what it adds")
    own_concepts = sum(1 for c in concepts if any(own[c].values()))
    print(f"  A: its own typed tables in its own namespace (up to {own_concepts} here), the core untouched")
    print(f"  B: new columns on the shared tables: every engine's options in one table everyone edits")
    print(f"  C, D: no table changes at all; its options are data")

    print("== 6. the same questions in each approach, and their timing at scale")
    queries = {
        "every column with a default, any engine": {
            "a": "SELECT count(*) FROM a.column WHERE \"default\" IS NOT NULL",
            "b": "SELECT count(*) FROM b.column WHERE \"default\" IS NOT NULL",
            "c": "SELECT count(*) FROM c.column WHERE \"default\" IS NOT NULL",
            "d": "SELECT count(*) FROM d.column WHERE \"default\" IS NOT NULL"},
        "MySQL tables on MyISAM": {
            "a": "SELECT count(*) FROM a.mysql_object WHERE \"ENGINE\" = 'MyISAM'",
            "b": "SELECT count(*) FROM b.object WHERE \"my_ENGINE\" = 'MyISAM'",
            "c": "SELECT count(*) FROM c.object WHERE own->>'ENGINE' = 'MyISAM'",
            "d": "SELECT count(*) FROM d.object_properties WHERE key = 'ENGINE' AND value = 'MyISAM'"},
        "PostgreSQL GIN indexes": {
            "a": "SELECT count(*) FROM a.index WHERE method = 'gin'",
            "b": "SELECT count(*) FROM b.index WHERE method = 'gin'",
            "c": "SELECT count(*) FROM c.index WHERE method = 'gin'",
            "d": "SELECT count(*) FROM d.index WHERE method = 'gin'"},
        "objects with their every own property, one row each": {
            "a": "SELECT count(*) FROM (SELECT t.id, my, pg FROM a.object t LEFT JOIN a.mysql_object my ON my.id = t.id LEFT JOIN a.postgresql_object pg ON pg.id = t.id) x",
            "b": "SELECT count(*) FROM (SELECT * FROM b.object) x",
            "c": "SELECT count(*) FROM (SELECT id, own FROM c.object) x",
            "d": "SELECT count(*) FROM (SELECT t.id, jsonb_object_agg(p.key, p.value) FROM d.object t JOIN d.object_properties p ON p.id = t.id GROUP BY t.id) x"},
    }
    big = []
    n = len(parts)
    for k in range(scale):
        for p in parts:
            c = dict(p)
            c["id"] = p["id"] + (k + 1) * n
            c["key"] = f"{p['key']}#{k}"
            big.append(c)
    t = time.time()
    load(big, concepts, shared, own)
    print(f"  loaded {len(big) + n} parts in each approach ({time.time() - t:.1f}s for all four)")
    psql("VACUUM ANALYZE;")
    for sch in "abcd":
        size = psql(f"SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '{sch}' AND c.relkind = 'r';").strip()
        print(f"  {sch}: {size}")
    for name, by in queries.items():
        cells = []
        for sch in "abcd":
            t = time.time()
            for _ in range(3):
                psql(by[sch] + ";")
            cells.append(f"{sch} {(time.time() - t) / 3 * 1000:.0f} ms")
        print(f"  {name}: " + ", ".join(cells))


if __name__ == "__main__":
    main()
