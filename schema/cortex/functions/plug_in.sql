-- How a plugin fits into schema_forge, and the cortex itself. Every namespace has the same two roles, named after it
-- (decision consistent-roles): <namespace>_owner owns it and never signs in; <namespace>_service is its service account.
-- The cortex has two more: cortex_agent (the coding agent) and cortex_reader (reads only).
--
-- Who may do what (least privilege):
--   cortex_reader        reads everything; writes nothing
--   cortex_service (app) reads everything; writes designs, branches and the model; opens, ends and numbers turns,
--                        adds operations; locks versions; never writes the log, the plugs or any plugin's tables
--   cortex_agent         as cortex_service, but reads designs, branches and locked versions only
--   <plugin>_service     the least its work needs: reads its declarations and its own engine's designs; reads and
--                        writes the model and its own namespace's rows for its own engine's designs only (row-level
--                        security); adds its operations to the turn the app opened; nothing of turns, branches,
--                        locked versions, the plugs or the log; the only writer of its namespace (decision plugin-writes)
--   <plugin>_owner       owns its namespace and runs its migrations; may reference the cortex tables its own extend,
--                        nothing else of the cortex
--   the log (cortex.row_changes) is written only by cortex.log_row; nobody rewrites it
--
-- Plugging in, done by tools/local/plug_in.py, in order:
--   1. the superuser makes <ns>_owner and <ns>_service
--   2. cortex_owner makes the schema, owned by <ns>_owner, its row in cortex.plugins, and cortex.open_to(plugin)
--   3. <ns>_owner makes its tables and functions, and lets cortex_owner see its namespace (USAGE), to check it
--   4. cortex_owner loads its seeds (engine, versions, flavors, kinds, plugin_tables), then cortex.plug_in(plugin)
--   5. <ns>_owner runs cortex.fit_plugin(plugin): only a table's owner may put the fence on it

-- the fence's check: is the design of the engine whose plugin's service account is asking; the policy passes the asking
-- account (current_user where the policy runs), since inside this function current_user is the cortex's owner
CREATE FUNCTION cortex.owns_design(design uuid, asking name) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
  SELECT EXISTS (SELECT 1 FROM cortex.designs g JOIN cortex.engines e ON e.id = g.engine JOIN cortex.plugins p ON p.id = e.plugin
                  WHERE g.id = owns_design.design AND p.account = owns_design.asking)
$$;

-- every table of a plugin's namespace is registered, of a design, keyed (design, id), and extends what it says
CREATE FUNCTION cortex.check_plugin(plugin text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  ns text := (SELECT namespace FROM cortex.plugins WHERE id = plugin);
  t  record;
BEGIN
  FOR t IN SELECT c.oid, c.relname, pt.name AS registered, pt.extends FROM pg_class c
             LEFT JOIN cortex.plugin_tables pt ON pt.plugin = check_plugin.plugin AND pt.name = c.relname
            WHERE c.relnamespace = ns::regnamespace AND c.relkind = 'r' LOOP
    IF t.registered IS NULL THEN
      RAISE EXCEPTION '%.% is not in cortex.plugin_tables', ns, t.relname;
    END IF;
    IF (SELECT count(*) FROM pg_attribute WHERE attrelid = t.oid AND attname IN ('id', 'design') AND atttypid = 'uuid'::regtype AND attnotnull) <> 2 THEN
      RAISE EXCEPTION '%.% needs id and design, both UUID NOT NULL', ns, t.relname;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = t.oid AND k.contype = 'u'
                      AND k.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = t.oid AND attname = 'design'),
                                           (SELECT attnum FROM pg_attribute WHERE attrelid = t.oid AND attname = 'id')]::int2[]) THEN
      RAISE EXCEPTION '%.% needs UNIQUE (design, id)', ns, t.relname;
    END IF;
    IF t.extends IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = t.oid AND k.contype = 'f'
         AND k.confrelid = ('cortex.' || t.extends)::regclass
         AND k.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = t.oid AND attname = 'design'),
                              (SELECT attnum FROM pg_attribute WHERE attrelid = t.oid AND attname = 'id')]::int2[]) THEN
      RAISE EXCEPTION '%.% extends cortex.% but has no FOREIGN KEY (design, id) to it', ns, t.relname, t.extends;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM cortex.plugin_tables pt WHERE pt.plugin = check_plugin.plugin
              AND to_regclass(format('%I.%I', ns, pt.name)) IS NULL) THEN
    RAISE EXCEPTION 'cortex.plugin_tables names a table % lacks', ns;
  END IF;
