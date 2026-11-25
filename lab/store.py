"""The store (lab/design/store.sql) on MySQL snapshots: every object loaded into the global schema and the MySQL
plugin's, every statement written back from the store alone and compared with the server's SHOW CREATE, and with
--roundtrip the whole schema written as SQL from the store, loaded into a fresh server of the same version, read again
and compared, part by part.

  python3 lab/store.py [--roundtrip] <snapshot.json> [...]
"""
import csv
import io
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract as X  # noqa: E402
import mysql_ddl as D  # noqa: E402
import mysql_programs as P  # noqa: E402
import roundtrip as R  # noqa: E402
import setup as SU  # noqa: E402
import versioning_test as V  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OPTIONS = ["row_format", "avg_row_length", "min_rows", "max_rows", "pack_keys", "checksum", "delay_key_write", "key_block_size",
           "stats_persistent", "stats_auto_recalc", "stats_sample_pages", "compression", "encryption"]
ORDER = ["core.server", "core.namespace", "core.object", "core.column", "core.index", "core.index_part", "core.constraint",
         "core.constraint_column", "core.dependency", "core.routine", "core.parameter", "core.trigger", "core.view", "core.partitioning",
         "core.partition", "core.sequence", "engine_mysql.namespace", "engine_mysql.table", "engine_mysql.column",
         "engine_mysql.index", "engine_mysql.index_part", "engine_mysql.subpartitioning", "engine_mysql.subpartition",
         "engine_mysql.program", "engine_mysql.routine", "engine_mysql.view", "engine_mysql.trigger", "engine_mysql.event"]
STATUS_WORD = {"ENABLED": "ENABLE", "DISABLED": "DISABLE", "SLAVESIDE_DISABLED": "DISABLE ON SLAVE", "REPLICA_SIDE_DISABLED": "DISABLE ON REPLICA"}


