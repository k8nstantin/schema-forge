#!/usr/bin/env python3
"""Install SchemaForge's locked schema on a PostgreSQL 18 cluster: one database, schema_forge.

It asks for the superuser's password, makes the service accounts (schema/accounts.py), then makes the one database,
schema_forge, loaded from the owner folders exactly as the locked dump loads it (tools/schema_dump.py): the cortex
(the workspace among it), the ui, then every engine and feature, each in its own namespace, as sf_owner, with every
rule in force. Every design people work on is rows of these tables: installing never makes one, and making one never
makes a database, a namespace or a table. Last it proves each service account logs in, and that none can change the
schema.

  python3 schema/install.py [--host H] [--port P] [--user postgres] [--fresh] [--accounts-file PATH]

  --fresh    first drop schema_forge (and any database an older install made, sf_*) and every sf_ role: it asks you to
             type DROP

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


DATABASE = "schema_forge"


def drop_everything(conn):
    dbs = A.ok(A.run(conn, f"SELECT string_agg(datname, ' ') FROM pg_database WHERE datname = '{DATABASE}' OR datname LIKE 'sf\\_%';"),
               "listing databases").split()
    roles = A.ok(A.run(conn, "SELECT string_agg(rolname, ' ') FROM pg_roles WHERE rolname LIKE 'sf\\_%';"), "listing roles").split()
    print(f"--fresh drops {len(dbs)} databases ({', '.join(dbs) or 'none'}) and {len(roles)} roles ({', '.join(roles) or 'none'}).")
    if not dbs and not roles:
        return
    if os.environ.get("SF_CONFIRM", "").upper() != "DROP" and input("type DROP to go on: ").strip().upper() != "DROP":
        raise SystemExit("nothing dropped")
    for db in dbs:
        A.ok(A.run(conn, f'DROP DATABASE "{db}" WITH (FORCE);'), f"dropping {db}")
    # what the roles own or were granted in any other database of the cluster goes first, database by database (pg_shdepend
    # names them); only then can a role go
    others = A.ok(A.run(conn, "SELECT string_agg(DISTINCT d.datname, ' ') FROM pg_shdepend s JOIN pg_database d ON d.oid = s.dbid "
                              "JOIN pg_roles r ON r.oid = s.refobjid WHERE r.rolname LIKE 'sf\\_%';"), "listing what the roles hold").split()
    owned = " ".join(f'DROP OWNED BY "{r}" CASCADE;' for r in sorted(roles, key=lambda r: r == "sf_owner"))
    for db in [d for d in others if d not in dbs]:
        A.ok(A.run(conn, owned, db), f"dropping what the roles hold in {db}")
    for role in sorted(roles, key=lambda r: r == "sf_owner"):  # the owner last: the others may hold its grants
        A.ok(A.run(conn, f'DROP OWNED BY "{role}" CASCADE; DROP ROLE "{role}";'), f"dropping {role}")


def install(conn):
    if A.ok(A.run(conn, f"SELECT count(*) FROM pg_database WHERE datname = '{DATABASE}';"), "checking") != "0":
        raise SystemExit(f"{DATABASE} is installed already: run with --fresh to install it again")
    owners = SD.databases()[DATABASE]
    A.ok(A.run(conn, f"CREATE DATABASE {DATABASE} OWNER sf_owner;"), f"making {DATABASE}")
    # the cluster's own databases: PostgreSQL lets every role connect to them; no service account needs to (a superuser,
    # the DBA, is not bound by it)
    A.ok(A.run(conn, "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC; REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;"),
         "keeping the service accounts out of postgres and template1")
    print("postgres and template1: no longer open to every role (CONNECT revoked from PUBLIC); a superuser is not bound by it")
    script = "BEGIN;\nSET ROLE sf_owner;\n" + "".join(sql + "\n" for o in owners for _, sql in SD.version_one(o)) + "COMMIT;\n"
    A.ok(A.run(conn, script, DATABASE), f"loading {DATABASE}")
    tables = A.ok(A.run(conn, "SELECT string_agg(n.nspname || ' ' || x.c, ', ' ORDER BY n.nspname) FROM (SELECT relnamespace, count(*) c "
                              "FROM pg_class WHERE relkind = 'r' GROUP BY 1) x JOIN pg_namespace n ON n.oid = x.relnamespace "
                              "WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema';", DATABASE), "counting")
    rules = A.ok(A.run(conn, "SELECT count(*) FROM pg_views WHERE viewname LIKE 'broken\\_%';", DATABASE), "counting rules")
    print(f"{DATABASE}: {tables}" + (f"; {rules} rules in force" if rules != "0" else ""))
    declared = A.ok(A.run(conn, "SELECT string_agg(engine || ': ' || v || ' versions, ' || k || ' kinds, ' || o || ' options', '; ' ORDER BY engine) FROM "
                                "(SELECT engine, (SELECT count(*) FROM cortex.engine_versions x WHERE x.engine = e.engine) v, "
                                "(SELECT count(*) FROM cortex.object_kinds x WHERE x.engine = e.engine) k, "
                                "(SELECT count(*) FROM cortex.option_declarations x WHERE x.engine = e.engine) o "
                                "FROM (SELECT engine FROM cortex.engine_versions UNION SELECT engine FROM cortex.object_kinds) e) d;", DATABASE),
                    "counting the engines' declarations")
    print(f"declared by the engines' seeds: {declared}")
    return [o["ns"] for o in owners]


def prove(conn, passwords, namespaces):
    """Each login account logs in; none can make a table in any namespace of the design."""
    failures = 0
    for role, pw in passwords.items():
        r = A.run(conn, "SELECT current_user;", DATABASE, user=role, password=pw)
        logged = r.returncode == 0 and r.stdout.strip() == role
        changed = [ns for ns in namespaces
                   if A.run(conn, f"CREATE TABLE {ns}.install_attempt (id bigint);", DATABASE, user=role, password=pw).returncode == 0]
        if not logged or changed:
            failures += 1
        print(f"  {role}: {'logs in' if logged else 'CANNOT LOG IN'}, "
              + (f"CHANGED THE SCHEMA in {', '.join(changed)}" if changed else f"cannot change the schema in any of {len(namespaces)} namespaces"))
    if failures:
        raise SystemExit(f"{failures} account checks failed")


def main():
    p = A.parser()
    p.description = "Install SchemaForge's locked schema: one database, schema_forge."
    p.add_argument("--fresh", action="store_true", help="drop schema_forge and every sf_ role first")
    args = p.parse_args()
    conn = A.connection(args)
    if args.fresh:
        drop_everything(conn)
    passwords = A.make_accounts(conn, args.accounts_file)
    print(f"service accounts {', '.join(A.LOGINS)} ready; their passwords are in {args.accounts_file} (mode 600)")
    namespaces = install(conn)
    prove(conn, passwords, namespaces)
    print("installed")


if __name__ == "__main__":
    sys.exit(main())
