"""engine_mysql's reader: a live MySQL server (5.7 to 9.7, and its flavors) read into the plugin's model, a plain
structure of what the server holds, the same shape the store gives back and the writer writes from. Structure comes from
information_schema; what only the statement records (an option written or not, an index's clauses, AUTO_INCREMENT, a
MERGE table's tables, a tablespace) from SHOW CREATE. Every value as the server writes it.

  model = {"instance": {...}, "databases": {name: {...}}, "objects": {"db|kind|name": {...}}}

The server is anything with json(query) -> parsed JSON and rows(statements) -> each SHOW's fields."""
import re

SYSTEM = ("mysql", "information_schema", "performance_schema", "sys")
SYS_LIST = "('mysql', 'information_schema', 'performance_schema', 'sys')"


def key(db, kind, name):
    return f"{db}|{kind}|{name}"


def q(name):
    return "`" + name.replace("`", "``") + "`"


def read(server):
    version = server.json("SELECT JSON_ARRAY(VERSION(), @@character_set_server, @@collation_server, @@lower_case_table_names, @@sql_mode)")
    major = tuple(int(x) for x in re.match(r"(\d+)\.(\d+)", version[0]).groups())
    model = {"instance": {"version": version[0], "character_set": version[1], "collation": version[2],
                          "lower_case_table_names": int(version[3]), "sql_mode": version[4]},
             "databases": {}, "objects": {}}
    enc = "DEFAULT_ENCRYPTION = 'YES'" if major >= (8, 0) else "NULL"
    for d in server.json(f"SELECT JSON_ARRAYAGG(JSON_OBJECT('name', SCHEMA_NAME, 'cs', DEFAULT_CHARACTER_SET_NAME, 'coll', DEFAULT_COLLATION_NAME, 'enc', {enc})) "
                         f"FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN {SYS_LIST}"):
        model["databases"][d["name"]] = {"character_set": d["cs"], "collation": d["coll"], "encryption": bool(d["enc"]) if d["enc"] is not None else None, "read_only": None}
    if major >= (8, 0) and server.json("SELECT JSON_ARRAYAGG(1) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'information_schema' AND TABLE_NAME = 'SCHEMATA_EXTENSIONS'"):
        for d in server.json(f"SELECT JSON_ARRAYAGG(JSON_OBJECT('name', SCHEMA_NAME, 'opt', OPTIONS)) FROM information_schema.SCHEMATA_EXTENSIONS WHERE SCHEMA_NAME NOT IN {SYS_LIST}"):
            model["databases"][d["name"]]["read_only"] = "READ ONLY=1" in (d["opt"] or "")
    read_tables(server, model, major)
    read_views(server, model)
    read_routines(server, model)
    read_triggers(server, model)
    read_events(server, model)
    return model


# --- tables ------------------------------------------------------------------------------------------------------------
OPTION_KEYS = {"row_format": "row_format", "stats_persistent": "stats_persistent", "stats_auto_recalc": "stats_auto_recalc",
               "stats_sample_pages": "stats_sample_pages", "key_block_size": "key_block_size", "max_rows": "max_rows", "min_rows": "min_rows",
               "avg_row_length": "avg_row_length", "pack_keys": "pack_keys", "checksum": "checksum", "delay_key_write": "delay_key_write",
               "compression": "compression", "encryption": "encryption", "autoextend_size": "autoextend_size"}


def table_options(create_options):
    out = {}
    for m in re.finditer(r'(\w+)=("[^"]*"|\S+)', create_options or ""):
        k, v = m.group(1).lower(), m.group(2).strip('"')
        if k in OPTION_KEYS:
            out[OPTION_KEYS[k]] = v
    for k in ("key_block_size", "max_rows", "min_rows", "avg_row_length"):
        if k in out:
            out[k] = int(out[k])
    for k in ("checksum", "delay_key_write"):
        if k in out:
            out[k] = out[k] == "1"
    if "encryption" in out:
        out["encryption"] = out["encryption"].upper() == "Y"
    return out


INDEX_LINE = re.compile(r"^\s*(PRIMARY KEY|UNIQUE KEY|FULLTEXT KEY|SPATIAL KEY|KEY)\s*(`(?:[^`]|``)*`)?\s*\((.*)\)(.*?),?$")


