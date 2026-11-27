#!/usr/bin/env python3
"""QA of an installed schema_forge (the local one by default): the schema, every role and its permissions, and
engine_mysql, probed through the service accounts themselves with the passwords of the accounts file (no superuser's
password needed). Everything it makes is one QA design, deleted at the end even when a probe fails: the database is
left as it was.

  1. the roles: owners never sign in, service accounts do; no superuser, createdb, createrole, replication or
     bypassrls; members of no role; each service account reaches schema_forge alone, makes no temporary table, creates
     in no schema
  2. the grants: each account's privileges on every cortex and engine_mysql table, and the functions each may execute,
     exactly as the policy gives them
  3. behavior, tried as each account: the app makes a design and opens turns; engine_mysql_service writes its rows under
     the app's turn; the app and the agent cannot write engine_mysql; the reader writes nothing; a change outside a turn is
     refused; nobody rewrites the log; nobody creates, alters or drops a table, turns the fence off, drops a trigger or
     makes a role; the app undoes the plugin's turn exactly
  4. the flavors: an Aurora design of 8.4, a MyISAM table on Cloud SQL, a compression dictionary on MySQL, a library on
     an 8.4 design, each refused
  5. a round trip on the installed database: the MySQL 8.0 every-object sample read from a container, stored by
     engine_mysql_service in the app's turn, read back identical (needs Docker)
  6. the lock: pg_dump of the installed database, as cortex_reader, still equals schema/dump/schema_forge.sql

  python3 tools/local/qa.py [--host 127.0.0.1] [--port 5432] [--accounts-file FILE] [--no-roundtrip]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(TOOLS, "cortex"))
sys.path.insert(0, os.path.join(TOOLS, "mysql"))
sys.path.insert(0, os.path.join(ROOT, "engines", "mysql"))

ARGS = sys.argv[1:]


def arg(name, default):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


HOST, PORT = arg("--host", "127.0.0.1"), arg("--port", "5432")
ACCOUNTS_FILE = os.path.expanduser(arg("--accounts-file", "~/schema-forge-lab-private/local-accounts.env"))
PSQL = os.environ.get("PSQL") or shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
PG_DUMP = os.environ.get("PG_DUMP") or os.path.join(os.path.dirname(PSQL), "pg_dump")
SERVICES = ("cortex_service", "cortex_agent", "cortex_reader", "engine_mysql_service")
OWNERS = ("cortex_owner", "engine_mysql_owner")
PASSWORDS = {}


def load_passwords():
    for line in open(ACCOUNTS_FILE):
        m = re.match(r"^([A-Z_]+)_PASSWORD=(.*)$", line.strip())
        if m:
            PASSWORDS[m.group(1).lower()] = m.group(2)
    missing = [s for s in SERVICES if s not in PASSWORDS]
    if missing:
        raise SystemExit(f"FAIL  {ACCOUNTS_FILE} has no password for {', '.join(missing)}: run tools/local/install.py first")


def run(role, sql, db="schema_forge", check=True):
    """A script as a service account, in one transaction; returns (exit, stdout, stderr)."""
    r = subprocess.run([PSQL, "-h", HOST, "-p", PORT, "-U", role, "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At", "-X", "-1"],
                       input=sql, capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=PASSWORDS[role]))
    if check and r.returncode:
        raise SystemExit(f"FAIL  as {role}: {r.stderr.strip()[:400]}")
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def value(sql, role="cortex_reader"):
    return run(role, sql)[1]


class AsPlugin:
    """The installed database seen as engine_mysql_service, for the store's own SQL (stored.py's model shape)."""

    def value(self, query):
        return value(query, "engine_mysql_service")


def main():
    load_passwords()
    bad = []

    def check(ok, what, detail=""):
        print(f"  {'pass' if ok else 'FAIL'}  {what}" + ("" if ok or not detail else f" ({detail[:200]})"))
        if not ok:
            bad.append(what)

    import privileges as P  # the policy tools/cortex/privileges.py proves on containers, read here for the installed database
    print("== 1. the roles")
    roles = "', '".join(SERVICES + OWNERS)
    for line in value("SELECT string_agg(rolname || '|' || rolsuper || rolcreatedb || rolcreaterole || rolreplication || rolbypassrls || '|' || rolcanlogin "
                      f"|| '|' || (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid), E'\\n' ORDER BY rolname) FROM pg_roles r WHERE rolname IN ('{roles}')").splitlines():
        name, attrs, login, member = line.split("|")
        owner = name in OWNERS
        check(attrs == "falsefalsefalsefalsefalse" and login == ("false" if owner else "true") and member == "0",
              f"{name}: {'no login, owns its namespace' if owner else 'signs in'}; nothing more; a member of no role")
    for s in SERVICES:
        reach = [d for d in ("postgres", "template1") if run(s, "SELECT 1;", db=d, check=False)[0] == 0]
        temp = value(f"SELECT has_database_privilege('{s}', 'schema_forge', 'TEMPORARY')")
        create = value(f"SELECT coalesce(string_agg(nspname, ' '), '') FROM pg_namespace WHERE has_schema_privilege('{s}', oid, 'CREATE')")
        check(not reach and temp == "f" and not create, f"{s}: reaches schema_forge alone, no temporary tables, creates in no schema",
              f"reaches {reach}, temporary {temp}, creates in {create}")

    print("== 2. the grants, against the policy")
    cortex_tables = value("SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class WHERE relnamespace = 'cortex'::regnamespace AND relkind = 'r'").split()
    mysql_tables = value("SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class WHERE relnamespace = 'engine_mysql'::regnamespace AND relkind = 'r'").split()
    privs = "ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']"
    for s in SERVICES:
        wrong = []
        for t in cortex_tables:
            have = set(value(f"SELECT coalesce(string_agg(p, ' '), '') FROM unnest({privs}) p WHERE has_table_privilege('{s}', 'cortex.{t}', p)").split())
            if have != P.policy(s, t):
                wrong.append(f"cortex.{t} has {sorted(have)} wants {sorted(P.policy(s, t))}")
        for t in mysql_tables:
            have = set(value(f"SELECT coalesce(string_agg(p, ' '), '') FROM unnest({privs}) p WHERE has_table_privilege('{s}', 'engine_mysql.{t}', p)").split())
            want = {"SELECT", "INSERT", "UPDATE", "DELETE"} if s == "engine_mysql_service" else {"SELECT"}
            if have != want:
                wrong.append(f"engine_mysql.{t} has {sorted(have)} wants {sorted(want)}")
        check(not wrong, f"{s}: {len(cortex_tables)} cortex and {len(mysql_tables)} engine_mysql tables as the policy gives them", "; ".join(wrong[:4]))
        fns = set(value(f"SELECT coalesce(string_agg(p.oid::regprocedure::text, ' '), '') FROM pg_proc p WHERE p.pronamespace IN ('cortex'::regnamespace, "
                        f"'engine_mysql'::regnamespace) AND has_function_privilege('{s}', p.oid, 'EXECUTE')").split())
        want = P.FUNCTIONS.get(s, {"cortex.designs_of(name)"})
        check(fns == want, f"{s}: executes {sorted(fns)}", f"wants {sorted(want)}")

    print("== 3. behavior, tried as each account (in a QA design, deleted at the end)")
    qa = f"qa_{int(time.time())}"
    design = branch = None
    try:
        rc, out, err = run("cortex_service", f"INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('{qa}', 'mysql', '8.0', 'mysql') RETURNING id;"
                                             f"INSERT INTO cortex.branches (design, name) SELECT id, 'main' FROM cortex.designs WHERE name = '{qa}' RETURNING id;", check=False)
        check(rc == 0, "the app makes a design and its branch", err)
        design, branch = out.split()[:2]

        def app_turn(kind="edit"):
            return run("cortex_service", f"INSERT INTO cortex.turns (design, branch, kind, author) VALUES ('{design}', '{branch}', '{kind}', 'qa') RETURNING id;")[1]

        def commit(turn):
            run("cortex_service", f"UPDATE cortex.turns SET state = 'committed', ended_at = now() WHERE id = '{turn}';")

        def under_op(role, turn, body, check_=False):
            return run(role, f"WITH o AS (INSERT INTO cortex.operations (design, turn, position, kind, summary) "
                             f"VALUES ('{design}', '{turn}', (SELECT count(*) + 1 FROM cortex.operations WHERE turn = '{turn}'), 'qa', 'qa by {role}') RETURNING id) "
                             f"SELECT set_config('schema_forge.operation', id::text, true) FROM o;\n{body}", check=check_)

        t1 = app_turn("import")
        rc, _, err = under_op("cortex_service", t1, f"""
            INSERT INTO cortex.namespaces (design, name, position) VALUES ('{design}', 'server', 1);
            INSERT INTO cortex.namespaces (design, parent, name, position) SELECT '{design}', id, 'shop', 1 FROM cortex.namespaces WHERE design = '{design}' AND name = 'server';""")
        commit(t1)
        check(rc == 0, "the app writes the model in its turn", err)
        before = value(f"SELECT md5(coalesce(string_agg(to_jsonb(o)::text, ',' ORDER BY o.id), '')) FROM cortex.objects o WHERE design = '{design}'")
        t2 = app_turn()
        rc, _, err = under_op("engine_mysql_service", t2, f"""
            INSERT INTO cortex.objects (design, engine, namespace, kind, name, position)
              SELECT '{design}', 'mysql', id, 'table', 'qa_orders', 1 FROM cortex.namespaces WHERE design = '{design}' AND name = 'shop';
            INSERT INTO engine_mysql.tables (id, design, engine, "collation") SELECT id, '{design}', 'InnoDB', 'utf8mb4_0900_ai_ci' FROM cortex.objects WHERE design = '{design}' AND name = 'qa_orders';""")
        commit(t2)
        check(rc == 0, "engine_mysql_service writes the model and its own table under the app's turn", err)
        logged = value(f"SELECT count(*) FROM cortex.row_changes r JOIN cortex.operations o ON o.id = r.operation WHERE o.turn = '{t2}'")
        check(logged == "2", f"its two rows are logged ({logged} of 2)")
        for role in ("cortex_service", "cortex_agent"):
            t = app_turn()
            rc, _, _ = under_op(role, t, f"UPDATE engine_mysql.tables SET row_format = 'DYNAMIC' WHERE design = '{design}';")
            run("cortex_service", f"UPDATE cortex.turns SET state = 'rejected', ended_at = now() WHERE id = '{t}';")
            changed = value(f"SELECT count(*) FROM engine_mysql.tables WHERE design = '{design}' AND row_format IS NOT NULL")
            check(rc != 0 or changed == "0", f"{role} may not write engine_mysql")
        for what, sql in (("write the model", f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{design}', 'x', 9);"),
                          ("make a design", "INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('qa_x', 'mysql', '8.0', 'mysql');"),
                          ("write engine_mysql", f"DELETE FROM engine_mysql.tables WHERE design = '{design}';")):
            rc, _, _ = run("cortex_reader", sql, check=False)
            check(rc != 0, f"cortex_reader may not {what}")
        rc, _, _ = run("engine_mysql_service", f"INSERT INTO cortex.turns (design, branch, kind, author) VALUES ('{design}', '{branch}', 'edit', 'x');", check=False)
        check(rc != 0, "engine_mysql_service may not open a turn: the app does")
        rc, _, err = run("cortex_service", f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{design}', 'stray', 9);", check=False)
        check(rc != 0 and "outside an operation" in err, "a change outside an operation is refused")
        for role in ("cortex_service", "cortex_agent"):
            rc, _, _ = run(role, f"DELETE FROM cortex.row_changes WHERE design = '{design}';", check=False)
            check(rc != 0, f"{role} may not rewrite the log")
        tries = [("make a table", "CREATE TABLE cortex.qa_x (id int);"), ("drop a table", "DROP TABLE cortex.namespaces;"),
                 ("change a table", "ALTER TABLE engine_mysql.tables ADD COLUMN x int;"), ("turn the fence off", "ALTER TABLE cortex.objects DISABLE ROW LEVEL SECURITY;"),
                 ("drop the history trigger", "DROP TRIGGER log_row ON engine_mysql.tables;"), ("make a role", "CREATE ROLE qa_role;"),
                 ("plug a plugin in", "SELECT cortex.plug_in('mysql');"), ("read the passwords", "SELECT rolpassword FROM pg_authid;"),
                 ("declare a flavor", "INSERT INTO cortex.engine_flavors (id, engine, flavor, name) VALUES ('mysql/qa', 'mysql', 'qa', 'qa');")]
        for s in SERVICES:
            took = [w for w, sql in tries if run(s, sql, check=False)[0] == 0]
            check(not took, f"{s} may do none of {len(tries)} things beyond its rows", f"it may: {', '.join(took)}")
        t3 = app_turn("undo")
        rc, _, err = under_op("cortex_service", t3, f"SELECT cortex.undo('{t2}');")
        commit(t3)
        after = value(f"SELECT md5(coalesce(string_agg(to_jsonb(o)::text, ',' ORDER BY o.id), '')) FROM cortex.objects o WHERE design = '{design}'")
        left = value(f"SELECT count(*) FROM engine_mysql.tables WHERE design = '{design}'")
        check(rc == 0 and after == before and left == "0", "the app undoes the plugin's turn: its rows in the cortex and in engine_mysql gone, exactly", err)

        print("== 4. the flavors, refused on the installed database")
        rc, _, err = run("cortex_service", "INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('qa_aurora84', 'mysql', '8.4', 'aurora');", check=False)
        check(rc != 0 and "does not run" in err, "an Aurora design of MySQL 8.4 is refused")
        for flavor, version, what, body, expect in (
                ("cloudsql", "8.0", "a MyISAM table on Cloud SQL",
                 "INSERT INTO engine_mysql.tables (id, design, engine, \"collation\") SELECT id, design, 'MyISAM', 'utf8mb4_0900_ai_ci' FROM cortex.objects WHERE design = '{d}' AND name = 't';",
                 "refuses the storage engine MyISAM"),
                ("mysql", "8.0", "a compression dictionary on MySQL", None, "refuses a compression_dictionary"),
                ("mysql", "8.4", "a JavaScript library on an 8.4 design", None, "has no library")):
            name = f"qa_{flavor}_{version.replace('.', '')}_{int(time.time() * 1000) % 100000}"
            rc0, out, err0 = run("cortex_service", f"INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('{name}', 'mysql', '{version}', '{flavor}') RETURNING id;"
                                                   f"INSERT INTO cortex.branches (design, name) SELECT id, 'main' FROM cortex.designs WHERE name = '{name}' RETURNING id;")
            d, b = out.split()[:2]
            t = run("cortex_service", f"INSERT INTO cortex.turns (design, branch, kind, author) VALUES ('{d}', '{b}', 'edit', 'qa') RETURNING id;")[1]
            kind = "table" if body else ("compression_dictionary" if "dictionary" in what else "library")
            sql = (f"WITH o AS (INSERT INTO cortex.operations (design, turn, position, kind, summary) VALUES ('{d}', '{t}', 1, 'qa', 'qa') RETURNING id) "
                   f"SELECT set_config('schema_forge.operation', id::text, true) FROM o;"
                   f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{d}', 'server', 1);"
                   f"INSERT INTO cortex.objects (design, engine, namespace, kind, name, position) SELECT '{d}', 'mysql', id, '{kind}', 't', 1 FROM cortex.namespaces WHERE design = '{d}';"
                   + (body.replace("{d}", d) if body else ""))
            rc, _, err = run("engine_mysql_service", sql, check=False)
            check(rc != 0 and expect in err, f"{what} is refused", err)
            run("cortex_service", f"DELETE FROM cortex.designs WHERE id = '{d}';")

        print("== 5. a round trip on the installed database")
        if "--no-roundtrip" in ARGS:
            print("  note  skipped (--no-roundtrip)")
        else:
            import reader  # noqa: E402
            import roundtrip  # noqa: E402
            import rows  # noqa: E402
            from sf.servers import MySQL  # noqa: E402
            sys.argv = [sys.argv[0], "--server", "mysql:8.0"]
            with MySQL("mysql:8.0", name="sf-qa") as a:
                for f in roundtrip.samples("mysql:8.0"):
                    a.load(f)
                model = reader.read(a)
            # its own design, as an import makes one
            rt_name = f"{qa}_roundtrip"
            rt, rt_branch = run("cortex_service", f"INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('{rt_name}', 'mysql', '8.0', 'mysql') RETURNING id;"
                                                  f"INSERT INTO cortex.branches (design, name) SELECT id, 'main' FROM cortex.designs WHERE name = '{rt_name}' RETURNING id;")[1].split()[:2]
            sql, n = rows.insert_sql(model, rt)
            t4 = run("cortex_service", f"INSERT INTO cortex.turns (design, branch, kind, author) VALUES ('{rt}', '{rt_branch}', 'import', 'qa') RETURNING id;")[1]
            rc, _, err = run("engine_mysql_service", f"WITH o AS (INSERT INTO cortex.operations (design, turn, position, kind, summary) "
                                                     f"VALUES ('{rt}', '{t4}', 1, 'import', 'the sample') RETURNING id) "
                                                     f"SELECT set_config('schema_forge.operation', id::text, true) FROM o;\n{sql}", check=False)
            run("cortex_service", f"UPDATE cortex.turns SET state = '{'committed' if rc == 0 else 'rejected'}', ended_at = now() WHERE id = '{t4}';")
            check(rc == 0, f"the MySQL 8.0 every-object sample stored by engine_mysql_service in the app's turn ({n} rows)", err)
            if rc == 0:
                back = rows.model_from(json.loads(value(rows.select_sql(rt) + ";", "engine_mysql_service")))
                diff = roundtrip.differences(model, back)
                check(not diff, "read back from the installed database as engine_mysql_service: identical", "; ".join(diff[:3]))
    finally:
        for name in (qa, f"{qa}_roundtrip"):
            run("cortex_service", f"DELETE FROM cortex.designs WHERE name = '{name}';", check=False)
        left = value(f"SELECT count(*) FROM cortex.designs WHERE name LIKE 'qa\\_%'")
        print(f"  {'pass' if left == '0' else 'FAIL'}  the QA designs deleted: the database is as it was ({left} left)")
        if left != "0":
            bad.append("QA designs left")

    print("== 6. the lock")
    r = subprocess.run([PG_DUMP, "-h", HOST, "-p", PORT, "-U", "cortex_reader", "--schema-only", "schema_forge"],
                       capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=PASSWORDS["cortex_reader"]))
    from lock import compare  # noqa: E402
    diff = compare(r.stdout) if r.returncode == 0 else f"pg_dump as cortex_reader: {r.stderr.strip()[:200]}"
    check(not diff, "the installed database is still exactly schema/dump/schema_forge.sql", diff or "")

    print(f"{'pass' if not bad else 'FAIL'}  QA of schema_forge on {HOST}:{PORT}: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
