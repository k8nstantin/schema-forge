"""What the lab's scripts share: our own PostgreSQL (the store), fresh servers to write a schema into, and comparing
what two servers hold.
"""
import os
import codecs
import re
import subprocess
import time

import setup as S

SOURCE_DB = S.SOURCE_DB
SERVER = "sf-store"  # our own PostgreSQL, apart from the test targets
DELIM = "$$sf$$"


def psql(sql, db):
    r = subprocess.run(["docker", "exec", "-i", SERVER, "psql", "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{db}: {r.stderr.strip()[-800:]}")
    return r.stdout.strip()


def mysql_latin1(err):
    """MySQL's latin1 is Windows-1252 with the five bytes it leaves undefined kept as themselves."""
    return bytes(ord(c) for c in err.object[err.start:err.end] if ord(c) < 256), err.end


codecs.register_error("mysql_latin1", mysql_latin1)
PY = {"latin1": "cp1252", "utf8": "utf-8", "utf8mb3": "utf-8", "utf8mb4": "utf-8", "ascii": "ascii", "binary": "latin-1"}


def lit(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"


def implicit_collate(definition):
    """8.0 and later remember whether a column's collation was written: SHOW CREATE TABLE writes an implicit one as
    COLLATE alone, an explicit one as CHARACTER SET and COLLATE. A COLLATE alone that is the table's default is left
    out, so the column takes it implicitly again, as it did."""
    table = re.search(r"\n\)(?: /\*!50100 TABLESPACE `(?:[^`]|``)+` \*/)? ENGINE=.*\bCOLLATE=(\w+)", definition)
    if not table:
        return definition
    def line_of(line):
        m = re.search(r" COLLATE (\w+)", line)  # the first is the column type's, before any default or expression
        if not line.startswith("  `") or not m or m.group(1) != table.group(1) or re.search(r"CHARACTER SET \w+$", line[:m.start()]):
            return line
        return line[:m.start()] + line[m.end():]
    return "\n".join(line_of(line) for line in definition.split("\n"))


def fresh_mysql(version):
    name = f"sf-mysql-{version}-roundtrip"
    S.remove(name)
    platform = ["--platform", "linux/amd64"] if version == "5.7" else []
    S.sh("docker", "run", "-d", "--name", name, *platform, "-e", f"MYSQL_ROOT_PASSWORD={S.PW}", f"mysql:{version}",
         "--event-scheduler=OFF", "--log-bin-trust-function-creators=1")
    return name


def ready_mysql(name):
    for _ in range(150):
        if S.sh("docker", "exec", name, "mysql", "-uroot", f"-p{S.PW}", "-e", "SELECT 1", check=False).returncode == 0:
            return
        time.sleep(2)
    raise SystemExit(f"{name} did not answer")


def schema_dump(container, schemas):
    """PostgreSQL's own word on a database's structure: pg_dump --schema-only of the schemas named, as statements,
    without the lines that differ between any two dumps (comments, SET, the restrict key)."""
    args = ["docker", "exec", container, "pg_dump", "-U", "postgres", "-d", SOURCE_DB, "--schema-only"] + [f"--schema={n}" for n in schemas]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    keep = "\n".join(l for l in out.split("\n") if l and not l.startswith(("--", "SET ", "SELECT pg_catalog.set_config", "\\restrict", "\\unrestrict")))
    return sorted(st.strip() for st in keep.split(";\n") if st.strip())


def dump_diff(source, rebuilt, schemas):
    """The statements pg_dump writes for one database and not the other: (only the source's, only the rebuilt's)."""
    from collections import Counter
    a, b = Counter(schema_dump(source, schemas)), Counter(schema_dump(rebuilt, schemas))
    return sorted((a - b).elements()), sorted((b - a).elements())


def fresh_pg(version):
    name = f"sf-pg-{version}-roundtrip"
    S.remove(name)
    S.sh("docker", "run", "-d", "--name", name, "-e", f"POSTGRES_PASSWORD={S.PW}", f"postgres:{version}-alpine")
    return name


def ready_pg(name):
    for _ in range(90):
        if S.sh("docker", "exec", name, "pg_isready", "-U", "postgres", "-q", check=False).returncode == 0:
            # the image's first server is a short-lived one that makes the cluster; wait for the real one to settle
            time.sleep(2)
            if S.sh("docker", "exec", name, "psql", "-U", "postgres", "-c", "SELECT 1", check=False).returncode == 0:
                S.sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", f"CREATE DATABASE {SOURCE_DB}")
                return
        time.sleep(1)
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
                if os.environ.get("LAB_SHOW_DIFFS"):
                    print(f"            {k[1]}.{pk}:\n              was {ia[k].get(pk)!r}\n              now {ib[k].get(pk)!r}")
    return diffs, len(ia)
