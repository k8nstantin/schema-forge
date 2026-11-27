#!/usr/bin/env python3
"""Installs schema_forge on a PostgreSQL 18 server (the local one by default), run by its superuser (the DBA):
the cortex and every engine package (engines/<engine>), each namespace with its two roles, and then locks it in by
checking the installed database is exactly the one the tools tested.

  1. asks the superuser's password (never stored, never printed); checks the server is PostgreSQL 18 and the user a
     superuser; stops before changing anything if schema_forge or any of its roles already exist, unless --fresh
  2. --fresh: drops schema_forge and every role an install made (cortex_*, engine_*_owner, engine_*_service, and the
     sf_ roles of the schema before the rebuild), after you type DROP
  3. makes the roles: cortex_owner and each engine's <namespace>_owner (no login), and the service accounts
     cortex_service, cortex_agent, cortex_reader and each engine's <namespace>_service, each with a strong random
     password written only to the accounts file (mode 600), never printed
  4. makes the one database schema_forge, closed to everyone but the service accounts; loads the cortex as
     cortex_owner; plugs every engine in (tools/sf/plugin.py: the five steps, each as its role)
  5. checks it: every table, comment, function and plug of the cortex and of each engine; each service account signs in
     to schema_forge and reaches no other database; and the lock: pg_dump --schema-only of the installed database
     equals schema/dump/schema_forge.sql, the dump of the database CI built and tested (tools/local/lock.py)

  python3 tools/local/install.py [--host 127.0.0.1] [--port 5432] [--user dba] [--fresh] [--accounts-file FILE]

SF_ROOT_PASSWORD gives the superuser's password without the prompt and SF_CONFIRM=DROP the confirmation, for tests.
"""
import getpass
import os
import secrets
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
from sf.plugin import engine_folders, install_all, package  # noqa: E402

ARGS = sys.argv[1:]


def arg(name, default):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


HOST, PORT, USER = arg("--host", "127.0.0.1"), arg("--port", "5432"), arg("--user", "dba")
ACCOUNTS_FILE = os.path.expanduser(arg("--accounts-file", "~/schema-forge-lab-private/local-accounts.env"))
PSQL = os.environ.get("PSQL") or shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
PG_DUMP = os.environ.get("PG_DUMP") or os.path.join(os.path.dirname(PSQL), "pg_dump")
CORTEX_SERVICE = ("cortex_service", "cortex_agent", "cortex_reader")
# every role an install made: the cortex's and each plugin's, named after their namespace; and the old schema's sf_ roles
MADE = r"rolname ~ '^(cortex_(owner|service|agent|reader)|engine_[a-z0-9_]+_(owner|service)|sf_[a-z_]+)$'"


class Local:
    """The server installed on, spoken to as the container tools speak to theirs."""

    def __init__(self, password):
        self.password = password

    def sql(self, text, db="schema_forge", user=None, password=None, check=True):
        r = subprocess.run([PSQL, "-h", HOST, "-p", PORT, "-U", user or USER, "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At", "-X"],
                           input=text, capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=password or self.password))
        if check and r.returncode:
            labels = [l[3:] for l in r.stdout.splitlines() if l.startswith("@@ ")]
            raise SystemExit(f"FAIL  {labels[-1] if labels else db}: {r.stderr.strip()[:400]}")
        return r.returncode, r.stdout, r.stderr

    def value(self, query, user=None):
        return self.sql(query)[1].strip()

    def dump(self):
        r = subprocess.run([PG_DUMP, "-h", HOST, "-p", PORT, "-U", USER, "--schema-only", "schema_forge"],
                           capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=self.password))
        if r.returncode:
            raise SystemExit(f"FAIL  pg_dump: {r.stderr.strip()[:400]}")
        return r.stdout


