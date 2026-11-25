-- schema/dump/quill.sql: the schema-only pg_dump of the database cortex and engine_quill make, as the locked design gives it.
-- Written by tools/schema_dump.py --write in a design session; tools/check.sh compares it on every change and CI every day (decision schema-dump).
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
-- Name: cortex; Type: SCHEMA; Schema: -; Owner: sf_owner
--

CREATE SCHEMA cortex;


ALTER SCHEMA cortex OWNER TO sf_owner;

--
-- Name: engine_quill; Type: SCHEMA; Schema: -; Owner: sf_owner
--

CREATE SCHEMA engine_quill;


ALTER SCHEMA engine_quill OWNER TO sf_owner;

--
-- Name: enforce_rules(text); Type: FUNCTION; Schema: cortex; Owner: sf_owner
--

CREATE FUNCTION cortex.enforce_rules(owner text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v     record;
  t     record;
  name  text;
  count integer := 0;
BEGIN
  FOR v IN
    SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = owner AND c.relkind = 'v' AND c.relname LIKE 'broken\_%' ORDER BY c.relname
  LOOP
    name := 'rule:' || owner || '.' || substr(v.relname, 8);
    IF length(name || ':again') > 63 THEN
      RAISE EXCEPTION 'rule name % is too long for its triggers (63 bytes with :again)', name;
    END IF;
    FOR t IN
      SELECT DISTINCT d.refobjid::regclass AS tab
      FROM pg_rewrite r JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
      JOIN pg_class rc ON rc.oid = d.refobjid
      WHERE r.ev_class = v.oid AND d.refclassid = 'pg_class'::regclass AND rc.relkind IN ('r', 'p')
    LOOP
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', name, t.tab);
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', name || ':again', t.tab);
      EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s DEFERRABLE INITIALLY DEFERRED '
                     'FOR EACH ROW EXECUTE FUNCTION cortex.rule_check(%L)', name, t.tab, owner || '.' || v.relname);
      EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s '
                     'FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again(%L)', name || ':again', t.tab, owner || '.' || v.relname);
      count := count + 1;
    END LOOP;
  END LOOP;
  RETURN count;
END $$;


ALTER FUNCTION cortex.enforce_rules(owner text) OWNER TO sf_owner;

--
-- Name: FUNCTION enforce_rules(owner text); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.enforce_rules(owner text) IS 'puts the triggers of every rule view of a namespace on each table the view reads; returns how many tables it guarded';


--
-- Name: grant_roles(text); Type: FUNCTION; Schema: cortex; Owner: sf_owner
--

CREATE FUNCTION cortex.grant_roles(owner text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', owner);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO sf_service, sf_reader', owner);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sf_service', owner);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sf_reader', owner);
  EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sf_service', owner);
  -- and the same for every table and function a later version makes (they are made as sf_owner)
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sf_service', owner);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT ON TABLES TO sf_reader', owner);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO sf_service', owner);
END $$;


ALTER FUNCTION cortex.grant_roles(owner text) OWNER TO sf_owner;

--
-- Name: FUNCTION grant_roles(owner text); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.grant_roles(owner text) IS 'gives an owner''s namespace to sf_service (rows, the rules) and sf_reader (reading), so the schema changes only as sf_owner';


--
-- Name: rule_again(); Type: FUNCTION; Schema: cortex; Owner: sf_owner
--

CREATE FUNCTION cortex.rule_again() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  PERFORM cortex.rule_marks();
  DELETE FROM pg_temp.rule_marks m WHERE m.rule = TG_ARGV[0];
  RETURN NULL;
END $$;


ALTER FUNCTION cortex.rule_again() OWNER TO sf_owner;

--
-- Name: FUNCTION rule_again(); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.rule_again() IS 'after a write to a table a rule reads, marks the rule to be read again at commit';


--
-- Name: rule_check(); Type: FUNCTION; Schema: cortex; Owner: sf_owner
--

CREATE FUNCTION cortex.rule_check() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  rule   text := TG_ARGV[0];
  broken text;
BEGIN
  PERFORM cortex.rule_marks();
  IF EXISTS (SELECT 1 FROM pg_temp.rule_marks m WHERE m.rule = TG_ARGV[0]) THEN
    RETURN NULL;
  END IF;
  EXECUTE format('SELECT string_agg(id, '', '') FROM (SELECT id FROM %s ORDER BY id LIMIT 5) b', rule) INTO broken;
  IF broken IS NOT NULL THEN
    RAISE EXCEPTION 'rule % is broken by %', rule, broken
      USING ERRCODE = 'check_violation', HINT = format('SELECT * FROM %s lists every row breaking it', rule);
  END IF;
  INSERT INTO pg_temp.rule_marks (rule) VALUES (TG_ARGV[0]) ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;


ALTER FUNCTION cortex.rule_check() OWNER TO sf_owner;

--
-- Name: FUNCTION rule_check(); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.rule_check() IS 'at commit, refuses the commit when the rule view named by the trigger lists a row; once held, it is not read again until a write marks it; it runs as sf_owner, so no writer can skip it';


--
-- Name: rule_marks(); Type: FUNCTION; Schema: cortex; Owner: sf_owner
--

