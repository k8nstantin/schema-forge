"""The locked design on PostgreSQL snapshots: schema/cortex and engines/postgresql/schema, loaded exactly as the dump
loads them, every part of a snapshot stored in them as one design, read back from them alone, and every index,
constraint, trigger and function written from what was read back and compared with the server's own rendering
(pg_get_indexdef, pg_get_constraintdef, pg_get_triggerdef, pg_get_functiondef); with --roundtrip the whole schema
written as SQL from the locked tables, loaded into a fresh server of the same version, read again and compared, part
by part. The writer is lab/pg_store.py's, proven on the lab's first store: here it reads only what the locked tables
gave back, so a fact the locked tables cannot hold shows as a difference.

  python3 lab/repo_pg_store.py [--roundtrip] <snapshot.json> [...]
"""
import json
import os
import subprocess
import sys
import time
import uuid
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import extract as X  # noqa: E402
import pg_store as P  # noqa: E402
import repo_store as R  # noqa: E402

KIND = {"materialized view": "materialized_view"}
TYPE_KIND = {"e": "enum", "c": "composite", "d": "domain", "r": "range"}
ACTION = {"a": "no_action", "r": "restrict", "c": "cascade", "n": "set_null", "d": "set_default"}
MATCH = {"s": "simple", "f": "full", "p": "partial"}
ENABLED = {"O": "origin", "D": "disabled", "R": "replica", "A": "always"}
CONSTRAINT = {"not null": "not_null"}
MODE = {"IN": "in", "OUT": "out", "INOUT": "in_out", "VARIADIC": "variadic", "TABLE": "table"}
TIMING = {"BEFORE": "before", "AFTER": "after", "INSTEAD OF": "instead_of"}
VOLATILITY = {"i": "immutable", "s": "stable", "v": "volatile"}
PARALLEL = {"s": "safe", "r": "restricted", "u": "unsafe"}
PERSISTENCE = {"p": "permanent", "u": "unlogged", "t": "temporary"}
REPLICA = {"d": "default", "n": "nothing", "f": "full", "i": "index"}
ORDER = ["cortex.designs", "cortex.namespaces", "cortex.required_extensions",
         "cortex.objects", "cortex.columns", "cortex.indexes", "cortex.index_parts", "cortex.constraints", "cortex.constraint_columns",
         "cortex.dependencies", "cortex.views", "cortex.routines", "cortex.routine_parameters", "cortex.triggers", "cortex.partitionings",
         "cortex.partitions", "cortex.sequences", "cortex.column_identities", "cortex.domains", "cortex.enum_values",
         "engine_postgresql.namespaces", "engine_postgresql.collations", "engine_postgresql.relations", "engine_postgresql.inheritance",
         "engine_postgresql.columns", "engine_postgresql.indexes", "engine_postgresql.index_parts", "engine_postgresql.constraints",
         "engine_postgresql.routines", "engine_postgresql.types", "engine_postgresql.sequences", "engine_postgresql.triggers", "engine_postgresql.trigger_columns",
         "engine_postgresql.policies", "engine_postgresql.rules"]


