#!/usr/bin/env python3
"""The round trip that vets engine_mysql, on one server image (a MySQL or Percona version):

  1. the every-object sample (tools/mysql/samples: common.sql, then the version's own file) is loaded into server A
  2. A is read (engines/mysql/reader.py)
  3. with --store: the model is stored in the cortex and engine_mysql by engine_mysql_service in an app's turn, and
     read back from the store: it must equal what was read
  4. the model is written (engines/mysql/writer.py) into a fresh server B of the same image, and B is read
  5. A's and B's models must be equal, and every SHOW CREATE (table, view, procedure, function, trigger, event) identical

  python3 tools/mysql/roundtrip.py --server mysql:8.0 [--store] [--sample FILE]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "engines", "mysql"))
import reader  # noqa: E402
import writer  # noqa: E402
from sf.servers import MySQL  # noqa: E402
from sf.store import Failed  # noqa: E402

ARGS = sys.argv[1:]
IMAGE = ARGS[ARGS.index("--server") + 1] if "--server" in ARGS else "mysql:8.0"


def samples(image):
    version = image.split(":")[1]
    files = [os.path.join(HERE, "samples", "common.sql")]
    for v in ("8.0", "8.4", "9.7"):
        if v <= version and os.path.exists(os.path.join(HERE, "samples", f"{v}.sql")):
            files.append(os.path.join(HERE, "samples", f"{v}.sql"))
    if "percona" in image and os.path.exists(os.path.join(HERE, "samples", f"percona-{version}.sql")):
        files.append(os.path.join(HERE, "samples", f"percona-{version}.sql"))
    if "--sample" in ARGS:
        files = [ARGS[ARGS.index("--sample") + 1]]
    return files


def shows(server, model):
    """Every object's SHOW CREATE, by its key."""
    stmts, keys = [], []
    for k, o in sorted(model["objects"].items()):
        db, kind, name = k.split("|", 2)
        what = {"table": "TABLE", "view": "VIEW", "procedure": "PROCEDURE", "function": "FUNCTION", "trigger": "TRIGGER", "event": "EVENT"}[kind]
        stmts.append(f"SHOW CREATE {what} {writer.q(db)}.{writer.q(name)}")
        keys.append(k)
    out = {}
    for k, row in zip(keys, server.rows(stmts)):
        kind = k.split("|")[1]
        out[k] = row[{"table": 1, "view": 1, "procedure": 2, "function": 2, "trigger": 2, "event": 3}[kind]]
    return out


def differences(a, b, path="", limit=12, out=None):
    out = [] if out is None else out
    if len(out) >= limit:
        return out
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a or k not in b:
                out.append(f"{path}/{k}: only in {'A' if k in a else 'B'}")
            else:
                differences(a[k], b[k], f"{path}/{k}", limit, out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            differences(x, y, f"{path}[{i}]", limit, out)
    elif a != b:
        out.append(f"{path}: A {json.dumps(a)[:160]} B {json.dumps(b)[:160]}")
    return out


def main():
    bad = []
    files = samples(IMAGE)
    print(f"== {IMAGE}: {', '.join(os.path.relpath(f, ROOT) for f in files)}", flush=True)
    with MySQL(IMAGE, name="sf-rt-a") as a:
        for f in files:
            a.load(f)
        model_a = reader.read(a)
        show_a = shows(a, model_a)
    kinds = {}
    for o in model_a["objects"].values():
        kinds[o["kind"]] = kinds.get(o["kind"], 0) + 1
    print(f"  read from A: {len(model_a['databases'])} databases, " + ", ".join(f"{n} {k}s" for k, n in sorted(kinds.items())))
    if "--store" in ARGS:
        from store import round_trip_store  # noqa: E402
        stored, rows = round_trip_store(model_a, IMAGE)
        diff = differences(model_a, stored)
        print(f"  {'pass' if not diff else 'FAIL'}  stored by engine_mysql_service in an app's turn ({rows} rows) and read back" + ("" if not diff else ": differs"))
        for d in diff:
            print(f"    differs  {d}")
        if diff:
            bad.append("the store")
        model_a_for_write = stored
    else:
        model_a_for_write = model_a
    sql = writer.write(model_a_for_write)
    with MySQL(IMAGE, name="sf-rt-b") as b:
        try:
            b.sql(sql)
        except Failed as e:
            print(f"  FAIL  the written SQL does not load into a fresh {IMAGE}: {e}")
            open(os.path.expanduser("~/schema-forge-lab-private/roundtrip-last.sql"), "w").write(sql)
            return 1
        model_b = reader.read(b)
        show_b = shows(b, model_b)
    diff = differences(model_a, model_b)
    print(f"  {'pass' if not diff else 'FAIL'}  written into a fresh server and read again: the model " + ("identical" if not diff else "differs"))
    for d in diff:
        print(f"    differs  {d}")
    if diff:
        bad.append("the model")
    same = [k for k in show_a if show_a[k] == show_b.get(k)]
    print(f"  {'pass' if len(same) == len(show_a) else 'FAIL'}  SHOW CREATE identical for {len(same)} of {len(show_a)} objects")
    for k in [k for k in show_a if show_a[k] != show_b.get(k)][:6]:
        la, lb = show_a[k].split("\n"), (show_b.get(k) or "").split("\n")
        first = next((i for i, (x, y) in enumerate(zip(la, lb)) if x != y), min(len(la), len(lb)))
        print(f"    differs  {k} line {first + 1}:\n      A {la[first] if first < len(la) else '(end)'}\n      B {lb[first] if first < len(lb) else '(end)'}")
    if len(same) != len(show_a):
        bad.append("SHOW CREATE")
    print(f"{'pass' if not bad else 'FAIL'}  engine_mysql round trip on {IMAGE}: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
