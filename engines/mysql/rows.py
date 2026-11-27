"""engine_mysql's rows: the plugin's model as the rows of the cortex and engine_mysql that hold it, and back. Written by
engine_mysql_service, under the operation of the app's turn (decision plugin-writes); every row's id a UUIDv7 made here.

  insert_sql(model, design)  -> the SQL that stores the model as a design's rows
  select_sql(design)         -> one query giving every row of the design as JSON
  model_from(rows)           -> the model again, the same shape the reader gives"""
import secrets
import time

RULES = {"CASCADE": "cascade", "SET NULL": "set_null", "SET DEFAULT": "set_default", "RESTRICT": "restrict", "NO ACTION": "no_action"}
BACK = {v: k for k, v in RULES.items()}
TABLE_OPTIONAL = ("row_format", "avg_row_length", "min_rows", "max_rows", "pack_keys", "checksum", "delay_key_write", "key_block_size",
                  "stats_persistent", "stats_auto_recalc", "stats_sample_pages", "compression", "encryption", "autoextend_size")
PROGRAM_CONTEXT = ("sql_mode", "character_set_client", "collation_connection", "database_collation")


def uuid7():
    b = bytearray(int(time.time() * 1000).to_bytes(6, "big") + secrets.token_bytes(10))
    b[6] = 0x70 | (b[6] & 0x0F)
    b[8] = 0x80 | (b[8] & 0x3F)
    h = b.hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def v(x):
    if x is None:
        return "NULL"
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, int):
        return str(x)
    return "'" + str(x).replace("'", "''") + "'"


def ins(table, row):
    return f"INSERT INTO {table} ({', '.join(row)}) VALUES ({', '.join(v(x) for x in row.values())});"


