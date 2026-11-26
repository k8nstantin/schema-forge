"""Where the locked design does one thing two ways: read from PostgreSQL's catalog once the design is loaded, every place
a kind of column or constraint differs from the rest of its kind. Each line is to be made one way, or kept for a reason
the design states.

  python3 lab/consistency.py
"""
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_consistency"
NS = "('cortex', 'ui', 'engine_mysql', 'engine_postgresql')"


def rows(sql):
    """A query's rows, its fields split on a separator no definition holds."""
    return [line.split("~#~") for line in C.psql("\\pset fieldsep '~#~'\n" + sql, DB).splitlines() if line and "~#~" in line]


def report(title, items):
    print(f"== {title}: {len(items) if items else 'one way'}")
    for i in items:
        print(f"  {i}")


def main():
    R.build(DB)
    cols = rows(f"""SELECT n.nspname || '.' || c.relname, a.attname, format_type(a.atttypid, NULL), a.attnotnull::text,
                          coalesce(pg_get_expr(d.adbin, d.adrelid), '')
                   FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                   WHERE c.relkind = 'r' AND n.nspname IN {NS} AND a.attnum > 0 AND NOT a.attisdropped ORDER BY 1, a.attnum""")
    checks = defaultdict(list)
    for t, defn in rows(f"""SELECT n.nspname || '.' || c.relname, pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
                            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE k.contype = 'c' AND n.nspname IN {NS}"""):
        checks[t].append(defn)

    by_type = defaultdict(list)
    for t, a, typ, nn, dflt in cols:
        if a == "position":
            by_type[typ].append(t)
    report("position: an order key (NUMERIC) or a counted place (INTEGER)", [f"{typ}: {len(ts)} tables: {', '.join(sorted(ts))}" for typ, ts in by_type.items()])

    report("ids that are not UUIDv7", [f"{t}.{a} {typ}" for t, a, typ, nn, dflt in cols if a == "id" and typ != "uuid" and not t.startswith(("cortex.engine_", "cortex.object_kinds", "cortex.option_declarations", "cortex.catalog_sources", "cortex.workspace_parameters"))])

    report("booleans that may be null", [f"{t}.{a}" for t, a, typ, nn, dflt in cols if typ == "boolean" and nn == "false"])

    names = [f"{t}.{a}" for t, a, typ, nn, dflt in cols if a == "name" and typ == "text" and not any("length(name)" in c for c in checks[t])]
    report("names with no check that they are not empty", names)

    fks = rows(f"""SELECT n.nspname || '.' || c.relname, pg_get_constraintdef(k.oid), k.condeferrable::text, k.confdeltype
                   FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE k.contype = 'f' AND n.nspname IN {NS} ORDER BY 1""")
    report("foreign keys checked at once, not at commit", [f"{t}: {d[:110]}" for t, d, deferrable, _ in fks if deferrable == "false"])
    action = defaultdict(list)
    for t, d, _, deltype in fks:
        if "(design, " in d:
            action[{"a": "no action", "r": "restrict", "c": "cascade", "n": "set null", "d": "set default"}[deltype]].append(f"{t}: {d.split(' REFERENCES ')[0][12:]}")
    report("what a reference within a design does when its row is deleted", [f"{k}: {len(v)}" for k, v in action.items()] + [f"  no action: {x}" for x in action.get("no action", [])])

    uniq = rows(f"""SELECT n.nspname || '.' || c.relname, pg_get_constraintdef(k.oid), k.condeferrable::text FROM pg_constraint k
                    JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE k.contype = 'u' AND n.nspname IN {NS} AND pg_get_constraintdef(k.oid) <> 'UNIQUE (design, id)' ORDER BY 1""")
    report("unique keys checked at once (a rename or a reorder that swaps two values needs them at commit)",
           [f"{t}: {d}" for t, d, deferrable in uniq if deferrable == "false"])

    report("text columns holding a list or an object (JSONB, or not)", [])
    for t, a, typ, nn, dflt in cols:
        if typ == "jsonb":
            print(f"  jsonb  {t}.{a}")

    created = [f"{t}.{a}" for t, a, typ, nn, dflt in cols if typ == "timestamp with time zone" and a.endswith("_at") and "now()" not in dflt and nn == "true"]
    report("NOT NULL times the database does not default to now()", created)
    C.psql(f"DROP DATABASE {DB} WITH (FORCE);", "postgres")


if __name__ == "__main__":
    main()