def rows_of(snap):
    """The snapshot as the store's rows: {table: [row]}, and the views the server says are broken (not stored: a
    broken view is the server's state, and no server takes one back)."""
    version = snap["version"]
    n = [0]

    def nid():
        n[0] += 1
        return n[0]
    out, by = defaultdict(list), defaultdict(list)
    for p in snap["parts"]:
        by[p["kind"]].append(p["props"])
    server = nid()
    out["core.server"].append({"id": server, "engine": "mysql", "version": version, "name": f"mysql-{version}"})
    ns = {}
    for s in by["namespace"]:
        i = ns[s["SCHEMA_NAME"]] = nid()
        out["core.namespace"].append({"id": i, "server_id": server, "parent_id": None, "name": s["SCHEMA_NAME"], "comment": None})
        out["engine_mysql.namespace"].append({"id": i, "collation_name": s["DEFAULT_COLLATION_NAME"],
                                              "encryption": {"YES": True, "NO": False}.get(s.get("DEFAULT_ENCRYPTION"))})
    obj, col, broken = {}, {}, []
    views = {(v["TABLE_SCHEMA"], v["TABLE_NAME"]): v for v in by["view"]}

    def program(i, r, sql_mode):
        out["engine_mysql.program"].append({"id": i, "definer": r["DEFINER"], "sql_mode": sql_mode,
                                            "character_set_client": r["CHARACTER_SET_CLIENT"], "collation_connection": r["COLLATION_CONNECTION"],
                                            "database_collation": r.get("DATABASE_COLLATION"), "time_zone": r.get("TIME_ZONE")})
    for t in by["table"]:
        key = (t["TABLE_SCHEMA"], t["TABLE_NAME"])
        if t.get("TABLE_TYPE") == "VIEW":
            v = views[key]
            if "references invalid" in (t.get("TABLE_COMMENT") or ""):
                broken.append(key)
                continue
            i = obj[key] = nid()
            text = v["__show_create"]
            body = P.body_of("view", text, v["TABLE_NAME"])
            if v.get("CHECK_OPTION") not in (None, "NONE"):
                body = body[:body.rindex(" WITH ")]
            out["core.object"].append({"id": i, "namespace_id": ns[key[0]], "parent_id": None, "kind": "view", "name": key[1],
                                       "signature": "", "comment": None, "body": body})
            out["core.view"].append({"id": i, "kind": "view", "check_option": None if v.get("CHECK_OPTION") in (None, "NONE") else v["CHECK_OPTION"]})
            out["engine_mysql.view"].append({"id": i, "algorithm": P.view_algorithm(text), "security": v["SECURITY_TYPE"]})
            program(i, v, None)
            continue
        i = obj[key] = nid()
        out["core.object"].append({"id": i, "namespace_id": ns[key[0]], "parent_id": None, "kind": "table", "name": key[1],
                                   "signature": "", "comment": t.get("TABLE_COMMENT") or None, "body": None})
        opts = dict(o.split("=", 1) for o in (t.get("CREATE_OPTIONS") or "").split() if "=" in o)
        unknown = set(opts) - set(OPTIONS)
        assert not unknown, f"table options the store has no column for: {unknown}"
        r = {"id": i, "kind": "table", "engine": D.ENGINE_NAMES.get(t["ENGINE"], t["ENGINE"]), "collation_name": t["TABLE_COLLATION"],
             "merge_union": t.get("__merge_union"), "insert_method": t.get("__insert_method")}
        r.update({k: opts.get(k) for k in OPTIONS})
        out["engine_mysql.table"].append(r)
    for c in by["column"]:
        key = (c["TABLE_SCHEMA"], c["TABLE_NAME"])
        if key not in obj or key in views:
            continue
        i = col[key + (c["COLUMN_NAME"],)] = nid()
        extra = c.get("EXTRA") or ""
        out["core.column"].append({
            "id": i, "object_id": obj[key], "position": c["ORDINAL_POSITION"], "name": c["COLUMN_NAME"], "type": c["COLUMN_TYPE"],
            "nullable": c["IS_NULLABLE"] == "YES", "default_value": c.get("COLUMN_DEFAULT"),
            "default_is_expression": "DEFAULT_GENERATED" in extra, "generated": c.get("GENERATION_EXPRESSION") or None,
            "generated_stored": ("STORED" in extra) if c.get("GENERATION_EXPRESSION") else None,
            "identity": "auto" if "auto_increment" in extra else None, "collation_name": c.get("COLLATION_NAME"),
            "comment": c.get("COLUMN_COMMENT") or None})
        m = re.search(r"on update (CURRENT_TIMESTAMP(\(\d\))?)", extra, re.I)
        if m or c.get("SRS_ID") is not None or "INVISIBLE" in extra:
            out["engine_mysql.column"].append({"id": i, "on_update": m.group(1) if m else None, "srid": c.get("SRS_ID"),
                                               "invisible": "INVISIBLE" in extra})
    tables = {(t["TABLE_SCHEMA"], t["TABLE_NAME"]): t for t in by["table"]}
    parts = defaultdict(list)
    for r in by["index_part"]:
        parts[(r["TABLE_SCHEMA"], r["TABLE_NAME"], r["INDEX_NAME"])].append(r)
    index_id = {}
    for (s, t, name), rs in parts.items():
        first = rs[0]
        i = index_id[(s, t, name)] = nid()
        out["core.index"].append({"id": i, "object_id": obj[(s, t)], "name": name, "position": tables[(s, t)]["__index_order"].index(name) + 1,
                                  "is_primary": name == "PRIMARY", "is_unique": str(first["NON_UNIQUE"]) == "0",
                                  "method": first["INDEX_TYPE"], "predicate": None, "comment": first.get("INDEX_COMMENT") or None})
        if first.get("IS_VISIBLE") == "NO":
            out["engine_mysql.index"].append({"id": i, "invisible": True})
        for r in rs:
            pid = nid()
            out["core.index_part"].append({"id": pid, "index_id": i, "position": r["SEQ_IN_INDEX"],
                                           "column_id": None if r.get("EXPRESSION") else col[(s, t, r["COLUMN_NAME"])],
                                           "expression": r.get("EXPRESSION"), "descending": r.get("COLLATION") == "D"})
            if r.get("SUB_PART") and first["INDEX_TYPE"] != "SPATIAL":
                out["engine_mysql.index_part"].append({"id": pid, "prefix_length": r["SUB_PART"]})
    kcu = defaultdict(list)
    for r in by["key_column"]:
        kcu[(r["TABLE_SCHEMA"], r["TABLE_NAME"], r["CONSTRAINT_NAME"])].append(r)
    checks = {(r["CONSTRAINT_SCHEMA"], r["CONSTRAINT_NAME"]): r["CHECK_CLAUSE"] for r in by["check"]}
    rcs = {(r["CONSTRAINT_SCHEMA"], r["TABLE_NAME"], r["CONSTRAINT_NAME"]): r for r in by["foreign_key"]}
    for tc in by["constraint"]:
        s, t, name, kind = tc["TABLE_SCHEMA"], tc["TABLE_NAME"], tc["CONSTRAINT_NAME"], tc["CONSTRAINT_TYPE"]
        i = nid()
        row = {"id": i, "object_id": obj[(s, t)], "name": name, "in_database": True, "enforced": tc.get("ENFORCED", "YES") != "NO",
               "is_deferrable": False, "is_deferred": False, "expression": None, "index_id": None, "ref_object_id": None,
               "ref_namespace": None, "ref_object": None, "on_delete": None, "on_update": None, "match": None}
        if kind in ("PRIMARY KEY", "UNIQUE"):
            row.update(kind="primary" if kind == "PRIMARY KEY" else "unique", index_id=index_id[(s, t, name)])
        elif kind == "CHECK":
            row.update(kind="check", expression=checks[(s, name)])
        else:
            rc = rcs[(s, t, name)]
            cols = sorted(kcu[(s, t, name)], key=lambda r: int(r["ORDINAL_POSITION"]))
            ref = (cols[0]["REFERENCED_TABLE_SCHEMA"], rc["REFERENCED_TABLE_NAME"])
            row.update(kind="foreign", ref_object_id=obj.get(ref), on_delete=rc["DELETE_RULE"], on_update=rc["UPDATE_RULE"],
                       match=rc.get("MATCH_OPTION"), ref_namespace=None if ref in obj else ref[0], ref_object=None if ref in obj else ref[1])
            for c in cols:
                rk = (ref[0], ref[1], c["REFERENCED_COLUMN_NAME"])
                out["core.constraint_column"].append({"id": nid(), "constraint_id": i, "position": c["ORDINAL_POSITION"],
                                                      "column_id": col[(s, t, c["COLUMN_NAME"])], "ref_column_id": col.get(rk),
                                                      "ref_column": None if rk in col else c["REFERENCED_COLUMN_NAME"]})
        out["core.constraint"].append(row)
    pgroups = defaultdict(list)
    for r in by["partition"]:
        pgroups[(r["TABLE_SCHEMA"], r["TABLE_NAME"])].append(r)
    for key, rs in pgroups.items():
        rs.sort(key=lambda r: (int(r["PARTITION_ORDINAL_POSITION"]), int(r.get("SUBPARTITION_ORDINAL_POSITION") or 0)))
        out["core.partitioning"].append({"id": obj[key], "strategy": rs[0]["PARTITION_METHOD"], "expression": rs[0]["PARTITION_EXPRESSION"]})
        if rs[0].get("SUBPARTITION_METHOD"):
            out["engine_mysql.subpartitioning"].append({"id": obj[key], "method": rs[0]["SUBPARTITION_METHOD"],
                                                        "expression": rs[0]["SUBPARTITION_EXPRESSION"]})
        pid = {}
        for r in rs:
            if r["PARTITION_NAME"] not in pid:
                pid[r["PARTITION_NAME"]] = nid()
                out["core.partition"].append({"id": pid[r["PARTITION_NAME"]], "object_id": obj[key], "position": r["PARTITION_ORDINAL_POSITION"],
                                              "name": r["PARTITION_NAME"], "bounds": r.get("PARTITION_DESCRIPTION"), "table_id": None,
                                              "comment": r.get("PARTITION_COMMENT") or None})
            if r.get("SUBPARTITION_NAME"):
                out["engine_mysql.subpartition"].append({"id": nid(), "partition_id": pid[r["PARTITION_NAME"]],
                                                         "position": r["SUBPARTITION_ORDINAL_POSITION"], "name": r["SUBPARTITION_NAME"]})
    param_colls = defaultdict(Counter)
    for r in by["parameter"]:
        if r.get("COLLATION_NAME"):
            param_colls[(r["SPECIFIC_SCHEMA"], r["ROUTINE_TYPE"], r["SPECIFIC_NAME"])][r["COLLATION_NAME"]] += 1
    for r in by["routine"]:
        key = (r["ROUTINE_SCHEMA"], r["ROUTINE_TYPE"], r["ROUTINE_NAME"])
        i = obj[key] = nid()
        text = r["__show_create"]
        kind = r["ROUTINE_TYPE"].lower()
        if r.get("COLLATION_NAME"):
            param_colls[key][r["COLLATION_NAME"]] += 1
        out["core.object"].append({"id": i, "namespace_id": ns[r["ROUTINE_SCHEMA"]], "parent_id": None, "kind": kind,
                                   "name": r["ROUTINE_NAME"], "signature": "", "comment": r.get("ROUTINE_COMMENT") or None,
                                   "body": P.body_of("routine", text, r["ROUTINE_NAME"])})
        out["core.routine"].append({"id": i, "kind": kind, "returns": r["DTD_IDENTIFIER"] if kind == "function" else None,
                                    "language": r.get("ROUTINE_BODY") or "SQL", "deterministic": r["IS_DETERMINISTIC"] == "YES",
                                    "security": r["SECURITY_TYPE"].lower()})
        out["engine_mysql.routine"].append({"id": i, "parameter_text": P.written_params(text, r["ROUTINE_NAME"]),
                                            "data_access": r["SQL_DATA_ACCESS"], "returns_charset": r.get("CHARACTER_SET_NAME") if kind == "function" else None,
                                            "parameter_collation": param_colls[key].most_common(1)[0][0] if param_colls[key] else None})
        program(i, r, r.get("__sql_mode") or "")
    for r in by["parameter"]:
        out["core.parameter"].append({"id": nid(), "object_id": obj[(r["SPECIFIC_SCHEMA"], r["ROUTINE_TYPE"], r["SPECIFIC_NAME"])],
                                      "position": r["ORDINAL_POSITION"], "name": r.get("PARAMETER_NAME"), "mode": r.get("PARAMETER_MODE"),
                                      "type": r["DTD_IDENTIFIER"]})
    for r in by["trigger"]:
        i = nid()
        text = r["__show_create"]
        body = P.body_of("trigger", text) if D.mysql8(version) else r["ACTION_STATEMENT"]  # 5.7 gives the statement as typed
        out["core.object"].append({"id": i, "namespace_id": ns[r["TRIGGER_SCHEMA"]], "parent_id": obj[(r["EVENT_OBJECT_SCHEMA"], r["EVENT_OBJECT_TABLE"])],
                                   "kind": "trigger", "name": r["TRIGGER_NAME"], "signature": "", "comment": None, "body": body})
        out["core.trigger"].append({"id": i, "kind": "trigger", "timing": r["ACTION_TIMING"], "events": [r["EVENT_MANIPULATION"]], "level": "row"})
        out["engine_mysql.trigger"].append({"id": i, "action_order": r["ACTION_ORDER"]})
        program(i, r, r.get("__sql_mode") or "")
    for r in by["event"]:
        i = nid()
        out["core.object"].append({"id": i, "namespace_id": ns[r["EVENT_SCHEMA"]], "parent_id": None, "kind": "event",
                                   "name": r["EVENT_NAME"], "signature": "", "comment": r.get("EVENT_COMMENT") or None,
                                   "body": P.body_of("event", r["__show_create"])})
        out["engine_mysql.event"].append({"id": i, "kind": "event", "interval_value": r.get("INTERVAL_VALUE"), "interval_field": r.get("INTERVAL_FIELD"),
                                          "execute_at": P.when(r["EXECUTE_AT"]) if r.get("EXECUTE_AT") else None,
                                          "starts": P.when(r["STARTS"]) if r.get("STARTS") else None,
                                          "ends": P.when(r["ENDS"]) if r.get("ENDS") else None,
                                          "status": STATUS_WORD[r["STATUS"]], "on_completion": r["ON_COMPLETION"]})
        program(i, r, r.get("__sql_mode") or "")
    # a view's tables: MySQL writes a view's query with every table named in full, on every version
    for o in [o for o in out["core.object"] if o["kind"] == "view"]:
        for sch, tbl in set(re.findall(r"`((?:[^`]|``)+)`\.`((?:[^`]|``)+)`", o["body"])):
            used = obj.get((sch.replace("``", "`"), tbl.replace("``", "`")))
            if used and used != o["id"]:
                out["core.dependency"].append({"id": nid(), "object_id": o["id"], "uses_object_id": used, "uses_column_id": None})
    # a MERGE table's tables: they must stay MyISAM and alike, so an edit to them must know the MERGE table uses them
    for t in out["engine_mysql.table"]:
        o = next(x for x in out["core.object"] if x["id"] == t["id"])
        schema = next(n["name"] for n in out["core.namespace"] if n["id"] == o["namespace_id"])
        for u in t.get("merge_union") or []:
            used = obj.get((schema, u))
            if used:
                out["core.dependency"].append({"id": nid(), "object_id": t["id"], "uses_object_id": used, "uses_column_id": None})
    return out, broken


