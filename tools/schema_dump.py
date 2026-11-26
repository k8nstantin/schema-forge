"""The schema dump: what PostgreSQL itself holds once the locked design is loaded, kept in schema/dump/ (decision
schema-dump in specs/root.xml).

The one database the design makes, schema_forge, is loaded from the owners' folders on PostgreSQL 18 in Docker, in the
order the root's method schema gives (the cortex, the ui, then every engine and feature), and dumped with
pg_dump --schema-only into schema/dump/schema_forge.sql. A design session writes them
(`--write`) together with the lock; everything else compares (the default, run by tools/check.sh on every change and
every day by CI), so a database that no longer comes out as the design was locked fails, naming the file and the
first line that differs. The image is postgres/manifest.toml's [check] image.
"""
import difflib
import glob
import os
import re
import subprocess
import sys
import time
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMPS = os.path.join(ROOT, "schema", "dump")
IMAGE = tomllib.load(open(os.path.join(ROOT, "postgres", "manifest.toml"), "rb"))["check"]["image"]


def owner(root, folder, kind, oid):
    ns = f"engine_{oid}" if kind == "engine" else oid
    return {"root": root, "folder": folder, "kind": kind, "id": oid, "ns": ns}


CORTEX = owner("schema/cortex", "schema/cortex", "core", "cortex")
UI = owner("schema/ui", "schema/ui", "core", "ui")


def databases():
    """The one database the design makes, schema_forge: the cortex (the workspace among it), the ui, then every engine
    and feature, each in its namespace."""
    owners = [CORTEX, UI]
    for parent, kind in (("engines", "engine"), ("features", "feature")):
        for d in sorted(glob.glob(os.path.join(ROOT, parent, "*", "schema"))):
            oid = os.path.basename(os.path.dirname(d))
            owners.append(owner(f"{parent}/{oid}", f"{parent}/{oid}/schema", kind, oid))
    return {"schema_forge": owners}


def read(path):
    return open(os.path.join(ROOT, path), encoding="utf-8").read()


def files(folder):
    return sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, folder, "*.sql")))


def tables_in_order(o):
    """An owner's table files in the order of their foreign keys, ties by file name."""
    left = []
    for path in files(o["folder"]):
        text = read(path)
        if not re.search(r"^CREATE TABLE ", text, re.M):
            continue
        table = f'{o["ns"]}.{os.path.basename(path)[:-4]}'
        refs = {r for r in re.findall(r"REFERENCES\s+([a-z_]+\.[a-z_]+)", text) if r.startswith(o["ns"] + ".") and r != table}
        left.append((path, table, refs))
    done, out = set(), []
    while left:
        i = next((i for i, (_, _, refs) in enumerate(left) if refs <= done), 0)
        path, table, _ = left.pop(i)
        done.add(table)
        out.append(path)
    return out


def version_one(o):
    """An owner's version 1, as the root's method schema orders it: (path, SQL) in order."""
    ns, folder = o["ns"], o["folder"]
    parts = [(f'{o["root"]}/owner.toml', f"CREATE SCHEMA {ns};")]
    parts += [(p, read(p)) for p in tables_in_order(o)]
    if o["id"] == "cortex":
        parts += [(f"{folder}/{f}", read(f"{folder}/{f}")) for f in ("enforce_rules.sql", "check_options.sql", "check_kinds.sql", "check_references.sql", "misfits.sql", "notify_turns.sql", "grant_roles.sql")]
    parts += [(p, read(p)) for p in files(f"{folder}/rules")]
    parts.append((f"{folder}/rules", f"SELECT cortex.enforce_rules('{ns}');"))
    parts += [(p, read(p)) for p in files(f"{folder}/seeds")]
    parts.append((f'{o["root"]}/owner.toml', f"SELECT cortex.grant_roles('{ns}');"))
    return parts


def docker(*args, stdin=None):
    return subprocess.run(["docker", *args], input=stdin, capture_output=True, text=True)