def index_clauses(create):
    """From SHOW CREATE TABLE: each index's clauses only the statement records, by index name, in the server's order."""
    out = {}
    for line in create.split("\n"):
        m = INDEX_LINE.match(line)
        if not m or line.strip().startswith("CONSTRAINT"):
            continue
        name = "PRIMARY" if m.group(1) == "PRIMARY KEY" else m.group(2)[1:-1].replace("``", "`")
        rest = m.group(4)
        using = re.search(r"USING (BTREE|HASH)", rest)
        kbs = re.search(r"KEY_BLOCK_SIZE=(\d+)", rest)
        parser = re.search(r"WITH PARSER `([^`]+)`", rest)
        comment = re.search(r"COMMENT '((?:[^']|'')*)'", rest)
        out[name] = {"position": len(out) + 1, "method": using.group(1) if using else None, "key_block_size": int(kbs.group(1)) if kbs else None,
                     "parser": parser.group(1) if parser else None, "comment": comment.group(1).replace("''", "'") if comment else None,
                     "invisible": "INVISIBLE" in rest}
    return out


def read_tables(server, model, major):
    tables = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TABLE_SCHEMA, 'name', TABLE_NAME, 'engine', ENGINE, 'coll', TABLE_COLLATION,
        'opts', CREATE_OPTIONS, 'comment', TABLE_COMMENT)) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN {SYS_LIST} AND TABLE_TYPE = 'BASE TABLE'""")
    if not tables:
        return
    creates = server.rows([f"SHOW CREATE TABLE {q(t['db'])}.{q(t['name'])}" for t in tables])
    by = {}
    for t, row in zip(tables, creates):
        create = row[1]
        opts = table_options(t["opts"])
        ai = re.search(r"\) ENGINE=.*?AUTO_INCREMENT=(\d+)", create.split("\n")[-1] if create else "")
        tail = create[create.rfind("\n)"):] if "\n)" in create else ""
        ts = re.search(r"TABLESPACE `([^`]+)`", tail)
        union = re.search(r"UNION=\(([^)]*)\)", tail)
        im = re.search(r"INSERT_METHOD=(\w+)", tail)
        details = {"engine": t["engine"], "collation": t["coll"], "auto_increment": int(ai.group(1)) if ai else None, "tablespace": ts.group(1) if ts else None,
                   "insert_method": im.group(1) if im else None}
        details.update(opts)
        o = {"kind": "table", "comment": t["comment"] or None, "details": details, "columns": [], "indexes": [], "constraints": [],
             "union": [u.strip().strip("`") for u in union.group(1).split(",")] if union else [], "partitioning": None, "partitions": []}
        o["_create"] = create
        model["objects"][key(t["db"], "table", t["name"])] = o
        by[(t["db"], t["name"])] = o
    read_columns(server, model, by, major)
    read_indexes(server, by, major)
    read_constraints(server, by, major)
    read_partitions(server, by)
    for o in by.values():
        del o["_create"]


def read_columns(server, model, by, major):
    srs = "SRS_ID" if major >= (8, 0) else "NULL"
    for c in sorted(server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TABLE_SCHEMA, 't', TABLE_NAME, 'pos', ORDINAL_POSITION, 'name', COLUMN_NAME,
            'type', CAST(COLUMN_TYPE AS CHAR), 'nullable', IS_NULLABLE = 'YES', 'default', COLUMN_DEFAULT, 'extra', EXTRA, 'gen', GENERATION_EXPRESSION,
            'cs', CHARACTER_SET_NAME, 'coll', COLLATION_NAME, 'comment', COLUMN_COMMENT, 'srs', {srs}))
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN {SYS_LIST}"""), key=lambda c: (c["db"], c["t"], c["pos"])):
        o = by.get((c["db"], c["t"]))
        if o is None:
            vk = key(c["db"], "view", c["t"])
            if vk in model["objects"]:
                model["objects"][vk].setdefault("columns", []).append(column(c, None))
            else:
                model["objects"].setdefault(vk, {"kind": "view", "columns": []})["columns"].append(column(c, None))
            continue
        o["columns"].append(column(c, o["details"]["collation"], o["_create"]))