def copy_sql(table, rows):
    cols = list(rows[0])
    buf = io.StringIO()
    w = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator="\n")

    def cell(v):
        if v is None:
            return "\\N"
        if isinstance(v, bool):
            return "t" if v else "f"
        if isinstance(v, list):
            return "{" + ",".join('"' + str(x).replace("\\", "\\\\").replace('"', '\\"') + '"' for x in v) + "}"
        return v
    for r in rows:
        w.writerow([cell(r[c]) for c in cols])
    body = buf.getvalue().replace('"\\N"', "\\N")
    return f"COPY {table} ({', '.join(chr(34) + c + chr(34) for c in cols)}) FROM STDIN WITH (FORMAT csv, NULL '\\N');\n{body}\\.\n"


def build(db, rows):
    V.psql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE); CREATE DATABASE {db};", "postgres")
    V.psql(open(os.path.join(HERE, "design", "store.sql")).read() + open(os.path.join(HERE, "design", "versioning.sql")).read()
           + "\nSELECT log.attach(); SELECT log.init('main');", db)
    t = time.time()
    V.psql("BEGIN; SELECT log.begin_turn('import');\n" + "".join(copy_sql(k, rows[k]) for k in ORDER if rows.get(k))
           + "SELECT log.end_turn(); COMMIT;", db)
    return time.time() - t