def to_locked(old, version):
    """The first store's rows as rows of the locked design: one design, every id a UUIDv7."""
    ids = defaultdict(lambda: str(uuid.uuid7()))
    U = lambda i: None if i is None else ids[i]  # noqa: E731
    design = str(uuid.uuid7())
    old = defaultdict(list, old)
    st = defaultdict(dict, {k: {r["id"]: r for r in rs} for k, rs in old.items()})
    out = defaultdict(list)

    def add(table, row):
        out[table].append({"design": design, **row} if not table.startswith("cortex.engine_") and table not in (
            "cortex.designs", "cortex.object_kinds") else row)
    out["cortex.designs"].append({"id": design, "name": f"postgresql-{version}", "engine": "postgresql", "engine_version": version, "comment": None})
    for k, n in enumerate(old["core.namespace"]):
        add("cortex.namespaces", {"id": U(n["id"]), "parent": U(n["parent_id"]), "name": n["name"], "position": k + 1, "comment": n["comment"]})
    for k, e in enumerate(old["engine_postgresql.extension"]):
        add("cortex.required_extensions", {"id": U(e["id"]), "name": e["name"], "namespace_name": e["schema_name"], "version": e["version"],
                                           "position": k + 1})
    types = {t["id"]: t for t in old["engine_postgresql.type"]}
    for k, o in enumerate(old["core.object"]):
        kind = TYPE_KIND[types[o["id"]]["type_kind"]] if o["kind"] == "type" else KIND.get(o["kind"], o["kind"])
        add("cortex.objects", {"id": U(o["id"]), "namespace": U(o["namespace_id"]), "kind": kind, "name": o["name"], "signature": o["signature"],
                               "parent": U(o["parent_id"]), "position": k + 1, "comment": o["comment"], "notes": None})
    identity = {s["owned_by"]: s["id"] for s in old["core.sequence"] if s["owned_by"] and st["engine_postgresql.sequence"][s["id"]]["identity"]}
    for c in old["core.column"]:
        add("cortex.columns", {"id": U(c["id"]), "object": U(c["object_id"]), "position": c["position"], "name": c["name"], "type": c["type"],
                               "nullable": c["nullable"], "default_value": c["default_value"], "generated_expression": c["generated"],
                               "generated_stored": c["generated_stored"], "collation": c["collation_name"], "comment": c["comment"]})
        if c["identity"]:
            add("cortex.column_identities", {"id": U(c["id"]), "always": c["identity"] == "always", "sequence": U(identity.get(c["id"]))})
    for i in old["core.index"]:
        add("cortex.indexes", {"id": U(i["id"]), "object": U(i["object_id"]), "position": i["position"], "name": i["name"], "unique": i["is_unique"],
                               "method": i["method"], "condition": i["predicate"], "comment": i["comment"],
                               "parent": U(st["engine_postgresql.index"][i["id"]]["parent_index_id"])})
    for p in old["core.index_part"]:
        add("cortex.index_parts", {"id": U(p["id"]), "index": U(p["index_id"]), "position": p["position"], "column": U(p["column_id"]),
                                   "expression": p["expression"], "descending": p["descending"],
                                   "included": not st["engine_postgresql.index_part"][p["id"]]["is_key"]})
    place = Counter()
    for c in old["core.constraint"]:
        place[c["object_id"]] += 1
        add("cortex.constraints", {"id": U(c["id"]), "object": U(c["object_id"]), "name": c["name"], "kind": CONSTRAINT.get(c["kind"], c["kind"]),
                                   "in_database": c["in_database"], "enforced": c["enforced"], "deferrable": c["is_deferrable"],
                                   "initially_deferred": c["is_deferred"], "expression": c["expression"], "index": U(c["index_id"]),
                                   "to_object": U(c["ref_object_id"]), "to_namespace_name": c["ref_namespace"], "to_object_name": c["ref_object"],
                                   "on_delete": ACTION.get(c["on_delete"]), "on_update": ACTION.get(c["on_update"]),
                                   "match_kind": MATCH.get(c["match"]), "position": place[c["object_id"]]})
    for c in old["core.constraint_column"]:
        only = st["engine_postgresql.constraint"][c["constraint_id"]].get("delete_set_columns") or []
        add("cortex.constraint_columns", {"id": U(c["id"]), "constraint": U(c["constraint_id"]), "position": c["position"],
                                          "column": U(c["column_id"]), "to_column": U(c["ref_column_id"]), "to_column_name": c["ref_column"],
                                          **({"options": {"set_on_delete": True}} if c["column_id"] in only else {})})
    place = Counter()
    for d in old["core.dependency"]:
        place[d["object_id"]] += 1
        add("cortex.dependencies", {"id": U(d["id"]), "object": U(d["object_id"]), "uses": U(d["uses_object_id"]), "position": place[d["object_id"]]})
    body = {o["id"]: o["body"] for o in old["core.object"]}
    for v in old["core.view"]:
        add("cortex.views", {"id": U(v["id"]), "query": body[v["id"]], "check_option": v["check_option"] and v["check_option"].lower()})
    for r in old["core.routine"]:
        add("cortex.routines", {"id": U(r["id"]), "returns": r["returns"], "language": r["language"], "deterministic": r["deterministic"],
                                "security": r["security"], "body": body[r["id"]]})
    for p in old["core.parameter"]:
        d = st["engine_postgresql.parameter"].get(p["id"])
        add("cortex.routine_parameters", {"id": U(p["id"]), "routine": U(p["object_id"]), "position": p["position"], "name": p["name"],
                                          "type": p["type"], "mode": MODE[p["mode"]], "default_value": d["default_value"] if d else None})
    for t in old["core.trigger"]:
        e = st["engine_postgresql.trigger"][t["id"]]
        add("cortex.triggers", {"id": U(t["id"]), "timing": TIMING[t["timing"]], "events": [x.lower() for x in t["events"]], "level": t["level"],
                                "condition": e["condition"], "body": None, "action_order": 1})
    for p in old["core.partitioning"]:
        add("cortex.partitionings", {"id": U(p["id"]), "strategy": p["strategy"], "expression": p["expression"]})
    for p in old["core.partition"]:
        add("cortex.partitions", {"id": U(p["id"]), "partitioning": U(p["object_id"]), "position": p["position"], "name": p["name"],
                                  "bounds": p["bounds"], "table_object": U(p["table_id"]), "comment": p["comment"]})
    for s in old["core.sequence"]:
        add("cortex.sequences", {"id": U(s["id"]), "type": s["type"], "start": s["start"], "increment": s["increment"], "min_value": s["minimum"],
                                 "max_value": s["maximum"], "cache": s["cache"], "cycle": s["cycle"], "owned_by": U(s["owned_by"])})
    for t in old["engine_postgresql.type"]:
        if t["type_kind"] == "d":
            add("cortex.domains", {"id": U(t["id"]), "base": t["base"], "default_value": t["default_value"], "nullable": not t["not_null"],
                                   "collation": t["collation_name"]})
        for k, label in enumerate(t["labels"] or []):
            add("cortex.enum_values", {"id": str(uuid.uuid7()), "object": U(t["id"]), "position": k + 1, "value": label})
        for k, f in enumerate(json.loads(t["attributes"]) if t["attributes"] else []):
            add("cortex.columns", {"id": str(uuid.uuid7()), "object": U(t["id"]), "position": k + 1, "name": f["name"], "type": f["type"],
                                   "nullable": True, "default_value": None, "generated_expression": None, "generated_stored": None,
                                   "collation": None, "comment": None})
        add("engine_postgresql.types", {"id": U(t["id"]), "owner": t["owner"], "acl": t["acl"], "range_subtype": t["range_subtype"],
                                        "multirange": t["multirange"]})
    for n in old["engine_postgresql.namespace"]:
        add("engine_postgresql.namespaces", {"id": U(n["id"]), "owner": n["owner"], "acl": n["acl"]})
    for c in old["engine_postgresql.collation"]:
        add("engine_postgresql.collations", {"id": U(c["id"]), "namespace": U(c["namespace_id"]), "name": c["name"], "provider": c["provider"],
                                             "locale": c["locale"], "lc_collate": c["lc_collate"], "lc_ctype": c["lc_ctype"],
                                             "deterministic": c["deterministic"], "comment": c["comment"]})
    for r in old["engine_postgresql.relation"]:
        add("engine_postgresql.relations", {"id": U(r["id"]), **{k: r[k] for k in ("options", "access_method", "owner", "acl",
                                                                                     "row_security", "force_row_security", "populated")},
                                            "persistence": PERSISTENCE[r["persistence"]], "replica_identity": REPLICA[r["replica_identity"]]})
    for i in old["engine_postgresql.inheritance"]:
        add("engine_postgresql.inheritance", {"id": U(i["id"]), "object": U(i["object_id"]), "parent": U(i["parent_id"]), "position": i["position"]})
    for c in old["engine_postgresql.column"]:
        add("engine_postgresql.columns", {"id": U(c["id"]), "is_local": c["is_local"], "inherit_count": c["inherit_count"], "options": c["options"],
                                          "acl": c["acl"]})
    for i in old["engine_postgresql.index"]:
        add("engine_postgresql.indexes", {"id": U(i["id"]), "nulls_not_distinct": i["nulls_not_distinct"], "options": i["options"],
                                          "replica_identity_index": i["replica_identity_index"], "clustered": i["clustered"]})
    for p in old["engine_postgresql.index_part"]:
        add("engine_postgresql.index_parts", {"id": U(p["id"]), "nulls_first": p["nulls_first"], "operator_class": p["operator_class"],
                                              "collation": p["collation_name"]})
    for c in old["engine_postgresql.constraint"]:
        add("engine_postgresql.constraints", {"id": U(c["id"]), **{k: c[k] for k in ("validated", "no_inherit", "is_local", "inherit_count", "operators")}})
    for r in old["engine_postgresql.routine"]:
        add("engine_postgresql.routines", {"id": U(r["id"]), **{k: r[k] for k in ("strict", "leakproof", "returns_set",
                                                                                   "cost", "result_rows", "config", "owner", "acl")},
                                           "volatility": VOLATILITY[r["volatility"]], "parallel": PARALLEL[r["parallel"]]})
    for s in old["engine_postgresql.sequence"]:
        add("engine_postgresql.sequences", {"id": U(s["id"]), "identity": s["identity"]})
    for t in old["engine_postgresql.trigger"]:
        for k, c in enumerate(t["update_columns"] or []):
            add("engine_postgresql.trigger_columns", {"id": str(uuid.uuid7()), "trigger": U(t["id"]), "column": U(c), "position": k + 1})
        add("engine_postgresql.triggers", {"id": U(t["id"]), "function_name": t["function_name"], "arguments": t["arguments"],
                                           "old_table": t["old_table"], "new_table": t["new_table"], "enabled": ENABLED[t["enabled"]],
                                           "deferrable": t["is_deferrable"], "initially_deferred": t["initially_deferred"],
                                           "constraint_trigger": t["constraint_trigger"], "from_table": t["from_table"]})
    for p in old["engine_postgresql.policy"]:
        add("engine_postgresql.policies", {"id": U(p["id"]), "object": U(p["object_id"]), "name": p["name"], "permissive": p["permissive"],
                                           "command": p["command"], "roles": p["roles"], "using_expression": p["using_expr"],
                                           "check_expression": p["check_expr"]})
    for r in old["engine_postgresql.rule"]:
        add("engine_postgresql.rules", {"id": U(r["id"]), "object": U(r["object_id"]), "name": r["name"], "definition": r["definition"]})
    return out, design


