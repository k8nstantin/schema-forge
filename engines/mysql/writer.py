"""engine_mysql's writer: the plugin's model written as the SQL a MySQL server of the same version loads, every
statement from facts (decision cortex-and-engine-schemas): databases, then tables (foreign key checks off while they are
made), views in the order they use each other, routines, triggers in their order, and events, each program made in the
session it was made in (its SQL mode, client character set, connection collation and, for an event, time zone)."""
import re


def q(name):
    return "`" + name.replace("`", "``") + "`"


def lit(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def split_key(k):
    db, kind, name = k.split("|", 2)
    return db, kind, name


def write(model):
    out = ["SET NAMES utf8mb4;", "SET FOREIGN_KEY_CHECKS = 0;", "SET UNIQUE_CHECKS = 0;", "SET sql_mode = 'NO_ENGINE_SUBSTITUTION';"]
    for name, d in sorted(model["databases"].items()):
        opts = f" CHARACTER SET {charset(d['collation'])} COLLATE {d['collation']}"
        if d.get("encryption") is not None:
            opts += f" ENCRYPTION={lit('Y' if d['encryption'] else 'N')}"
        out.append(f"CREATE DATABASE {q(name)}{opts};")
    objects = model["objects"]
    tables = sorted((k for k, o in objects.items() if o["kind"] == "table"), key=lambda k: (bool(objects[k].get("union")), k))
    for k in tables:
        out += [f"USE {q(split_key(k)[0])};", create_table(k, objects[k])]
    for name, d in sorted(model["databases"].items()):
        if d.get("read_only"):
            out.append(f"ALTER DATABASE {q(name)} READ ONLY = 1;")
    out.append("SET FOREIGN_KEY_CHECKS = 1;")
    for k in view_order(objects):
        out += [f"USE {q(split_key(k)[0])};"] + program_session(objects[k]["details"]) + [create_view(k, objects[k])]
    # programs: a delimiter no body holds (a JavaScript body is quoted with $$)
    d = DELIMITER
    out.append(f"DELIMITER {d}")
    for k in sorted(k for k, o in objects.items() if o["kind"] == "library"):
        out += [f"USE {q(split_key(k)[0])}{d}", f"SET sql_mode = {lit(objects[k]['details']['sql_mode'])}{d}", create_library(k, objects[k]) + d]
    for k in sorted(k for k, o in objects.items() if o["kind"] in ("procedure", "function")):
        out += [f"USE {q(split_key(k)[0])}{d}"] + [s.rstrip(";") + d for s in program_session(objects[k]["details"], with_mode=True)]
        out.append(create_routine(k, objects[k]) + d)
    triggers = sorted((k for k, o in objects.items() if o["kind"] == "trigger"),
                      key=lambda k: (objects[k]["parent"], objects[k]["details"]["timing"], objects[k]["details"]["event"], objects[k]["details"]["action_order"]))
    previous = {}
    for k in triggers:
        t = objects[k]
        group = (t["parent"], t["details"]["timing"], t["details"]["event"])
        out += [f"USE {q(split_key(k)[0])}{d}"] + [s.rstrip(";") + d for s in program_session(t["details"], with_mode=True)]
        out.append(create_trigger(k, t, previous.get(group)) + d)
        previous[group] = split_key(k)[2]
    for k in sorted(k for k, o in objects.items() if o["kind"] == "event"):
        e = objects[k]
        out += [f"USE {q(split_key(k)[0])}{d}"] + [s.rstrip(";") + d for s in program_session(e["details"], with_mode=True)]
        out.append(f"SET time_zone = {lit(e['details']['time_zone'])}{d}")
        out.append(create_event(k, e) + d)
    out.append("DELIMITER ;")
    return "\n".join(out) + "\n"


DELIMITER = "$sf_end$"


def create_library(k, o):
    db, _, name = split_key(k)
    d = o["details"]
    s = f"CREATE LIBRARY {q(db)}.{q(name)}"
    if o.get("comment"):
        s += f" COMMENT {lit(o['comment'])}"
    return s + f" LANGUAGE {d['language']} AS $${d['source']}$$"


def charset(collation):
    return "binary" if collation == "binary" else collation.split("_", 1)[0]


def program_session(d, with_mode=False):
    s = [f"SET character_set_client = {d['character_set_client']};", f"SET collation_connection = {d['collation_connection']};"]
    if with_mode:
        s.insert(0, f"SET sql_mode = {lit(d['sql_mode'])};")
    return s


# --- tables ------------------------------------------------------------------------------------------------------------
def column_sql(c):
    s = f"{q(c['name'])} {c['type']}"
    if c.get("srid") is not None:
        s += f" /*!80003 SRID {c['srid']} */"
    if c.get("collation"):
        s += f" CHARACTER SET {c['character_set'] or charset(c['collation'])} COLLATE {c['collation']}"
    if c.get("generated_expression"):
        s += f" GENERATED ALWAYS AS ({c['generated_expression']}) {'STORED' if c['generated_stored'] else 'VIRTUAL'}"
    s += " NOT NULL" if not c["nullable"] else " NULL"
    if c.get("default") is not None:
        d = c["default"]
        if c.get("default_is_expression"):
            s += f" DEFAULT {d}" if re.match(r"^(current_timestamp|now)(\(\d*\))?$", d, re.I) else f" DEFAULT ({d})"
        else:
            s += f" DEFAULT {lit(d)}"
    if c.get("on_update"):
        s += f" ON UPDATE {c['on_update']}"
    if c.get("auto_increment"):
        s += " AUTO_INCREMENT"
    if c.get("invisible"):
        s += " /*!80023 INVISIBLE */"
    if c.get("comment"):
        s += f" COMMENT {lit(c['comment'])}"
    return s


def index_sql(i):
    parts = []
    for p in i["parts"]:
        if p.get("expression"):
            part = f"({p['expression']})"
        else:
            part = q(p["column"]) + (f"({p['prefix']})" if p.get("prefix") else "")
        parts.append(part + (" DESC" if p.get("descending") else ""))
    head = {"index": "UNIQUE KEY" if i["unique"] else "KEY", "fulltext": "FULLTEXT KEY", "spatial": "SPATIAL KEY"}[i["kind"]]
    s = f"PRIMARY KEY ({','.join(parts)})" if i["name"] == "PRIMARY" else f"{head} {q(i['name'])} ({','.join(parts)})"
    if i.get("method"):
        s += f" USING {i['method']}"
    if i.get("key_block_size"):
        s += f" KEY_BLOCK_SIZE={i['key_block_size']}"
    if i.get("parser"):
        s += f" /*!50100 WITH PARSER {q(i['parser'])} */"
    if i.get("comment"):
        s += f" COMMENT {lit(i['comment'])}"
    if i.get("invisible"):
        s += " /*!80000 INVISIBLE */"
    return s


def constraint_sql(c, db):
    if c["kind"] == "foreign":
        to = q(c["to"][1]) if c["to"][0] == db else f"{q(c['to'][0])}.{q(c['to'][1])}"
        s = (f"CONSTRAINT {q(c['name'])} FOREIGN KEY ({', '.join(q(x) for x in c['columns'])}) "
             f"REFERENCES {to} ({', '.join(q(x) for x in c['to_columns'])})")
        # what the server reports for a rule not written is NO ACTION (8.0 and later) or RESTRICT (5.7, which never writes it)
        if c.get("on_delete") and c["on_delete"] != "NO ACTION":
            s += f" ON DELETE {c['on_delete']}"
        if c.get("on_update") and c["on_update"] != "NO ACTION":
            s += f" ON UPDATE {c['on_update']}"
        return s
    if c["kind"] == "check":
        return f"CONSTRAINT {q(c['name'])} CHECK ({c['expression']})" + ("" if c.get("enforced", True) else " /*!80016 NOT ENFORCED */")
    return None


TABLE_OPTIONS = [("avg_row_length", "AVG_ROW_LENGTH"), ("checksum", "CHECKSUM"), ("compression", "COMPRESSION"), ("delay_key_write", "DELAY_KEY_WRITE"),
                 ("encryption", "ENCRYPTION"), ("key_block_size", "KEY_BLOCK_SIZE"), ("max_rows", "MAX_ROWS"), ("min_rows", "MIN_ROWS"),
                 ("pack_keys", "PACK_KEYS"), ("row_format", "ROW_FORMAT"), ("stats_auto_recalc", "STATS_AUTO_RECALC"),
                 ("stats_persistent", "STATS_PERSISTENT"), ("stats_sample_pages", "STATS_SAMPLE_PAGES"), ("autoextend_size", "AUTOEXTEND_SIZE")]


def create_table(k, o):
    db, _, name = split_key(k)
    d = o["details"]
    body = [column_sql(c) for c in o["columns"]] + [index_sql(i) for i in o["indexes"]]
    body += [s for s in (constraint_sql(c, db) for c in o["constraints"]) if s]
    opts = [f"ENGINE={d['engine']}"]
    if d.get("auto_increment"):
        opts.append(f"AUTO_INCREMENT={d['auto_increment']}")
    opts.append(f"DEFAULT CHARSET={charset(d['collation'])} COLLATE={d['collation']}")
    for field, word in TABLE_OPTIONS:
        v = d.get(field)
        if v is None:
            continue
        if isinstance(v, bool):
            v = "1" if v else "0"
        if field == "compression":
            v = lit(v)
        if field == "encryption":
            v = lit("Y" if d[field] else "N")
        opts.append(f"{word}={v}")
    if o.get("comment"):
        opts.append(f"COMMENT={lit(o['comment'])}")
    if d.get("insert_method"):
        opts.append(f"INSERT_METHOD={d['insert_method']}")
    if o.get("union"):
        opts.append(f"UNION=({','.join(q(u) for u in o['union'])})")
    if d.get("tablespace"):
        opts.append(f"TABLESPACE {q(d['tablespace'])}")
    s = f"CREATE TABLE {q(db)}.{q(name)} (\n  " + ",\n  ".join(body) + "\n) " + " ".join(opts)
    if o.get("partitioning"):
        s += "\n" + partition_sql(o["partitioning"], o["partitions"])
    return s + ";"


def method_sql(method, expression, algorithm):
    if method.endswith("KEY"):
        return f"{method}{f' ALGORITHM = {algorithm}' if algorithm else ''} ({expression})"
    if method.endswith("COLUMNS"):
        return f"{method}({expression})"
    return f"{method} ({expression})"


def partition_sql(p, parts):
    s = f"PARTITION BY {method_sql(p['method'], p['expression'], p['key_algorithm'])}"
    if p.get("sub_method"):
        s += f"\nSUBPARTITION BY {method_sql(p['sub_method'], p['sub_expression'], p['sub_key_algorithm'])}"
        if not p.get("sub_listed"):
            s += f"\nSUBPARTITIONS {len(parts[0]['subpartitions'])}"
    if not p.get("listed"):
        return s + f"\nPARTITIONS {len(parts)}"
    items = []
    for part in parts:
        x = f"PARTITION {q(part['name'])}" + (f" VALUES {part['values']}" if part.get("values") else "")
        if part.get("comment"):
            x += f" COMMENT = {lit(part['comment'])}"
        if p.get("sub_listed"):
            x += " (" + ", ".join(f"SUBPARTITION {q(sp['name'])}" for sp in part["subpartitions"]) + ")"
        items.append(x)
    return s + "\n(" + ",\n ".join(items) + ")"


# --- programs ----------------------------------------------------------------------------------------------------------
def view_order(objects):
    views = {k for k, o in objects.items() if o["kind"] == "view"}
    done, order = set(), []
    while len(order) < len(views):
        for k in sorted(views - done):
            needs = {f"{u[0]}|view|{u[1]}" for u in objects[k].get("uses", [])} & views
            if needs <= done | {k}:
                done.add(k)
                order.append(k)
                break
        else:
            order += sorted(views - done)
            break
    return order


def create_view(k, o):
    db, _, name = split_key(k)
    d = o["details"]
    s = f"CREATE ALGORITHM={d['algorithm']} DEFINER={d['definer']} SQL SECURITY {d['security']} VIEW {q(db)}.{q(name)} AS {d['definition']}"
    if d.get("check_option"):
        s += f" WITH {d['check_option']} CHECK OPTION"
    return s + ";"


def create_routine(k, o):
    db, kind, name = split_key(k)
    d = o["details"]
    params = ", ".join(" ".join(x for x in (p.get("mode"), p["name"], p["type"]) if x) for p in o.get("parameters", []))
    s = f"CREATE DEFINER={d['definer']} {kind.upper()} {q(db)}.{q(name)}({params})"
    if kind == "function":
        s += f" RETURNS {d['returns']}"
    if o.get("comment"):
        s += f"\n    COMMENT {lit(o['comment'])}"
    if d.get("language", "SQL") != "SQL":
        s += f"\n    LANGUAGE {d['language']}"
    # each characteristic written where it is not the default (the server writes none of the defaults back)
    if d["deterministic"]:
        s += "\n    DETERMINISTIC"
    if d["data_access"] != "CONTAINS SQL":
        s += f"\n    {d['data_access']}"
    if d["security"] != "DEFINER":
        s += f"\n    SQL SECURITY {d['security']}"
    return s + "\n" + d["body"]


def create_trigger(k, o, follows):
    db, _, name = split_key(k)
    d = o["details"]
    table = split_key(o["parent"])[2]
    s = f"CREATE DEFINER={d['definer']} TRIGGER {q(db)}.{q(name)} {d['timing']} {d['event']} ON {q(db)}.{q(table)} FOR EACH ROW"
    if follows:
        s += f" FOLLOWS {q(follows)}"
    return s + " " + d["body"]


def create_event(k, o):
    db, _, name = split_key(k)
    d = o["details"]
    if d.get("execute_at"):
        sched = f"AT {lit(d['execute_at'])}"
    else:
        sched = f"EVERY {lit(d['interval_value'])} {d['interval_field']}"
        if d.get("starts"):
            sched += f" STARTS {lit(d['starts'])}"
        if d.get("ends"):
            sched += f" ENDS {lit(d['ends'])}"
    s = f"CREATE DEFINER={d['definer']} EVENT {q(db)}.{q(name)} ON SCHEDULE {sched} ON COMPLETION {d['on_completion']} {d['status']}"
    if o.get("comment"):
        s += f" COMMENT {lit(o['comment'])}"
    return s + f" DO {d['body']}"
