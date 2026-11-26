"""The store (lab/design/store.sql) on PostgreSQL snapshots: every object loaded into the global schema and the
PostgreSQL plugin's; every index, constraint, trigger and function written from the store's facts and compared with
the server's own rendering (pg_get_indexdef, pg_get_constraintdef, pg_get_triggerdef, pg_get_functiondef); with
--roundtrip the whole schema written as SQL from the store, loaded into a fresh server of the same version, read again
and compared, part by part.

  python3 lab/pg_store.py [--roundtrip] <snapshot.json> [...]
"""
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402
import extract as X  # noqa: E402
import store as ST  # noqa: E402

DATABASE = "postgres"
ORDER = ["core.server", "core.namespace", "core.object", "core.column", "core.index", "core.index_part", "core.constraint",
         "core.constraint_column", "core.dependency", "core.routine", "core.parameter", "core.trigger", "core.view",
         "core.partitioning", "core.partition", "core.sequence", "engine_postgresql.namespace", "engine_postgresql.extension",
         "engine_postgresql.collation", "engine_postgresql.relation", "engine_postgresql.inheritance", "engine_postgresql.column",
         "engine_postgresql.index", "engine_postgresql.index_part", "engine_postgresql.constraint", "engine_postgresql.routine",
         "engine_postgresql.parameter", "engine_postgresql.trigger", "engine_postgresql.type", "engine_postgresql.sequence",
         "engine_postgresql.policy", "engine_postgresql.rule"]
KEYWORDS = set(C.psql("SELECT string_agg(word, ' ') FROM pg_get_keywords() WHERE catcode <> 'U'", "postgres").split())
ACTION = {"a": None, "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"}


def qi(n):
    """An identifier as PostgreSQL's quote_ident writes it."""
    return n if re.fullmatch(r"[a-z_][a-z0-9_$]*", n) and n not in KEYWORDS else '"' + n.replace('"', '""') + '"'


def qrel(schema, name):
    """A name as the server's renderings write it: schema-qualified unless public is where it is found."""
    return qi(name) if schema == "public" else f"{qi(schema)}.{qi(name)}"


def split_args(text):
    """Top-level comma split of a rendered list."""
    out, depth, cur, quote = [], 0, "", False
    for ch in text or "":
        if ch == "'":
            quote = not quote
        if not quote:
            depth += ch == "("
            depth -= ch == ")"
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
                continue
        cur += ch
    return out + ([cur.strip()] if cur.strip() else [])


UNHELD = {}   # what rows_of left out: no place for it in the design yet
UNHELD_KEYS = set()


