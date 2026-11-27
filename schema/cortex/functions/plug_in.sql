-- cortex.plug_in: fits a plugin into schema_forge in one call: checks its tables against the plugs, attaches history,
-- gives the grants, fences its account to its engine's designs. Run as the cortex's owner by the plug-in tool, after the
-- plugin's row in cortex.plugins, its tables and its plugin_tables rows are loaded. cortex.plug_in('cortex') fits the
-- cortex itself.

-- the fence's check: is the design of the engine whose plugin's account is asking; the policy passes the asking
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

-- the fence: the app, the agent and the reader see every design; a plugin's account only its engine's
CREATE FUNCTION cortex.fence(ns text, tabs text[]) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  t   text;
  key text;
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    key := CASE WHEN ns = 'cortex' AND t = 'designs' THEN 'id' ELSE 'design' END;
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', ns, t);
    EXECUTE format('DROP POLICY IF EXISTS everyone ON %I.%I', ns, t);
    EXECUTE format('CREATE POLICY everyone ON %I.%I TO sf_service, sf_agent, sf_reader USING (true) WITH CHECK (true)', ns, t);
    EXECUTE format('DROP POLICY IF EXISTS own_engine ON %I.%I', ns, t);
    EXECUTE format('CREATE POLICY own_engine ON %I.%I TO PUBLIC USING (cortex.owns_design(%I, current_user)) WITH CHECK (cortex.owns_design(%I, current_user))', ns, t, key, key);
  END LOOP;
END $$;

CREATE FUNCTION cortex.plug_in(plugin text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, cortex AS $$
DECLARE
  p     cortex.plugins;
  tabs  text[];
  model text[] := ARRAY['namespaces', 'objects', 'columns', 'indexes', 'index_parts', 'constraints', 'constraint_columns', 'dependencies'];
  design_tables text[] := ARRAY['designs', 'branches', 'turns', 'operations', 'row_changes', 'locked_versions',
                                'namespaces', 'objects', 'columns', 'indexes', 'index_parts', 'constraints', 'constraint_columns', 'dependencies'];
BEGIN
  SELECT * INTO STRICT p FROM cortex.plugins WHERE id = plugin;
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', p.namespace);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO sf_service, sf_agent, sf_reader', p.namespace);
  EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC', p.namespace);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sf_service, sf_agent, sf_reader', p.namespace);

  IF p.kind = 'core' THEN
    -- the declarations and the log are read only; the app writes designs and versions; the writers the model and turns
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON cortex.designs, cortex.branches TO sf_service';
    EXECUTE 'GRANT INSERT ON cortex.locked_versions TO sf_service';
    EXECUTE 'GRANT INSERT, UPDATE ON cortex.turns TO sf_service, sf_agent';
    EXECUTE 'GRANT INSERT ON cortex.operations TO sf_service, sf_agent';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON ' || (SELECT string_agg('cortex.' || m, ', ') FROM unnest(model) m) || ' TO sf_service, sf_agent';
    PERFORM cortex.attach_history('cortex', model);
    PERFORM cortex.fence('cortex', design_tables);
    EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cortex FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION cortex.undo(uuid) TO sf_service, sf_agent';
    EXECUTE 'GRANT EXECUTE ON FUNCTION cortex.owns_design(uuid, name) TO sf_service, sf_agent, sf_reader';
    RETURN;
  END IF;

  PERFORM cortex.check_plugin(plugin);
  SELECT coalesce(array_agg(name ORDER BY name), '{}') INTO tabs FROM cortex.plugin_tables WHERE plugin_tables.plugin = plug_in.plugin;
  -- its own account: reads the declarations and its engine's designs; writes the model, its namespace, turns and operations for them
  EXECUTE format('GRANT USAGE ON SCHEMA cortex, %I TO %I', p.namespace, p.account);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA cortex TO %I', p.account);
  EXECUTE format('REVOKE SELECT ON cortex.row_changes FROM %I', p.account);
  EXECUTE format('GRANT INSERT, UPDATE ON cortex.turns TO %I', p.account);
  EXECUTE format('GRANT INSERT ON cortex.operations TO %I', p.account);
  EXECUTE 'GRANT INSERT, UPDATE, DELETE ON ' || (SELECT string_agg('cortex.' || m, ', ') FROM unnest(model) m) || format(' TO %I', p.account);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', p.namespace, p.account);
  EXECUTE format('GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sf_service, sf_agent', p.namespace);
  EXECUTE format('GRANT EXECUTE ON FUNCTION cortex.owns_design(uuid, name) TO %I', p.account);
  PERFORM cortex.attach_history(p.namespace, tabs);
  PERFORM cortex.fence(p.namespace, tabs);
END $$;

COMMENT ON FUNCTION cortex.owns_design(uuid, name) IS 'true when the current account is the service account of the design''s engine''s plugin: the fence of row-level security';
COMMENT ON FUNCTION cortex.check_plugin(text) IS 'refuses a plugin whose namespace holds a table that is not a plug: unregistered, not of a design, not keyed (design, id), or not extending what it says';
COMMENT ON FUNCTION cortex.attach_history(text, text[]) IS 'puts cortex.log_row on every table named, so every change of their rows is logged';
COMMENT ON FUNCTION cortex.fence(text, text[]) IS 'row-level security on every table named: the app, the agent and the reader see every design, a plugin''s account only its engine''s';
COMMENT ON FUNCTION cortex.plug_in(text) IS 'fits a plugin or the cortex into schema_forge: checks its tables, attaches history, gives the grants, fences its account';
