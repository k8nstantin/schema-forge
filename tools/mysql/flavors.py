#!/usr/bin/env python3
"""The flavors of engine_mysql that have no server to run here (Cloud SQL, Amazon RDS, Amazon Aurora), and what every
flavor refuses, proven through the store:

  refusals   each fact a flavor declares (cortex.engine_flavors refuses, from its provider's documentation) is tried on a
             design of that flavor and refused: by the cortex (a version it does not run, a kind it refuses) or by
             engine_mysql.check_flavor (a storage engine, a privilege, a table option, a database name, a flavor option
             it does not declare); and Percona's compression dictionary on a MySQL design
  allowed    the every-object sample read from MySQL 8.0, cut to what the flavor allows, is stored whole as a design of
             it by engine_mysql_service, read back identical, written into MySQL 8.0 and read again identical: a design
             of the flavor loads into the MySQL it is a subset of

Nothing here runs against the services themselves; their facts are their documentation's.

  python3 tools/mysql/flavors.py
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "engines", "mysql"))
sys.path.insert(0, HERE)
import reader  # noqa: E402
import roundtrip  # noqa: E402
import writer  # noqa: E402
from sf.fixture import as_role, new_design, plugin_turn  # noqa: E402
from sf.plugin import plug_folder  # noqa: E402
from sf.schema import cortex_sql, script  # noqa: E402
from sf.servers import MySQL  # noqa: E402
from sf.store import Store  # noqa: E402
from stored import round_trip_store  # noqa: E402

FLAVORS = ("cloudsql", "rds", "aurora")


def refusals(store, check):
    """Each declared fact, tried on a design of its flavor."""
    def design(name, version, flavor):
        return new_design(store, name, "mysql", version, flavor)

    def plugin_write(d, b, body):
        return plugin_turn(store, d, b, body, "engine_mysql_service", check=False)

    def server_ns(d):
        return f"(SELECT id FROM cortex.namespaces WHERE design = '{d}' AND parent IS NULL)"

    def db_ns(d):
        return f"(SELECT id FROM cortex.namespaces WHERE design = '{d}' AND parent IS NOT NULL LIMIT 1)"

    def base(d):
        return (f"INSERT INTO cortex.namespaces (design, name, position) VALUES ('{d}', 'server', 1);"
                f"INSERT INTO engine_mysql.instances (id, design, version, character_set, \"collation\", lower_case_table_names, sql_mode) "
                f"SELECT id, '{d}', '8.0.46', 'utf8mb4', 'utf8mb4_0900_ai_ci', 0, '' FROM cortex.namespaces WHERE design = '{d}' AND name = 'server';"
                f"INSERT INTO cortex.namespaces (design, parent, name, position) SELECT '{d}', id, 'shop', 1 FROM cortex.namespaces WHERE design = '{d}' AND name = 'server';")

    def table(d, name, engine, extra=""):
        return (f"INSERT INTO cortex.objects (design, engine, namespace, kind, name, position) VALUES ('{d}', 'mysql', {db_ns(d)}, 'table', '{name}', 1);"
                f"INSERT INTO engine_mysql.tables (id, design, engine, \"collation\"{', ' + extra.split('=')[0] if extra else ''}) "
                f"SELECT id, '{d}', '{engine}', 'utf8mb4_0900_ai_ci'{', ' + extra.split('=', 1)[1] if extra else ''} FROM cortex.objects WHERE design = '{d}' AND name = '{name}';")

    def server_object(d, kind, name, table_sql):
        return (f"INSERT INTO cortex.objects (design, engine, namespace, kind, name, position) VALUES ('{d}', 'mysql', {server_ns(d)}, '{kind}', '{name}', 1);"
                + table_sql.replace("$ID", f"(SELECT id FROM cortex.objects WHERE design = '{d}' AND name = '{name}')"))

    for flavor, version in (("aurora", "8.4"), ("aurora", "5.7"), ("cloudsql", "9.7")):
        rc, _, err = store.sql(as_role("cortex_service", f"INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('{flavor}_{version}', 'mysql', '{version}', '{flavor}');"), check=False)
        check(rc != 0 and "does not run" in err, f"{flavor} refuses a design of MySQL {version} (it does not run it)")
    cases = [
        ("cloudsql", "a MyISAM table", lambda d: base(d) + table(d, "t", "MyISAM"), "refuses the storage engine MyISAM"),
        ("cloudsql", "a MEMORY table", lambda d: base(d) + table(d, "t", "MEMORY"), "refuses the storage engine MEMORY"),
        ("cloudsql", "a loadable function", lambda d: base(d) + server_object(d, "loadable_function", "f",
            "INSERT INTO engine_mysql.loadable_functions (id, design, returns, library) SELECT $ID, '{d}', 'INTEGER', 'x.so';".replace("{d}", d)), "refuses a loadable_function"),
        ("cloudsql", "the privilege FILE", lambda d: base(d) + server_object(d, "account", "a@%",
            "INSERT INTO engine_mysql.accounts (id, design, user_name, host) SELECT $ID, '{d}', 'a', '%';".replace("{d}", d))
            + f"INSERT INTO engine_mysql.privileges (design, grantee, privilege, level) SELECT '{d}', id, 'FILE', 'global' FROM cortex.objects WHERE design = '{d}' AND name = 'a@%';",
            "refuses the privilege FILE"),
        ("cloudsql", "the privilege SUPER", lambda d: base(d) + server_object(d, "account", "a@%",
            "INSERT INTO engine_mysql.accounts (id, design, user_name, host) SELECT $ID, '{d}', 'a', '%';".replace("{d}", d))
            + f"INSERT INTO engine_mysql.privileges (design, grantee, privilege, level) SELECT '{d}', id, 'SUPER', 'global' FROM cortex.objects WHERE design = '{d}' AND name = 'a@%';",
            "refuses the privilege SUPER"),
        ("aurora", "a MyISAM table", lambda d: base(d) + table(d, "t", "MyISAM"), "refuses the storage engine MyISAM"),
        ("aurora", "a resource group", lambda d: base(d) + server_object(d, "resource_group", "rg",
            "INSERT INTO engine_mysql.resource_groups (id, design, type) SELECT $ID, '{d}', 'USER';".replace("{d}", d)), "aurora refuses a resource_group"),
        ("rds", "a table with COMPRESSION", lambda d: base(d) + table(d, "t", "InnoDB", "compression='zlib'"), "refuses the table option COMPRESSION"),
        ("rds", "a database named InnoDB", lambda d: (base(d).replace("'shop'", "'InnoDB'")
            + f"INSERT INTO engine_mysql.databases (id, design, character_set, \"collation\") SELECT id, '{d}', 'utf8mb4', 'utf8mb4_0900_ai_ci' FROM cortex.namespaces WHERE design = '{d}' AND name = 'InnoDB';"),
            "refuses a database named InnoDB"),
        ("rds", "a compression dictionary", lambda d: base(d) + server_object(d, "compression_dictionary", "words",
            "INSERT INTO engine_mysql.compression_dictionaries (id, design, data) SELECT $ID, '{d}', 'x';".replace("{d}", d)), "rds refuses a compression_dictionary"),
        ("mysql", "a compression dictionary (Percona's)", lambda d: base(d) + server_object(d, "compression_dictionary", "words",
            "INSERT INTO engine_mysql.compression_dictionaries (id, design, data) SELECT $ID, '{d}', 'x';".replace("{d}", d)), "mysql refuses a compression_dictionary"),
        ("mysql", "a flavor option it does not declare", lambda d: base(d) + table(d, "t", "InnoDB", "flavor_options='{\"shard_row_id_bits\": 4}'"),
         "declares no flavor option shard_row_id_bits"),
    ]
    for n, (flavor, what, body, expect) in enumerate(cases):
        d, b = design(f"refuse_{n}_{flavor}", "8.0", flavor)
        rc, _, err = plugin_write(d, b, body(d))
        check(rc != 0 and expect in err, f"{flavor} refuses {what}" + ("" if rc != 0 and expect in err else f" (got: {err.strip()[:160] or 'taken'})"))
    d, b = design("percona_dict", "8.0", "percona")
    rc, _, err = plugin_write(d, b, base(d) + server_object(d, "compression_dictionary", "words",
                              f"INSERT INTO engine_mysql.compression_dictionaries (id, design, data) SELECT $ID, '{d}', 'x';"))
    check(rc == 0, "percona takes a compression dictionary" + ("" if rc == 0 else f" ({err.strip()[:160]})"))


def fit(model, refuses):
    """The model cut to what a flavor allows: no storage engine, kind or privilege it refuses, nor anything that needs one."""
    m = copy.deepcopy(model)
    engines = {e.upper() for e in refuses.get("engines", [])}
    kinds = set(refuses.get("kinds", []))
    gone = {k for k, o in m["objects"].items() if o["kind"] in kinds or (o["kind"] == "table" and o["details"]["engine"].upper() in engines)}
    changed = True
    while changed:
        changed = False
        for k, o in m["objects"].items():
            if k in gone:
                continue
            uses = [f"{u[0]}|table|{u[1]}" for u in o.get("uses", [])] + [f"{u[0]}|view|{u[1]}" for u in o.get("uses", [])]
            if (o["kind"] == "trigger" and o["parent"] in gone) or (o["kind"] == "view" and any(u in gone for u in uses)) \
                    or any(f"{k.split('|')[0]}|table|{u}" in gone for u in o.get("union", [])):
                gone.add(k)
                changed = True
    for k in gone:
        del m["objects"][k]
    for o in m["objects"].values():
        if o["kind"] == "table":
            o["constraints"] = [c for c in o["constraints"] if c["kind"] != "foreign" or f"{c['to'][0]}|table|{c['to'][1]}" not in gone]
    refused_privs = set(refuses.get("privileges", []))
    m["privileges"] = [p for p in m.get("privileges", []) if p["privilege"] not in refused_privs
                       and not (p["object"] and p["level"] in ("table", "column") and f"{p['database']}|table|{p['object']}" in gone and f"{p['database']}|view|{p['object']}" not in m["objects"])]
    return m, len(gone)


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)

    print("== what each flavor refuses, refused by the store")
    with Store("sf-mysql-flavors") as store:
        store.sql(script(cortex_sql()))
        plug_folder(store, "engines/mysql")
        refusals(store, check)
        facts = json.loads(store.value("SELECT json_object_agg(flavor, refuses) FROM cortex.engine_flavors WHERE engine = 'mysql'"))
    print("== a design of everything each flavor allows: taken by the store, and loading into MySQL 8.0")
    sys.argv = [sys.argv[0], "--server", "mysql:8.0"]
    with MySQL("mysql:8.0", name="sf-flavors-a") as a:
        for f in roundtrip.samples("mysql:8.0"):
            a.load(f)
        model = reader.read(a)
    for flavor in FLAVORS:
        fitted, cut = fit(model, facts[flavor])
        stored, rows = round_trip_store(fitted, "mysql:8.0", flavor=flavor)
        diff = roundtrip.differences(fitted, stored)
        check(not diff, f"{flavor}: the sample without the {cut} objects it refuses, stored as a {flavor} design ({rows} rows) and read back identical")
        with MySQL("mysql:8.0", name=f"sf-flavors-{flavor}") as b:
            b.sql(writer.write(stored))
            back = reader.read(b)
        diff = roundtrip.differences(fitted, back)
        check(not diff, f"{flavor}: written into MySQL 8.0 and read again identical ({len(fitted['objects'])} objects)")
        for line in diff[:5]:
            print(f"    differs  {line}")
    print(f"{'pass' if not bad else 'FAIL'}  engine_mysql flavors: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
