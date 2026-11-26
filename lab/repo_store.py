"""The locked design itself on MySQL snapshots: schema/cortex and engines/mysql/schema, loaded exactly as the dumps and
the lock load them (tools/schema_dump.py, every reference of a design held by its foreign keys), every object of a snapshot stored in them,
every statement written back from them alone and compared with the server's SHOW CREATE, and with --roundtrip the
whole schema written as SQL, loaded into a fresh server of the same version, read again and compared, part by part.

  python3 lab/repo_store.py [--roundtrip] <snapshot.json> [...]
"""
import csv
import io
import json
import os
import re
import subprocess
import sys
import time
import uuid
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # tools/ holds crates: a __pycache__ there would be taken for one
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
import common as C  # noqa: E402
import extract as X  # noqa: E402
import mysql_ddl as D  # noqa: E402
import mysql_programs as P  # noqa: E402
import schema_dump as SD  # noqa: E402

OPTIONS = ["row_format", "avg_row_length", "min_rows", "max_rows", "pack_keys", "checksum", "delay_key_write", "key_block_size",
           "stats_persistent", "stats_auto_recalc", "stats_sample_pages", "compression", "encryption"]
RULE = {"NO ACTION": "no_action", "RESTRICT": "restrict", "CASCADE": "cascade", "SET NULL": "set_null", "SET DEFAULT": "set_default"}
STATUS = {"ENABLED": "ENABLE", "DISABLED": "DISABLE", "SLAVESIDE_DISABLED": "DISABLE ON SLAVE", "REPLICA_SIDE_DISABLED": "DISABLE ON REPLICA"}
KINDS = ["table", "view", "procedure", "function", "trigger", "event"]


