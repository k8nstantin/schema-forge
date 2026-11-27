"""The install SQL of an owner's folder (the cortex, a plugin): its namespace, its tables in owner.toml's order with
every table's and column's comment in the database, its functions, and its plug-in. Comments are read from the files:
a table's from its first line (-- ns.table: what it holds.), a column's from its line's trailing -- comment."""
import os
import re
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROLES = ("cortex_owner", "cortex_service", "cortex_agent", "cortex_reader")


def owner(folder):
    return tomllib.load(open(os.path.join(ROOT, folder, "owner.toml"), "rb"))


def q(s):
    return "'" + s.replace("'", "''") + "'"


def comments(ns, table, text):
    """COMMENT ON statements for a table file: its first line, then every column line's trailing comment."""
    head = re.match(r"^--\s*" + re.escape(f"{ns}.{table}") + r":\s*(.+?)\s*$", text.splitlines()[0])
    if not head:
        raise SystemExit(f"{ns}.{table}: the first line must be '-- {ns}.{table}: what it holds.'")
    out = [f"COMMENT ON TABLE {ns}.{table} IS {q(head.group(1))};"]
    body = text[text.index("("):]
    for line in body.splitlines():
        m = re.match(r'^\s+("?[a-z_][a-z0-9_]*"?)\s+[A-Z].*?--\s*(.+?)\s*$', line)
        if m and m.group(1).upper() not in ("UNIQUE", "CHECK", "FOREIGN", "PRIMARY", "CONSTRAINT"):
            out.append(f"COMMENT ON COLUMN {ns}.{table}.{m.group(1)} IS {q(m.group(2))};")
    return out


def install_sql(folder):
    """(label, SQL) parts installing one owner's folder, in order."""
    o = owner(folder)
    ns = o["namespace"]
    parts = [(f"{folder}/owner.toml", f"CREATE SCHEMA {ns};")]
    for t in o["tables"]:
        path = f"{folder}/{t}.sql"
        text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        parts.append((path, text))
        parts.append((path + " comments", "\n".join(comments(ns, t, text))))
    for f in o.get("functions", []):
        path = f"{folder}/functions/{f}.sql"
        parts.append((path, open(os.path.join(ROOT, path), encoding="utf-8").read()))
    return o, parts


def cortex_sql():
    """The whole cortex install, run as cortex_owner in the one database schema_forge: its tables, functions, its own row
    among the plugins, its version, and its plug-in (grants, history, the fence)."""
    o, parts = install_sql("schema/cortex")
    parts.append(("schema/cortex/owner.toml plugin",
                  f"INSERT INTO cortex.plugins (id, kind, namespace, name, version, requires_cortex) "
                  f"VALUES ('cortex', 'core', 'cortex', 'SchemaForge cortex', {o['version']}, {o['version']});\n"
                  f"INSERT INTO cortex.schema_migrations (plugin, version) VALUES ('cortex', {o['version']});\n"
                  f"SELECT cortex.plug_in('cortex');"))
    return parts


def script(parts, role="cortex_owner"):
    """One psql script of the parts, in one transaction, as the role, each part labelled so a failure names its file."""
    return f"BEGIN;\nSET ROLE {role};\n" + "".join(f"\\echo @@ {label}\n{sql}\n" for label, sql in parts) + "COMMIT;\n"
