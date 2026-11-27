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
from sf.fixture import in_turn, installed, new_design, plugin_turn  # noqa: E402

DECLARED = ("plugins", "plugin_tables", "engines", "engine_versions", "engine_flavors", "object_kinds", "schema_migrations")
MODEL = ("namespaces", "objects", "columns", "indexes", "index_parts", "constraints", "constraint_columns", "dependencies")
ENGINE_ACCOUNTS = ("engine_mysql_service", "engine_postgresql_service")
ACCOUNTS = ("cortex_service", "cortex_agent", "cortex_reader") + ENGINE_ACCOUNTS
OWNERS = ("cortex_owner", "engine_mysql_owner", "engine_postgresql_owner")


PLUGIN_READS = ("engines", "engine_versions", "engine_flavors", "object_kinds", "designs")


def policy(account, table):
    """The privileges the policy gives an account on a cortex table: the least each one's work needs."""
    engine = account in ENGINE_ACCOUNTS
    if engine:
        # a plugin's service account: its declarations and designs to read, the model to read and write, its operations
        # to add to the app's turn; nothing else
        if table in MODEL:
            return {"SELECT", "INSERT", "UPDATE", "DELETE"}
        return {"SELECT"} if table in PLUGIN_READS else {"SELECT", "INSERT"} if table == "operations" else set()
    if table in DECLARED or account == "cortex_reader":
        return {"SELECT"}
    if table in MODEL:
        return {"SELECT", "INSERT", "UPDATE", "DELETE"}
    return {
        "designs": {"cortex_service": {"SELECT", "INSERT", "UPDATE", "DELETE"}},
        "branches": {"cortex_service": {"SELECT", "INSERT", "UPDATE", "DELETE"}},
        "turns": {"cortex_service": {"SELECT", "INSERT", "UPDATE"}, "cortex_agent": {"SELECT", "INSERT", "UPDATE"}},
        "operations": {"cortex_service": {"SELECT", "INSERT"}, "cortex_agent": {"SELECT", "INSERT"}},
        "row_changes": {"cortex_service": {"SELECT"}, "cortex_agent": {"SELECT"}},
        "locked_versions": {"cortex_service": {"SELECT", "INSERT"}},
    }[table].get(account, {"SELECT"})