def from_locked(st):
    """The locked design's rows, as read back, in the shape the first store's writer reads: every fact from them alone."""
    inv = lambda d: {v: k for k, v in d.items()}  # noqa: E731
    TK, AC, MA, EN, CO = inv(TYPE_KIND), inv(ACTION), inv(MATCH), inv(ENABLED), inv(CONSTRAINT)
    MO, TI, VO, PA, PE, RE = inv(MODE), inv(TIMING), inv(VOLATILITY), inv(PARALLEL), inv(PERSISTENCE), inv(REPLICA)
    design = next(iter(st["cortex.designs"].values()))
    objs = st["cortex.objects"]
    out = defaultdict(dict)
    out["core.server"][design["id"]] = {"id": design["id"], "engine": "postgresql", "version": design["engine_version"], "name": design["name"]}
    top = next(n["id"] for n in st["cortex.namespaces"].values() if n["parent"] is None)
    for n in st["cortex.namespaces"].values():
        out["core.namespace"][n["id"]] = {"id": n["id"], "server_id": design["id"], "parent_id": n["parent"], "name": n["name"], "comment": n["comment"]}
    for e in sorted(st["cortex.required_extensions"].values(), key=lambda e: e["position"]):
        out["engine_postgresql.extension"][e["id"]] = {"id": e["id"], "database_id": top, "name": e["name"], "schema_name": e["namespace_name"],
                                                       "version": e["version"]}
    body = {**{v["id"]: v["query"] for v in st["cortex.views"].values()}, **{r["id"]: r["body"] for r in st["cortex.routines"].values()}}
    for o in sorted(objs.values(), key=lambda o: o["position"]):
        kind = "type" if o["kind"] in TK else {"materialized_view": "materialized view"}.get(o["kind"], o["kind"])
        out["core.object"][o["id"]] = {"id": o["id"], "namespace_id": o["namespace"], "parent_id": o["parent"], "kind": kind, "name": o["name"],
                                       "signature": o["signature"], "comment": o["comment"], "body": body.get(o["id"])}
    ident = st["cortex.column_identities"]
    by_object = defaultdict(list)
    for c in st["cortex.columns"].values():
        by_object[c["object"]].append(c)
    for c in st["cortex.columns"].values():
        if objs[c["object"]]["kind"] == "composite":
            continue
        i = ident.get(c["id"])
        out["core.column"][c["id"]] = {"id": c["id"], "object_id": c["object"], "position": c["position"], "name": c["name"], "type": c["type"],
                                       "nullable": c["nullable"], "default_value": c["default_value"], "default_is_expression": True,
                                       "generated": c["generated_expression"], "generated_stored": c["generated_stored"],
                                       "identity": ("always" if i["always"] else "by default") if i else None, "collation_name": c["collation"],
                                       "comment": c["comment"]}
    primary = {c["index"] for c in st["cortex.constraints"].values() if c["kind"] == "primary" and c["index"]}
    for i in st["cortex.indexes"].values():
        out["core.index"][i["id"]] = {"id": i["id"], "object_id": i["object"], "name": i["name"], "position": i["position"], "is_primary": i["id"] in primary,
                                      "is_unique": i["unique"], "method": i["method"], "predicate": i["condition"], "comment": i["comment"]}
    for p in st["cortex.index_parts"].values():
        out["core.index_part"][p["id"]] = {"id": p["id"], "index_id": p["index"], "position": p["position"], "column_id": p["column"],
                                           "expression": p["expression"], "descending": p["descending"]}
        e = st["engine_postgresql.index_parts"].get(p["id"], {})
        out["engine_postgresql.index_part"][p["id"]] = {"id": p["id"], "is_key": not p["included"], "nulls_first": e.get("nulls_first", False),
                                                        "operator_class": e.get("operator_class"), "collation_name": e.get("collation")}
    for c in st["cortex.constraints"].values():
        out["core.constraint"][c["id"]] = {"id": c["id"], "object_id": c["object"], "name": c["name"], "kind": CO.get(c["kind"], c["kind"]),
                                           "in_database": c["in_database"], "enforced": c["enforced"], "is_deferrable": c["deferrable"],
                                           "is_deferred": c["initially_deferred"], "expression": c["expression"], "index_id": c["index"],
                                           "ref_object_id": c["to_object"], "ref_namespace": c["to_namespace_name"], "ref_object": c["to_object_name"],
                                           "on_delete": AC.get(c["on_delete"]), "on_update": AC.get(c["on_update"]), "match": MA.get(c["match_kind"])}
    for c in st["cortex.constraint_columns"].values():
        out["core.constraint_column"][c["id"]] = {"id": c["id"], "constraint_id": c["constraint"], "position": c["position"], "column_id": c["column"],
                                                  "ref_column_id": c["to_column"], "ref_column": c["to_column_name"]}
    for d in st["cortex.dependencies"].values():
        out["core.dependency"][d["id"]] = {"id": d["id"], "object_id": d["object"], "uses_object_id": d["uses"], "uses_column_id": None}
    for v in st["cortex.views"].values():
        out["core.view"][v["id"]] = {"id": v["id"], "kind": out["core.object"][v["id"]]["kind"], "check_option": v["check_option"] and v["check_option"].upper()}
    for r in st["cortex.routines"].values():
        out["core.routine"][r["id"]] = {"id": r["id"], "kind": objs[r["id"]]["kind"], "returns": r["returns"], "language": r["language"],
                                        "deterministic": r["deterministic"], "security": r["security"]}
    for p in st["cortex.routine_parameters"].values():
        out["core.parameter"][p["id"]] = {"id": p["id"], "object_id": p["routine"], "position": p["position"], "name": p["name"], "mode": MO[p["mode"]],
                                          "type": p["type"]}
        if p["default_value"] is not None:
            out["engine_postgresql.parameter"][p["id"]] = {"id": p["id"], "default_value": p["default_value"]}
    for t in st["cortex.triggers"].values():
        out["core.trigger"][t["id"]] = {"id": t["id"], "kind": "trigger", "timing": TI[t["timing"]], "events": [x.upper() for x in t["events"]],
                                        "level": t["level"]}
        e = st["engine_postgresql.triggers"][t["id"]]
        fires = sorted((x for x in st["engine_postgresql.trigger_columns"].values() if x["trigger"] == t["id"]), key=lambda x: x["position"])
        out["engine_postgresql.trigger"][t["id"]] = {"id": t["id"], "function_name": e["function_name"], "arguments": e["arguments"],
                                                     "update_columns": [x["column"] for x in fires] or None, "condition": t["condition"], "old_table": e["old_table"],
                                                     "new_table": e["new_table"], "enabled": EN[e["enabled"]], "is_deferrable": e["deferrable"],
                                                     "initially_deferred": e["initially_deferred"], "constraint_trigger": e["constraint_trigger"],
                                                     "from_table": e["from_table"]}
    for p in st["cortex.partitionings"].values():
        out["core.partitioning"][p["id"]] = dict(p)
    for p in st["cortex.partitions"].values():
        out["core.partition"][p["id"]] = {"id": p["id"], "object_id": p["partitioning"], "position": p["position"], "name": p["name"],
                                          "bounds": p["bounds"], "table_id": p["table_object"], "comment": p["comment"]}
    for s in st["cortex.sequences"].values():
        out["core.sequence"][s["id"]] = {"id": s["id"], "kind": "sequence", "type": s["type"], "start": s["start"], "increment": s["increment"],
                                         "minimum": s["min_value"], "maximum": s["max_value"], "cache": s["cache"], "cycle": s["cycle"],
                                         "owned_by": s["owned_by"]}
    enum = defaultdict(list)
    for e in st["cortex.enum_values"].values():
        enum[e["object"]].append(e)
    for t in st["engine_postgresql.types"].values():
        o, d = objs[t["id"]], st["cortex.domains"].get(t["id"], {})
        fields = sorted(by_object[t["id"]], key=lambda c: c["position"]) if o["kind"] == "composite" else []
        out["engine_postgresql.type"][t["id"]] = {
            "id": t["id"], "kind": "type", "type_kind": TK[o["kind"]],
            "labels": [e["value"] for e in sorted(enum[t["id"]], key=lambda e: e["position"])] or None,
            "attributes": json.dumps([{"name": f["name"], "type": f["type"]} for f in fields]) if fields else None,
            "base": d.get("base"), "not_null": not d.get("nullable", True), "default_value": d.get("default_value"),
            "collation_name": d.get("collation"), "range_subtype": t["range_subtype"], "multirange": t["multirange"], "owner": t["owner"], "acl": t["acl"]}
    for n in st["engine_postgresql.namespaces"].values():
        out["engine_postgresql.namespace"][n["id"]] = {"id": n["id"], "owner": n["owner"], "acl": n["acl"]}
    for c in st["engine_postgresql.collations"].values():
        out["engine_postgresql.collation"][c["id"]] = {**{k: c[k] for k in ("id", "name", "provider", "locale", "lc_collate", "lc_ctype",
                                                                          "deterministic", "comment")}, "namespace_id": c["namespace"]}
    for r in st["engine_postgresql.relations"].values():
        out["engine_postgresql.relation"][r["id"]] = {**{k: v for k, v in r.items() if k != "design"}, "persistence": PE[r["persistence"]],
                                                      "replica_identity": RE[r["replica_identity"]]}
    for i in st["engine_postgresql.inheritance"].values():
        out["engine_postgresql.inheritance"][i["id"]] = {"id": i["id"], "object_id": i["object"], "parent_id": i["parent"], "position": i["position"]}
    for c in st["engine_postgresql.columns"].values():
        out["engine_postgresql.column"][c["id"]] = {k: v for k, v in c.items() if k != "design"}
    for i in st["engine_postgresql.indexes"].values():
        out["engine_postgresql.index"][i["id"]] = {"id": i["id"], "nulls_not_distinct": i["nulls_not_distinct"], "options": i["options"],
                                                   "replica_identity_index": i["replica_identity_index"], "clustered": i["clustered"],
                                                   "parent_index_id": st["cortex.indexes"][i["id"]]["parent"]}
    sets = {}
    for cc in sorted(st["cortex.constraint_columns"].values(), key=lambda c: c["position"]):
        if (cc.get("options") or {}).get("set_on_delete"):
            sets.setdefault(cc["constraint"], []).append(cc["column"])
    for c in st["engine_postgresql.constraints"].values():
        out["engine_postgresql.constraint"][c["id"]] = {**{k: v for k, v in c.items() if k != "design"}, "delete_set_columns": sets.get(c["id"])}
    for r in st["engine_postgresql.routines"].values():
        out["engine_postgresql.routine"][r["id"]] = {**{k: v for k, v in r.items() if k != "design"}, "volatility": VO[r["volatility"]],
                                                     "parallel": PA[r["parallel"]]}
    for s in st["engine_postgresql.sequences"].values():
        out["engine_postgresql.sequence"][s["id"]] = {"id": s["id"], "identity": s["identity"]}
    for p in st["engine_postgresql.policies"].values():
        out["engine_postgresql.policy"][p["id"]] = {"id": p["id"], "object_id": p["object"], "name": p["name"], "permissive": p["permissive"],
                                                    "command": p["command"], "roles": p["roles"], "using_expr": p["using_expression"],
                                                    "check_expr": p["check_expression"]}
    for r in st["engine_postgresql.rules"].values():
        out["engine_postgresql.rule"][r["id"]] = {"id": r["id"], "object_id": r["object"], "name": r["name"], "definition": r["definition"]}
    for k in P.ORDER:
        out.setdefault(k, {})
    return out


