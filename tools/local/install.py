#!/usr/bin/env python3
"""Installs the cortex on a PostgreSQL 18 server (the local one by default), as its owner runs it:

  1. asks the superuser's password (never stored, never printed)
  2. --fresh: drops schema_forge and every role it made (cortex_*, engine_*_owner and engine_*_service, and the sf_
     roles of the schema before the rebuild) first, after you type DROP
  3. makes the roles: cortex_owner (no login) and the service accounts cortex_service, cortex_agent, cortex_reader,
     each with a strong random password written only to the accounts file (mode 600), never printed
  4. makes the one database schema_forge, closed to everyone but them, and loads the cortex into it as cortex_owner
  5. checks what was installed, the way tools/cortex/load.py checks a container: every table, comment, function and
     plug; and that each service account signs in and reaches schema_forge alone

  python3 tools/local/install.py [--host 127.0.0.1] [--port 5432] [--user dba] [--fresh] [--accounts-file FILE]
"""
import getpass
import os
import secrets
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.schema import cortex_sql, script  # noqa: E402

ARGS = sys.argv[1:]


def arg(name, default):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


HOST, PORT, USER = arg("--host", "127.0.0.1"), arg("--port", "5432"), arg("--user", "dba")
ACCOUNTS_FILE = os.path.expanduser(arg("--accounts-file", "~/schema-forge-lab-private/local-accounts.env"))
PSQL = os.environ.get("PSQL") or shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
SERVICE = ("cortex_service", "cortex_agent", "cortex_reader")
# every role an install made: the cortex's and each plugin's, named after their namespace; and the old schema's sf_ roles
MADE = r"rolname ~ '^(cortex_(owner|service|agent|reader)|engine_[a-z0-9_]+_(owner|service)|sf_[a-z_]+)$'"


class Local:
    """The installed server, read the way the container tools read theirs."""

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


def main():
    password = os.environ.get("SF_ROOT_PASSWORD") or getpass.getpass(f"password of {USER} on {HOST}:{PORT}: ")
    db = Local(password)
    version = db.sql("SHOW server_version_num;", db="postgres")[1].strip()
    if not version.startswith("18"):
        raise SystemExit(f"FAIL  the store is PostgreSQL 18; this server is {version}")
    if "--fresh" in ARGS:
        roles = db.sql(f"SELECT string_agg(rolname, ' ') FROM pg_roles WHERE {MADE};", db="postgres")[1].split()
        there = db.sql("SELECT count(*) FROM pg_database WHERE datname = 'schema_forge';", db="postgres")[1].strip() == "1"
        print(f"--fresh drops {'the database schema_forge' if there else 'no database'} and {len(roles)} roles ({', '.join(roles) or 'none'}).")
        if os.environ.get("SF_CONFIRM") != "DROP" and input("type DROP to go on: ").strip() != "DROP":
            raise SystemExit("nothing dropped")
        db.sql("DROP DATABASE IF EXISTS schema_forge WITH (FORCE);", db="postgres")
        for r in roles:
            db.sql(f"DROP OWNED BY {r} CASCADE; DROP ROLE {r};", db="postgres")
        print(f"  dropped schema_forge and {len(roles)} roles")
    secrets_out = {r: secrets.token_urlsafe(32) for r in SERVICE}
    db.sql("CREATE ROLE cortex_owner NOLOGIN;\n" + "".join(f"CREATE ROLE {r} LOGIN PASSWORD '{p}';\n" for r, p in secrets_out.items()), db="postgres")
    os.makedirs(os.path.dirname(ACCOUNTS_FILE), mode=0o700, exist_ok=True)
    fd = os.open(ACCOUNTS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("".join(f"{r.upper()}_PASSWORD={p}\n" for r, p in secrets_out.items()))
    print(f"  made cortex_owner and {', '.join(SERVICE)}; their passwords are in {ACCOUNTS_FILE} (mode 600)")
    db.sql("CREATE DATABASE schema_forge OWNER cortex_owner; REVOKE ALL ON DATABASE schema_forge FROM PUBLIC;"
           "GRANT CONNECT ON DATABASE schema_forge TO cortex_service, cortex_agent, cortex_reader;", db="postgres")
    # the service accounts reach schema_forge alone: the default databases are closed to PUBLIC (their owners keep them)
    db.sql("REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;", db="postgres")
    print("  schema_forge is open to cortex_service, cortex_agent and cortex_reader alone; postgres and template1 are closed to PUBLIC")
    db.sql("REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE TEMPORARY ON DATABASE schema_forge FROM PUBLIC; GRANT CREATE ON DATABASE schema_forge TO cortex_owner;")
    db.sql(script(cortex_sql()))
    print("  loaded the cortex into schema_forge as cortex_owner")
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cortex"))
    from load import check  # noqa: E402
    bad, lines = check(db)
    for line in lines:
        print(f"  {line}")
    for r, p in secrets_out.items():
        ok = db.sql("SELECT current_user;", user=r, password=p, check=False)[0] == 0
        reach = [d for d in ("postgres", "template1") if db.sql("SELECT 1;", db=d, user=r, password=p, check=False)[0] == 0]
        print(f"  {'pass' if ok and not reach else 'FAIL'}  {r} signs in to schema_forge{'' if not reach else ' and reaches ' + ', '.join(reach)}")
        if not ok or reach:
            bad.append(f"{r}: signs in {ok}, reaches {reach}")
    for b in bad:
        print(f"  FAIL  {b}")
    print(f"{'pass' if not bad else 'FAIL'}  install on {HOST}:{PORT}: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