def rows_of(snap):
    n = [0]

    def nid():
        n[0] += 1
        return n[0]
    out, by = defaultdict(list), defaultdict(list)
    # a relation of a kind the design holds no place for yet, and every part on it, is left out and counted, not guessed
    unheld = {p["key"] for p in snap["parts"] if p["kind"] == "relation" and p["props"]["relkind"] not in "rpvmS"
              or p["kind"] == "routine" and p["props"].get("prokind") not in ("f", "p")}
    UNHELD_KEYS.update(unheld)
    for p in snap["parts"]:
        if p["key"] in unheld or p["parent"] in unheld:
            UNHELD[p["kind"]] = UNHELD.get(p["kind"], 0) + 1
            continue
        by[p["kind"]].append(p)
    server = nid()
    out["core.server"].append({"id": server, "engine": "postgresql", "version": snap["version"], "name": f"postgresql-{snap['version']}"})
    db = nid()
    out["core.namespace"].append({"id": db, "server_id": server, "parent_id": None, "name": DATABASE, "comment": None})
    ns = {}
    for p in by["namespace"]:
        pr = p["props"]
        i = ns[p["key"]] = nid()
        out["core.namespace"].append({"id": i, "server_id": server, "parent_id": db, "name": p["key"], "comment": pr.get("comment")})
        out["engine_postgresql.namespace"].append({"id": i, "owner": pr.get("owner"), "acl": pr.get("acl")})
    for p in by["extension"]:
        pr = p["props"]
        out["engine_postgresql.extension"].append({"id": nid(), "database_id": db, "name": p["key"], "schema_name": pr["schema"], "version": pr["version"]})
    for p in by["collation"]:
        pr = p["props"]
        out["engine_postgresql.collation"].append({
            "id": nid(), "namespace_id": ns[p["parent"]], "name": pr["collname"], "provider": {"i": "icu", "c": "libc", "b": "builtin"}[pr["collprovider"]],
            "locale": pr.get("colllocale") or pr.get("colliculocale"), "lc_collate": pr.get("collcollate"), "lc_ctype": pr.get("collctype"),
            "deterministic": pr["collisdeterministic"], "comment": None})
    obj, col = {}, {}
    # a part's parent names its table as schema.table; names may hold dots, so the schema is looked up, never split
    home = {p["key"]: p["parent"] for p in by["relation"]}
    home.update({p["key"]: p["parent"] for p in by["type"]})
    kinds = {"r": "table", "p": "table", "v": "view", "m": "materialized view", "S": "sequence"}
    for p in by["relation"]:
        pr = p["props"]
        i = obj[p["key"]] = nid()
        kind = kinds[pr["relkind"]]
        out["core.object"].append({"id": i, "namespace_id": ns[p["parent"]], "parent_id": None, "kind": kind, "name": pr["relname"],
                                   "signature": "", "comment": pr.get("comment"), "body": pr.get("view_definition")})
        out["engine_postgresql.relation"].append({
            "id": i, "persistence": pr["relpersistence"], "options": pr.get("reloptions"), "access_method": pr.get("am"), "owner": pr.get("owner"),
            "acl": pr.get("acl"), "row_security": pr["relrowsecurity"], "force_row_security": pr["relforcerowsecurity"],
            "replica_identity": pr["relreplident"], "populated": pr["relispopulated"], "of_type": pr.get("of_type"),
            "tablespace": pr.get("tablespace")})
        if kind in ("view", "materialized view"):
            opts = pr.get("reloptions") or []
            check = next((o.split("=")[1].upper() for o in opts if o.startswith("check_option=")), None)
            out["core.view"].append({"id": i, "kind": kind, "check_option": check})
    for p in by["relation"]:
        pr = p["props"]
        for k, parent in enumerate(pr.get("inherits") or []):
            if pr.get("relispartition"):
                continue
            out["engine_postgresql.inheritance"].append({"id": nid(), "object_id": obj[p["key"]], "parent_id": obj[parent], "position": k + 1})
        if pr.get("partition_key"):
            m = re.match(r"(\w+) \((.*)\)$", pr["partition_key"])
            out["core.partitioning"].append({"id": obj[p["key"]], "strategy": m.group(1), "expression": m.group(2)})
        for u in pr.get("uses") or []:
            if u in obj:
                out["core.dependency"].append({"id": nid(), "object_id": obj[p["key"]], "uses_object_id": obj[u], "uses_column_id": None})
    position = Counter()
    for p in by["relation"]:
        pr = p["props"]
        if pr.get("relispartition"):
            parent = pr["inherits"][0]
            position[parent] += 1
            out["core.partition"].append({"id": nid(), "object_id": obj[parent], "position": position[parent], "name": pr["relname"],
                                          "bounds": pr["partition_bound"], "table_id": obj[p["key"]], "comment": None})
    for p in by["column"]:
        pr = p["props"]
        i = col[p["key"]] = nid()
        gen = pr.get("attgenerated") or ""
        out["core.column"].append({
            "id": i, "object_id": obj[p["parent"]], "position": pr["attnum"], "name": pr["attname"], "type": pr["type"],
            "nullable": not pr["attnotnull"], "default_value": None if gen else pr.get("default"), "default_is_expression": True,
            "generated": pr.get("default") if gen else None, "generated_stored": {"s": True, "v": False}.get(gen),
            "identity": {"a": "always", "d": "by default"}.get(pr.get("attidentity") or ""), "collation_name": pr.get("collation"),
            "comment": pr.get("comment")})
        if not pr["attislocal"] or pr["attinhcount"] or pr.get("options") or pr.get("acl") or pr.get("statistics_target") is not None:
            out["engine_postgresql.column"].append({"id": i, "is_local": pr["attislocal"], "inherit_count": pr["attinhcount"],
                                                    "options": pr.get("options"), "acl": pr.get("acl"), "statistics_target": pr.get("statistics_target")})
    types = {}
    for p in by["type"]:
        pr = p["props"]
        i = obj[p["key"]] = types[p["key"]] = nid()
        out["core.object"].append({"id": i, "namespace_id": ns[p["parent"]], "parent_id": None, "kind": "type",
                                   "name": p["key"][len(p["parent"]) + 1:], "signature": "", "comment": pr.get("comment"), "body": None})
        out["engine_postgresql.type"].append({
            "id": i, "kind": "type", "type_kind": pr["typtype"], "labels": pr.get("labels"), "attributes": json.dumps(pr["fields"]) if pr.get("fields") else None,
            "base": pr.get("base"), "not_null": pr.get("notnull") or False, "default_value": pr.get("default"), "collation_name": pr.get("collation"),
            "range_subtype": pr.get("range_subtype"), "multirange": pr.get("multirange"), "owner": pr.get("owner"), "acl": pr.get("acl")})
    index_by_key = {}
    for p in by["index"]:
        pr = p["props"]
        table = p["parent"]
        i = index_by_key[p["key"]] = nid()
        idx_name = p["key"][len(home[table]) + 1:]
        out["core.index"].append({"id": i, "object_id": obj[table], "name": idx_name, "position": 0, "is_primary": pr["indisprimary"],
                                  "is_unique": pr["indisunique"], "method": pr["am"], "predicate": pr.get("predicate"), "comment": pr.get("comment")})
        out["engine_postgresql.index"].append({"id": i, "nulls_not_distinct": pr.get("indnullsnotdistinct") or False, "options": pr.get("options"),
                                               "replica_identity_index": pr.get("indisreplident") or False, "clustered": pr.get("indisclustered") or False,
                                               "parent_index_id": None, "__parent": pr.get("parent_index")})
        for part in pr["parts"] or []:
            pid = nid()
            out["core.index_part"].append({"id": pid, "index_id": i, "position": part["position"],
                                           "column_id": col.get(f"{table}.{part['column']}") if not part["expression"] else None,
                                           "expression": part["expression"], "descending": bool(part["descending"])})
            out["engine_postgresql.index_part"].append({"id": pid, "is_key": part["key"], "nulls_first": bool(part["nulls_first"]),
                                                        "operator_class": part["opclass"], "collation_name": part["collation"]})
    for r in out["engine_postgresql.index"]:
        r["parent_index_id"] = index_by_key.get(r.pop("__parent")) if r.get("__parent") else None
        r.pop("__parent", None)
    for i, x in enumerate(sorted(out["core.index"], key=lambda x: (x["object_id"], x["name"]))):
        x["position"] = i + 1
    for p in by["constraint"]:
        pr = p["props"]
        i = nid()
        parent = p["parent"]
        on_type = parent in types
        kind = {"p": "primary", "u": "unique", "f": "foreign", "c": "check", "x": "exclusion", "n": "not null"}.get(pr["contype"])
        if kind is None:
            continue
        ref = None
        if pr.get("ref_table"):
            ref = next(k for k in obj if qrel(*k.split(".", 1)) == pr["ref_table"] or f"{qi(k.split('.', 1)[0])}.{qi(k.split('.', 1)[1])}" == pr["ref_table"])
        idx = index_by_key.get(f"{home[parent]}.{pr['index']}") if pr.get("index") else None
        out["core.constraint"].append({
            "id": i, "object_id": obj[parent], "name": pr["conname"], "kind": kind, "in_database": True, "enforced": pr.get("conenforced", True),
            "is_deferrable": pr["condeferrable"], "is_deferred": pr["condeferred"], "expression": pr.get("expression"), "index_id": idx,
            "ref_object_id": obj.get(ref), "ref_namespace": None, "ref_object": None, "on_delete": pr.get("confdeltype"),
            "on_update": pr.get("confupdtype"), "match": pr.get("confmatchtype")})
        out["engine_postgresql.constraint"].append({"id": i, "validated": pr["convalidated"], "no_inherit": pr["connoinherit"],
                                                    "is_local": pr["conislocal"], "inherit_count": pr["coninhcount"], "operators": pr.get("operators"),
                                                    "delete_set_columns": [col[f"{parent}.{c}"] for c in pr["delete_set_columns"]]
                                                    if pr.get("delete_set_columns") else None})
        if not on_type:
            for k, c in enumerate(pr.get("columns") or []):
                out["core.constraint_column"].append({"id": nid(), "constraint_id": i, "position": k + 1, "column_id": col[f"{parent}.{c}"],
                                                      "ref_column_id": col[f"{ref}.{pr['ref_columns'][k]}"] if ref else None, "ref_column": None})
    for p in by["sequence"]:
        pr = p["props"]
        i = obj[p["key"]]
        owned = f"{p['parent']}.{pr['owned_by']}" if pr.get("owned_by") else None
        out["core.sequence"].append({"id": i, "kind": "sequence", "type": pr["type"], "start": pr["seqstart"], "increment": pr["seqincrement"],
                                     "minimum": pr["seqmin"], "maximum": pr["seqmax"], "cache": pr["seqcache"], "cycle": pr["seqcycle"],
                                     "owned_by": col.get(owned)})
        out["engine_postgresql.sequence"].append({"id": i, "identity": pr.get("identity") or False})
    for p in by["routine"]:
        pr = p["props"]
        if pr.get("made_by"):
            continue  # made by a type or an extension: it comes back with them
        i = obj[p["key"]] = nid()
        kind = {"f": "function", "p": "procedure"}[pr["prokind"]]
        out["core.object"].append({"id": i, "namespace_id": ns[p["parent"]], "parent_id": None, "kind": kind, "name": pr["proname"],
                                   "signature": p["key"][p["key"].index("("):], "comment": pr.get("comment"), "body": sql_body(pr) if pr.get("sql_body") else pr["prosrc"]})
        out["core.routine"].append({"id": i, "kind": kind, "returns": pr.get("returns") if kind == "function" else None, "language": pr["language"],
                                    "deterministic": pr["provolatile"] == "i", "security": "definer" if pr["prosecdef"] else "invoker"})
        out["engine_postgresql.routine"].append({"id": i, "volatility": pr["provolatile"], "parallel": pr["proparallel"], "strict": pr["proisstrict"],
                                                 "leakproof": pr["proleakproof"], "returns_set": pr["proretset"], "cost": pr.get("procost"),
                                                 "result_rows": pr.get("prorows"), "config": pr.get("proconfig"), "owner": pr.get("owner"), "acl": pr.get("acl")})
        names, modes, typ = pr.get("proargnames") or [], pr.get("proargmodes") or [], pr.get("argument_types") or []
        defaults = split_args(pr.get("argument_defaults"))
        inputs = [k for k in range(len(typ)) if (modes[k] if modes else "i") in ("i", "b", "v")]
        with_default = inputs[len(inputs) - len(defaults):] if defaults else []
        for k, t in enumerate(typ):
            pid = nid()
            out["core.parameter"].append({"id": pid, "object_id": i, "position": k + 1, "name": names[k] if k < len(names) and names[k] else None,
                                          "mode": {"i": "IN", "o": "OUT", "b": "INOUT", "v": "VARIADIC", "t": "TABLE"}[modes[k] if modes else "i"], "type": t})
            if k in with_default:
                out["engine_postgresql.parameter"].append({"id": pid, "default_value": defaults[with_default.index(k)]})
    for p in by["trigger"]:
        pr = p["props"]
        i = nid()
        t = pr["tgtype"]
        events = [e for bit, e in ((4, "INSERT"), (8, "DELETE"), (16, "UPDATE"), (32, "TRUNCATE")) if t & bit]
        out["core.object"].append({"id": i, "namespace_id": ns[home[p["parent"]]], "parent_id": obj[p["parent"]], "kind": "trigger",
                                   "name": pr["tgname"], "signature": "", "comment": None, "body": None})
        out["core.trigger"].append({"id": i, "kind": "trigger", "timing": "INSTEAD OF" if t & 64 else ("BEFORE" if t & 2 else "AFTER"),
                                    "events": events, "level": "row" if t & 1 else "statement"})
        out["engine_postgresql.trigger"].append({
            "id": i, "function_name": pr["function"], "arguments": pr.get("arguments"),
            "update_columns": [col[f"{p['parent']}.{c}"] for c in pr["update_columns"]] if pr.get("update_columns") else None,
            "condition": pr.get("condition"), "old_table": pr.get("tgoldtable"), "new_table": pr.get("tgnewtable"), "enabled": pr["tgenabled"],
            "is_deferrable": pr["tgdeferrable"], "initially_deferred": pr["tginitdeferred"],
            "constraint_trigger": pr.get("constraint_trigger", False), "from_table": pr.get("from_table")})
    for p in by["policy"]:
        pr = p["props"]
        out["engine_postgresql.policy"].append({"id": nid(), "object_id": obj[p["parent"]], "name": pr["policyname"],
                                                "permissive": pr["permissive"] == "PERMISSIVE", "command": pr["cmd"], "roles": pr["roles"],
                                                "using_expr": pr.get("qual"), "check_expr": pr.get("with_check")})
    for p in by["rule"]:
        pr = p["props"]
        out["engine_postgresql.rule"].append({"id": nid(), "object_id": obj[p["parent"]], "name": pr["rulename"], "definition": pr["definition"]})
    return out


