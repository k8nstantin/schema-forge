"""What the cortex tools test on: the cortex installed in a fresh store, and two engines plugged in the way every plugin
is (tools/sf/plugin.py: its owner and service account, its namespace, its seeds, plug_in and fit_plugin), each with no
tables of its own yet; and helpers to work as an account inside a turn, as the app and the agent do."""
import json

from sf.plugin import plug
from sf.schema import cortex_sql, script
from sf.store import Store

# test engines: a kind that arrives in a later version (since), and a flavor that refuses a kind (refuses.kinds)
ENGINES = {
    "mysql": {"name": "MySQL", "versions": ["5.7", "8.0", "8.4", "9.7"],
              "flavors": {"mysql": ("MySQL", {}), "percona": ("Percona Server for MySQL", {}),
                          "aurora": ("Amazon Aurora MySQL", {"kinds": ["resource_group"], "versions": ["5.7", "8.4", "9.7"]})},
              "kinds": [("table", "Table", True, None), ("view", "View", True, None), ("procedure", "Procedure", False, None), ("trigger", "Trigger", False, None),
                        ("library", "Library", False, "9.7"), ("resource_group", "Resource group", False, "8.0")]},
    "postgresql": {"name": "PostgreSQL", "versions": ["15", "16", "17", "18"], "flavors": {"postgresql": ("PostgreSQL", {}), "alloydb": ("AlloyDB", {})},
                   "kinds": [("table", "Table", True, None), ("view", "View", True, None), ("function", "Function", False, None), ("sequence", "Sequence", False, None)]},
}


def plug_engine(store, engine):
    """A test engine with one table of its own (tables, extending cortex.objects), plugged in the way every plugin is."""
    e = ENGINES[engine]
    ns = f"engine_{engine}"
    table = (f"{ns}.tables", f"""CREATE TABLE {ns}.tables (
        id      UUID NOT NULL PRIMARY KEY,
        design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
        note    TEXT,
        UNIQUE (design, id),
        FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED);""")
    rows = [f"INSERT INTO cortex.engines (id, plugin, name) VALUES ('{engine}', '{engine}', '{e['name']}');",
            f"INSERT INTO cortex.plugin_tables (plugin, name, extends, comment) VALUES ('{engine}', 'tables', 'objects', 'a test table of the engine');"]
    rows += [f"INSERT INTO cortex.engine_versions (id, engine, version, name, position) VALUES ('{engine}/{v}', '{engine}', '{v}', '{e['name']} {v}', {i + 1});"
             for i, v in enumerate(e["versions"])]
    rows += [f"INSERT INTO cortex.engine_flavors (id, engine, flavor, name, refuses) VALUES ('{engine}/{f}', '{engine}', '{f}', '{n}', '{json.dumps(r)}');"
             for f, (n, r) in e["flavors"].items()]
    rows += [f"INSERT INTO cortex.object_kinds (id, engine, kind, name, has_columns, position, since) VALUES ('{engine}/{k}', '{engine}', '{k}', '{n}', {str(c).lower()}, {i + 1}, "
             f"{repr(s) if s else 'NULL'});" for i, (k, n, c, s) in enumerate(e["kinds"])]
    plug(store, engine, "engine", ns, e["name"], 1, 1, [table], [(f"{engine} seeds", "\n".join(rows))])


def installed(name):
    """A store with the cortex installed and both engines plugged in."""
    store = Store(name).__enter__()
    try:
        store.sql(script(cortex_sql()))
        for engine in ENGINES:
            plug_engine(store, engine)
    except BaseException:
        store.__exit__(None, None, None)
        raise
    return store


def as_role(role, body):
    """A transaction as an account: the body's SQL between BEGIN and COMMIT."""
    return f"BEGIN;\nSET ROLE {role};\n{body}\nCOMMIT;\n"


def new_design(store, name, engine, version, flavor, role="cortex_service"):
    """A design and its main branch, made as the app makes them; returns (design, branch)."""
    out = store.sql(as_role(role, f"""
        INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('{name}', '{engine}', '{version}', '{flavor}') RETURNING id;
        INSERT INTO cortex.branches (design, name) SELECT id, 'main' FROM cortex.designs WHERE name = '{name}' RETURNING id;"""))[1].split()
    return out[0], out[1]


def in_turn(design, branch, body, kind="edit", author="tool", parent=None, op_kind="edit", role="cortex_service"):
    """SQL that opens a turn and one operation, sets the session's operation, runs the body, and commits the turn;
    it prints the turn's id first."""
    par = f"'{parent}'" if parent else "NULL"
    return as_role(role, f"""
        WITH t AS (INSERT INTO cortex.turns (design, branch, parent, kind, author) VALUES ('{design}', '{branch}', {par}, '{kind}', '{author}') RETURNING id)
        SELECT set_config('sf.turn', id::text, true) FROM t;
        SELECT current_setting('sf.turn');
        WITH o AS (INSERT INTO cortex.operations (design, turn, position, kind, summary)
                   VALUES ('{design}', current_setting('sf.turn')::uuid, 1, '{op_kind}', '{op_kind} by {author}') RETURNING id)
        SELECT set_config('schema_forge.operation', id::text, true) FROM o;
        {body}
        UPDATE cortex.turns SET state = 'committed', ended_at = now() WHERE id = current_setting('sf.turn')::uuid;""")


def plugin_turn(store, design, branch, body, plugin_role, op_kind="import", check=True):
    """The real way a plugin works: the app opens a turn; the plugin, as its own service account, adds its operation
    to it and writes under it; the app commits the turn. Returns the plugin's (exit, stdout, stderr); the turn is
    committed when the plugin's work went in, rejected when it did not."""
    t = store.sql(as_role("cortex_service", f"INSERT INTO cortex.turns (design, branch, kind, author) VALUES ('{design}', '{branch}', '{op_kind}', 'app') RETURNING id;"))[1].split()[0]
    r = store.sql(as_role(plugin_role, f"""
        WITH o AS (INSERT INTO cortex.operations (design, turn, position, kind, summary)
                   VALUES ('{design}', '{t}', 1, '{op_kind}', '{op_kind} by {plugin_role}') RETURNING id)
        SELECT set_config('schema_forge.operation', id::text, true) FROM o;
        {body}"""), check=check)
    state = "'committed', ended_at = now()" if r[0] == 0 else "'rejected', ended_at = now()"
    store.sql(as_role("cortex_service", f"UPDATE cortex.turns SET state = {state} WHERE id = '{t}';"))
    return r


def turn_id(output):
    """The turn's id from in_turn's output: the first line that is a UUID."""
    for line in output.split():
        if len(line) == 36 and line.count("-") == 4:
            return line
    raise ValueError(f"no turn id in {output!r}")