def load_back(db):
    return {k: {r["id"]: r for r in json.loads(V.psql(f"SELECT coalesce(json_agg(to_jsonb(t)), '[]') FROM {k} t;", db))} for k in ORDER}


def charset_default(version):
    return {"latin1": "latin1_swedish_ci", "utf8": "utf8_general_ci", "utf8mb3": "utf8mb3_general_ci",
            "utf8mb4": "utf8mb4_0900_ai_ci" if D.mysql8(version) else "utf8mb4_general_ci", "ascii": "ascii_general_ci",
            "binary": "binary", "ucs2": "ucs2_general_ci", "utf16": "utf16_general_ci"}


def write(st, version):
    """Every object's statement, written from the store alone: {(kind, schema, name): text}."""
    ns = st["core.namespace"]
    by = defaultdict(lambda: defaultdict(list))
    for k, key in (("core.column", "object_id"), ("core.index", "object_id"), ("core.index_part", "index_id"),
                   ("core.constraint", "object_id"), ("core.constraint_column", "constraint_id"), ("core.partition", "object_id"),
                   ("engine_mysql.subpartition", "partition_id")):
        for r in st[k].values():
            by[k][r[key]].append(r)
    objs, allcols = st["core.object"], st["core.column"]
    out = {}
    for o in objs.values():
        schema = ns[o["namespace_id"]]["name"]
        key = (o["kind"], schema, o["name"])
        pr = st["engine_mysql.program"].get(o["id"])
        if o["kind"] == "table":
            mt = st["engine_mysql.table"][o["id"]]
            t = {"TABLE_NAME": o["name"], "TABLE_SCHEMA": schema, "ENGINE": mt["engine"], "TABLE_COLLATION": mt["collation_name"],
                 "CREATE_OPTIONS": " ".join(f"{k}={mt[k]}" for k in OPTIONS if mt.get(k) is not None),
                 "TABLE_COMMENT": o.get("comment") or "", "__merge_union": mt.get("merge_union"), "__insert_method": mt.get("insert_method"),
                 "__index_order": [i["name"] for i in sorted(by["core.index"][o["id"]], key=lambda i: i["position"])]}
            cid = {c["id"]: c for c in by["core.column"][o["id"]]}
            icols = []
            for c in by["core.column"][o["id"]]:
                mc = st["engine_mysql.column"].get(c["id"], {})
                extra = " ".join(x for x in ["DEFAULT_GENERATED" if c["default_is_expression"] else "", "auto_increment" if c["identity"] == "auto" else "",
                                             f"on update {mc['on_update']}" if mc.get("on_update") else "",
                                             ("STORED GENERATED" if c["generated_stored"] else "VIRTUAL GENERATED") if c["generated"] else "",
                                             "INVISIBLE" if mc.get("invisible") else ""] if x)
                coll = c["collation_name"]
                icols.append({"COLUMN_NAME": c["name"], "ORDINAL_POSITION": c["position"], "COLUMN_TYPE": c["type"],
                              "DATA_TYPE": re.match(r"\w+", c["type"]).group(0).lower(), "IS_NULLABLE": "YES" if c["nullable"] else "NO",
                              "COLUMN_DEFAULT": c["default_value"], "EXTRA": extra, "GENERATION_EXPRESSION": c["generated"] or "",
                              "COLLATION_NAME": coll, "CHARACTER_SET_NAME": (coll.split("_")[0] if coll != "binary" else "binary") if coll else None,
                              "COLUMN_COMMENT": c["comment"] or "", "SRS_ID": mc.get("srid")})
            index = {}
            for i in by["core.index"][o["id"]]:
                mi = st["engine_mysql.index"].get(i["id"], {})
                index[i["name"]] = [{"SEQ_IN_INDEX": p["position"], "COLUMN_NAME": cid[p["column_id"]]["name"] if p["column_id"] else None,
                                     "EXPRESSION": p["expression"], "COLLATION": "D" if p["descending"] else "A",
                                     "SUB_PART": st["engine_mysql.index_part"].get(p["id"], {}).get("prefix_length"),
                                     "INDEX_TYPE": i["method"], "NON_UNIQUE": 0 if i["is_unique"] else 1, "INDEX_COMMENT": i["comment"] or "",
                                     "IS_VISIBLE": "NO" if mi.get("invisible") else "YES"} for p in by["core.index_part"][i["id"]]]
            fks, checks = [], []
            for c in by["core.constraint"][o["id"]]:
                if not c["in_database"]:
                    continue
                if c["kind"] == "foreign":
                    ref = objs.get(c["ref_object_id"])
                    ref_schema = ns[ref["namespace_id"]]["name"] if ref else c["ref_namespace"]
                    kc = [{"ORDINAL_POSITION": x["position"], "COLUMN_NAME": allcols[x["column_id"]]["name"], "REFERENCED_TABLE_SCHEMA": ref_schema,
                           "REFERENCED_COLUMN_NAME": allcols[x["ref_column_id"]]["name"] if x["ref_column_id"] else x["ref_column"]}
                          for x in by["core.constraint_column"][c["id"]]]
                    fks.append(D.foreign_key({"CONSTRAINT_NAME": c["name"], "REFERENCED_TABLE_NAME": ref["name"] if ref else c["ref_object"],
                                              "DELETE_RULE": c["on_delete"], "UPDATE_RULE": c["on_update"]}, kc, schema, version))
                elif c["kind"] == "check":
                    checks.append(f"  CONSTRAINT {D.q(c['name'])} CHECK ({c['expression']})" + ("" if c["enforced"] else " /*!80016 NOT ENFORCED */"))
            prows = []
            pg, sp = st["core.partitioning"].get(o["id"]), st["engine_mysql.subpartitioning"].get(o["id"])
            for p in by["core.partition"][o["id"]]:
                base = {"PARTITION_NAME": p["name"], "PARTITION_ORDINAL_POSITION": p["position"], "PARTITION_METHOD": pg["strategy"],
                        "PARTITION_EXPRESSION": pg["expression"], "PARTITION_DESCRIPTION": p["bounds"],
                        "SUBPARTITION_METHOD": sp["method"] if sp else None, "SUBPARTITION_EXPRESSION": sp["expression"] if sp else None}
                subs = by["engine_mysql.subpartition"][p["id"]]
                prows += [dict(base, SUBPARTITION_NAME=s["name"], SUBPARTITION_ORDINAL_POSITION=s["position"]) for s in subs] or [base]
            out[key] = D.create_table(t, icols, index, fks, checks, version, charset_default(version), prows)
        elif o["kind"] in ("procedure", "function"):
            ro, mr = st["core.routine"][o["id"]], st["engine_mysql.routine"][o["id"]]
            r = {"DEFINER": pr["definer"], "ROUTINE_TYPE": o["kind"].upper(), "ROUTINE_NAME": o["name"], "DTD_IDENTIFIER": ro["returns"],
                 "CHARACTER_SET_NAME": mr["returns_charset"], "SQL_DATA_ACCESS": mr["data_access"],
                 "IS_DETERMINISTIC": "YES" if ro["deterministic"] else "NO", "SECURITY_TYPE": ro["security"].upper(), "ROUTINE_COMMENT": o["comment"]}
            out[key] = P.routine(r, mr["parameter_text"], o["body"], version)
        elif o["kind"] == "trigger":
            tr = st["core.trigger"][o["id"]]
            out[key] = P.trigger({"DEFINER": pr["definer"], "TRIGGER_NAME": o["name"], "ACTION_TIMING": tr["timing"],
                                  "EVENT_MANIPULATION": tr["events"][0], "EVENT_OBJECT_TABLE": objs[o["parent_id"]]["name"]}, o["body"])
        elif o["kind"] == "event":
            e = st["engine_mysql.event"][o["id"]]
            status = {v: k for k, v in STATUS_WORD.items()}[e["status"]]
            out[key] = P.event({"DEFINER": pr["definer"], "EVENT_NAME": o["name"], "INTERVAL_VALUE": e["interval_value"],
                                "INTERVAL_FIELD": e["interval_field"], "STARTS": e["starts"] and e["starts"].replace("T", " "),
                                "ENDS": e["ends"] and e["ends"].replace("T", " "), "EXECUTE_AT": e["execute_at"] and e["execute_at"].replace("T", " "),
                                "ON_COMPLETION": e["on_completion"], "STATUS": status, "EVENT_COMMENT": o["comment"]}, o["body"])
        elif o["kind"] == "view":
            mv, cv = st["engine_mysql.view"][o["id"]], st["core.view"][o["id"]]
            out[key] = P.view({"TABLE_SCHEMA": schema, "TABLE_NAME": o["name"], "DEFINER": pr["definer"], "SECURITY_TYPE": mv["security"],
                               "CHECK_OPTION": cv["check_option"] or "NONE"}, mv["algorithm"], o["body"], version)
    return out