def generated(create, name):
    """A generated column's expression as SHOW CREATE TABLE writes it (information_schema's copy escapes its quotes on 8.0)."""
    for line in create.split("\n"):
        if line.startswith(f"  {q(name)} ") and " GENERATED ALWAYS AS (" in line:
            start = line.index(" GENERATED ALWAYS AS (") + len(" GENERATED ALWAYS AS (")
            depth, i, quote = 1, start, None
            while depth:
                ch = line[i]
                if quote:
                    if ch == "\\":
                        i += 1
                    elif ch == quote:
                        quote = None
                elif ch in "'\"`":
                    quote = ch
                else:
                    depth += {"(": 1, ")": -1}.get(ch, 0)
                i += 1
            return line[start:i - 1]
    return None


def column(c, table_collation, create=None):
    extra = (c["extra"] or "").lower()
    gen = (generated(create, c["name"]) if create else None) or c["gen"] or None
    default = c["default"]
    expression = "default_generated" in extra or bool(default and re.match(r"^(current_timestamp|now)(\(\d*\))?$", default, re.I))
    on_update = re.search(r"on update (current_timestamp(\(\d+\))?)", extra)
    coll = c["coll"] if c["coll"] and c["coll"] != table_collation else None
    cs = c["cs"] if coll else None
    return {"name": c["name"], "type": c["type"], "nullable": bool(c["nullable"]), "default": default if not gen else None,
            "default_is_expression": expression and not gen, "generated_expression": gen, "generated_stored": ("stored generated" in extra) if gen else None,
            "collation": coll, "character_set": cs, "on_update": on_update.group(1).upper() if on_update else None,
            "auto_increment": "auto_increment" in extra, "invisible": "invisible" in extra, "srid": c["srs"], "comment": c["comment"] or None}