def rows_of(snap, name=None):
    """A snapshot as the locked design's rows: {table: [row]}, and the views the server says are broken. Every id is a
    UUIDv7 made with its row, as the core makes them; name names the design."""
    version = snap["version"]
    n = [0]

    def nid():
        return str(uuid.uuid7())

    def next_place():
        n[0] += 1
        return n[0]
    out, by = defaultdict(list), defaultdict(list)
    for p in snap["parts"]:
        by[p["kind"]].append(p["props"])
    design = str(uuid.uuid7())
    out["cortex.designs"] = [{"id": design, "name": name or f"mysql-{version}", "engine": "mysql", "engine_version": version, "comment": None}]
    ns = {}
    for s in by["namespace"]:
        i = ns[s["SCHEMA_NAME"]] = nid()
        out["cortex.namespaces"].append({"id": i, "design": design, "parent": None, "name": s["SCHEMA_NAME"], "position": next_place(), "comment": None})
        out["engine_mysql.databases"].append({"id": i, "collation": s["DEFAULT_COLLATION_NAME"],
                                              "encryption": {"YES": True, "NO": False}.get(s.get("DEFAULT_ENCRYPTION"))})
    obj, col, broken = {}, {}, []
    views = {(v["TABLE_SCHEMA"], v["TABLE_NAME"]): v for v in by["view"]}

    def add_object(key, schema, kind, name, comment=None, parent=None):
        i = obj[key] = nid()
        out["cortex.objects"].append({"id": i, "namespace": None if schema is None else ns[schema], "kind": kind, "name": name, "signature": "", "parent": parent,
                                      "position": next_place(), "comment": comment, "notes": None})
        return i

    def program(i, r, sql_mode):
        out["engine_mysql.programs"].append({"id": i, "definer": r["DEFINER"], "sql_mode": sql_mode, "character_set_client": r["CHARACTER_SET_CLIENT"],
                                             "collation_connection": r["COLLATION_CONNECTION"], "database_collation": r.get("DATABASE_COLLATION"),
                                             "time_zone": r.get("TIME_ZONE")})
    # what the server holds beside its namespaces (scope server): in no namespace
    for r in by["tablespace"]:
        i = add_object(("tablespace", r["NAME"]), None, "tablespace", r["NAME"])
        out["engine_mysql.tablespaces"].append({"id": i, "datafile": r["FILE_NAME"], "file_block_size": r["ZIP_PAGE_SIZE"] or None,
                                                "autoextend_size": r.get("AUTOEXTEND_SIZE") or None, "engine": r["ENGINE"],
                                                "encryption": r.get("ENCRYPTION")})
    for r in by["spatial_reference_system"]:
        i = add_object(("spatial_reference_system", r["SRS_ID"]), None, "spatial_reference_system", r["SRS_NAME"], r.get("DESCRIPTION"))
        out["engine_mysql.spatial_reference_systems"].append({"id": i, "srs_id": r["SRS_ID"], "organization": r.get("ORGANIZATION"),
                                                              "organization_coordsys_id": r.get("ORGANIZATION_COORDSYS_ID"), "definition": r["DEFINITION"]})
    for r in by["loadable_function"]:
        i = add_object(("loadable_function", r["NAME"]), None, "loadable_function", r["NAME"])
        out["engine_mysql.loadable_functions"].append({"id": i, "soname": r["DL"], "returns": UDF_RETURNS[int(r["RET"])],
                                                       "aggregate": r["TYPE"] == "aggregate"})
    for t in by["table"]:
        key = (t["TABLE_SCHEMA"], t["TABLE_NAME"])
        if t.get("TABLE_TYPE") == "VIEW":
            if "references invalid" in (t.get("TABLE_COMMENT") or ""):
                broken.append(key)
                continue
            v = views[key]
            i = add_object(key, key[0], "view", key[1])
            body = P.body_of("view", v["__show_create"], v["TABLE_NAME"])
            if v.get("CHECK_OPTION") not in (None, "NONE"):
                body = body[:body.rindex(" WITH ")]
            out["cortex.views"].append({"id": i, "query": body, "check_option": None if v.get("CHECK_OPTION") in (None, "NONE") else v["CHECK_OPTION"].lower()})
            out["engine_mysql.views"].append({"id": i, "algorithm": P.view_algorithm(v["__show_create"]), "security": v["SECURITY_TYPE"]})
            program(i, v, None)
            continue
        i = add_object(key, key[0], "table", key[1], t.get("TABLE_COMMENT") or None)
        # CREATE_OPTIONS writes most options lower case, KEY_BLOCK_SIZE upper
        opts = {k.lower(): v for k, v in (o.split("=", 1) for o in (t.get("CREATE_OPTIONS") or "").split() if "=" in o)}
        unknown = set(opts) - set(OPTIONS)
        assert not unknown, f"table options the design has no column for: {unknown}"
        r = {"id": i, "engine": D.ENGINE_NAMES.get(t["ENGINE"], t["ENGINE"]), "collation": t["TABLE_COLLATION"],
             "auto_increment": t.get("__auto_increment"), "insert_method": t.get("__insert_method"),
             "tablespace": t["__tablespace"] if t.get("__tablespace") and ("tablespace", t["__tablespace"]) not in obj else None}
        r.update({k: opts.get(k) for k in OPTIONS})
        out["engine_mysql.tables"].append(r)
    for c in by["column"]:
        key = (c["TABLE_SCHEMA"], c["TABLE_NAME"])
        if key not in obj or key in views:
            continue
        i = col[key + (c["COLUMN_NAME"],)] = nid()
        extra = c.get("EXTRA") or ""
        out["cortex.columns"].append({
            "id": i, "object": obj[key], "position": c["ORDINAL_POSITION"], "name": c["COLUMN_NAME"], "type": c["COLUMN_TYPE"],
            "nullable": c["IS_NULLABLE"] == "YES", "default_value": D.default_sql(c, version),
            "generated_expression": c.get("GENERATION_EXPRESSION") or None,
            "generated_stored": ("STORED" in extra) if c.get("GENERATION_EXPRESSION") else None,
            "collation": c.get("COLLATION_NAME"), "comment": c.get("COLUMN_COMMENT") or None})
        if "auto_increment" in extra:
            out["cortex.column_identities"].append({"id": i, "always": False, "sequence": None})
        m = re.search(r"on update (CURRENT_TIMESTAMP(\(\d\))?)", extra, re.I)
        if m or c.get("SRS_ID") is not None or "INVISIBLE" in extra:
            out["engine_mysql.columns"].append({"id": i, "on_update": m.group(1) if m else None, "srid": c.get("SRS_ID"), "invisible": "INVISIBLE" in extra})
    tables = {(t["TABLE_SCHEMA"], t["TABLE_NAME"]): t for t in by["table"]}
    parts = defaultdict(list)
    for r in by["index_part"]:
        parts[(r["TABLE_SCHEMA"], r["TABLE_NAME"], r["INDEX_NAME"])].append(r)
    index_id = {}
    for (s, t, name), rs in parts.items():
        first = rs[0]
        i = index_id[(s, t, name)] = nid()
        out["cortex.indexes"].append({"id": i, "object": obj[(s, t)], "position": tables[(s, t)]["__index_order"].index(name) + 1, "name": name,
                                      "unique": str(first["NON_UNIQUE"]) == "0", "method": first["INDEX_TYPE"], "condition": None,
                                      "comment": first.get("INDEX_COMMENT") or None})
        if first.get("IS_VISIBLE") == "NO":
            out["engine_mysql.indexes"].append({"id": i, "invisible": True, "parser": None})
        for r in rs:
            pid = nid()
            out["cortex.index_parts"].append({"id": pid, "index": i, "position": r["SEQ_IN_INDEX"],
                                              "column": None if r.get("EXPRESSION") else col[(s, t, r["COLUMN_NAME"])],
                                              "expression": r.get("EXPRESSION"), "descending": r.get("COLLATION") == "D", "included": False})
            if r.get("SUB_PART") and first["INDEX_TYPE"] != "SPATIAL":
                out["engine_mysql.index_parts"].append({"id": pid, "length": r["SUB_PART"]})
    kcu = defaultdict(list)
    for r in by["key_column"]:
        kcu[(r["TABLE_SCHEMA"], r["TABLE_NAME"], r["CONSTRAINT_NAME"])].append(r)
    checks = {(r["CONSTRAINT_SCHEMA"], r["CONSTRAINT_NAME"]): r["CHECK_CLAUSE"] for r in by["check"]}
    rcs = {(r["CONSTRAINT_SCHEMA"], r["TABLE_NAME"], r["CONSTRAINT_NAME"]): r for r in by["foreign_key"]}
    place = Counter()
    for tc in by["constraint"]:
        s, t, name, kind = tc["TABLE_SCHEMA"], tc["TABLE_NAME"], tc["CONSTRAINT_NAME"], tc["CONSTRAINT_TYPE"]
        i = nid()
        place[(s, t)] += 1
        row = {"id": i, "object": obj[(s, t)], "name": name, "in_database": True, "enforced": tc.get("ENFORCED", "YES") != "NO",
               "deferrable": False, "initially_deferred": False, "expression": None, "index": None, "to_object": None,
               "to_namespace_name": None, "to_object_name": None, "on_delete": None, "on_update": None, "match_kind": None,
               "position": place[(s, t)]}
        cols = sorted(kcu[(s, t, name)], key=lambda r: int(r["ORDINAL_POSITION"]))
        if kind in ("PRIMARY KEY", "UNIQUE"):
            row.update(kind="primary" if kind == "PRIMARY KEY" else "unique", index=index_id[(s, t, name)])
            for c in cols:
                out["cortex.constraint_columns"].append({"id": nid(), "constraint": i, "position": c["ORDINAL_POSITION"],
                                                         "column": col[(s, t, c["COLUMN_NAME"])], "to_column": None, "to_column_name": None})
        elif kind == "CHECK":
            row.update(kind="check", expression=checks[(s, name)])
        else:
            rc = rcs[(s, t, name)]
            ref = (cols[0]["REFERENCED_TABLE_SCHEMA"], rc["REFERENCED_TABLE_NAME"])
            row.update(kind="foreign", to_object=obj.get(ref), on_delete=RULE[rc["DELETE_RULE"]], on_update=RULE[rc["UPDATE_RULE"]],
                       to_namespace_name=None if ref in obj else ref[0], to_object_name=None if ref in obj else ref[1])
            for c in cols:
                rk = (ref[0], ref[1], c["REFERENCED_COLUMN_NAME"])
                out["cortex.constraint_columns"].append({"id": nid(), "constraint": i, "position": c["ORDINAL_POSITION"],
                                                         "column": col[(s, t, c["COLUMN_NAME"])], "to_column": col.get(rk),
                                                         "to_column_name": None if rk in col else c["REFERENCED_COLUMN_NAME"]})
        out["cortex.constraints"].append(row)
    pgroups = defaultdict(list)
    for r in by["partition"]:
        pgroups[(r["TABLE_SCHEMA"], r["TABLE_NAME"])].append(r)
    for key, rs in pgroups.items():
        rs.sort(key=lambda r: (int(r["PARTITION_ORDINAL_POSITION"]), int(r.get("SUBPARTITION_ORDINAL_POSITION") or 0)))
        out["cortex.partitionings"].append({"id": obj[key], "strategy": rs[0]["PARTITION_METHOD"], "expression": rs[0]["PARTITION_EXPRESSION"]})
        if rs[0].get("SUBPARTITION_METHOD"):
            out["engine_mysql.subpartitionings"].append({"id": obj[key], "strategy": rs[0]["SUBPARTITION_METHOD"], "expression": rs[0]["SUBPARTITION_EXPRESSION"]})
        pid = {}
        for r in rs:
            if r["PARTITION_NAME"] not in pid:
                pid[r["PARTITION_NAME"]] = nid()
                out["cortex.partitions"].append({"id": pid[r["PARTITION_NAME"]], "partitioning": obj[key], "position": r["PARTITION_ORDINAL_POSITION"],
                                                 "name": r["PARTITION_NAME"], "bounds": r.get("PARTITION_DESCRIPTION"), "table_object": None,
                                                 "comment": r.get("PARTITION_COMMENT") or None})
            if r.get("SUBPARTITION_NAME"):
                out["engine_mysql.subpartitions"].append({"id": nid(), "partition": pid[r["PARTITION_NAME"]],
                                                          "position": r["SUBPARTITION_ORDINAL_POSITION"], "name": r["SUBPARTITION_NAME"]})
    param_colls = defaultdict(Counter)
    for r in by["parameter"]:
        if r.get("COLLATION_NAME"):
            param_colls[(r["SPECIFIC_SCHEMA"], r["ROUTINE_TYPE"], r["SPECIFIC_NAME"])][r["COLLATION_NAME"]] += 1
    for r in by["library"]:   # MySQL 9.7: made before the routines that use them
        i = add_object(("library", r["LIBRARY_SCHEMA"], r["LIBRARY_NAME"]), r["LIBRARY_SCHEMA"], "library", r["LIBRARY_NAME"], r.get("LIBRARY_COMMENT") or None)
        out["engine_mysql.libraries"].append({"id": i, "body": P.body_of("library", r["__show_create"]), "language": r["LANGUAGE"],
                                              "sql_mode": r.get("__sql_mode") or ""})
    for r in by["routine"]:
        key = (r["ROUTINE_SCHEMA"], r["ROUTINE_TYPE"], r["ROUTINE_NAME"])
        kind = r["ROUTINE_TYPE"].lower()
        i = add_object(key, r["ROUTINE_SCHEMA"], kind, r["ROUTINE_NAME"], r.get("ROUTINE_COMMENT") or None)
        text = r["__show_create"]
        if r.get("COLLATION_NAME"):
            param_colls[key][r["COLLATION_NAME"]] += 1
        out["cortex.routines"].append({"id": i, "returns": r["DTD_IDENTIFIER"] if kind == "function" else None, "language": r["EXTERNAL_LANGUAGE"] if r.get("ROUTINE_BODY") == "EXTERNAL" else (r.get("ROUTINE_BODY") or "SQL"),
                                       "deterministic": r["IS_DETERMINISTIC"] == "YES", "security": r["SECURITY_TYPE"].lower(),
                                       "body": P.body_of("routine", text, r["ROUTINE_NAME"])})
        out["engine_mysql.routines"].append({"id": i, "parameter_text": P.written_params(text, r["ROUTINE_NAME"]), "data_access": r["SQL_DATA_ACCESS"],
                                             "returns_charset": r.get("CHARACTER_SET_NAME") if kind == "function" else None,
                                             "parameter_collation": param_colls[key].most_common(1)[0][0] if param_colls[key] else None})
        program(i, r, r.get("__sql_mode") or "")
    for r in by["parameter"]:
        if int(r["ORDINAL_POSITION"]) == 0:
            continue  # a function's result: cortex.routines.returns
        out["cortex.routine_parameters"].append({"id": nid(), "routine": obj[(r["SPECIFIC_SCHEMA"], r["ROUTINE_TYPE"], r["SPECIFIC_NAME"])],
                                                 "position": r["ORDINAL_POSITION"], "name": r.get("PARAMETER_NAME"), "type": r["DTD_IDENTIFIER"],
                                                 "mode": {"IN": "in", "OUT": "out", "INOUT": "in_out"}.get(r.get("PARAMETER_MODE"), "in"), "default_value": None})
    for r in by["trigger"]:
        key = ("trigger", r["TRIGGER_SCHEMA"], r["TRIGGER_NAME"])
        i = add_object(key, r["TRIGGER_SCHEMA"], "trigger", r["TRIGGER_NAME"], parent=obj[(r["EVENT_OBJECT_SCHEMA"], r["EVENT_OBJECT_TABLE"])])
        body = P.body_of("trigger", r["__show_create"]) if D.mysql8(version) else r["ACTION_STATEMENT"]
        out["cortex.triggers"].append({"id": i, "timing": r["ACTION_TIMING"].lower(), "events": json.dumps([r["EVENT_MANIPULATION"].lower()]),
                                       "level": "row", "condition": None, "body": body, "action_order": r["ACTION_ORDER"]})
        program(i, r, r.get("__sql_mode") or "")
    for r in by["event"]:
        key = ("event", r["EVENT_SCHEMA"], r["EVENT_NAME"])
        i = add_object(key, r["EVENT_SCHEMA"], "event", r["EVENT_NAME"], r.get("EVENT_COMMENT") or None)
        out["engine_mysql.events"].append({"id": i, "body": P.body_of("event", r["__show_create"]), "interval_value": r.get("INTERVAL_VALUE"),
                                           "interval_field": r.get("INTERVAL_FIELD"), "execute_at": P.when(r["EXECUTE_AT"]) if r.get("EXECUTE_AT") else None,
                                           "starts": P.when(r["STARTS"]) if r.get("STARTS") else None, "ends": P.when(r["ENDS"]) if r.get("ENDS") else None,
                                           "status": STATUS[r["STATUS"]], "preserve": r["ON_COMPLETION"] == "PRESERVE"})
        program(i, r, r.get("__sql_mode") or "")
    place = Counter()

    def depends(o, u):
        if u and u != o:
            place[o] += 1
            d = nid()
            out["cortex.dependencies"].append({"id": d, "object": o, "uses": u, "position": place[o]})
            return d
    for r in by["routine"]:   # the libraries a routine uses, in its USING order, each with the name its code calls it by
        for sch, lib, alias in P.uses(r["__show_create"]):
            d = depends(obj[(r["ROUTINE_SCHEMA"], r["ROUTINE_TYPE"], r["ROUTINE_NAME"])], obj[("library", sch, lib)])
            out["engine_mysql.dependencies"].append({"id": d, "alias": alias})
    for v in [o for o in out["cortex.objects"] if o["kind"] == "view"]:
        q = next(x for x in out["cortex.views"] if x["id"] == v["id"])["query"]
        seen = []
        for sch, tbl in re.findall(r"`((?:[^`]|``)+)`\.`((?:[^`]|``)+)`", q):
            u = obj.get((sch.replace("``", "`"), tbl.replace("``", "`")))
            if u and u not in seen:
                seen.append(u)
                depends(v["id"], u)
    for t in by["table"]:   # a table's tablespace, where the design holds it: a reference, not a name
        if t.get("__tablespace") and ("tablespace", t["__tablespace"]) in obj:
            depends(obj[(t["TABLE_SCHEMA"], t["TABLE_NAME"])], obj[("tablespace", t["__tablespace"])])
    for t in by["table"]:
        key = (t["TABLE_SCHEMA"], t["TABLE_NAME"])
        for u in t.get("__merge_union") or []:
            depends(obj[key], obj.get((key[0], u)))  # a MERGE table's tables, in their UNION order
    # every table of a design carries its design (decision database-per-schema): the column first after id
    for k, rows in out.items():
        if k not in ("cortex.designs", "cortex.engine_versions", "cortex.object_kinds"):
            out[k] = [{"id": r["id"], "design": design, **{c: v for c, v in r.items() if c not in ("id", "design")}} for r in rows]
    return out, broken


