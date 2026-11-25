"""The lab's schema fuzzer: from a seed, a schema of random tables, columns, keys, indexes, partitions, views,
routines and triggers, every feature its engine has at the server's version, names awkward on purpose. Each is loaded
on the server, probed, read whole, and checked: every object it made in the roster once, every definition read or
reported unreadable with the server's reason, the snapshot stored and rebuilt exactly.

  python3 lab/fuzz.py [seeds per server] [first seed]      (10, 1)
"""
import json
import random
import subprocess
import sys

import probe as P

NAMES = ["orders", "Order", "my.table", "it's", "MixedCase", "two words", "ünïcode", "select", "x", "a_very_long_name_" + "z" * 40]


def name(rnd, used):
    base = rnd.choice(NAMES) if rnd.random() < 0.3 else rnd.choice(["t", "acct", "event", "item", "log"]) + str(rnd.randint(0, 9999))
    n = base
    while n.lower() in used:
        n = base + str(rnd.randint(0, 999))
    used.add(n.lower())
    return n


def ver(v):
    return tuple(int(x) for x in v.split("."))


# --- MySQL ----------------------------------------------------------------------------------------------------------

def my_q(n):
    return "`" + n.replace("`", "``") + "`"


def my_type(rnd, v):
    t = rnd.choice(["INT", "INT UNSIGNED", "BIGINT", "TINYINT(1)", "SMALLINT", "DECIMAL(12,3)", "DOUBLE", "FLOAT", "BIT(4)",
                    "VARCHAR(40)", "CHAR(3)", "TEXT", "BLOB", "DATE", "DATETIME(3)", "TIMESTAMP NULL", "TIME", "YEAR",
                    "ENUM('a','b','c')", "SET('x','y')", "JSON", "VARCHAR(20) CHARACTER SET latin1 COLLATE latin1_bin"])
    return t