FUNCTIONS = {"cortex_service": {"cortex.designs_of(name)", "cortex.undo(uuid)"}, "cortex_agent": {"cortex.designs_of(name)", "cortex.undo(uuid)"},
             "cortex_reader": {"cortex.designs_of(name)"}, "engine_mysql_service": {"cortex.designs_of(name)"},
             "engine_postgresql_service": {"cortex.designs_of(name)"}}


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)

    store = installed("sf-cortex-privileges")
    try:
        print("== what each account is")
        roles = "', '".join(ACCOUNTS + OWNERS)
        for line in store.value("SELECT string_agg(rolname || '|' || rolsuper || rolcreatedb || rolcreaterole || rolreplication || rolbypassrls || '|' || rolcanlogin "
                                f"|| '|' || (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid), E'\\n' ORDER BY rolname) FROM pg_roles r WHERE rolname IN ('{roles}')").splitlines():
            name, attrs, login, member = line.split("|")
            owner = name in OWNERS
            check(attrs == "falsefalsefalsefalsefalse" and login == ("false" if owner else "true") and member == "0",
                  f"{name}: {'no login, owns its namespace' if owner else 'LOGIN'} alone, a member of no role")
        names = store.value(f"SELECT count(*) FROM pg_roles WHERE rolname IN ('{roles}')")
        check(names == str(len(ACCOUNTS + OWNERS)), f"every namespace's roles named after it: <namespace>_owner and <namespace>_service ({names} of {len(ACCOUNTS + OWNERS)})")
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
        for acct, own, other in (("engine_mysql_service", m, p), ("engine_postgresql_service", p, m)):
            seen = store.value(f"BEGIN; SET ROLE {acct}; SELECT string_agg(name, ' ') FROM cortex.designs; COMMIT;")
            check(seen == ("shop_mysql" if acct == "engine_mysql_service" else "shop_pg"), f"{acct} sees its own engine's design only ({seen})")
            ob = mb if own == m else pb
            rc, _, err = plugin_turn(store, own, ob, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{own}', 'mine', 2);", acct, check=False)
            check(rc == 0, f"{acct} writes its own engine's design, in the app's turn" + ("" if rc == 0 else f" ({err.strip()[:120]})"))
            xb = pb if other == p else mb
            rc, _, err = plugin_turn(store, other, xb, f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{other}', 'theirs', 3);", acct, check=False)
            check(rc != 0, f"{acct} may not write the other engine's design")
            rc, _, _ = store.sql(in_turn(own, ob, "SELECT 1;", role=acct), check=False)
            check(rc != 0, f"{acct} may not open or end a turn: the app does")
            n = store.value(f"BEGIN; SET ROLE {acct}; SELECT count(*) FROM cortex.namespaces WHERE design = '{other}'; COMMIT;")
            check(n == "0", f"{acct} reads none of the other engine's rows ({n})")
        for a in ("cortex_service", "cortex_agent", "cortex_reader"):
            seen = store.value(f"BEGIN; SET ROLE {a}; SELECT count(*) FROM cortex.designs; COMMIT;")
            check(seen == "2", f"{a} sees every design ({seen} of 2)")
        # the fence is worked out once per statement (decision fence-per-statement): the plan reads the fence's set once,
        # as a hashed subplan, an init plan or a semi-join, never a function call for every row
        plan = store.sql("BEGIN; SET ROLE engine_mysql_service; EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM cortex.objects; COMMIT;")[1]
        once = "designs_of" in plan and any(w in plan for w in ("hashed SubPlan", "InitPlan", "Semi Join"))
        check(once, "the fence is worked out once per statement, not for every row" + ("" if once else f": {' / '.join(l.strip() for l in plan.splitlines())}"))
        print("== each plugin's namespace: written by its own service account alone (no cross-engine writes)")
        body = lambda d, name, role: f"""
            INSERT INTO cortex.objects (design, engine, namespace, kind, name, position)
              SELECT '{d}', g.engine, n.id, 'table', '{name}', 9 FROM cortex.namespaces n JOIN cortex.designs g ON g.id = n.design WHERE n.design = '{d}' AND n.name IN ('shop', 'public');
            INSERT INTO {'engine_mysql' if d == m else 'engine_postgresql'}.tables (id, design, note)
              SELECT id, '{d}', 'by {role}' FROM cortex.objects WHERE design = '{d}' AND name = '{name}';"""
        rc, _, err = plugin_turn(store, m, mb, body(m, "orders", "engine_mysql_service"), "engine_mysql_service", check=False)
        check(rc == 0, "engine_mysql_service writes engine_mysql for a MySQL design" + ("" if rc == 0 else f" ({err.strip()[:120]})"))
        for role in ("cortex_service", "cortex_agent"):
            rc, _, _ = store.sql(in_turn(m, mb, body(m, f"by_{role}", role), role=role), check=False)
            check(rc != 0, f"{role} may not write engine_mysql")
        rc, _, _ = plugin_turn(store, m, mb, body(m, "by_pg", "engine_postgresql_service"), "engine_postgresql_service", check=False)
        check(rc != 0, "engine_postgresql_service may not write engine_mysql")
        for role in ("cortex_service", "cortex_agent", "cortex_reader"):
            n = store.value(f"BEGIN; SET ROLE {role}; SELECT count(*) FROM engine_mysql.tables; COMMIT;")
            check(n == "1", f"{role} reads engine_mysql ({n} of 1 rows)")
        rc, _, _ = store.sql("BEGIN; SET ROLE engine_postgresql_service; SELECT count(*) FROM engine_mysql.tables; COMMIT;", check=False)
        check(rc != 0, "engine_postgresql_service may not even read engine_mysql")
        logged = store.value(f"SELECT count(*) FROM cortex.row_changes WHERE design = '{m}' AND tab = 'engine_mysql.tables'")
        check(logged == "1", f"a plugin's row is logged like the cortex's ({logged} of 1)")
        print("== a plugin that is not a plug is refused")
        rc, _, err = store.sql("BEGIN; SET ROLE engine_mysql_owner; CREATE TABLE engine_mysql.stray (x int); ROLLBACK;"
                               "BEGIN; SET ROLE engine_mysql_owner; CREATE TABLE engine_mysql.stray (x int); RESET ROLE; SET ROLE cortex_owner; SELECT cortex.plug_in('mysql'); ROLLBACK;", check=False)
        check(rc != 0 and "not in cortex.plugin_tables" in err, "a table the plugin did not register is refused at plug-in")
        rc, _, _ = store.sql("BEGIN; SET ROLE engine_mysql_owner; ALTER TABLE cortex.objects ADD COLUMN x int; ROLLBACK;", check=False)
        check(rc != 0, "a plugin's owner may not change the cortex")
        rc, _, _ = store.sql("BEGIN; SET ROLE engine_mysql_owner; DROP TABLE engine_postgresql.tables; ROLLBACK;", check=False)
        check(rc != 0, "a plugin's owner may not touch another plugin")
        print("== what no account may do")
        tries = [("make a table", "CREATE TABLE cortex.x (id int);"), ("drop a table", "DROP TABLE cortex.namespaces;"),
                 ("change a table", "ALTER TABLE cortex.objects ADD COLUMN x int;"), ("turn the fence off", "ALTER TABLE cortex.objects DISABLE ROW LEVEL SECURITY;"),
                 ("drop the history trigger", "DROP TRIGGER log_row ON cortex.objects;"), ("plug a plugin in", "SELECT cortex.plug_in('mysql');"),
                 ("declare an engine", "INSERT INTO cortex.engines (id, plugin, name) VALUES ('x', 'mysql', 'X');"),
                 ("read the passwords", "SELECT rolpassword FROM pg_authid;"), ("read a server file", "SELECT pg_read_file('postgresql.conf');"),
                 ("write a server file", "COPY (SELECT 1) TO '/tmp/sf_probe';"), ("make a role", "CREATE ROLE stray_role;"),
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
