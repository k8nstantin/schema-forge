"""Plugging a plugin into schema_forge, the five steps of schema/cortex/functions/plug_in.sql, each as the role it
belongs to: the same here, in the tests, and in tools/local/plug_in.py.

  1. the superuser makes <ns>_owner (no login) and <ns>_service (login), and the schema, owned by <ns>_owner
  2. cortex_owner adds its row to cortex.plugins and opens the cortex to its owner (cortex.open_to)
  3. <ns>_owner makes its tables and functions, and lets cortex_owner see its namespace (USAGE), to check it
  4. cortex_owner loads its seeds (engine, versions, flavors, kinds, plugin_tables), then cortex.plug_in
  5. <ns>_owner runs cortex.fit_plugin: its grants, history and fence"""
from sf.schema import script


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