def psql(name, db, script):
    r = docker("exec", "-i", name, "psql", "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At", stdin=script)
    if r.returncode:
        failed = [l[3:] for l in r.stdout.splitlines() if l.startswith("@@ ")]
        raise SystemExit(f"{failed[-1] if failed else db}: does not load: {r.stderr.strip()}")
    return r.stdout


def normal(dump):
    """A dump without what changes from run to run: the versions it names and pg_dump's random restrict key."""
    keep = [l for l in dump.splitlines()
            if not l.startswith(("-- Dumped from", "-- Dumped by", "\\restrict", "\\unrestrict"))]
    return "\n".join(keep).strip() + "\n"


def dumps():
    """Every database loaded in one container, and its dump, by name."""
    if docker("info").returncode:
        raise SystemExit("docker: not running")
    name = f"schema-forge-dump-{os.getpid()}"
    r = docker("run", "-d", "--rm", "--name", name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", IMAGE)
    if r.returncode:
        raise SystemExit(f"docker: {r.stderr.strip()}")
    try:
        for _ in range(240):
            logs = docker("logs", name)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and \
                    docker("exec", name, "psql", "-U", "postgres", "-c", "SELECT 1").returncode == 0:
                break
            time.sleep(0.25)
        else:
            raise SystemExit("docker: PostgreSQL did not answer within a minute")
        psql(name, "postgres", "CREATE ROLE sf_owner NOLOGIN; CREATE ROLE sf_service LOGIN; CREATE ROLE sf_agent LOGIN; CREATE ROLE sf_reader LOGIN;")
        out = {}
        for db, owners in databases().items():
            psql(name, "postgres", f"CREATE DATABASE {db} OWNER sf_owner;")
            script = "BEGIN;\nSET ROLE sf_owner;\n" + "".join(
                f"\\echo @@ {path}\n{sql}\n" for o in owners for path, sql in version_one(o)) + "COMMIT;\n"
            psql(name, db, script)
            r = docker("exec", name, "pg_dump", "-U", "postgres", "--schema-only", db)
            if r.returncode:
                raise SystemExit(f"pg_dump {db}: {r.stderr.strip()}")
            spaces = " and ".join(o["ns"] for o in owners)
            head = (f"-- schema/dump/{db}.sql: the schema-only pg_dump of the database {spaces} make, as the locked "
                    f"design gives it.\n-- Written by tools/schema_dump.py --write in a design session; tools/check.sh "
                    f"compares it on every change and CI every day (decision schema-dump).\n")
            out[db] = head + normal(r.stdout)
        return out
    finally:
        docker("rm", "-f", name)


def main():
    now = dumps()
    if "--write" in sys.argv:
        os.makedirs(DUMPS, exist_ok=True)
        for old in glob.glob(os.path.join(DUMPS, "*.sql")):
            if os.path.basename(old)[:-4] not in now:
                os.remove(old)
        for db, text in now.items():
            open(os.path.join(DUMPS, f"{db}.sql"), "w", encoding="utf-8").write(text)
        print(f"schema/dump: {len(now)} databases dumped")
        return 0
    wrong = []
    for db, text in now.items():
        path = os.path.join(DUMPS, f"{db}.sql")
        if not os.path.exists(path):
            wrong.append(f"schema/dump/{db}.sql: missing; a design session writes it")
            continue
        was = open(path, encoding="utf-8").read()
        if was != text:
            diff = [l for l in difflib.unified_diff(was.splitlines(), text.splitlines(), lineterm="", n=0)
                    if l[:1] in "+-" and not l.startswith(("+++", "---"))]
            wrong.append(f"schema/dump/{db}.sql: the database drifted from its dump: " + " | ".join(diff[:4]))
    for old in sorted(glob.glob(os.path.join(DUMPS, "*.sql"))):
        if os.path.basename(old)[:-4] not in now:
            wrong.append(f"{os.path.relpath(old, ROOT)}: no database of the design gives it")
    for w in wrong:
        print(w)
    print(f"schema dump: {len(now)} databases, {len(wrong)} drifted")
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main())