def build(db, rows):
    C.psql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE); CREATE DATABASE {db};", "postgres")
    here = os.path.dirname(os.path.abspath(__file__))
    C.psql(open(os.path.join(here, "design", "store.sql")).read() + open(os.path.join(here, "design", "versioning.sql")).read()
           + "\nSELECT log.attach(); SELECT log.init('main');", db)
    t = time.time()
    C.psql("BEGIN; SELECT log.begin_turn('import');\n" + "".join(ST.copy_sql(k, rows[k]) for k in ORDER if rows.get(k))
           + "SELECT log.end_turn(); COMMIT;", db)
    return time.time() - t


def load_back(db):
    return {k: {r["id"]: r for r in json.loads(C.psql(f"SELECT coalesce(json_agg(to_jsonb(t)), '[]') FROM {k} t;", db))} for k in ORDER}


class Store:
    """The store's rows with the lookups the writer needs."""

    def __init__(self, st):
        self.st = st
        self.by = defaultdict(lambda: defaultdict(list))
        for k, key in (("core.column", "object_id"), ("core.index", "object_id"), ("core.index_part", "index_id"),
                       ("core.constraint", "object_id"), ("core.constraint_column", "constraint_id"), ("core.parameter", "object_id"),
                       ("core.partition", "object_id"), ("engine_postgresql.inheritance", "object_id"), ("core.dependency", "object_id")):
            for r in st[k].values():
                self.by[k][r[key]].append(r)
        self.ns = st["core.namespace"]
        self.objs = st["core.object"]

    def schema(self, o):
        return self.ns[o["namespace_id"]]["name"]

    def rel(self, o):
        return qrel(self.schema(o), o["name"])

    def full(self, o):
        return f"{qi(self.schema(o))}.{qi(o['name'])}"


