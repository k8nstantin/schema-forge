"""The model every engine shares, read three ways and compared: from a MySQL server's information_schema, from a
PostgreSQL server's pg_catalog, and from the cortex after it is stored there. Each gives the same shape:

  {(namespace, kind, object): {"columns": [...], "constraints": [...], "indexes": [...]}}

with each list in the server's order, every field as the server writes it. Storing writes the shape into the cortex as
one import turn, with UUIDv7 ids made for every row."""
import os
import secrets
import time

from sf.fixture import in_turn

MYSQL_SYSTEM = "('mysql', 'information_schema', 'performance_schema', 'sys')"


def uuid7():
    ms = int(time.time() * 1000)
    b = bytearray(ms.to_bytes(6, "big") + secrets.token_bytes(10))
    b[6] = 0x70 | (b[6] & 0x0F)
    b[8] = 0x80 | (b[8] & 0x3F)
    h = b.hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def mysql_model(server):
    objs = {}
    for t in server.json(f"SELECT JSON_ARRAYAGG(JSON_OBJECT('ns', TABLE_SCHEMA, 'name', TABLE_NAME, 'kind', IF(TABLE_TYPE = 'VIEW', 'view', 'table'))) "
                         f"FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN {MYSQL_SYSTEM}"):
        objs[(t["ns"], t["kind"], t["name"])] = {"columns": [], "constraints": [], "indexes": []}
    kinds = {(ns, n): k for ns, k, n in objs}
    for c in sorted(server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('ns', TABLE_SCHEMA, 't', TABLE_NAME, 'pos', ORDINAL_POSITION, 'name', COLUMN_NAME,
                    'type', CAST(COLUMN_TYPE AS CHAR), 'nullable', IS_NULLABLE = 'YES', 'default', COLUMN_DEFAULT, 'gen', NULLIF(GENERATION_EXPRESSION, ''),
                    'stored', EXTRA LIKE '%STORED GENERATED%', 'collation', COLLATION_NAME, 'comment', NULLIF(COLUMN_COMMENT, '')))
                    FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN {MYSQL_SYSTEM}"""), key=lambda c: (c["ns"], c["t"], c["pos"])):
        objs[(c["ns"], kinds[(c["ns"], c["t"])], c["t"])]["columns"].append(
            [c["pos"], c["name"], c["type"], bool(c["nullable"]), c["default"], c["gen"], bool(c["stored"]) if c["gen"] else None, c["collation"], c["comment"]])
    keys = {}
    for k in server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('ns', k.TABLE_SCHEMA, 't', k.TABLE_NAME, 'name', k.CONSTRAINT_NAME, 'kind', k.CONSTRAINT_TYPE,
                    'col', u.COLUMN_NAME, 'pos', u.ORDINAL_POSITION, 'to_ns', u.REFERENCED_TABLE_SCHEMA, 'to_t', u.REFERENCED_TABLE_NAME, 'to_col', u.REFERENCED_COLUMN_NAME,
                    'del', r.DELETE_RULE, 'upd', r.UPDATE_RULE))
                    FROM information_schema.TABLE_CONSTRAINTS k
                    JOIN information_schema.KEY_COLUMN_USAGE u ON u.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND u.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND u.TABLE_NAME = k.TABLE_NAME
                    LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
                    WHERE k.TABLE_SCHEMA NOT IN {MYSQL_SYSTEM} AND k.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')"""):
        kind = {"PRIMARY KEY": "primary", "UNIQUE": "unique", "FOREIGN KEY": "foreign"}[k["kind"]]
        key = keys.setdefault((k["ns"], k["t"], k["name"]), {"kind": kind, "cols": [], "to": (k["to_ns"], k["to_t"]) if k["to_t"] else None,
                                                               "del": rule(k["del"]), "upd": rule(k["upd"])})
        key["cols"].append((k["pos"], k["col"], k["to_col"]))
    for (ns, t, name), k in sorted(keys.items()):
        objs[(ns, "table", t)]["constraints"].append([name, k["kind"], None, [c for _, c, _ in sorted(k["cols"])],
                                                     list(k["to"]) if k["to"] else None, [tc for _, _, tc in sorted(k["cols"])] if k["to"] else None, k["del"], k["upd"]])
    idx = {}
    for s in server.json(f"""SELECT JSON_ARRAYAGG(JSON_OBJECT('ns', TABLE_SCHEMA, 't', TABLE_NAME, 'name', INDEX_NAME, 'unique', NON_UNIQUE = 0, 'seq', SEQ_IN_INDEX,
                    'col', COLUMN_NAME, 'desc', COLLATION = 'D', 'type', INDEX_TYPE))
                    FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN {MYSQL_SYSTEM}"""):
        i = idx.setdefault((s["ns"], s["t"], s["name"]), {"unique": bool(s["unique"]), "method": s["type"], "parts": []})
        i["parts"].append((s["seq"], s["col"], bool(s["desc"])))
    for (ns, t, name), i in sorted(idx.items()):
        objs[(ns, "table", t)]["indexes"].append([name, i["unique"], i["method"], [[c, d] for _, c, d in sorted(i["parts"])]])
    return objs


