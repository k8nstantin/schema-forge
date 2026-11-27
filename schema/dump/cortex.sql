--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: cortex; Type: SCHEMA; Schema: -; Owner: cortex_owner
--

CREATE SCHEMA cortex;


ALTER SCHEMA cortex OWNER TO cortex_owner;

--
-- Name: attach_history(text, text[]); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.attach_history(ns text, tabs text[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS log_row ON %I.%I', ns, t);
    EXECUTE format('CREATE TRIGGER log_row AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cortex.log_row()', ns, t);
  END LOOP;
END $$;


ALTER FUNCTION cortex.attach_history(ns text, tabs text[]) OWNER TO cortex_owner;

--
-- Name: FUNCTION attach_history(ns text, tabs text[]); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.attach_history(ns text, tabs text[]) IS 'puts cortex.log_row on every table named, so every change of their rows is logged';


--
-- Name: check_design(); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.check_design() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM cortex.engine_flavors f WHERE f.engine = NEW.engine AND f.flavor = NEW.flavor
              AND coalesce(f.refuses -> 'versions', '[]') ? NEW.engine_version) THEN
    RAISE EXCEPTION '% does not run % %', (SELECT name FROM cortex.engine_flavors WHERE engine = NEW.engine AND flavor = NEW.flavor), NEW.engine, NEW.engine_version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;


ALTER FUNCTION cortex.check_design() OWNER TO cortex_owner;

--
-- Name: FUNCTION check_design(); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.check_design() IS 'refuses a design of a version its flavor does not run';


--
-- Name: check_object(); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.check_object() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
DECLARE
  bad record;
BEGIN
  SELECT d.engine_version, d.flavor, k.since, k."until", f.refuses INTO bad
    FROM cortex.designs d
    JOIN cortex.object_kinds k ON k.engine = d.engine AND k.kind = NEW.kind
    JOIN cortex.engine_versions v ON v.engine = d.engine AND v.version = d.engine_version
    JOIN cortex.engine_flavors f ON f.engine = d.engine AND f.flavor = d.flavor
    LEFT JOIN cortex.engine_versions s ON s.engine = d.engine AND s.version = k.since
    LEFT JOIN cortex.engine_versions u ON u.engine = d.engine AND u.version = k."until"
   WHERE d.id = NEW.design
     AND (v.position < s.position OR v.position > u.position OR coalesce(f.refuses -> 'kinds', '[]') ? NEW.kind);
  IF FOUND THEN
    IF bad.refuses -> 'kinds' ? NEW.kind THEN
      RAISE EXCEPTION '% refuses a % (%)', bad.flavor, NEW.kind, NEW.name USING ERRCODE = 'check_violation';
    END IF;
    RAISE EXCEPTION '% % has no % (from %, until %): %', NEW.engine, bad.engine_version, NEW.kind, coalesce(bad.since, 'the first'), coalesce(bad."until", 'the last'), NEW.name
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;


ALTER FUNCTION cortex.check_object() OWNER TO cortex_owner;

--
-- Name: FUNCTION check_object(); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.check_object() IS 'refuses an object of a kind its design''s version lacks or its design''s flavor refuses';


--
-- Name: check_plugin(text); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.check_plugin(plugin text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
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


ALTER FUNCTION cortex.check_plugin(plugin text) OWNER TO cortex_owner;

--
-- Name: FUNCTION check_plugin(plugin text); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.check_plugin(plugin text) IS 'refuses a plugin whose namespace holds a table that is not a plug: unregistered, not of a design, not keyed (design, id), or not extending what it says';


--
-- Name: designs_of(name); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.designs_of(asking name) RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
  SELECT g.id FROM cortex.designs g JOIN cortex.engines e ON e.id = g.engine JOIN cortex.plugins p ON p.id = e.plugin
   WHERE p.account = designs_of.asking
$$;


ALTER FUNCTION cortex.designs_of(asking name) OWNER TO cortex_owner;

--
-- Name: FUNCTION designs_of(asking name); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.designs_of(asking name) IS 'the designs of the engine whose plugin''s service account is asking: the fence of row-level security, worked out once per statement';


--
-- Name: fence(text, text[]); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.fence(ns text, tabs text[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
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
    EXECUTE format('CREATE POLICY own_engine ON %I.%I TO PUBLIC USING (%I IN (SELECT cortex.designs_of(current_user))) WITH CHECK (%I IN (SELECT cortex.designs_of(current_user)))', ns, t, key, key);
  END LOOP;
END $$;


ALTER FUNCTION cortex.fence(ns text, tabs text[]) OWNER TO cortex_owner;

--
-- Name: FUNCTION fence(ns text, tabs text[]); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.fence(ns text, tabs text[]) IS 'row-level security on every table named: the cortex''s accounts see every design, a plugin''s service account only its engine''s';


--
-- Name: fit_plugin(text); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.fit_plugin(plugin text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
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


ALTER FUNCTION cortex.fit_plugin(plugin text) OWNER TO cortex_owner;

--
-- Name: FUNCTION fit_plugin(plugin text); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.fit_plugin(plugin text) IS 'the plugin''s side of plugging in, run as its owner: its tables written by its service account alone, read by the cortex''s accounts, logged and fenced';


--
-- Name: log_row(); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.log_row() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
DECLARE
  op   uuid := nullif(current_setting('schema_forge.operation', true), '')::uuid;
  old_row jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  new_row jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM cortex.designs WHERE id = (old_row ->> 'design')::uuid) THEN
    RETURN NULL;   -- its design is being deleted: the design's whole log goes with it
  END IF;
  IF op IS NULL THEN
    RAISE EXCEPTION 'a change to %.% outside an operation: set schema_forge.operation first', TG_TABLE_SCHEMA, TG_TABLE_NAME
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' AND old_row = new_row THEN
    RETURN NULL;
  END IF;
  INSERT INTO cortex.row_changes (design, operation, tab, row_id, action, before, after)
  VALUES ((coalesce(new_row, old_row) ->> 'design')::uuid, op, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
          (coalesce(new_row, old_row) ->> 'id')::uuid, lower(TG_OP), old_row, new_row);
  RETURN NULL;
END $$;


ALTER FUNCTION cortex.log_row() OWNER TO cortex_owner;

--
-- Name: FUNCTION log_row(); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.log_row() IS 'writes every change of a model or plugin row to cortex.row_changes under the session''s operation; refuses a change made outside one';


--
-- Name: notify_turn(); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.notify_turn() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
BEGIN
  IF NEW.state = 'committed' AND OLD.state = 'open' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.design::text, 0));
    NEW.seq := coalesce((SELECT max(seq) FROM cortex.turns WHERE design = NEW.design), 0) + 1;
    PERFORM pg_notify('schema_forge_turns', NEW.design::text || ':' || NEW.seq);
  END IF;
  RETURN NEW;
END $$;


ALTER FUNCTION cortex.notify_turn() OWNER TO cortex_owner;

--
-- Name: FUNCTION notify_turn(); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.notify_turn() IS 'numbers a turn in its design''s commit order as it commits, and rings schema_forge_turns with the design and the number';


--
-- Name: open_to(text); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.open_to(plugin text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
DECLARE
  p cortex.plugins;
BEGIN
  SELECT * INTO STRICT p FROM cortex.plugins WHERE id = plugin;
  EXECUTE format('GRANT USAGE ON SCHEMA cortex TO %I', p.namespace || '_owner');
  EXECUTE format('GRANT SELECT ON cortex.plugins, cortex.plugin_tables TO %I', p.namespace || '_owner');
  EXECUTE format('GRANT REFERENCES ON cortex.designs, cortex.namespaces, cortex.objects, cortex.columns, cortex.indexes, cortex.index_parts, cortex.constraints, cortex.constraint_columns TO %I',
                 p.namespace || '_owner');
  EXECUTE format('GRANT EXECUTE ON FUNCTION cortex.log_row(), cortex.designs_of(name), cortex.attach_history(text, text[]), cortex.fence(text, text[]), cortex.fit_plugin(text) TO %I',
                 p.namespace || '_owner');
END $$;


ALTER FUNCTION cortex.open_to(plugin text) OWNER TO cortex_owner;

--
-- Name: FUNCTION open_to(plugin text); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.open_to(plugin text) IS 'what a plugin''s owner needs of the cortex to build on it: to see it and to reference the tables its own extend';


--
-- Name: plug_in(text); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.plug_in(plugin text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'cortex'
    AS $$
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
    EXECUTE 'GRANT EXECUTE ON FUNCTION cortex.designs_of(name) TO cortex_service, cortex_agent, cortex_reader';
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
  EXECUTE format('GRANT EXECUTE ON FUNCTION cortex.designs_of(name) TO %I', p.account);
END $$;


ALTER FUNCTION cortex.plug_in(plugin text) OWNER TO cortex_owner;

--
-- Name: FUNCTION plug_in(plugin text); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.plug_in(plugin text) IS 'the cortex''s side of plugging in: the cortex''s own grants, history and fence; or a plugin''s tables checked and its service account given its rights on the cortex';


--
-- Name: undo(uuid); Type: FUNCTION; Schema: cortex; Owner: cortex_owner
--

CREATE FUNCTION cortex.undo(turn uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'cortex'
    AS $_$
DECLARE
  op    uuid := nullif(current_setting('schema_forge.operation', true), '')::uuid;
  d     uuid := (SELECT design FROM cortex.turns WHERE id = undo.turn);
  gone  uuid[] := '{}';
  x     record;
  c     record;
  cols  text;
  n     integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cortex.turns WHERE id = undo.turn AND state = 'committed') THEN
    RAISE EXCEPTION 'undo: turn % is not a committed turn', undo.turn;
  END IF;
  IF op IS NULL THEN
    RAISE EXCEPTION 'undo: outside an operation: set schema_forge.operation first' USING ERRCODE = 'insufficient_privilege';
  END IF;
  FOR c IN SELECT r.* FROM cortex.row_changes r JOIN cortex.operations o ON o.id = r.operation
            WHERE o.turn = undo.turn ORDER BY r.id DESC LOOP
    SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols FROM pg_attribute
     WHERE attrelid = c.tab::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = '';
    IF c.action = 'insert' THEN
      EXECUTE format('DELETE FROM %s WHERE id = $1', c.tab) USING c.row_id;
    ELSIF c.action = 'delete' THEN
      EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1)', c.tab, cols, cols, c.tab) USING c.before;
    ELSE
      EXECUTE format('UPDATE %s SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::%s, $1)) WHERE id = $2', c.tab, cols, cols, c.tab)
        USING c.before, c.row_id;
    END IF;
    n := n + 1;
  END LOOP;
  UPDATE cortex.operations SET undoes = undo.turn WHERE id = op;
  -- every turn's state from the undos in effect, newest first (the open turn, this undo's, is the newest)
  FOR x IN SELECT id, state FROM cortex.turns WHERE design = d AND state IN ('open', 'committed', 'undone')
            ORDER BY seq DESC NULLS FIRST LOOP
    IF x.id = ANY (gone) THEN
      IF x.state = 'committed' THEN
        UPDATE cortex.turns SET state = 'undone' WHERE id = x.id;
      END IF;
    ELSE
      IF x.state = 'undone' THEN
        UPDATE cortex.turns SET state = 'committed' WHERE id = x.id;
      END IF;
      gone := gone || ARRAY(SELECT o.undoes FROM cortex.operations o WHERE o.turn = x.id AND o.undoes IS NOT NULL);
    END IF;
  END LOOP;
  RETURN n;
END $_$;


ALTER FUNCTION cortex.undo(turn uuid) OWNER TO cortex_owner;

--
-- Name: FUNCTION undo(turn uuid); Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON FUNCTION cortex.undo(turn uuid) IS 'undoes a committed turn: the inverse of each of its row changes, newest first, logged under the current operation, which records the turn undone; then marks every turn of the design undone or committed by whether an undo in effect undid it';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: branches; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.branches (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT branches_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT branches_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100)))
);