CREATE FUNCTION cortex.rule_marks() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  -- The marks of the rules read and held in this transaction: a temporary table this function's owner (sf_owner) makes
  -- and alone may write, emptied at every commit. A table of that name another role made first is refused, so no
  -- writer can mark a rule held that was not read.
  CREATE TEMPORARY TABLE IF NOT EXISTS rule_marks (rule text PRIMARY KEY) ON COMMIT DELETE ROWS;
  IF (SELECT c.relowner FROM pg_class c WHERE c.oid = 'pg_temp.rule_marks'::regclass) <> (SELECT oid FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'pg_temp.rule_marks was made by another role: the rules cannot be held' USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;


ALTER FUNCTION cortex.rule_marks() OWNER TO sf_owner;

--
-- Name: FUNCTION rule_marks(); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.rule_marks() IS 'makes, or checks, the session''s table of rules held in this transaction, which only sf_owner writes';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: engine_features; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.engine_features (
    id text NOT NULL,
    what text NOT NULL,
    since text,
    until text,
    detail text,
    CONSTRAINT engine_features_id_check CHECK ((id ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT engine_features_what_check CHECK ((length(what) >= 1))
);


ALTER TABLE cortex.engine_features OWNER TO sf_owner;

--
-- Name: TABLE engine_features; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.engine_features IS 'what a version of the database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it. Written when the database is made, from the engine''s declaration (decision version-facts), so a person or the agent can ask what a schema may use at its version and what changes when it moves to another.';


--
-- Name: COLUMN engine_features.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_features.id IS 'as the engine names it (vector, check_constraints)';


--
-- Name: COLUMN engine_features.what; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_features.what IS 'what it is, in a few words (the VECTOR type)';


--
-- Name: COLUMN engine_features.since; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_features.since IS 'the first version that has it; NULL for every version from the oldest';


--
-- Name: COLUMN engine_features.until; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_features.until IS 'the last version that has it; NULL for every version to the newest';


--
-- Name: COLUMN engine_features.detail; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_features.detail IS 'what a version alone does not say (enforced from 8.0.16; parsed and ignored before); NULL for nothing';


--
-- Name: engine_versions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.engine_versions (
    id text NOT NULL,
    name text NOT NULL,
    "position" numeric NOT NULL,
    support_ends timestamp with time zone,
    CONSTRAINT engine_versions_id_check CHECK (((length(id) >= 1) AND (length(id) <= 40))),
    CONSTRAINT engine_versions_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT engine_versions_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.engine_versions OWNER TO sf_owner;

--
-- Name: TABLE engine_versions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.engine_versions IS 'the versions of the database the schema''s engine supports, in order, as the engine declares them. Written when the database is made, from the engine''s declaration (decision version-facts); the engine''s code is the one source.';


--
-- Name: COLUMN engine_versions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_versions.id IS 'as the engine names the version (5.7, 8.4)';


--
-- Name: COLUMN engine_versions.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_versions.name IS 'as people say it (MySQL 8.4)';


--
-- Name: COLUMN engine_versions."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_versions."position" IS 'its place, oldest first: a version''s features compare by it';


--
-- Name: COLUMN engine_versions.support_ends; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.engine_versions.support_ends IS 'when its maker stops supporting it; NULL when not announced';


--
-- Name: broken_features_since_before_until; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_features_since_before_until AS
 SELECT 'features-since-before-until'::text AS rule,
    f.id
   FROM ((cortex.engine_features f
     JOIN cortex.engine_versions s ON ((s.id = f.since)))
     JOIN cortex.engine_versions u ON ((u.id = f.until)))
  WHERE (s."position" > u."position");


ALTER VIEW cortex.broken_features_since_before_until OWNER TO sf_owner;

--
-- Name: VIEW broken_features_since_before_until; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_features_since_before_until IS 'A feature''s first version is not after its last.';


--
-- Name: check_constraints; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.check_constraints (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    name text,
    expression text NOT NULL,
    CONSTRAINT check_constraints_check CHECK (((substr(id, 1, (length(object) + 6)) = (object || '.check'::text)) AND (substr(id, (length(object) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT check_constraints_expression_check CHECK ((length(expression) >= 1)),
    CONSTRAINT check_constraints_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.check_constraints OWNER TO sf_owner;

--
-- Name: TABLE check_constraints; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.check_constraints IS 'an expression every row of a table satisfies.';


--
-- Name: COLUMN check_constraints.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.check_constraints.id IS '<object>.check<n>, n given once from id_counters and never reused: o_orders.check1';


--
-- Name: COLUMN check_constraints.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.check_constraints.object IS 'the table or domain it is on';


--
-- Name: COLUMN check_constraints."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.check_constraints."position" IS 'its place among the object''s checks; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN check_constraints.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.check_constraints.name IS 'its constraint name; NULL for none';


--
-- Name: COLUMN check_constraints.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.check_constraints.expression IS 'the expression, in the engine''s SQL, exactly as written';


--
-- Name: composite_type_fields; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.composite_type_fields (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    comment text,
    CONSTRAINT composite_type_fields_check CHECK (((substr(id, 1, (length(object) + 6)) = (object || '.field'::text)) AND (substr(id, (length(object) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT composite_type_fields_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT composite_type_fields_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT composite_type_fields_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.composite_type_fields OWNER TO sf_owner;

--
-- Name: TABLE composite_type_fields; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.composite_type_fields IS 'the fields of a composite type, in order.';


--
-- Name: COLUMN composite_type_fields.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields.id IS '<object>.field<n>, n given once from id_counters and never reused: o_address.field1';


--
-- Name: COLUMN composite_type_fields.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields.object IS 'the type';


--
-- Name: COLUMN composite_type_fields."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields."position" IS 'its place in the type; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN composite_type_fields.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields.name IS 'its name';


--
-- Name: COLUMN composite_type_fields.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields.type IS 'its type, as the engine writes it';


--
-- Name: COLUMN composite_type_fields.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.composite_type_fields.comment IS 'what it holds';


--
-- Name: enum_values; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.enum_values (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    value text NOT NULL,
    CONSTRAINT enum_values_check CHECK (((substr(id, 1, (length(object) + 6)) = (object || '.value'::text)) AND (substr(id, (length(object) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT enum_values_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.enum_values OWNER TO sf_owner;

--
-- Name: TABLE enum_values; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.enum_values IS 'the values of an enumerated type, in order.';


--
-- Name: COLUMN enum_values.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.id IS '<object>.value<n>, n given once from id_counters and never reused: o_order_status.value1';


--
-- Name: COLUMN enum_values.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.object IS 'the type';


--
-- Name: COLUMN enum_values."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values."position" IS 'its place among the values; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN enum_values.value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.value IS 'the value';


--
-- Name: id_counters; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.id_counters (
    id text NOT NULL,
    last integer NOT NULL,
    CONSTRAINT id_counters_id_check CHECK (((length(id) >= 3) AND (id = rtrim(id, '0123456789'::text)))),
    CONSTRAINT id_counters_last_check CHECK ((last >= 1))
);


ALTER TABLE cortex.id_counters OWNER TO sf_owner;

--
-- Name: TABLE id_counters; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.id_counters IS 'the last number given to a kind of part under its parent, so a number is given once and never reused. A part the model gives no id is named <parent>.<word><n> (o_orders.index3); its n is this row''s last plus one, written in the same transaction as the part. A part deleted keeps its number used: the next is still one more.';


--
-- Name: COLUMN id_counters.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.id_counters.id IS 'the id of a part without its number: <parent>.<word> (o_orders.key), <parent>. when the word is empty (o_orders.key1.), <word> when there is no parent (statement)';


--
-- Name: COLUMN id_counters.last; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.id_counters.last IS 'the last number given: the next part is <id><last + 1>';


--
-- Name: index_includes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.index_includes (
    id text NOT NULL,
    index text NOT NULL,
    "position" numeric NOT NULL,
    "column" text NOT NULL,
    CONSTRAINT index_includes_check CHECK (((substr(id, 1, (length(index) + 8)) = (index || '.include'::text)) AND (substr(id, (length(index) + 9)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT index_includes_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.index_includes OWNER TO sf_owner;

--
-- Name: TABLE index_includes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.index_includes IS 'columns carried in an index without being part of its order.';


--
-- Name: COLUMN index_includes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_includes.id IS '<index>.include<n>, n given once from id_counters and never reused: o_orders.index1.include1';


--
-- Name: COLUMN index_includes.index; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_includes.index IS 'the index';


--
-- Name: COLUMN index_includes."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_includes."position" IS 'its place among the index''s included columns; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN index_includes."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_includes."column" IS 'a column of the index''s table';


--
-- Name: index_parts; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.index_parts (
    id text NOT NULL,
    index text NOT NULL,
    "position" numeric NOT NULL,
    "column" text,
    expression text,
    direction text,
    nulls text,
    CONSTRAINT index_parts_check CHECK ((("column" IS NULL) <> (expression IS NULL))),
    CONSTRAINT index_parts_check1 CHECK (((substr(id, 1, (length(index) + 1)) = (index || '.'::text)) AND (substr(id, (length(index) + 2)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT index_parts_direction_check CHECK ((direction = ANY (ARRAY['asc'::text, 'desc'::text]))),
    CONSTRAINT index_parts_nulls_check CHECK ((nulls = ANY (ARRAY['first'::text, 'last'::text]))),
    CONSTRAINT index_parts_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.index_parts OWNER TO sf_owner;

--
-- Name: TABLE index_parts; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.index_parts IS 'the parts of an index, in order: each a column or an expression.';


--
-- Name: COLUMN index_parts.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.id IS '<index>.<n>, n given once from id_counters and never reused: o_orders.index1.1';


--
-- Name: COLUMN index_parts.index; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.index IS 'the index';


--
-- Name: COLUMN index_parts."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts."position" IS 'the part''s place in the index; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN index_parts."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts."column" IS 'the column indexed; NULL for an expression';


--
-- Name: COLUMN index_parts.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.expression IS 'the expression indexed, in the engine''s SQL; NULL for a column';


--
-- Name: COLUMN index_parts.direction; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.direction IS 'its order; NULL for the engine''s default';


--
-- Name: COLUMN index_parts.nulls; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.nulls IS 'where nulls sort; NULL for the engine''s default';


--
-- Name: indexes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.indexes (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    name text NOT NULL,
    "unique" boolean DEFAULT false NOT NULL,
    method text,
    condition text,
    CONSTRAINT indexes_check CHECK (((substr(id, 1, (length(object) + 6)) = (object || '.index'::text)) AND (substr(id, (length(object) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT indexes_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT indexes_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.indexes OWNER TO sf_owner;

--
-- Name: TABLE indexes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.indexes IS 'an index of a table.';


--
-- Name: COLUMN indexes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.id IS '<object>.index<n>, n given once from id_counters and never reused: o_orders.index1';


--
-- Name: COLUMN indexes.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.object IS 'the table it is on';


--
-- Name: COLUMN indexes."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes."position" IS 'its place among the table''s indexes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN indexes.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.name IS 'its name';


--
-- Name: COLUMN indexes."unique"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes."unique" IS 'true for a unique index';


--
-- Name: COLUMN indexes.method; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.method IS 'how it is built, in the engine''s words (btree, fulltext, spatial); NULL for the engine''s default';


--
-- Name: COLUMN indexes.condition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.condition IS 'the rows a partial index covers, in the engine''s SQL; NULL for all';


--
-- Name: layout_pins; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.layout_pins (
    id text NOT NULL,
    view text NOT NULL,
    object text NOT NULL,
    x numeric NOT NULL,
    y numeric NOT NULL,
    CONSTRAINT layout_pins_id_check CHECK ((id ~ '^pin[1-9][0-9]*$'::text)),
    CONSTRAINT layout_pins_view_check CHECK ((view ~ '^[a-z_]+(/[a-z0-9_.]+)?$'::text))
);


ALTER TABLE cortex.layout_pins OWNER TO sf_owner;

--
-- Name: TABLE layout_pins; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.layout_pins IS 'a table''s place pinned in one view of the canvas; everything not pinned is laid out afresh each time. Part of the design (decision canvas-state). The view is the perspective and its focus as the canvas''s address writes them.';


--
-- Name: COLUMN layout_pins.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.layout_pins.id IS 'pin<n>, n given once from id_counters and never reused: pin1';


--
-- Name: COLUMN layout_pins.view; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.layout_pins.view IS 'the view: a perspective and its focus (map, map/billing, table/o_orders) or a custom perspective''s id (p_billing_review)';


--
-- Name: COLUMN layout_pins.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.layout_pins.object IS 'the table or view pinned';


--
-- Name: COLUMN layout_pins.x; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.layout_pins.x IS 'across, in the layout''s grid units from its left';


--
-- Name: COLUMN layout_pins.y; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.layout_pins.y IS 'down, in the layout''s grid units from its top';


--
-- Name: object_reads; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.object_reads (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    reads text NOT NULL,
    CONSTRAINT object_reads_check CHECK ((object <> reads)),
    CONSTRAINT object_reads_check1 CHECK (((substr(id, 1, (length(object) + 5)) = (object || '.read'::text)) AND (substr(id, (length(object) + 6)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT object_reads_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.object_reads OWNER TO sf_owner;

--
-- Name: TABLE object_reads; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.object_reads IS 'the objects an object is made from or reads (a view''s query), worked out by the engine, in the order first named.';


--
-- Name: COLUMN object_reads.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_reads.id IS '<object>.read<n>, n given once from id_counters and never reused: o_current_orders.read1';


--
-- Name: COLUMN object_reads.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_reads.object IS 'the object that reads';


--
-- Name: COLUMN object_reads."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_reads."position" IS 'the order the reader names them in; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN object_reads.reads; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_reads.reads IS 'the object read';


--
-- Name: object_tags; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.object_tags (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    tag text NOT NULL,
    CONSTRAINT object_tags_check CHECK (((substr(id, 1, (length(object) + 4)) = (object || '.tag'::text)) AND (substr(id, (length(object) + 5)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT object_tags_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT object_tags_tag_check CHECK ((length(tag) >= 1))
);


ALTER TABLE cortex.object_tags OWNER TO sf_owner;

--
-- Name: TABLE object_tags; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.object_tags IS 'the tags of an object (scd2, pii), in order.';


--
-- Name: COLUMN object_tags.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags.id IS '<object>.tag<n>, n given once from id_counters and never reused: o_orders.tag1';


--
-- Name: COLUMN object_tags.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags.object IS 'the object tagged';


--
-- Name: COLUMN object_tags."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags."position" IS 'its place among the object''s tags; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN object_tags.tag; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags.tag IS 'the tag';


--
-- Name: partition_fields; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.partition_fields (
    id text NOT NULL,
    partitioning text NOT NULL,
    "position" numeric NOT NULL,
    "column" text,
    expression text,
    transform text,
    CONSTRAINT partition_fields_check CHECK ((("column" IS NULL) <> (expression IS NULL))),
    CONSTRAINT partition_fields_check1 CHECK (((substr(id, 1, (length(partitioning) + 3)) = (partitioning || '.by'::text)) AND (substr(id, (length(partitioning) + 4)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT partition_fields_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.partition_fields OWNER TO sf_owner;

--
-- Name: TABLE partition_fields; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.partition_fields IS 'what a table is partitioned by, in order: a column or an expression, through a transform.';


--
-- Name: COLUMN partition_fields.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields.id IS '<object>.by<n>, n given once from id_counters and never reused: o_events.by1';


--
-- Name: COLUMN partition_fields.partitioning; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields.partitioning IS 'the partitioning';


--
-- Name: COLUMN partition_fields."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields."position" IS 'its place in the partitioning; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN partition_fields."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields."column" IS 'the column; NULL for an expression';


--
-- Name: COLUMN partition_fields.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields.expression IS 'the expression, in the engine''s SQL; NULL for a column';


--
-- Name: COLUMN partition_fields.transform; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_fields.transform IS 'the transform, in the engine''s words (day, bucket[16]); NULL for the value itself';


--
-- Name: partitions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.partitions (
    id text NOT NULL,
    partitioning text NOT NULL,
    "position" numeric NOT NULL,
    name text NOT NULL,
    bounds text NOT NULL,
    CONSTRAINT partitions_check CHECK (((substr(id, 1, (length(partitioning) + 10)) = (partitioning || '.partition'::text)) AND (substr(id, (length(partitioning) + 11)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT partitions_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT partitions_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.partitions OWNER TO sf_owner;

--
-- Name: TABLE partitions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.partitions IS 'the partitions defined in a table itself, in order, with their bounds.';


--
-- Name: COLUMN partitions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.id IS '<object>.partition<n>, n given once from id_counters and never reused: o_events.partition1';


--
-- Name: COLUMN partitions.partitioning; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.partitioning IS 'the partitioning';


--
-- Name: COLUMN partitions."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions."position" IS 'its place among the partitions; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN partitions.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.name IS 'its name';


--
-- Name: COLUMN partitions.bounds; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.bounds IS 'its bounds in the engine''s SQL (VALUES LESS THAN (2025)); empty when its strategy gives none';


--
-- Name: perspective_members; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.perspective_members (
    id text NOT NULL,
    perspective text NOT NULL,
    object text NOT NULL,
    "column" text,
    "position" numeric NOT NULL,
    colour text,
    CONSTRAINT perspective_members_check CHECK (((substr(id, 1, (length(perspective) + 7)) = (perspective || '.member'::text)) AND (substr(id, (length(perspective) + 8)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT perspective_members_colour_check CHECK ((colour ~ '^#[0-9a-f]{6}$'::text)),
    CONSTRAINT perspective_members_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.perspective_members OWNER TO sf_owner;

--
-- Name: TABLE perspective_members; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.perspective_members IS 'the tables and columns a custom perspective shows, in order.';


--
-- Name: COLUMN perspective_members.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members.id IS '<perspective>.member<n>, n given once from id_counters and never reused: p_billing_review.member1';


--
-- Name: COLUMN perspective_members.perspective; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members.perspective IS 'the perspective';


--
-- Name: COLUMN perspective_members.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members.object IS 'the table or view shown';


--
-- Name: COLUMN perspective_members."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members."column" IS 'one of its columns, shown alone; NULL for the whole object';


--
-- Name: COLUMN perspective_members."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members."position" IS 'its place in the perspective; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN perspective_members.colour; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.perspective_members.colour IS 'its own colour, as #rrggbb; NULL to follow the perspective''s colour_by';


--
-- Name: pinned_notes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.pinned_notes (
    id text NOT NULL,
    target_kind text NOT NULL,
    target_id text NOT NULL,
    "position" numeric NOT NULL,
    text text NOT NULL,
    done boolean DEFAULT false NOT NULL,
    written_by text NOT NULL,
    CONSTRAINT pinned_notes_id_check CHECK ((id ~ '^note[1-9][0-9]*$'::text)),
    CONSTRAINT pinned_notes_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT pinned_notes_target_id_check CHECK ((length(target_id) >= 1)),
    CONSTRAINT pinned_notes_target_kind_check CHECK ((target_kind = ANY (ARRAY['schema'::text, 'namespace'::text, 'object'::text, 'column'::text, 'relationship'::text, 'area'::text, 'part'::text, 'turn'::text, 'locked_version'::text]))),
    CONSTRAINT pinned_notes_text_check CHECK ((length(text) >= 1)),
    CONSTRAINT pinned_notes_written_by_check CHECK ((length(written_by) >= 1))
);


ALTER TABLE cortex.pinned_notes OWNER TO sf_owner;

--
-- Name: TABLE pinned_notes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.pinned_notes IS 'a note pinned to anything of the design, for people and the agent (@notes). Part of the design (decision canvas-state): shared by everyone on the schema and the agent, every change an operation of a turn. A note is not removed with what it is pinned to: the operation that removes a part removes or moves its notes in the same turn, and the rule notes-on-what-exists refuses a commit that leaves one pinned to nothing.';


--
-- Name: COLUMN pinned_notes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.id IS 'note<n>, n given once from id_counters and never reused: note1';


--
-- Name: COLUMN pinned_notes.target_kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.target_kind IS 'what it is pinned to: a part is any numbered part (a key, an index, a check…)';


--
-- Name: COLUMN pinned_notes.target_id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.target_id IS 'the id of what it is pinned to (o_orders, c_orders_total, o_orders.key1, a turn''s id); for the schema, schema';


--
-- Name: COLUMN pinned_notes."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes."position" IS 'its place among the notes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN pinned_notes.text; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.text IS 'the note, as written';


--
-- Name: COLUMN pinned_notes.done; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.done IS 'true once it has been worked through';


--
-- Name: COLUMN pinned_notes.written_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.pinned_notes.written_by IS 'who wrote it: a person''s name or the agent''s label';


--
-- Name: relationship_columns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.relationship_columns (
    id text NOT NULL,
    relationship text NOT NULL,
    "position" numeric NOT NULL,
    from_column text NOT NULL,
    to_column text NOT NULL,
    CONSTRAINT relationship_columns_check CHECK (((substr(id, 1, (length(relationship) + 1)) = (relationship || '.'::text)) AND (substr(id, (length(relationship) + 2)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT relationship_columns_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.relationship_columns OWNER TO sf_owner;

--
-- Name: TABLE relationship_columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.relationship_columns IS 'the column pairs of a relationship, in order: from_column refers to to_column.';


--
-- Name: COLUMN relationship_columns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationship_columns.id IS '<relationship>.<n>, n given once from id_counters and never reused: l_orders_customer.1';


--
-- Name: COLUMN relationship_columns.relationship; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationship_columns.relationship IS 'the relationship';


--
-- Name: COLUMN relationship_columns."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationship_columns."position" IS 'the pair''s place in the relationship; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN relationship_columns.from_column; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationship_columns.from_column IS 'a column of the relationship''s from_object';


--
-- Name: COLUMN relationship_columns.to_column; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationship_columns.to_column IS 'a column of the relationship''s to_object';


--
-- Name: routine_parameters; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.routine_parameters (
    id text NOT NULL,
    routine text NOT NULL,
    "position" numeric NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    mode text,
    default_value text,
    CONSTRAINT routine_parameters_check CHECK (((substr(id, 1, (length(routine) + 6)) = (routine || '.param'::text)) AND (substr(id, (length(routine) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT routine_parameters_mode_check CHECK ((mode = ANY (ARRAY['in'::text, 'out'::text, 'in_out'::text]))),
    CONSTRAINT routine_parameters_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT routine_parameters_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT routine_parameters_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.routine_parameters OWNER TO sf_owner;

--
-- Name: TABLE routine_parameters; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.routine_parameters IS 'the parameters of a routine, in order.';


--
-- Name: COLUMN routine_parameters.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.id IS '<routine>.param<n>, n given once from id_counters and never reused: o_close_customer.param1';


--
-- Name: COLUMN routine_parameters.routine; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.routine IS 'the routine';


--
-- Name: COLUMN routine_parameters."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters."position" IS 'its place among the parameters; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN routine_parameters.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.name IS 'its name';


--
-- Name: COLUMN routine_parameters.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.type IS 'its type, as the engine writes it';


--
-- Name: COLUMN routine_parameters.mode; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.mode IS 'how it is passed; NULL for in';


--
-- Name: COLUMN routine_parameters.default_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.default_value IS 'its default, in the engine''s SQL; NULL for none';


--
-- Name: sort_fields; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.sort_fields (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    "column" text NOT NULL,
    transform text,
    direction text,
    nulls text,
    CONSTRAINT sort_fields_check CHECK (((substr(id, 1, (length(object) + 6)) = (object || '.order'::text)) AND (substr(id, (length(object) + 7)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT sort_fields_direction_check CHECK ((direction = ANY (ARRAY['asc'::text, 'desc'::text]))),
    CONSTRAINT sort_fields_nulls_check CHECK ((nulls = ANY (ARRAY['first'::text, 'last'::text]))),
    CONSTRAINT sort_fields_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.sort_fields OWNER TO sf_owner;

--
-- Name: TABLE sort_fields; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.sort_fields IS 'the order a table''s rows are written in (a sort order, a clustering).';


--
-- Name: COLUMN sort_fields.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.id IS '<object>.order<n>, n given once from id_counters and never reused: o_events.order1';


--
-- Name: COLUMN sort_fields.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.object IS 'the table';


--
-- Name: COLUMN sort_fields."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields."position" IS 'its place in the order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN sort_fields."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields."column" IS 'the column ordered by';


--
-- Name: COLUMN sort_fields.transform; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.transform IS 'the transform, in the engine''s words; NULL for the value itself';


--
-- Name: COLUMN sort_fields.direction; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.direction IS 'NULL for the engine''s default';


--
-- Name: COLUMN sort_fields.nulls; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.nulls IS 'NULL for the engine''s default';


--
-- Name: table_key_columns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.table_key_columns (
    id text NOT NULL,
    key text NOT NULL,
    "position" numeric NOT NULL,
    "column" text NOT NULL,
    CONSTRAINT table_key_columns_check CHECK (((substr(id, 1, (length(key) + 1)) = (key || '.'::text)) AND (substr(id, (length(key) + 2)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT table_key_columns_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.table_key_columns OWNER TO sf_owner;

--
-- Name: TABLE table_key_columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.table_key_columns IS 'the columns of a key, in order.';


--
-- Name: COLUMN table_key_columns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_key_columns.id IS '<key>.<n>, n given once from id_counters and never reused: o_orders.key1.1';


--
-- Name: COLUMN table_key_columns.key; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_key_columns.key IS 'the key';


--
-- Name: COLUMN table_key_columns."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_key_columns."position" IS 'the column''s place in the key; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN table_key_columns."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_key_columns."column" IS 'a column of the key''s table';


--
-- Name: table_keys; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.table_keys (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    what text NOT NULL,
    name text,
    CONSTRAINT table_keys_check CHECK (((substr(id, 1, (length(object) + 4)) = (object || '.key'::text)) AND (substr(id, (length(object) + 5)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT table_keys_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT table_keys_what_check CHECK ((what = ANY (ARRAY['primary'::text, 'unique'::text, 'identifier'::text])))
);


ALTER TABLE cortex.table_keys OWNER TO sf_owner;

--
-- Name: TABLE table_keys; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.table_keys IS 'a table''s primary key, its unique keys and its identifier fields.';


--
-- Name: COLUMN table_keys.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_keys.id IS '<object>.key<n>, n given once from id_counters and never reused: o_orders.key1';


--
-- Name: COLUMN table_keys.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_keys.object IS 'the table it is on';


--
-- Name: COLUMN table_keys."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_keys."position" IS 'its place among the table''s keys: the primary key first; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN table_keys.what; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_keys.what IS 'primary, unique, or identifier: columns that identify a row with no constraint enforcing it';


--
-- Name: COLUMN table_keys.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_keys.name IS 'its constraint name; NULL for none';


--
-- Name: trigger_events; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.trigger_events (
    id text NOT NULL,
    trigger text NOT NULL,
    "position" numeric NOT NULL,
    change text NOT NULL,
    CONSTRAINT trigger_events_change_check CHECK ((change = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text, 'truncate'::text]))),
    CONSTRAINT trigger_events_check CHECK (((substr(id, 1, (length(trigger) + 3)) = (trigger || '.on'::text)) AND (substr(id, (length(trigger) + 4)) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT trigger_events_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.trigger_events OWNER TO sf_owner;

--
-- Name: TABLE trigger_events; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.trigger_events IS 'the changes a trigger fires on, in order.';


--
-- Name: COLUMN trigger_events.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.trigger_events.id IS '<trigger>.on<n>, n given once from id_counters and never reused: o_orders_touch.on1';


--
-- Name: COLUMN trigger_events.trigger; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.trigger_events.trigger IS 'the trigger';


--
-- Name: COLUMN trigger_events."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.trigger_events."position" IS 'its place among the trigger''s changes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN trigger_events.change; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.trigger_events.change IS 'the change it fires on';


--
-- Name: verbatim_statements; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.verbatim_statements (
    id text NOT NULL,
    "position" numeric NOT NULL,
    kind text NOT NULL,
    text text NOT NULL,
    after_namespace text,
    after_object text,
    CONSTRAINT verbatim_statements_check CHECK (((after_namespace IS NULL) OR (after_object IS NULL))),
    CONSTRAINT verbatim_statements_id_check CHECK ((id ~ '^statement[1-9][0-9]*$'::text)),
    CONSTRAINT verbatim_statements_kind_check CHECK ((length(kind) >= 1)),
    CONSTRAINT verbatim_statements_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.verbatim_statements OWNER TO sf_owner;

--
-- Name: TABLE verbatim_statements; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.verbatim_statements IS 'what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place.';


--
-- Name: COLUMN verbatim_statements.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.id IS 'statement<n>, n given once from id_counters and never reused: statement1';


--
-- Name: COLUMN verbatim_statements."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements."position" IS 'its place in the order it was read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN verbatim_statements.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.kind IS 'what it is, in the engine''s words (account, grant, other)';


--
-- Name: COLUMN verbatim_statements.text; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.text IS 'the statement, exactly as written';


--
-- Name: COLUMN verbatim_statements.after_namespace; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.after_namespace IS 'the namespace it is written after (a statement kept after a switch of namespace); NULL when it follows an object or the start';


--
-- Name: COLUMN verbatim_statements.after_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.after_object IS 'the object it is written after; NULL when it follows a namespace or the start';


--
-- Name: broken_ids_within_their_counters; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_ids_within_their_counters AS
 SELECT 'ids-within-their-counters'::text AS rule,
    p.id
   FROM (( SELECT check_constraints.id
           FROM cortex.check_constraints
        UNION ALL
         SELECT composite_type_fields.id
           FROM cortex.composite_type_fields
        UNION ALL
         SELECT enum_values.id
           FROM cortex.enum_values
        UNION ALL
         SELECT indexes.id
           FROM cortex.indexes
        UNION ALL
         SELECT object_tags.id
           FROM cortex.object_tags
        UNION ALL
         SELECT object_reads.id
           FROM cortex.object_reads
        UNION ALL
         SELECT partition_fields.id
           FROM cortex.partition_fields
        UNION ALL
         SELECT partitions.id
           FROM cortex.partitions
        UNION ALL
         SELECT routine_parameters.id
           FROM cortex.routine_parameters
        UNION ALL
         SELECT table_keys.id
           FROM cortex.table_keys
        UNION ALL
         SELECT sort_fields.id
           FROM cortex.sort_fields
        UNION ALL
         SELECT table_key_columns.id
           FROM cortex.table_key_columns
        UNION ALL
         SELECT relationship_columns.id
           FROM cortex.relationship_columns
        UNION ALL
         SELECT index_parts.id
           FROM cortex.index_parts
        UNION ALL
         SELECT index_includes.id
           FROM cortex.index_includes
        UNION ALL
         SELECT trigger_events.id
           FROM cortex.trigger_events
        UNION ALL
         SELECT verbatim_statements.id
           FROM cortex.verbatim_statements
        UNION ALL
         SELECT pinned_notes.id
           FROM cortex.pinned_notes
        UNION ALL
         SELECT perspective_members.id
           FROM cortex.perspective_members
        UNION ALL
         SELECT layout_pins.id
           FROM cortex.layout_pins) p
     LEFT JOIN cortex.id_counters c ON ((c.id = rtrim(p.id, '0123456789'::text))))
  WHERE ((c.id IS NULL) OR (c.last < (substr(p.id, (length(rtrim(p.id, '0123456789'::text)) + 1)))::integer));


ALTER VIEW cortex.broken_ids_within_their_counters OWNER TO sf_owner;

--
-- Name: VIEW broken_ids_within_their_counters; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_ids_within_their_counters IS 'A numbered part''s number was given by its counter: the counter exists and is at least the number, so it is never given again.';


--
-- Name: columns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.columns (
    id text NOT NULL,
    object text NOT NULL,
    "position" numeric NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    nullable boolean NOT NULL,
    comment text,
    default_value text,
    generated_expression text,
    generated_stored boolean,
    CONSTRAINT columns_check CHECK (((generated_expression IS NULL) = (generated_stored IS NULL))),
    CONSTRAINT columns_id_check CHECK (((id ~ '^c_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT columns_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT columns_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT columns_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.columns OWNER TO sf_owner;

--
-- Name: TABLE columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.columns IS 'the columns of an object, in order, with what every engine says of a column.';


--
-- Name: COLUMN columns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.id IS 'the model''s id (c_orders_total), kept when the name changes';


--
-- Name: COLUMN columns.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.object IS 'the object it belongs to';


--
-- Name: COLUMN columns."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns."position" IS 'its place in the object: 1, 2, 3; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN columns.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.name IS 'total';


--
-- Name: COLUMN columns.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.type IS 'its type as the engine writes it (decimal(12,2)); only the engine reads it';


--
-- Name: COLUMN columns.nullable; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.nullable IS 'true when it may hold null';


--
-- Name: COLUMN columns.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.comment IS 'what it holds: written into its SQL';


--
-- Name: COLUMN columns.default_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.default_value IS 'its default, an expression in the engine''s SQL; NULL for none';


--
-- Name: COLUMN columns.generated_expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.generated_expression IS 'the expression it is computed from, in the engine''s SQL; NULL when it is not computed';


--
-- Name: COLUMN columns.generated_stored; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.generated_stored IS 'for a computed column: 1 computed when written and stored, 0 computed when read';


--
-- Name: broken_index_columns_on_their_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_index_columns_on_their_table AS
 SELECT 'index-columns-on-their-table'::text AS rule,
    p.id
   FROM ((cortex.index_parts p
     JOIN cortex.indexes i ON ((i.id = p.index)))
     JOIN cortex.columns c ON ((c.id = p."column")))
  WHERE (c.object <> i.object)
UNION ALL
 SELECT 'index-columns-on-their-table'::text AS rule,
    x.id
   FROM ((cortex.index_includes x
     JOIN cortex.indexes i ON ((i.id = x.index)))
     JOIN cortex.columns c ON ((c.id = x."column")))
  WHERE (c.object <> i.object);


ALTER VIEW cortex.broken_index_columns_on_their_table OWNER TO sf_owner;

--
-- Name: VIEW broken_index_columns_on_their_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_index_columns_on_their_table IS 'Every column an index orders by or includes is a column of the index''s table.';


--
-- Name: broken_key_columns_on_their_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_key_columns_on_their_table AS
 SELECT 'key-columns-on-their-table'::text AS rule,
    kc.id
   FROM ((cortex.table_key_columns kc
     JOIN cortex.table_keys k ON ((k.id = kc.key)))
     JOIN cortex.columns c ON ((c.id = kc."column")))
  WHERE (c.object <> k.object);


ALTER VIEW cortex.broken_key_columns_on_their_table OWNER TO sf_owner;

--
-- Name: VIEW broken_key_columns_on_their_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_key_columns_on_their_table IS 'Every column of a key is a column of the key''s table.';


--
-- Name: locked_versions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.locked_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    number integer NOT NULL,
    at_operation uuid NOT NULL,
    hash text NOT NULL,
    message text NOT NULL,
    locked_by text NOT NULL,
    locked_at timestamp with time zone NOT NULL,
    git_commit text,
    git_tag text,
    CONSTRAINT locked_versions_git_commit_check CHECK (((git_commit IS NULL) OR (length(git_commit) = ANY (ARRAY[40, 64])))),
    CONSTRAINT locked_versions_hash_check CHECK ((length(hash) = 64)),
    CONSTRAINT locked_versions_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT locked_versions_message_check CHECK ((length(message) >= 1)),
    CONSTRAINT locked_versions_number_check CHECK ((number >= 1))
);


ALTER TABLE cortex.locked_versions OWNER TO sf_owner;

--
-- Name: TABLE locked_versions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.locked_versions IS 'a locked version of the schema: the log up to one operation, its number and its hash.';


--
-- Name: COLUMN locked_versions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.id IS 'UUIDv7, issued when it is locked';


--
-- Name: COLUMN locked_versions.number; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.number IS 'v1, v2, v3: one more than the version before';


--
-- Name: COLUMN locked_versions.at_operation; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.at_operation IS 'the last operation it holds: replaying the log to it gives the version';


--
-- Name: COLUMN locked_versions.hash; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.hash IS 'SHA-256 of the version''s model in its canonical file form, hex';


--
-- Name: COLUMN locked_versions.message; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.message IS 'what the version is, in a sentence';


--
-- Name: COLUMN locked_versions.locked_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.locked_by IS 'who locked it';


--
-- Name: COLUMN locked_versions.locked_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.locked_at IS 'when';


--
-- Name: COLUMN locked_versions.git_commit; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.git_commit IS 'the commit its definitions were written in (SHA-1 or SHA-256); NULL outside a git repository';


--
-- Name: COLUMN locked_versions.git_tag; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.git_tag IS 'the tag of that commit (schema/shop/v3); NULL outside a git repository';


--
-- Name: namespaces; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.namespaces (
    id text NOT NULL,
    name text NOT NULL,
    parent text,
    "position" numeric NOT NULL,
    comment text,
    CONSTRAINT namespaces_id_check CHECK (((id ~ '^n_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT namespaces_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT namespaces_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.namespaces OWNER TO sf_owner;

--
-- Name: TABLE namespaces; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.namespaces IS 'the levels that hold objects, nested under another or at the top. What the engine calls one (a database, a schema, a shelf) is the engine''s word, never stored here.';


--
-- Name: COLUMN namespaces.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.id IS 'the model''s id (n_sales), kept when the name changes';


--
-- Name: COLUMN namespaces.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.name IS 'sales';


--
-- Name: COLUMN namespaces.parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.parent IS 'the namespace it sits in; NULL at the top';


--
-- Name: COLUMN namespaces."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces."position" IS 'its place among the namespaces, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN namespaces.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.comment IS 'what it holds';


--
-- Name: objects; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.objects (
    id text NOT NULL,
    kind text NOT NULL,
    namespace text NOT NULL,
    name text NOT NULL,
    "position" numeric NOT NULL,
    comment text,
    notes text,
    area text,
    CONSTRAINT objects_id_check CHECK (((id ~ '^o_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT objects_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT objects_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.objects OWNER TO sf_owner;

--
-- Name: TABLE objects; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds: tables, views, routines, triggers, whatever kinds the engine has.';


--
-- Name: COLUMN objects.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.id IS 'the model''s id (o_orders), kept when the name changes';


--
-- Name: COLUMN objects.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.kind IS 'one of the engine''s kinds: no other is accepted';


--
-- Name: COLUMN objects.namespace; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it';


--
-- Name: COLUMN objects.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.name IS 'orders';


--
-- Name: COLUMN objects."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects."position" IS 'its place among the objects, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN objects.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';


--
-- Name: COLUMN objects.notes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';


--
-- Name: COLUMN objects.area; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.area IS 'the area it belongs to; NULL for none';


--
-- Name: relationships; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.relationships (
    id text NOT NULL,
    name text,
    from_object text NOT NULL,
    to_object text NOT NULL,
    "position" numeric NOT NULL,
    enforced boolean DEFAULT true NOT NULL,
    on_delete text,
    on_update text,
    match_kind text,
    "deferrable" boolean DEFAULT false NOT NULL,
    initially_deferred boolean,
    CONSTRAINT relationships_check CHECK (("deferrable" = (initially_deferred IS NOT NULL))),
    CONSTRAINT relationships_id_check CHECK (((id ~ '^l_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT relationships_on_delete_check CHECK ((on_delete = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT relationships_on_update_check CHECK ((on_update = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT relationships_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.relationships OWNER TO sf_owner;

--
-- Name: TABLE relationships; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.relationships IS 'a relationship from columns of one object to columns of another: a foreign key, or one the design only draws.';


--
-- Name: COLUMN relationships.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.id IS 'the model''s id (l_orders_customer)';


--
-- Name: COLUMN relationships.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.name IS 'its constraint name; NULL for none';


--
-- Name: COLUMN relationships.from_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.from_object IS 'the object that refers';


--
-- Name: COLUMN relationships.to_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.to_object IS 'the object referred to';


--
-- Name: COLUMN relationships."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships."position" IS 'its place among the relationships; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN relationships.enforced; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.enforced IS 'true when the database enforces it (a foreign key); false when the design only draws it';


--
-- Name: COLUMN relationships.on_delete; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.on_delete IS 'what happens when the row referred to is deleted; NULL for the engine''s default';


--
-- Name: COLUMN relationships.on_update; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.on_update IS 'what happens when its key changes; NULL for the engine''s default';


--
-- Name: COLUMN relationships.match_kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.match_kind IS 'how a key of several columns with some null matches, in the engine''s words (full, simple); NULL for the engine''s default';


--
-- Name: COLUMN relationships."deferrable"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships."deferrable" IS 'true when it may be checked at the end of a transaction';


--
-- Name: COLUMN relationships.initially_deferred; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.relationships.initially_deferred IS 'for a deferrable relationship: true when it is checked at the end unless said otherwise';


--
-- Name: schema_identity; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.schema_identity (
    id uuid NOT NULL,
    name text NOT NULL,
    engine text NOT NULL,
    engine_version text NOT NULL,
    comment text,
    section_format integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    one boolean DEFAULT true NOT NULL,
    CONSTRAINT schema_identity_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT schema_identity_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100))),
    CONSTRAINT schema_identity_one_check CHECK (one),
    CONSTRAINT schema_identity_section_format_check CHECK ((section_format >= 0))
);


ALTER TABLE cortex.schema_identity OWNER TO sf_owner;

--
-- Name: TABLE schema_identity; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.schema_identity IS 'the schema this database holds, exactly one row. Written when the database is made; only name, comment and engine_version ever change, each by an operation.';


--
-- Name: COLUMN schema_identity.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.id IS 'UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema, and what its database is named from (sf_<id, hex>)';


--
-- Name: COLUMN schema_identity.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.name IS 'as people call it (shop); a rename never moves its database';


--
-- Name: COLUMN schema_identity.engine; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.engine IS 'the id of the engine it is designed for, as the registry knows it (mysql)';


--
-- Name: COLUMN schema_identity.engine_version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.engine_version IS 'one of the engine''s versions; it decides which features the schema is offered (8.4)';


--
-- Name: COLUMN schema_identity.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.comment IS 'what the schema is for, in a sentence or two';


--
-- Name: COLUMN schema_identity.section_format; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.section_format IS 'the engine''s storage version its options were written in, as the schema''s section holds it (0 when it says none)';


--
-- Name: COLUMN schema_identity.created_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.created_at IS 'when the database was made';


--
-- Name: COLUMN schema_identity.one; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.one IS 'keeps the table to one row';


--
-- Name: subject_areas; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.subject_areas (
    id text NOT NULL,
    name text NOT NULL,
    colour text,
    "position" numeric NOT NULL,
    CONSTRAINT subject_areas_id_check CHECK (((id ~ '^a_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT subject_areas_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT subject_areas_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.subject_areas OWNER TO sf_owner;

--
-- Name: TABLE subject_areas; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.subject_areas IS 'groups of objects by subject (billing, catalog), across namespaces.';


--
-- Name: COLUMN subject_areas.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.subject_areas.id IS 'the model''s id (a_billing)';


--
-- Name: COLUMN subject_areas.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.subject_areas.name IS 'billing';


--
-- Name: COLUMN subject_areas.colour; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.subject_areas.colour IS 'its colour on the canvas, as the model holds it; NULL for the canvas''s choice';


--
-- Name: COLUMN subject_areas."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.subject_areas."position" IS 'its place among the areas; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: turns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.turns (
    id uuid DEFAULT uuidv7() NOT NULL,
    by text NOT NULL,
    who text NOT NULL,
    summary text NOT NULL,
    state text NOT NULL,
    undoes uuid,
    started_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    decided_at timestamp with time zone,
    decided_by text,
    CONSTRAINT turns_by_check CHECK ((by = ANY (ARRAY['agent'::text, 'person'::text, 'import'::text]))),
    CONSTRAINT turns_check CHECK (((state = 'open'::text) = (decided_at IS NULL))),
    CONSTRAINT turns_check1 CHECK (((decided_at IS NULL) = (decided_by IS NULL))),
    CONSTRAINT turns_check2 CHECK (((undoes IS NULL) OR (undoes <> id))),
    CONSTRAINT turns_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT turns_state_check CHECK ((state = ANY (ARRAY['open'::text, 'accepted'::text, 'rejected'::text, 'undone'::text]))),
    CONSTRAINT turns_summary_check CHECK ((length(summary) >= 1)),
    CONSTRAINT turns_who_check CHECK ((length(who) >= 1))
);


ALTER TABLE cortex.turns OWNER TO sf_owner;

--
-- Name: TABLE turns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.turns IS 'one round of work: the agent''s answer to one prompt, a person''s edit, an import, an undo. Every change belongs to one (decision 8). A turn is accepted or rejected whole; a rejected or undone turn stays, and the turn that takes it back names it in undoes (decision 9).';


--
-- Name: COLUMN turns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.id IS 'UUIDv7, issued by the database (uuidv7()), increasing within a session: its order is the order turns began';


--
-- Name: COLUMN turns.by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.by IS 'who made it';


--
-- Name: COLUMN turns.who; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.who IS 'the agent''s label (claude-opus-5-5), the person''s name, or the source read (a file path, a connection name)';


--
-- Name: COLUMN turns.summary; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.summary IS 'what it does, in one line, as its maker gives it';


--
-- Name: COLUMN turns.state; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.state IS 'open while it awaits a verdict; then accepted, rejected or undone';


--
-- Name: COLUMN turns.undoes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.undoes IS 'the turn this one takes back, by applying its inverses; NULL for any other turn';


--
-- Name: COLUMN turns.started_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.started_at IS 'when its first change landed';


--
-- Name: COLUMN turns.ended_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.ended_at IS 'when its maker ended it; NULL while it is still being made';


--
-- Name: COLUMN turns.decided_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.decided_at IS 'when it was accepted, rejected or undone; NULL while open';


--
-- Name: COLUMN turns.decided_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.decided_by IS 'who decided it; NULL while open';


--
-- Name: broken_notes_on_what_exists; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_notes_on_what_exists AS
 SELECT 'notes-on-what-exists'::text AS rule,
    id
   FROM cortex.pinned_notes n
  WHERE (NOT
        CASE target_kind
            WHEN 'schema'::text THEN ((target_id = 'schema'::text) AND (EXISTS ( SELECT 1
               FROM cortex.schema_identity)))
            WHEN 'namespace'::text THEN (EXISTS ( SELECT 1
               FROM cortex.namespaces x
              WHERE (x.id = n.target_id)))
            WHEN 'object'::text THEN (EXISTS ( SELECT 1
               FROM cortex.objects x
              WHERE (x.id = n.target_id)))
            WHEN 'column'::text THEN (EXISTS ( SELECT 1
               FROM cortex.columns x
              WHERE (x.id = n.target_id)))
            WHEN 'relationship'::text THEN (EXISTS ( SELECT 1
               FROM cortex.relationships x
              WHERE (x.id = n.target_id)))
            WHEN 'area'::text THEN (EXISTS ( SELECT 1
               FROM cortex.subject_areas x
              WHERE (x.id = n.target_id)))
            WHEN 'turn'::text THEN (EXISTS ( SELECT 1
               FROM cortex.turns x
              WHERE ((x.id)::text = n.target_id)))
            WHEN 'locked_version'::text THEN (EXISTS ( SELECT 1
               FROM cortex.locked_versions x
              WHERE ((x.id)::text = n.target_id)))
            ELSE (target_id IN ( SELECT table_keys.id
               FROM cortex.table_keys
            UNION ALL
             SELECT check_constraints.id
               FROM cortex.check_constraints
            UNION ALL
             SELECT indexes.id
               FROM cortex.indexes
            UNION ALL
             SELECT partitions.id
               FROM cortex.partitions
            UNION ALL
             SELECT sort_fields.id
               FROM cortex.sort_fields
            UNION ALL
             SELECT enum_values.id
               FROM cortex.enum_values
            UNION ALL
             SELECT composite_type_fields.id
               FROM cortex.composite_type_fields
            UNION ALL
             SELECT routine_parameters.id
               FROM cortex.routine_parameters
            UNION ALL
             SELECT trigger_events.id
               FROM cortex.trigger_events
            UNION ALL
             SELECT verbatim_statements.id
               FROM cortex.verbatim_statements))
        END);


ALTER VIEW cortex.broken_notes_on_what_exists OWNER TO sf_owner;

--
-- Name: VIEW broken_notes_on_what_exists; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_notes_on_what_exists IS 'A pinned note is pinned to something the design holds: its target, of its kind, exists.';


--
-- Name: domains; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.domains (
    id text NOT NULL,
    base text NOT NULL,
    default_value text,
    nullable boolean DEFAULT true NOT NULL,
    CONSTRAINT domains_base_check CHECK ((length(base) >= 1))
);


ALTER TABLE cortex.domains OWNER TO sf_owner;

--
-- Name: TABLE domains; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.domains IS 'a type narrowed by a default, a not null and checks (its checks are in check_constraints).';


--
-- Name: COLUMN domains.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.domains.id IS 'the domain';


--
-- Name: COLUMN domains.base; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.domains.base IS 'the type it narrows, as the engine writes it';


--
-- Name: COLUMN domains.default_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.domains.default_value IS 'its default, in the engine''s SQL; NULL for none';


--
-- Name: COLUMN domains.nullable; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.domains.nullable IS 'true when it may hold null';


--
-- Name: routines; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.routines (
    id text NOT NULL,
    returns text,
    language text,
    deterministic boolean,
    security text,
    body text NOT NULL
);


ALTER TABLE cortex.routines OWNER TO sf_owner;

--
-- Name: TABLE routines; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.routines IS 'a procedure, a function or a library: what it returns, how it runs, and its body exactly as written.';


--
-- Name: COLUMN routines.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.id IS 'the routine';


--
-- Name: COLUMN routines.returns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.returns IS 'what a function returns, as the engine writes the type; NULL for a procedure';


--
-- Name: COLUMN routines.language; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.language IS 'its language in the engine''s words (sql, javascript); NULL for the engine''s own';


--
-- Name: COLUMN routines.deterministic; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.deterministic IS 'true when the same arguments always give the same result; NULL when it says nothing';


--
-- Name: COLUMN routines.security; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.security IS 'whose rights it runs with, in the engine''s words (definer, invoker); NULL for the engine''s default';


--
-- Name: COLUMN routines.body; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.body IS 'its body, exactly as written';


--
-- Name: scheduled_events; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.scheduled_events (
    id text NOT NULL,
    schedule text NOT NULL,
    preserve boolean DEFAULT false NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    body text NOT NULL,
    CONSTRAINT scheduled_events_schedule_check CHECK ((length(schedule) >= 1))
);


ALTER TABLE cortex.scheduled_events OWNER TO sf_owner;

--
-- Name: TABLE scheduled_events; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.scheduled_events IS 'something the database runs on a schedule, with its body exactly as written.';


--
-- Name: COLUMN scheduled_events.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.scheduled_events.id IS 'the event';


--
-- Name: COLUMN scheduled_events.schedule; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.scheduled_events.schedule IS 'when it runs, in the engine''s SQL (EVERY 1 DAY STARTS ''2027-01-01'')';


--
-- Name: COLUMN scheduled_events.preserve; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.scheduled_events.preserve IS 'true when it is kept once its schedule is over';


--
-- Name: COLUMN scheduled_events.enabled; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.scheduled_events.enabled IS 'true when it runs';


--
-- Name: COLUMN scheduled_events.body; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.scheduled_events.body IS 'the statements it runs, exactly as written';


--
-- Name: sequences; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.sequences (
    id text NOT NULL,
    type text,
    start integer,
    increment integer,
    min_value integer,
    max_value integer,
    cache integer,
    cycle boolean DEFAULT false NOT NULL,
    owned_by text,
    CONSTRAINT sequences_cache_check CHECK ((cache >= 1)),
    CONSTRAINT sequences_increment_check CHECK ((increment <> 0))
);


ALTER TABLE cortex.sequences OWNER TO sf_owner;

--
-- Name: TABLE sequences; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.sequences IS 'a sequence object, and how it numbers.';


--
-- Name: COLUMN sequences.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.id IS 'the sequence';


--
-- Name: COLUMN sequences.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.type IS 'its type as the engine writes it; NULL for the engine''s default';


--
-- Name: COLUMN sequences.start; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.start IS 'NULL for the engine''s default';


--
-- Name: COLUMN sequences.increment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.increment IS 'NULL for the engine''s default';


--
-- Name: COLUMN sequences.min_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.min_value IS 'NULL for the engine''s default';


--
-- Name: COLUMN sequences.max_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.max_value IS 'NULL for the engine''s default';


--
-- Name: COLUMN sequences.cache; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.cache IS 'NULL for the engine''s default';


--
-- Name: COLUMN sequences.cycle; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.cycle IS 'true when it starts again after its last number';


--
-- Name: COLUMN sequences.owned_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.owned_by IS 'the column that owns it and drops it with itself; NULL for none';


--
-- Name: triggers; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.triggers (
    id text NOT NULL,
    timing text NOT NULL,
    "on" text NOT NULL,
    condition text,
    body text NOT NULL,
    CONSTRAINT triggers_check CHECK ((id <> "on")),
    CONSTRAINT triggers_timing_check CHECK ((timing = ANY (ARRAY['before'::text, 'after'::text, 'instead_of'::text])))
);


ALTER TABLE cortex.triggers OWNER TO sf_owner;

--
-- Name: TABLE triggers; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.triggers IS 'a trigger: when it fires, on which object, and its body exactly as written.';


--
-- Name: COLUMN triggers.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.id IS 'the trigger';


--
-- Name: COLUMN triggers.timing; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.timing IS 'when it fires';


--
-- Name: COLUMN triggers."on"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers."on" IS 'the table or view it is on';


--
-- Name: COLUMN triggers.condition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.condition IS 'the rows it fires for, in the engine''s SQL; NULL for every row';


--
-- Name: COLUMN triggers.body; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.body IS 'the statements it runs, or the routine it calls, exactly as written';


--
-- Name: view_queries; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.view_queries (
    id text NOT NULL,
    text text NOT NULL,
    CONSTRAINT view_queries_text_check CHECK ((length(text) >= 1))
);


ALTER TABLE cortex.view_queries OWNER TO sf_owner;

--
-- Name: TABLE view_queries; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.view_queries IS 'a view''s query, exactly as written in the engine''s SQL.';


--
-- Name: COLUMN view_queries.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.view_queries.id IS 'the view';


--
-- Name: COLUMN view_queries.text; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.view_queries.text IS 'the query';


--
-- Name: broken_one_program_part; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_one_program_part AS
 SELECT 'one-program-part'::text AS rule,
    id
   FROM cortex.objects o
  WHERE ((((((((id IN ( SELECT view_queries.id
           FROM cortex.view_queries)))::integer + ((id IN ( SELECT routines.id
           FROM cortex.routines)))::integer) + ((id IN ( SELECT triggers.id
           FROM cortex.triggers)))::integer) + ((id IN ( SELECT scheduled_events.id
           FROM cortex.scheduled_events)))::integer) + ((id IN ( SELECT sequences.id
           FROM cortex.sequences)))::integer) + ((id IN ( SELECT domains.id
           FROM cortex.domains)))::integer) > 1);


ALTER VIEW cortex.broken_one_program_part OWNER TO sf_owner;

--
-- Name: VIEW broken_one_program_part; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_one_program_part IS 'An object holds at most one of a query, a routine, a trigger, an event, a sequence and a domain.';


--
-- Name: broken_one_schema_row; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_one_schema_row AS
 SELECT 'one-schema-row'::text AS rule,
    'schema'::text AS id
  WHERE ((EXISTS ( SELECT 1
           FROM cortex.namespaces)) AND (( SELECT count(*) AS count
           FROM cortex.schema_identity) <> 1));


ALTER VIEW cortex.broken_one_schema_row OWNER TO sf_owner;

--
-- Name: VIEW broken_one_schema_row; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_one_schema_row IS 'A database that holds any namespace holds its schema''s row (the table allows at most one).';


--
-- Name: operations; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.operations (
    id uuid DEFAULT uuidv7() NOT NULL,
    turn uuid NOT NULL,
    kind text NOT NULL,
    summary text NOT NULL,
    at timestamp with time zone NOT NULL,
    CONSTRAINT operations_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT operations_kind_check CHECK (((kind ~ '^[a-z0-9_]+$'::text) AND (length(kind) >= 1))),
    CONSTRAINT operations_summary_check CHECK ((length(summary) >= 1))
);


ALTER TABLE cortex.operations OWNER TO sf_owner;

--
-- Name: TABLE operations; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.operations IS 'the log: every change, appended, never edited or deleted (decision 5). The current model (every other cortex and engine table) is written in the same transaction as its operation; replaying the log from an empty database rebuilds it exactly.';


--
-- Name: COLUMN operations.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.id IS 'UUIDv7, issued by the database (uuidv7()), increasing within a session: its order is the commit order (decision 7)';


--
-- Name: COLUMN operations.turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.turn IS 'the turn it belongs to (decision 8)';


--
-- Name: COLUMN operations.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.kind IS 'what it is: one of the operation kinds, which the root decision operation-kinds settles before the operations task (import is the one kind the store task writes)';


--
-- Name: COLUMN operations.summary; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.summary IS 'what it did, in one line (added table orders)';


--
-- Name: COLUMN operations.at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.at IS 'when it was committed';


--
-- Name: broken_operation_after_its_turn; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_operation_after_its_turn AS
 SELECT 'operation-after-its-turn'::text AS rule,
    (id)::text AS id
   FROM cortex.operations o
  WHERE (id < turn);


ALTER VIEW cortex.broken_operation_after_its_turn OWNER TO sf_owner;

--
-- Name: VIEW broken_operation_after_its_turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_operation_after_its_turn IS 'An operation''s id is after its turn''s id: a turn begins with its first operation.';


--
-- Name: broken_partition_columns_on_their_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_partition_columns_on_their_table AS
 SELECT 'partition-columns-on-their-table'::text AS rule,
    f.id
   FROM (cortex.partition_fields f
     JOIN cortex.columns c ON ((c.id = f."column")))
  WHERE (c.object <> f.partitioning)
UNION ALL
 SELECT 'partition-columns-on-their-table'::text AS rule,
    o.id
   FROM (cortex.sort_fields o
     JOIN cortex.columns c ON ((c.id = o."column")))
  WHERE (c.object <> o.object);


ALTER VIEW cortex.broken_partition_columns_on_their_table OWNER TO sf_owner;

--
-- Name: VIEW broken_partition_columns_on_their_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_partition_columns_on_their_table IS 'Every column a table is partitioned or ordered by is a column of that table.';


--
-- Name: object_kind_parts; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.object_kind_parts (
    id text NOT NULL,
    kind text NOT NULL,
    slot text NOT NULL,
    CONSTRAINT object_kind_parts_check CHECK ((id = ((kind || '.'::text) || slot))),
    CONSTRAINT object_kind_parts_slot_check CHECK ((slot = ANY (ARRAY['keys'::text, 'checks'::text, 'indexes'::text, 'partitioning'::text, 'partition_of'::text, 'order'::text, 'query'::text, 'sequence'::text, 'values'::text, 'domain'::text, 'fields'::text, 'routine'::text, 'trigger'::text, 'event'::text])))
);


ALTER TABLE cortex.object_kind_parts OWNER TO sf_owner;

--
-- Name: TABLE object_kind_parts; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.object_kind_parts IS 'the parts an object of each kind may have, as the engine declares them; any other part is refused. Written from the engine''s declaration of its kinds with the database; the slots are the section layout''s (crates/engine/src/kinds.rs Slot).';


--
-- Name: COLUMN object_kind_parts.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kind_parts.id IS '<kind>.<slot>: table.keys';


--
-- Name: COLUMN object_kind_parts.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kind_parts.kind IS 'the kind';


--
-- Name: COLUMN object_kind_parts.slot; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kind_parts.slot IS 'a part it may have';


--
-- Name: partition_parents; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.partition_parents (
    id text NOT NULL,
    parent text NOT NULL,
    bounds text NOT NULL,
    CONSTRAINT partition_parents_bounds_check CHECK ((length(bounds) >= 1)),
    CONSTRAINT partition_parents_check CHECK ((id <> parent))
);


ALTER TABLE cortex.partition_parents OWNER TO sf_owner;

--
-- Name: TABLE partition_parents; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.partition_parents IS 'a table that is a partition of another, and the rows it holds.';


--
-- Name: COLUMN partition_parents.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_parents.id IS 'the partition';


--
-- Name: COLUMN partition_parents.parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_parents.parent IS 'the table it is a partition of';


--
-- Name: COLUMN partition_parents.bounds; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partition_parents.bounds IS 'the rows it holds, in the engine''s SQL';


--
-- Name: table_partitionings; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.table_partitionings (
    id text NOT NULL,
    strategy text
);


ALTER TABLE cortex.table_partitionings OWNER TO sf_owner;

--
-- Name: TABLE table_partitionings; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.table_partitionings IS 'how a table is split into partitions.';


--
-- Name: COLUMN table_partitionings.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_partitionings.id IS 'the table split';


--
-- Name: COLUMN table_partitionings.strategy; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.table_partitionings.strategy IS 'the way rows are split, in the engine''s words (range, list, hash, key); NULL when each field says its own transform';


--
-- Name: broken_parts_only_in_their_kinds; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_parts_only_in_their_kinds AS
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.table_keys p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'keys'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.check_constraints p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'checks'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.indexes p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'indexes'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.table_partitionings p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'partitioning'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.partition_parents p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'partition_of'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.sort_fields p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'order'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.view_queries p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'query'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.sequences p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'sequence'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.enum_values p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'values'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.domains p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'domain'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.composite_type_fields p
     JOIN cortex.objects o ON ((o.id = p.object)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'fields'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.routines p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'routine'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.triggers p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'trigger'::text)))))
UNION ALL
 SELECT 'parts-only-in-their-kinds'::text AS rule,
    p.id
   FROM (cortex.scheduled_events p
     JOIN cortex.objects o ON ((o.id = p.id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.object_kind_parts k
          WHERE ((k.kind = o.kind) AND (k.slot = 'event'::text)))));


ALTER VIEW cortex.broken_parts_only_in_their_kinds OWNER TO sf_owner;

--
-- Name: VIEW broken_parts_only_in_their_kinds; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_parts_only_in_their_kinds IS 'An object has a part only when its kind''s slots (object_kind_parts) hold that part: a view no keys, a table no query.';


--
-- Name: broken_perspective_columns_of_their_object; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_perspective_columns_of_their_object AS
 SELECT 'perspective-columns-of-their-object'::text AS rule,
    m.id
   FROM (cortex.perspective_members m
     JOIN cortex.columns c ON ((c.id = m."column")))
  WHERE (c.object <> m.object);


ALTER VIEW cortex.broken_perspective_columns_of_their_object OWNER TO sf_owner;

--
-- Name: VIEW broken_perspective_columns_of_their_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_perspective_columns_of_their_object IS 'A column a custom perspective shows alone is a column of the object it shows.';


--
-- Name: broken_primary_key_columns_not_null; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_primary_key_columns_not_null AS
 SELECT 'primary-key-columns-not-null'::text AS rule,
    kc.id
   FROM ((cortex.table_key_columns kc
     JOIN cortex.table_keys k ON ((k.id = kc.key)))
     JOIN cortex.columns c ON ((c.id = kc."column")))
  WHERE ((k.what = 'primary'::text) AND c.nullable);


ALTER VIEW cortex.broken_primary_key_columns_not_null OWNER TO sf_owner;

--
-- Name: VIEW broken_primary_key_columns_not_null; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_primary_key_columns_not_null IS 'A column of a primary key never holds null.';


--
-- Name: broken_relationship_from_columns_on_from_object; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_relationship_from_columns_on_from_object AS
 SELECT 'relationship-from-columns-on-from-object'::text AS rule,
    lc.id
   FROM ((cortex.relationship_columns lc
     JOIN cortex.relationships l ON ((l.id = lc.relationship)))
     JOIN cortex.columns c ON ((c.id = lc.from_column)))
  WHERE (c.object <> l.from_object);


ALTER VIEW cortex.broken_relationship_from_columns_on_from_object OWNER TO sf_owner;

--
-- Name: VIEW broken_relationship_from_columns_on_from_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_relationship_from_columns_on_from_object IS 'Every from_column of a relationship is a column of its from_object.';


--
-- Name: broken_relationship_has_columns; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_relationship_has_columns AS
 SELECT 'relationship-has-columns'::text AS rule,
    id
   FROM cortex.relationships l
  WHERE (NOT (EXISTS ( SELECT 1
           FROM cortex.relationship_columns lc
          WHERE (lc.relationship = l.id))));


ALTER VIEW cortex.broken_relationship_has_columns OWNER TO sf_owner;

--
-- Name: VIEW broken_relationship_has_columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_relationship_has_columns IS 'Every relationship joins at least one column.';


--
-- Name: broken_relationship_to_columns_on_to_object; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_relationship_to_columns_on_to_object AS
 SELECT 'relationship-to-columns-on-to-object'::text AS rule,
    lc.id
   FROM ((cortex.relationship_columns lc
     JOIN cortex.relationships l ON ((l.id = lc.relationship)))
     JOIN cortex.columns c ON ((c.id = lc.to_column)))
  WHERE (c.object <> l.to_object);


ALTER VIEW cortex.broken_relationship_to_columns_on_to_object OWNER TO sf_owner;

--
-- Name: VIEW broken_relationship_to_columns_on_to_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_relationship_to_columns_on_to_object IS 'Every to_column of a relationship is a column of its to_object.';


--
-- Name: row_changes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.row_changes (
    id text NOT NULL,
    operation uuid NOT NULL,
    "position" integer NOT NULL,
    table_name text NOT NULL,
    row_id text NOT NULL,
    action text NOT NULL,
    CONSTRAINT row_changes_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT row_changes_check CHECK ((("left"(id, 37) = ((operation)::text || '.'::text)) AND (substr(id, 38) ~ '^[1-9][0-9]*$'::text))),
    CONSTRAINT row_changes_position_check CHECK (("position" >= 1)),
    CONSTRAINT row_changes_table_name_check CHECK ((table_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text))
);


ALTER TABLE cortex.row_changes OWNER TO sf_owner;

--
-- Name: TABLE row_changes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.row_changes IS 'every row an operation inserted, updated or deleted, in any table of the database, in the order it changed them. With value_changes, the exact record of what the operation did; its inverse is worked out from this record, never written by hand.';


--
-- Name: COLUMN row_changes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.id IS '<operation>.<n>, n its place in the operation (the log is never reordered)';


--
-- Name: COLUMN row_changes.operation; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.operation IS 'the operation';


--
-- Name: COLUMN row_changes."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes."position" IS 'the order the rows changed in';


--
-- Name: COLUMN row_changes.table_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.table_name IS 'the table, cortex or engine with its namespace (cortex.objects, engine_mysql.table_options)';


--
-- Name: COLUMN row_changes.row_id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.row_id IS 'the row''s id, its primary key';


--
-- Name: COLUMN row_changes.action; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.action IS 'what happened to the row';


--
-- Name: broken_row_changes_name_tables_of_the_database; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_row_changes_name_tables_of_the_database AS
 SELECT 'row-changes-name-tables-of-the-database'::text AS rule,
    id
   FROM cortex.row_changes r
  WHERE (to_regclass(table_name) IS NULL);


ALTER VIEW cortex.broken_row_changes_name_tables_of_the_database OWNER TO sf_owner;

--
-- Name: VIEW broken_row_changes_name_tables_of_the_database; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_row_changes_name_tables_of_the_database IS 'The log names only tables of this database, each with its namespace.';


--
-- Name: broken_turn_takes_back_an_earlier_turn; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_turn_takes_back_an_earlier_turn AS
 SELECT 'turn-takes-back-an-earlier-turn'::text AS rule,
    (id)::text AS id
   FROM cortex.turns t
  WHERE ((undoes IS NOT NULL) AND (undoes >= id));


ALTER VIEW cortex.broken_turn_takes_back_an_earlier_turn OWNER TO sf_owner;

--
-- Name: VIEW broken_turn_takes_back_an_earlier_turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_turn_takes_back_an_earlier_turn IS 'A turn that undoes another began after it.';


--
-- Name: broken_versions_follow_the_log; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_versions_follow_the_log AS
 SELECT 'versions-follow-the-log'::text AS rule,
    (b.id)::text AS id
   FROM (cortex.locked_versions a
     JOIN cortex.locked_versions b ON ((b.number = (a.number + 1))))
  WHERE (b.at_operation <= a.at_operation);


ALTER VIEW cortex.broken_versions_follow_the_log OWNER TO sf_owner;

--
-- Name: VIEW broken_versions_follow_the_log; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_versions_follow_the_log IS 'A higher version holds a later operation.';


--
-- Name: catalog_sources; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.catalog_sources (
    id text NOT NULL,
    version text NOT NULL,
    source text NOT NULL,
    gives text NOT NULL,
    needs text,
    usage boolean DEFAULT false NOT NULL,
    "position" numeric NOT NULL,
    CONSTRAINT catalog_sources_check CHECK ((id = ((version || '/'::text) || source))),
    CONSTRAINT catalog_sources_gives_check CHECK ((length(gives) >= 1)),
    CONSTRAINT catalog_sources_position_check CHECK (("position" > (0)::numeric)),
    CONSTRAINT catalog_sources_source_check CHECK ((length(source) >= 1))
);


ALTER TABLE cortex.catalog_sources OWNER TO sf_owner;

--
-- Name: TABLE catalog_sources; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.catalog_sources IS 'what the engine''s live read asks a server of each version, what it gives, and the grant it needs. Written when the database is made, from the engine''s declaration (decision version-facts): what the Connections page shows and the connection test checks, so a missing grant says what will not be read.';


--
-- Name: COLUMN catalog_sources.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.id IS '<version>/<source>: 5.7/information_schema.ROUTINES';


--
-- Name: COLUMN catalog_sources.version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.version IS 'the version it is asked of';


--
-- Name: COLUMN catalog_sources.source; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.source IS 'the catalog table or statement, as the server names it (performance_schema.table_io_waits_summary_by_table, SHOW CREATE TABLE)';


--
-- Name: COLUMN catalog_sources.gives; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.gives IS 'what the read takes from it (routines and their bodies)';


--
-- Name: COLUMN catalog_sources.needs; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.needs IS 'the grant it needs, as the server writes it (SELECT ON mysql.proc); NULL for none beyond the database''s';


--
-- Name: COLUMN catalog_sources.usage; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.usage IS 'true for a source of usage (performance_schema), false for one of structure';


--
-- Name: COLUMN catalog_sources."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources."position" IS 'its place in the read of its version, in the order asked';


--
-- Name: column_identities; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.column_identities (
    id text NOT NULL,
    always boolean NOT NULL,
    start integer,
    increment integer,
    min_value integer,
    max_value integer,
    cache integer,
    cycle boolean DEFAULT false NOT NULL,
    CONSTRAINT column_identities_cache_check CHECK ((cache >= 1)),
    CONSTRAINT column_identities_increment_check CHECK ((increment <> 0))
);


ALTER TABLE cortex.column_identities OWNER TO sf_owner;

--
-- Name: TABLE column_identities; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.column_identities IS 'a column the database numbers itself, and how.';


--
-- Name: COLUMN column_identities.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.id IS 'the column numbered';


--
-- Name: COLUMN column_identities.always; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.always IS 'true when a value can never be given (ALWAYS); 0 only when none is (BY DEFAULT)';


--
-- Name: COLUMN column_identities.start; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.start IS 'the first number; NULL for the engine''s default';


--
-- Name: COLUMN column_identities.increment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.increment IS 'the step; NULL for the engine''s default';


--
-- Name: COLUMN column_identities.min_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.min_value IS 'the smallest number; NULL for the engine''s default';


--
-- Name: COLUMN column_identities.max_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.max_value IS 'the largest number; NULL for the engine''s default';


--
-- Name: COLUMN column_identities.cache; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.cache IS 'how many numbers are taken at a time; NULL for the engine''s default';


--
-- Name: COLUMN column_identities.cycle; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.cycle IS 'true when it starts again after its last number';


--
-- Name: custom_perspectives; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.custom_perspectives (
    id text NOT NULL,
    name text NOT NULL,
    "position" numeric NOT NULL,
    group_by text DEFAULT 'family'::text NOT NULL,
    colour_by text DEFAULT 'family'::text NOT NULL,
    comment text,
    made_by text NOT NULL,
    CONSTRAINT custom_perspectives_colour_by_check CHECK ((colour_by = ANY (ARRAY['namespace'::text, 'family'::text, 'area'::text, 'none'::text]))),
    CONSTRAINT custom_perspectives_group_by_check CHECK ((group_by = ANY (ARRAY['namespace'::text, 'family'::text, 'area'::text, 'none'::text]))),
    CONSTRAINT custom_perspectives_id_check CHECK (((id ~ '^p_[a-z0-9_]*$'::text) AND (length(id) <= 128))),
    CONSTRAINT custom_perspectives_made_by_check CHECK ((length(made_by) >= 1)),
    CONSTRAINT custom_perspectives_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT custom_perspectives_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.custom_perspectives OWNER TO sf_owner;

--
-- Name: TABLE custom_perspectives; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.custom_perspectives IS 'a perspective someone saved: their own choice of tables and columns, grouped and coloured their way. Part of the design (decision canvas-state): shareable, and the agent may make one; its members are in perspective_members.';


--
-- Name: COLUMN custom_perspectives.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.id IS 'the perspective''s id (p_billing_review), kept when it is renamed';


--
-- Name: COLUMN custom_perspectives.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.name IS 'as people call it (Billing review)';


--
-- Name: COLUMN custom_perspectives."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives."position" IS 'its place among the perspectives; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: COLUMN custom_perspectives.group_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.group_by IS 'how its tables are grouped';


--
-- Name: COLUMN custom_perspectives.colour_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.colour_by IS 'what its colours follow, unless a member sets its own';


--
-- Name: COLUMN custom_perspectives.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.comment IS 'what it is for; NULL for none';


--
-- Name: COLUMN custom_perspectives.made_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.custom_perspectives.made_by IS 'who made it: a person''s name or the agent''s label';


--
-- Name: family_assignments; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.family_assignments (
    id text NOT NULL,
    family text NOT NULL,
    CONSTRAINT family_assignments_family_check CHECK ((length(family) >= 1))
);


ALTER TABLE cortex.family_assignments OWNER TO sf_owner;

--
-- Name: TABLE family_assignments; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.family_assignments IS 'an object put in a family by hand, overriding the family worked out from its name. Shape 1 of the owner template: at most one row per object, its id the object''s. An object with no row is in the family its name gives.';


--
-- Name: COLUMN family_assignments.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.family_assignments.id IS 'the object';


--
-- Name: COLUMN family_assignments.family; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.family_assignments.family IS 'the family it belongs to, as the canvas names families (billing)';


--
-- Name: object_kinds; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.object_kinds (
    id text NOT NULL,
    name text NOT NULL,
    "position" numeric NOT NULL,
    CONSTRAINT object_kinds_id_check CHECK ((id ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT object_kinds_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.object_kinds OWNER TO sf_owner;

--
-- Name: TABLE object_kinds; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object this schema''s engine has, as the engine declares them. Written from the engine''s declaration when the database is made and when the engine''s version of the schema changes; an object of a kind not here is refused by objects.kind, and a part its kind''s slots (object_kind_parts) lack by integrity.sql.';


--
-- Name: COLUMN object_kinds.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds.id IS 'as an object names its kind (table, view, record)';


--
-- Name: COLUMN object_kinds.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';


--
-- Name: COLUMN object_kinds."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds."position" IS 'its place in the engine''s declaration, for listing in the engine''s order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: required_extensions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.required_extensions (
    id text NOT NULL,
    "position" numeric NOT NULL,
    CONSTRAINT required_extensions_id_check CHECK ((length(id) >= 1)),
    CONSTRAINT required_extensions_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.required_extensions OWNER TO sf_owner;

--
-- Name: TABLE required_extensions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.required_extensions IS 'what the database must have installed for this schema (an extension, a plugin), by name, in order.';


--
-- Name: COLUMN required_extensions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions.id IS 'its name, in the engine''s words (postgis)';


--
-- Name: COLUMN required_extensions."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions."position" IS 'its place in the schema''s list of requirements; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';


--
-- Name: schema_migrations; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.schema_migrations (
    id text NOT NULL,
    owner text NOT NULL,
    version integer NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone NOT NULL,
    CONSTRAINT schema_migrations_check CHECK ((id = ((owner || '/'::text) || version))),
    CONSTRAINT schema_migrations_checksum_check CHECK ((length(checksum) = 64)),
    CONSTRAINT schema_migrations_owner_check CHECK (((owner = 'cortex'::text) OR (owner ~ '^[a-z0-9_]+$'::text))),
    CONSTRAINT schema_migrations_version_check CHECK ((version >= 1))
);


ALTER TABLE cortex.schema_migrations OWNER TO sf_owner;

--
-- Name: TABLE schema_migrations; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.schema_migrations IS 'every migration applied to this schema''s database, by its owner. The owner is cortex, an engine''s id or a feature''s (decision features-as-owners); each counts its own versions from 1 (decision 13). Opening the database applies, in order and in one transaction, every version its owners ship that is not here; a checksum that differs from the shipped file refuses the database.';


--
-- Name: COLUMN schema_migrations.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_migrations.id IS '<owner>/<version>: cortex/1, mysql/3';


--
-- Name: COLUMN schema_migrations.owner; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_migrations.owner IS 'cortex, or the id of the engine or the feature whose tables it creates';


--
-- Name: COLUMN schema_migrations.version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_migrations.version IS 'the owner''s version; 1 creates its tables from its schema folder';


--
-- Name: COLUMN schema_migrations.checksum; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_migrations.checksum IS 'SHA-256 of what was applied, hex: a shipped migration whose text changed is refused';


--
-- Name: COLUMN schema_migrations.applied_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_migrations.applied_at IS 'when it was applied';


--
-- Name: source_reads; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.source_reads (
    id uuid DEFAULT uuidv7() NOT NULL,
    turn uuid,
    connection_id uuid NOT NULL,
    connection_name text NOT NULL,
    database_name text NOT NULL,
    server_version text NOT NULL,
    server_edition text,
    read_as text NOT NULL,
    server_uptime bigint,
    usage_available boolean NOT NULL,
    missing_grants text,
    started_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    CONSTRAINT source_reads_check CHECK (((ended_at IS NULL) OR (ended_at >= started_at))),
    CONSTRAINT source_reads_connection_name_check CHECK ((length(connection_name) >= 1)),
    CONSTRAINT source_reads_database_name_check CHECK ((length(database_name) >= 1)),
    CONSTRAINT source_reads_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT source_reads_read_as_check CHECK ((length(read_as) >= 1)),
    CONSTRAINT source_reads_server_uptime_check CHECK ((server_uptime >= 0)),
    CONSTRAINT source_reads_server_version_check CHECK ((length(server_version) >= 1))
);


ALTER TABLE cortex.source_reads OWNER TO sf_owner;

--
-- Name: TABLE source_reads; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.source_reads IS 'each read of a live database for this schema: from which saved connection, which server, as whom, and when. An import lands in its turn; a read of usage alone has none (decision usage-apart). The connection is the workspace''s, in another database, so it is kept by its id and name, not a foreign key.';


--
-- Name: COLUMN source_reads.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.id IS 'UUIDv7, issued by the database';


--
-- Name: COLUMN source_reads.turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.turn IS 'the import turn the structure read landed in; NULL for a read of usage alone';


--
-- Name: COLUMN source_reads.connection_id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.connection_id IS 'the saved connection read through, as the workspace''s connections row holds it';


--
-- Name: COLUMN source_reads.connection_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.connection_name IS 'its name when it was read (prod-replica)';


--
-- Name: COLUMN source_reads.database_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.database_name IS 'the database read, as the server names it (shop)';


--
-- Name: COLUMN source_reads.server_version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.server_version IS 'the version the server gave (8.4.13)';


--
-- Name: COLUMN source_reads.server_edition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.server_edition IS 'what the server says it is beyond its version (MySQL Community Server - GPL); NULL when it says nothing';


--
-- Name: COLUMN source_reads.read_as; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.read_as IS 'the account the server says the read ran as (sf_reader@%)';


--
-- Name: COLUMN source_reads.server_uptime; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.server_uptime IS 'the server''s uptime in seconds when read: usage counts from its start; NULL when it would not say';


--
-- Name: COLUMN source_reads.usage_available; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.usage_available IS 'whether the server keeps usage (MySQL: performance_schema on) and the account could read it';


--
-- Name: COLUMN source_reads.missing_grants; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.missing_grants IS 'the grants the account lacked, as the test named them, and so what was not read; NULL for none';


--
-- Name: COLUMN source_reads.started_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.started_at IS 'when the read began';


--
-- Name: COLUMN source_reads.ended_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.ended_at IS 'when it ended; NULL while it runs';


--
-- Name: value_changes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.value_changes (
    id text NOT NULL,
    row_change text NOT NULL,
    column_name text NOT NULL,
    before jsonb,
    after jsonb,
    CONSTRAINT value_changes_check CHECK ((id = ((row_change || '.'::text) || column_name))),
    CONSTRAINT value_changes_column_name_check CHECK ((column_name ~ '^[a-z0-9_]+$'::text))
);


ALTER TABLE cortex.value_changes OWNER TO sf_owner;

--
-- Name: TABLE value_changes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.value_changes IS 'every column value a row change set or cleared: for an insert every column, for a delete every column, for an update the columns that changed.';


--
-- Name: COLUMN value_changes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.value_changes.id IS '<row change>.<column>';


--
-- Name: COLUMN value_changes.row_change; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.value_changes.row_change IS 'the row change';


--
-- Name: COLUMN value_changes.column_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.value_changes.column_name IS 'the column';


--
-- Name: COLUMN value_changes.before; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.value_changes.before IS 'its value before; NULL for an insert, and for a value that was null';


--
-- Name: COLUMN value_changes.after; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.value_changes.after IS 'its value after; NULL for a delete, and for a value that is null';


--
-- Name: record_options; Type: TABLE; Schema: engine_quill; Owner: sf_owner
--

CREATE TABLE engine_quill.record_options (
    id text NOT NULL,
    fast boolean NOT NULL,
    CONSTRAINT record_options_fast_check CHECK (fast)
);


ALTER TABLE engine_quill.record_options OWNER TO sf_owner;

--
-- Name: TABLE record_options; Type: COMMENT; Schema: engine_quill; Owner: sf_owner
--

COMMENT ON TABLE engine_quill.record_options IS 'what Quill says of a record beyond the cortex: whether it is kept in memory. Shipped in the Quill plugin (engines/quill); created in a schema database whose engine is quill, and in no other.';


--
-- Name: COLUMN record_options.id; Type: COMMENT; Schema: engine_quill; Owner: sf_owner
--

COMMENT ON COLUMN engine_quill.record_options.id IS 'the record';


--
-- Name: COLUMN record_options.fast; Type: COMMENT; Schema: engine_quill; Owner: sf_owner
--

COMMENT ON COLUMN engine_quill.record_options.fast IS 'present only for a record written fast (kept in memory), from Quill version 2';


--
-- Name: broken_record_options_on_records; Type: VIEW; Schema: engine_quill; Owner: sf_owner
--

CREATE VIEW engine_quill.broken_record_options_on_records AS
 SELECT 'record-options-on-records'::text AS rule,
    r.id
   FROM (engine_quill.record_options r
     JOIN cortex.objects o ON ((o.id = r.id)))
  WHERE (o.kind <> 'record'::text);


ALTER VIEW engine_quill.broken_record_options_on_records OWNER TO sf_owner;

--
-- Name: VIEW broken_record_options_on_records; Type: COMMENT; Schema: engine_quill; Owner: sf_owner
--

COMMENT ON VIEW engine_quill.broken_record_options_on_records IS 'Record options belong to an object of the kind record.';


--
-- Name: catalog_sources catalog_sources_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.catalog_sources
    ADD CONSTRAINT catalog_sources_pkey PRIMARY KEY (id);


--
-- Name: catalog_sources catalog_sources_version_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.catalog_sources
    ADD CONSTRAINT catalog_sources_version_position_key UNIQUE (version, "position");


--
-- Name: catalog_sources catalog_sources_version_source_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.catalog_sources
    ADD CONSTRAINT catalog_sources_version_source_key UNIQUE (version, source);


--
-- Name: check_constraints check_constraints_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.check_constraints
    ADD CONSTRAINT check_constraints_object_position_key UNIQUE (object, "position");


--
-- Name: check_constraints check_constraints_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.check_constraints
    ADD CONSTRAINT check_constraints_pkey PRIMARY KEY (id);


--
-- Name: column_identities column_identities_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.column_identities
    ADD CONSTRAINT column_identities_pkey PRIMARY KEY (id);


--
-- Name: columns columns_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_name_key UNIQUE (object, name);


--
-- Name: columns columns_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_position_key UNIQUE (object, "position");


--
-- Name: columns columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_pkey PRIMARY KEY (id);


--
-- Name: composite_type_fields composite_type_fields_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.composite_type_fields
    ADD CONSTRAINT composite_type_fields_object_name_key UNIQUE (object, name);


--
-- Name: composite_type_fields composite_type_fields_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.composite_type_fields
    ADD CONSTRAINT composite_type_fields_object_position_key UNIQUE (object, "position");


--
-- Name: composite_type_fields composite_type_fields_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.composite_type_fields
    ADD CONSTRAINT composite_type_fields_pkey PRIMARY KEY (id);


--
-- Name: custom_perspectives custom_perspectives_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.custom_perspectives
    ADD CONSTRAINT custom_perspectives_name_key UNIQUE (name);


--
-- Name: custom_perspectives custom_perspectives_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.custom_perspectives
    ADD CONSTRAINT custom_perspectives_pkey PRIMARY KEY (id);


--
-- Name: custom_perspectives custom_perspectives_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.custom_perspectives
    ADD CONSTRAINT custom_perspectives_position_key UNIQUE ("position");


--
-- Name: domains domains_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.domains
    ADD CONSTRAINT domains_pkey PRIMARY KEY (id);


--
-- Name: engine_features engine_features_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.engine_features
    ADD CONSTRAINT engine_features_pkey PRIMARY KEY (id);


--
-- Name: engine_versions engine_versions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_pkey PRIMARY KEY (id);


--
-- Name: engine_versions engine_versions_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.engine_versions
    ADD CONSTRAINT engine_versions_position_key UNIQUE ("position");


--
-- Name: enum_values enum_values_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_object_position_key UNIQUE (object, "position");


--
-- Name: enum_values enum_values_object_value_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_object_value_key UNIQUE (object, value);


--
-- Name: enum_values enum_values_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_pkey PRIMARY KEY (id);


--
-- Name: family_assignments family_assignments_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.family_assignments
    ADD CONSTRAINT family_assignments_pkey PRIMARY KEY (id);


--
-- Name: id_counters id_counters_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.id_counters
    ADD CONSTRAINT id_counters_pkey PRIMARY KEY (id);


--
-- Name: index_includes index_includes_index_column_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_includes
    ADD CONSTRAINT index_includes_index_column_key UNIQUE (index, "column");


--
-- Name: index_includes index_includes_index_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_includes
    ADD CONSTRAINT index_includes_index_position_key UNIQUE (index, "position");


--
-- Name: index_includes index_includes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_includes
    ADD CONSTRAINT index_includes_pkey PRIMARY KEY (id);


--
-- Name: index_parts index_parts_index_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_index_position_key UNIQUE (index, "position");


--
-- Name: index_parts index_parts_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_pkey PRIMARY KEY (id);


--
-- Name: indexes indexes_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_name_key UNIQUE (object, name);


--
-- Name: indexes indexes_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_position_key UNIQUE (object, "position");


--
-- Name: indexes indexes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_pkey PRIMARY KEY (id);


--
-- Name: layout_pins layout_pins_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.layout_pins
    ADD CONSTRAINT layout_pins_pkey PRIMARY KEY (id);


--
-- Name: layout_pins layout_pins_view_object_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.layout_pins
    ADD CONSTRAINT layout_pins_view_object_key UNIQUE (view, object);


--
-- Name: locked_versions locked_versions_at_operation_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_at_operation_key UNIQUE (at_operation);


--
-- Name: locked_versions locked_versions_number_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_number_key UNIQUE (number);


--
-- Name: locked_versions locked_versions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_pkey PRIMARY KEY (id);


--
-- Name: namespaces namespaces_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_pkey PRIMARY KEY (id);


--
-- Name: namespaces namespaces_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_position_key UNIQUE ("position");


--
-- Name: object_kind_parts object_kind_parts_kind_slot_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_kind_parts
    ADD CONSTRAINT object_kind_parts_kind_slot_key UNIQUE (kind, slot);


--
-- Name: object_kind_parts object_kind_parts_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_kind_parts
    ADD CONSTRAINT object_kind_parts_pkey PRIMARY KEY (id);


--
-- Name: object_kinds object_kinds_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_pkey PRIMARY KEY (id);


--
-- Name: object_kinds object_kinds_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_kinds
    ADD CONSTRAINT object_kinds_position_key UNIQUE ("position");


--
-- Name: object_reads object_reads_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_reads
    ADD CONSTRAINT object_reads_object_position_key UNIQUE (object, "position");


--
-- Name: object_reads object_reads_object_reads_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_reads
    ADD CONSTRAINT object_reads_object_reads_key UNIQUE (object, reads);


--
-- Name: object_reads object_reads_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_reads
    ADD CONSTRAINT object_reads_pkey PRIMARY KEY (id);


--
-- Name: object_tags object_tags_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_object_position_key UNIQUE (object, "position");


--
-- Name: object_tags object_tags_object_tag_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_object_tag_key UNIQUE (object, tag);


--
-- Name: object_tags object_tags_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_pkey PRIMARY KEY (id);


--
-- Name: objects objects_namespace_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_name_key UNIQUE (namespace, name);


--
-- Name: objects objects_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_pkey PRIMARY KEY (id);


--
-- Name: objects objects_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_position_key UNIQUE ("position");


--
-- Name: operations operations_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_pkey PRIMARY KEY (id);


--
-- Name: partition_fields partition_fields_partitioning_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_fields
    ADD CONSTRAINT partition_fields_partitioning_position_key UNIQUE (partitioning, "position");


--
-- Name: partition_fields partition_fields_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_fields
    ADD CONSTRAINT partition_fields_pkey PRIMARY KEY (id);


--
-- Name: partition_parents partition_parents_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_parents
    ADD CONSTRAINT partition_parents_pkey PRIMARY KEY (id);


--
-- Name: partitions partitions_partitioning_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_name_key UNIQUE (partitioning, name);


--
-- Name: partitions partitions_partitioning_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_position_key UNIQUE (partitioning, "position");


--
-- Name: partitions partitions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_pkey PRIMARY KEY (id);


--
-- Name: perspective_members perspective_members_perspective_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.perspective_members
    ADD CONSTRAINT perspective_members_perspective_position_key UNIQUE (perspective, "position");


--
-- Name: perspective_members perspective_members_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.perspective_members
    ADD CONSTRAINT perspective_members_pkey PRIMARY KEY (id);


--
-- Name: pinned_notes pinned_notes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.pinned_notes
    ADD CONSTRAINT pinned_notes_pkey PRIMARY KEY (id);


--
-- Name: pinned_notes pinned_notes_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.pinned_notes
    ADD CONSTRAINT pinned_notes_position_key UNIQUE ("position");


--
-- Name: relationship_columns relationship_columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationship_columns
    ADD CONSTRAINT relationship_columns_pkey PRIMARY KEY (id);


--
-- Name: relationship_columns relationship_columns_relationship_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationship_columns
    ADD CONSTRAINT relationship_columns_relationship_position_key UNIQUE (relationship, "position");


--
-- Name: relationships relationships_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationships
    ADD CONSTRAINT relationships_pkey PRIMARY KEY (id);


--
-- Name: relationships relationships_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationships
    ADD CONSTRAINT relationships_position_key UNIQUE ("position");


--
-- Name: required_extensions required_extensions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.required_extensions
    ADD CONSTRAINT required_extensions_pkey PRIMARY KEY (id);


--
-- Name: required_extensions required_extensions_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.required_extensions
    ADD CONSTRAINT required_extensions_position_key UNIQUE ("position");


--
-- Name: routine_parameters routine_parameters_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routine_parameters
    ADD CONSTRAINT routine_parameters_pkey PRIMARY KEY (id);


--
-- Name: routine_parameters routine_parameters_routine_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routine_parameters
    ADD CONSTRAINT routine_parameters_routine_position_key UNIQUE (routine, "position");


--
-- Name: routines routines_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routines
    ADD CONSTRAINT routines_pkey PRIMARY KEY (id);


--
-- Name: row_changes row_changes_operation_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_operation_position_key UNIQUE (operation, "position");


--
-- Name: row_changes row_changes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_pkey PRIMARY KEY (id);


--
-- Name: scheduled_events scheduled_events_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.scheduled_events
    ADD CONSTRAINT scheduled_events_pkey PRIMARY KEY (id);


--
-- Name: schema_identity schema_identity_one_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.schema_identity
    ADD CONSTRAINT schema_identity_one_key UNIQUE (one);


--
-- Name: schema_identity schema_identity_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.schema_identity
    ADD CONSTRAINT schema_identity_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_owner_version_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.schema_migrations
    ADD CONSTRAINT schema_migrations_owner_version_key UNIQUE (owner, version);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (id);


--
-- Name: sequences sequences_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sequences
    ADD CONSTRAINT sequences_pkey PRIMARY KEY (id);


--
-- Name: sort_fields sort_fields_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_object_position_key UNIQUE (object, "position");


--
-- Name: sort_fields sort_fields_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_pkey PRIMARY KEY (id);


--
-- Name: source_reads source_reads_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.source_reads
    ADD CONSTRAINT source_reads_pkey PRIMARY KEY (id);


--
-- Name: subject_areas subject_areas_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.subject_areas
    ADD CONSTRAINT subject_areas_name_key UNIQUE (name);


--
-- Name: subject_areas subject_areas_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.subject_areas
    ADD CONSTRAINT subject_areas_pkey PRIMARY KEY (id);


--
-- Name: subject_areas subject_areas_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.subject_areas
    ADD CONSTRAINT subject_areas_position_key UNIQUE ("position");


--
-- Name: table_key_columns table_key_columns_key_column_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_key_columns
    ADD CONSTRAINT table_key_columns_key_column_key UNIQUE (key, "column");


--
-- Name: table_key_columns table_key_columns_key_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_key_columns
    ADD CONSTRAINT table_key_columns_key_position_key UNIQUE (key, "position");


--
-- Name: table_key_columns table_key_columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_key_columns
    ADD CONSTRAINT table_key_columns_pkey PRIMARY KEY (id);


--
-- Name: table_keys table_keys_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_keys
    ADD CONSTRAINT table_keys_object_position_key UNIQUE (object, "position");


--
-- Name: table_keys table_keys_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_keys
    ADD CONSTRAINT table_keys_pkey PRIMARY KEY (id);


--
-- Name: table_partitionings table_partitionings_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_partitionings
    ADD CONSTRAINT table_partitionings_pkey PRIMARY KEY (id);


--
-- Name: trigger_events trigger_events_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.trigger_events
    ADD CONSTRAINT trigger_events_pkey PRIMARY KEY (id);


--
-- Name: trigger_events trigger_events_trigger_change_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.trigger_events
    ADD CONSTRAINT trigger_events_trigger_change_key UNIQUE (trigger, change);


--
-- Name: trigger_events trigger_events_trigger_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.trigger_events
    ADD CONSTRAINT trigger_events_trigger_position_key UNIQUE (trigger, "position");


--
-- Name: triggers triggers_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.triggers
    ADD CONSTRAINT triggers_pkey PRIMARY KEY (id);


--
-- Name: turns turns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_pkey PRIMARY KEY (id);


--
-- Name: value_changes value_changes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.value_changes
    ADD CONSTRAINT value_changes_pkey PRIMARY KEY (id);


--
-- Name: value_changes value_changes_row_change_column_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.value_changes
    ADD CONSTRAINT value_changes_row_change_column_name_key UNIQUE (row_change, column_name);


--
-- Name: verbatim_statements verbatim_statements_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_pkey PRIMARY KEY (id);


--
-- Name: verbatim_statements verbatim_statements_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_position_key UNIQUE ("position");


--
-- Name: view_queries view_queries_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.view_queries
    ADD CONSTRAINT view_queries_pkey PRIMARY KEY (id);


--
-- Name: record_options record_options_pkey; Type: CONSTRAINT; Schema: engine_quill; Owner: sf_owner
--

ALTER TABLE ONLY engine_quill.record_options
    ADD CONSTRAINT record_options_pkey PRIMARY KEY (id);


--
-- Name: namespaces_name; Type: INDEX; Schema: cortex; Owner: sf_owner
--

CREATE UNIQUE INDEX namespaces_name ON cortex.namespaces USING btree (COALESCE(parent, ''::text), name);


--
-- Name: perspective_members_once; Type: INDEX; Schema: cortex; Owner: sf_owner
--

CREATE UNIQUE INDEX perspective_members_once ON cortex.perspective_members USING btree (perspective, object, COALESCE("column", ''::text));


--
-- Name: table_keys_one_primary; Type: INDEX; Schema: cortex; Owner: sf_owner
--

CREATE UNIQUE INDEX table_keys_one_primary ON cortex.table_keys USING btree (object) WHERE (what = 'primary'::text);


--
-- Name: engine_features rule:cortex.features_since_before_until; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.features_since_before_until" AFTER INSERT OR DELETE OR UPDATE ON cortex.engine_features DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_features_since_before_until');


--
-- Name: engine_versions rule:cortex.features_since_before_until; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.features_since_before_until" AFTER INSERT OR DELETE OR UPDATE ON cortex.engine_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_features_since_before_until');


--
-- Name: engine_features rule:cortex.features_since_before_until:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.features_since_before_until:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.engine_features FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_features_since_before_until');


--
-- Name: engine_versions rule:cortex.features_since_before_until:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.features_since_before_until:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.engine_versions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_features_since_before_until');


--
-- Name: check_constraints rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: composite_type_fields rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: enum_values rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: id_counters rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.id_counters DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: index_includes rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_includes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: index_parts rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: indexes rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: layout_pins rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.layout_pins DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: object_reads rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_reads DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: object_tags rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_tags DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: partition_fields rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: partitions rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: perspective_members rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.perspective_members DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: pinned_notes rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.pinned_notes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: relationship_columns rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: routine_parameters rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.routine_parameters DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: sort_fields rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: table_key_columns rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: table_keys rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: trigger_events rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.trigger_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: verbatim_statements rule:cortex.ids_within_their_counters; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.ids_within_their_counters" AFTER INSERT OR DELETE OR UPDATE ON cortex.verbatim_statements DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_ids_within_their_counters');


--
-- Name: check_constraints rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: composite_type_fields rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: enum_values rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: id_counters rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.id_counters FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: index_includes rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_includes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: index_parts rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: indexes rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: layout_pins rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.layout_pins FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: object_reads rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_reads FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: object_tags rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_tags FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: partition_fields rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: partitions rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: perspective_members rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.perspective_members FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: pinned_notes rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.pinned_notes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: relationship_columns rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: routine_parameters rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.routine_parameters FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: sort_fields rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: table_key_columns rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: table_keys rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: trigger_events rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.trigger_events FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: verbatim_statements rule:cortex.ids_within_their_counters:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.ids_within_their_counters:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.verbatim_statements FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_ids_within_their_counters');


--
-- Name: columns rule:cortex.index_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.index_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_index_columns_on_their_table');


--
-- Name: index_includes rule:cortex.index_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.index_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_includes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_index_columns_on_their_table');


--
-- Name: index_parts rule:cortex.index_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.index_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_index_columns_on_their_table');


--
-- Name: indexes rule:cortex.index_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.index_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_index_columns_on_their_table');


--
-- Name: columns rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: index_includes rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_includes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: index_parts rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: indexes rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: columns rule:cortex.key_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.key_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_key_columns_on_their_table');


--
-- Name: table_key_columns rule:cortex.key_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.key_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_key_columns_on_their_table');


--
-- Name: table_keys rule:cortex.key_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.key_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_key_columns_on_their_table');


--
-- Name: columns rule:cortex.key_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.key_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_key_columns_on_their_table');


--
-- Name: table_key_columns rule:cortex.key_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.key_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_key_columns_on_their_table');


--
-- Name: table_keys rule:cortex.key_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.key_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_key_columns_on_their_table');


--
-- Name: check_constraints rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: columns rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: composite_type_fields rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: enum_values rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: indexes rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: locked_versions rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: namespaces rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.namespaces DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: objects rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: partitions rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: pinned_notes rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.pinned_notes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: relationships rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: routine_parameters rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.routine_parameters DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: schema_identity rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.schema_identity DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: sort_fields rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: subject_areas rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.subject_areas DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: table_keys rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: trigger_events rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.trigger_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: turns rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: verbatim_statements rule:cortex.notes_on_what_exists; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.notes_on_what_exists" AFTER INSERT OR DELETE OR UPDATE ON cortex.verbatim_statements DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_notes_on_what_exists');


--
-- Name: check_constraints rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: columns rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: composite_type_fields rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: enum_values rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: indexes rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: locked_versions rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: namespaces rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.namespaces FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: objects rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: partitions rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: pinned_notes rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.pinned_notes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: relationships rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: routine_parameters rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.routine_parameters FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: schema_identity rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.schema_identity FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: sort_fields rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: subject_areas rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.subject_areas FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: table_keys rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: trigger_events rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.trigger_events FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: turns rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: verbatim_statements rule:cortex.notes_on_what_exists:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.notes_on_what_exists:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.verbatim_statements FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_notes_on_what_exists');


--
-- Name: domains rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: objects rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: routines rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: scheduled_events rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.scheduled_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: sequences rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: triggers rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: view_queries rule:cortex.one_program_part; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_program_part" AFTER INSERT OR DELETE OR UPDATE ON cortex.view_queries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_program_part');


--
-- Name: domains rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: objects rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: routines rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: scheduled_events rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.scheduled_events FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: sequences rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: triggers rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: view_queries rule:cortex.one_program_part:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_program_part:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.view_queries FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_program_part');


--
-- Name: namespaces rule:cortex.one_schema_row; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_schema_row" AFTER INSERT OR DELETE OR UPDATE ON cortex.namespaces DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_schema_row');


--
-- Name: schema_identity rule:cortex.one_schema_row; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_schema_row" AFTER INSERT OR DELETE OR UPDATE ON cortex.schema_identity DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_schema_row');


--
-- Name: namespaces rule:cortex.one_schema_row:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_schema_row:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.namespaces FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_schema_row');


--
-- Name: schema_identity rule:cortex.one_schema_row:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_schema_row:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.schema_identity FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_schema_row');


--
-- Name: operations rule:cortex.operation_after_its_turn; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.operation_after_its_turn" AFTER INSERT OR DELETE OR UPDATE ON cortex.operations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_operation_after_its_turn');


--
-- Name: operations rule:cortex.operation_after_its_turn:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.operation_after_its_turn:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.operations FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_operation_after_its_turn');


--
-- Name: columns rule:cortex.partition_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.partition_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_partition_columns_on_their_table');


--
-- Name: partition_fields rule:cortex.partition_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.partition_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_partition_columns_on_their_table');


--
-- Name: sort_fields rule:cortex.partition_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.partition_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_partition_columns_on_their_table');


--
-- Name: columns rule:cortex.partition_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.partition_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_partition_columns_on_their_table');


--
-- Name: partition_fields rule:cortex.partition_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.partition_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_partition_columns_on_their_table');


--
-- Name: sort_fields rule:cortex.partition_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.partition_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_partition_columns_on_their_table');


--
-- Name: check_constraints rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: composite_type_fields rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: domains rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: enum_values rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: indexes rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: object_kind_parts rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_kind_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: objects rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: partition_parents rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_parents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: routines rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: scheduled_events rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.scheduled_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: sequences rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: sort_fields rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: table_keys rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: table_partitionings rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_partitionings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: triggers rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: view_queries rule:cortex.parts_only_in_their_kinds; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_only_in_their_kinds" AFTER INSERT OR DELETE OR UPDATE ON cortex.view_queries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_only_in_their_kinds');


--
-- Name: check_constraints rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.check_constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: composite_type_fields rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.composite_type_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: domains rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: enum_values rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.enum_values FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: indexes rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: object_kind_parts rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.object_kind_parts FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: objects rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: partition_parents rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partition_parents FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: routines rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: scheduled_events rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.scheduled_events FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: sequences rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: sort_fields rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: table_keys rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: table_partitionings rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_partitionings FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: triggers rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: view_queries rule:cortex.parts_only_in_their_kinds:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_only_in_their_kinds:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.view_queries FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_only_in_their_kinds');


--
-- Name: columns rule:cortex.perspective_columns_of_their_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.perspective_columns_of_their_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_perspective_columns_of_their_object');


--
-- Name: perspective_members rule:cortex.perspective_columns_of_their_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.perspective_columns_of_their_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.perspective_members DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_perspective_columns_of_their_object');


--
-- Name: columns rule:cortex.perspective_columns_of_their_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.perspective_columns_of_their_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_perspective_columns_of_their_object');


--
-- Name: perspective_members rule:cortex.perspective_columns_of_their_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.perspective_columns_of_their_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.perspective_members FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_perspective_columns_of_their_object');


--
-- Name: columns rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: table_key_columns rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: table_keys rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: columns rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: table_key_columns rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_key_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: table_keys rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.table_keys FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: columns rule:cortex.relationship_from_columns_on_from_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_from_columns_on_from_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: relationship_columns rule:cortex.relationship_from_columns_on_from_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_from_columns_on_from_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: relationships rule:cortex.relationship_from_columns_on_from_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_from_columns_on_from_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: columns rule:cortex.relationship_from_columns_on_from_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_from_columns_on_from_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: relationship_columns rule:cortex.relationship_from_columns_on_from_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_from_columns_on_from_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: relationships rule:cortex.relationship_from_columns_on_from_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_from_columns_on_from_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_from_columns_on_from_object');


--
-- Name: relationship_columns rule:cortex.relationship_has_columns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_has_columns" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_has_columns');


--
-- Name: relationships rule:cortex.relationship_has_columns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_has_columns" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_has_columns');


--
-- Name: relationship_columns rule:cortex.relationship_has_columns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_has_columns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_has_columns');


--
-- Name: relationships rule:cortex.relationship_has_columns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_has_columns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_has_columns');


--
-- Name: columns rule:cortex.relationship_to_columns_on_to_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_to_columns_on_to_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: relationship_columns rule:cortex.relationship_to_columns_on_to_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_to_columns_on_to_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: relationships rule:cortex.relationship_to_columns_on_to_object; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.relationship_to_columns_on_to_object" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: columns rule:cortex.relationship_to_columns_on_to_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_to_columns_on_to_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: relationship_columns rule:cortex.relationship_to_columns_on_to_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_to_columns_on_to_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationship_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: relationships rule:cortex.relationship_to_columns_on_to_object:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.relationship_to_columns_on_to_object:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.relationships FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_relationship_to_columns_on_to_object');


--
-- Name: row_changes rule:cortex.row_changes_name_tables_of_the_database; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.row_changes_name_tables_of_the_database" AFTER INSERT OR DELETE OR UPDATE ON cortex.row_changes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_row_changes_name_tables_of_the_database');


--
-- Name: row_changes rule:cortex.row_changes_name_tables_of_the_database:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.row_changes_name_tables_of_the_database:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.row_changes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_row_changes_name_tables_of_the_database');


--
-- Name: turns rule:cortex.turn_takes_back_an_earlier_turn; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.turn_takes_back_an_earlier_turn" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_turn_takes_back_an_earlier_turn');


--
-- Name: turns rule:cortex.turn_takes_back_an_earlier_turn:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.turn_takes_back_an_earlier_turn:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_turn_takes_back_an_earlier_turn');


--
-- Name: locked_versions rule:cortex.versions_follow_the_log; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.versions_follow_the_log" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_versions_follow_the_log');


--
-- Name: locked_versions rule:cortex.versions_follow_the_log:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.versions_follow_the_log:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_versions_follow_the_log');


--
-- Name: objects rule:engine_quill.record_options_on_records; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_quill.record_options_on_records" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_quill.broken_record_options_on_records');


--
-- Name: objects rule:engine_quill.record_options_on_records:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_quill.record_options_on_records:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_quill.broken_record_options_on_records');


--
-- Name: record_options rule:engine_quill.record_options_on_records; Type: TRIGGER; Schema: engine_quill; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_quill.record_options_on_records" AFTER INSERT OR DELETE OR UPDATE ON engine_quill.record_options DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_quill.broken_record_options_on_records');


--
-- Name: record_options rule:engine_quill.record_options_on_records:again; Type: TRIGGER; Schema: engine_quill; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_quill.record_options_on_records:again" AFTER INSERT OR DELETE OR UPDATE ON engine_quill.record_options FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_quill.broken_record_options_on_records');


--
-- Name: catalog_sources catalog_sources_version_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.catalog_sources
    ADD CONSTRAINT catalog_sources_version_fkey FOREIGN KEY (version) REFERENCES cortex.engine_versions(id);


--
-- Name: check_constraints check_constraints_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.check_constraints
    ADD CONSTRAINT check_constraints_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: column_identities column_identities_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.column_identities
    ADD CONSTRAINT column_identities_id_fkey FOREIGN KEY (id) REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: columns columns_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: composite_type_fields composite_type_fields_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.composite_type_fields
    ADD CONSTRAINT composite_type_fields_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: domains domains_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.domains
    ADD CONSTRAINT domains_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: engine_features engine_features_since_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.engine_features
    ADD CONSTRAINT engine_features_since_fkey FOREIGN KEY (since) REFERENCES cortex.engine_versions(id);


--
-- Name: engine_features engine_features_until_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.engine_features
    ADD CONSTRAINT engine_features_until_fkey FOREIGN KEY (until) REFERENCES cortex.engine_versions(id);


--
-- Name: enum_values enum_values_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: family_assignments family_assignments_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.family_assignments
    ADD CONSTRAINT family_assignments_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: index_includes index_includes_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_includes
    ADD CONSTRAINT index_includes_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: index_includes index_includes_index_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_includes
    ADD CONSTRAINT index_includes_index_fkey FOREIGN KEY (index) REFERENCES cortex.indexes(id) ON DELETE CASCADE;


--
-- Name: index_parts index_parts_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: index_parts index_parts_index_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_index_fkey FOREIGN KEY (index) REFERENCES cortex.indexes(id) ON DELETE CASCADE;


--
-- Name: indexes indexes_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: layout_pins layout_pins_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.layout_pins
    ADD CONSTRAINT layout_pins_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: locked_versions locked_versions_at_operation_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_at_operation_fkey FOREIGN KEY (at_operation) REFERENCES cortex.operations(id);


--
-- Name: namespaces namespaces_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.namespaces(id) ON DELETE CASCADE;


--
-- Name: object_kind_parts object_kind_parts_kind_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_kind_parts
    ADD CONSTRAINT object_kind_parts_kind_fkey FOREIGN KEY (kind) REFERENCES cortex.object_kinds(id) ON DELETE CASCADE;


--
-- Name: object_reads object_reads_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_reads
    ADD CONSTRAINT object_reads_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: object_reads object_reads_reads_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_reads
    ADD CONSTRAINT object_reads_reads_fkey FOREIGN KEY (reads) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: object_tags object_tags_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: objects objects_area_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_area_fkey FOREIGN KEY (area) REFERENCES cortex.subject_areas(id) ON DELETE SET NULL;


--
-- Name: objects objects_kind_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_kind_fkey FOREIGN KEY (kind) REFERENCES cortex.object_kinds(id);


--
-- Name: objects objects_namespace_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_fkey FOREIGN KEY (namespace) REFERENCES cortex.namespaces(id) ON DELETE CASCADE;


--
-- Name: operations operations_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: partition_fields partition_fields_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_fields
    ADD CONSTRAINT partition_fields_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: partition_fields partition_fields_partitioning_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_fields
    ADD CONSTRAINT partition_fields_partitioning_fkey FOREIGN KEY (partitioning) REFERENCES cortex.table_partitionings(id) ON DELETE CASCADE;


--
-- Name: partition_parents partition_parents_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_parents
    ADD CONSTRAINT partition_parents_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: partition_parents partition_parents_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partition_parents
    ADD CONSTRAINT partition_parents_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: partitions partitions_partitioning_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_fkey FOREIGN KEY (partitioning) REFERENCES cortex.table_partitionings(id) ON DELETE CASCADE;


--
-- Name: perspective_members perspective_members_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.perspective_members
    ADD CONSTRAINT perspective_members_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: perspective_members perspective_members_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.perspective_members
    ADD CONSTRAINT perspective_members_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: perspective_members perspective_members_perspective_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.perspective_members
    ADD CONSTRAINT perspective_members_perspective_fkey FOREIGN KEY (perspective) REFERENCES cortex.custom_perspectives(id) ON DELETE CASCADE;


--
-- Name: relationship_columns relationship_columns_from_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationship_columns
    ADD CONSTRAINT relationship_columns_from_column_fkey FOREIGN KEY (from_column) REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: relationship_columns relationship_columns_relationship_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationship_columns
    ADD CONSTRAINT relationship_columns_relationship_fkey FOREIGN KEY (relationship) REFERENCES cortex.relationships(id) ON DELETE CASCADE;


--
-- Name: relationship_columns relationship_columns_to_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationship_columns
    ADD CONSTRAINT relationship_columns_to_column_fkey FOREIGN KEY (to_column) REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: relationships relationships_from_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationships
    ADD CONSTRAINT relationships_from_object_fkey FOREIGN KEY (from_object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: relationships relationships_to_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.relationships
    ADD CONSTRAINT relationships_to_object_fkey FOREIGN KEY (to_object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: routine_parameters routine_parameters_routine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routine_parameters
    ADD CONSTRAINT routine_parameters_routine_fkey FOREIGN KEY (routine) REFERENCES cortex.routines(id) ON DELETE CASCADE;


--
-- Name: routines routines_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routines
    ADD CONSTRAINT routines_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: row_changes row_changes_operation_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_operation_fkey FOREIGN KEY (operation) REFERENCES cortex.operations(id);


--
-- Name: scheduled_events scheduled_events_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.scheduled_events
    ADD CONSTRAINT scheduled_events_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: sequences sequences_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sequences
    ADD CONSTRAINT sequences_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: sequences sequences_owned_by_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sequences
    ADD CONSTRAINT sequences_owned_by_fkey FOREIGN KEY (owned_by) REFERENCES cortex.columns(id) ON DELETE SET NULL;


--
-- Name: sort_fields sort_fields_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: sort_fields sort_fields_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: source_reads source_reads_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.source_reads
    ADD CONSTRAINT source_reads_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: table_key_columns table_key_columns_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_key_columns
    ADD CONSTRAINT table_key_columns_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE;


--
-- Name: table_key_columns table_key_columns_key_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_key_columns
    ADD CONSTRAINT table_key_columns_key_fkey FOREIGN KEY (key) REFERENCES cortex.table_keys(id) ON DELETE CASCADE;


--
-- Name: table_keys table_keys_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_keys
    ADD CONSTRAINT table_keys_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: table_partitionings table_partitionings_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.table_partitionings
    ADD CONSTRAINT table_partitionings_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: trigger_events trigger_events_trigger_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.trigger_events
    ADD CONSTRAINT trigger_events_trigger_fkey FOREIGN KEY (trigger) REFERENCES cortex.triggers(id) ON DELETE CASCADE;


--
-- Name: triggers triggers_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.triggers
    ADD CONSTRAINT triggers_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: triggers triggers_on_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.triggers
    ADD CONSTRAINT triggers_on_fkey FOREIGN KEY ("on") REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: turns turns_undoes_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_undoes_fkey FOREIGN KEY (undoes) REFERENCES cortex.turns(id);


--
-- Name: value_changes value_changes_row_change_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.value_changes
    ADD CONSTRAINT value_changes_row_change_fkey FOREIGN KEY (row_change) REFERENCES cortex.row_changes(id);


--
-- Name: verbatim_statements verbatim_statements_after_namespace_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_after_namespace_fkey FOREIGN KEY (after_namespace) REFERENCES cortex.namespaces(id) ON DELETE SET NULL;


--
-- Name: verbatim_statements verbatim_statements_after_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_after_object_fkey FOREIGN KEY (after_object) REFERENCES cortex.objects(id) ON DELETE SET NULL;


--
-- Name: view_queries view_queries_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.view_queries
    ADD CONSTRAINT view_queries_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: record_options record_options_id_fkey; Type: FK CONSTRAINT; Schema: engine_quill; Owner: sf_owner
--

ALTER TABLE ONLY engine_quill.record_options
    ADD CONSTRAINT record_options_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE;


--
-- Name: SCHEMA cortex; Type: ACL; Schema: -; Owner: sf_owner
--

GRANT USAGE ON SCHEMA cortex TO sf_service;
GRANT USAGE ON SCHEMA cortex TO sf_reader;


--
-- Name: SCHEMA engine_quill; Type: ACL; Schema: -; Owner: sf_owner
--

GRANT USAGE ON SCHEMA engine_quill TO sf_service;
GRANT USAGE ON SCHEMA engine_quill TO sf_reader;


--
-- Name: FUNCTION enforce_rules(owner text); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.enforce_rules(owner text) TO sf_service;


--
-- Name: FUNCTION grant_roles(owner text); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.grant_roles(owner text) TO sf_service;


--
-- Name: FUNCTION rule_again(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_again() TO sf_service;


--
-- Name: FUNCTION rule_check(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_check() TO sf_service;


--
-- Name: FUNCTION rule_marks(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_marks() TO sf_service;


--
-- Name: TABLE engine_features; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.engine_features TO sf_service;
GRANT SELECT ON TABLE cortex.engine_features TO sf_reader;


--
-- Name: TABLE engine_versions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.engine_versions TO sf_service;
GRANT SELECT ON TABLE cortex.engine_versions TO sf_reader;


--
-- Name: TABLE broken_features_since_before_until; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_features_since_before_until TO sf_service;
GRANT SELECT ON TABLE cortex.broken_features_since_before_until TO sf_reader;


--
-- Name: TABLE check_constraints; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.check_constraints TO sf_service;
GRANT SELECT ON TABLE cortex.check_constraints TO sf_reader;


--
-- Name: TABLE composite_type_fields; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.composite_type_fields TO sf_service;
GRANT SELECT ON TABLE cortex.composite_type_fields TO sf_reader;


--
-- Name: TABLE enum_values; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.enum_values TO sf_service;
GRANT SELECT ON TABLE cortex.enum_values TO sf_reader;


--
-- Name: TABLE id_counters; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.id_counters TO sf_service;
GRANT SELECT ON TABLE cortex.id_counters TO sf_reader;


--
-- Name: TABLE index_includes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_includes TO sf_service;
GRANT SELECT ON TABLE cortex.index_includes TO sf_reader;


--
-- Name: TABLE index_parts; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_parts TO sf_service;
GRANT SELECT ON TABLE cortex.index_parts TO sf_reader;


--
-- Name: TABLE indexes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.indexes TO sf_service;
GRANT SELECT ON TABLE cortex.indexes TO sf_reader;


--
-- Name: TABLE layout_pins; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.layout_pins TO sf_service;
GRANT SELECT ON TABLE cortex.layout_pins TO sf_reader;


--
-- Name: TABLE object_reads; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_reads TO sf_service;
GRANT SELECT ON TABLE cortex.object_reads TO sf_reader;


--
-- Name: TABLE object_tags; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_tags TO sf_service;
GRANT SELECT ON TABLE cortex.object_tags TO sf_reader;


--
-- Name: TABLE partition_fields; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partition_fields TO sf_service;
GRANT SELECT ON TABLE cortex.partition_fields TO sf_reader;


--
-- Name: TABLE partitions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partitions TO sf_service;
GRANT SELECT ON TABLE cortex.partitions TO sf_reader;


--
-- Name: TABLE perspective_members; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.perspective_members TO sf_service;
GRANT SELECT ON TABLE cortex.perspective_members TO sf_reader;


--
-- Name: TABLE pinned_notes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.pinned_notes TO sf_service;
GRANT SELECT ON TABLE cortex.pinned_notes TO sf_reader;


--
-- Name: TABLE relationship_columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.relationship_columns TO sf_service;
GRANT SELECT ON TABLE cortex.relationship_columns TO sf_reader;


--
-- Name: TABLE routine_parameters; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routine_parameters TO sf_service;
GRANT SELECT ON TABLE cortex.routine_parameters TO sf_reader;


--
-- Name: TABLE sort_fields; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sort_fields TO sf_service;
GRANT SELECT ON TABLE cortex.sort_fields TO sf_reader;


--
-- Name: TABLE table_key_columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.table_key_columns TO sf_service;
GRANT SELECT ON TABLE cortex.table_key_columns TO sf_reader;


--
-- Name: TABLE table_keys; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.table_keys TO sf_service;
GRANT SELECT ON TABLE cortex.table_keys TO sf_reader;


--
-- Name: TABLE trigger_events; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.trigger_events TO sf_service;
GRANT SELECT ON TABLE cortex.trigger_events TO sf_reader;


--
-- Name: TABLE verbatim_statements; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.verbatim_statements TO sf_service;
GRANT SELECT ON TABLE cortex.verbatim_statements TO sf_reader;


--
-- Name: TABLE broken_ids_within_their_counters; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_ids_within_their_counters TO sf_service;
GRANT SELECT ON TABLE cortex.broken_ids_within_their_counters TO sf_reader;


--
-- Name: TABLE columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.columns TO sf_service;
GRANT SELECT ON TABLE cortex.columns TO sf_reader;


--
-- Name: TABLE broken_index_columns_on_their_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_index_columns_on_their_table TO sf_service;
GRANT SELECT ON TABLE cortex.broken_index_columns_on_their_table TO sf_reader;


--
-- Name: TABLE broken_key_columns_on_their_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_key_columns_on_their_table TO sf_service;
GRANT SELECT ON TABLE cortex.broken_key_columns_on_their_table TO sf_reader;


--
-- Name: TABLE locked_versions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.locked_versions TO sf_service;
GRANT SELECT ON TABLE cortex.locked_versions TO sf_reader;


--
-- Name: TABLE namespaces; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.namespaces TO sf_service;
GRANT SELECT ON TABLE cortex.namespaces TO sf_reader;


--
-- Name: TABLE objects; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.objects TO sf_service;
GRANT SELECT ON TABLE cortex.objects TO sf_reader;


--
-- Name: TABLE relationships; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.relationships TO sf_service;
GRANT SELECT ON TABLE cortex.relationships TO sf_reader;


--
-- Name: TABLE schema_identity; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.schema_identity TO sf_service;
GRANT SELECT ON TABLE cortex.schema_identity TO sf_reader;


--
-- Name: TABLE subject_areas; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.subject_areas TO sf_service;
GRANT SELECT ON TABLE cortex.subject_areas TO sf_reader;


--
-- Name: TABLE turns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.turns TO sf_service;
GRANT SELECT ON TABLE cortex.turns TO sf_reader;


--
-- Name: TABLE broken_notes_on_what_exists; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_notes_on_what_exists TO sf_service;
GRANT SELECT ON TABLE cortex.broken_notes_on_what_exists TO sf_reader;


--
-- Name: TABLE domains; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.domains TO sf_service;
GRANT SELECT ON TABLE cortex.domains TO sf_reader;


--
-- Name: TABLE routines; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routines TO sf_service;
GRANT SELECT ON TABLE cortex.routines TO sf_reader;


--
-- Name: TABLE scheduled_events; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.scheduled_events TO sf_service;
GRANT SELECT ON TABLE cortex.scheduled_events TO sf_reader;


--
-- Name: TABLE sequences; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sequences TO sf_service;
GRANT SELECT ON TABLE cortex.sequences TO sf_reader;


--
-- Name: TABLE triggers; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.triggers TO sf_service;
GRANT SELECT ON TABLE cortex.triggers TO sf_reader;


--
-- Name: TABLE view_queries; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.view_queries TO sf_service;
GRANT SELECT ON TABLE cortex.view_queries TO sf_reader;


--
-- Name: TABLE broken_one_program_part; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_one_program_part TO sf_service;
GRANT SELECT ON TABLE cortex.broken_one_program_part TO sf_reader;


--
-- Name: TABLE broken_one_schema_row; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_one_schema_row TO sf_service;
GRANT SELECT ON TABLE cortex.broken_one_schema_row TO sf_reader;


--
-- Name: TABLE operations; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.operations TO sf_service;
GRANT SELECT ON TABLE cortex.operations TO sf_reader;


--
-- Name: TABLE broken_operation_after_its_turn; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_operation_after_its_turn TO sf_service;
GRANT SELECT ON TABLE cortex.broken_operation_after_its_turn TO sf_reader;


--
-- Name: TABLE broken_partition_columns_on_their_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_partition_columns_on_their_table TO sf_service;
GRANT SELECT ON TABLE cortex.broken_partition_columns_on_their_table TO sf_reader;


--
-- Name: TABLE object_kind_parts; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_kind_parts TO sf_service;
GRANT SELECT ON TABLE cortex.object_kind_parts TO sf_reader;


--
-- Name: TABLE partition_parents; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partition_parents TO sf_service;
GRANT SELECT ON TABLE cortex.partition_parents TO sf_reader;


--
-- Name: TABLE table_partitionings; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.table_partitionings TO sf_service;
GRANT SELECT ON TABLE cortex.table_partitionings TO sf_reader;


--
-- Name: TABLE broken_parts_only_in_their_kinds; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_parts_only_in_their_kinds TO sf_service;
GRANT SELECT ON TABLE cortex.broken_parts_only_in_their_kinds TO sf_reader;


--
-- Name: TABLE broken_perspective_columns_of_their_object; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_perspective_columns_of_their_object TO sf_service;
GRANT SELECT ON TABLE cortex.broken_perspective_columns_of_their_object TO sf_reader;


--
-- Name: TABLE broken_primary_key_columns_not_null; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_primary_key_columns_not_null TO sf_service;
GRANT SELECT ON TABLE cortex.broken_primary_key_columns_not_null TO sf_reader;


--
-- Name: TABLE broken_relationship_from_columns_on_from_object; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_relationship_from_columns_on_from_object TO sf_service;
GRANT SELECT ON TABLE cortex.broken_relationship_from_columns_on_from_object TO sf_reader;


--
-- Name: TABLE broken_relationship_has_columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_relationship_has_columns TO sf_service;
GRANT SELECT ON TABLE cortex.broken_relationship_has_columns TO sf_reader;


--
-- Name: TABLE broken_relationship_to_columns_on_to_object; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_relationship_to_columns_on_to_object TO sf_service;
GRANT SELECT ON TABLE cortex.broken_relationship_to_columns_on_to_object TO sf_reader;


--
-- Name: TABLE row_changes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.row_changes TO sf_service;
GRANT SELECT ON TABLE cortex.row_changes TO sf_reader;


--
-- Name: TABLE broken_row_changes_name_tables_of_the_database; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_row_changes_name_tables_of_the_database TO sf_service;
GRANT SELECT ON TABLE cortex.broken_row_changes_name_tables_of_the_database TO sf_reader;


--
-- Name: TABLE broken_turn_takes_back_an_earlier_turn; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_turn_takes_back_an_earlier_turn TO sf_service;
GRANT SELECT ON TABLE cortex.broken_turn_takes_back_an_earlier_turn TO sf_reader;


--
-- Name: TABLE broken_versions_follow_the_log; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_versions_follow_the_log TO sf_service;
GRANT SELECT ON TABLE cortex.broken_versions_follow_the_log TO sf_reader;


--
-- Name: TABLE catalog_sources; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.catalog_sources TO sf_service;
GRANT SELECT ON TABLE cortex.catalog_sources TO sf_reader;


--
-- Name: TABLE column_identities; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.column_identities TO sf_service;
GRANT SELECT ON TABLE cortex.column_identities TO sf_reader;


--
-- Name: TABLE custom_perspectives; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.custom_perspectives TO sf_service;
GRANT SELECT ON TABLE cortex.custom_perspectives TO sf_reader;


--
-- Name: TABLE family_assignments; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.family_assignments TO sf_service;
GRANT SELECT ON TABLE cortex.family_assignments TO sf_reader;


--
-- Name: TABLE object_kinds; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_kinds TO sf_service;
GRANT SELECT ON TABLE cortex.object_kinds TO sf_reader;


--
-- Name: TABLE required_extensions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.required_extensions TO sf_service;
GRANT SELECT ON TABLE cortex.required_extensions TO sf_reader;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.schema_migrations TO sf_service;
GRANT SELECT ON TABLE cortex.schema_migrations TO sf_reader;


--
-- Name: TABLE source_reads; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.source_reads TO sf_service;
GRANT SELECT ON TABLE cortex.source_reads TO sf_reader;


--
-- Name: TABLE value_changes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.value_changes TO sf_service;
GRANT SELECT ON TABLE cortex.value_changes TO sf_reader;


--
-- Name: TABLE record_options; Type: ACL; Schema: engine_quill; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_quill.record_options TO sf_service;
GRANT SELECT ON TABLE engine_quill.record_options TO sf_reader;


--
-- Name: TABLE broken_record_options_on_records; Type: ACL; Schema: engine_quill; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_quill.broken_record_options_on_records TO sf_service;
GRANT SELECT ON TABLE engine_quill.broken_record_options_on_records TO sf_reader;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: cortex; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT ALL ON FUNCTIONS TO sf_service;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: cortex; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT SELECT ON TABLES TO sf_reader;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: engine_quill; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_quill GRANT ALL ON FUNCTIONS TO sf_service;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: engine_quill; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_quill GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_quill GRANT SELECT ON TABLES TO sf_reader;


--
-- PostgreSQL database dump complete
--