def rule(r):
    return {"NO ACTION": "no_action", "RESTRICT": "restrict", "CASCADE": "cascade", "SET NULL": "set_null", "SET DEFAULT": "set_default"}.get(r) if r else None


def postgresql_model(server, db):
    objs = {}
    system = "n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%'"
    for t in server.json(f"SELECT n.nspname AS ns, c.relname AS name, CASE c.relkind WHEN 'v' THEN 'view' ELSE 'table' END AS kind "
                         f"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'v') AND {system}", db):
        objs[(t["ns"], t["kind"], t["name"])] = {"columns": [], "constraints": [], "indexes": []}
    kinds = {(ns, n): k for ns, k, n in objs}
    for c in server.json(f"""SELECT n.nspname AS ns, c.relname AS t, a.attnum AS pos, a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type,
                    NOT a.attnotnull AS nullable, CASE WHEN a.attgenerated = '' THEN pg_get_expr(d.adbin, d.adrelid) END AS "default",
                    CASE WHEN a.attgenerated <> '' THEN pg_get_expr(d.adbin, d.adrelid) END AS gen, CASE WHEN a.attgenerated <> '' THEN a.attgenerated = 's' END AS stored,
                    CASE WHEN a.attcollation <> 0 AND a.attcollation <> (SELECT typcollation FROM pg_type WHERE oid = a.atttypid) THEN (SELECT collname FROM pg_collation WHERE oid = a.attcollation) END AS "collation",
                    col_description(c.oid, a.attnum) AS comment
                    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                    WHERE c.relkind IN ('r', 'p', 'v') AND a.attnum > 0 AND NOT a.attisdropped AND {system} ORDER BY 1, 2, 3""", db):
        objs[(c["ns"], kinds[(c["ns"], c["t"])], c["t"])]["columns"].append(
            [c["pos"], c["name"], c["type"], c["nullable"], c["default"], c["gen"], c["stored"], c["collation"], c["comment"]])
    for k in server.json(f"""SELECT n.nspname AS ns, c.relname AS t, k.conname AS name, k.contype AS kind,
                    CASE WHEN k.contype = 'c' THEN pg_get_expr(k.conbin, k.conrelid) END AS expr,
                    (SELECT array_agg(a.attname ORDER BY u.o) FROM unnest(k.conkey) WITH ORDINALITY u(n, o) JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.n) AS cols,
                    CASE WHEN k.contype = 'f' THEN json_build_array(fn.nspname, f.relname) END AS "to",
                    (SELECT array_agg(a.attname ORDER BY u.o) FROM unnest(k.confkey) WITH ORDINALITY u(n, o) JOIN pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = u.n) AS to_cols,
                    CASE WHEN k.contype = 'f' THEN k.confdeltype END AS del, CASE WHEN k.contype = 'f' THEN k.confupdtype END AS upd
                    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    LEFT JOIN pg_class f ON f.oid = k.confrelid LEFT JOIN pg_namespace fn ON fn.oid = f.relnamespace
                    WHERE k.contype IN ('p', 'u', 'f', 'c') AND {system} ORDER BY 1, 2, 3""", db):
        acts = {"a": "no_action", "r": "restrict", "c": "cascade", "n": "set_null", "d": "set_default"}
        objs[(k["ns"], "table", k["t"])]["constraints"].append(
            [k["name"], {"p": "primary", "u": "unique", "f": "foreign", "c": "check"}[k["kind"]], k["expr"], k["cols"] if k["kind"] != "c" else None,
             k["to"], k["to_cols"], acts.get(k["del"]), acts.get(k["upd"])])
    for i in server.json(f"""SELECT n.nspname AS ns, c.relname AS t, ic.relname AS name, x.indisunique AS "unique", am.amname AS method,
                    (SELECT json_agg(json_build_array(CASE WHEN x.indkey[o - 1] = 0 THEN NULL ELSE (SELECT attname FROM pg_attribute WHERE attrelid = c.oid AND attnum = x.indkey[o - 1]) END,
                                                      (x.indoption[o - 1] & 1) = 1) ORDER BY o) FROM generate_series(1, x.indnkeyatts) o) AS parts
                    FROM pg_index x JOIN pg_class ic ON ic.oid = x.indexrelid JOIN pg_class c ON c.oid = x.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    JOIN pg_am am ON am.oid = ic.relam WHERE {system} ORDER BY 1, 2, 3""", db):
        objs[(i["ns"], "table", i["t"])]["indexes"].append([i["name"], i["unique"], i["method"], i["parts"]])
    return objs


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def store_model(store, design, branch, engine, objs):
    """Writes the shape into the cortex as one import turn; every row's id a UUIDv7 made here."""
    sql, ns_ids, obj_ids, col_ids = [], {}, {}, {}
    for i, ns in enumerate(sorted({k[0] for k in objs})):
        ns_ids[ns] = uuid7()
        sql.append(f"INSERT INTO cortex.namespaces (id, design, name, position) VALUES ('{ns_ids[ns]}', '{design}', {q(ns)}, {i + 1});")
    pos = {}
    for (ns, kind, name) in sorted(objs):
        pos[ns] = pos.get(ns, 0) + 1
        obj_ids[(ns, name)] = uuid7()
        sql.append(f"INSERT INTO cortex.objects (id, design, engine, namespace, kind, name, position) VALUES "
                   f"('{obj_ids[(ns, name)]}', '{design}', '{engine}', '{ns_ids[ns]}', '{kind}', {q(name)}, {pos[ns]});")
    for (ns, kind, name), o in sorted(objs.items()):
        for p, cname, typ, nullable, default, gen, stored, coll, comment in o["columns"]:
            col_ids[(ns, name, cname)] = cid = uuid7()
            sql.append(f"INSERT INTO cortex.columns (id, design, object, position, name, type, nullable, default_value, generated_expression, generated_stored, \"collation\", comment) "
                       f"VALUES ('{cid}', '{design}', '{obj_ids[(ns, name)]}', {p}, {q(cname)}, {q(typ)}, {q(nullable)}, {q(default)}, {q(gen)}, {q(stored)}, {q(coll)}, {q(comment)});")
    for (ns, kind, name), o in sorted(objs.items()):
        for n, (kname, kkind, expr, cols, to, to_cols, d, u) in enumerate(o["constraints"]):
            kid = uuid7()
            to_obj = obj_ids.get(tuple(to)) if to else None
            if to and not to_obj:
                continue   # a key to a table outside the read: not in the model
            sql.append(f"INSERT INTO cortex.constraints (id, design, object, position, name, kind, expression, to_object, on_delete, on_update) VALUES "
                       f"('{kid}', '{design}', '{obj_ids[(ns, name)]}', {n + 1}, {q(kname)}, '{kkind}', {q(expr)}, {q(to_obj)}, {q(d)}, {q(u)});")
            for m, c in enumerate(cols or []):
                tc = col_ids[(to[0], to[1], to_cols[m])] if to else None
                sql.append(f"INSERT INTO cortex.constraint_columns (id, design, \"constraint\", position, \"column\", to_column) VALUES "
                           f"('{uuid7()}', '{design}', '{kid}', {m + 1}, '{col_ids[(ns, name, c)]}', {q(tc)});")
        for n, (iname, uniq, method, parts) in enumerate(o["indexes"]):
            iid = uuid7()
            sql.append(f"INSERT INTO cortex.indexes (id, design, object, position, name, \"unique\", method) VALUES "
                       f"('{iid}', '{design}', '{obj_ids[(ns, name)]}', {n + 1}, {q(iname)}, {q(uniq)}, {q(method)});")
            for m, (c, desc) in enumerate(parts):
                col = q(col_ids[(ns, name, c)]) if c else "NULL"
                expr = "NULL" if c else "'(expression)'"
                sql.append(f"INSERT INTO cortex.index_parts (id, design, \"index\", position, \"column\", expression, descending) VALUES "
                           f"('{uuid7()}', '{design}', '{iid}', {m + 1}, {col}, {expr}, {q(desc)});")
    store.sql(in_turn(design, branch, "\n".join(sql), kind="import", op_kind="import"))
    return len(sql)


