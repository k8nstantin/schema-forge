"""Plugging a plugin into schema_forge, the five steps of schema/cortex/functions/plug_in.sql, each as the role it
belongs to: the same here, in the tests, and in tools/local/plug_in.py.

  1. the superuser makes <ns>_owner (no login) and <ns>_service (login), and the schema, owned by <ns>_owner
  2. cortex_owner adds its row to cortex.plugins and opens the cortex to its owner (cortex.open_to)
  3. <ns>_owner makes its tables and functions, and lets cortex_owner see its namespace (USAGE), to check it
  4. cortex_owner loads its seeds (engine, versions, flavors, kinds, plugin_tables), then cortex.plug_in
  5. <ns>_owner runs cortex.fit_plugin: its grants, history and fence"""
import os
import tomllib

from sf.schema import ROOT, comments, script


def package(folder):
    """A plugin's package (engines/<engine>): its card, its tables (each with its comments in the database) and
    functions as its owner makes them, and its seeds as cortex_owner loads them."""
    card = tomllib.load(open(os.path.join(ROOT, folder, "owner.toml"), "rb"))
    ns, tables = card["namespace"], []
    for t in card["tables"]:
        path = f"{folder}/schema/{t}.sql"
        text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        tables += [(path, text), (path + " comments", "\n".join(comments(ns, t, text)))]
    for f in card.get("functions", []):
        path = f"{folder}/schema/functions/{f}.sql"
        tables.append((path, open(os.path.join(ROOT, path), encoding="utf-8").read()))
    seeds = [(f"{folder}/seeds/{s}.sql", open(os.path.join(ROOT, folder, "seeds", f"{s}.sql"), encoding="utf-8").read()) for s in card.get("seeds", [])]
    return card, tables, seeds


def plug_folder(store, folder, password=None):
    """Plugs the plugin of a package folder into the store, the five steps; returns its card."""
    card, tables, seeds = package(folder)
    plug(store, card["id"], card["kind"], card["namespace"], card["name"], card["version"], card["requires_cortex"], tables, seeds, password)
    return card


def engine_folders():
    """Every engine package of the repository (engines/<engine> with its card), in name order."""
    root = os.path.join(ROOT, "engines")
    return sorted(f"engines/{d}" for d in os.listdir(root) if os.path.exists(os.path.join(root, d, "owner.toml"))) if os.path.isdir(root) else []


def install_all(store, passwords=None):
    """The whole schema_forge, as the installer makes it: the cortex, then every engine package plugged in. passwords
    maps a plugin's service account to its password (a real install); without, the accounts sign in with none (a test
    container). Returns the cards of the plugins plugged in."""
    from sf.schema import cortex_sql
    store.sql(script(cortex_sql()))
    cards = []
    for folder in engine_folders():
        card, _, _ = package(folder)
        cards.append(plug_folder(store, folder, (passwords or {}).get(f"{card['namespace']}_service")))
    return cards


def plug(store, plugin, kind, namespace, name, version, requires_cortex, tables, seeds, password=None):
    """tables: (label, SQL) parts run as the plugin's owner; seeds: (label, SQL) parts run as cortex_owner."""
    owner, service = f"{namespace}_owner", f"{namespace}_service"
    login = f"LOGIN PASSWORD '{password}'" if password else "LOGIN"
    store.sql(f"CREATE ROLE {owner} NOLOGIN; CREATE ROLE {service} {login}; GRANT CONNECT ON DATABASE schema_forge TO {service};"
              f"CREATE SCHEMA {namespace} AUTHORIZATION {owner};")
    store.sql(script([("cortex.plugins", f"INSERT INTO cortex.plugins (id, kind, namespace, name, version, requires_cortex) "
                                         f"VALUES ('{plugin}', '{kind}', '{namespace}', '{name}', {version}, {requires_cortex});"
                                         f"INSERT INTO cortex.schema_migrations (plugin, version) VALUES ('{plugin}', {version});"
                                         f"SELECT cortex.open_to('{plugin}');")]))
    # step 3: its tables, and the cortex's owner let in to see them (to check them at step 4)
    store.sql(script(list(tables) + [(f"{namespace} open to cortex_owner", f"GRANT USAGE ON SCHEMA {namespace} TO cortex_owner;")], role=owner))
    store.sql(script(list(seeds) + [("cortex.plug_in", f"SELECT cortex.plug_in('{plugin}');")]))
    store.sql(script([("cortex.fit_plugin", f"SELECT cortex.fit_plugin('{plugin}');")], role=owner))
