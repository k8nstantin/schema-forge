#!/usr/bin/env python3
"""What PostgreSQL itself holds once the cortex is installed, kept and compared: the schema-only pg_dump of
schema_forge, (1) loaded into a second fresh store and dumped again, identical; (2) the same as schema/dump/cortex.sql,
the dump kept beside the design, so any change to what the database holds shows as a diff. --write rewrites the kept
dump after a change of the design.

  python3 tools/cortex/dump.py [--write]
"""
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.schema import ROOT, cortex_sql, script  # noqa: E402
from sf.store import Store  # noqa: E402

KEPT = os.path.join(ROOT, "schema", "dump", "cortex.sql")


def first_difference(a, b, names):
    diff = list(difflib.unified_diff(a.splitlines(), b.splitlines(), *names, lineterm="", n=1))
    return "\n".join(diff[:12])


def main():
    bad = []
    with Store("sf-cortex-dump-a") as a:
        a.sql(script(cortex_sql()))
        one = a.dump()
    with Store("sf-cortex-dump-b") as b:
        b.sql(one)
        two = b.dump()
    print(f"  the dump: {len(one.splitlines())} lines")
    if one != two:
        bad.append("the dump, loaded into a fresh store and dumped again, differs:\n" + first_difference(one, two, ("installed", "reloaded")))
    else:
        print("  loaded into a fresh store and dumped again: identical")
    if "--write" in sys.argv:
        os.makedirs(os.path.dirname(KEPT), exist_ok=True)
        open(KEPT, "w", encoding="utf-8").write(one)
        print(f"  written: {os.path.relpath(KEPT, ROOT)}")
    elif not os.path.exists(KEPT):
        bad.append(f"{os.path.relpath(KEPT, ROOT)} is not kept yet: run with --write")
    elif open(KEPT, encoding="utf-8").read() != one:
        bad.append(f"the database differs from {os.path.relpath(KEPT, ROOT)}:\n" + first_difference(open(KEPT, encoding="utf-8").read(), one, ("kept", "installed")))
    else:
        print(f"  the same as {os.path.relpath(KEPT, ROOT)}")
    for x in bad:
        print(f"  FAIL  {x}")
    print(f"{'pass' if not bad else 'FAIL'}  cortex dump: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