def cortex_model(store, design):
    """The shape read back from the cortex."""
    import json
    rows = json.loads(store.value(f"""SELECT json_build_object(
      'objects', (SELECT json_agg(json_build_array(n.name, o.kind, o.name)) FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.design = '{design}'),
      'columns', (SELECT json_agg(json_build_array(n.name, o.name, c.position, c.name, c.type, c.nullable, c.default_value, c.generated_expression, c.generated_stored, c."collation", c.comment) ORDER BY n.name, o.name, c.position)
                  FROM cortex.columns c JOIN cortex.objects o ON o.id = c.object JOIN cortex.namespaces n ON n.id = o.namespace WHERE c.design = '{design}'),
      'constraints', (SELECT json_agg(json_build_array(n.name, o.name, k.name, k.kind, k.expression,
                        (SELECT json_agg(c.name ORDER BY cc.position) FROM cortex.constraint_columns cc JOIN cortex.columns c ON c.id = cc."column" WHERE cc."constraint" = k.id),
                        CASE WHEN k.to_object IS NOT NULL THEN json_build_array(tn.name, t.name) END,
                        (SELECT json_agg(c.name ORDER BY cc.position) FROM cortex.constraint_columns cc JOIN cortex.columns c ON c.id = cc.to_column WHERE cc."constraint" = k.id),
                        k.on_delete, k.on_update) ORDER BY n.name, o.name, k.position)
                  FROM cortex.constraints k JOIN cortex.objects o ON o.id = k.object JOIN cortex.namespaces n ON n.id = o.namespace
                  LEFT JOIN cortex.objects t ON t.id = k.to_object LEFT JOIN cortex.namespaces tn ON tn.id = t.namespace WHERE k.design = '{design}'),
      'indexes', (SELECT json_agg(json_build_array(n.name, o.name, i.name, i."unique", i.method,
                        (SELECT json_agg(json_build_array(c.name, p.descending) ORDER BY p.position) FROM cortex.index_parts p LEFT JOIN cortex.columns c ON c.id = p."column" WHERE p."index" = i.id)) ORDER BY n.name, o.name, i.position)
                  FROM cortex.indexes i JOIN cortex.objects o ON o.id = i.object JOIN cortex.namespaces n ON n.id = o.namespace WHERE i.design = '{design}'))"""))
    objs = {(ns, k, n): {"columns": [], "constraints": [], "indexes": []} for ns, k, n in rows["objects"] or []}
    kinds = {(ns, n): k for ns, k, n in objs}
    for ns, t, *rest in rows["columns"] or []:
        objs[(ns, kinds[(ns, t)], t)]["columns"].append(rest)
    for ns, t, name, kind, expr, cols, to, to_cols, d, u in rows["constraints"] or []:
        objs[(ns, "table", t)]["constraints"].append([name, kind, expr, cols if kind != "check" else None, to, to_cols if to else None, d, u])
    for ns, t, name, uniq, method, parts in rows["indexes"] or []:
        objs[(ns, "table", t)]["indexes"].append([name, uniq, method, parts or []])
    return objs