def index_def(S, i):
    st = S.st
    o = S.objs[i["object_id"]]
    pi = st["engine_postgresql.index"].get(i["id"], {})
    cols = {c["id"]: c for c in S.by["core.column"][o["id"]]}
    keys, include = [], []
    for p in sorted(S.by["core.index_part"][i["id"]], key=lambda p: p["position"]):
        pp = st["engine_postgresql.index_part"].get(p["id"], {})
        if p["column_id"]:
            t = qi(cols[p["column_id"]]["name"])
        else:
            e = p["expression"]
            t = e if re.fullmatch(r"[\w.\"]+\(.*\)", e) and e.count("(") == e.count(")") else f"({e})"
        if not pp.get("is_key", True):
            include.append(t)
            continue
        t += (f" COLLATE {pp['collation_name']}" if pp.get("collation_name") else "") + (f" {pp['operator_class']}" if pp.get("operator_class") else "")
        if p["descending"]:
            t += " DESC" + ("" if pp.get("nulls_first") else " NULLS LAST")
        elif pp.get("nulls_first"):
            t += " NULLS FIRST"
        keys.append(t)
    only = "ONLY " if st["core.partitioning"].get(o["id"]) else ""
    out = f"CREATE {'UNIQUE ' if i['is_unique'] else ''}INDEX {qi(i['name'])} ON {only}{S.rel(o)} USING {i['method']} ({', '.join(keys)})"
    if include:
        out += f" INCLUDE ({', '.join(include)})"
    if pi.get("nulls_not_distinct"):
        out += " NULLS NOT DISTINCT"
    if pi.get("options"):
        out += " WITH (" + ", ".join(k + "=" + (v if qi(v) == v else "'" + v + "'") for k, _, v in (o.partition("=") for o in pi["options"])) + ")"
    if i["predicate"]:
        out += f" WHERE {i['predicate']}"
    return out


def constraint_def(S, c):
    st = S.st
    pc = st["engine_postgresql.constraint"].get(c["id"], {})
    cc = sorted(S.by["core.constraint_column"][c["id"]], key=lambda x: x["position"])
    allcols = st["core.column"]
    names = ", ".join(qi(allcols[x["column_id"]]["name"]) for x in cc)
    tail = ""
    if c["kind"] in ("primary", "unique", "exclusion") and c["index_id"]:
        idx = st["core.index"][c["index_id"]]
        inc = [qi(allcols[p["column_id"]]["name"]) for p in S.by["core.index_part"][idx["id"]]
               if not st["engine_postgresql.index_part"].get(p["id"], {}).get("is_key", True)]
        if inc:
            tail += f" INCLUDE ({', '.join(inc)})"
    if c["kind"] == "primary":
        out = f"PRIMARY KEY ({names}){tail}"
    elif c["kind"] == "unique":
        nnd = st["engine_postgresql.index"].get(c["index_id"], {}).get("nulls_not_distinct")
        out = f"UNIQUE {'NULLS NOT DISTINCT ' if nnd else ''}({names}){tail}"
    elif c["kind"] == "foreign":
        ref = S.objs[c["ref_object_id"]]
        out = f"FOREIGN KEY ({names}) REFERENCES {S.rel(ref)}({', '.join(qi(allcols[x['ref_column_id']]['name']) for x in cc)})"
        out += " MATCH FULL" if c["match"] == "f" else (" MATCH PARTIAL" if c["match"] == "p" else "")
        if ACTION.get(c["on_update"]):
            out += f" ON UPDATE {ACTION[c['on_update']]}"
        if ACTION.get(c["on_delete"]):
            out += f" ON DELETE {ACTION[c['on_delete']]}"
            only = st["engine_postgresql.constraint"].get(c["id"], {}).get("delete_set_columns")
            if only:
                out += " (" + ", ".join(qi(st["core.column"][x]["name"]) for x in only) + ")"
    elif c["kind"] == "check":
        out = f"CHECK ({c['expression']})" + (" NO INHERIT" if pc.get("no_inherit") else "")
    elif c["kind"] == "exclusion":
        idx = st["core.index"][c["index_id"]]
        cols = {x["id"]: x for x in allcols.values() if x["object_id"] == c["object_id"]}
        parts = [p for p in sorted(S.by["core.index_part"][idx["id"]], key=lambda p: p["position"])
                 if st["engine_postgresql.index_part"].get(p["id"], {}).get("is_key", True)]
        els = ", ".join(f"{qi(cols[p['column_id']]['name']) if p['column_id'] else '(' + p['expression'] + ')'} WITH {op}"
                        for p, op in zip(parts, pc["operators"]))
        out = f"EXCLUDE USING {idx['method']} ({els})" + (f" WHERE ({idx['predicate']})" if idx["predicate"] else "")
    else:
        out = "NOT NULL" + (f" {names}" if names else "") + (" NO INHERIT" if pc.get("no_inherit") else "")
    if c["is_deferrable"]:
        out += " DEFERRABLE"
    if c["is_deferred"]:
        out += " INITIALLY DEFERRED"
    if not c["enforced"]:
        out += " NOT ENFORCED"
    if not pc.get("validated", True):
        out += " NOT VALID"
    return out


def trigger_def(S, o):
    st = S.st
    t, pt = st["core.trigger"][o["id"]], st["engine_postgresql.trigger"][o["id"]]
    table = S.objs[o["parent_id"]]
    cols = st["core.column"]
    ev = []
    for e in t["events"]:
        if e == "UPDATE" and pt.get("update_columns"):
            e += " OF " + ", ".join(qi(cols[c]["name"]) for c in pt["update_columns"])
        ev.append(e)
    out = f"CREATE {'CONSTRAINT ' if pt.get('constraint_trigger') else ''}TRIGGER {qi(o['name'])} {t['timing']} {' OR '.join(ev)} ON {S.rel(table)}"
    if pt.get("constraint_trigger"):
        out += (f" FROM {pt['from_table']}" if pt.get("from_table") else "") + (" DEFERRABLE" if pt.get("is_deferrable") else " NOT DEFERRABLE") \
            + (" INITIALLY DEFERRED" if pt.get("initially_deferred") else " INITIALLY IMMEDIATE")
    if pt.get("old_table") or pt.get("new_table"):
        out += " REFERENCING" + (f" OLD TABLE AS {qi(pt['old_table'])}" if pt.get("old_table") else "") + (f" NEW TABLE AS {qi(pt['new_table'])}" if pt.get("new_table") else "")
    out += f" FOR EACH {t['level'].upper()}"
    if pt.get("condition"):
        out += f" WHEN ({pt['condition']})"
    args = ", ".join("'" + a.replace("'", "''") + "'" for a in pt.get("arguments") or [])
    fn = pt["function_name"]
    return out + f" EXECUTE FUNCTION {fn[len('public.'):] if fn.startswith('public.') else fn}({args})"