ORDER = ["cortex.designs", "cortex.namespaces", "cortex.objects", "cortex.columns", "cortex.column_identities", "cortex.indexes",
         "cortex.index_parts", "cortex.constraints", "cortex.constraint_columns", "cortex.dependencies", "cortex.views",
         "cortex.routines", "cortex.routine_parameters", "cortex.triggers", "cortex.partitionings", "cortex.partitions",
         "engine_mysql.databases", "engine_mysql.tables", "engine_mysql.columns", "engine_mysql.indexes", "engine_mysql.index_parts",
         "engine_mysql.subpartitionings", "engine_mysql.subpartitions", "engine_mysql.programs", "engine_mysql.routines",
         "engine_mysql.views", "engine_mysql.events", "engine_mysql.libraries", "engine_mysql.dependencies", "engine_mysql.tablespaces",
         "engine_mysql.spatial_reference_systems", "engine_mysql.loadable_functions"]
UDF_RETURNS = {0: "STRING", 1: "REAL", 2: "INTEGER", 4: "DECIMAL"}   # mysql.func.ret


def twin(rows, name):
    """The same design under fresh ids and another name: every id, and every value that names one, made anew, so the
    twin can sit beside the original in one database. Returns the rows and the map from each old id to its new one."""
    ids = {str(r["id"]): str(uuid.uuid7()) for k, rs in rows.items() for r in rs
           if k not in ("cortex.engine_versions", "cortex.object_kinds")}
    out = {}
    for k, rs in rows.items():
        if k in ("cortex.engine_versions", "cortex.object_kinds"):
            continue
        out[k] = [{c: (ids.get(v, v) if isinstance(v, str) else v) for c, v in r.items()} for r in rs]
    out["cortex.designs"][0]["name"] = name
    return out, ids


