"""The lab's round trip: the schema written back as SQL from the store alone (the global schema and the MySQL plugin's,
as lab/scale.py left them), loaded into a fresh server of the same version, read again, and compared with what the
original server gave, part by part and property by property. Nothing may differ.

Every program is written back under the context it was made in: its sql_mode, its character set and collation (the
text sent in that character set's bytes), its time zone, and its database.

  LAB_SCHEMAS=a,b LAB_OUT=~/private/out python3 lab/roundtrip.py     after lab/scale.py
"""
import codecs
import json
import re
import os
import subprocess
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract as X  # noqa: E402
import setup as S  # noqa: E402
import versioning_test as V  # noqa: E402

DELIM = "$$sf$$"


def mysql_latin1(err):
    """MySQL's latin1 is Windows-1252 with the five bytes it leaves undefined kept as themselves."""
    return bytes(ord(c) for c in err.object[err.start:err.end] if ord(c) < 256), err.end


codecs.register_error("mysql_latin1", mysql_latin1)
PY = {"latin1": "cp1252", "utf8": "utf-8", "utf8mb3": "utf-8", "utf8mb4": "utf-8", "ascii": "ascii", "binary": "latin-1"}


def q(n):
    return "`" + n.replace("`", "``") + "`"


def lit(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"


def from_store(db):
    """Namespaces and objects as the store holds them, each one row with its global and plugin properties."""
    out = {}
    for c in ("namespace", "object", "parameter"):
        sql = (f"SELECT coalesce(json_agg(to_jsonb(t) || coalesce(to_jsonb(o) - 'id', '{{}}')), '[]') FROM core.{c} t "
               f"LEFT JOIN engine_mysql.{c}_options o ON o.id = t.id;")
        out[c] = json.loads(V.psql(sql, db))
    return out


def broken(o):
    """A view the server itself says is broken (its table or a column it uses is gone): it cannot be created again."""
    return o["kind"] == "view" and "references invalid" in (o.get("comment") or "")


def implicit_collate(definition):
    """8.0 and later remember whether a column's collation was written: SHOW CREATE TABLE writes an implicit one as
    COLLATE alone, an explicit one as CHARACTER SET and COLLATE. A COLLATE alone that is the table's default is left
    out, so the column takes it implicitly again, as it did."""
    table = re.search(r"\) ENGINE=.*\bCOLLATE=(\w+)", definition)
    if not table:
        return definition
    def line_of(line):
        m = re.search(r" COLLATE (\w+)", line)  # the first is the column type's, before any default or expression
        if not line.startswith("  `") or not m or m.group(1) != table.group(1) or re.search(r"CHARACTER SET \w+$", line[:m.start()]):
            return line
        return line[:m.start()] + line[m.end():]
    return "\n".join(line_of(line) for line in definition.split("\n"))


def contexts(store):
    """{routine id: the collation its character parameters and result were made under}. A routine's parameters
    without a character set of their own take the current database's, not the routine's: a routine created while
    another database was current must be created with one of that collation current again."""
    out = {}
    for prm in store["parameter"]:
        if prm.get("COLLATION_NAME"):
            rid = prm["id"].rsplit(".", 1)[0]
            out.setdefault(rid, Counter())[prm["COLLATION_NAME"]] += 1
    for o in store["object"]:
        if o["kind"] == "routine" and o.get("COLLATION_NAME"):
            out.setdefault(o["id"], Counter())[o["COLLATION_NAME"]] += 1
    return {k: c.most_common(1)[0][0] for k, c in out.items()}


def script(store):
    """The SQL, as bytes: each statement in the character set its object was made in."""
    chunks = []

    def say(sql, charset="utf8mb4"):
        enc = PY.get(charset.split("_")[0], "utf-8")
        chunks.append(sql.encode(enc, errors="mysql_latin1" if enc == "cp1252" else "strict"))

    say("SET NAMES utf8mb4;\nSET SESSION innodb_strict_mode = 0;\nSET FOREIGN_KEY_CHECKS = 0;\n")
    collation = {}
    for n in sorted(store["namespace"], key=lambda r: r["name"]):
        collation[n["name"]] = n["DEFAULT_COLLATION_NAME"]
        say(f"CREATE DATABASE {q(n['name'])} DEFAULT CHARACTER SET {n['DEFAULT_CHARACTER_SET_NAME']} "
            f"COLLATE {n['DEFAULT_COLLATION_NAME']};\n")
    objs = store["object"]
    tables = [o for o in objs if o["kind"] == "table" and o.get("TABLE_TYPE") == "BASE TABLE"]
    for t in sorted(tables, key=lambda o: o["id"]):
        say(f"USE {q(t['parent'])};\nSET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO';\n{implicit_collate(t['definition'])};\n")
    order = {"view": 0, "routine": 1, "trigger": 2, "event": 3}
    progs = [o for o in objs if o["kind"] in order and not broken(o)]
    parent = {o["id"]: o["parent"] for o in objs}
    made_under = contexts(store)
    helpers = set()
    for o in sorted(progs, key=lambda o: (order[o["kind"]], o["id"])):
        ns = parent[o["parent"]] if o["kind"] == "trigger" else o["parent"]  # a trigger's parent is its table
        current = q(ns)
        under = made_under.get(o["id"])
        if under and under != collation.get(ns):
            current = q(f"sf_context_{under}")
            if under not in helpers:
                helpers.add(under)
                say(f"CREATE DATABASE {current} DEFAULT CHARACTER SET {under.split('_')[0]} COLLATE {under};\n")
        cs, coll = o.get("CHARACTER_SET_CLIENT") or "utf8mb4", o.get("COLLATION_CONNECTION") or "utf8mb4_general_ci"
        say(f"USE {current};\nSET SESSION sql_mode = {lit(o.get('__sql_mode') or '')};\n"
            + (f"SET SESSION time_zone = {lit(o['TIME_ZONE'])};\n" if o.get("TIME_ZONE") else "")
            + f"SET NAMES {cs} COLLATE {coll};\nDELIMITER {DELIM}\n")
        body = o["definition"]
        if current != q(ns):
            # SHOW CREATE does not name the routine's database: from another database it must
            body = re.sub(r"\b(PROCEDURE|FUNCTION) `", lambda m: f"{m.group(1)} {q(ns)}.`", body, count=1)
        say(body + DELIM + "\n", cs)
        say("DELIMITER ;\nSET NAMES utf8mb4;\n")
    for h in sorted(helpers):
        say(f"DROP DATABASE {q('sf_context_' + h)};\n")
    say("SET FOREIGN_KEY_CHECKS = 1;\n")
    return b"".join(chunks), [o["id"] for o in objs if broken(o)]


def fresh(version):
    name = f"sf-mysql-{version}-roundtrip"
    S.remove(name)
    platform = ["--platform", "linux/amd64"] if version == "5.7" else []
    S.sh("docker", "run", "-d", "--name", name, *platform, "-e", f"MYSQL_ROOT_PASSWORD={S.PW}", f"mysql:{version}",
         "--event-scheduler=OFF", "--log-bin-trust-function-creators=1")
    return name


def ready(name):
    for _ in range(150):
        if S.sh("docker", "exec", name, "mysql", "-uroot", f"-p{S.PW}", "-e", "SELECT 1", check=False).returncode == 0:
            return
        time.sleep(2)
    raise SystemExit(f"{name} did not answer")


def compare(a, b, skip=()):
    """{property: parts that differ}, with parts only one side has; the keys in skip left out."""
    ia = {(p["kind"], p["key"]): p["props"] for p in a if p["key"] not in skip}
    ib = {(p["kind"], p["key"]): p["props"] for p in b if p["key"] not in skip}
    diffs = {}
    for k in set(ia) | set(ib):
        if k not in ia or k not in ib:
            w = f"{k[0]} only in the {'fresh' if k in ib else 'original'} server"
            diffs[w] = diffs.get(w, 0) + 1
            continue
        for pk in set(ia[k]) | set(ib[k]):
            if ia[k].get(pk) != ib[k].get(pk):
                diffs[f"{k[0]}.{pk}"] = diffs.get(f"{k[0]}.{pk}", 0) + 1
    return diffs, len(ia)


def main():
    if not os.environ.get("LAB_SCHEMAS") or not os.environ.get("LAB_OUT"):
        raise SystemExit("LAB_SCHEMAS and LAB_OUT name the schemas and where their snapshots are")
    names = {v: fresh(v) for v, _ in X.MYSQL}
    failures = 0
    try:
        for version, _ in X.MYSQL:
            ready(names[version])
            db = f"lab_scale_mysql_{version.replace('.', '_')}"
            sql, unwritable = script(from_store(db))
            t = time.time()
            r = subprocess.run(["docker", "exec", "-i", names[version], "mysql", "-uroot", f"-p{S.PW}", "--force", "--comments",
                                "--default-character-set=utf8mb4"], input=sql, capture_output=True)
            refused = [l for l in r.stderr.decode(errors="replace").splitlines() if l.startswith("ERROR")]
            t_load = time.time() - t
            original = json.load(open(os.path.join(X.OUT, f"mysql-{version}.json")))["parts"]
            again = X.extract_mysql(version, names[version])
            diffs, n = compare(original, again, set(unwritable))
            ok = not refused and not diffs
            failures += not ok
            print(f"{'pass' if ok else 'FAIL'}  mysql {version}: {len(sql) // 1024} KB of SQL written from the store, loaded in "
                  f"{t_load:.1f}s, {len(refused)} statements refused; {n} parts compared, "
                  f"{sum(diffs.values())} properties differ"
                  + (f"; {len(unwritable)} broken views not written, as the server says they are broken" if unwritable else ""))
            for e in refused[:5]:
                print(f"        refused: {e[:160]}")
            for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:10]:
                print(f"        differs: {k} in {c} parts")
    finally:
        for name in names.values():
            S.remove(name)
    print(f"== {failures} servers failed")


if __name__ == "__main__":
    main()
