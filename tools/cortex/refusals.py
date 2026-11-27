#!/usr/bin/env python3
"""What the cortex refuses the same way for every engine, as an object is written (cortex.check_object):

  a kind its design's version does not have   a library (from 9.7) on an 8.4 design; taken on a 9.7 design
  a kind its design's flavor refuses          a resource group on an Aurora design; taken on a MySQL design
  a kind its design's engine does not have    a function (PostgreSQL's) on a MySQL design (the foreign key to object_kinds)

  python3 tools/cortex/refusals.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.fixture import in_turn, installed, new_design  # noqa: E402


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)

    store = installed("sf-cortex-refusals")
    try:
        def put(design, branch, kind, name):
            return store.sql(in_turn(design, branch, f"""
                INSERT INTO cortex.namespaces (design, name, position) SELECT '{design}', 'db', 1 WHERE NOT EXISTS (SELECT 1 FROM cortex.namespaces WHERE design = '{design}');
                INSERT INTO cortex.objects (design, engine, namespace, kind, name, position)
                  SELECT '{design}', 'mysql', id, '{kind}', '{name}', (SELECT count(*) + 1 FROM cortex.objects WHERE design = '{design}') FROM cortex.namespaces WHERE design = '{design}';"""),
                check=False)
        d84, b84 = new_design(store, "on84", "mysql", "8.4", "mysql")
        d97, b97 = new_design(store, "on97", "mysql", "9.7", "mysql")
        aur, baur = new_design(store, "aurora", "mysql", "8.0", "aurora")
        my80, bmy80 = new_design(store, "my80", "mysql", "8.0", "mysql")
        d57, b57 = new_design(store, "on57", "mysql", "5.7", "mysql")
        rc, _, err = put(d84, b84, "library", "lib")
        check(rc != 0 and "has no library" in err, "a library on a MySQL 8.4 design is refused (from 9.7)")
        rc, _, err = put(d97, b97, "library", "lib")
        check(rc == 0, "a library on a MySQL 9.7 design is taken" + ("" if rc == 0 else f" ({err.strip()[:100]})"))
        rc, _, err = put(d57, b57, "resource_group", "rg")
        check(rc != 0 and "has no resource_group" in err, "a resource group on a MySQL 5.7 design is refused (from 8.0)")
        rc, _, err = put(aur, baur, "resource_group", "rg")
        check(rc != 0 and "aurora refuses a resource_group" in err, "a resource group on an Aurora design is refused (the flavor refuses it)")
        rc, _, err = put(my80, bmy80, "resource_group", "rg")
        check(rc == 0, "a resource group on a MySQL 8.0 design is taken" + ("" if rc == 0 else f" ({err.strip()[:100]})"))
        rc, _, err = put(my80, bmy80, "function", "f")
        check(rc != 0, "a PostgreSQL kind (function) on a MySQL design is refused")
    finally:
        store.__exit__(None, None, None)
    print(f"{'pass' if not bad else 'FAIL'}  cortex refusals: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