def insert_sql(model, design):
    out, ids = [], {}
    inst = model["instance"]
    server = uuid7()
    out.append(ins("cortex.namespaces", {"id": server, "design": design, "name": "server", "position": 1}))
    out.append(ins("engine_mysql.instances", {"id": server, "design": design, "version": inst["version"], "character_set": inst["character_set"],
                                              '"collation"': inst["collation"], "lower_case_table_names": inst["lower_case_table_names"], "sql_mode": inst["sql_mode"]}))
    dbs = {}
    for n, (name, d) in enumerate(sorted(model["databases"].items())):
        dbs[name] = uuid7()
        out.append(ins("cortex.namespaces", {"id": dbs[name], "design": design, "parent": server, "name": name, "position": n + 1}))
        out.append(ins("engine_mysql.databases", {"id": dbs[name], "design": design, "character_set": d["character_set"], '"collation"': d["collation"],
                                                  "encryption": d.get("encryption"), "read_only": d.get("read_only")}))
    position = {}
    objects = model["objects"]
    for k in sorted(objects, key=lambda k: (objects[k]["kind"] == "trigger", k)):
        db, kind, name = k.split("|", 2)
        o = objects[k]
        ids[k] = uuid7()
        position[db] = position.get(db, 0) + 1
        out.append(ins("cortex.objects", {"id": ids[k], "design": design, "engine": "mysql", "namespace": dbs[db], "kind": kind, "name": name,
                                          "parent": ids.get(o.get("parent")), "position": position[db], "comment": o.get("comment")}))
    cols = {}
    for k, o in sorted(objects.items()):
        db, kind, name = k.split("|", 2)
        for p, c in enumerate(o.get("columns", [])):
            cid = cols[(k, c["name"])] = uuid7()
            out.append(ins("cortex.columns", {"id": cid, "design": design, "object": ids[k], "position": p + 1, "name": c["name"], "type": c["type"],
                                              "nullable": c["nullable"], "default_value": c["default"], "generated_expression": c["generated_expression"],
                                              "generated_stored": c["generated_stored"], '"collation"': c["collation"], "comment": c["comment"]}))
            out.append(ins("engine_mysql.columns", {"id": cid, "design": design, "character_set": c["character_set"], "default_is_expression": c["default_is_expression"],
                                                    "on_update": c["on_update"], "auto_increment": c["auto_increment"], "invisible": c["invisible"], "srid": c["srid"]}))
    for k, o in sorted(objects.items()):
        kind = o["kind"]
        if kind == "table":
            out += table_rows(k, o, design, ids, cols)
        elif kind == "view":
            d = o["details"]
            out.append(ins("engine_mysql.views", {"id": ids[k], "design": design, "definition": d["definition"], "algorithm": d["algorithm"], "definer": d["definer"],
                                                  "security": d["security"], "check_option": d["check_option"], "character_set_client": d["character_set_client"],
                                                  "collation_connection": d["collation_connection"]}))
            for u in o.get("uses", []):
                used = ids.get(f"{u[0]}|table|{u[1]}") or ids.get(f"{u[0]}|view|{u[1]}")
                out.append(ins("cortex.dependencies", {"design": design, "object": ids[k], "uses": used, '"as"': "reads"}))
        elif kind in ("procedure", "function"):
            d = o["details"]
            row = {"id": ids[k], "design": design, "returns": d["returns"], "deterministic": d["deterministic"], "data_access": d["data_access"],
                   "security": d["security"], "definer": d["definer"], "body": d["body"]}
            row.update({c: d[c] for c in PROGRAM_CONTEXT})
            out.append(ins("engine_mysql.routines", row))
            for p, prm in enumerate(o.get("parameters", [])):
                out.append(ins("engine_mysql.routine_parameters", {"design": design, "routine": ids[k], "position": p + 1, "mode": prm["mode"], "name": prm["name"], "type": prm["type"]}))
        elif kind == "trigger":
            d = o["details"]
            row = {"id": ids[k], "design": design, "timing": d["timing"], "event": d["event"], "action_order": d["action_order"], "body": d["body"], "definer": d["definer"]}
            row.update({c: d[c] for c in PROGRAM_CONTEXT})
            out.append(ins("engine_mysql.triggers", row))
        elif kind == "event":
            d = o["details"]
            row = {"id": ids[k], "design": design}
            row.update({c: d[c] for c in ("execute_at", "interval_value", "interval_field", "starts", "ends", "on_completion", "status", "body", "definer", "time_zone")})
            row.update({c: d[c] for c in PROGRAM_CONTEXT})
            out.append(ins("engine_mysql.events", row))
    return "\n".join(out), len(out)


