#!/usr/bin/env python3
"""The lock: what PostgreSQL holds once the whole schema_forge is installed (the cortex and every engine package, with
every grant and policy), kept beside the design in schema/dump/schema_forge.sql and compared. It is built in a fresh
PostgreSQL 18 container exactly as tools/local/install.py builds it (tools/sf/plugin.py install_all), dumped with
pg_dump --schema-only, and must equal the kept dump; the installer then dumps the database it installed and must equal
it too, so what is installed is what was tested. --write rewrites the kept dump after a change of the design (a design
change, committed with it).

  python3 tools/local/lock.py [--write]
"""
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.plugin import install_all  # noqa: E402
from sf.schema import ROOT  # noqa: E402
from sf.store import Store  # noqa: E402

KEPT = os.path.join(ROOT, "schema", "dump", "schema_forge.sql")


def normal(dump):
    """A dump without what changes from run to run or client to client: the versions it names, pg_dump's restrict key."""
    keep = [l for l in dump.splitlines() if not l.startswith(("-- Dumped from", "-- Dumped by", "\\restrict", "\\unrestrict"))]
    return "\n".join(keep).strip() + "\n"


def first_difference(a, b, names):
    return "\n".join(list(difflib.unified_diff(a.splitlines(), b.splitlines(), *names, lineterm="", n=1))[:14])


def compare(dump):
    """None when the dump is the kept one; else what differs first."""
    if not os.path.exists(KEPT):
        return f"{os.path.relpath(KEPT, ROOT)} is not kept yet: run python3 tools/local/lock.py --write"
    kept = open(KEPT, encoding="utf-8").read()
    return None if normal(dump) == kept else first_difference(kept, normal(dump), ("locked", "this database"))


def main():
    with Store("sf-lock") as store:
        cards = install_all(store)
        dump = normal(store.dump())
    print(f"  built: the cortex and {', '.join(c['namespace'] for c in cards)}; the dump {len(dump.splitlines())} lines")
    if "--write" in sys.argv:
        os.makedirs(os.path.dirname(KEPT), exist_ok=True)
        open(KEPT, "w", encoding="utf-8").write(dump)
        print(f"  written: {os.path.relpath(KEPT, ROOT)}")
        print("pass  lock: written")
        return 0
    diff = compare(dump)
    print(f"  {'pass' if not diff else 'FAIL'}  the same as {os.path.relpath(KEPT, ROOT)}" + ("" if not diff else f":\n{diff}"))
    print(f"{'pass' if not diff else 'FAIL'}  lock: {0 if not diff else 1} findings")
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