def copy_sql(table, rows):
    cols = list(dict.fromkeys(c for r in rows for c in r))   # every row's columns, not the first row's alone
    rows = [{c: r.get(c, DEFAULT.get(c)) for c in cols} for r in rows]
    buf = io.StringIO()
    w = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator="\n")
    for r in rows:
        w.writerow(["\\N" if r[c] is None else ("t" if r[c] is True else "f") if isinstance(r[c], bool) else r[c] for c in cols])
    body = buf.getvalue().replace('"\\N"', "\\N")
    return f"COPY {table} ({', '.join(chr(34) + c + chr(34) for c in cols)}) FROM STDIN WITH (FORMAT csv, NULL '\\N');\n{body}\\.\n"


DEFAULT = {"options": "{}"}   # a column some rows leave out: what the table's own default is
import options_layout as OL  # noqa: E402  the readers' engine rows as the locked design's options (decision declared-options)
MOVED = OL.MOVED


def build(db):
    """A database of the locked design: every owner folder, as the dump loads it, the engines' declarations seeded."""
    C.psql("DO $$ BEGIN CREATE ROLE sf_owner NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;"
           "DO $$ BEGIN CREATE ROLE sf_service LOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;"
           "DO $$ BEGIN CREATE ROLE sf_agent LOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;"
           "DO $$ BEGIN CREATE ROLE sf_reader LOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;", "postgres")
    C.psql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE); CREATE DATABASE {db} OWNER sf_owner;", "postgres")
    owners = SD.databases()["schema_forge"]
    script = "BEGIN;\nSET ROLE sf_owner;\n" + "".join(sql + "\n" for o in owners for _, sql in SD.version_one(o)) + "COMMIT;\n"
    C.psql(script, db)