def main():
    password = os.environ.get("SF_ROOT_PASSWORD") or getpass.getpass(f"password of {USER} on {HOST}:{PORT}: ")
    db = Local(password)
    version, superuser = db.sql("SELECT current_setting('server_version_num') || ' ' || rolsuper FROM pg_roles WHERE rolname = current_user;",
                                db="postgres")[1].split()
    if not version.startswith("18"):
        raise SystemExit(f"FAIL  the store is PostgreSQL 18; this server is {version}: nothing changed")
    if superuser != "true":
        raise SystemExit(f"FAIL  {USER} is not a superuser: the install makes roles and acts as each namespace's owner: nothing changed")
    roles = db.sql(f"SELECT coalesce(string_agg(rolname, ' ' ORDER BY rolname), '') FROM pg_roles WHERE {MADE};", db="postgres")[1].split()
    there = db.sql("SELECT count(*) FROM pg_database WHERE datname = 'schema_forge';", db="postgres")[1].strip() == "1"
    if (roles or there) and "--fresh" not in ARGS:
        raise SystemExit(f"FAIL  {'schema_forge' if there else 'no database'} and {len(roles)} roles of an earlier install are here "
                         f"({', '.join(roles) or 'none'}): run with --fresh to drop them first: nothing changed")
    if "--fresh" in ARGS and (roles or there):
        print(f"--fresh drops {'the database schema_forge' if there else 'no database'} and {len(roles)} roles ({', '.join(roles) or 'none'}).")
        if os.environ.get("SF_CONFIRM") != "DROP" and input("type DROP to go on: ").strip() != "DROP":
            raise SystemExit("nothing dropped")
        db.sql("DROP DATABASE IF EXISTS schema_forge WITH (FORCE);", db="postgres")
        for r in roles:
            db.sql(f"DROP OWNED BY {r} CASCADE; DROP ROLE {r};", db="postgres")
        print(f"  dropped schema_forge and {len(roles)} roles")

    plugins = [package(f)[0]["namespace"] for f in engine_folders()]
    services = list(CORTEX_SERVICE) + [f"{ns}_service" for ns in plugins]
    secrets_out = {r: secrets.token_urlsafe(32) for r in services}
    db.sql("CREATE ROLE cortex_owner NOLOGIN;\n" + "".join(f"CREATE ROLE {r} LOGIN PASSWORD '{secrets_out[r]}';\n" for r in CORTEX_SERVICE), db="postgres")
    os.makedirs(os.path.dirname(ACCOUNTS_FILE), mode=0o700, exist_ok=True)
    fd = os.open(ACCOUNTS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("".join(f"{r.upper()}_PASSWORD={p}\n" for r, p in secrets_out.items()))
    print(f"  the service accounts' passwords are in {ACCOUNTS_FILE} (mode 600): {', '.join(services)}")
    db.sql("CREATE DATABASE schema_forge OWNER cortex_owner; REVOKE ALL ON DATABASE schema_forge FROM PUBLIC;"
           "GRANT CONNECT ON DATABASE schema_forge TO cortex_service, cortex_agent, cortex_reader;", db="postgres")
    # the service accounts reach schema_forge alone: the default databases are closed to PUBLIC (their owners keep them)
    db.sql("REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;", db="postgres")
    db.sql("REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE TEMPORARY ON DATABASE schema_forge FROM PUBLIC; GRANT CREATE ON DATABASE schema_forge TO cortex_owner;")
    cards = install_all(db, secrets_out)
    print(f"  installed the cortex and plugged in {', '.join(c['namespace'] for c in cards)}, each with its owner and service account")

    bad = []
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "cortex"))
    from load import check as check_cortex  # noqa: E402
    found, lines = check_cortex(db)
    bad += found
    for line in lines:
        print(f"  cortex: {line}")
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "mysql"))
    import importlib.util
    for card in cards:
        spec = importlib.util.spec_from_file_location("plugin_load", os.path.join(os.path.dirname(HERE), card["id"], "load.py"))
        if spec and os.path.exists(spec.origin):
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            found, lines = mod.check(db, card)
            bad += found
            for line in lines:
                print(f"  {card['namespace']}: {line}")
    for r in services:
        ok = db.sql("SELECT current_user;", user=r, password=secrets_out[r], check=False)[0] == 0
        reach = [d for d in ("postgres", "template1") if db.sql("SELECT 1;", db=d, user=r, password=secrets_out[r], check=False)[0] == 0]
        print(f"  {'pass' if ok and not reach else 'FAIL'}  {r} signs in to schema_forge{'' if not reach else ' and reaches ' + ', '.join(reach)}")
        if not ok or reach:
            bad.append(f"{r}: signs in {ok}, reaches {reach}")
    from lock import KEPT, compare  # noqa: E402
    diff = compare(db.dump())
    print(f"  {'pass' if not diff else 'FAIL'}  locked in: the installed database is exactly {os.path.relpath(KEPT, os.path.dirname(os.path.dirname(HERE)))}, the one CI tested"
          + ("" if not diff else f"\n{diff}"))
    if diff:
        bad.append("the installed database differs from the locked dump")
    for b in bad:
        print(f"  FAIL  {b}")
    print(f"{'pass' if not bad else 'FAIL'}  install on {HOST}:{PORT}: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
