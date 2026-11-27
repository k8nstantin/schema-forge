#!/usr/bin/env python3
"""The history every engine gets from the cortex: changes made in turns are logged row by row; undoing a turn gives
back the model as it was before it, exactly; undoing the undo gives the turn back; undoing every turn, newest first,
restores the empty design; turns are numbered in commit order; a change outside an operation is refused.

  python3 tools/cortex/history.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.fixture import in_turn, installed, new_design, turn_id  # noqa: E402

MODEL = ("namespaces", "objects", "columns", "indexes", "index_parts", "constraints", "constraint_columns", "dependencies")


def model(store, design):
    """The design's whole model, every row of every model table, as one text: what must come back exactly."""
    parts = " || ".join(f"coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM cortex.{t} r WHERE r.design = '{design}'), '[]')::text" for t in MODEL)
    return store.value(f"SELECT {parts}")


def main():
    bad = []

    def check(ok, what):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            bad.append(what)

    store = installed("sf-cortex-history")
    try:
        d, b = new_design(store, "history", "mysql", "8.4", "mysql")
        empty = model(store, d)
        t1 = turn_id(store.sql(in_turn(d, b, f"""
            INSERT INTO cortex.namespaces (design, name, position) VALUES ('{d}', 'shop', 1);
            INSERT INTO cortex.objects (design, engine, namespace, kind, name, position)
              SELECT '{d}', 'mysql', id, 'table', 'orders', 1 FROM cortex.namespaces WHERE design = '{d}' AND name = 'shop';
            INSERT INTO cortex.columns (design, object, position, name, type, nullable)
              SELECT '{d}', id, 1, 'id', 'bigint', false FROM cortex.objects WHERE design = '{d}' AND name = 'orders';
            INSERT INTO cortex.columns (design, object, position, name, type, nullable)
              SELECT '{d}', id, 2, 'total', 'decimal(12,2)', true FROM cortex.objects WHERE design = '{d}' AND name = 'orders';
            INSERT INTO cortex.constraints (design, object, position, name, kind)
              SELECT '{d}', id, 1, 'PRIMARY', 'primary' FROM cortex.objects WHERE design = '{d}' AND name = 'orders';
            INSERT INTO cortex.constraint_columns (design, "constraint", position, "column")
              SELECT '{d}', k.id, 1, c.id FROM cortex.constraints k JOIN cortex.columns c ON c.object = k.object AND c.name = 'id' WHERE k.design = '{d}';
            INSERT INTO cortex.indexes (design, object, position, name)
              SELECT '{d}', id, 1, 'by_total' FROM cortex.objects WHERE design = '{d}' AND name = 'orders';
            INSERT INTO cortex.index_parts (design, "index", position, "column")
              SELECT '{d}', i.id, 1, c.id FROM cortex.indexes i JOIN cortex.columns c ON c.object = i.object AND c.name = 'total' WHERE i.design = '{d}';""",
            kind="import"))[1])
        after1 = model(store, d)
        check(after1 != empty, "turn 1 (an import) made a table, its columns, its key and an index")
        t2 = turn_id(store.sql(in_turn(d, b, f"""
            UPDATE cortex.columns SET name = 'amount', type = 'decimal(14,2)' WHERE design = '{d}' AND name = 'total';
            INSERT INTO cortex.columns (design, object, position, name, type, nullable, comment)
              SELECT '{d}', id, 3, 'placed_at', 'datetime', false, 'when it was placed' FROM cortex.objects WHERE design = '{d}' AND name = 'orders';
            DELETE FROM cortex.indexes WHERE design = '{d}' AND name = 'by_total';""", parent=t1))[1])
        after2 = model(store, d)
        logged = store.value(f"SELECT count(*) FROM cortex.row_changes r JOIN cortex.operations o ON o.id = r.operation WHERE o.turn = '{t2}'")
        check(logged == "4", f"turn 2 logged every row it changed, the index part its delete cascaded among them ({logged} of 4)")
        u = turn_id(store.sql(in_turn(d, b, f"SELECT cortex.undo('{t2}');", kind="undo", parent=t2))[1])
        check(model(store, d) == after1, "undoing turn 2 gives the model after turn 1 back, exactly")
        check(store.value(f"SELECT state FROM cortex.turns WHERE id = '{t2}'") == "undone", "turn 2 is marked undone")
        store.sql(in_turn(d, b, f"SELECT cortex.undo('{u}');", kind="undo", parent=u))
        check(model(store, d) == after2, "undoing the undo gives turn 2 back, exactly")
        last = store.value(f"SELECT id FROM cortex.turns WHERE design = '{d}' AND state = 'committed' ORDER BY seq DESC LIMIT 1")
        store.sql(in_turn(d, b, f"SELECT cortex.undo('{last}');", kind="restore", parent=last))
        store.sql(in_turn(d, b, f"SELECT cortex.undo('{t1}');", kind="restore"))
        check(model(store, d) == empty, "restoring to before turn 1, newest first, gives the empty design back")
        seqs = store.value(f"SELECT string_agg(seq::text, ',' ORDER BY seq) FROM cortex.turns WHERE design = '{d}'")
        check(seqs == "1,2,3,4,5,6", f"turns numbered in commit order ({seqs})")
        rc, _, err = store.sql(f"BEGIN; SET ROLE sf_service; INSERT INTO cortex.namespaces (design, name, position) VALUES ('{d}', 'stray', 9); COMMIT;", check=False)
        check(rc != 0 and "outside an operation" in err, "a change outside an operation is refused")
        rc, _, err = store.sql(f"BEGIN; SET ROLE sf_service; DELETE FROM cortex.row_changes; COMMIT;", check=False)
        check(rc != 0, "the app may not rewrite the log")
    finally:
        store.__exit__(None, None, None)
    print(f"{'pass' if not bad else 'FAIL'}  cortex history: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
