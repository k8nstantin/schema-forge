"""Layout B, declared options: the experiment against the locked layout (A). In A every fact one engine adds to a cortex
row is a column of an engine table (engine_mysql.tables.row_format), so a new option is ALTER TABLE. In B it is a key of
that cortex row's options (JSONB), declared as a row of cortex.option_declarations (engine, part, name, type, allowed
values, since and until which version), and the database refuses, as each row is written, an option not declared for
the design's engine and part, of the wrong type, not one of its values, or not in the design's version. A new option, or
a new engine, is rows, never a new column.

The engine tables that add one row's facts move into options; the ones that are lists of their own (a table's
policies, its subpartitions) stay tables. Every declaration is read from the engine table it replaces: its columns,
types, NOT NULL and IN (...) checks, so B holds exactly what A held and the proven writers read B through from_options.

  transform(db)              a database of layout A made layout B; returns the map {engine table: cortex table}
  to_options(rows, moved)    a design's rows of A as rows of B
  from_options(st, moved)    rows read back from B as A's, for the writers
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

TYPE = {"text": "string", "boolean": "boolean", "integer": "number", "bigint": "number", "numeric": "number", "jsonb": "json", "uuid": "string"}

SETUP = r"""
CREATE TABLE cortex.option_declarations (
  id          TEXT NOT NULL PRIMARY KEY,
  engine      TEXT NOT NULL,
  part        TEXT NOT NULL,
  name        TEXT NOT NULL,
  value_type  TEXT NOT NULL CHECK (value_type IN ('string', 'number', 'boolean', 'json')),
  nullable    BOOLEAN NOT NULL DEFAULT true,
  choices     JSONB,
  since       TEXT REFERENCES cortex.engine_versions (id),
  "until"     TEXT REFERENCES cortex.engine_versions (id),
  UNIQUE (engine, part, name)
);
GRANT SELECT ON cortex.option_declarations TO sf_service, sf_agent, sf_reader;

CREATE FUNCTION cortex.check_options() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  d cortex.designs;
  o record;
  dec cortex.option_declarations;
  at numeric;
BEGIN
  IF NEW.options = '{}'::jsonb THEN RETURN NEW; END IF;
  SELECT * INTO d FROM cortex.designs WHERE id = NEW.design;
  SELECT position INTO at FROM cortex.engine_versions WHERE engine = d.engine AND version = d.engine_version;
  FOR o IN SELECT key, value FROM jsonb_each(NEW.options) LOOP
    SELECT * INTO dec FROM cortex.option_declarations WHERE engine = d.engine AND part = TG_TABLE_NAME AND name = o.key;
    IF dec.id IS NULL THEN
      RAISE EXCEPTION 'option % is not declared for % %', o.key, d.engine, TG_TABLE_NAME USING ERRCODE = 'check_violation';
    END IF;
    IF jsonb_typeof(o.value) = 'null' THEN
      IF NOT dec.nullable THEN RAISE EXCEPTION 'option % may not be null', o.key USING ERRCODE = 'check_violation'; END IF;
      CONTINUE;
    END IF;
    IF dec.value_type <> 'json' AND jsonb_typeof(o.value) <> dec.value_type THEN
      RAISE EXCEPTION 'option % is a %, not a %', o.key, dec.value_type, jsonb_typeof(o.value) USING ERRCODE = 'check_violation';
    END IF;
    IF dec.choices IS NOT NULL AND NOT dec.choices @> jsonb_build_array(o.value) THEN
      RAISE EXCEPTION 'option % may be one of %, not %', o.key, dec.choices, o.value USING ERRCODE = 'check_violation';
    END IF;
    IF (dec.since IS NOT NULL AND at < (SELECT position FROM cortex.engine_versions WHERE id = dec.since))
       OR (dec."until" IS NOT NULL AND at > (SELECT position FROM cortex.engine_versions WHERE id = dec."until")) THEN
      RAISE EXCEPTION 'option % is not in % %', o.key, d.engine, d.engine_version USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
"""


TYPES = {}  # (engine table, column): the declared value type, for typing what a reader gives as text


def typed(v, kind):
    """A value as its declaration types it: the lab's MySQL reader gives some numbers and booleans as text."""
    if isinstance(v, str) and kind == "number":
        return int(v) if v.lstrip("-").isdigit() else float(v)
    if isinstance(v, str) and kind == "boolean":
        return v.lower() in ("t", "true", "1", "yes", "on")
    return v


def q(sql, db):
    return C.psql(sql, db)


def transform(db):
    """Layout A's database made B: each engine table that extends one cortex row folded into that row's options."""
    q(SETUP, db)
    rows = q("""SELECT c.conrelid::regclass::text, c.confrelid::regclass::text FROM pg_constraint c
                WHERE c.contype = 'f' AND c.conrelid::regclass::text ~ '^engine_' AND c.confrelid::regclass::text ~ '^cortex\\.'
                AND (SELECT array_agg(attname ORDER BY attname) FROM pg_attribute WHERE attrelid = c.conrelid AND attnum = ANY (c.conkey))
                    = ARRAY['design', 'id']::name[]""", db).split("\n")
    moved = dict(r.split("|") for r in rows if r)
    targets = sorted(set(moved.values()))
    seen, keys = {}, {}
    decl = []
    for t, target in sorted(moved.items()):
        engine = t.split(".")[0][len("engine_"):]
        part = target.split(".")[1]
        cols = q(f"""SELECT a.attname || '|' || format_type(a.atttypid, NULL) || '|' || NOT a.attnotnull FROM pg_attribute a
                     WHERE a.attrelid = '{t}'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attname NOT IN ('id', 'design')
                     ORDER BY a.attnum""", db).split("\n")
        checks = q(f"SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '{t}'::regclass AND contype = 'c'", db).split("\n")
        for line in cols:
            name, typ, nullable = line.split("|")
            keys.setdefault(t, []).append(name)
            TYPES[(t, name)] = TYPE[typ]
            if (engine, part, name) in seen:
                if seen[(engine, part, name)] != TYPE[typ]:
                    raise SystemExit(f"{t}.{name} is a {TYPE[typ]}, but another table's {name} of {part} is a {seen[(engine, part, name)]}")
                continue  # the same fact with the same meaning on two kinds of object: one option, declared once
            seen[(engine, part, name)] = TYPE[typ]
            choices = None
            for ch in checks:
                m = re.search(rf'\(?"?{name}"? = ANY \(ARRAY\[(.*?)\]\)', ch)
                if m:
                    choices = json.dumps(re.findall(r"'((?:[^']|'')*)'", m.group(1)))
            decl.append((f"{engine}/{part}/{name}", engine, part, name, TYPE[typ], nullable == "true", choices, t))
    q("INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices) VALUES "
      + ", ".join("(" + ", ".join("NULL" if v is None else ("true" if v is True else "false" if v is False else "'" + str(v).replace("'", "''") + "'")
                                  for v in d[:7]) + ")" for d in decl) + ";", db)
    for target in targets:
        q(f"ALTER TABLE {target} ADD COLUMN options JSONB NOT NULL DEFAULT '{{}}';"
          f"CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON {target} FOR EACH ROW EXECUTE FUNCTION cortex.check_options();", db)
    q("".join(f"DROP TABLE {t} CASCADE;" for t in moved), db)
    return moved, keys


def to_options(rows, moved):
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


def from_options(st, moved, keys):
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
