"""The lab's PostgreSQL round trip: every schema written back as SQL from the store alone (the global schema and the
PostgreSQL plugin's, as lab/scale.py --postgresql left them), loaded into a fresh server of the same version, read
again, and compared with what the original server gave, part by part and property by property.

PostgreSQL has no SHOW CREATE: the writer makes each statement from the catalog's facts, and uses the server's own
rendering (pg_get_indexdef, pg_get_constraintdef, pg_get_viewdef, pg_get_functiondef, pg_get_triggerdef) where the
store holds it.

  LAB_SCHEMAS=a,b LAB_OUT=~/private/out python3 lab/roundtrip_pg.py      after lab/scale.py --postgresql
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract as X  # noqa: E402
import roundtrip as R  # noqa: E402
import setup as S  # noqa: E402
import versioning_test as V  # noqa: E402

SUPER = "postgres"
PRIVS = {"r": "SELECT", "a": "INSERT", "w": "UPDATE", "d": "DELETE", "D": "TRUNCATE", "x": "REFERENCES", "t": "TRIGGER",
         "m": "MAINTAIN", "U": "USAGE", "C": "CREATE", "X": "EXECUTE", "T": "TEMPORARY", "c": "CONNECT"}


def q(n):
    return '"' + n.replace('"', '""') + '"'


def lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def listed(v):
    """A shared attribute the store keeps as text: a list written as JSON comes back a list."""
    if isinstance(v, str) and v.startswith("["):
        return json.loads(v)
    return v


def from_store(db):
    out = {}
    for c in ("namespace", "object", "column", "index", "constraint"):
        sql = (f"SELECT coalesce(json_agg(to_jsonb(t) || coalesce(to_jsonb(o) - 'id', '{{}}')), '[]') FROM core.{c} t "
               f"LEFT JOIN engine_postgresql.{c}_options o ON o.id = t.id;")
        try:
            out[c] = json.loads(V.psql(sql, db))
        except SystemExit:  # a concept without a plugin table
            out[c] = json.loads(V.psql(f"SELECT coalesce(json_agg(to_jsonb(t)), '[]') FROM core.{c} t;", db))
    return out


def grants(what, acl, owner):
    """REVOKE what the object starts with, then GRANT what its acl holds."""
    out = [f"REVOKE ALL ON {what} FROM PUBLIC;", f"REVOKE ALL ON {what} FROM {q(owner)};"]
    for item in listed(acl) or []:
        grantee, _, rest = item.partition("=")
        privs, _, _grantor = rest.partition("/")
        plain = [PRIVS[c] for i, c in enumerate(privs) if c != "*" and (i + 1 >= len(privs) or privs[i + 1] != "*")]
        opted = [PRIVS[c] for i, c in enumerate(privs) if c != "*" and i + 1 < len(privs) and privs[i + 1] == "*"]
        who = "PUBLIC" if grantee == "" else q(grantee)
        if plain:
            out.append(f"GRANT {', '.join(plain)} ON {what} TO {who};")
        if opted:
            out.append(f"GRANT {', '.join(opted)} ON {what} TO {who} WITH GRANT OPTION;")
    return out


def script(store):
    objs = store["object"]
    by_id = {o["id"]: o for o in objs}
    rel = {o["id"]: o for o in objs if o["kind"] == "relation"}
    name = lambda o: f"{q(o['parent'])}.{q(o['name'])}"
    sql = ["SET check_function_bodies = off;", "SET client_min_messages = warning;"]

    # roles the schema names: they belong to the server, so the writer only makes the ones that are missing
    roles = set()
    for o in objs + store["namespace"]:
        if o.get("owner"):
            roles.add(o["owner"])
        for item in listed(o.get("acl")) or []:
            roles.add(item.partition("=")[0])
        for r in listed(o.get("roles")) or []:
            roles.add(r)
    for r in sorted(roles - {"", "public", SUPER}):
        sql.append(f"DO $$ BEGIN CREATE ROLE {q(r)} NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;")

    for n in sorted(store["namespace"], key=lambda n: n["name"]):
        sql.append(f"CREATE SCHEMA {q(n['name'])} AUTHORIZATION {q(n.get('owner') or SUPER)};")
        if n.get("comment"):
            sql.append(f"COMMENT ON SCHEMA {q(n['name'])} IS {lit(n['comment'])};")
        if n.get("acl"):
            sql += grants(f"SCHEMA {q(n['name'])}", n["acl"], n.get("owner") or SUPER)
    for e in sorted((o for o in objs if o["kind"] == "extension"), key=lambda o: o["id"]):
        sql.append(f"CREATE EXTENSION IF NOT EXISTS {q(e['id'])} WITH SCHEMA {q(e['schema'])} VERSION {lit(e['version'])};")
    for c in (o for o in objs if o["kind"] == "collation"):
        prov = {"i": "icu", "c": "libc", "b": "builtin"}[c["collprovider"]]
        loc = c.get("colllocale") or c.get("colliculocale")
        how = f"locale = {lit(loc)}" if prov != "libc" else f"lc_collate = {lit(c['collcollate'])}, lc_ctype = {lit(c['collctype'])}"
        sql.append(f"CREATE COLLATION {name(c)} (provider = {prov}, {how}, deterministic = {str(c['collisdeterministic']).lower()});")

    # types: enums and ranges first, then composites and domains, which may use them
    types = [o for o in objs if o["kind"] == "type"]
    tname = lambda t: ".".join(q(x) for x in (t["parent"], t["id"][len(t["parent"]) + 1:]))
    domain_constraints = [c for c in store["constraint"] if c["parent"] in by_id and by_id[c["parent"]]["kind"] == "type"]
    for t in sorted(types, key=lambda t: ("erdc".index(t["typtype"]), t["id"])):
        if t["typtype"] == "e":
            sql.append(f"CREATE TYPE {tname(t)} AS ENUM ({', '.join(lit(x) for x in t.get('labels') or [])});")
        elif t["typtype"] == "r":
            sql.append(f"CREATE TYPE {tname(t)} AS RANGE (subtype = {t['range_subtype']}, multirange_type_name = {t['multirange']});")
        elif t["typtype"] == "c":
            sql.append(f"CREATE TYPE {tname(t)} AS ({', '.join(q(f['name']) + ' ' + f['type'] for f in t.get('fields') or [])});")
        else:
            sql.append(f"CREATE DOMAIN {tname(t)} AS {t['base']}" + (f" COLLATE {t['collation']}" if t.get("collation") else "")
                       + (f" DEFAULT {t['default']}" if t.get("default") else "") + (" NOT NULL" if t.get("notnull") else "") + ";")
            for c in domain_constraints:
                if c["parent"] == t["id"] and c["type"] == "c":
                    sql.append(f"ALTER DOMAIN {tname(t)} ADD CONSTRAINT {q(c['name'])} {c['definition']};")
        if t.get("comment"):
            sql.append(f"COMMENT ON TYPE {tname(t)} IS {lit(t['comment'])};")

    seqs = {o["id"].removeprefix("sequence:"): o for o in objs if o["kind"] == "sequence"}

    def seq_options(s):
        return (f"AS {s['type']} START WITH {s['seqstart']} INCREMENT BY {s['seqincrement']} MINVALUE {s['seqmin']} "
                f"MAXVALUE {s['seqmax']} CACHE {s['seqcache']} {'CYCLE' if s['seqcycle'] else 'NO CYCLE'}")
    for sid, s in sorted(seqs.items()):
        if not s.get("identity"):
            sql.append(f"CREATE SEQUENCE {name(rel[sid])} {seq_options(s)};")

    for r in sorted((o for o in objs if o["kind"] == "routine" and not o.get("made_by")), key=lambda o: o["id"]):
        sql.append(r["create"].rstrip() + ";")

    # tables: a parent before its partitions and children
    tables = [o for o in rel.values() if o["relkind"] in ("r", "p")]
    done, ordered = set(), []
    while len(ordered) < len(tables):
        for t in tables:
            if t["id"] not in done and all(p in done for p in listed(t.get("inherits")) or []):
                done.add(t["id"])
                ordered.append(t)
    cols = {}
    for c in store["column"]:
        cols.setdefault(c["parent"], []).append(c)
    for t in ordered:
        unlogged = "UNLOGGED " if t.get("relpersistence") == "u" else ""
        options = listed(t.get("check_option"))
        tail = (f" PARTITION BY {t['partition_key']}" if t.get("partition_key") else "") + \
               (f" WITH ({', '.join(options)})" if options else "")
        if t.get("relispartition"):
            parent = rel[listed(t["inherits"])[0]]
            sql.append(f"CREATE {unlogged}TABLE {name(t)} PARTITION OF {name(parent)} {t['partition_bound']}{tail};")
            continue
        defs = []
        for c in sorted(cols.get(t["id"], []), key=lambda c: int(c["position"])):
            if not c.get("attislocal", True):
                continue
            d = f"{q(c['name'])} {c['type']}" + (f" COLLATE {c['collation']}" if c.get("collation") else "")
            if c.get("generated") == "s":
                d += f" GENERATED ALWAYS AS ({c['default']}) STORED"
            elif c.get("generated") == "v":
                d += f" GENERATED ALWAYS AS ({c['default']}) VIRTUAL"
            elif c.get("default"):
                d += f" DEFAULT {c['default']}"
            if c.get("nullable") == "true":
                d += " NOT NULL"
            if c.get("identity") in ("a", "d"):
                sid = next(k for k, s in seqs.items() if s.get("identity") and rel[k]["parent"] == t["parent"]
                           and s["owned_by"] == f"{t['name']}.{c['name']}")
                d += (f" GENERATED {'ALWAYS' if c['identity'] == 'a' else 'BY DEFAULT'} AS IDENTITY "
                      f"(SEQUENCE NAME {name(rel[sid])} {seq_options(seqs[sid]).replace('AS ' + seqs[sid]['type'] + ' ', '')})")
            defs.append(d)
        inherits = listed(t.get("inherits"))
        sql.append(f"CREATE {unlogged}TABLE {name(t)} ({', '.join(defs)})"
                   + (f" INHERITS ({', '.join(name(rel[p]) for p in inherits)})" if inherits else "") + tail + ";")

    cons = [c for c in store["constraint"] if c["parent"] in rel and c.get("conislocal", True) and c["type"] in "puxcf"]
    for c in sorted(cons, key=lambda c: ("puxcf".index(c["type"]), c["id"])):
        sql.append(f"ALTER TABLE {name(rel[c['parent']])} ADD CONSTRAINT {q(c['name'])} {c['definition']};")

    views = [o for o in rel.values() if o["relkind"] in ("v", "m")]
    placed, vorder = set(), []
    while len(vorder) < len(views):
        moved = False
        for v in views:
            if v["id"] in placed:
                continue
            uses = [w for w in views if w is not v and w["id"] not in placed
                    and re.search(rf"(?<![\w\"]){re.escape(w['name'])}(?![\w\"])|{re.escape(q(w['name']))}", v["definition"] or "")]
            if not uses:
                placed.add(v["id"])
                vorder.append(v)
                moved = True
        if not moved:
            vorder += [v for v in views if v["id"] not in placed]
            break
    for v in vorder:
        opts = listed(v.get("check_option"))
        if v["relkind"] == "v":
            sql.append(f"CREATE VIEW {name(v)}" + (f" WITH ({', '.join(opts)})" if opts else "") + f" AS {v['definition'].rstrip().rstrip(';')};")
        else:
            sql.append(f"CREATE MATERIALIZED VIEW {name(v)}" + (f" WITH ({', '.join(opts)})" if opts else "")
                       + f" AS {v['definition'].rstrip().rstrip(';')} WITH {'' if v.get('relispopulated') else 'NO '}DATA;")

    for i in store["index"]:
        if not i.get("constraint") and not i.get("parent_index"):
            sql.append(i["name"] + ";")  # the index's name attribute holds the server's CREATE INDEX

    for t in rel.values():
        if t.get("relrowsecurity"):
            sql.append(f"ALTER TABLE {name(t)} ENABLE ROW LEVEL SECURITY;")
        if t.get("relforcerowsecurity"):
            sql.append(f"ALTER TABLE {name(t)} FORCE ROW LEVEL SECURITY;")
    for p in (o for o in objs if o["kind"] == "policy"):
        roles = ", ".join("PUBLIC" if r == "public" else q(r) for r in listed(p.get("roles")) or ["public"])
        sql.append(f"CREATE POLICY {q(p['name'])} ON {name(rel[p['parent']])} AS {p['permissive']} FOR {p['cmd']} TO {roles}"
                   + (f" USING ({p['qual']})" if p.get("qual") else "") + (f" WITH CHECK ({p['with_check']})" if p.get("with_check") else "") + ";")
    for g in (o for o in objs if o["kind"] == "trigger"):
        sql.append(g["definition"] + ";")
        state = {"D": "DISABLE", "R": "ENABLE REPLICA", "A": "ENABLE ALWAYS"}.get(g.get("tgenabled"))
        if state:
            sql.append(f"ALTER TABLE {name(rel[g['parent']])} {state} TRIGGER {q(g['name'])};")
    for r in (o for o in objs if o["kind"] == "rule"):
        sql.append(r["definition"].rstrip().rstrip(";") + ";")
    for sid, s in seqs.items():
        if not s.get("identity") and s.get("owned_by"):
            table, _, col = s["owned_by"].rpartition(".")
            sql.append(f"ALTER SEQUENCE {name(rel[sid])} OWNED BY {q(rel[sid]['parent'])}.{q(table)}.{q(col)};")

    # comments, owners and grants
    kinds = {"r": "TABLE", "p": "TABLE", "v": "VIEW", "m": "MATERIALIZED VIEW", "S": "SEQUENCE"}
    for o in rel.values():
        what = f"{kinds[o['relkind']]} {name(o)}"
        if o.get("comment"):
            sql.append(f"COMMENT ON {what} IS {lit(o['comment'])};")
        if (o.get("owner") or SUPER) != SUPER:
            sql.append(f"ALTER {what} OWNER TO {q(o['owner'])};")
        if o.get("acl"):
            sql += grants(f"{'TABLE' if o['relkind'] != 'S' else 'SEQUENCE'} {name(o)}", o["acl"], o.get("owner") or SUPER)
    for c in store["column"]:
        if c.get("comment") and c["parent"] in rel:
            sql.append(f"COMMENT ON COLUMN {name(rel[c['parent']])}.{q(c['name'])} IS {lit(c['comment'])};")
    for c in cons:
        if c.get("comment"):
            sql.append(f"COMMENT ON CONSTRAINT {q(c['name'])} ON {name(rel[c['parent']])} IS {lit(c['comment'])};")
    for i in store["index"]:
        if i.get("comment"):
            sql.append(f"COMMENT ON INDEX {q(rel[i['parent']]['parent'])}.{q(i['id'][len(rel[i['parent']]['parent']) + 1:])} IS {lit(i['comment'])};")
    for r in (o for o in objs if o["kind"] == "routine" and not o.get("made_by")):
        sig = f"{q(r['parent'])}.{q(r['name'])}({r['id'][r['id'].index('(') + 1:-1]})"
        kind = "PROCEDURE" if r.get("prokind") == "p" else "FUNCTION"
        if r.get("comment"):
            sql.append(f"COMMENT ON {kind} {sig} IS {lit(r['comment'])};")
        if (r.get("owner") or SUPER) != SUPER:
            sql.append(f"ALTER {kind} {sig} OWNER TO {q(r['owner'])};")
        if r.get("acl"):
            sql += grants(f"{kind} {sig}", r["acl"], r.get("owner") or SUPER)
    return "\n".join(sql) + "\n"


def fresh(version):
    name = f"sf-pg-{version}-roundtrip"
    S.remove(name)
    S.sh("docker", "run", "-d", "--name", name, "-e", f"POSTGRES_PASSWORD={S.PW}", f"postgres:{version}-alpine")
    return name


def ready(name):
    for _ in range(90):
        if S.sh("docker", "exec", name, "pg_isready", "-U", "postgres", "-q", check=False).returncode == 0:
            # the image's first server is a short-lived one that makes the cluster; wait for the real one to settle
            time.sleep(2)
            if S.sh("docker", "exec", name, "psql", "-U", "postgres", "-c", "SELECT 1", check=False).returncode == 0:
                return
        time.sleep(1)
    raise SystemExit(f"{name} did not answer")


def main():
    if not os.environ.get("LAB_SCHEMAS") or not os.environ.get("LAB_OUT"):
        raise SystemExit("LAB_SCHEMAS and LAB_OUT name the schemas and where their snapshots are")
    names = {v: fresh(v) for v, _ in X.POSTGRES}
    failures = 0
    try:
        for version, _ in X.POSTGRES:
            ready(names[version])
            sql = script(from_store(f"lab_scale_postgresql_{version}"))
            if "--show" in sys.argv:
                open(os.path.join(X.OUT, f"postgresql-{version}.sql"), "w").write(sql)
            t = time.time()
            r = subprocess.run(["docker", "exec", "-i", names[version], "psql", "-U", "postgres", "-q"], input=sql,
                               capture_output=True, text=True)
            refused = [l for l in r.stderr.splitlines() if l.startswith("ERROR") or "ERROR:" in l]
            t_load = time.time() - t
            original = json.load(open(os.path.join(X.OUT, f"postgresql-{version}.json")))["parts"]
            again = X.extract_pg(version, names[version])
            diffs, n = R.compare(original, again)
            ok = not refused and not diffs
            failures += not ok
            print(f"{'pass' if ok else 'FAIL'}  postgresql {version}: {len(sql) // 1024} KB of SQL written from the store, loaded in "
                  f"{t_load:.1f}s, {len(refused)} statements refused; {n} parts compared, {sum(diffs.values())} properties differ")
            for e in refused[:8]:
                print(f"        refused: {e[:200]}")
            for k, c in sorted(diffs.items(), key=lambda x: -x[1])[:12]:
                print(f"        differs: {k} in {c} parts")
    finally:
        if "--keep" not in sys.argv:
            for name in names.values():
                S.remove(name)
    print(f"== {failures} servers failed")


if __name__ == "__main__":
    main()