def load(db, rows):
    rows = OL.to_options(rows)
    t = time.time()
    C.psql("BEGIN;\nSET ROLE sf_service;\n" + "".join(copy_sql(k, rows[k]) for k in ORDER if rows.get(k)) + "COMMIT;\n", db)
    return time.time() - t


def read_back(db):
    out = {}
    for k in ORDER:
        if k not in MOVED:
            out[k] = {r["id"]: r for r in json.loads(C.psql(f"SELECT coalesce(json_agg(to_jsonb(t)), '[]') FROM {k} t;", db))}
    out = OL.from_options(out)
    return out


def charset_default(version):
    return {"latin1": "latin1_swedish_ci", "utf8": "utf8_general_ci", "utf8mb3": "utf8mb3_general_ci",
            "utf8mb4": "utf8mb4_0900_ai_ci" if D.mysql8(version) else "utf8mb4_general_ci", "ascii": "ascii_general_ci",
            "binary": "binary", "ucs2": "ucs2_general_ci", "utf16": "utf16_general_ci"}


def write(st, version):
    """Every object's statement, written from the design's rows alone: {(kind, schema, name): text}."""
    by = defaultdict(lambda: defaultdict(list))
    for k, key in (("cortex.columns", "object"), ("cortex.indexes", "object"), ("cortex.index_parts", "index"),
                   ("cortex.constraints", "object"), ("cortex.constraint_columns", "constraint"), ("cortex.partitions", "partitioning"),
                   ("engine_mysql.subpartitions", "partition"), ("cortex.dependencies", "object")):
        for r in st[k].values():
            by[k][r[key]].append(r)
    ns, objs, allcols = st["cortex.namespaces"], st["cortex.objects"], st["cortex.columns"]
    out = {}
    for o in objs.values():
        schema = ns[o["namespace"]]["name"] if o["namespace"] else None
        key = (o["kind"], schema, o["name"])
        pr = st["engine_mysql.programs"].get(o["id"])
        if o["kind"] == "table":
            mt = st["engine_mysql.tables"][o["id"]]
            uses = [objs[d["uses"]] for d in sorted(by["cortex.dependencies"][o["id"]], key=lambda d: d["position"])]
            union = [u["name"] for u in uses if u["kind"] == "table"] if mt["engine"] == "MRG_MyISAM" else None
            space = next((u["name"] for u in uses if u["kind"] == "tablespace"), mt.get("tablespace"))
            t = {"TABLE_NAME": o["name"], "TABLE_SCHEMA": schema, "ENGINE": mt["engine"], "TABLE_COLLATION": mt["collation"],
                 "CREATE_OPTIONS": " ".join(f"{k}={mt[k]}" for k in OPTIONS if mt.get(k) is not None), "TABLE_COMMENT": o.get("comment") or "",
                 "__merge_union": union, "__insert_method": mt.get("insert_method"), "__tablespace": space, "__auto_increment": mt.get("auto_increment"),
                 "__index_order": [i["name"] for i in sorted(by["cortex.indexes"][o["id"]], key=lambda i: i["position"])]}
            cid = {c["id"]: c for c in by["cortex.columns"][o["id"]]}
            icols = []
            for c in by["cortex.columns"][o["id"]]:
                mc = st["engine_mysql.columns"].get(c["id"], {})
                auto = c["id"] in st["cortex.column_identities"]
                extra = " ".join(x for x in ["auto_increment" if auto else "", f"on update {mc['on_update']}" if mc.get("on_update") else "",
                                             ("STORED GENERATED" if c["generated_stored"] else "VIRTUAL GENERATED") if c["generated_expression"] else "",
                                             "INVISIBLE" if mc.get("invisible") else ""] if x)
                coll = c["collation"]
                icols.append({"COLUMN_NAME": c["name"], "ORDINAL_POSITION": c["position"], "COLUMN_TYPE": c["type"],
                              "DATA_TYPE": re.match(r"\w+", c["type"]).group(0).lower(), "IS_NULLABLE": "YES" if c["nullable"] else "NO",
                              "__default_sql": c["default_value"], "EXTRA": extra, "GENERATION_EXPRESSION": c["generated_expression"] or "",
                              "COLLATION_NAME": coll, "CHARACTER_SET_NAME": (coll.split("_")[0] if coll != "binary" else "binary") if coll else None,
                              "COLUMN_COMMENT": c["comment"] or "", "SRS_ID": mc.get("srid")})
            index = {}
            for i in by["cortex.indexes"][o["id"]]:
                mi = st["engine_mysql.indexes"].get(i["id"], {})
                index[i["name"]] = [{"SEQ_IN_INDEX": p["position"], "COLUMN_NAME": cid[p["column"]]["name"] if p["column"] else None,
                                     "EXPRESSION": p["expression"], "COLLATION": "D" if p["descending"] else "A",
                                     "SUB_PART": st["engine_mysql.index_parts"].get(p["id"], {}).get("length"), "INDEX_TYPE": i["method"],
                                     "NON_UNIQUE": 0 if i["unique"] else 1, "INDEX_COMMENT": i["comment"] or "",
                                     "IS_VISIBLE": "NO" if mi.get("invisible") else "YES"} for p in by["cortex.index_parts"][i["id"]]]
            fks, checks = [], []
            for c in by["cortex.constraints"][o["id"]]:
                if not c["in_database"]:
                    continue
                if c["kind"] == "foreign":
                    ref = objs.get(c["to_object"])
                    ref_schema = ns[ref["namespace"]]["name"] if ref else c["to_namespace_name"]
                    kc = [{"ORDINAL_POSITION": x["position"], "COLUMN_NAME": allcols[x["column"]]["name"], "REFERENCED_TABLE_SCHEMA": ref_schema,
                           "REFERENCED_COLUMN_NAME": allcols[x["to_column"]]["name"] if x["to_column"] else x["to_column_name"]}
                          for x in by["cortex.constraint_columns"][c["id"]]]
                    back = {v: k for k, v in RULE.items()}
                    fks.append(D.foreign_key({"CONSTRAINT_NAME": c["name"], "REFERENCED_TABLE_NAME": ref["name"] if ref else c["to_object_name"],
                                              "DELETE_RULE": back[c["on_delete"]], "UPDATE_RULE": back[c["on_update"]]}, kc, schema, version))
                elif c["kind"] == "check":
                    checks.append(f"  CONSTRAINT {D.q(c['name'])} CHECK ({c['expression']})" + ("" if c["enforced"] else " /*!80016 NOT ENFORCED */"))
            prows = []
            pg, sp = st["cortex.partitionings"].get(o["id"]), st["engine_mysql.subpartitionings"].get(o["id"])
            for p in by["cortex.partitions"][o["id"]]:
                base = {"PARTITION_NAME": p["name"], "PARTITION_ORDINAL_POSITION": p["position"], "PARTITION_METHOD": pg["strategy"],
                        "PARTITION_EXPRESSION": pg["expression"], "PARTITION_DESCRIPTION": p["bounds"],
                        "SUBPARTITION_METHOD": sp["strategy"] if sp else None, "SUBPARTITION_EXPRESSION": sp["expression"] if sp else None}
                subs = by["engine_mysql.subpartitions"][p["id"]]
                prows += [dict(base, SUBPARTITION_NAME=s["name"], SUBPARTITION_ORDINAL_POSITION=s["position"]) for s in subs] or [base]
            out[key] = D.create_table(t, icols, index, fks, checks, version, charset_default(version), prows)
        elif o["kind"] in ("procedure", "function"):
            ro, mr = st["cortex.routines"][o["id"]], st["engine_mysql.routines"][o["id"]]
            r = {"DEFINER": pr["definer"], "ROUTINE_TYPE": o["kind"].upper(), "ROUTINE_NAME": o["name"], "DTD_IDENTIFIER": ro["returns"],
                 "CHARACTER_SET_NAME": mr["returns_charset"], "SQL_DATA_ACCESS": mr["data_access"], "IS_DETERMINISTIC": "YES" if ro["deterministic"] else "NO",
                 "SECURITY_TYPE": ro["security"].upper(), "ROUTINE_COMMENT": o["comment"]}
            libs = [d for d in sorted(by["cortex.dependencies"][o["id"]], key=lambda d: d["position"]) if objs[d["uses"]]["kind"] == "library"]
            r.update(LANGUAGE=ro["language"], USING=[(ns[objs[d["uses"]]["namespace"]]["name"], objs[d["uses"]]["name"],
                                                       st["engine_mysql.dependencies"].get(d["id"], {}).get("alias")) for d in libs])
            out[key] = P.routine(r, mr["parameter_text"], ro["body"], version)
        elif o["kind"] == "tablespace":
            ts = st["engine_mysql.tablespaces"][o["id"]]
            out[key] = (f"CREATE TABLESPACE {D.q(o['name'])} ADD DATAFILE {C.lit(ts['datafile'])}"
                        + (f" FILE_BLOCK_SIZE = {ts['file_block_size']}" if ts.get("file_block_size") else "")
                        + (f" AUTOEXTEND_SIZE = {ts['autoextend_size']}" if ts.get("autoextend_size") else "")
                        + (" ENCRYPTION = 'Y'" if ts.get("encryption") == "Y" else "") + f" ENGINE = {ts['engine']}")
        elif o["kind"] == "spatial_reference_system":
            sr = st["engine_mysql.spatial_reference_systems"][o["id"]]
            out[key] = (f"CREATE SPATIAL REFERENCE SYSTEM {sr['srs_id']} NAME {C.lit(o['name'])}"
                        + (f" ORGANIZATION {C.lit(sr['organization'])} IDENTIFIED BY {sr['organization_coordsys_id']}" if sr.get("organization") else "")
                        + f" DEFINITION {C.lit(sr['definition'])}" + (f" DESCRIPTION {C.lit(o['comment'])}" if o.get("comment") else ""))
        elif o["kind"] == "loadable_function":
            lf = st["engine_mysql.loadable_functions"][o["id"]]
            out[key] = f"CREATE {'AGGREGATE ' if lf['aggregate'] else ''}FUNCTION {D.q(o['name'])} RETURNS {lf['returns']} SONAME {C.lit(lf['soname'])}"
        elif o["kind"] == "library":
            lib = st["engine_mysql.libraries"][o["id"]]
            out[key] = P.library(o["name"], lib["language"], o["comment"], lib["body"])
        elif o["kind"] == "trigger":
            tr = st["cortex.triggers"][o["id"]]
            events = tr["events"] if isinstance(tr["events"], list) else json.loads(tr["events"])
            out[key] = P.trigger({"DEFINER": pr["definer"], "TRIGGER_NAME": o["name"], "ACTION_TIMING": tr["timing"].upper(),
                                  "EVENT_MANIPULATION": events[0].upper(), "EVENT_OBJECT_TABLE": objs[o["parent"]]["name"]}, tr["body"])
        elif o["kind"] == "event":
            e = st["engine_mysql.events"][o["id"]]
            out[key] = P.event({"DEFINER": pr["definer"], "EVENT_NAME": o["name"], "INTERVAL_VALUE": e["interval_value"], "INTERVAL_FIELD": e["interval_field"],
                                "STARTS": e["starts"], "ENDS": e["ends"], "EXECUTE_AT": e["execute_at"],
                                "ON_COMPLETION": "PRESERVE" if e["preserve"] else "NOT PRESERVE",
                                "STATUS": {v: k for k, v in STATUS.items()}[e["status"]], "EVENT_COMMENT": o["comment"]}, e["body"])
        elif o["kind"] == "view":
            mv, cv = st["engine_mysql.views"][o["id"]], st["cortex.views"][o["id"]]
            out[key] = P.view({"TABLE_SCHEMA": schema, "TABLE_NAME": o["name"], "DEFINER": pr["definer"], "SECURITY_TYPE": mv["security"],
                               "CHECK_OPTION": (cv["check_option"] or "NONE").upper()}, mv["algorithm"], cv["query"], version)
    return out


