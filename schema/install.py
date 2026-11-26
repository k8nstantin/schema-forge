#!/usr/bin/env python3
"""Install SchemaForge's locked schema on a PostgreSQL 18 cluster.

It asks for the superuser's password, makes the service accounts (schema/accounts.py), then makes the workspace's
database (sf_workspace) and one schema database per engine, named from its own UUIDv7, each loaded from the owner
folders exactly as the locked dumps load them (tools/schema_dump.py): the cortex, the ui, then the engine, as sf_owner,
with every rule in force. Last it proves each service account logs in, and that none can change the schema.

  python3 schema/install.py [--host H] [--port P] [--user postgres] [--engine mysql ...] [--fresh] [--accounts-file PATH]

  --engine   an engine with a schema folder (engines/<engine>/schema); give it more than once; default: every one
  --fresh    first drop every SchemaForge database (sf_*) and role (sf_*) on the cluster: it asks you to type DROP

SF_ROOT_PASSWORD gives the superuser's password without the prompt, for automation; PSQL names the psql command
(default: psql).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # tools/ holds crates: a __pycache__ there would be taken for one
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
import accounts as A  # noqa: E402
import schema_dump as SD  # noqa: E402


def drop_everything(conn):
    dbs = A.ok(A.run(conn, "SELECT string_agg(datname, ' ') FROM pg_database WHERE datname LIKE 'sf\\_%';"), "listing databases").split()
    roles = A.ok(A.run(conn, "SELECT string_agg(rolname, ' ') FROM pg_roles WHERE rolname LIKE 'sf\\_%';"), "listing roles").split()
    print(f"--fresh drops {len(dbs)} databases ({', '.join(dbs) or 'none'}) and {len(roles)} roles ({', '.join(roles) or 'none'}).")
    if os.environ.get("SF_CONFIRM") != "DROP" and input("type DROP to go on: ").strip() != "DROP":
        raise SystemExit("nothing dropped")
    for db in dbs:
        A.ok(A.run(conn, f'DROP DATABASE "{db}" WITH (FORCE);'), f"dropping {db}")
    for role in sorted(roles, key=lambda r: r == "sf_owner"):  # the owner last: the others may hold its grants
        A.ok(A.run(conn, f'DROP OWNED BY "{role}" CASCADE; DROP ROLE "{role}";'), f"dropping {role}")


def install(conn, engines):
    all_dbs = SD.databases()
    unknown = [e for e in engines if e not in all_dbs or e in ("workspace",)]
    if unknown:
        raise SystemExit(f"no such engine: {', '.join(unknown)} (engines: {', '.join(k for k in all_dbs if k not in ('workspace', 'usage'))})")
    existing = A.ok(A.run(conn, "SELECT count(*) FROM pg_database WHERE datname = 'sf_workspace';"), "checking")
    plan = {} if existing == "1" else {"sf_workspace": all_dbs["workspace"]}
    if existing == "1":
        print("sf_workspace is there already: kept")
    for engine in engines:
        uid = A.ok(A.run(conn, "SELECT uuidv7();"), "an id")
        plan[f"sf_{uid.replace('-', '')}"] = all_dbs[engine]
    made = []
    for db, owners in plan.items():
        A.ok(A.run(conn, f"CREATE DATABASE {db} OWNER sf_owner;"), f"making {db}")
        script = "BEGIN;\nSET ROLE sf_owner;\n" + "".join(sql + "\n" for o in owners for _, sql in SD.version_one(o)) + "COMMIT;\n"
        A.ok(A.run(conn, script, db), f"loading {db}")
        tables = A.ok(A.run(conn, "SELECT string_agg(n.nspname || ' ' || x.c, ', ' ORDER BY n.nspname) FROM (SELECT relnamespace, count(*) c "
                                  "FROM pg_class WHERE relkind = 'r' GROUP BY 1) x JOIN pg_namespace n ON n.oid = x.relnamespace "
                                  "WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema';", db), "counting")
        rules = A.ok(A.run(conn, "SELECT count(*) FROM pg_views WHERE viewname LIKE 'broken\\_%';", db), "counting rules")
        print(f"{db}: {tables}; {rules} rules in force")
        made.append((db, owners[-1]["ns"]))
    return made


def prove(conn, passwords, made):
    """Each login account logs in; none can make a table in any namespace of the design."""
    failures = 0
    for db, ns in made:
        for role, pw in passwords.items():
            r = A.run(conn, "SELECT current_user;", db, user=role, password=pw)
            logged = r.returncode == 0 and r.stdout.strip() == role
            attempt = A.run(conn, f"CREATE TABLE {ns}.install_attempt (id bigint);", db, user=role, password=pw)
            refused = attempt.returncode != 0
            if not (logged and refused):
                failures += 1
            print(f"  {db} {role}: {'logs in' if logged else 'CANNOT LOG IN'}, "
                  f"{'cannot change the schema' if refused else 'CHANGED THE SCHEMA'}")
    if failures:
        raise SystemExit(f"{failures} account checks failed")


def main():
    p = A.parser()
    p.description = "Install SchemaForge's locked schema."
    p.add_argument("--engine", action="append", help="an engine to make a schema database for (default: every engine)")
    p.add_argument("--fresh", action="store_true", help="drop every SchemaForge database and role first")
    args = p.parse_args()
    conn = A.connection(args)
    if args.fresh:
        drop_everything(conn)
    passwords = A.make_accounts(conn, args.accounts_file)
    print(f"service accounts {', '.join(A.LOGINS)} ready; their passwords are in {args.accounts_file} (mode 600)")
    engines = args.engine or [k for k in SD.databases() if k not in ("workspace", "usage")]
    made = install(conn, engines)
    prove(conn, passwords, made)
    print("installed")


if __name__ == "__main__":
    sys.exit(main())