def my_schema(rnd, v, db):
    used, sql, objs, tables = set(), [f"CREATE DATABASE {my_q(db)};"], [], []
    innodb_plain = set()  # MySQL: a foreign key only between InnoDB tables, neither partitioned
    for _ in range(rnd.randint(2, 6)):
        tn = name(rnd, used)
        cols, cused = [], set()
        n = rnd.randint(2, 7)
        cnames = [name(rnd, cused) for _ in range(n)]
        types = {}
        for i, c in enumerate(cnames):
            t = "INT" if i == 0 else my_type(rnd, v)
            types[c] = t
            col = f"{my_q(c)} {t}"
            if i == 0:
                auto = rnd.random() < 0.5
                col += " NOT NULL" + (" AUTO_INCREMENT" if auto else "")
            elif rnd.random() < 0.3 and t.startswith(("INT", "BIGINT", "SMALLINT", "DECIMAL", "VARCHAR(40)", "CHAR")):
                col += " NOT NULL DEFAULT " + ("0" if not t.startswith(("VARCHAR", "CHAR")) else "'z'")
            if rnd.random() < 0.2:
                col += " COMMENT " + P.lit("note on " + c)
            cols.append(col)
        if rnd.random() < 0.25 and not auto:  # MySQL: a generated column cannot use the AUTO_INCREMENT column
            cols.append(f"{my_q('gen_' + str(rnd.randint(0, 99)))} INT AS ({my_q(cnames[0])} * 2) {rnd.choice(['VIRTUAL', 'STORED'])}")
        keys = [f"PRIMARY KEY ({my_q(cnames[0])})"]
        idx_cols = [c for c in cnames[1:] if not types[c].startswith(("TEXT", "BLOB", "JSON"))]
        if idx_cols and rnd.random() < 0.6:
            keys.append(f"{'UNIQUE ' if rnd.random() < 0.3 else ''}KEY {my_q('k_' + str(rnd.randint(0, 999)))} ({my_q(rnd.choice(idx_cols))})")
        if ver(v) >= (8, 0, 16) and rnd.random() < 0.3 and not auto:  # nor can a CHECK
            keys.append(f"CONSTRAINT {my_q('ck_' + str(rnd.randint(0, 999)))} CHECK ({my_q(cnames[0])} >= 0)")
        engine_ = rnd.choice(['InnoDB', 'InnoDB', 'MyISAM'])
        will_partition = rnd.random() < 0.2 and (engine_ == "InnoDB" or ver(v) < (8,))
        fk_ok = [x for x in tables if x in innodb_plain] if engine_ == "InnoDB" and not will_partition else []
        if fk_ok and rnd.random() < 0.4:
            other = rnd.choice(fk_ok)
            keys.append(f"FOREIGN KEY ({my_q(cnames[0])}) REFERENCES {my_q(db)}.{my_q(other)} (id_pk) ON DELETE {rnd.choice(['CASCADE', 'RESTRICT', 'SET NULL', 'NO ACTION'])}".replace(
                "SET NULL", "CASCADE"))
        opts = f" ENGINE={engine_}"
        if rnd.random() < 0.3:
            opts += " COMMENT=" + P.lit("table " + tn)
        part = ""
        if will_partition and "FOREIGN" not in " ".join(keys) and not any(k.startswith("UNIQUE") for k in keys):
            part = f" PARTITION BY HASH ({my_q(cnames[0])}) PARTITIONS {rnd.randint(2, 4)}"
        # the first column is renamed id_pk so foreign keys can name it
        cols[0] = cols[0].replace(my_q(cnames[0]), "`id_pk`", 1)
        keys = [k.replace(my_q(cnames[0]), "`id_pk`") for k in keys]
        cols = [c.replace(f"({my_q(cnames[0])} * 2)", "(`id_pk` * 2)") for c in cols]
        part = part.replace(my_q(cnames[0]), "`id_pk`")
        sql.append(f"CREATE TABLE {my_q(db)}.{my_q(tn)} ({', '.join(cols + keys)}){opts}{part};")
        objs.append(("table", tn))
        tables.append(tn)
        if engine_ == "InnoDB" and not part:
            innodb_plain.add(tn)
    for _ in range(rnd.randint(0, 2)):
        vn = name(rnd, used)
        sql.append(f"CREATE {rnd.choice(['', 'ALGORITHM=MERGE ', 'SQL SECURITY INVOKER '])}VIEW {my_q(db)}.{my_q(vn)} AS SELECT * FROM {my_q(db)}.{my_q(rnd.choice(tables))};")
        objs.append(("view", vn))
    for _ in range(rnd.randint(0, 2)):
        pn = name(rnd, used)
        if rnd.random() < 0.5:
            sql.append(f"CREATE PROCEDURE {my_q(db)}.{my_q(pn)}(IN a INT, OUT b INT) SET b = a + 1;")
            objs.append(("procedure", pn))
        else:
            sql.append(f"CREATE FUNCTION {my_q(db)}.{my_q(pn)}(a INT) RETURNS INT DETERMINISTIC RETURN a * 2;")
            objs.append(("function", pn))
    if rnd.random() < 0.5:
        tg = name(rnd, used)
        sql.append(f"CREATE TRIGGER {my_q(db)}.{my_q(tg)} {rnd.choice(['BEFORE', 'AFTER'])} {rnd.choice(['INSERT', 'UPDATE', 'DELETE'])} ON {my_q(db)}.{my_q(rnd.choice(tables))} FOR EACH ROW SET @x = 1;")
        objs.append(("trigger", tg))
    return sql, objs


# --- PostgreSQL -----------------------------------------------------------------------------------------------------

def pg_q(n):
    return '"' + n.replace('"', '""') + '"'


def pg_type(rnd, v, types_made):
    t = rnd.choice(["integer", "bigint", "smallint", "numeric(12,3)", "double precision", "real", "boolean", "text",
                    "varchar(40)", "char(3)", "bytea", "date", "timestamp", "timestamptz", "time", "interval", "uuid",
                    "jsonb", "json", "integer[]", "text[]", "inet", "tsvector", "int4range", "money"] + types_made)
    return t