def function_def(S, o):
    st = S.st
    r, pr = st["core.routine"][o["id"]], st["engine_postgresql.routine"][o["id"]]
    args = []
    for p in sorted(S.by["core.parameter"][o["id"]], key=lambda p: p["position"]):
        if p["mode"] == "TABLE" or (p["mode"] == "OUT" and o["kind"] == "function"):
            continue
        d = st["engine_postgresql.parameter"].get(p["id"])
        # a procedure's every parameter is written with its mode (IN p integer); a function's IN is left out
        a = ("" if p["mode"] == "IN" and o["kind"] == "function" else p["mode"] + " ") + (qi(p["name"]) + " " if p["name"] else "") + p["type"]
        args.append(a + (f" DEFAULT {d['default_value']}" if d else ""))
    head = f"CREATE OR REPLACE {o['kind'].upper()} {S.full(o) if S.schema(o) != 'public' else qi(o['name'])}({', '.join(args)})\n"
    if o["kind"] == "function":
        head += f" RETURNS {r['returns']}\n"
    head += f" LANGUAGE {r['language']}\n"
    opts = ""
    opts += {"i": " IMMUTABLE", "s": " STABLE", "v": ""}[pr["volatility"]]
    opts += {"s": " PARALLEL SAFE", "r": " PARALLEL RESTRICTED", "u": ""}[pr["parallel"]]
    opts += " STRICT" if pr["strict"] else ""
    opts += " SECURITY DEFINER" if r["security"] == "definer" else ""
    opts += " LEAKPROOF" if pr["leakproof"] else ""
    default_cost = 1 if r["language"] in ("internal", "c") else 100
    if pr.get("cost") is not None and pr["cost"] != default_cost:
        opts += f" COST {pr['cost']:g}"
    if pr.get("result_rows") and pr["result_rows"] not in (0, 1000):
        opts += f" ROWS {pr['result_rows']:g}"
    if opts:
        head += opts + "\n"
    for c in pr.get("config") or []:
        k, _, v = c.partition("=")
        head += f" SET {k} TO '{v}'\n"
    if o["body"].startswith(("RETURN ", "BEGIN ATOMIC")):   # a SQL-standard body: no string, no AS
        return head + o["body"] + "\n"
    tag = "$function$" if o["kind"] == "function" else "$procedure$"
    return head + f"AS {tag}{o['body']}{tag}\n"


def sql_body(pr):
    """A SQL-standard body (RETURN ..., BEGIN ATOMIC ... END), as pg_get_functiondef writes it: prosrc holds nothing of it."""
    text = pr["create"]
    i = min(k for k in (text.find("\nRETURN "), text.find("\nBEGIN ATOMIC")) if k >= 0)
    return text[i + 1:].rstrip("\n")


def lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def grants(what, acl, owner):
    out = [f"REVOKE ALL ON {what} FROM PUBLIC;", f"REVOKE ALL ON {what} FROM {qi(owner)};"]
    privs = {"r": "SELECT", "a": "INSERT", "w": "UPDATE", "d": "DELETE", "D": "TRUNCATE", "x": "REFERENCES", "t": "TRIGGER",
             "m": "MAINTAIN", "U": "USAGE", "C": "CREATE", "X": "EXECUTE", "T": "TEMPORARY", "c": "CONNECT"}
    for item in acl or []:
        grantee, _, rest = item.partition("=")
        letters = rest.partition("/")[0]
        plain = [privs[ch] for k, ch in enumerate(letters) if ch != "*" and (k + 1 >= len(letters) or letters[k + 1] != "*")]
        opted = [privs[ch] for k, ch in enumerate(letters) if ch != "*" and k + 1 < len(letters) and letters[k + 1] == "*"]
        who = "PUBLIC" if grantee == "" else qi(grantee)
        if plain:
            out.append(f"GRANT {', '.join(plain)} ON {what} TO {who};")
        if opted:
            out.append(f"GRANT {', '.join(opted)} ON {what} TO {who} WITH GRANT OPTION;")
    return out