def read_indexes(server, by, major):
    expr = "EXPRESSION" if major >= (8, 0) else "NULL"
    vis = "IS_VISIBLE = 'NO'" if major >= (8, 0) else "false"
    rows = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TABLE_SCHEMA, 't', TABLE_NAME, 'name', INDEX_NAME, 'unique', NON_UNIQUE = 0, 'seq', SEQ_IN_INDEX,
        'col', COLUMN_NAME, 'sub', SUB_PART, 'coll', COLLATION, 'type', INDEX_TYPE, 'expr', {expr}, 'invisible', {vis}, 'comment', INDEX_COMMENT))
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN {SYS_LIST}""") or []
    found = {}
    for s in rows:
        o = by.get((s["db"], s["t"]))
        if o is None:
            continue
        i = found.setdefault((s["db"], s["t"], s["name"]), {"name": s["name"], "unique": bool(s["unique"]), "type": s["type"], "parts": []})
        i["parts"].append((s["seq"], {"column": s["col"], "expression": s["expr"], "prefix": s["sub"], "descending": s["coll"] == "D"}))
    for (db, t, name), i in found.items():
        o = by[(db, t)]
        clauses = index_clauses(o["_create"]).get(name, {})
        kind = {"FULLTEXT": "fulltext", "SPATIAL": "spatial"}.get(i["type"], "index")
        if kind == "spatial":
            # information_schema gives a SPATIAL part an internal prefix (32) the statement never writes
            for _, p in i["parts"]:
                p["prefix"] = None
        o["indexes"].append({"name": name, "unique": i["unique"], "kind": kind, "method": clauses.get("method"), "key_block_size": clauses.get("key_block_size"),
                             "parser": clauses.get("parser"), "comment": clauses.get("comment"), "invisible": clauses.get("invisible", False),
                             "parts": [p for _, p in sorted(i["parts"], key=lambda x: x[0])], "_position": clauses.get("position", 999)})
    for o in by.values():
        o["indexes"].sort(key=lambda i: i.pop("_position"))
        for i in o["indexes"]:
            if i["name"] == "PRIMARY" or i["unique"]:
                o["constraints"].append({"name": i["name"], "kind": "primary" if i["name"] == "PRIMARY" else "unique",
                                         "columns": [p["column"] for p in i["parts"]]})


def read_constraints(server, by, major):
    fks = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', k.TABLE_SCHEMA, 't', k.TABLE_NAME, 'name', k.CONSTRAINT_NAME, 'col', k.COLUMN_NAME, 'pos', k.ORDINAL_POSITION,
        'to_db', k.REFERENCED_TABLE_SCHEMA, 'to_t', k.REFERENCED_TABLE_NAME, 'to_col', k.REFERENCED_COLUMN_NAME, 'del', r.DELETE_RULE, 'upd', r.UPDATE_RULE))
        FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
          ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
        WHERE k.TABLE_SCHEMA NOT IN {SYS_LIST}""") or []
    found = {}
    for f in fks:
        c = found.setdefault((f["db"], f["t"], f["name"]), {"name": f["name"], "kind": "foreign", "columns": [], "to": [f["to_db"], f["to_t"]], "to_columns": [],
                                                            "on_delete": f["del"], "on_update": f["upd"], "_cols": []})
        c["_cols"].append((f["pos"], f["col"], f["to_col"]))
    for (db, t, name), c in found.items():
        cols = sorted(c.pop("_cols"))
        c["columns"], c["to_columns"] = [x[1] for x in cols], [x[2] for x in cols]
    order = {}
    for (db, t, name), c in found.items():
        create = by[(db, t)]["_create"]
        order[(db, t, name)] = create.find(f"CONSTRAINT {q(name)} FOREIGN KEY")
    for k in sorted(found, key=lambda k: order[k]):
        by[(k[0], k[1])]["constraints"].append(found[k])
    if major >= (8, 0):
        checks = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', t.TABLE_SCHEMA, 't', t.TABLE_NAME, 'name', t.CONSTRAINT_NAME, 'expr', c.CHECK_CLAUSE, 'enforced', t.ENFORCED = 'YES'))
            FROM information_schema.TABLE_CONSTRAINTS t JOIN information_schema.CHECK_CONSTRAINTS c ON c.CONSTRAINT_SCHEMA = t.CONSTRAINT_SCHEMA AND c.CONSTRAINT_NAME = t.CONSTRAINT_NAME
            WHERE t.CONSTRAINT_TYPE = 'CHECK' AND t.TABLE_SCHEMA NOT IN {SYS_LIST}""") or []
        for c in sorted(checks, key=lambda c: by[(c["db"], c["t"])]["_create"].find(f"CONSTRAINT {q(c['name'])} CHECK") if (c["db"], c["t"]) in by else 0):
            o = by.get((c["db"], c["t"]))
            if o is not None:
                o["constraints"].append({"name": c["name"], "kind": "check", "expression": c["expr"], "enforced": bool(c["enforced"])})


def read_partitions(server, by):
    rows = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TABLE_SCHEMA, 't', TABLE_NAME, 'p', PARTITION_NAME, 'sp', SUBPARTITION_NAME,
        'ppos', PARTITION_ORDINAL_POSITION, 'spos', SUBPARTITION_ORDINAL_POSITION, 'method', PARTITION_METHOD, 'smethod', SUBPARTITION_METHOD,
        'expr', PARTITION_EXPRESSION, 'sexpr', SUBPARTITION_EXPRESSION, 'desc', PARTITION_DESCRIPTION, 'comment', PARTITION_COMMENT))
        FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA NOT IN {SYS_LIST} AND PARTITION_NAME IS NOT NULL""") or []
    for r in sorted(rows, key=lambda r: (r["db"], r["t"], r["ppos"], r["spos"] or 0)):
        o = by[(r["db"], r["t"])]
        create = o["_create"]
        if o["partitioning"] is None:
            alg = re.search(r"PARTITION BY (?:LINEAR )?KEY ALGORITHM = (\d)", create)
            salg = re.search(r"SUBPARTITION BY (?:LINEAR )?KEY ALGORITHM = (\d)", create)
            o["partitioning"] = {"method": r["method"], "expression": r["expr"], "key_algorithm": int(alg.group(1)) if alg else None,
                                 "sub_method": r["smethod"], "sub_expression": r["sexpr"], "sub_key_algorithm": int(salg.group(1)) if salg else None,
                                 "listed": bool(re.search(r"\(PARTITION ", create)), "sub_listed": "SUBPARTITION `" in create}
        parts = o["partitions"]
        if not parts or parts[-1]["name"] != r["p"]:
            values = None
            if r["method"] and r["method"].startswith("RANGE"):
                values = f"LESS THAN ({r['desc']})" if r["desc"] != "MAXVALUE" else "LESS THAN MAXVALUE"
            elif r["method"] and r["method"].startswith("LIST"):
                values = f"IN ({r['desc']})"
            parts.append({"name": r["p"], "values": values, "comment": r["comment"] or None, "subpartitions": []})
        if r["sp"]:
            parts[-1]["subpartitions"].append({"name": r["sp"]})