def script(st, version):
    """The whole schema as SQL bytes, written from the store: each program under the context it was made in."""
    text = write(st, version)
    ns = st["core.namespace"]
    chunks = []

    def say(sql, charset="utf8mb4"):
        enc = R.PY.get(charset.split("_")[0], "utf-8")
        chunks.append(sql.encode(enc, errors="mysql_latin1" if enc == "cp1252" else "strict"))
    say("SET NAMES utf8mb4;\nSET SESSION innodb_strict_mode = 0;\nSET FOREIGN_KEY_CHECKS = 0;\n")
    coll = {}
    for n in sorted(ns.values(), key=lambda n: n["name"]):
        c = st["engine_mysql.namespace"][n["id"]]["collation_name"]
        coll[n["name"]] = c
        say(f"CREATE DATABASE {D.q(n['name'])} DEFAULT CHARACTER SET {c.split('_')[0]} COLLATE {c};\n")
    objs = st["core.object"]
    for o in sorted((o for o in objs.values() if o["kind"] == "table"), key=lambda o: o["id"]):
        schema = ns[o["namespace_id"]]["name"]
        say(f"USE {D.q(schema)};\nSET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO';\n{R.implicit_collate(text[('table', schema, o['name'])])};\n")
    helpers = set()
    rank = {"view": 0, "procedure": 1, "function": 1, "trigger": 2, "event": 3}
    progs = sorted((o for o in objs.values() if o["kind"] in rank),
                   key=lambda o: (rank[o["kind"]], st["engine_mysql.trigger"].get(o["id"], {}).get("action_order", 0), o["id"]))
    for o in progs:
        schema = ns[o["namespace_id"]]["name"]
        pr = st["engine_mysql.program"][o["id"]]
        stmt = text[(o["kind"], schema, o["name"])]
        current = D.q(schema)
        under = st["engine_mysql.routine"].get(o["id"], {}).get("parameter_collation")
        if under and under != coll[schema]:
            current = D.q(f"sf_context_{under}")
            if under not in helpers:
                helpers.add(under)
                say(f"CREATE DATABASE {current} DEFAULT CHARACTER SET {under.split('_')[0]} COLLATE {under};\n")
            stmt = re.sub(r"\b(PROCEDURE|FUNCTION) `", lambda m: f"{m.group(1)} {D.q(schema)}.`", stmt, count=1)
        if o["kind"] == "trigger":
            order = st["engine_mysql.trigger"][o["id"]]["action_order"]
            if order > 1:  # the trigger it follows: same table, timing and event, one before it
                tr = st["core.trigger"][o["id"]]
                prev = next(p for p in objs.values() if p["kind"] == "trigger" and p["parent_id"] == o["parent_id"]
                            and st["core.trigger"][p["id"]]["timing"] == tr["timing"] and st["core.trigger"][p["id"]]["events"] == tr["events"]
                            and st["engine_mysql.trigger"][p["id"]]["action_order"] == order - 1)
                stmt = stmt.replace(" FOR EACH ROW ", f" FOR EACH ROW FOLLOWS {D.q(prev['name'])} ", 1)
        say(f"USE {current};\nSET SESSION sql_mode = {R.lit(pr['sql_mode'] or '')};\n"
            + (f"SET SESSION time_zone = {R.lit(pr['time_zone'])};\n" if pr.get("time_zone") else "")
            + f"SET NAMES {pr['character_set_client']} COLLATE {pr['collation_connection']};\nDELIMITER {R.DELIM}\n")
        say(stmt + R.DELIM + "\n", pr["character_set_client"])
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
        db = f"lab_store_mysql_{version.replace('.', '_')}"
        t_load = build(db, rows)
        size = V.psql("SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                      "WHERE n.nspname IN ('core', 'engine_mysql') AND c.relkind = 'r'", db)
        t = time.time()
        st = load_back(db)
        got = write(st, version)
        t_write = time.time() - t
        n, exact = Counter(), Counter()
        for p in snap["parts"]:
            pr = p["props"]
            if "__show_create" not in pr or p["kind"] not in ("table", "routine", "trigger", "event", "view"):
                continue
            if p["kind"] == "table" and pr.get("TABLE_TYPE") == "VIEW":
                continue
            kind = {"routine": pr.get("ROUTINE_TYPE", "").lower()}.get(p["kind"], p["kind"])
            schema = pr.get("TABLE_SCHEMA") or pr.get("ROUTINE_SCHEMA") or pr.get("TRIGGER_SCHEMA") or pr.get("EVENT_SCHEMA")
            name = pr.get("TABLE_NAME") or pr.get("ROUTINE_NAME") or pr.get("TRIGGER_NAME") or pr.get("EVENT_NAME")
            if (schema, name) in broken:
                continue
            n[kind] += 1
            if kind == "trigger" and not D.mysql8(version):
                exact[kind] += got.get((kind, schema, name)) is not None  # 5.7 shows the statement as typed: checked by the round trip
                continue
            want = D.normal(pr["__show_create"]) if kind == "table" else pr["__show_create"]
            exact[kind] += got.get((kind, schema, name)) == want
        total = sum(len(v) for v in rows.values())
        print(f"{'pass' if exact == n else 'FAIL'}  mysql {version}: {total} rows, loaded with versioning in {t_load:.1f}s, {size}; "
              f"written from the store in {t_write:.1f}s: " + ", ".join(f"{exact[k]}/{n[k]} {k}s" for k in sorted(n))
              + (f"; {len(broken)} broken views not stored" if broken else ""))
        if roundtrip:
            name = R.fresh(version)
            try:
                R.ready(name)
                sql = script(st, version)
                r = subprocess.run(["docker", "exec", "-i", name, "mysql", "-uroot", f"-p{SU.PW}", "--force", "--comments",
                                    "--default-character-set=utf8mb4"], input=sql, capture_output=True)
                refused = [l for l in r.stderr.decode(errors="replace").splitlines() if l.startswith("ERROR")]
                schemas = [n["name"] for n in st["core.namespace"].values()]
                saved = X.SCHEMAS
                X.SCHEMAS = tuple(schemas)
                again = X.extract_mysql(version, name)
                X.SCHEMAS = saved
                skip = {f"{s}.{v}" for s, v in broken}
                def settled(parts):
                    """What the round trip leaves as it is: a table's AUTO_INCREMENT counter is data, not design; 5.7
                    shows a trigger as it was typed, and the writer types it its own way."""
                    out = []
                    for p in parts:
                        pr = dict(p["props"])
                        if p["kind"] == "table" and "__show_create" in pr:
                            pr["__show_create"] = D.normal(pr["__show_create"])
                        if p["kind"] == "trigger" and not D.mysql8(version):
                            pr.pop("__show_create", None)
                        out.append(dict(p, props=pr))
                    return out
                diffs, m = R.compare(settled(snap["parts"]), settled(again), skip)
                ok = not refused and not diffs
                print(f"      {'pass' if ok else 'FAIL'}  round trip: {len(sql) // 1024} KB of SQL from the store, {len(refused)} refused, "
                      f"{m} parts compared, {sum(diffs.values())} properties differ")
                for e in refused[:4]:
                    print(f"            refused: {re.sub('`[^`]*`', '`x`', e)[:150]}")
                for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:8]:
                    print(f"            differs: {k} in {c} parts")
            finally:
                SU.remove(name)


if __name__ == "__main__":
    main()