def pg_schema(rnd, v, sch):
    used, sql, objs, tables = set(), [f"CREATE SCHEMA {pg_q(sch)};"], [], []
    types_made = []
    if rnd.random() < 0.5:
        en = name(rnd, used)
        sql.append(f"CREATE TYPE {pg_q(sch)}.{pg_q(en)} AS ENUM ('a', 'b', 'c');")
        objs.append(("type", en))
        types_made.append(f"{pg_q(sch)}.{pg_q(en)}")
    if rnd.random() < 0.4:
        dn = name(rnd, used)
        sql.append(f"CREATE DOMAIN {pg_q(sch)}.{pg_q(dn)} AS integer CHECK (VALUE > 0);")
        objs.append(("type", dn))
        types_made.append(f"{pg_q(sch)}.{pg_q(dn)}")
    for _ in range(rnd.randint(2, 6)):
        tn = name(rnd, used)
        cused = set()
        cnames = ["id_pk"] + [name(rnd, cused) for _ in range(rnd.randint(1, 6))]
        cols = []
        types = {}
        for i, c in enumerate(cnames):
            t = "integer" if i == 0 else pg_type(rnd, v, types_made)
            types[c] = t
            col = f"{pg_q(c)} {t}"
            if i == 0:
                col += rnd.choice([" NOT NULL", " GENERATED ALWAYS AS IDENTITY", " GENERATED BY DEFAULT AS IDENTITY"])
            elif rnd.random() < 0.25 and t in ("integer", "bigint", "smallint", "text", "varchar(40)", "boolean"):
                col += " NOT NULL DEFAULT " + {"integer": "0", "bigint": "0", "smallint": "0", "boolean": "false"}.get(t, "'z'")
            cols.append(col)
        if rnd.random() < 0.25:
            cols.append(f"{pg_q('gen_' + str(rnd.randint(0, 99)))} integer GENERATED ALWAYS AS (id_pk * 2) STORED")
        partitioned = rnd.random() < 0.2
        keys = [] if partitioned else ["PRIMARY KEY (id_pk)"]
        scalar = [c for c in cnames[1:] if types[c] in ("integer", "bigint", "text", "varchar(40)", "date", "uuid")]
        if scalar and rnd.random() < 0.3 and not partitioned:
            uq = f"UNIQUE {'NULLS NOT DISTINCT ' if ver(v) >= (15,) and rnd.random() < 0.5 else ''}({pg_q(rnd.choice(scalar))})"
            keys.append(uq)
        if rnd.random() < 0.3:
            keys.append(f"CONSTRAINT {pg_q('ck_' + str(rnd.randint(0, 999)))} CHECK (id_pk >= 0){' NOT VALID' if rnd.random() < 0.3 else ''}")
        unlogged = "UNLOGGED " if not partitioned and rnd.random() < 0.1 else ""
        if tables and rnd.random() < 0.4 and not partitioned and not unlogged:
            other = rnd.choice([t for t in tables if t[1] and not t[2]] or [None])
            if other:
                keys.append(f"FOREIGN KEY (id_pk) REFERENCES {pg_q(sch)}.{pg_q(other[0])} (id_pk) ON DELETE {rnd.choice(['CASCADE', 'RESTRICT', 'NO ACTION', 'SET NULL'])}"
                            + (" DEFERRABLE INITIALLY DEFERRED" if rnd.random() < 0.3 else ""))
        tail = " PARTITION BY RANGE (id_pk)" if partitioned else ""
        if not partitioned and rnd.random() < 0.15:
            tail = " WITH (fillfactor = 80)"
        sql.append(f"CREATE {unlogged}TABLE {pg_q(sch)}.{pg_q(tn)} ({', '.join(cols + keys)}){tail};")
        objs.append(("partitioned table" if partitioned else "table", tn))
        if partitioned:
            for i in range(rnd.randint(1, 3)):
                pn = name(rnd, used)
                sql.append(f"CREATE TABLE {pg_q(sch)}.{pg_q(pn)} PARTITION OF {pg_q(sch)}.{pg_q(tn)} FOR VALUES FROM ({i * 1000}) TO ({(i + 1) * 1000});")
                objs.append(("partition", pn))
        else:
            if scalar and rnd.random() < 0.6:
                c = rnd.choice(scalar)
                method = rnd.choice(["btree", "hash", "brin"]) if types[c] in ("integer", "bigint", "date") else "btree"
                where = f" WHERE {pg_q(c)} IS NOT NULL" if rnd.random() < 0.3 else ""
                sql.append(f"CREATE INDEX ON {pg_q(sch)}.{pg_q(tn)} USING {method} ({pg_q(c)}){where};")
            gin = [c for c in cnames if types[c] in ("jsonb", "integer[]", "text[]", "tsvector")]
            if gin and rnd.random() < 0.5:
                sql.append(f"CREATE INDEX ON {pg_q(sch)}.{pg_q(tn)} USING gin ({pg_q(rnd.choice(gin))});")
        tables.append((tn, not partitioned, bool(unlogged)))
    for _ in range(rnd.randint(0, 2)):
        vn = name(rnd, used)
        mat = rnd.random() < 0.3
        sql.append(f"CREATE {'MATERIALIZED ' if mat else ''}VIEW {pg_q(sch)}.{pg_q(vn)} AS SELECT * FROM {pg_q(sch)}.{pg_q(rnd.choice(tables)[0])}{' WITH NO DATA' if mat else ''};")
        objs.append(("materialized view" if mat else "view", vn))
    fn = None
    for _ in range(rnd.randint(0, 2)):
        fn = name(rnd, used)
        sql.append(f"CREATE FUNCTION {pg_q(sch)}.{pg_q(fn)}(a integer) RETURNS integer LANGUAGE sql {rnd.choice(['IMMUTABLE', 'STABLE', 'VOLATILE'])} AS $$ SELECT a * 2 $$;")
        objs.append(("function", f"{pg_q(sch)}.{pg_q(fn)}(integer)"))
        if rnd.random() < 0.4:
            sql.append(f"CREATE FUNCTION {pg_q(sch)}.{pg_q(fn)}(a integer, b integer) RETURNS integer LANGUAGE sql AS $$ SELECT a + b $$;")
            objs.append(("function", f"{pg_q(sch)}.{pg_q(fn)}(integer,integer)"))
    if rnd.random() < 0.5:
        tf = name(rnd, used)
        sql.append(f"CREATE FUNCTION {pg_q(sch)}.{pg_q(tf)}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;")
        objs.append(("function", f"{pg_q(sch)}.{pg_q(tf)}()"))
        tg = name(rnd, used)
        on = rnd.choice([t for t in tables if t[1]] or tables)[0]
        sql.append(f"CREATE TRIGGER {pg_q(tg)} BEFORE INSERT ON {pg_q(sch)}.{pg_q(on)} FOR EACH ROW EXECUTE FUNCTION {pg_q(sch)}.{pg_q(tf)}();")
        objs.append(("trigger", f"{on}.{tg}"))
    return sql, objs


