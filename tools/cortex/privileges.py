#!/usr/bin/env python3
"""Least privilege, read from the catalog and tried through the accounts themselves, on the cortex with two engines
plugged in:

  every account   LOGIN alone (the owner not even that), a member of no role, connects to schema_forge alone, makes no
                  temporary table, creates, alters or drops nothing, reads no password, touches no server file
  every table     exactly the privileges the policy gives each account (below), no more, no less
  every function  executed only where the policy says (undo by the app and the agent, the fence's check by all)
  the fence       an engine's account sees and writes its own engine's designs only; the app, the agent and the reader
                  see every design

  python3 tools/cortex/privileges.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.fixture import in_turn, installed, new_design  # noqa: E402

DECLARED = ("plugins", "plugin_tables", "engines", "engine_versions", "engine_flavors", "object_kinds", "schema_migrations")
MODEL = ("namespaces", "objects", "columns", "indexes", "index_parts", "constraints", "constraint_columns", "dependencies")
ACCOUNTS = ("sf_service", "sf_agent", "sf_reader", "sf_mysql", "sf_postgresql")


def policy(account, table):
    """The privileges the policy gives an account on a cortex table."""
    engine = account in ("sf_mysql", "sf_postgresql")
    if table in DECLARED or account == "sf_reader":
        return {"SELECT"}
    if table in MODEL:
        return {"SELECT", "INSERT", "UPDATE", "DELETE"}
    return {
        "designs": {"sf_service": {"SELECT", "INSERT", "UPDATE", "DELETE"}},
        "branches": {"sf_service": {"SELECT", "INSERT", "UPDATE", "DELETE"}},
        "turns": {"sf_service": {"SELECT", "INSERT", "UPDATE"}, "sf_agent": {"SELECT", "INSERT", "UPDATE"}, "engine": {"SELECT", "INSERT", "UPDATE"}},
        "operations": {"sf_service": {"SELECT", "INSERT"}, "sf_agent": {"SELECT", "INSERT"}, "engine": {"SELECT", "INSERT"}},
        "row_changes": {"sf_service": {"SELECT"}, "sf_agent": {"SELECT"}, "engine": set()},
        "locked_versions": {"sf_service": {"SELECT", "INSERT"}},
    }[table].get("engine" if engine else account, {"SELECT"})


FUNCTIONS = {"sf_service": {"cortex.owns_design(uuid,name)", "cortex.undo(uuid)"}, "sf_agent": {"cortex.owns_design(uuid,name)", "cortex.undo(uuid)"},
             "sf_reader": {"cortex.owns_design(uuid,name)"}, "sf_mysql": {"cortex.owns_design(uuid,name)"}, "sf_postgresql": {"cortex.owns_design(uuid,name)"}}


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)

    store = installed("sf-cortex-privileges")
    try:
        print("== what each account is")
        for line in store.value("SELECT string_agg(rolname || '|' || rolsuper || rolcreatedb || rolcreaterole || rolreplication || rolbypassrls || '|' || rolcanlogin "
                                "|| '|' || (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid), E'\\n' ORDER BY rolname) FROM pg_roles r WHERE rolname LIKE 'sf\\_%'").splitlines():
            name, attrs, login, member = line.split("|")
            check(attrs == "falsefalsefalsefalsefalse" and login == ("false" if name == "sf_owner" else "true") and member == "0",
                  f"{name}: {'no login' if name == 'sf_owner' else 'LOGIN'} alone, a member of no role")
        for a in ACCOUNTS:
            dbs = store.value(f"SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE datallowconn AND has_database_privilege('{a}', datname, 'CONNECT')")
            check(dbs == "schema_forge", f"{a} connects to schema_forge alone ({dbs})")
            temp = store.value(f"SELECT has_database_privilege('{a}', 'schema_forge', 'TEMPORARY')")
            check(temp == "f", f"{a} makes no temporary table")
            create = store.value(f"SELECT coalesce(string_agg(nspname, ' '), '') FROM pg_namespace WHERE has_schema_privilege('{a}', oid, 'CREATE')")
            check(create == "", f"{a} creates in no schema ({create or 'none'})")
        print("== every cortex table, against the policy")
        tables = store.value("SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class WHERE relnamespace = 'cortex'::regnamespace AND relkind = 'r'").split()
        for a in ACCOUNTS:
            wrong = []
            for t in tables:
                have = set(store.value(f"SELECT coalesce(string_agg(p, ' '), '') FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p "
                                       f"WHERE has_table_privilege('{a}', 'cortex.{t}', p)").split())
                if have != policy(a, t):
                    wrong.append(f"{t} has {sorted(have)} wants {sorted(policy(a, t))}")
            check(not wrong, f"{a}: {len(tables)} tables as the policy gives them" + ("" if not wrong else ": " + "; ".join(wrong[:5])))
        print("== the functions each may execute")
        for a in ACCOUNTS:
            fns = set(store.value(f"SELECT coalesce(string_agg(p.oid::regprocedure::text, ' '), '') FROM pg_proc p "
                                  f"WHERE p.pronamespace IN ('cortex'::regnamespace, 'engine_mysql'::regnamespace, 'engine_postgresql'::regnamespace) "
                                  f"AND has_function_privilege('{a}', p.oid, 'EXECUTE')").split())
            check(fns == FUNCTIONS[a], f"{a} executes {sorted(fns)}")
        print("== the fence between engines")
        m, mb = new_design(store, "shop_mysql", "mysql", "8.4", "percona")
        p, pb = new_design(store, "shop_pg", "postgresql", "18", "alloydb")
        store.sql(in_turn(m, mb, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{m}', 'shop', 1);"))
        store.sql(in_turn(p, pb, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{p}', 'public', 1);"))
        for acct, own, other in (("sf_mysql", m, p), ("sf_postgresql", p, m)):
            seen = store.value(f"BEGIN; SET ROLE {acct}; SELECT string_agg(name, ' ') FROM cortex.designs; COMMIT;")
            check(seen == ("shop_mysql" if acct == "sf_mysql" else "shop_pg"), f"{acct} sees its own engine's design only ({seen})")
            ob = mb if own == m else pb
            rc, _, _ = store.sql(in_turn(own, ob, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{own}', 'mine', 2);", role=acct), check=False)
            check(rc == 0, f"{acct} writes its own engine's design")
            xb = pb if other == p else mb
            rc, _, err = store.sql(in_turn(other, xb, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{other}', 'theirs', 3);", role=acct), check=False)
            check(rc != 0, f"{acct} may not write the other engine's design")
            n = store.value(f"BEGIN; SET ROLE {acct}; SELECT count(*) FROM cortex.namespaces WHERE design = '{other}'; COMMIT;")
            check(n == "0", f"{acct} reads none of the other engine's rows ({n})")
        for a in ("sf_service", "sf_agent", "sf_reader"):
            seen = store.value(f"BEGIN; SET ROLE {a}; SELECT count(*) FROM cortex.designs; COMMIT;")
            check(seen == "2", f"{a} sees every design ({seen} of 2)")
        print("== what no account may do")
        tries = [("make a table", "CREATE TABLE cortex.x (id int);"), ("drop a table", "DROP TABLE cortex.namespaces;"),
                 ("change a table", "ALTER TABLE cortex.objects ADD COLUMN x int;"), ("turn the fence off", "ALTER TABLE cortex.objects DISABLE ROW LEVEL SECURITY;"),
                 ("drop the history trigger", "DROP TRIGGER log_row ON cortex.objects;"), ("plug a plugin in", "SELECT cortex.plug_in('mysql');"),
                 ("declare an engine", "INSERT INTO cortex.engines (id, plugin, name) VALUES ('x', 'mysql', 'X');"),
                 ("read the passwords", "SELECT rolpassword FROM pg_authid;"), ("read a server file", "SELECT pg_read_file('postgresql.conf');"),
                 ("write a server file", "COPY (SELECT 1) TO '/tmp/sf_probe';"), ("make a role", "CREATE ROLE sf_x;"),
                 ("make itself more", "ALTER ROLE CURRENT_USER CREATEDB;")]
        for a in ACCOUNTS:
            took = [w for w, sql in tries if store.sql(f"BEGIN; SET ROLE {a}; {sql} ROLLBACK;", check=False)[0] == 0]
            check(not took, f"{a} may do none of {len(tries)} things beyond its rows" + ("" if not took else f" (it may: {', '.join(took)})"))
    finally:
        store.__exit__(None, None, None)
    print(f"{'pass' if not bad else 'FAIL'}  cortex privileges: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