def script(st):
    """The whole schema as SQL, written from the store."""
    S = Store(st)
    objs = S.objs
    owner_default = "postgres"
    sql = ["SET check_function_bodies = off;", "SET client_min_messages = warning;"]
    roles = set()
    for k in ("engine_postgresql.namespace", "engine_postgresql.relation", "engine_postgresql.routine", "engine_postgresql.type"):
        for r in st[k].values():
            roles.add(r.get("owner") or owner_default)
            roles |= {a.partition("=")[0] for a in r.get("acl") or []}
    for p in st["engine_postgresql.policy"].values():
        roles |= set(p["roles"])
    defs = st.get("engine_postgresql.role_def") or {}
    if defs:   # the design's roles, with what each may do; one the server has already (postgres) is left as it is
        for r in defs.values():
            attrs = " ".join(("" if r.get(k) else "NO") + k.upper() for k in ("login", "superuser", "createdb", "createrole", "inherit", "replication", "bypassrls"))
            attrs += f" CONNECTION LIMIT {r['connection_limit']}" if r.get("connection_limit", -1) != -1 else ""
            attrs += f" VALID UNTIL {lit(r['valid_until'])}" if r.get("valid_until") else ""
            sql.append(f"DO $$ BEGIN CREATE ROLE {qi(r['name'])} {attrs}; EXCEPTION WHEN duplicate_object THEN NULL; END $$;")
            if r.get("comment"):
                sql.append(f"COMMENT ON ROLE {qi(r['name'])} IS {lit(r['comment'])};")
        for m in (st.get("engine_postgresql.membership") or {}).values():
            opts = [o for o, on in (("ADMIN OPTION", m["admin_option"]),) if on]
            if "inherit_option" in m:
                opts = [f"ADMIN {str(m['admin_option']).upper()}", f"INHERIT {str(m['inherit_option']).upper()}", f"SET {str(m['set_option']).upper()}"]
                sql.append(f"GRANT {qi(m['role'])} TO {qi(m['member'])} WITH {', '.join(opts)};")
            else:
                sql.append(f"GRANT {qi(m['role'])} TO {qi(m['member'])}{' WITH ADMIN OPTION' if m['admin_option'] else ''};")
    else:
        for r in sorted(roles - {"", "public", owner_default}):
            sql.append(f"DO $$ BEGIN CREATE ROLE {qi(r)} NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;")
    schemas = [n for n in S.ns.values() if n["parent_id"]]
    for n in sorted(schemas, key=lambda n: n["name"]):
        pn = st["engine_postgresql.namespace"].get(n["id"], {})
        sql.append(f"CREATE SCHEMA {qi(n['name'])} AUTHORIZATION {qi(pn.get('owner') or owner_default)};")
        if n.get("comment"):
            sql.append(f"COMMENT ON SCHEMA {qi(n['name'])} IS {lit(n['comment'])};")
        if pn.get("acl"):
            sql += grants(f"SCHEMA {qi(n['name'])}", pn["acl"], pn.get("owner") or owner_default)
    defaults = list((st.get("engine_postgresql.default_acl") or {}).values())
    # a role's defaults for every schema replace PostgreSQL's own (PUBLIC may execute a function, use a type): they are
    # written whole, everything revoked and then what they give; a schema's own defaults only add, and are granted alone
    for role, otype in sorted({(d["role"], d["object_type"]) for d in defaults if not d["schema"]}):
        sql.append(f"ALTER DEFAULT PRIVILEGES FOR ROLE {qi(role)} REVOKE ALL ON {otype.replace('_', ' ').upper()} FROM PUBLIC, {qi(role)};")
    for d in defaults:
        sql.append(f"ALTER DEFAULT PRIVILEGES FOR ROLE {qi(d['role'])}" + (f" IN SCHEMA {qi(d['schema'])}" if d["schema"] else "")
                   + f" GRANT {d['privilege']} ON {d['object_type'].replace('_', ' ').upper()} TO {'PUBLIC' if d['grantee'] == 'PUBLIC' else qi(d['grantee'])}"
                   + (" WITH GRANT OPTION;" if d["grantable"] else ";"))
    for e in st["engine_postgresql.extension"].values():
        sql.append(f"CREATE EXTENSION IF NOT EXISTS {qi(e['name'])} WITH SCHEMA {qi(e['schema_name'])} VERSION {lit(e['version'])};")
    for c in st["engine_postgresql.collation"].values():
        how = f"locale = {lit(c['locale'])}" if c["provider"] != "libc" else f"lc_collate = {lit(c['lc_collate'])}, lc_ctype = {lit(c['lc_ctype'])}"
        sql.append(f"CREATE COLLATION {qi(S.ns[c['namespace_id']]['name'])}.{qi(c['name'])} (provider = {c['provider']}, {how}, "
                   f"deterministic = {str(c['deterministic']).lower()});")
    types = sorted((o for o in objs.values() if o["kind"] == "type"), key=lambda o: ("erdc".index(st["engine_postgresql.type"][o["id"]]["type_kind"]), o["id"]))
    for o in types:
        t = st["engine_postgresql.type"][o["id"]]
        name = S.full(o)
        if t["type_kind"] == "e":
            sql.append(f"CREATE TYPE {name} AS ENUM ({', '.join(lit(x) for x in t['labels'] or [])});")
        elif t["type_kind"] == "r":
            sql.append(f"CREATE TYPE {name} AS RANGE (subtype = {t['range_subtype']}, multirange_type_name = {t['multirange']});")
        elif t["type_kind"] == "c":
            attrs = t["attributes"] if isinstance(t["attributes"], list) else json.loads(t["attributes"] or "[]")
            sql.append(f"CREATE TYPE {name} AS ({', '.join(qi(a['name']) + ' ' + a['type'] for a in attrs)});")
        else:
            sql.append(f"CREATE DOMAIN {name} AS {t['base']}" + (f" COLLATE {t['collation_name']}" if t.get("collation_name") else "")
                       + (f" DEFAULT {t['default_value']}" if t.get("default_value") else "") + (" NOT NULL" if t["not_null"] else "") + ";")
            for c in S.by["core.constraint"][o["id"]]:
                if c["kind"] == "check":
                    sql.append(f"ALTER DOMAIN {name} ADD CONSTRAINT {qi(c['name'])} {constraint_def(S, c)};")
        if o.get("comment"):
            sql.append(f"COMMENT ON TYPE {name} IS {lit(o['comment'])};")
    seqs = st["core.sequence"]

    def seq_options(s, with_type=True):
        return ((f"AS {s['type']} " if with_type else "") + f"START WITH {s['start']} INCREMENT BY {s['increment']} MINVALUE {s['minimum']} "
                f"MAXVALUE {s['maximum']} CACHE {s['cache']} {'CYCLE' if s['cycle'] else 'NO CYCLE'}")
    for sid, s in seqs.items():
        if not st["engine_postgresql.sequence"][sid]["identity"]:
            sql.append(f"CREATE SEQUENCE {S.full(objs[sid])} {seq_options(s)};")
    for o in sorted((o for o in objs.values() if o["kind"] in ("function", "procedure")), key=lambda o: o["id"]):
        sql.append(function_def(S, o).rstrip() + ";")
    tables = [o for o in objs.values() if o["kind"] == "table"]
    parents = {o["id"]: [i["parent_id"] for i in sorted(S.by["engine_postgresql.inheritance"][o["id"]], key=lambda i: i["position"])] for o in tables}
    partition_of = {p["table_id"]: p for ps in S.by["core.partition"].values() for p in ps}
    for o in tables:
        if o["id"] in partition_of:
            parents[o["id"]] = [partition_of[o["id"]]["object_id"]]
    done, ordered = set(), []
    while len(ordered) < len(tables):
        for o in tables:
            if o["id"] not in done and all(p in done for p in parents[o["id"]]):
                done.add(o["id"])
                ordered.append(o)
    stats = []   # a column's statistics target, set once every table is made
    for o in ordered:
        r = st["engine_postgresql.relation"][o["id"]]
        unlogged = "UNLOGGED " if r["persistence"] == "u" else ""
        pg = st["core.partitioning"].get(o["id"])
        tail = (f" PARTITION BY {pg['strategy']} ({pg['expression']})" if pg else "") + (f" WITH ({', '.join(r['options'])})" if r.get("options") else "")
        tail += f" TABLESPACE {qi(r['tablespace'])}" if r.get("tablespace") else ""
        if o["id"] in partition_of:
            p = partition_of[o["id"]]
            sql.append(f"CREATE {unlogged}TABLE {S.full(o)} PARTITION OF {S.full(objs[p['object_id']])} {p['bounds']}{tail};")
            continue
        defs = []
        for c in sorted(S.by["core.column"][o["id"]], key=lambda c: c["position"]):
            pc = st["engine_postgresql.column"].get(c["id"], {})
            if not pc.get("is_local", True):
                continue
            d = f"{qi(c['name'])} {c['type']}" + (f" COLLATE {c['collation_name']}" if c.get("collation_name") else "")
            if c["generated"]:
                d += f" GENERATED ALWAYS AS ({c['generated']}) {'STORED' if c['generated_stored'] else 'VIRTUAL'}"
            elif c["default_value"]:
                d += f" DEFAULT {c['default_value']}"
            if not c["nullable"]:
                d += " NOT NULL"
            if c["identity"]:
                sid = next(k for k, s in seqs.items() if s["owned_by"] == c["id"] and st["engine_postgresql.sequence"][k]["identity"])
                d += (f" GENERATED {c['identity'].upper()} AS IDENTITY (SEQUENCE NAME {S.full(objs[sid])} {seq_options(seqs[sid], False)})")
            defs.append(d)
        inh = [S.full(objs[p]) for p in parents[o["id"]]]
        if r.get("of_type"):   # a typed table: its columns are its type's; only what it adds to them is written
            adds = [f"{qi(c['name'])} NOT NULL" for c in sorted(S.by["core.column"][o["id"]], key=lambda c: c["position"]) if not c["nullable"]]
            sql.append(f"CREATE {unlogged}TABLE {S.full(o)} OF {r['of_type']}" + (f" ({', '.join(adds)})" if adds else "") + tail + ";")
        else:
            sql.append(f"CREATE {unlogged}TABLE {S.full(o)} ({', '.join(defs)})" + (f" INHERITS ({', '.join(inh)})" if inh else "") + tail + ";")
        for c in sorted(S.by["core.column"][o["id"]], key=lambda c: c["position"]):
            target = st["engine_postgresql.column"].get(c["id"], {}).get("statistics_target")
            if target is not None:
                stats.append(f"ALTER TABLE ONLY {S.full(o)} ALTER COLUMN {qi(c['name'])} SET STATISTICS {target};")
    cons = [c for c in st["core.constraint"].values() if objs[c["object_id"]]["kind"] == "table" and c["kind"] != "not null"
            and st["engine_postgresql.constraint"][c["id"]]["is_local"]]
    for c in sorted(cons, key=lambda c: ("primary unique exclusion check foreign".split().index(c["kind"]), c["id"])):
        sql.append(f"ALTER TABLE {S.full(objs[c['object_id']])} ADD CONSTRAINT {qi(c['name'])} {constraint_def(S, c)};")
    views = [o for o in objs.values() if o["kind"] in ("view", "materialized view")]
    placed, vorder = set(), []
    while len(vorder) < len(views):
        for v in views:
            uses = [d["uses_object_id"] for d in S.by["core.dependency"][v["id"]]]
            if v["id"] not in placed and all(u in placed or objs[u]["kind"] not in ("view", "materialized view") for u in uses):
                placed.add(v["id"])
                vorder.append(v)
    for v in vorder:
        r = st["engine_postgresql.relation"][v["id"]]
        opts = f" WITH ({', '.join(r['options'])})" if r.get("options") else ""
        body = v["body"].rstrip().rstrip(";")
        if v["kind"] == "view":
            sql.append(f"CREATE VIEW {S.full(v)}{opts} AS {body};")
        else:
            sql.append(f"CREATE MATERIALIZED VIEW {S.full(v)}{opts} AS {body} WITH {'' if r['populated'] else 'NO '}DATA;")
    constraint_index = {c["index_id"] for c in st["core.constraint"].values() if c["index_id"]}
    for i in st["core.index"].values():
        if i["id"] not in constraint_index and not st["engine_postgresql.index"].get(i["id"], {}).get("parent_index_id"):
            sql.append(index_def(S, i).replace(" ON ONLY ", " ON ") + ";")
    for o in tables:
        r = st["engine_postgresql.relation"][o["id"]]
        if r["row_security"]:
            sql.append(f"ALTER TABLE {S.full(o)} ENABLE ROW LEVEL SECURITY;")
        if r["force_row_security"]:
            sql.append(f"ALTER TABLE {S.full(o)} FORCE ROW LEVEL SECURITY;")
    for p in st["engine_postgresql.policy"].values():
        roles = ", ".join("PUBLIC" if r == "public" else qi(r) for r in p["roles"])
        sql.append(f"CREATE POLICY {qi(p['name'])} ON {S.full(objs[p['object_id']])} AS {'PERMISSIVE' if p['permissive'] else 'RESTRICTIVE'} "
                   f"FOR {p['command']} TO {roles}" + (f" USING ({p['using_expr']})" if p.get("using_expr") else "")
                   + (f" WITH CHECK ({p['check_expr']})" if p.get("check_expr") else "") + ";")
    for o in (o for o in objs.values() if o["kind"] == "trigger"):
        sql.append(trigger_def(S, o) + ";")
        state = {"D": "DISABLE", "R": "ENABLE REPLICA", "A": "ENABLE ALWAYS"}.get(st["engine_postgresql.trigger"][o["id"]]["enabled"])
        if state:
            sql.append(f"ALTER TABLE {S.full(objs[o['parent_id']])} {state} TRIGGER {qi(o['name'])};")
    for r in st["engine_postgresql.rule"].values():
        sql.append(r["definition"].rstrip().rstrip(";") + ";")
    # what identifies a table's rows to logical replication, and the index it was clustered on
    for i in st["core.index"].values():
        pi = st["engine_postgresql.index"].get(i["id"], {})
        table = S.full(objs[i["object_id"]])
        if pi.get("replica_identity_index"):
            sql.append(f"ALTER TABLE {table} REPLICA IDENTITY USING INDEX {qi(i['name'])};")
        if pi.get("clustered"):
            sql.append(f"ALTER TABLE {table} CLUSTER ON {qi(i['name'])};")
    for o in objs.values():
        r = st["engine_postgresql.relation"].get(o["id"], {})
        if o["kind"] == "table" and r.get("replica_identity") in ("f", "n"):  # a view's or a sequence's is always nothing
            sql.append(f"ALTER TABLE {S.full(o)} REPLICA IDENTITY {'FULL' if r['replica_identity'] == 'f' else 'NOTHING'};")
    for sid, s in seqs.items():
        if not st["engine_postgresql.sequence"][sid]["identity"] and s["owned_by"]:
            c = st["core.column"][s["owned_by"]]
            sql.append(f"ALTER SEQUENCE {S.full(objs[sid])} OWNED BY {S.full(objs[c['object_id']])}.{qi(c['name'])};")
    kinds = {"table": "TABLE", "view": "VIEW", "materialized view": "MATERIALIZED VIEW", "sequence": "SEQUENCE"}
    for o in objs.values():
        if o["kind"] not in kinds:
            continue
        r = st["engine_postgresql.relation"][o["id"]]
        what = f"{kinds[o['kind']]} {S.full(o)}"
        if o.get("comment"):
            sql.append(f"COMMENT ON {what} IS {lit(o['comment'])};")
        if (r.get("owner") or owner_default) != owner_default:
            sql.append(f"ALTER {what} OWNER TO {qi(r['owner'])};")
        if r.get("acl"):
            sql += grants(f"{'SEQUENCE' if o['kind'] == 'sequence' else 'TABLE'} {S.full(o)}", r["acl"], r.get("owner") or owner_default)
    for c in st["core.column"].values():
        if c.get("comment"):
            sql.append(f"COMMENT ON COLUMN {S.full(objs[c['object_id']])}.{qi(c['name'])} IS {lit(c['comment'])};")
    for c in cons:
        if c.get("comment"):
            sql.append(f"COMMENT ON CONSTRAINT {qi(c['name'])} ON {S.full(objs[c['object_id']])} IS {lit(c['comment'])};")
    for i in st["core.index"].values():
        if i.get("comment"):
            sql.append(f"COMMENT ON INDEX {qi(S.schema(objs[i['object_id']]))}.{qi(i['name'])} IS {lit(i['comment'])};")
    for o in (o for o in objs.values() if o["kind"] in ("function", "procedure")):
        pr = st["engine_postgresql.routine"][o["id"]]
        sig = f"{S.full(o)}{o['signature']}"
        if o.get("comment"):
            sql.append(f"COMMENT ON {o['kind'].upper()} {sig} IS {lit(o['comment'])};")
        if (pr.get("owner") or owner_default) != owner_default:
            sql.append(f"ALTER {o['kind'].upper()} {sig} OWNER TO {qi(pr['owner'])};")
        if pr.get("acl"):
            sql += grants(f"{o['kind'].upper()} {sig}", pr["acl"], pr.get("owner") or owner_default)
    sql += stats
    return "\n".join(sql) + "\n"