def jsonish(rows):
    """Lists and objects as JSON text, for the locked design's JSONB columns."""
    return {k: [{c: (json.dumps(v) if isinstance(v, (list, dict)) else v) for c, v in r.items()} for r in rs] for k, rs in rows.items()}


def main():
    roundtrip = "--roundtrip" in sys.argv
    for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
        snap = json.load(open(path))
        version = snap["version"]
        rows, design = to_locked(P.rows_of(snap), version)
        db = f"lab_repo_postgresql_{version}"
        R.build(db)
        t = time.time()
        rows = R.OL.to_options(rows)
        rows = jsonish(rows)
        C.psql("BEGIN;\nSET ROLE sf_service;\n" + "".join(R.copy_sql(k, rows[k]) for k in ORDER if rows.get(k)) + "COMMIT;\n", db)
        t_load = time.time() - t
        st = {k: {r["id"]: r for r in json.loads(C.psql(f"SELECT coalesce(json_agg(to_jsonb(t)), '[]') FROM {k} t;", db))}
              for k in ORDER if k not in R.MOVED}
        st = R.OL.from_options(st)
        S = P.Store(from_locked(st))
        n, exact, first = Counter(), Counter(), {}
        names = {(S.schema(S.objs[i["object_id"]]), i["name"]): i for i in S.st["core.index"].values()}
        home = {p["key"]: p["parent"] for p in snap["parts"] if p["kind"] == "relation"}
        for p in snap["parts"]:
            pr = p["props"]
            if p["kind"] == "index":
                schema = home[p["parent"]]
                got, want = P.index_def(S, names[(schema, p["key"][len(schema) + 1:])]), pr["definition"]
            elif p["kind"] == "constraint" and pr["contype"] in "pufcxn":
                c = next(c for c in S.st["core.constraint"].values() if c["name"] == pr["conname"]
                         and f"{S.schema(S.objs[c['object_id']])}.{S.objs[c['object_id']]['name']}" == p["parent"])
                got, want = P.constraint_def(S, c), pr["definition"]
            elif p["kind"] == "trigger":
                o = next(o for o in S.objs.values() if o["kind"] == "trigger" and o["name"] == pr["tgname"]
                         and f"{S.schema(S.objs[o['parent_id']])}.{S.objs[o['parent_id']]['name']}" == p["parent"])
                got, want = P.trigger_def(S, o), pr["definition"]
            elif p["kind"] == "routine" and not pr.get("made_by"):
                o = next(o for o in S.objs.values() if o["kind"] in ("function", "procedure") and o["name"] == pr["proname"]
                         and S.schema(o) == p["parent"] and o["signature"] == p["key"][p["key"].index("("):])
                got, want = P.function_def(S, o), pr["create"]
            else:
                continue
            n[p["kind"]] += 1
            if got == want:
                exact[p["kind"]] += 1
            else:
                first.setdefault(p["kind"], (want, got))
        print(f"{'pass' if exact == n else 'FAIL'}  postgresql {version}: one design, {sum(len(v) for k, v in rows.items() if not k.startswith('cortex.engine_') and k not in ('cortex.designs', 'cortex.object_kinds'))} "
              f"rows in the locked design, loaded as sf_service, every foreign key held, in {t_load:.1f}s; written from it: "
              + ", ".join(f"{exact[k]}/{n[k]} {k}s" for k in sorted(n)))
        for k, (w, g) in first.items():
            print(f"      {k}: want {w!r}\n      {' ' * len(k)}  got  {g!r}")
        if roundtrip:
            name = C.fresh_pg(version)
            try:
                C.ready_pg(name)
                sql = snap.get("prelude", "") + P.script(S.st)  # what the server needs before the schema: its roles, a stand-in
                r = subprocess.run(["docker", "exec", "-i", name, "psql", "-U", "postgres", "-q"], input=sql, capture_output=True, text=True)
                refused = [line for line in r.stderr.splitlines() if "ERROR:" in line]
                saved, X.SCHEMAS = X.SCHEMAS, tuple(n["name"] for n in S.ns.values() if n["parent_id"])
                again = X.extract_pg(version, name)
                X.SCHEMAS = saved
                diffs, m = C.compare(snap["parts"], again)
                ok = not refused and not diffs
                print(f"      {'pass' if ok else 'FAIL'}  round trip: {len(sql) // 1024} KB of SQL from the locked design, {len(refused)} refused, "
                      f"{m} parts compared, {sum(diffs.values())} properties differ")
                for e in refused[:5]:
                    print(f"            refused: {e[:160]}")
                for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:10]:
                    print(f"            differs: {k} in {c} parts")
            finally:
                C.S.remove(name)


if __name__ == "__main__":
    main()
