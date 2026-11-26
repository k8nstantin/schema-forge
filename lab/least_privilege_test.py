"""Least privilege: each service account holds what its job needs and nothing more, measured from PostgreSQL's catalog and
tried through the account itself, on a fresh install.

  sf_service  the app: reads everything; writes designs and their rows, the workspace, the reads people chose, and the
              log as it grows (new turns, operations and row changes; a turn's state as it ends or is decided); never
              rewrites history, never the engines' declarations, never what was migrated or locked
  sf_agent    the coding agent: reads everything; writes a design's rows; adds to the log; nothing else
  sf_reader   reads everything; writes nothing
  All three: no attribute past LOGIN (no superuser, createdb, createrole, replication, bypassrls), a member of no role,
  connect to schema_forge alone, no temporary tables, execute cortex.misfits alone, read no password, touch no server file.

  python3 lab/least_privilege_test.py --port 54399 --accounts-file FILE --root-password PASSWORD
"""
import os
import re
import subprocess
import sys

PSQL = "/opt/homebrew/opt/postgresql@18/bin/psql"
ARGS = sys.argv[1:]
PORT = ARGS[ARGS.index("--port") + 1]
ROOT = ARGS[ARGS.index("--root-password") + 1]
SECRET = {}
for line in open(os.path.expanduser(ARGS[ARGS.index("--accounts-file") + 1])):
    m = re.match(r"^\s*(?:export\s+)?([A-Z_]+)=(.*)$", line.strip())
    if m:
        SECRET[m.group(1)] = m.group(2).strip("'\"")
ROLES = ("sf_service", "sf_agent", "sf_reader")
LOG_GROWS = {"turns": {"SELECT", "INSERT", "UPDATE"}, "operations": {"SELECT", "INSERT"}, "row_changes": {"SELECT", "INSERT"}}
READ_ONLY_FOR_ALL = {"engine_versions", "engine_features", "catalog_sources", "object_kinds", "option_declarations", "engine_flavors",
                     "flavor_limits", "reference_kinds", "privilege_declarations", "schema_migrations"}
# what the agent reads and does not write (decision database-roles): the designs, the workspace, what a person chose to
# read, what was read and what was locked
AGENT_READS = {"designs", "workspace_identity", "workspace_parameters", "workspace_connections", "workspace_connection_values",
               "workspace_connection_tests", "workspace_connection_test_steps", "workspace_design_connections", "read_scopes",
               "read_scope_kinds", "read_scope_objects", "source_reads", "locked_versions"}


def q(user, password, db, sql):
    r = subprocess.run([PSQL, "-h", "127.0.0.1", "-p", PORT, "-U", user, "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"], input=sql,
                       capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=password))
    return r.returncode == 0, r.stdout.strip(), next((x for x in r.stderr.splitlines() if x.startswith("ERROR")), r.stderr.strip()[:160])


def root(sql, db="schema_forge"):
    ok, out, err = q("postgres", ROOT, db, sql)
    if not ok:
        raise SystemExit(f"as the superuser: {err}")
    return out


def expected(role, schema, table, of_a_design):
    """The privileges the policy gives a role on a table."""
    if role == "sf_reader":
        return {"SELECT"}
    if table in LOG_GROWS and schema == "cortex":
        return LOG_GROWS[table] if role == "sf_service" else {"SELECT", "INSERT"}
    if schema == "cortex" and table in READ_ONLY_FOR_ALL:
        return {"SELECT"}
    if role == "sf_agent" and schema == "cortex" and table in AGENT_READS:
        return {"SELECT"}
    if role == "sf_service" and schema == "cortex" and table == "locked_versions":
        return {"SELECT", "INSERT"}   # a version is locked once and stays as it was
    return {"SELECT", "INSERT", "UPDATE", "DELETE"}


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)
    print("== what each account is, from the catalog")
    for line in root("SELECT rolname || '|' || rolsuper || rolcreatedb || rolcreaterole || rolreplication || rolbypassrls || '|' || rolcanlogin || '|' "
                     "|| (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid) FROM pg_roles r WHERE rolname IN ('sf_service', 'sf_agent', 'sf_reader')").splitlines():
        name, attrs, login, member = line.split("|")
        check(attrs == "falsefalsefalsefalsefalse" and login == "true" and member == "0",
              f"{name}: LOGIN alone (no superuser, createdb, createrole, replication, bypassrls), a member of no role")
    print("== the databases each may reach")
    dbs = root("SELECT string_agg(datname, ' ') FROM pg_database WHERE datallowconn", "postgres").split()
    for role in ROLES:
        reach = [d for d in dbs if q(role, SECRET[f"{role.upper()}_PASSWORD"], d, "SELECT 1")[0]]
        check(reach == ["schema_forge"], f"{role} connects to schema_forge alone (reaches: {', '.join(reach)})")
        ok, _, _ = q(role, SECRET[f"{role.upper()}_PASSWORD"], "schema_forge", "CREATE TEMPORARY TABLE t (id int);")
        check(not ok, f"{role} makes no temporary table")
    print("== the functions each may execute")
    for role in ROLES:
        fns = root(f"""SELECT coalesce(string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1), '') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname IN ('cortex', 'ui', 'engine_mysql', 'engine_postgresql') AND has_function_privilege('{role}', p.oid, 'EXECUTE')""")
        check(fns == "cortex.misfits(uuid,text,text)", f"{role} executes cortex.misfits alone (executes: {fns or 'nothing'})")
    print("== every table, against the policy")
    tables = root("""SELECT string_agg(n.nspname || '.' || c.relname || ':' || EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'design'), ' ')
                     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('cortex', 'ui', 'engine_mysql', 'engine_postgresql')""").split()
    for role in ROLES:
        wrong = []
        for t in tables:
            name, design = t.split(":")
            schema, table = name.split(".")
            have = set(root(f"SELECT coalesce(string_agg(p, ' '), '') FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p "
                            f"WHERE has_table_privilege('{role}', '{name}', p)").split())
            want = expected(role, schema, table, design == "true" and table != "designs")
            if have != want:
                wrong.append(f"{name} has {sorted(have)} wants {sorted(want)}")
        check(not wrong, f"{role}: {len(tables)} tables as the policy gives them" + ("" if not wrong else ": " + "; ".join(wrong[:6])))
    print("== what no account may do")
    tries = [("read the passwords", "SELECT rolpassword FROM pg_authid;"), ("read a server file", "SELECT pg_read_file('postgresql.conf');"),
             ("write a server file", "COPY (SELECT 1) TO '/tmp/sf_probe';"), ("run a server program", "COPY (SELECT 1) TO PROGRAM 'true';"),
             ("make a role", "CREATE ROLE sf_x;"), ("make itself more", "ALTER ROLE CURRENT_USER CREATEDB;"),
             ("make another role more", "ALTER ROLE sf_reader SUPERUSER;"), ("make the owner sign in", "ALTER ROLE sf_owner LOGIN;"),
             ("rewrite the log", "UPDATE cortex.row_changes SET row_id = row_id;"), ("delete from the log", "DELETE FROM cortex.operations;")]
    for role in ROLES:
        for what, sql in tries:
            ok, _, err = q(role, SECRET[f"{role.upper()}_PASSWORD"], "schema_forge", f"BEGIN;\n{sql}\nROLLBACK;")
            check(not ok, f"{role} may not {what}" + ("" if not ok else " (it may)"))
    print("  note  as in every PostgreSQL, a role may change its own password and its own session defaults (ALTER ROLE CURRENT_USER SET ...): "
          "they bind that role alone and change no schema")
    print(f"{'pass' if not bad else 'FAIL'}  least privilege: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