def main():
    roundtrip = "--roundtrip" in sys.argv
    for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
        snap = json.load(open(path))
        version = snap["version"]
        rows = rows_of(snap)
        db = f"lab_store_postgresql_{version}"
        t_load = build(db, rows)
        S = Store(load_back(db))
        n, exact, first = Counter(), Counter(), {}
        names = {(S.schema(S.objs[i["object_id"]]), i["name"]): i for i in S.st["core.index"].values()}
        home = {p["key"]: p["parent"] for p in snap["parts"] if p["kind"] == "relation"}
        for p in snap["parts"]:
            pr = p["props"]
            if p["kind"] == "index":
                schema = home[p["parent"]]
                got, want = index_def(S, names[(schema, p["key"][len(schema) + 1:])]), pr["definition"]
            elif p["kind"] == "constraint" and pr["contype"] in "pufcxn":
                c = next(c for c in S.st["core.constraint"].values() if c["name"] == pr["conname"]
                         and f"{S.schema(S.objs[c['object_id']])}.{S.objs[c['object_id']]['name']}" == p["parent"])
                got, want = constraint_def(S, c), pr["definition"]
            elif p["kind"] == "trigger":
                o = next(o for o in S.objs.values() if o["kind"] == "trigger" and o["name"] == pr["tgname"]
                         and f"{S.schema(S.objs[o['parent_id']])}.{S.objs[o['parent_id']]['name']}" == p["parent"])
                got, want = trigger_def(S, o), pr["definition"]
            elif p["kind"] == "routine" and not pr.get("made_by"):
                o = next(o for o in S.objs.values() if o["kind"] in ("function", "procedure") and o["name"] == pr["proname"]
                         and S.schema(o) == p["parent"] and o["signature"] == p["key"][p["key"].index("("):])
                got, want = function_def(S, o), pr["create"]
            else:
                continue
            n[p["kind"]] += 1
            if got == want:
                exact[p["kind"]] += 1
            else:
                first.setdefault(p["kind"], (want, got))
        print(f"{'pass' if exact == n else 'FAIL'}  postgresql {version}: {sum(len(v) for v in rows.values())} rows, loaded with versioning in "
              f"{t_load:.1f}s; written from facts: " + ", ".join(f"{exact[k]}/{n[k]} {k}s" for k in sorted(n)))
        for k, (w, g) in first.items():
            print(f"      {k}: want {w!r}\n      {' ' * len(k)}  got  {g!r}")
        if roundtrip:
            name = C.fresh_pg(version)
            try:
                C.ready_pg(name)
                sql = script(S.st)
                r = subprocess.run(["docker", "exec", "-i", name, "psql", "-U", "postgres", "-d", C.SOURCE_DB, "-q"], input=sql, capture_output=True, text=True)
                refused = [l for l in r.stderr.splitlines() if "ERROR:" in l]
                saved, X.SCHEMAS = X.SCHEMAS, tuple(n["name"] for n in S.ns.values() if n["parent_id"])
                again = X.extract_pg(version, name)
                X.SCHEMAS = saved
                diffs, m = C.compare(snap["parts"], again)
                ok = not refused and not diffs
                print(f"      {'pass' if ok else 'FAIL'}  round trip: {len(sql) // 1024} KB of SQL from the store, {len(refused)} refused, "
                      f"{m} parts compared, {sum(diffs.values())} properties differ")
                for e in refused[:5]:
                    print(f"            refused: {e[:160]}")
                for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:10]:
                    print(f"            differs: {k} in {c} parts")
            finally:
                C.S.remove(name)


if __name__ == "__main__":
    main()