def table_rows(k, o, design, ids, cols):
    out, d = [], o["details"]
    row = {"id": ids[k], "design": design, "engine": d["engine"], '"collation"': d["collation"], "auto_increment": d.get("auto_increment"),
           "tablespace": d.get("tablespace"), "insert_method": d.get("insert_method")}
    row.update({f: d.get(f) for f in TABLE_OPTIONAL})
    out.append(ins("engine_mysql.tables", row))
    for p, i in enumerate(o["indexes"]):
        iid = uuid7()
        out.append(ins("cortex.indexes", {"id": iid, "design": design, "object": ids[k], "position": p + 1, "name": i["name"], '"unique"': i["unique"],
                                          "method": i["method"], "comment": i["comment"]}))
        out.append(ins("engine_mysql.indexes", {"id": iid, "design": design, "kind": i["kind"], "parser": i["parser"], "key_block_size": i["key_block_size"],
                                                "invisible": i["invisible"]}))
        for n, part in enumerate(i["parts"]):
            pid = uuid7()
            out.append(ins("cortex.index_parts", {"id": pid, "design": design, '"index"': iid, "position": n + 1,
                                                  '"column"': cols.get((k, part["column"])) if part["column"] else None,
                                                  "expression": part["expression"], "descending": part["descending"]}))
            if part.get("prefix"):
                out.append(ins("engine_mysql.index_parts", {"id": pid, "design": design, "prefix_length": part["prefix"]}))
    for p, c in enumerate(o["constraints"]):
        kid = uuid7()
        to = ids.get(f"{c['to'][0]}|table|{c['to'][1]}") if c["kind"] == "foreign" else None
        out.append(ins("cortex.constraints", {"id": kid, "design": design, "object": ids[k], "position": p + 1, "name": c["name"], "kind": c["kind"],
                                              "expression": c.get("expression"), "to_object": to, "on_delete": RULES.get(c.get("on_delete")),
                                              "on_update": RULES.get(c.get("on_update")), "enforced": c.get("enforced", True)}))
        for n, col in enumerate(c.get("columns") or []):
            to_col = cols.get((f"{c['to'][0]}|table|{c['to'][1]}", c["to_columns"][n])) if c["kind"] == "foreign" else None
            out.append(ins("cortex.constraint_columns", {"design": design, '"constraint"': kid, "position": n + 1, '"column"': cols[(k, col)], "to_column": to_col}))
    for n, u in enumerate(o.get("union", [])):
        db = k.split("|", 1)[0]
        out.append(ins("cortex.dependencies", {"design": design, "object": ids[k], "uses": ids[f"{db}|table|{u}"], '"as"': "union", "position": n + 1}))
    p = o.get("partitioning")
    if p:
        out.append(ins("engine_mysql.partitionings", {"id": ids[k], "design": design, "method": p["method"], "expression": p["expression"], "key_algorithm": p["key_algorithm"],
                                                      "partition_count": None if p["listed"] else len(o["partitions"]), "sub_method": p["sub_method"],
                                                      "sub_expression": p["sub_expression"], "sub_key_algorithm": p["sub_key_algorithm"],
                                                      "subpartition_count": len(o["partitions"][0]["subpartitions"]) if p["sub_method"] and not p["sub_listed"] else None}))
        for n, part in enumerate(o["partitions"]):
            pid = uuid7()
            out.append(ins("engine_mysql.partitions", {"id": pid, "design": design, "partitioning": ids[k], "position": n + 1, "name": part["name"],
                                                       '"values"': part["values"], "comment": part["comment"]}))
            for m, sp in enumerate(part["subpartitions"]):
                out.append(ins("engine_mysql.partitions", {"design": design, "partitioning": ids[k], "parent": pid, "position": m + 1, "name": sp["name"]}))
    return out