# --- programs ----------------------------------------------------------------------------------------------------------
def read_views(server, model):
    views = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TABLE_SCHEMA, 'name', TABLE_NAME, 'def', VIEW_DEFINITION, 'check', CHECK_OPTION, 'definer', DEFINER,
        'security', SECURITY_TYPE, 'cs', CHARACTER_SET_CLIENT, 'cc', COLLATION_CONNECTION)) FROM information_schema.VIEWS WHERE TABLE_SCHEMA NOT IN {SYS_LIST}""") or []
    creates = server.rows([f"SHOW CREATE VIEW {q(v['db'])}.{q(v['name'])}" for v in views])
    for v, row in zip(views, creates):
        create = row[1]
        alg = re.search(r"ALGORITHM=(\w+)", create)
        head = re.search(r" VIEW (?:`(?:[^`]|``)*`\.)?`(?:[^`]|``)*` AS ", create)
        definition = create[head.end():]
        check = None
        for opt in ("CASCADED", "LOCAL"):
            if definition.endswith(f" WITH {opt} CHECK OPTION"):
                check, definition = opt, definition[: -len(f" WITH {opt} CHECK OPTION")]
        k = key(v["db"], "view", v["name"])
        o = model["objects"].setdefault(k, {"kind": "view", "columns": []})
        o.update({"comment": None, "details": {"definition": definition, "algorithm": alg.group(1) if alg else "UNDEFINED", "definer": definer(v["definer"]),
                                               "security": v["security"], "check_option": check, "character_set_client": v["cs"], "collation_connection": v["cc"]},
                  "uses": sorted(set(re.findall(r"`([^`]+)`\.`([^`]+)`", definition)))})
        o["uses"] = [list(u) for u in o["uses"] if key(u[0], "table", u[1]) in model["objects"] or key(u[0], "view", u[1]) in model["objects"] or True]


def definer(d):
    user, _, host = d.rpartition("@")
    return f"{q(user)}@{q(host)}"


def read_routines(server, model):
    routines = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', ROUTINE_SCHEMA, 'name', ROUTINE_NAME, 'type', ROUTINE_TYPE, 'det', IS_DETERMINISTIC = 'YES',
        'access', SQL_DATA_ACCESS, 'security', SECURITY_TYPE, 'definer', DEFINER, 'mode', SQL_MODE, 'comment', ROUTINE_COMMENT,
        'cs', CHARACTER_SET_CLIENT, 'cc', COLLATION_CONNECTION, 'dbc', DATABASE_COLLATION)) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN {SYS_LIST}""") or []
    creates = server.rows([f"SHOW CREATE {r['type']} {q(r['db'])}.{q(r['name'])}" for r in routines])
    for r, row in zip(routines, creates):
        create = row[2]
        head = re.search(rf"{r['type']} {re.escape(q(r['name']))}\(", create)
        start = head.end()
        depth, i = 1, start
        while depth:
            depth += {"(": 1, ")": -1}.get(create[i], 0)
            i += 1
        params_text = create[start:i - 1]
        rest = create[i:]
        returns = None
        if r["type"] == "FUNCTION":
            m = re.match(r" RETURNS (.+?)\n", rest)
            returns, rest = m.group(1), rest[m.end():]
        else:
            rest = rest.lstrip("\n")
        lines = rest.split("\n")
        n = 0
        while n < len(lines) and re.match(r"^    (DETERMINISTIC|NOT DETERMINISTIC|CONTAINS SQL|NO SQL|READS SQL DATA|MODIFIES SQL DATA|SQL SECURITY \w+|COMMENT '|LANGUAGE \w+)", lines[n]):
            n += 1
        body = "\n".join(lines[n:])
        model["objects"][key(r["db"], r["type"].lower(), r["name"])] = {
            "kind": r["type"].lower(), "comment": r["comment"] or None,
            "details": {"returns": returns, "deterministic": bool(r["det"]), "data_access": r["access"], "security": r["security"], "definer": definer(r["definer"]),
                        "body": body, "sql_mode": r["mode"], "character_set_client": r["cs"], "collation_connection": r["cc"], "database_collation": r["dbc"]},
            "parameters": params(params_text, r["type"])}


