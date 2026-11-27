#!/usr/bin/env python3
"""Research for the MySQL plugin (#140): what each server says of itself, read from its own catalog, on every version
and flavor that has an image. For each server it records the tables and columns of information_schema (what the
plugin's tables must hold), its storage engines, its plugins, its server variables' names, and its privileges; then
it prints what differs across versions and between MySQL and Percona Server of the same version. Writes the full
survey as JSON to the scratch file named, for the issue.

  python3 tools/mysql/survey.py [--out FILE] [--only mysql:8.4,percona/percona-server:8.4] [--pairs percona]

  --only   survey only these servers (the others' kept surveys are reused)
  --pairs  print only the comparisons whose second server's name contains this (percona, tidb, mysql:9.7)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.servers import MySQL, TiDB  # noqa: E402

SERVERS = ["mysql:5.7", "mysql:8.0", "mysql:8.4", "mysql:9.7",
           "percona/percona-server:5.7", "percona/percona-server:8.0", "percona/percona-server:8.4", "pingcap/tidb:v8.5.4"]
ARGS = sys.argv[1:]
OUT = ARGS[ARGS.index("--out") + 1] if "--out" in ARGS else os.path.expanduser("~/schema-forge-lab-private/mysql-survey.json")
ONLY = ARGS[ARGS.index("--only") + 1].split(",") if "--only" in ARGS else SERVERS


def survey(image):
    with (TiDB(image, name="sf-survey") if "tidb" in image else MySQL(image, name="sf-survey")) as s:
        version = s.json("SELECT JSON_ARRAY(VERSION(), @@version_comment)")
        cols = s.json("SELECT JSON_ARRAYAGG(JSON_ARRAY(TABLE_NAME, COLUMN_NAME, CAST(COLUMN_TYPE AS CHAR))) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'information_schema'")
        engines = s.json("SELECT JSON_ARRAYAGG(JSON_ARRAY(ENGINE, SUPPORT)) FROM information_schema.ENGINES")
        plugins = s.json("SELECT JSON_ARRAYAGG(JSON_ARRAY(PLUGIN_NAME, PLUGIN_TYPE, PLUGIN_STATUS)) FROM information_schema.PLUGINS")
        try:
            variables = s.json("SELECT JSON_ARRAYAGG(VARIABLE_NAME) FROM performance_schema.global_variables")
        except Exception:
            variables = s.json("SELECT JSON_ARRAYAGG(VARIABLE_NAME) FROM information_schema.GLOBAL_VARIABLES")
        r = s.json("SELECT JSON_ARRAYAGG(PRIVILEGE_TYPE) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = \"'root'@'localhost'\"")
        privs = sorted(set(r or []))
    tables = {}
    for t, c, typ in cols or []:
        tables.setdefault(t.upper(), []).append([c.upper(), typ])
    return {"image": image, "version": version[0], "comment": version[1], "information_schema": tables,
            "engines": sorted(e for e, sup in engines if sup in ("YES", "DEFAULT")),
            "plugins": sorted(p for p, _, st in plugins if st == "ACTIVE"), "variables": sorted(v.lower() for v in variables or []),
            "privileges": privs}


def diff(a, b):
    out = []
    ta, tb = a["information_schema"], b["information_schema"]
    for t in sorted(set(ta) | set(tb)):
        if t not in ta:
            out.append(f"+ information_schema.{t} ({len(tb[t])} columns)")
        elif t not in tb:
            out.append(f"- information_schema.{t}")
        else:
            ca, cb = {c for c, _ in ta[t]}, {c for c, _ in tb[t]}
            for c in sorted(cb - ca):
                out.append(f"+ information_schema.{t}.{c}")
            for c in sorted(ca - cb):
                out.append(f"- information_schema.{t}.{c}")
    for key in ("engines", "plugins", "privileges"):
        for x in sorted(set(b[key]) - set(a[key])):
            out.append(f"+ {key[:-1]} {x}")
        for x in sorted(set(a[key]) - set(b[key])):
            out.append(f"- {key[:-1]} {x}")
    va, vb = set(a["variables"]), set(b["variables"])
    out.append(f"  variables: +{len(vb - va)} -{len(va - vb)}" + (f" (+ {', '.join(sorted(vb - va)[:12])}{' ...' if len(vb - va) > 12 else ''})" if vb - va else ""))
    return out


def main():
    # each server's survey is kept as it finishes, so a run split over several calls (--only) adds up
    results = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for image in ONLY:
        print(f"== {image}", flush=True)
        try:
            results[image] = survey(image)
            r = results[image]
            print(f"  {r['version']} ({r['comment']}): {len(r['information_schema'])} information_schema tables, "
                  f"{sum(len(v) for v in r['information_schema'].values())} columns, {len(r['engines'])} engines, {len(r['plugins'])} active plugins, "
                  f"{len(r['variables'])} variables, {len(r['privileges'])} global privileges")
        except SystemExit as e:
            print(f"  FAIL  {e}")
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        json.dump(results, open(OUT, "w"), indent=1)
    print(f"\nkept: {OUT} ({', '.join(sorted(results))})")
    pairs = [("mysql:5.7", "mysql:8.0"), ("mysql:8.0", "mysql:8.4"), ("mysql:8.4", "mysql:9.7"),
             ("mysql:5.7", "percona/percona-server:5.7"), ("mysql:8.0", "percona/percona-server:8.0"), ("mysql:8.4", "percona/percona-server:8.4"),
             ("mysql:8.0", "pingcap/tidb:v8.5.4")]
    want = ARGS[ARGS.index("--pairs") + 1] if "--pairs" in ARGS else ""
    for a, b in pairs:
        if a in results and b in results and want in b:
            print(f"\n== {a} -> {b}")
            for line in diff(results[a], results[b]):
                print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