ALTER TABLE cortex.branches OWNER TO cortex_owner;

--
-- Name: TABLE branches; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.branches IS 'the lines of work of a design; a design has its first, main, from when it is made, and its head is its newest committed turn.';


--
-- Name: COLUMN branches.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.branches.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN branches.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.branches.design IS 'the design';


--
-- Name: COLUMN branches.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.branches.name IS 'as people call it (main)';


--
-- Name: COLUMN branches.created_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.branches.created_at IS 'when it was made';


--
-- Name: columns; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.columns (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    object uuid NOT NULL,
    "position" integer NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    nullable boolean NOT NULL,
    default_value text,
    generated_expression text,
    generated_stored boolean,
    "collation" text,
    comment text,
    CONSTRAINT columns_check CHECK (((generated_expression IS NULL) = (generated_stored IS NULL))),
    CONSTRAINT columns_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT columns_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT columns_position_check CHECK (("position" >= 1)),
    CONSTRAINT columns_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.columns OWNER TO cortex_owner;

--
-- Name: TABLE columns; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.columns IS 'the columns of an object that has them (a table, a view), in order, with what every engine says of a column; what only one engine says is its plugin''s, with the same id.';


--
-- Name: COLUMN columns.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.id IS 'a UUIDv7 made with its row, kept when the name changes';


--
-- Name: COLUMN columns.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.design IS 'the design';


--
-- Name: COLUMN columns.object; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.object IS 'the object it belongs to';


--
-- Name: COLUMN columns."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns."position" IS 'its place in the object, as the server orders it: 1, 2, 3';


--
-- Name: COLUMN columns.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.name IS 'as the engine names it (total)';


--
-- Name: COLUMN columns.type; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.type IS 'its type as the engine writes it at the design''s version (decimal(12,2))';


--
-- Name: COLUMN columns.nullable; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.nullable IS 'true when it may hold null';


--
-- Name: COLUMN columns.default_value; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.default_value IS 'its default as the engine writes it: a literal quoted, an expression as written; NULL for none';


--
-- Name: COLUMN columns.generated_expression; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.generated_expression IS 'the expression it is computed from, as the engine writes it; NULL when not computed';


--
-- Name: COLUMN columns.generated_stored; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.generated_stored IS 'for a computed column, true when stored, false when computed as read; NULL otherwise';


--
-- Name: COLUMN columns."collation"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns."collation" IS 'its collation where it is not its object''s, as the engine names it; NULL for the object''s';


--
-- Name: COLUMN columns.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.columns.comment IS 'what it holds: written into its SQL';


--
-- Name: constraint_columns; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.constraint_columns (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    "constraint" uuid NOT NULL,
    "position" integer NOT NULL,
    "column" uuid NOT NULL,
    to_column uuid,
    CONSTRAINT constraint_columns_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT constraint_columns_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.constraint_columns OWNER TO cortex_owner;

--
-- Name: TABLE constraint_columns; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.constraint_columns IS 'the columns of a key, in order; for a foreign key, each with the column of the other table it refers to.';


--
-- Name: COLUMN constraint_columns.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN constraint_columns.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns.design IS 'the design';


--
-- Name: COLUMN constraint_columns."constraint"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns."constraint" IS 'the key';


--
-- Name: COLUMN constraint_columns."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns."position" IS 'its place in the key: 1 first';


--
-- Name: COLUMN constraint_columns."column"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns."column" IS 'a column of the key''s table';


--
-- Name: COLUMN constraint_columns.to_column; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraint_columns.to_column IS 'for a foreign key, the column it refers to; NULL otherwise';


--
-- Name: constraints; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.constraints (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    object uuid NOT NULL,
    "position" integer NOT NULL,
    name text,
    kind text NOT NULL,
    expression text,
    to_object uuid,
    on_delete text,
    on_update text,
    enforced boolean DEFAULT true NOT NULL,
    "deferrable" boolean DEFAULT false NOT NULL,
    initially_deferred boolean DEFAULT false NOT NULL,
    CONSTRAINT constraints_check CHECK (((kind = 'check'::text) = (expression IS NOT NULL))),
    CONSTRAINT constraints_check1 CHECK (((kind = 'foreign'::text) = (to_object IS NOT NULL))),
    CONSTRAINT constraints_check2 CHECK (((kind = 'foreign'::text) OR ((on_delete IS NULL) AND (on_update IS NULL)))),
    CONSTRAINT constraints_check3 CHECK (("deferrable" OR (NOT initially_deferred))),
    CONSTRAINT constraints_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT constraints_kind_check CHECK ((kind = ANY (ARRAY['primary'::text, 'unique'::text, 'check'::text, 'foreign'::text]))),
    CONSTRAINT constraints_on_delete_check CHECK ((on_delete = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT constraints_on_update_check CHECK ((on_update = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT constraints_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.constraints OWNER TO cortex_owner;

--
-- Name: TABLE constraints; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.constraints IS 'a table''s primary key, unique keys, checks and foreign keys, with what every engine says of them; what only one engine has (an exclusion constraint, a NOT NULL constraint by name) is its plugin''s.';


--
-- Name: COLUMN constraints.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.id IS 'a UUIDv7 made with its row, kept when the name changes';


--
-- Name: COLUMN constraints.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.design IS 'the design';


--
-- Name: COLUMN constraints.object; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.object IS 'the table it is on';


--
-- Name: COLUMN constraints."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints."position" IS 'its place among the table''s constraints, as the server lists them';


--
-- Name: COLUMN constraints.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.name IS 'its name; NULL where the engine gives it none';


--
-- Name: COLUMN constraints.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.kind IS 'what it is';


--
-- Name: COLUMN constraints.expression; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.expression IS 'a check''s expression, as the engine writes it; NULL otherwise';


--
-- Name: COLUMN constraints.to_object; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.to_object IS 'the table a foreign key refers to; NULL otherwise';


--
-- Name: COLUMN constraints.on_delete; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.on_delete IS 'what a foreign key does when the row it refers to is deleted; NULL otherwise';


--
-- Name: COLUMN constraints.on_update; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.on_update IS 'what a foreign key does when the key it refers to changes; NULL otherwise';


--
-- Name: COLUMN constraints.enforced; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.enforced IS 'false for one the database holds but does not enforce (NOT ENFORCED)';


--
-- Name: COLUMN constraints."deferrable"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints."deferrable" IS 'true when it may be checked at the end of a transaction';


--
-- Name: COLUMN constraints.initially_deferred; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.constraints.initially_deferred IS 'true when it is checked at the end unless said otherwise';


--
-- Name: dependencies; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.dependencies (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    object uuid NOT NULL,
    uses uuid NOT NULL,
    "as" text NOT NULL,
    "position" integer DEFAULT 1 NOT NULL,
    CONSTRAINT dependencies_as_check CHECK (("as" ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT dependencies_check CHECK ((object <> uses)),
    CONSTRAINT dependencies_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT dependencies_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.dependencies OWNER TO cortex_owner;

--
-- Name: TABLE dependencies; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.dependencies IS 'what an object uses, and as what (a view''s tables, a trigger''s function, a routine''s tables where the engine says): what the canvas draws as lineage and the agent follows as impact; a used object cannot go while what uses it stays.';


--
-- Name: COLUMN dependencies.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN dependencies.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies.design IS 'the design';


--
-- Name: COLUMN dependencies.object; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies.object IS 'the object that uses';


--
-- Name: COLUMN dependencies.uses; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies.uses IS 'the object used';


--
-- Name: COLUMN dependencies."as"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies."as" IS 'the part it plays, as the engine names it (reads, calls, function, type, union)';


--
-- Name: COLUMN dependencies."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.dependencies."position" IS 'its place among the object''s dependencies of the same part, where their order means something (a MERGE table''s tables); 1 where it does not';


--
-- Name: designs; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.designs (
    id uuid DEFAULT uuidv7() NOT NULL,
    name text NOT NULL,
    engine text NOT NULL,
    engine_version text NOT NULL,
    flavor text NOT NULL,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT designs_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT designs_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100)))
);


ALTER TABLE cortex.designs OWNER TO cortex_owner;

--
-- Name: TABLE designs; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.designs IS 'every design people work on: one engine, version and flavor; everything of it is rows of these tables and its plugin''s that point at it, never a database, a schema or a table of its own.';


--
-- Name: COLUMN designs.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.id IS 'a UUIDv7 made with its row, never changed: how everything names the design';


--
-- Name: COLUMN designs.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.name IS 'as people call it (shop); a rename changes this and nothing else';


--
-- Name: COLUMN designs.engine; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.engine IS 'the engine it is made for (mysql)';


--
-- Name: COLUMN designs.engine_version; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.engine_version IS 'the engine''s version it is made for (8.4)';


--
-- Name: COLUMN designs.flavor; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.flavor IS 'the engine''s flavor it is made for (mysql, percona, aurora)';


--
-- Name: COLUMN designs.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.comment IS 'what it is for, in a sentence or two';


--
-- Name: COLUMN designs.created_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.designs.created_at IS 'when it was made';


--
-- Name: engine_flavors; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.engine_flavors (
    id text NOT NULL,
    engine text NOT NULL,
    flavor text NOT NULL,
    name text NOT NULL,
    refuses jsonb DEFAULT '{}'::jsonb NOT NULL,
    options jsonb DEFAULT '{}'::jsonb NOT NULL,
    sources jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT engine_flavors_check CHECK ((id = ((engine || '/'::text) || flavor))),
    CONSTRAINT engine_flavors_flavor_check CHECK ((flavor ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT engine_flavors_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT engine_flavors_options_check CHECK ((jsonb_typeof(options) = 'object'::text)),
    CONSTRAINT engine_flavors_refuses_check CHECK ((jsonb_typeof(refuses) = 'object'::text)),
    CONSTRAINT engine_flavors_sources_check CHECK ((jsonb_typeof(sources) = 'array'::text))
);


ALTER TABLE cortex.engine_flavors OWNER TO cortex_owner;

--
-- Name: TABLE engine_flavors; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.engine_flavors IS 'the flavors of each engine a design may be made for: the engine itself, and each fork or managed service that is a subset of it (Percona Server, Cloud SQL, RDS, Aurora, AlloyDB), with what each refuses and the options it adds, declared by its plugin and checked by it.';


--
-- Name: COLUMN engine_flavors.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.id IS '<engine>/<flavor>: mysql/aurora';


--
-- Name: COLUMN engine_flavors.engine; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.engine IS 'the engine it is a flavor of';


--
-- Name: COLUMN engine_flavors.flavor; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.flavor IS 'as the plugin names it; the engine''s own is named as the engine (mysql)';


--
-- Name: COLUMN engine_flavors.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.name IS 'as people say it (Amazon Aurora MySQL)';


--
-- Name: COLUMN engine_flavors.refuses; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.refuses IS 'what a design of it may not hold, by what the plugin checks: {"engines": ["MyISAM"], "kinds": ["resource_group"], "privileges": ["SUPER"]}';


--
-- Name: COLUMN engine_flavors.options; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.options IS 'the flavor_options keys it adds, by table, each with its JSON type: {"tables": {"compression_dictionary": "string"}}';


--
-- Name: COLUMN engine_flavors.sources; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_flavors.sources IS 'the documentation pages its facts come from';


--
-- Name: engine_versions; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.engine_versions (
    id text NOT NULL,
    engine text NOT NULL,
    version text NOT NULL,
    name text NOT NULL,
    "position" numeric NOT NULL,
    CONSTRAINT engine_versions_check CHECK ((id = ((engine || '/'::text) || version))),
    CONSTRAINT engine_versions_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT engine_versions_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT engine_versions_version_check CHECK ((version ~ '^[0-9A-Za-z][0-9A-Za-z.\-]*$'::text))
);


ALTER TABLE cortex.engine_versions OWNER TO cortex_owner;

--
-- Name: TABLE engine_versions; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.engine_versions IS 'the versions of each engine''s database a design may be made for, oldest first.';


--
-- Name: COLUMN engine_versions.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_versions.id IS '<engine>/<version>: mysql/8.4';


--
-- Name: COLUMN engine_versions.engine; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_versions.engine IS 'the engine';


--
-- Name: COLUMN engine_versions.version; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_versions.version IS 'as the engine names it (5.7, 18)';


--
-- Name: COLUMN engine_versions.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_versions.name IS 'as people say it (MySQL 8.4)';


--
-- Name: COLUMN engine_versions."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engine_versions."position" IS 'its place among the engine''s versions, oldest first: versions compare by it';


--
-- Name: engines; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.engines (
    id text NOT NULL,
    plugin text NOT NULL,
    name text NOT NULL,
    CONSTRAINT engines_id_check CHECK ((id ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT engines_name_check CHECK ((length(name) >= 1))
);


ALTER TABLE cortex.engines OWNER TO cortex_owner;

--
-- Name: TABLE engines; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.engines IS 'the databases designs are made for, each brought by its plugin.';


--
-- Name: COLUMN engines.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engines.id IS 'as the registry knows it (mysql)';


--
-- Name: COLUMN engines.plugin; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engines.plugin IS 'the plugin that brings it';


--
-- Name: COLUMN engines.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.engines.name IS 'as people say it (MySQL)';


--
-- Name: index_parts; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.index_parts (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    index uuid NOT NULL,
    "position" integer NOT NULL,
    "column" uuid,
    expression text,
    descending boolean DEFAULT false NOT NULL,
    included boolean DEFAULT false NOT NULL,
    CONSTRAINT index_parts_check CHECK ((("column" IS NULL) <> (expression IS NULL))),
    CONSTRAINT index_parts_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT index_parts_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.index_parts OWNER TO cortex_owner;

--
-- Name: TABLE index_parts; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.index_parts IS 'the parts of an index, in order: each a column of its table or an expression, in the order or only carried along.';


--
-- Name: COLUMN index_parts.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN index_parts.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.design IS 'the design';


--
-- Name: COLUMN index_parts.index; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.index IS 'the index';


--
-- Name: COLUMN index_parts."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts."position" IS 'its place in the index: 1 first';


--
-- Name: COLUMN index_parts."column"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts."column" IS 'the column indexed; NULL for an expression';


--
-- Name: COLUMN index_parts.expression; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.expression IS 'the expression indexed, as the engine writes it; NULL for a column';


--
-- Name: COLUMN index_parts.descending; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.descending IS 'true when held in descending order';


--
-- Name: COLUMN index_parts.included; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.index_parts.included IS 'true for a column carried without being part of the order (INCLUDE)';


--
-- Name: indexes; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.indexes (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    object uuid NOT NULL,
    "position" integer NOT NULL,
    name text NOT NULL,
    "unique" boolean DEFAULT false NOT NULL,
    method text,
    condition text,
    comment text,
    CONSTRAINT indexes_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT indexes_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT indexes_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.indexes OWNER TO cortex_owner;

--
-- Name: TABLE indexes; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.indexes IS 'the indexes of a table, in the order the server lists them, with what every engine says of an index; what only one engine says is its plugin''s, with the same id.';


--
-- Name: COLUMN indexes.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.id IS 'a UUIDv7 made with its row, kept when the name changes';


--
-- Name: COLUMN indexes.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.design IS 'the design';


--
-- Name: COLUMN indexes.object; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.object IS 'the table it is on';


--
-- Name: COLUMN indexes."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes."position" IS 'its place among the table''s indexes, as the server lists them';


--
-- Name: COLUMN indexes.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.name IS 'as the engine names it';


--
-- Name: COLUMN indexes."unique"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes."unique" IS 'true when no two rows may share its values';


--
-- Name: COLUMN indexes.method; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.method IS 'how it is built, in the engine''s words (BTREE, FULLTEXT, gin); NULL for the engine''s default';


--
-- Name: COLUMN indexes.condition; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.condition IS 'the rows a partial index covers, as the engine writes it; NULL for all';


--
-- Name: COLUMN indexes.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.indexes.comment IS 'what it is for: written into its SQL';


--
-- Name: locked_versions; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.locked_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    turn uuid NOT NULL,
    number integer NOT NULL,
    hash text NOT NULL,
    locked_by text NOT NULL,
    locked_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT locked_versions_hash_check CHECK ((hash ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT locked_versions_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT locked_versions_locked_by_check CHECK ((length(locked_by) >= 1)),
    CONSTRAINT locked_versions_number_check CHECK ((number >= 1))
);


ALTER TABLE cortex.locked_versions OWNER TO cortex_owner;

--
-- Name: TABLE locked_versions; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.locked_versions IS 'a locked version of a design: the log up to one committed turn, its number and the hash of the model it gives; locked once, never changed.';


--
-- Name: COLUMN locked_versions.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN locked_versions.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.design IS 'the design';


--
-- Name: COLUMN locked_versions.turn; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.turn IS 'the last turn it holds';


--
-- Name: COLUMN locked_versions.number; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.number IS 'its number in the design: 1, 2, 3';


--
-- Name: COLUMN locked_versions.hash; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.hash IS 'the SHA-256 of the model at that turn';


--
-- Name: COLUMN locked_versions.locked_by; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.locked_by IS 'who locked it';


--
-- Name: COLUMN locked_versions.locked_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.locked_versions.locked_at IS 'when';


--
-- Name: namespaces; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.namespaces (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    parent uuid,
    name text NOT NULL,
    "position" numeric NOT NULL,
    comment text,
    CONSTRAINT namespaces_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT namespaces_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT namespaces_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.namespaces OWNER TO cortex_owner;

--
-- Name: TABLE namespaces; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.namespaces IS 'the levels that hold objects, each under its parent or at the top: a MySQL database; a PostgreSQL database and its schemas.';


--
-- Name: COLUMN namespaces.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces.id IS 'a UUIDv7 made with its row, kept when the name changes';


--
-- Name: COLUMN namespaces.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces.design IS 'the design';


--
-- Name: COLUMN namespaces.parent; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces.parent IS 'the namespace it is in; NULL at the top';


--
-- Name: COLUMN namespaces.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces.name IS 'as the engine names it (sales)';


--
-- Name: COLUMN namespaces."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces."position" IS 'its place among its parent''s namespaces, in the order made or read; one put between two takes their midpoint';


--
-- Name: COLUMN namespaces.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.namespaces.comment IS 'what it holds: written into its SQL';


--
-- Name: object_kinds; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.object_kinds (
    id text NOT NULL,
    engine text NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    has_columns boolean NOT NULL,
    details text,
    "position" numeric NOT NULL,
    since text,
    until text,
    details_plugin text GENERATED ALWAYS AS (
CASE
    WHEN (details IS NULL) THEN NULL::text
    ELSE engine
END) STORED,
    CONSTRAINT object_kinds_check CHECK ((id = ((engine || '/'::text) || kind))),
    CONSTRAINT object_kinds_kind_check CHECK ((kind ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT object_kinds_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT object_kinds_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.object_kinds OWNER TO cortex_owner;

--
-- Name: TABLE object_kinds; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object each engine has, the versions that have each, and the plugin table that holds each kind''s details; an object of a kind its design''s engine or version lacks cannot be stored.';


--
-- Name: COLUMN object_kinds.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.id IS '<engine>/<kind>: mysql/table';


--
-- Name: COLUMN object_kinds.engine; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.engine IS 'the engine';


--
-- Name: COLUMN object_kinds.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.kind IS 'as an object names its kind (table, view, procedure)';


--
-- Name: COLUMN object_kinds.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';


--
-- Name: COLUMN object_kinds.has_columns; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.has_columns IS 'true when its objects have columns the canvas draws (a table, a view)';


--
-- Name: COLUMN object_kinds.details; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.details IS 'the plugin table that extends its objects (tables); NULL when the cortex says all of it';


--
-- Name: COLUMN object_kinds."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds."position" IS 'its place in the engine''s list of kinds';


--
-- Name: COLUMN object_kinds.since; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.since IS 'the first version of the engine that has it (9.7 for a JavaScript library); NULL for every version';


--
-- Name: COLUMN object_kinds.until; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.until IS 'the last version that has it; NULL for every later one';


--
-- Name: COLUMN object_kinds.details_plugin; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.object_kinds.details_plugin IS 'the plugin of its details table: its engine''s';


--
-- Name: objects; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.objects (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    engine text NOT NULL,
    namespace uuid NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    signature text DEFAULT ''::text NOT NULL,
    parent uuid,
    "position" numeric NOT NULL,
    comment text,
    notes text,
    CONSTRAINT objects_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT objects_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT objects_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.objects OWNER TO cortex_owner;

--
-- Name: TABLE objects; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds, of a kind its design''s engine has (a table, a view, a routine, a trigger, an event, a type); what only its engine says of it is a row of its kind''s plugin table, with the same id.';


--
-- Name: COLUMN objects.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.id IS 'a UUIDv7 made with its row, kept when the name changes';


--
-- Name: COLUMN objects.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.design IS 'the design';


--
-- Name: COLUMN objects.engine; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.engine IS 'its design''s engine: it ties the object''s kind to that engine''s kinds';


--
-- Name: COLUMN objects.namespace; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it';


--
-- Name: COLUMN objects.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.kind IS 'one of its engine''s kinds (table)';


--
-- Name: COLUMN objects.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.name IS 'as the engine names it (orders)';


--
-- Name: COLUMN objects.signature; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.signature IS 'what tells overloaded routines apart ((integer, text)); empty where the name is enough';


--
-- Name: COLUMN objects.parent; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.parent IS 'the object it belongs to (a trigger''s table); NULL for none';


--
-- Name: COLUMN objects."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects."position" IS 'its place among its namespace''s objects, in the order made or read; one put between two takes their midpoint';


--
-- Name: COLUMN objects.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';


--
-- Name: COLUMN objects.notes; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';


--
-- Name: operations; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.operations (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    turn uuid NOT NULL,
    "position" integer NOT NULL,
    kind text NOT NULL,
    summary text NOT NULL,
    undoes uuid,
    CONSTRAINT operations_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT operations_kind_check CHECK ((kind ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT operations_position_check CHECK (("position" >= 1)),
    CONSTRAINT operations_summary_check CHECK ((length(summary) >= 1))
);


ALTER TABLE cortex.operations OWNER TO cortex_owner;

--
-- Name: TABLE operations; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.operations IS 'what a turn did, one operation at a time, each named as the agent and the canvas name it (add_table orders); its row changes are what it changed.';


--
-- Name: COLUMN operations.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.id IS 'a UUIDv7 made with its row';


--
-- Name: COLUMN operations.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.design IS 'the design';


--
-- Name: COLUMN operations.turn; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.turn IS 'the turn it belongs to';


--
-- Name: COLUMN operations."position"; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations."position" IS 'its place in the turn: 1, 2, 3';


--
-- Name: COLUMN operations.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.kind IS 'what it is, as the agent and the canvas name it (add_table)';


--
-- Name: COLUMN operations.summary; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.summary IS 'what it did, for people (added table orders)';


--
-- Name: COLUMN operations.undoes; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.operations.undoes IS 'the turn it undid, for an undo; written by cortex.undo, NULL otherwise';


--
-- Name: plugin_tables; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.plugin_tables (
    plugin text NOT NULL,
    name text NOT NULL,
    extends text,
    comment text NOT NULL,
    CONSTRAINT plugin_tables_comment_check CHECK ((length(comment) >= 1)),
    CONSTRAINT plugin_tables_extends_check CHECK ((extends = ANY (ARRAY['namespaces'::text, 'objects'::text, 'columns'::text, 'indexes'::text, 'index_parts'::text, 'constraints'::text, 'constraint_columns'::text]))),
    CONSTRAINT plugin_tables_name_check CHECK ((name ~ '^[a-z][a-z0-9_]*$'::text))
);


ALTER TABLE cortex.plugin_tables OWNER TO cortex_owner;

--
-- Name: TABLE plugin_tables; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.plugin_tables IS 'every table a plugin brings, and the cortex table each extends: how the canvas, the agent and the log find an object''s engine details.';


--
-- Name: COLUMN plugin_tables.plugin; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugin_tables.plugin IS 'the plugin that brings it';


--
-- Name: COLUMN plugin_tables.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugin_tables.name IS 'its name in the plugin''s namespace (tables)';


--
-- Name: COLUMN plugin_tables.extends; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugin_tables.extends IS 'the cortex table whose rows it extends, one row each with the same id; NULL for a part of its own (a routine''s parameters)';


--
-- Name: COLUMN plugin_tables.comment; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugin_tables.comment IS 'what it holds';


--
-- Name: plugins; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.plugins (
    id text NOT NULL,
    kind text NOT NULL,
    namespace text NOT NULL,
    name text NOT NULL,
    version integer NOT NULL,
    requires_cortex integer NOT NULL,
    owner text GENERATED ALWAYS AS ((namespace || '_owner'::text)) STORED,
    account text GENERATED ALWAYS AS ((namespace || '_service'::text)) STORED,
    installed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT plugins_check CHECK (((kind <> 'engine'::text) OR (namespace = ('engine_'::text || id)))),
    CONSTRAINT plugins_check1 CHECK (((kind <> 'core'::text) OR ((id = 'cortex'::text) AND (namespace = 'cortex'::text)))),
    CONSTRAINT plugins_id_check CHECK ((id ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT plugins_kind_check CHECK ((kind = ANY (ARRAY['core'::text, 'engine'::text, 'feature'::text]))),
    CONSTRAINT plugins_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT plugins_namespace_check CHECK ((namespace ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT plugins_requires_cortex_check CHECK ((requires_cortex >= 1)),
    CONSTRAINT plugins_version_check CHECK ((version >= 1))
);


ALTER TABLE cortex.plugins OWNER TO cortex_owner;

--
-- Name: TABLE plugins; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.plugins IS 'every plugin installed in schema_forge, the cortex among them: its namespace, its schema version, the cortex version it needs, and its two roles, named after its namespace.';


--
-- Name: COLUMN plugins.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.id IS 'as the registry knows it (mysql)';


--
-- Name: COLUMN plugins.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.kind IS 'core: the cortex; engine: a database''s plugin; feature: one that adds tables of its own';


--
-- Name: COLUMN plugins.namespace; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.namespace IS 'the PostgreSQL schema its tables are in (engine_mysql)';


--
-- Name: COLUMN plugins.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.name IS 'as people say it (MySQL)';


--
-- Name: COLUMN plugins.version; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.version IS 'its newest schema version installed here';


--
-- Name: COLUMN plugins.requires_cortex; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.requires_cortex IS 'the lowest cortex version its tables are written against';


--
-- Name: COLUMN plugins.owner; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.owner IS 'the role that owns its namespace and runs its migrations, never signing in (engine_mysql_owner)';


--
-- Name: COLUMN plugins.account; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.account IS 'its service account: the only writer of its namespace, fenced to its engine''s designs (engine_mysql_service)';


--
-- Name: COLUMN plugins.installed_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.plugins.installed_at IS 'when it was plugged in';


--
-- Name: row_changes; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.row_changes (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    operation uuid NOT NULL,
    tab text NOT NULL,
    row_id uuid NOT NULL,
    action text NOT NULL,
    before jsonb,
    after jsonb,
    CONSTRAINT row_changes_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT row_changes_check CHECK ((((before IS NULL) = (action = 'insert'::text)) AND ((after IS NULL) = (action = 'delete'::text)))),
    CONSTRAINT row_changes_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT row_changes_tab_check CHECK ((tab ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text))
);


ALTER TABLE cortex.row_changes OWNER TO cortex_owner;

--
-- Name: TABLE row_changes; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.row_changes IS 'the log: every row an operation inserted, updated or deleted in any table of the model or a plugin, with its values before and after; written only by the trigger cortex.log_row, never by a person, the app or the agent.';


--
-- Name: COLUMN row_changes.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.id IS 'a UUIDv7 made with its row: the log reads in this order';


--
-- Name: COLUMN row_changes.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.design IS 'the design';


--
-- Name: COLUMN row_changes.operation; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.operation IS 'the operation that changed the row';


--
-- Name: COLUMN row_changes.tab; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.tab IS 'the table changed, with its namespace (engine_mysql.tables)';


--
-- Name: COLUMN row_changes.row_id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.row_id IS 'the row''s id';


--
-- Name: COLUMN row_changes.action; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.action IS 'what was done to it';


--
-- Name: COLUMN row_changes.before; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.before IS 'the row before, every column; NULL for an insert';


--
-- Name: COLUMN row_changes.after; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.row_changes.after IS 'the row after, every column; NULL for a delete';


--
-- Name: schema_migrations; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.schema_migrations (
    plugin text NOT NULL,
    version integer NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT schema_migrations_version_check CHECK ((version >= 1))
);


ALTER TABLE cortex.schema_migrations OWNER TO cortex_owner;

--
-- Name: TABLE schema_migrations; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.schema_migrations IS 'every schema version of every plugin applied to schema_forge, the cortex''s among them.';


--
-- Name: COLUMN schema_migrations.plugin; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.schema_migrations.plugin IS 'the plugin';


--
-- Name: COLUMN schema_migrations.version; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.schema_migrations.version IS 'the version applied';


--
-- Name: COLUMN schema_migrations.applied_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.schema_migrations.applied_at IS 'when';


--
-- Name: turns; Type: TABLE; Schema: cortex; Owner: cortex_owner
--

CREATE TABLE cortex.turns (
    id uuid DEFAULT uuidv7() NOT NULL,
    design uuid NOT NULL,
    branch uuid NOT NULL,
    parent uuid,
    kind text NOT NULL,
    state text DEFAULT 'open'::text NOT NULL,
    seq integer,
    author text NOT NULL,
    prompt text,
    summary text,
    name text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    CONSTRAINT turns_author_check CHECK ((length(author) >= 1)),
    CONSTRAINT turns_check CHECK (((state = 'open'::text) = (ended_at IS NULL))),
    CONSTRAINT turns_check1 CHECK (((seq IS NULL) = (state = ANY (ARRAY['open'::text, 'rejected'::text])))),
    CONSTRAINT turns_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT turns_kind_check CHECK ((kind = ANY (ARRAY['import'::text, 'edit'::text, 'agent'::text, 'undo'::text, 'restore'::text, 'switch'::text]))),
    CONSTRAINT turns_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100))),
    CONSTRAINT turns_seq_check CHECK ((seq >= 1)),
    CONSTRAINT turns_state_check CHECK ((state = ANY (ARRAY['open'::text, 'committed'::text, 'rejected'::text, 'undone'::text])))
);


ALTER TABLE cortex.turns OWNER TO cortex_owner;

--
-- Name: TABLE turns; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON TABLE cortex.turns IS 'one round of work on a design (an import, a person''s edit, the agent''s answer to a prompt, an undo, a restore); every change belongs to one; a named turn is a savepoint.';


--
-- Name: COLUMN turns.id; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.id IS 'a UUIDv7 made with its row: turns sort in the order they began';


--
-- Name: COLUMN turns.design; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.design IS 'the design';


--
-- Name: COLUMN turns.branch; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.branch IS 'the branch it was made on';


--
-- Name: COLUMN turns.parent; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.parent IS 'the turn it follows: the branch''s head when it began; NULL for a design''s first';


--
-- Name: COLUMN turns.kind; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.kind IS 'what made it';


--
-- Name: COLUMN turns.state; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.state IS 'open while it runs; committed or rejected when it ends; undone when a later turn undid it';


--
-- Name: COLUMN turns.seq; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.seq IS 'its place in its design''s commit order, given when it commits; NULL until then';


--
-- Name: COLUMN turns.author; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.author IS 'who made it: a person''s name, or the agent''s';


--
-- Name: COLUMN turns.prompt; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.prompt IS 'the prompt it answers, for an agent''s turn';


--
-- Name: COLUMN turns.summary; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.summary IS 'what it did, in a sentence';


--
-- Name: COLUMN turns.name; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.name IS 'its savepoint name, when someone named it; NULL otherwise';


--
-- Name: COLUMN turns.started_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.started_at IS 'when it began';


--
-- Name: COLUMN turns.ended_at; Type: COMMENT; Schema: cortex; Owner: cortex_owner
--

COMMENT ON COLUMN cortex.turns.ended_at IS 'when it ended; NULL while open';


--
-- Name: branches branches_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_design_id_key UNIQUE (design, id);


--
-- Name: branches branches_design_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_design_name_key UNIQUE (design, name);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: columns columns_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_design_id_key UNIQUE (design, id);


--
-- Name: columns columns_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_pkey PRIMARY KEY (id);


--
-- Name: constraint_columns constraint_columns_constraint_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_constraint_position_key UNIQUE ("constraint", "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_design_id_key UNIQUE (design, id);


--
-- Name: constraint_columns constraint_columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_pkey PRIMARY KEY (id);


--
-- Name: constraints constraints_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_design_id_key UNIQUE (design, id);


--
-- Name: constraints constraints_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_pkey PRIMARY KEY (id);


--
-- Name: dependencies dependencies_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_design_id_key UNIQUE (design, id);


--
-- Name: dependencies dependencies_object_uses_as_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_object_uses_as_key UNIQUE (object, uses, "as") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_pkey PRIMARY KEY (id);


--
-- Name: designs designs_id_engine_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_id_engine_key UNIQUE (id, engine);


--
-- Name: designs designs_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_name_key UNIQUE (name);


--
-- Name: designs designs_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_pkey PRIMARY KEY (id);


--
-- Name: engine_flavors engine_flavors_engine_flavor_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_flavors
    ADD CONSTRAINT engine_flavors_engine_flavor_key UNIQUE (engine, flavor);


--
-- Name: engine_flavors engine_flavors_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_flavors
    ADD CONSTRAINT engine_flavors_pkey PRIMARY KEY (id);


--
-- Name: engine_versions engine_versions_engine_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_engine_position_key UNIQUE (engine, "position");


--
-- Name: engine_versions engine_versions_engine_version_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_engine_version_key UNIQUE (engine, version);


--
-- Name: engine_versions engine_versions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_pkey PRIMARY KEY (id);


--
-- Name: engines engines_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engines
    ADD CONSTRAINT engines_pkey PRIMARY KEY (id);


--
-- Name: index_parts index_parts_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_design_id_key UNIQUE (design, id);


--
-- Name: index_parts index_parts_index_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_index_position_key UNIQUE (index, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_pkey PRIMARY KEY (id);


--
-- Name: indexes indexes_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_design_id_key UNIQUE (design, id);


--
-- Name: indexes indexes_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_pkey PRIMARY KEY (id);


--
-- Name: locked_versions locked_versions_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_design_id_key UNIQUE (design, id);


--
-- Name: locked_versions locked_versions_design_number_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_design_number_key UNIQUE (design, number);


--
-- Name: locked_versions locked_versions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_pkey PRIMARY KEY (id);


--
-- Name: namespaces namespaces_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_design_id_key UNIQUE (design, id);


--
-- Name: namespaces namespaces_design_parent_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_design_parent_name_key UNIQUE NULLS NOT DISTINCT (design, parent, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: namespaces namespaces_design_parent_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_design_parent_position_key UNIQUE NULLS NOT DISTINCT (design, parent, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: namespaces namespaces_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_pkey PRIMARY KEY (id);


--
-- Name: object_kinds object_kinds_engine_kind_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_engine_kind_key UNIQUE (engine, kind);


--
-- Name: object_kinds object_kinds_engine_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_engine_position_key UNIQUE (engine, "position");


--
-- Name: object_kinds object_kinds_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_pkey PRIMARY KEY (id);


--
-- Name: objects objects_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_design_id_key UNIQUE (design, id);


--
-- Name: objects objects_namespace_kind_name_signature_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_kind_name_signature_key UNIQUE (namespace, kind, name, signature) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_namespace_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_position_key UNIQUE (namespace, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_pkey PRIMARY KEY (id);


--
-- Name: operations operations_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_design_id_key UNIQUE (design, id);


--
-- Name: operations operations_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_pkey PRIMARY KEY (id);


--
-- Name: operations operations_turn_position_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_turn_position_key UNIQUE (turn, "position");


--
-- Name: plugin_tables plugin_tables_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.plugin_tables
    ADD CONSTRAINT plugin_tables_pkey PRIMARY KEY (plugin, name);


--
-- Name: plugins plugins_namespace_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.plugins
    ADD CONSTRAINT plugins_namespace_key UNIQUE (namespace);


--
-- Name: plugins plugins_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.plugins
    ADD CONSTRAINT plugins_pkey PRIMARY KEY (id);


--
-- Name: row_changes row_changes_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_design_id_key UNIQUE (design, id);


--
-- Name: row_changes row_changes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (plugin, version);


--
-- Name: turns turns_design_id_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_id_key UNIQUE (design, id);


--
-- Name: turns turns_design_name_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_name_key UNIQUE (design, name);


--
-- Name: turns turns_design_seq_key; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_seq_key UNIQUE (design, seq);


--
-- Name: turns turns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_pkey PRIMARY KEY (id);


--
-- Name: columns_object; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX columns_object ON cortex.columns USING btree (design, object);


--
-- Name: constraint_columns_column; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX constraint_columns_column ON cortex.constraint_columns USING btree (design, "column");


--
-- Name: constraint_columns_constraint; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX constraint_columns_constraint ON cortex.constraint_columns USING btree (design, "constraint");


--
-- Name: constraint_columns_to_column; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX constraint_columns_to_column ON cortex.constraint_columns USING btree (design, to_column);


--
-- Name: constraints_object; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX constraints_object ON cortex.constraints USING btree (design, object);


--
-- Name: constraints_to_object; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX constraints_to_object ON cortex.constraints USING btree (design, to_object);


--
-- Name: dependencies_object; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX dependencies_object ON cortex.dependencies USING btree (design, object);


--
-- Name: dependencies_uses; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX dependencies_uses ON cortex.dependencies USING btree (design, uses);


--
-- Name: index_parts_column; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX index_parts_column ON cortex.index_parts USING btree (design, "column");


--
-- Name: index_parts_index; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX index_parts_index ON cortex.index_parts USING btree (design, index);


--
-- Name: indexes_object; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX indexes_object ON cortex.indexes USING btree (design, object);


--
-- Name: locked_versions_turn; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX locked_versions_turn ON cortex.locked_versions USING btree (design, turn);


--
-- Name: namespaces_parent; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX namespaces_parent ON cortex.namespaces USING btree (design, parent);


--
-- Name: objects_kind; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX objects_kind ON cortex.objects USING btree (engine, kind);


--
-- Name: objects_namespace; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX objects_namespace ON cortex.objects USING btree (design, namespace);


--
-- Name: objects_parent; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX objects_parent ON cortex.objects USING btree (design, parent);


--
-- Name: operations_turn; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX operations_turn ON cortex.operations USING btree (design, turn);


--
-- Name: operations_undoes; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX operations_undoes ON cortex.operations USING btree (design, undoes);


--
-- Name: row_changes_operation; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX row_changes_operation ON cortex.row_changes USING btree (design, operation);


--
-- Name: row_changes_row; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX row_changes_row ON cortex.row_changes USING btree (design, row_id);


--
-- Name: turns_branch; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX turns_branch ON cortex.turns USING btree (design, branch);


--
-- Name: turns_one_open; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE UNIQUE INDEX turns_one_open ON cortex.turns USING btree (design) WHERE (state = 'open'::text);


--
-- Name: turns_parent; Type: INDEX; Schema: cortex; Owner: cortex_owner
--

CREATE INDEX turns_parent ON cortex.turns USING btree (design, parent);


--
-- Name: designs check_design; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE CONSTRAINT TRIGGER check_design AFTER INSERT OR UPDATE OF engine_version, flavor ON cortex.designs DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cortex.check_design();


--
-- Name: objects check_object; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE CONSTRAINT TRIGGER check_object AFTER INSERT OR UPDATE OF kind ON cortex.objects DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cortex.check_object();


--
-- Name: columns log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: constraint_columns log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: constraints log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: dependencies log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.dependencies FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: index_parts log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: indexes log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: namespaces log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.namespaces FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: objects log_row; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER log_row AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH ROW EXECUTE FUNCTION cortex.log_row();


--
-- Name: turns notify_turn; Type: TRIGGER; Schema: cortex; Owner: cortex_owner
--

CREATE TRIGGER notify_turn BEFORE UPDATE OF state ON cortex.turns FOR EACH ROW EXECUTE FUNCTION cortex.notify_turn();


--
-- Name: branches branches_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_design_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_design_object_fkey FOREIGN KEY (design, object) REFERENCES cortex.objects(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_design_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_design_column_fkey FOREIGN KEY (design, "column") REFERENCES cortex.columns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_design_constraint_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_design_constraint_fkey FOREIGN KEY (design, "constraint") REFERENCES cortex.constraints(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_design_to_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_design_to_column_fkey FOREIGN KEY (design, to_column) REFERENCES cortex.columns(design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_design_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_design_object_fkey FOREIGN KEY (design, object) REFERENCES cortex.objects(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_design_to_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_design_to_object_fkey FOREIGN KEY (design, to_object) REFERENCES cortex.objects(design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_design_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_design_object_fkey FOREIGN KEY (design, object) REFERENCES cortex.objects(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_design_uses_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_design_uses_fkey FOREIGN KEY (design, uses) REFERENCES cortex.objects(design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: designs designs_engine_engine_version_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_engine_engine_version_fkey FOREIGN KEY (engine, engine_version) REFERENCES cortex.engine_versions(engine, version);


--
-- Name: designs designs_engine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_engine_fkey FOREIGN KEY (engine) REFERENCES cortex.engines(id);


--
-- Name: designs designs_engine_flavor_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.designs
    ADD CONSTRAINT designs_engine_flavor_fkey FOREIGN KEY (engine, flavor) REFERENCES cortex.engine_flavors(engine, flavor);


--
-- Name: engine_flavors engine_flavors_engine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_flavors
    ADD CONSTRAINT engine_flavors_engine_fkey FOREIGN KEY (engine) REFERENCES cortex.engines(id) ON DELETE CASCADE;


--
-- Name: engine_versions engine_versions_engine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_engine_fkey FOREIGN KEY (engine) REFERENCES cortex.engines(id) ON DELETE CASCADE;


--
-- Name: engines engines_plugin_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.engines
    ADD CONSTRAINT engines_plugin_fkey FOREIGN KEY (plugin) REFERENCES cortex.plugins(id) ON DELETE CASCADE;


--
-- Name: index_parts index_parts_design_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_design_column_fkey FOREIGN KEY (design, "column") REFERENCES cortex.columns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_design_index_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_design_index_fkey FOREIGN KEY (design, index) REFERENCES cortex.indexes(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_design_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_design_object_fkey FOREIGN KEY (design, object) REFERENCES cortex.objects(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: locked_versions locked_versions_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: locked_versions locked_versions_design_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_design_turn_fkey FOREIGN KEY (design, turn) REFERENCES cortex.turns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: namespaces namespaces_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: namespaces namespaces_design_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_design_parent_fkey FOREIGN KEY (design, parent) REFERENCES cortex.namespaces(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: object_kinds object_kinds_details_plugin_details_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_details_plugin_details_fkey FOREIGN KEY (details_plugin, details) REFERENCES cortex.plugin_tables(plugin, name) ON DELETE RESTRICT;


--
-- Name: object_kinds object_kinds_engine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_engine_fkey FOREIGN KEY (engine) REFERENCES cortex.engines(id) ON DELETE CASCADE;


--
-- Name: object_kinds object_kinds_engine_since_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_engine_since_fkey FOREIGN KEY (engine, since) REFERENCES cortex.engine_versions(engine, version);


--
-- Name: object_kinds object_kinds_engine_until_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_engine_until_fkey FOREIGN KEY (engine, until) REFERENCES cortex.engine_versions(engine, version);


--
-- Name: objects objects_design_engine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_design_engine_fkey FOREIGN KEY (design, engine) REFERENCES cortex.designs(id, engine) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_design_namespace_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_design_namespace_fkey FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_design_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_design_parent_fkey FOREIGN KEY (design, parent) REFERENCES cortex.objects(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_engine_kind_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_engine_kind_fkey FOREIGN KEY (engine, kind) REFERENCES cortex.object_kinds(engine, kind);


--
-- Name: operations operations_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: operations operations_design_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_design_turn_fkey FOREIGN KEY (design, turn) REFERENCES cortex.turns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: operations operations_design_undoes_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_design_undoes_fkey FOREIGN KEY (design, undoes) REFERENCES cortex.turns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: plugin_tables plugin_tables_plugin_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.plugin_tables
    ADD CONSTRAINT plugin_tables_plugin_fkey FOREIGN KEY (plugin) REFERENCES cortex.plugins(id) ON DELETE CASCADE;


--
-- Name: row_changes row_changes_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: row_changes row_changes_design_operation_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_design_operation_fkey FOREIGN KEY (design, operation) REFERENCES cortex.operations(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: schema_migrations schema_migrations_plugin_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.schema_migrations
    ADD CONSTRAINT schema_migrations_plugin_fkey FOREIGN KEY (plugin) REFERENCES cortex.plugins(id) ON DELETE CASCADE;


--
-- Name: turns turns_design_branch_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_branch_fkey FOREIGN KEY (design, branch) REFERENCES cortex.branches(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: turns turns_design_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_fkey FOREIGN KEY (design) REFERENCES cortex.designs(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: turns turns_design_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_design_parent_fkey FOREIGN KEY (design, parent) REFERENCES cortex.turns(design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: branches; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.branches ENABLE ROW LEVEL SECURITY;

--
-- Name: columns; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.columns ENABLE ROW LEVEL SECURITY;

--
-- Name: constraint_columns; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.constraint_columns ENABLE ROW LEVEL SECURITY;

--
-- Name: constraints; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.constraints ENABLE ROW LEVEL SECURITY;

--
-- Name: dependencies; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.dependencies ENABLE ROW LEVEL SECURITY;

--
-- Name: designs; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.designs ENABLE ROW LEVEL SECURITY;

--
-- Name: branches everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.branches TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: columns everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.columns TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: constraint_columns everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.constraint_columns TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: constraints everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.constraints TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: dependencies everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.dependencies TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: designs everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.designs TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: index_parts everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.index_parts TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: indexes everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.indexes TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: locked_versions everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.locked_versions TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: namespaces everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.namespaces TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: objects everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.objects TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: operations everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.operations TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: row_changes everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.row_changes TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: turns everyone; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY everyone ON cortex.turns TO cortex_owner, cortex_service, cortex_agent, cortex_reader USING (true) WITH CHECK (true);


--
-- Name: index_parts; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.index_parts ENABLE ROW LEVEL SECURITY;

--
-- Name: indexes; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.indexes ENABLE ROW LEVEL SECURITY;

--
-- Name: locked_versions; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.locked_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: namespaces; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.namespaces ENABLE ROW LEVEL SECURITY;

--
-- Name: objects; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.objects ENABLE ROW LEVEL SECURITY;

--
-- Name: operations; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.operations ENABLE ROW LEVEL SECURITY;

--
-- Name: branches own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.branches USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: columns own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.columns USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: constraint_columns own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.constraint_columns USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: constraints own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.constraints USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: dependencies own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.dependencies USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: designs own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.designs USING ((id IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((id IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: index_parts own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.index_parts USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: indexes own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.indexes USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: locked_versions own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.locked_versions USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: namespaces own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.namespaces USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: objects own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.objects USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: operations own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.operations USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: row_changes own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.row_changes USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: turns own_engine; Type: POLICY; Schema: cortex; Owner: cortex_owner
--

CREATE POLICY own_engine ON cortex.turns USING ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of))) WITH CHECK ((design IN ( SELECT cortex.designs_of(CURRENT_USER) AS designs_of)));


--
-- Name: row_changes; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.row_changes ENABLE ROW LEVEL SECURITY;

--
-- Name: turns; Type: ROW SECURITY; Schema: cortex; Owner: cortex_owner
--

ALTER TABLE cortex.turns ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA cortex; Type: ACL; Schema: -; Owner: cortex_owner
--

GRANT USAGE ON SCHEMA cortex TO cortex_service;
GRANT USAGE ON SCHEMA cortex TO cortex_agent;
GRANT USAGE ON SCHEMA cortex TO cortex_reader;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;


--
-- Name: FUNCTION attach_history(ns text, tabs text[]); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.attach_history(ns text, tabs text[]) FROM PUBLIC;


--
-- Name: FUNCTION check_design(); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.check_design() FROM PUBLIC;


--
-- Name: FUNCTION check_object(); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.check_object() FROM PUBLIC;


--
-- Name: FUNCTION check_plugin(plugin text); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.check_plugin(plugin text) FROM PUBLIC;


--
-- Name: FUNCTION designs_of(asking name); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.designs_of(asking name) FROM PUBLIC;
GRANT ALL ON FUNCTION cortex.designs_of(asking name) TO cortex_service;
GRANT ALL ON FUNCTION cortex.designs_of(asking name) TO cortex_agent;
GRANT ALL ON FUNCTION cortex.designs_of(asking name) TO cortex_reader;


--
-- Name: FUNCTION fence(ns text, tabs text[]); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.fence(ns text, tabs text[]) FROM PUBLIC;


--
-- Name: FUNCTION fit_plugin(plugin text); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.fit_plugin(plugin text) FROM PUBLIC;


--
-- Name: FUNCTION log_row(); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.log_row() FROM PUBLIC;


--
-- Name: FUNCTION notify_turn(); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.notify_turn() FROM PUBLIC;


--
-- Name: FUNCTION open_to(plugin text); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.open_to(plugin text) FROM PUBLIC;


--
-- Name: FUNCTION plug_in(plugin text); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.plug_in(plugin text) FROM PUBLIC;


--
-- Name: FUNCTION undo(turn uuid); Type: ACL; Schema: cortex; Owner: cortex_owner
--

REVOKE ALL ON FUNCTION cortex.undo(turn uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION cortex.undo(turn uuid) TO cortex_service;
GRANT ALL ON FUNCTION cortex.undo(turn uuid) TO cortex_agent;


--
-- Name: TABLE branches; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.branches TO cortex_service;
GRANT SELECT ON TABLE cortex.branches TO cortex_agent;
GRANT SELECT ON TABLE cortex.branches TO cortex_reader;


--
-- Name: TABLE columns; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.columns TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.columns TO cortex_agent;
GRANT SELECT ON TABLE cortex.columns TO cortex_reader;


--
-- Name: TABLE constraint_columns; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraint_columns TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraint_columns TO cortex_agent;
GRANT SELECT ON TABLE cortex.constraint_columns TO cortex_reader;


--
-- Name: TABLE constraints; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraints TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraints TO cortex_agent;
GRANT SELECT ON TABLE cortex.constraints TO cortex_reader;


--
-- Name: TABLE dependencies; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.dependencies TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.dependencies TO cortex_agent;
GRANT SELECT ON TABLE cortex.dependencies TO cortex_reader;


--
-- Name: TABLE designs; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.designs TO cortex_service;
GRANT SELECT ON TABLE cortex.designs TO cortex_agent;
GRANT SELECT ON TABLE cortex.designs TO cortex_reader;


--
-- Name: TABLE engine_flavors; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.engine_flavors TO cortex_service;
GRANT SELECT ON TABLE cortex.engine_flavors TO cortex_agent;
GRANT SELECT ON TABLE cortex.engine_flavors TO cortex_reader;


--
-- Name: TABLE engine_versions; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.engine_versions TO cortex_service;
GRANT SELECT ON TABLE cortex.engine_versions TO cortex_agent;
GRANT SELECT ON TABLE cortex.engine_versions TO cortex_reader;


--
-- Name: TABLE engines; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.engines TO cortex_service;
GRANT SELECT ON TABLE cortex.engines TO cortex_agent;
GRANT SELECT ON TABLE cortex.engines TO cortex_reader;


--
-- Name: TABLE index_parts; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_parts TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_parts TO cortex_agent;
GRANT SELECT ON TABLE cortex.index_parts TO cortex_reader;


--
-- Name: TABLE indexes; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.indexes TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.indexes TO cortex_agent;
GRANT SELECT ON TABLE cortex.indexes TO cortex_reader;


--
-- Name: TABLE locked_versions; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT ON TABLE cortex.locked_versions TO cortex_service;
GRANT SELECT ON TABLE cortex.locked_versions TO cortex_agent;
GRANT SELECT ON TABLE cortex.locked_versions TO cortex_reader;


--
-- Name: TABLE namespaces; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.namespaces TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.namespaces TO cortex_agent;
GRANT SELECT ON TABLE cortex.namespaces TO cortex_reader;


--
-- Name: TABLE object_kinds; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.object_kinds TO cortex_service;
GRANT SELECT ON TABLE cortex.object_kinds TO cortex_agent;
GRANT SELECT ON TABLE cortex.object_kinds TO cortex_reader;


--
-- Name: TABLE objects; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.objects TO cortex_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.objects TO cortex_agent;
GRANT SELECT ON TABLE cortex.objects TO cortex_reader;


--
-- Name: TABLE operations; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT ON TABLE cortex.operations TO cortex_service;
GRANT SELECT,INSERT ON TABLE cortex.operations TO cortex_agent;
GRANT SELECT ON TABLE cortex.operations TO cortex_reader;


--
-- Name: TABLE plugin_tables; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.plugin_tables TO cortex_service;
GRANT SELECT ON TABLE cortex.plugin_tables TO cortex_agent;
GRANT SELECT ON TABLE cortex.plugin_tables TO cortex_reader;


--
-- Name: TABLE plugins; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.plugins TO cortex_service;
GRANT SELECT ON TABLE cortex.plugins TO cortex_agent;
GRANT SELECT ON TABLE cortex.plugins TO cortex_reader;


--
-- Name: TABLE row_changes; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.row_changes TO cortex_service;
GRANT SELECT ON TABLE cortex.row_changes TO cortex_agent;
GRANT SELECT ON TABLE cortex.row_changes TO cortex_reader;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT ON TABLE cortex.schema_migrations TO cortex_service;
GRANT SELECT ON TABLE cortex.schema_migrations TO cortex_agent;
GRANT SELECT ON TABLE cortex.schema_migrations TO cortex_reader;


--
-- Name: TABLE turns; Type: ACL; Schema: cortex; Owner: cortex_owner
--

GRANT SELECT,INSERT,UPDATE ON TABLE cortex.turns TO cortex_service;
GRANT SELECT,INSERT,UPDATE ON TABLE cortex.turns TO cortex_agent;
GRANT SELECT ON TABLE cortex.turns TO cortex_reader;


--
-- PostgreSQL database dump complete
--


