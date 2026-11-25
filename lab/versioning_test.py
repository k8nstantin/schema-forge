"""The lab's versioning test: a schema read from each engine (lab/out), stored in the global schema and its plugin's,
then worked on for hundreds of turns with savepoints, a locked version, a branch, switches, opens, restores and
compares; every state checked against the hash recorded when it was made.

  python3 lab/versioning_test.py [turns]      (300)
"""
import json
import os
import random
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from concepts import CONCEPT_OF, SHARED, split  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = "sf-store"  # our own PostgreSQL, apart from the test targets
SNAPSHOTS = {"mysql": "mysql-8.4", "postgresql": "postgresql-18"}


def psql(sql, db):
    r = subprocess.run(["docker", "exec", "-i", SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{db}: {r.stderr.strip()[-800:]}")
    return r.stdout.strip()


def lit(v):
    return "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"


def text(v):
    return v if isinstance(v, str) else json.dumps(v, sort_keys=True)


def parts_of(engine, snap):
    """A snapshot's parts as (concept, part, shared, own), one per part: a part the catalog lists twice (a MySQL view
    is in TABLES and in VIEWS) is one, its properties merged; two parts of one concept under one key (a trigger and a
    table of the same name) each keep theirs, the second's id taking its kind."""
    merged = {}
    for p in snap["parts"]:
        concept = CONCEPT_OF[engine][p["kind"]]
        cls = "table" if p["kind"] == "view" else p["kind"]
        m = merged.setdefault((concept, cls, p["key"]), {"kind": p["kind"], "key": p["key"], "parent": p["parent"], "props": {}})
        m["props"].update(p["props"])
        if p["kind"] == "view":
            m["kind"] = "view"
    ids, parts = set(), []
    for (concept, _, _), p in merged.items():
        if (concept, p["key"]) in ids:
            p["key"] = f"{p['kind']}:{p['key']}"
        ids.add((concept, p["key"]))
        shared, own = split(engine, concept, p["props"])
        parts.append((concept, p, {k: text(v) for k, v in shared.items() if v is not None},
                      {k: v for k, v in own.items() if v is not None}))
    return parts


def build(engine, snap=None, db=None):
    """The engine's schema database: the global schema (core), its plugin's (engine_<engine>), the log, and the
    snapshot imported as the first turn."""
    db = db or f"lab_{engine}"
    psql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE); CREATE DATABASE {db};", "postgres")
    snap = snap or json.load(open(os.path.join(HERE, "out", f"{SNAPSHOTS[engine]}.json")))
    parts = parts_of(engine, snap)
    concepts = sorted({c for c, *_ in parts})
    ddl = ["CREATE SCHEMA core;", f"CREATE SCHEMA engine_{engine};"]
    for c in concepts:
        cols = ", ".join(f'"{a}" text' for a in sorted(SHARED.get(c, {})))
        ddl.append(f"CREATE TABLE core.{c} (id text PRIMARY KEY, kind text NOT NULL, parent text{', ' + cols if cols else ''});")
        own = sorted({k for cc, _, _, o in parts if cc == c for k in o})
        if own:
            types = {}
            for k in own:
                vals = [o[k] for cc, _, _, o in parts if cc == c and k in o]
                if all(isinstance(v, bool) for v in vals):
                    types[k] = "boolean"
                elif all(isinstance(v, int) and not isinstance(v, bool) for v in vals):
                    types[k] = "bigint"
                elif any(isinstance(v, (list, dict)) for v in vals):
                    types[k] = "jsonb"
                else:
                    types[k] = "text"
            cols = ", ".join(f'"{k}" {types[k]}' for k in own)
            ddl.append(f"CREATE TABLE engine_{engine}.{c}_options (id text PRIMARY KEY REFERENCES core.{c} (id) "
                       f"ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, {cols});")
    psql("\n".join(ddl) + "\n" + open(os.path.join(HERE, "design", "versioning.sql")).read()
         + "\nSELECT log.attach(); SELECT log.init('main');", db)
    rows = []
    for c, p, s, o in parts:
        attrs = sorted(SHARED.get(c, {}))
        cols = ["id", "kind", "parent"] + [a for a in attrs if a in s]
        vals = [p["key"], p["kind"], p["parent"]] + [s[a] for a in attrs if a in s]
        rows.append(f"INSERT INTO core.{c} ({', '.join(chr(34) + x + chr(34) for x in cols)}) VALUES ({', '.join(lit(v) for v in vals)});")
        if o:
            ocols = sorted(o)
            ovals = [lit(json.dumps(o[k]) if isinstance(o[k], (list, dict)) else o[k]) for k in ocols]
            rows.append(f"INSERT INTO engine_{engine}.{c}_options (id, {', '.join(chr(34) + k + chr(34) for k in ocols)}) VALUES ({lit(p['key'])}, {', '.join(ovals)});")
    psql("BEGIN; SELECT log.begin_turn('import'); " + "\n".join(rows) + " SELECT log.end_turn(); COMMIT;", db)
    return db, parts


def edit_turn(db, engine, rnd, n):
    """One turn of one to five changes, across the global schema and the plugin's: a comment, a default, an engine
    option, a new table with columns and options, a column removed."""
    ids = psql("SELECT json_build_object('o', (SELECT json_agg(id) FROM core.object WHERE kind IN ('table','relation')), "
               "'c', (SELECT json_agg(id) FROM core.column), "
               f"'oo', (SELECT json_agg(id) FROM engine_{engine}.object_options))", db)
    ids = json.loads(ids)
    opt_col = {"mysql": '"ENGINE"', "postgresql": '"relpersistence"'}[engine]
    sql = [f"BEGIN; SELECT log.begin_turn('edit {n}');"]
    for _ in range(rnd.randint(1, 5)):
        k = rnd.random()
        if k < 0.3 and ids["o"]:
            sql.append(f"UPDATE core.object SET comment = {lit('comment ' + str(rnd.random()))} WHERE id = {lit(rnd.choice(ids['o']))};")
        elif k < 0.5 and ids["c"]:
            sql.append(f"UPDATE core.column SET \"default\" = {lit(str(rnd.randint(0, 999)))}, comment = {lit('c' + str(n))} WHERE id = {lit(rnd.choice(ids['c']))};")
        elif k < 0.7 and ids["oo"]:
            sql.append(f"UPDATE engine_{engine}.object_options SET {opt_col} = {lit(rnd.choice(['InnoDB', 'MyISAM', 'p', 'u']))} WHERE id = {lit(rnd.choice(ids['oo']))};")
        elif k < 0.9:
            t = f"lab.t{n}_{rnd.randint(0, 10**6)}"
            sql.append(f"INSERT INTO core.object (id, kind, parent, name) VALUES ({lit(t)}, 'table', 'lab', {lit(t[4:])});")
            sql.append(f"INSERT INTO engine_{engine}.object_options (id, {opt_col}) VALUES ({lit(t)}, {lit('InnoDB' if engine == 'mysql' else 'p')});")
            for i in range(rnd.randint(1, 4)):
                sql.append(f"INSERT INTO core.column (id, kind, parent, name, position, type) VALUES ({lit(t + '.c' + str(i))}, 'column', {lit(t)}, 'c{i}', '{i + 1}', 'int');")
        elif ids["c"]:
            cid = rnd.choice(ids["c"])
            ids["c"].remove(cid)
            sql.append(f"DELETE FROM engine_{engine}.column_options WHERE id = {lit(cid)}; DELETE FROM core.column WHERE id = {lit(cid)};")
    sql.append("SELECT log.end_turn(); COMMIT;")
    psql("\n".join(sql), db)


def run(engine, turns, snap=None, db=None):
    rnd = random.Random(42)
    t0 = time.time()
    db, _ = build(engine, snap, db)
    hashes = {}
    def save(name):
        psql(f"SELECT log.savepoint('{name}');", db)
        hashes[name] = psql("SELECT log.state_hash();", db)
    save("imported")
    print(f"== {engine}: imported {snap['version'] if snap else SNAPSHOTS[engine]} ({time.time() - t0:.1f}s)")
    t = time.time()
    for n in range(1, turns + 1):
        edit_turn(db, engine, rnd, n)
        if n % (turns // 3) == 0:
            save(f"main{n // (turns // 3)}")
    print(f"  {turns} turns on main, savepoints main1 to main3 ({time.time() - t:.1f}s)")
    version = psql("SELECT log.lock_version('v1');", db)
    ok = lambda name: "exact" if psql("SELECT log.state_hash();", db) == hashes[name] else "WRONG"
    print(f"  version v1 locked at main3: its hash is main3's: {'exact' if version == hashes['main3'] else 'WRONG'}")

    t = time.time()
    moved = psql("SELECT log.branch('experiment', 'main1');", db)
    print(f"  branch experiment from main1: {moved} changes undone ({(time.time() - t) * 1000:.0f} ms); state is main1's: {ok('main1')}")
    for n in range(turns + 1, turns + turns // 2 + 1):
        edit_turn(db, engine, rnd, n)
    save("experiment1")
    for target, name in (("main", "main3"), ("experiment", "experiment1"), ("main", "main3")):
        t = time.time()
        moved = psql(f"SELECT log.switch('{target}');", db)
        print(f"  switch to {target}: {moved} changes moved ({(time.time() - t) * 1000:.0f} ms); state is {name}'s: {ok(name)}")

    for name in ("imported", "main2", "experiment1"):
        t = time.time()
        got = psql(f"BEGIN; SELECT log.move_to((SELECT turn FROM log.savepoints WHERE name = '{name}')); SELECT log.state_hash(); ROLLBACK;", db).splitlines()[-1]
        print(f"  open {name} read only: {'exact' if got == hashes[name] else 'WRONG'} ({(time.time() - t) * 1000:.0f} ms); "
              f"the working state untouched: {ok('main3')}")

    before = int(psql("SELECT count(*) FROM log.turns;", db))
    t = time.time()
    psql("SELECT log.restore('main2');", db)
    after = int(psql("SELECT count(*) FROM log.turns;", db))
    print(f"  restore main2 on main: {ok('main2')} ({(time.time() - t) * 1000:.0f} ms); history kept: {after - before} new turn, none removed")
    psql("SELECT log.switch('experiment');", db)
    print(f"  the branch untouched by the restore: {ok('experiment1')}")

    diff = psql("SELECT json_agg(json_build_object('what', what, 'n', n)) FROM (SELECT what, count(*) n FROM log.compare('main1', 'main3') GROUP BY what) x;", db)
    print(f"  compare main1 to main3: {', '.join(f'{d[chr(110)]} {d[chr(119)+chr(104)+chr(97)+chr(116)]}' for d in json.loads(diff or '[]'))}")
    size = psql("SELECT count(*) || ' changes in ' || (SELECT count(*) FROM log.turns) || ' turns, ' || pg_size_pretty(pg_total_relation_size('log.changes')) FROM log.changes;", db)
    print(f"  the log: {size}")


if __name__ == "__main__":
    turns = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    for engine in ("mysql", "postgresql"):
        run(engine, turns)
