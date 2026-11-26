"""Declared options (decision declared-options) for the lab's readers. The lab's MySQL and PostgreSQL readers still give
what one engine adds to a cortex row as rows of the engine tables the locked layout had before (engine_mysql.tables,
engine_postgresql.relations); design/options_map.json, made from those tables when they were folded, says which cortex
row each became options of, and the type of each option. to_options turns a reader's rows into the locked design's;
from_options turns rows read back into the shape the proven writers read.
"""
import json
import os



MAP = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "design", "options_map.json")))
MOVED = {t: m["target"] for t, m in MAP["moved"].items()}
KEYS = {t: m["keys"] for t, m in MAP["moved"].items()}
TYPES = {(t, k): v for t, m in MAP["moved"].items() for k, v in m["types"].items()}


def typed(v, kind):
    """A value as its declaration types it: the lab's MySQL reader gives some numbers and booleans as text."""
    if isinstance(v, str) and kind == "number":
        return int(v) if v.lstrip("-").isdigit() else float(v)
    if isinstance(v, str) and kind == "boolean":
        return v.lower() in ("t", "true", "1", "yes", "on")
    return v


def to_options(rows, moved=MOVED):
    """A design's rows of A as B's: every moved engine row's columns become keys of its cortex row's options."""
    out = {k: [dict(r) for r in v] for k, v in rows.items() if k not in moved}
    index = {t: {r["id"]: r for r in out.get(t, [])} for t in set(moved.values())}
    for t, target in moved.items():
        for r in rows.get(t, []):
            row = index[target][r["id"]]
            opts = row.setdefault("options", {})
            for k, v in r.items():
                if k not in ("id", "design"):
                    opts[k] = typed(v, TYPES.get((t, k)))
    for target in set(moved.values()):
        for r in out.get(target, []):
            r["options"] = json.dumps(r.get("options") or {})
    return out


def from_options(st, moved=MOVED, keys=KEYS):
    """Rows read back from B as A's: each moved engine table rebuilt from the options of its cortex rows. A row of an
    engine table is there when a key only that table has is there (every key is written, null or not)."""
    back = {k: v for k, v in st.items()}
    for t, target in moved.items():
        others = {k for u, ks in keys.items() if u != t and moved[u] == target for k in ks}
        own = [k for k in keys[t] if k not in others] or keys[t]
        back[t] = {}
        for rid, r in st.get(target, {}).items():
            opts = r.get("options") or {}
            if any(k in opts for k in own):
                back[t][rid] = {"id": rid, "design": r["design"], **{k: opts.get(k) for k in keys[t]}}
    for target in set(moved.values()):
        for r in back.get(target, {}).values():
            r.pop("options", None)
    return back