def select_sql(design):
    """Every row of a design, as one JSON object of lists, each row with what model_from needs."""
    d = f"'{design}'"
    return f"""SELECT json_build_object(
  'instance', (SELECT to_jsonb(i) FROM engine_mysql.instances i WHERE i.design = {d}),
  'databases', (SELECT jsonb_agg(to_jsonb(x) || jsonb_build_object('name', n.name)) FROM engine_mysql.databases x JOIN cortex.namespaces n ON n.id = x.id WHERE x.design = {d}),
  'objects', (SELECT jsonb_agg(to_jsonb(o) || jsonb_build_object('db', n.name, 'parent_key', (SELECT pn.name || '|' || p.kind || '|' || p.name FROM cortex.objects p JOIN cortex.namespaces pn ON pn.id = p.namespace WHERE p.id = o.parent)))
              FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.design = {d}),
  'columns', (SELECT jsonb_agg(to_jsonb(c) || to_jsonb(m) - 'id' - 'design' ORDER BY c.object, c.position) FROM cortex.columns c JOIN engine_mysql.columns m ON m.id = c.id WHERE c.design = {d}),
  'tables', (SELECT jsonb_agg(to_jsonb(t)) FROM engine_mysql.tables t WHERE t.design = {d}),
  'indexes', (SELECT jsonb_agg(to_jsonb(i) || to_jsonb(m) - 'id' - 'design' || jsonb_build_object('id', i.id) ORDER BY i.object, i.position) FROM cortex.indexes i JOIN engine_mysql.indexes m ON m.id = i.id WHERE i.design = {d}),
  'index_parts', (SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('column_name', c.name, 'prefix', x.prefix_length) ORDER BY p."index", p.position)
                  FROM cortex.index_parts p LEFT JOIN cortex.columns c ON c.id = p."column" LEFT JOIN engine_mysql.index_parts x ON x.id = p.id WHERE p.design = {d}),
  'constraints', (SELECT jsonb_agg(to_jsonb(k) || jsonb_build_object('to_key', (SELECT tn.name || '|' || t.name FROM cortex.objects t JOIN cortex.namespaces tn ON tn.id = t.namespace WHERE t.id = k.to_object),
                    'cols', (SELECT jsonb_agg(c.name ORDER BY cc.position) FROM cortex.constraint_columns cc JOIN cortex.columns c ON c.id = cc."column" WHERE cc."constraint" = k.id),
                    'to_cols', (SELECT jsonb_agg(c.name ORDER BY cc.position) FROM cortex.constraint_columns cc JOIN cortex.columns c ON c.id = cc.to_column WHERE cc."constraint" = k.id))
                  ORDER BY k.object, k.position) FROM cortex.constraints k WHERE k.design = {d}),
  'dependencies', (SELECT jsonb_agg(to_jsonb(x) || jsonb_build_object('uses_key', un.name || '|' || u.name) ORDER BY x.object, x."as", x.position, un.name, u.name)
                   FROM cortex.dependencies x JOIN cortex.objects u ON u.id = x.uses JOIN cortex.namespaces un ON un.id = u.namespace WHERE x.design = {d}),
  'partitionings', (SELECT jsonb_agg(to_jsonb(p)) FROM engine_mysql.partitionings p WHERE p.design = {d}),
  'partitions', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.partitioning, p.parent NULLS FIRST, p.position) FROM engine_mysql.partitions p WHERE p.design = {d}),
  'views', (SELECT jsonb_agg(to_jsonb(x)) FROM engine_mysql.views x WHERE x.design = {d}),
  'routines', (SELECT jsonb_agg(to_jsonb(x)) FROM engine_mysql.routines x WHERE x.design = {d}),
  'parameters', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.routine, x.position) FROM engine_mysql.routine_parameters x WHERE x.design = {d}),
  'triggers', (SELECT jsonb_agg(to_jsonb(x)) FROM engine_mysql.triggers x WHERE x.design = {d}),
  'events', (SELECT jsonb_agg(to_jsonb(x)) FROM engine_mysql.events x WHERE x.design = {d}))"""