def script(st, version):
    """The whole schema as SQL bytes, written from the design's rows: each program under the context it was made in."""
    text = write(st, version)
    ns, objs = st["cortex.namespaces"], st["cortex.objects"]
    chunks = []

    def say(sql, charset="utf8mb4"):
        enc = C.PY.get(charset.split("_")[0], "utf-8")
        chunks.append(sql.encode(enc, errors="mysql_latin1" if enc == "cp1252" else "strict"))
    say("SET NAMES utf8mb4;\nSET SESSION innodb_strict_mode = 0;\nSET FOREIGN_KEY_CHECKS = 0;\n")
    for kind in ("tablespace", "spatial_reference_system", "loadable_function"):   # the server's, before any database
        for o in sorted((o for o in objs.values() if o["kind"] == kind), key=lambda o: o["position"]):
            say(text[(kind, None, o["name"])] + ";\n")
    coll = {}
    for n in sorted(ns.values(), key=lambda n: n["name"]):
        c = st["engine_mysql.databases"][n["id"]]["collation"]
        coll[n["name"]] = c
        say(f"CREATE DATABASE {D.q(n['name'])} DEFAULT CHARACTER SET {c.split('_')[0]} COLLATE {c};\n")
    for o in sorted((o for o in objs.values() if o["kind"] == "table"), key=lambda o: o["position"]):
        schema = ns[o["namespace"]]["name"]
        say(f"USE {D.q(schema)};\nSET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO';\n{C.implicit_collate(text[('table', schema, o['name'])])};\n")
    helpers = set()
    rank = {"library": -1, "view": 0, "procedure": 1, "function": 1, "trigger": 2, "event": 3}
    progs = sorted((o for o in objs.values() if o["kind"] in rank),
                   key=lambda o: (rank[o["kind"]], st["cortex.triggers"].get(o["id"], {}).get("action_order", 0), o["position"]))
    for o in progs:
        schema = ns[o["namespace"]]["name"]
        stmt = text[(o["kind"], schema, o["name"])]
        if o["kind"] == "library":   # no definer and no client character set: its sql_mode alone
            say(f"USE {D.q(schema)};\nSET SESSION sql_mode = {C.lit(st['engine_mysql.libraries'][o['id']]['sql_mode'])};\n"
                f"DELIMITER {C.DELIM}\n{stmt}{C.DELIM}\nDELIMITER ;\n")
            continue
        pr = st["engine_mysql.programs"][o["id"]]
        current = D.q(schema)
        under = st["engine_mysql.routines"].get(o["id"], {}).get("parameter_collation")
        if under and under != coll[schema]:
            current = D.q(f"sf_context_{under}")
            if under not in helpers:
                helpers.add(under)
                say(f"CREATE DATABASE {current} DEFAULT CHARACTER SET {under.split('_')[0]} COLLATE {under};\n")
            stmt = re.sub(r"\b(PROCEDURE|FUNCTION) `", lambda m: f"{m.group(1)} {D.q(schema)}.`", stmt, count=1)
        if o["kind"] == "trigger":
            tr = st["cortex.triggers"][o["id"]]
            if tr["action_order"] > 1:
                prev = next(p for p in objs.values() if p["kind"] == "trigger" and p["parent"] == o["parent"]
                            and st["cortex.triggers"][p["id"]]["timing"] == tr["timing"] and st["cortex.triggers"][p["id"]]["events"] == tr["events"]
                            and st["cortex.triggers"][p["id"]]["action_order"] == tr["action_order"] - 1)
                stmt = stmt.replace(" FOR EACH ROW ", f" FOR EACH ROW FOLLOWS {D.q(prev['name'])} ", 1)
        say(f"USE {current};\nSET SESSION sql_mode = {C.lit(pr['sql_mode'] or '')};\n"
            + (f"SET SESSION time_zone = {C.lit(pr['time_zone'])};\n" if pr.get("time_zone") else "")
            + f"SET NAMES {pr['character_set_client']} COLLATE {pr['collation_connection']};\nDELIMITER {C.DELIM}\n")
        say(stmt + C.DELIM + "\n", pr["character_set_client"])
        say("DELIMITER ;\nSET NAMES utf8mb4;\n")
    for h in sorted(helpers):
        say(f"DROP DATABASE {D.q('sf_context_' + h)};\n")
    say("SET FOREIGN_KEY_CHECKS = 1;\n")
    return b"".join(chunks)