def differences(a, b, limit=8):
    """What differs between two shapes, as lines; empty when identical."""
    out = []
    for k in sorted(set(a) | set(b)):
        if k not in a or k not in b:
            out.append(f"{'.'.join(k)}: only in the {'source' if k in a else 'cortex'}")
        else:
            for part in ("columns", "constraints", "indexes"):
                if a[k][part] != b[k][part]:
                    x = next((i for i, (p, r) in enumerate(zip(a[k][part], b[k][part])) if p != r), min(len(a[k][part]), len(b[k][part])))
                    out.append(f"{'.'.join(k)} {part}[{x}]: source {a[k][part][x] if x < len(a[k][part]) else None} cortex {b[k][part][x] if x < len(b[k][part]) else None}")
        if len(out) >= limit:
            break
    return out


def count(objs):
    return (len(objs), sum(len(o["columns"]) for o in objs.values()), sum(len(o["constraints"]) for o in objs.values()),
            sum(len(o["indexes"]) for o in objs.values()))


def drop_outside_keys(objs):
    """A foreign key to a table outside the read is not in the model: the source's shape without them."""
    for o in objs.values():
        o["constraints"] = [k for k in o["constraints"] if not k[4] or tuple([k[4][0], "table", k[4][1]]) in objs]
    return objs


PRIVATE = os.path.expanduser("~/schema-forge-lab-private")