def params(text, kind):
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        depth += {"(": 1, ")": -1}.get(ch, 0)
        cur += ch
    if cur.strip():
        out.append(cur)
    res = []
    for p in out:
        p = p.strip()
        mode = None
        m = re.match(r"^(IN|OUT|INOUT)\s+", p, re.I) if kind == "PROCEDURE" else None
        if m:
            mode, p = m.group(1).upper(), p[m.end():]
        name, _, typ = p.partition(" ")
        res.append({"mode": mode, "name": name, "type": typ.strip()})
    return res


def read_triggers(server, model):
    triggers = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', TRIGGER_SCHEMA, 'name', TRIGGER_NAME, 'table', EVENT_OBJECT_TABLE, 'timing', ACTION_TIMING,
        'event', EVENT_MANIPULATION, 'order', ACTION_ORDER, 'body', ACTION_STATEMENT, 'definer', DEFINER, 'mode', SQL_MODE, 'cs', CHARACTER_SET_CLIENT,
        'cc', COLLATION_CONNECTION, 'dbc', DATABASE_COLLATION)) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN {SYS_LIST}""") or []
    for t in triggers:
        model["objects"][key(t["db"], "trigger", t["name"])] = {
            "kind": "trigger", "comment": None, "parent": key(t["db"], "table", t["table"]),
            "details": {"timing": t["timing"], "event": t["event"], "action_order": t["order"], "body": t["body"], "definer": definer(t["definer"]),
                        "sql_mode": t["mode"], "character_set_client": t["cs"], "collation_connection": t["cc"], "database_collation": t["dbc"]}}


def read_events(server, model):
    events = server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('db', EVENT_SCHEMA, 'name', EVENT_NAME, 'body', EVENT_DEFINITION, 'type', EVENT_TYPE,
        'at', CAST(EXECUTE_AT AS CHAR), 'iv', CAST(INTERVAL_VALUE AS CHAR), 'if', INTERVAL_FIELD, 'starts', CAST(STARTS AS CHAR), 'ends', CAST(ENDS AS CHAR),
        'status', STATUS, 'completion', ON_COMPLETION,
        'comment', EVENT_COMMENT, 'definer', DEFINER, 'tz', TIME_ZONE, 'mode', SQL_MODE, 'cs', CHARACTER_SET_CLIENT, 'cc', COLLATION_CONNECTION,
        'dbc', DATABASE_COLLATION)) FROM information_schema.EVENTS WHERE EVENT_SCHEMA NOT IN {SYS_LIST}""") or []
    status = {"ENABLED": "ENABLE", "DISABLED": "DISABLE", "SLAVESIDE_DISABLED": "DISABLE ON SLAVE", "REPLICA_SIDE_DISABLED": "DISABLE ON REPLICA"}
    for e in events:
        model["objects"][key(e["db"], "event", e["name"])] = {
            "kind": "event", "comment": e["comment"] or None,
            "details": {"execute_at": e["at"], "interval_value": e["iv"], "interval_field": e["if"], "starts": e["starts"], "ends": e["ends"],
                        "on_completion": e["completion"], "status": status[e["status"]], "body": e["body"], "definer": definer(e["definer"]),
                        "time_zone": e["tz"], "sql_mode": e["mode"], "character_set_client": e["cs"], "collation_connection": e["cc"], "database_collation": e["dbc"]}}