def main():
    roundtrip = "--roundtrip" in sys.argv
    for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
        snap = json.load(open(path))
        version = snap["version"]
        rows, broken = rows_of(snap)
        db = f"lab_repo_mysql_{version.replace('.', '_')}"
        build(db)
        t_load = load(db, rows)
        size = C.psql("SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                      "WHERE n.nspname IN ('cortex', 'engine_mysql') AND c.relkind = 'r'", db)
        st = read_back(db)
        t = time.time()
        got = write(st, version)
        t_write = time.time() - t
        n, exact = Counter(), Counter()
        for p in snap["parts"]:
            pr = p["props"]
            if "__show_create" not in pr or p["kind"] not in ("table", "routine", "trigger", "event", "view", "library"):
                continue
            if p["kind"] == "table" and pr.get("TABLE_TYPE") == "VIEW":
                continue
            kind = {"routine": pr.get("ROUTINE_TYPE", "").lower()}.get(p["kind"], p["kind"])
            schema = pr.get("TABLE_SCHEMA") or pr.get("ROUTINE_SCHEMA") or pr.get("TRIGGER_SCHEMA") or pr.get("EVENT_SCHEMA") or pr.get("LIBRARY_SCHEMA")
            name = pr.get("TABLE_NAME") or pr.get("ROUTINE_NAME") or pr.get("TRIGGER_NAME") or pr.get("EVENT_NAME") or pr.get("LIBRARY_NAME")
            if (schema, name) in broken:
                continue
            n[kind] += 1
            if kind == "trigger" and not D.mysql8(version):
                exact[kind] += got.get((kind, schema, name)) is not None
                continue
            exact[kind] += got.get((kind, schema, name)) == pr["__show_create"]
        print(f"{'pass' if exact == n else 'FAIL'}  mysql {version}: one design, {sum(len(v) for k, v in rows.items() if k not in ('cortex.object_kinds', 'cortex.designs', 'cortex.engine_versions'))} rows in the locked design, "
              f"loaded as sf_service, every foreign key held, in {t_load:.1f}s, {size}; written from it: "
              + ", ".join(f"{exact[k]}/{n[k]} {'libraries' if k == 'library' else k + 's'}" for k in sorted(n)) + (f"; {len(broken)} broken views not stored" if broken else ""))
        if roundtrip:
            name = C.fresh_mysql(version)
            try:
                C.ready_mysql(name)
                sql = script(st, version)
                r = subprocess.run(["docker", "exec", "-i", name, "mysql", "-uroot", f"-p{C.S.PW}", "--force", "--comments",
                                    "--default-character-set=utf8mb4"], input=sql, capture_output=True)
                refused = [l for l in r.stderr.decode(errors="replace").splitlines() if l.startswith("ERROR")]
                saved, X.SCHEMAS = X.SCHEMAS, tuple(n["name"] for n in st["cortex.namespaces"].values())
                again = X.extract_mysql(version, name)
                X.SCHEMAS = saved

                def settled(parts):
                    out = []
                    for p in parts:
                        pr = dict(p["props"])
                        if p["kind"] == "trigger" and not D.mysql8(version):
                            pr.pop("__show_create", None)  # 5.7 shows a trigger as it was typed
                        out.append(dict(p, props=pr))
                    return out
                diffs, m = C.compare(settled(snap["parts"]), settled(again), {f"{s}.{v}" for s, v in broken})
                ok = not refused and not diffs
                print(f"      {'pass' if ok else 'FAIL'}  round trip: {len(sql) // 1024} KB of SQL from the design, {len(refused)} refused, "
                      f"{m} parts compared, {sum(diffs.values())} properties differ")
                for e in refused[:4]:
                    print(f"            refused: {re.sub('`[^`]*`', '`x`', e)[:150]}")
                for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:8]:
                    print(f"            differs: {k} in {c} parts")
            finally:
                C.S.remove(name)


if __name__ == "__main__":
    main()
