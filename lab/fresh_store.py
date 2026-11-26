"""Our own PostgreSQL (sf-store) wiped and the locked design installed fresh: every database but postgres dropped, the
four roles made again, then the workspace's database and one schema database per engine, each loaded from the owner
folders exactly as the dumps load them (tools/schema_dump.py), as sf_owner, its rules enforced. A schema's database is
named from its own UUIDv7 (decision database-per-schema).

  python3 lab/fresh_store.py                every engine with a schema folder: a schema database for each
  python3 lab/fresh_store.py mysql          one engine's only
"""
import os
import subprocess
import sys

sys.dont_write_bytecode = True  # tools/ holds crates: a __pycache__ there would be taken for one
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import schema_dump as SD  # noqa: E402

SERVER = "sf-store"


def psql(db, sql):
    r = subprocess.run(["docker", "exec", "-i", SERVER, "psql", "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{db}: {r.stderr.strip()[-500:]}")
    return r.stdout.strip()


def main():
    all_dbs = SD.databases()
    engines = sys.argv[1:] or [k for k in all_dbs if k not in ("workspace", "usage")]
    for db in psql("postgres", "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'").split():
        psql("postgres", f'DROP DATABASE "{db}" WITH (FORCE);')
    for role in ("sf_agent", "sf_reader", "sf_service", "sf_owner"):
        psql("postgres", f"DROP ROLE IF EXISTS {role};")
    print("dropped every database but postgres, and the roles")
    psql("postgres", "CREATE ROLE sf_owner NOLOGIN; CREATE ROLE sf_service LOGIN; CREATE ROLE sf_agent LOGIN; CREATE ROLE sf_reader LOGIN;")
    plan = {"sf_workspace": all_dbs["workspace"]}
    for engine in engines:
        plan[f"sf_{psql('postgres', 'SELECT uuidv7();').replace('-', '')}"] = all_dbs[engine]
    for db, owners in plan.items():
        psql("postgres", f"CREATE DATABASE {db} OWNER sf_owner;")
        psql(db, "BEGIN;\nSET ROLE sf_owner;\n" + "".join(sql + "\n" for o in owners for _, sql in SD.version_one(o)) + "COMMIT;\n")
        tables = psql(db, "SELECT string_agg(n.nspname || ' ' || x.c, ', ' ORDER BY n.nspname) FROM (SELECT relnamespace, count(*) c FROM pg_class "
                          "WHERE relkind = 'r' GROUP BY 1) x JOIN pg_namespace n ON n.oid = x.relnamespace "
                          "WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'")
        rules = psql(db, "SELECT count(*) FROM pg_views WHERE viewname LIKE 'broken\\_%'")
        print(f"{db}: {tables}; {rules} rules")


if __name__ == "__main__":
    main()