END $$;

-- history: every change of a row of these tables goes to the log
CREATE FUNCTION cortex.attach_history(ns text, tabs text[]) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS log_row ON %I.%I', ns, t);
    EXECUTE format('CREATE TRIGGER log_row AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cortex.log_row()', ns, t);
  END LOOP;
END $$;

-- the fence: the cortex's accounts see every design; a plugin's service account only its engine's
CREATE FUNCTION cortex.fence(ns text, tabs text[]) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  t   text;
  key text;
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    key := CASE WHEN ns = 'cortex' AND t = 'designs' THEN 'id' ELSE 'design' END;
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', ns, t);
    EXECUTE format('DROP POLICY IF EXISTS everyone ON %I.%I', ns, t);
    -- cortex_owner among them for cortex.undo, the one generic writer every engine's rows share, called by the app and the agent
    EXECUTE format('CREATE POLICY everyone ON %I.%I TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true)', ns, t);
    EXECUTE format('DROP POLICY IF EXISTS own_engine ON %I.%I', ns, t);
    EXECUTE format('CREATE POLICY own_engine ON %I.%I TO PUBLIC USING (cortex.owns_design(%I, current_user)) WITH CHECK (cortex.owns_design(%I, current_user))', ns, t, key, key);
  END LOOP;
END $$;