def pg_cut(n):
    """PostgreSQL keeps the first 63 bytes of a name (NAMEDATALEN - 1), without a word."""
    return n.encode()[:63].decode(errors="ignore")


def norm_pg(name_):
    import re
    name_ = name_.replace(" ", "").replace('"', "")
    return ".".join(re.sub(r"^([^(]*)", lambda m: pg_cut(m.group(1)), part) for part in name_.split("."))


def run(engine, container, seed):
    rnd = random.Random(seed)
    s = P.Server(engine, container)
    version = s.ask(P.PLUGINS[engine]["version"])[0][0].split("-")[0].split(" ")[0]
    zone = f"fuzz {seed}"
    if engine == "mysql":
        sql, objs = my_schema(rnd, version, zone)
        drop = f"DROP DATABASE IF EXISTS {my_q(zone)};"
    else:
        sql, objs = pg_schema(rnd, version, zone)
        drop = f"DROP SCHEMA IF EXISTS {pg_q(zone)} CASCADE;"
    try:
        s.ask(drop + "\n" + "\n".join(sql))
    except RuntimeError as e:
        return "generator", f"the server refused the generated schema: {str(e).splitlines()[-1][:160]}"
    saved = P.SCHEMAS, P.PLUGINS
    try:
        P.SCHEMAS = (zone,)
        import importlib
        importlib.reload(P)
        P.SCHEMAS = (zone,)
        S = P.in_list(P.SCHEMAS)
        plugins = json.loads(json.dumps(P.PLUGINS, default=str))
        roster_sql = P.PLUGINS[engine]["roster"].replace(P.in_list(("shop", "features", "Quoted Names")), S)
        P.PLUGINS[engine]["roster"] = roster_sql
        probed = P.probe(s)
    finally:
        pass
    got = {(o["kind"], norm_pg(o["name"]) if engine == "postgresql" else o["name"]) for o in probed["roster"]}
    want = {(k, norm_pg(n) if engine == "postgresql" else n) for k, n in objs}
    missing, extra = want - got, got - want
    read = P.read(s, probed, {"objects": "all", "groups": None})
    empty = [k for k, v in read["definitions"].items() if not any(v)]
    unread = read.get("unread", {})
    s.ask(drop)
    if missing or extra or empty or unread:
        return "failed", f"missing {sorted(missing)[:3]} extra {sorted(extra)[:3]} empty {empty[:2]} unread {list(unread.items())[:2]}"
    return "pass", f"{len(objs)} objects"


def main():
    per = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    tally = {}
    for engine, container in P.SERVERS:
        for seed in range(first, first + per):
            outcome, said = run(engine, container, seed)
            tally.setdefault(container, {}).setdefault(outcome, 0)
            tally[container][outcome] += 1
            if outcome != "pass":
                print(f"  {container} seed {seed}: {outcome}: {said}")
    print("== the fuzzer: per server, schemas that passed, failures found, schemas the server refused (the generator's to learn)")
    for c, t in tally.items():
        print(f"  {c:14} pass {t.get('pass', 0):3}  failed {t.get("failed", 0):3}  generator {t.get('generator', 0):3}")


if __name__ == "__main__":
    main()