def model_from(r):
    inst = r["instance"]
    model = {"instance": {"version": inst["version"], "character_set": inst["character_set"], "collation": inst["collation"],
                          "lower_case_table_names": inst["lower_case_table_names"], "sql_mode": inst["sql_mode"]},
             "databases": {d["name"]: {"character_set": d["character_set"], "collation": d["collation"], "encryption": d["encryption"], "read_only": d["read_only"]}
                           for d in r["databases"] or []},
             "objects": {}}
    by_id, objects = {}, model["objects"]
    for o in r["objects"] or []:
        k = f"{o['db']}|{o['kind']}|{o['name']}"
        by_id[o["id"]] = k
        entry = {"kind": o["kind"], "comment": o["comment"]}
        if o["kind"] == "table":
            entry.update({"details": None, "columns": [], "indexes": [], "constraints": [], "union": [], "partitioning": None, "partitions": []})
        elif o["kind"] == "view":
            entry.update({"columns": [], "details": None, "uses": []})
        elif o["kind"] in ("procedure", "function"):
            entry.update({"details": None, "parameters": []})
        elif o["kind"] == "trigger":
            entry["parent"] = o["parent_key"]
        objects[k] = entry
    for c in r["columns"] or []:
        objects[by_id[c["object"]]]["columns"].append({
            "name": c["name"], "type": c["type"], "nullable": c["nullable"], "default": c["default_value"], "default_is_expression": c["default_is_expression"],
            "generated_expression": c["generated_expression"], "generated_stored": c["generated_stored"], "collation": c["collation"],
            "character_set": c["character_set"], "on_update": c["on_update"], "auto_increment": c["auto_increment"], "invisible": c["invisible"],
            "srid": c["srid"], "comment": c["comment"]})
    for t in r["tables"] or []:
        d = {"engine": t["engine"], "collation": t["collation"], "auto_increment": t["auto_increment"], "tablespace": t["tablespace"], "insert_method": t["insert_method"]}
        d.update({f: t[f] for f in TABLE_OPTIONAL if t[f] is not None})
        objects[by_id[t["id"]]]["details"] = d
    parts = {}
    for p in r["index_parts"] or []:
        parts.setdefault(p["index"], []).append({"column": p["column_name"], "expression": p["expression"], "prefix": p["prefix"], "descending": p["descending"]})
    for i in r["indexes"] or []:
        objects[by_id[i["object"]]]["indexes"].append({"name": i["name"], "unique": i["unique"], "kind": i["kind"], "method": i["method"], "key_block_size": i["key_block_size"],
                                                       "parser": i["parser"], "comment": i["comment"], "invisible": i["invisible"], "parts": parts.get(i["id"], [])})
    for k in r["constraints"] or []:
        c = {"name": k["name"], "kind": k["kind"]}
        if k["kind"] in ("primary", "unique"):
            c["columns"] = k["cols"]
        elif k["kind"] == "foreign":
            c.update({"columns": k["cols"], "to": k["to_key"].split("|", 1), "to_columns": k["to_cols"], "on_delete": BACK.get(k["on_delete"]), "on_update": BACK.get(k["on_update"])})
        else:
            c.update({"expression": k["expression"], "enforced": k["enforced"]})
        objects[by_id[k["object"]]]["constraints"].append(c)
    for x in r["dependencies"] or []:
        o = objects[by_id[x["object"]]]
        if x["as"] == "union":
            o["union"].append(x["uses_key"].split("|", 1)[1])
        elif x["as"] == "reads":
            o["uses"].append(x["uses_key"].split("|", 1))
    for o in objects.values():
        if o["kind"] == "view":
            o["uses"].sort()
    pmap = {}
    for p in r["partitionings"] or []:
        pmap[p["id"]] = p
        objects[by_id[p["id"]]]["partitioning"] = {"method": p["method"], "expression": p["expression"], "key_algorithm": p["key_algorithm"],
                                                   "sub_method": p["sub_method"], "sub_expression": p["sub_expression"], "sub_key_algorithm": p["sub_key_algorithm"],
                                                   "listed": p["partition_count"] is None, "sub_listed": bool(p["sub_method"]) and p["subpartition_count"] is None}
    top = {}
    for p in r["partitions"] or []:
        if p["parent"] is None:
            top[p["id"]] = {"name": p["name"], "values": p["values"], "comment": p["comment"], "subpartitions": []}
            objects[by_id[p["partitioning"]]]["partitions"].append(top[p["id"]])
        else:
            top[p["parent"]]["subpartitions"].append({"name": p["name"]})
    for x in r["views"] or []:
        objects[by_id[x["id"]]]["details"] = {f: x[f] for f in ("definition", "algorithm", "definer", "security", "check_option", "character_set_client", "collation_connection")}
    for x in r["routines"] or []:
        objects[by_id[x["id"]]]["details"] = {f: x[f] for f in ("returns", "deterministic", "data_access", "security", "definer", "body") + PROGRAM_CONTEXT}
    for x in r["parameters"] or []:
        objects[by_id[x["routine"]]]["parameters"].append({"mode": x["mode"], "name": x["name"], "type": x["type"]})
    for x in r["triggers"] or []:
        objects[by_id[x["id"]]]["details"] = {f: x[f] for f in ("timing", "event", "action_order", "body", "definer") + PROGRAM_CONTEXT}
    for x in r["events"] or []:
        objects[by_id[x["id"]]]["details"] = {f: x[f] for f in ("execute_at", "interval_value", "interval_field", "starts", "ends", "on_completion", "status",
                                                                 "body", "definer", "time_zone") + PROGRAM_CONTEXT}
    return model