-- step 2: what a plugin's owner needs of the cortex to build on it: to see it, and to reference the tables its own extend
CREATE FUNCTION cortex.open_to(plugin text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  p cortex.plugins;
BEGIN
  SELECT * INTO STRICT p FROM cortex.plugins WHERE id = plugin;
  EXECUTE format('GRANT USAGE ON SCHEMA cortex TO %I', p.namespace || '_owner');
  EXECUTE format('GRANT SELECT ON cortex.plugins, cortex.plugin_tables TO %I', p.namespace || '_owner');
  EXECUTE format('GRANT REFERENCES ON cortex.designs, cortex.namespaces, cortex.objects, cortex.columns, cortex.indexes, cortex.index_parts, cortex.constraints TO %I',
                 p.namespace || '_owner');
  EXECUTE format('GRANT EXECUTE ON FUNCTION cortex.log_row(), cortex.owns_design(uuid, name), cortex.attach_history(text, text[]), cortex.fence(text, text[]), cortex.fit_plugin(text) TO %I',
                 p.namespace || '_owner');
END $$;

-- step 4: the cortex's side: the plugin's tables checked, its service account given its rights on the cortex
CREATE FUNCTION cortex.plug_in(plugin text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  p     cortex.plugins;
  model text[] := ARRAY['namespaces', 'objects', 'columns', 'indexes', 'index_parts', 'constraints', 'constraint_columns', 'dependencies'];
  design_tables text[] := ARRAY['designs', 'branches', 'turns', 'operations', 'row_changes', 'locked_versions',
                                'namespaces', 'objects', 'columns', 'indexes', 'index_parts', 'constraints', 'constraint_columns', 'dependencies'];
BEGIN
  SELECT * INTO STRICT p FROM cortex.plugins WHERE id = plugin;
  IF p.kind = 'core' THEN
    EXECUTE 'REVOKE ALL ON SCHEMA cortex FROM PUBLIC';
    EXECUTE 'GRANT USAGE ON SCHEMA cortex TO cortex_service, cortex_agent, cortex_reader';
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA cortex FROM PUBLIC';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA cortex TO cortex_service, cortex_agent, cortex_reader';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON cortex.designs, cortex.branches TO cortex_service';
    EXECUTE 'GRANT INSERT ON cortex.locked_versions TO cortex_service';
    EXECUTE 'GRANT INSERT, UPDATE ON cortex.turns TO cortex_service, cortex_agent';
    EXECUTE 'GRANT INSERT ON cortex.operations TO cortex_service, cortex_agent';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON ' || (SELECT string_agg('cortex.' || m, ', ') FROM unnest(model) m) || ' TO cortex_service, cortex_agent';
    PERFORM cortex.attach_history('cortex', model);
    PERFORM cortex.fence('cortex', design_tables);
    EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cortex FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION cortex.undo(uuid) TO cortex_service, cortex_agent';
    EXECUTE 'GRANT EXECUTE ON FUNCTION cortex.owns_design(uuid, name) TO cortex_service, cortex_agent, cortex_reader';
    RETURN;
  END IF;
  PERFORM cortex.check_plugin(plugin);
  -- its service account, the least its work needs (importing a live server into a design, writing a design back):
  -- reads its declarations and its engine's designs; reads and writes the model of them; adds its operations to the
  -- turn the app opened. Nothing of turns, branches, locked versions, the plugs or the log: the app opens and ends
  -- turns; foreign keys into what it cannot read are checked by the database as the tables' owner.
  EXECUTE format('GRANT USAGE ON SCHEMA cortex TO %I', p.account);
  EXECUTE format('GRANT SELECT ON cortex.engines, cortex.engine_versions, cortex.engine_flavors, cortex.object_kinds, cortex.designs TO %I', p.account);
  EXECUTE format('GRANT SELECT, INSERT ON cortex.operations TO %I', p.account);
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ' || (SELECT string_agg('cortex.' || m, ', ') FROM unnest(model) m) || format(' TO %I', p.account);
  EXECUTE format('GRANT EXECUTE ON FUNCTION cortex.owns_design(uuid, name) TO %I', p.account);
END $$;

-- step 5: the plugin's side, run as its owner: its tables written by its service account alone, read by the cortex's
-- accounts, every change logged, every row fenced to its engine's designs
CREATE FUNCTION cortex.fit_plugin(plugin text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  p    cortex.plugins;
  tabs text[];
BEGIN
  SELECT * INTO STRICT p FROM cortex.plugins WHERE id = plugin;
  IF current_user <> p.namespace || '_owner' THEN
    RAISE EXCEPTION 'fit_plugin %: run it as %, the owner of %', plugin, p.namespace || '_owner', p.namespace;
  END IF;
  SELECT coalesce(array_agg(name ORDER BY name), '{}') INTO tabs FROM cortex.plugin_tables WHERE plugin_tables.plugin = fit_plugin.plugin;
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', p.namespace);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO cortex_service, cortex_agent, cortex_reader, %I', p.namespace, p.account);
  EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC', p.namespace);
  EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', p.namespace);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO cortex_service, cortex_agent, cortex_reader', p.namespace);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', p.namespace, p.account);
  -- the cortex's owner, for cortex.undo alone (it signs in as nobody; undo runs as it for the app and the agent)
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO cortex_owner', p.namespace);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO cortex_owner', p.namespace);
  PERFORM cortex.attach_history(p.namespace, tabs);
  PERFORM cortex.fence(p.namespace, tabs);
END $$;

COMMENT ON FUNCTION cortex.owns_design(uuid, name) IS 'true when the asking account is the service account of the design''s engine''s plugin: the fence of row-level security';
COMMENT ON FUNCTION cortex.check_plugin(text) IS 'refuses a plugin whose namespace holds a table that is not a plug: unregistered, not of a design, not keyed (design, id), or not extending what it says';
COMMENT ON FUNCTION cortex.attach_history(text, text[]) IS 'puts cortex.log_row on every table named, so every change of their rows is logged';
COMMENT ON FUNCTION cortex.fence(text, text[]) IS 'row-level security on every table named: the cortex''s accounts see every design, a plugin''s service account only its engine''s';
COMMENT ON FUNCTION cortex.open_to(text) IS 'what a plugin''s owner needs of the cortex to build on it: to see it and to reference the tables its own extend';
COMMENT ON FUNCTION cortex.plug_in(text) IS 'the cortex''s side of plugging in: the cortex''s own grants, history and fence; or a plugin''s tables checked and its service account given its rights on the cortex';
COMMENT ON FUNCTION cortex.fit_plugin(text) IS 'the plugin''s side of plugging in, run as its owner: its tables written by its service account alone, read by the cortex''s accounts, logged and fenced';
